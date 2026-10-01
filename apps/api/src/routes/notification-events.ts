import { Hono } from "hono";
import { z } from "zod";
import type { Env } from "../env";
import type { Json } from "../db/types";
import { getSupabaseClient } from "../db/client";
import { requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { checkVerifiedMatch, isVerifiedMatch } from "../services/match-age-access";

const notificationEvents = new Hono<Env>();

/**
 * The event types an app client may report. Matches the CHECK constraint
 * on notification_events.event_type in migration 20260812100400_notifications.sql,
 * minus `sent` — that value is written only by the send pipeline itself
 * (services/notifications.ts), never by a client report.
 */
const CLIENT_EVENT_TYPES = ["delivered", "opened", "screen_viewed", "action_completed", "dismissed"] as const;

/**
 * Bounds on `metadata` (orchestrator review round 2, finding #3): the
 * unbounded `z.record(z.unknown())` this replaced let any authenticated
 * user who owns a notification persist arbitrarily large / deeply nested
 * JSON, repeatedly, through the service-role insert — `screen` right next
 * to it is already capped at 200 chars, so this field was the outlier.
 * Values are restricted to flat primitives (no nested objects/arrays), the
 * key count is capped, and the serialized size is capped independently of
 * key count (a few very long string values could still stay under the key
 * cap while being huge).
 */
const METADATA_MAX_KEYS = 20;
const METADATA_MAX_VALUE_STRING_LENGTH = 500;
const METADATA_MAX_SERIALIZED_BYTES = 4000;

const metadataValueSchema = z.union([z.string().max(METADATA_MAX_VALUE_STRING_LENGTH), z.number(), z.boolean(), z.null()]);

const metadataSchema = z
	.record(metadataValueSchema)
	.refine((obj) => Object.keys(obj).length <= METADATA_MAX_KEYS, {
		message: `metadata may have at most ${METADATA_MAX_KEYS} keys`,
	})
	.refine((obj) => new TextEncoder().encode(JSON.stringify(obj)).length <= METADATA_MAX_SERIALIZED_BYTES, {
		message: `metadata must serialize to at most ${METADATA_MAX_SERIALIZED_BYTES} bytes`,
	})
	.optional();

const bodySchema = z.object({
	notification_id: z.string().uuid(),
	event_type: z.enum(CLIENT_EVENT_TYPES),
	screen: z.string().max(200).optional(),
	occurred_at: z.string().datetime().optional(),
	metadata: metadataSchema,
});

/**
 * POST /api/notification-events — the app reports delivery/open/action
 * events for a notification it received (step-04-notifications.md §3-1).
 *
 * Ownership is enforced twice, deliberately: here (an explicit lookup +
 * comparison against the caller's own user_id) and by RLS policy
 * `notification_events_insert` (supabase/migrations/20260812100400_notifications.sql)
 * for any direct, non-service_role access. This route uses the service_role
 * client like the rest of the API (AGENTS.md security posture #3), so the
 * API-layer check here is the check that actually runs on this path — RLS
 * is the second line of defence for a client that talks to Supabase
 * directly instead of through this API.
 *
 * Both "notification doesn't exist" and "notification belongs to someone
 * else" return the identical NOT_FOUND response (orchestrator review
 * P2-a): returning FORBIDDEN for the second case would let any
 * authenticated caller use this endpoint as an existence oracle for
 * arbitrary notification_id values, the same class of leak as PR #26. The
 * distinction is only ever logged server-side.
 */
notificationEvents.post("/", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);

	let rawBody: unknown;
	try {
		rawBody = await c.req.json();
	} catch {
		return jsonError(c, "BAD_REQUEST", "Request body must be valid JSON");
	}
	const parsed = bodySchema.safeParse(rawBody);
	if (!parsed.success) {
		return jsonError(c, "BAD_REQUEST", parsed.error.message);
	}
	const body = parsed.data;

	const { data: notification, error: lookupError } = await supabase
		.from("notifications")
		.select("id, user_id, match_id")
		.eq("id", body.notification_id)
		.single();
	if (lookupError || !notification) {
		return jsonError(c, "NOT_FOUND", "Notification not found");
	}
	if (notification.user_id !== userId) {
		// Same response as the not-found case above — see the doc comment.
		console.warn(
			`[notification-events] user ${userId} reported an event against notification ${body.notification_id}, which belongs to a different user`,
		);
		return jsonError(c, "NOT_FOUND", "Notification not found");
	}
	if (notification.match_id) {
		const ageCheck = await checkVerifiedMatch(supabase, notification.match_id, userId);
		if (!isVerifiedMatch(ageCheck)) {
			return ageCheck.reason === "error"
				? jsonError(c, "INTERNAL_ERROR", "Failed to verify notification eligibility")
				: jsonError(c, "NOT_FOUND", "Notification not found");
		}
	}

	const { data: inserted, error: insertError } = await supabase
		.from("notification_events")
		.insert({
			notification_id: body.notification_id,
			user_id: userId,
			event_type: body.event_type,
			screen: body.screen ?? null,
			occurred_at: body.occurred_at ?? new Date().toISOString(),
			metadata: (body.metadata as Json | undefined) ?? null,
		})
		.select("id")
		.single();
	if (insertError || !inserted) {
		console.error("[notification-events] failed to insert event:", insertError?.message);
		return jsonError(c, "INTERNAL_ERROR", "Failed to record event");
	}

	return jsonData(c, { id: inserted.id }, 201);
});

export default notificationEvents;
