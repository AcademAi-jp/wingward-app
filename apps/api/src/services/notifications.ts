import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../db/types";
import { assertValidTimeZone, getHourInTimeZone, nextClockTimeInTimeZone } from "../lib/date";
import { isAllowedDeepLink } from "../lib/deep-links";
import { sendOneSignalNotification, setOneSignalTags } from "../lib/onesignal";
import { hasRecordingRehearsalConfig } from "./recording-rehearsal";
import { getNotificationCopy } from "./notification-copy";
import { computeNotificationTags } from "./notification-tags";
import { checkVerifiedMatch, isVerifiedMatch, type MatchParticipants } from "./match-age-access";
import {
	checkNotificationDeliveryAccess,
	isWiredNotificationScenario,
	isNotificationDeliveryContextForScenario,
	parseNotificationDeliveryContext,
	readNotificationMatchParticipants,
	type NotificationDeliveryContext,
} from "./notification-delivery-access";

/**
 * Transactional notification send pipeline (step-04-notifications.md §3-1).
 *
 * All three pre-send checks (quiet hours, 24h dedup, lost-permission
 * handling) live inside {@link sendNotification} / {@link deliverNow} —
 * deliberately not scattered into callers, per the spec.
 */

export interface NotificationsEnv {
	RECORDING_REHEARSAL_ENABLED?: string;
	RECORDING_REHEARSAL_ISSUED_AT?: string;
	RECORDING_REHEARSAL_EXPIRES_AT?: string;
	RECORDING_REHEARSAL_PAIR?: string;
	ONESIGNAL_APP_ID?: string;
	ONESIGNAL_API_KEY?: string;
	DEFERRED_SEND_LIMIT?: string;
}

const QUIET_HOURS_START = 22;
const QUIET_HOURS_END = 8;
const DEDUP_WINDOW_MS = 24 * 60 * 60 * 1000;

/**
 * The binding ceiling is 50 subrequests per invocation (Workers Free; Paid
 * raises it, but sizing against the lower number keeps the app deployable on
 * either). This executor no longer shares an invocation with `runDailyBatch`
 * — step 4-C split `handleScheduled` on `event.cron` precisely so the two
 * budgets stay separate — so the full 50 is available here, and the budget
 * below is sized against it rather than against a shared allowance (orchestrator review P1-a — the exact
 * trap step-04-notifications.md §7 item 2 named: recompute the budget
 * rather than trust an earlier assumption, every round). Round 6 raised
 * the WORST case again: recordSentEvent's collision-path fallback (see
 * its doc comment) adds up to 2 more subrequests, but only on that rare,
 * adversarial path — the common case is still a single insert.
 *
 * Actual subrequest count per due row processed by
 * {@link sendDeferredNotifications} — the worst case is now a row whose
 * `sent`-event id has been forged/occupied by a foreign row (round 6),
 * going through a fresh successful "sent" path:
 *   1 (claimDueNotification: the atomic claim UPDATE, round 3 finding #4)
 * + 1 (OneSignal POST /notifications, via deliverNow)
 * + 1 (notifications UPDATE: onesignal_notification_id, fenced, via deliverNow)
 * + 1 (notification_events INSERT: the `sent` event, deterministic id —
 *      always attempted first, round 5 finding #1)
 * + 1 (notification_events SELECT: identity check, only reached after a
 *      23505 collision on the insert above — round 6)
 * + 1 (notification_events INSERT: the fallback, non-deterministic-id
 *      insert, only reached if the identity check found no genuine sent
 *      event yet — round 6)
 * + 1 (notifications UPDATE: sent_at, fenced)
 * = 7 subrequests/row (was 5 before round 6; the ordinary, non-adversarial
 * case is still 5 — the extra 2 apply only when a collision is hit).
 * (The suppressed path costs 3: claim + one OneSignal call + one combined,
 * fenced notifications UPDATE (suppressed_reason + onesignal_notification_id)
 * — safe to combine there because a retry after a failed suppression write
 * just re-asks OneSignal, which is idempotent and never delivers a
 * duplicate push for a target with no subscription; this path never
 * touches notification_events at all. The "already answered, only
 * bookkeeping left" repair path (round 2 finding #1 / round 3 finding #2 /
 * round 4 findings #1-#2) costs the same as a fresh send minus the
 * OneSignal call and id-persist write: claim + recordSentEvent (1, or up
 * to 3 on a collision) + the fenced sent_at write, i.e. 3-5. A row this
 * invocation loses the claim race for, or the fencing check for, costs
 * 1-2: just the claim/check attempt(s) — no OneSignal call, no further
 * writes, and — critically — NOT counted against either retry budget
 * below, since losing a race is not a delivery failure of any kind.)
 *
 * PR #31 added 2 more to every fresh row: the block revalidation's `matches`
 * and `blocks` lookups (see checkNotificationBlocked). A fresh row is
 * therefore 7-9, not 5-7. Round 8 added one more — the fenced
 * "is this row still sendable" re-read immediately before the outbound call
 * — making a fresh row 8-10. Rows on the repair path skip both the block
 * check and the re-read
 * entirely — a push OneSignal already accepted cannot be unsent — so they
 * stay at 3-5.
 *
 * The final eligibility gate adds 2 more reads per fresh row: one ordered
 * match-identity read and one embedded notification snapshot that carries
 * the scenario, profiles, blocks, contact state and meetup state. This makes
 * a fresh row 10-12 requests. Real SupabaseJS transport tests measure 37
 * database + 4 provider requests for four ordinary rows, and 45 + 4 for four
 * event-collision rows. Already-accepted repair skips those reads.
 * Plus 1 subrequest for the single "which rows are due" query itself.
 * Total for `limit = 4` on the adversarial path: 1 + 4*12 = 49, inside the
 * 50 this invocation now has to itself. Explicit/environment overrides are
 * not clamped here; these measurements cover the default. Recount before changing the
 * limit; it has moved on every review round that touched the send path, and
 * every one of those rounds found the previous figure still written here.
 */
export const DEFAULT_DEFERRED_SEND_LIMIT = 4;

export interface SendNotificationParams {
	scenarioId: string;
	userId: string;
	matchId?: string | null;
	meetupId?: string | null;
	deepLink: string;
	/** Internal binding ids persisted in payload; never sent to OneSignal. */
	deliveryContext?: NotificationDeliveryContext | null;
	/** Injectable for tests; defaults to the real current time. */
	now?: Date;
	/** Optional clock used for final-state tests; sampled immediately before the final read. */
	clock?: () => Date;
}

export type SendNotificationResult =
	| { ok: true; notificationId: string; outcome: "sent" }
	| { ok: true; notificationId: string; outcome: "deferred"; scheduledFor: string }
	| { ok: true; notificationId: string; outcome: "suppressed_no_subscription" }
	| { ok: false; reason: "invalid_deep_link" }
	| { ok: false; reason: "not_configured" }
	| { ok: false; reason: "unknown_scenario" }
	| { ok: false; reason: "scenario_disabled" }
	| { ok: false; reason: "user_not_found" }
	| { ok: false; reason: "invalid_timezone" }
	| { ok: false; reason: "duplicate" }
	| { ok: false; reason: "blocked" }
	| { ok: false; reason: "block_check_failed" }
	| { ok: false; notificationId?: string; reason: "age_unverified" | "age_verification_failed" }
	| { ok: false; reason: "insert_failed" }
	| { ok: false; notificationId: string; reason: "send_failed" }
	| { ok: false; notificationId?: string; reason: "delivery_precondition_failed" }
	| { ok: false; notificationId: string; reason: "delivery_check_failed" }
	| { ok: false; notificationId: string; reason: "send_accepted_but_unrecorded"; oneSignalId: string }
	| { ok: false; notificationId: string; reason: "suppression_unrecorded"; oneSignalId: string }
	| { ok: false; notificationId: string; reason: "lost_ownership" };

/**
 * Whether a match-scoped notification must not go out because one of the two
 * people has blocked the other.
 *
 * This lives in the pipeline rather than at the trigger sites on purpose.
 * Checking at the trigger only covers the instant the notification is
 * CREATED, and a quiet-hours notification can sit deferred for up to ten
 * hours before delivery — long enough for the recipient to block the other
 * person in between (Codex P0, PR #31 review round 3). The relationship has
 * to be revalidated at every point where a push could actually leave, and the
 * only way to guarantee that for every future scenario is to put it where no
 * caller can forget it.
 *
 * `null` match_id means the notification is not about a pair (N-13's
 * availability reminder, say), so there is no relationship to check.
 *
 * Returns `"error"` rather than a boolean on a failed lookup: callers must
 * fail closed. An unreadable block list is not "not blocked" — this app can
 * put these two people in a room together.
 */
async function checkNotificationBlocked(
	supabase: SupabaseClient<Database>,
	matchId: string | null | undefined,
	userId: string,
	knownMatch: MatchParticipants | null = null,
): Promise<"blocked" | "clear" | "error"> {
	if (!matchId) return "clear";

	let match = knownMatch;
	if (match?.id && match.id !== matchId) return "error";
	if (!match) {
		const { data, error: matchError } = await supabase
			.from("matches")
			.select("user_a_id, user_b_id")
			.eq("id", matchId)
			.single();
		if (matchError || !data) {
			console.error(`[notifications/blocks] could not read match ${matchId} for a block check:`, matchError?.message);
			return "error";
		}
		match = data;
	}
	if (match.user_a_id !== userId && match.user_b_id !== userId) return "error";

	const counterpartId = match.user_a_id === userId ? match.user_b_id : match.user_a_id;
	const { data: blockRow, error: blockError } = await supabase
		.from("blocks")
		.select("id")
		.or(`and(blocker_id.eq.${userId},blocked_id.eq.${counterpartId}),and(blocker_id.eq.${counterpartId},blocked_id.eq.${userId})`)
		.limit(1)
		.maybeSingle();
	if (blockError) {
		console.error(`[notifications/blocks] blocks lookup failed for match ${matchId}:`, blockError.message);
		return "error";
	}
	return blockRow ? "blocked" : "clear";
}

type NotificationAgeState = "unverified" | "clear" | "error";
type NotificationAgeCheck = { state: NotificationAgeState; match: MatchParticipants | null };

/** Match-scoped notifications require both participants at every send point. */
async function checkNotificationAgeVerified(
	supabase: SupabaseClient<Database>,
	matchId: string | null | undefined,
	userId: string,
): Promise<NotificationAgeCheck> {
	if (!matchId) return { state: "clear", match: null };

	const result = await checkVerifiedMatch(supabase, matchId, userId);
	if (isVerifiedMatch(result)) return { state: "clear", match: result.match };
	return {
		state: result.reason === "error" ? "error" : "unverified",
		match: null,
	};
}

/**
 * Sends (or holds, or suppresses) one transactional notification.
 *
 * `deepLink` is validated against the server-side allow-list before
 * anything else happens — an out-of-list deep link is rejected outright,
 * no `notifications` row is created for it (step-04-notifications.md §5).
 */
export async function sendNotification(
	supabase: SupabaseClient<Database>,
	env: NotificationsEnv,
	params: SendNotificationParams,
): Promise<SendNotificationResult> {
	const now = params.now ?? new Date();

	if (!isAllowedDeepLink(params.deepLink)) {
		return { ok: false, reason: "invalid_deep_link" };
	}

	if (!env.ONESIGNAL_APP_ID || !env.ONESIGNAL_API_KEY) {
		console.error("[notifications/send] OneSignal not configured (ONESIGNAL_APP_ID/ONESIGNAL_API_KEY unset)");
		return { ok: false, reason: "not_configured" };
	}

	const { data: scenario, error: scenarioError } = await supabase
		.from("notification_scenarios")
		.select("quiet_hours_exempt, is_enabled")
		.eq("scenario_id", params.scenarioId)
		.single();
	if (scenarioError || !scenario) {
		console.error(`[notifications/send] unknown scenario_id ${params.scenarioId}:`, scenarioError?.message);
		return { ok: false, reason: "unknown_scenario" };
	}
	if (!scenario.is_enabled) {
		return { ok: false, reason: "scenario_disabled" };
	}

	const { data: userProfile, error: userError } = await supabase
		.from("user_profiles")
		.select("timezone")
		.eq("id", params.userId)
		.single();
	if (userError || !userProfile) {
		console.error(`[notifications/send] user ${params.userId} not found:`, userError?.message);
		return { ok: false, reason: "user_not_found" };
	}

	// A malformed stored timezone must fail cleanly here, not throw later.
	// `getHourInTimeZone` (unlike `nextClockTimeInTimeZone`) does not call
	// `assertValidTimeZone` itself, so without this check an invalid stored
	// value would reach `Intl.DateTimeFormat` inside the quiet-hours check
	// below and throw an uncaught RangeError out of this function instead of
	// returning a typed failure (orchestrator review round 2, finding #4 —
	// broader than the tags-side issue Codex flagged; verified by reading
	// getHourInTimeZone before acting on it).
	try {
		assertValidTimeZone(userProfile.timezone);
	} catch {
		console.error(`[notifications/send] stored timezone is invalid for user ${params.userId}: ${userProfile.timezone}`);
		return { ok: false, reason: "invalid_timezone" };
	}

	const deliveryContext = parseNotificationDeliveryContext(params.deliveryContext);
	const hasMalformedDeliveryContext = params.deliveryContext !== undefined && params.deliveryContext !== null && deliveryContext === null;
	if (hasMalformedDeliveryContext || !isWiredNotificationScenario(params.scenarioId) || !isNotificationDeliveryContextForScenario(params.scenarioId, params.matchId, params.meetupId, deliveryContext)) {
		return { ok: false, reason: "delivery_precondition_failed" };
	}

	// Early pair check is a cheap cost-avoidance gate: reject already-invalid
	// match notifications before dedup/block/insert work. `deliverNow` repeats
	// the authoritative check immediately before OneSignal, closing the
	// revocation/revoke-between-queries window for both immediate and deferred
	// delivery paths.
	const ageCheck = await checkNotificationAgeVerified(supabase, params.matchId, params.userId);
	if (ageCheck.state === "error") return { ok: false, reason: "age_verification_failed" };
	if (ageCheck.state === "unverified") return { ok: false, reason: "age_unverified" };

	// --- Pre-send check 2/3: 24h dedup. This query is the fast path and the
	// source of the "duplicate" outcome in the ordinary case; the authoritative
	// check is the `notifications_dedup_window_excl` exclusion constraint added
	// in migration 20260820100000, which the INSERT below hits when two callers
	// race past this query. Must suppress in both the non-NULL and the NULL
	// match_id case. See step-04-notifications.md §3-1.
	//
	// The constraint is what makes this correct rather than merely usual: two
	// concurrent calls for the same scenario_id/user_id/match_id can both pass
	// this SELECT before either has inserted. The older
	// UNIQUE(scenario_id, user_id, match_id, dedup_window_start) could not
	// close that — `dedup_window_start` is `now` per call, so two racers get
	// two different values and never conflict, and NULL match_id rows never
	// conflict at all. (This is a different race from review round 3's finding
	// #4, which is about two invocations of the DEFERRED EXECUTOR processing
	// the SAME already-created row — that one is closed below via
	// claimDueNotification, with fencing hardened in round 4's finding #3.)
	const dedupCutoff = new Date(now.getTime() - DEDUP_WINDOW_MS).toISOString();
	let dedupQuery = supabase
		.from("notifications")
		.select("id")
		.eq("scenario_id", params.scenarioId)
		.eq("user_id", params.userId)
		.gte("dedup_window_start", dedupCutoff);
	dedupQuery = params.matchId ? dedupQuery.eq("match_id", params.matchId) : dedupQuery.is("match_id", null);
	const { data: existingDupes, error: dedupError } = await dedupQuery.limit(1);
	if (dedupError) {
		// Fail closed: if we can't confirm there's no duplicate, don't send —
		// the UNIQUE constraint is only a second line of defence for the
		// non-NULL match_id case, so a dedup-query failure must not fall
		// through to a send.
		console.error("[notifications/send] dedup pre-check query failed:", dedupError.message);
		return { ok: false, reason: "insert_failed" };
	}
	if (existingDupes && existingDupes.length > 0) {
		return { ok: false, reason: "duplicate" };
	}

	// --- Pre-send check 2b/3: neither party has blocked the other. Checked
	// here rather than only at the trigger sites so that no future scenario
	// can be wired without it, and checked AGAIN in the deferred executor
	// because a block can be created between creation and delivery.
	const blockState = await checkNotificationBlocked(supabase, params.matchId, params.userId, ageCheck.match);
	if (blockState === "error") return { ok: false, reason: "block_check_failed" };
	if (blockState === "blocked") return { ok: false, reason: "blocked" };

	// --- Pre-send check 1/3: quiet hours (22:00-08:00 user-local), unless the
	// scenario is quiet_hours_exempt (N-08, N-09).
	let scheduledFor: string | null = null;
	if (!scenario.quiet_hours_exempt) {
		const localHour = getHourInTimeZone(now, userProfile.timezone);
		if (localHour >= QUIET_HOURS_START || localHour < QUIET_HOURS_END) {
			scheduledFor = nextClockTimeInTimeZone(now, userProfile.timezone, QUIET_HOURS_END, 0).toISOString();
		}
	}
	const immediateFencingToken = new Date(now.getTime() + CLAIM_WINDOW_MS).toISOString();

	const { data: inserted, error: insertError } = await supabase
		.from("notifications")
		.insert({
			scenario_id: params.scenarioId,
			user_id: params.userId,
			match_id: params.matchId ?? null,
			meetup_id: params.meetupId ?? null,
			payload: {
				deep_link: params.deepLink,
				...(deliveryContext ? { delivery_context: deliveryContext } : {}),
			},
			// Keep every newly-created row discoverable by the deferred executor.
			// A Worker can be evicted after INSERT and before the immediate
			// OneSignal call.  NULL used to make that row invisible forever.  An
			// immediate row gets a short reservation token; a quiet-hours row keeps
			// its real delivery time.
			scheduled_for: scheduledFor ?? immediateFencingToken,
			dedup_window_start: now.toISOString(),
		})
		.select("id")
		.single();
	if (insertError || !inserted) {
		// 23P01 (exclusion_violation) means the dedup exclusion constraint
		// rejected this row: another caller won the race past the SELECT above
		// and already created a notification whose 24h window overlaps ours.
		// That is a duplicate, not a failure — report the same outcome the
		// pre-send query would have. 23505 is kept alongside it because the
		// older UNIQUE(scenario_id, user_id, match_id, dedup_window_start) is
		// still on the table and can fire first on an exact-timestamp tie.
		if (insertError?.code === "23P01" || insertError?.code === "23505") {
			return { ok: false, reason: "duplicate" };
		}
		console.error("[notifications/send] failed to insert notifications row:", insertError?.message);
		return { ok: false, reason: "insert_failed" };
	}

	if (scheduledFor) {
		return { ok: true, notificationId: inserted.id, outcome: "deferred", scheduledFor };
	}

	// `deliverNow` is the single final delivery boundary for the immediate path
	// too.  The INSERT above reserves this row until the claim window expires;
	// passing that reservation as the fencing token means a deferred executor
	// that eventually takes over cannot have its writes overwritten by this
	// invocation.
	const result = await deliverNow(supabase, env, {
		notificationId: inserted.id,
		scenarioId: params.scenarioId,
		userId: params.userId,
		matchId: params.matchId,
		meetupId: params.meetupId,
		deepLink: params.deepLink,
		deliveryContext,
		participantIds: ageCheck.match ? [ageCheck.match.user_a_id, ageCheck.match.user_b_id] : undefined,
		now,
		clock: params.clock,
		fencingToken: immediateFencingToken,
	});

	// `result.ok === false` (not `!result.ok`): see refreshNotificationTags's
	// doc comment on the same pattern — this repo's build config
	// (tsconfig.build.json, `strict: false`) does not reliably narrow a
	// negated boolean-discriminant check on a multi-member union, and this
	// block needs fields that only exist on specific false-branch variants.
	if (result.ok === false) {
		// deliverNow has already terminally suppressed this newly-created row
		// when the final pair check found an unverified counterpart. Do not turn
		// that terminal row into a due retry (or overwrite its suppression
		// reason) merely because the common sink returned a typed denial.
		if (result.reason === "age_unverified" || result.reason === "delivery_precondition_failed" || result.reason === "lost_ownership") return result;

		// An immediate row already has a recovery reservation from the INSERT,
		// so it is discoverable after that short reservation expires even if the
		// Worker is evicted before this fallback runs.  This write moves the row
		// due immediately after a known failure and stores the provider outcome
		// marker when OneSignal already accepted the request.  The fencing filter
		// prevents this late fallback from overwriting a deferred claimant.
		//
		// If OneSignal already answered (accepted the push, or reported no
		// subscription) but the write recording that locally failed, stash
		// the right pending-outcome marker in payload in this SAME write —
		// see extractPendingOutcome / repairPendingOutcome's doc comments for
		// why this is what lets a later run repair the row WITHOUT calling
		// OneSignal again (round 3 finding #2's explicit requirement).
		// Orchestrator review round 4, finding #1: this is deliberately
		// `repair_attempts`, NOT `deferred_attempts`, for the pending-outcome
		// cases — see the constant's doc comment for why the two budgets
		// must never share a counter or a terminal state.
		const markDueAt = new Date().toISOString();
		let duePayload: Record<string, Json>;
		if (result.reason === "send_accepted_but_unrecorded") {
			duePayload = {
				deep_link: params.deepLink,
				...(deliveryContext ? { delivery_context: deliveryContext } : {}),
				repair_attempts: 1,
				pending_onesignal_id: result.oneSignalId,
			};
		} else if (result.reason === "suppression_unrecorded") {
			duePayload = {
				deep_link: params.deepLink,
				...(deliveryContext ? { delivery_context: deliveryContext } : {}),
				repair_attempts: 1,
				pending_suppression_id: result.oneSignalId,
			};
		} else {
			duePayload = {
				deep_link: params.deepLink,
				...(deliveryContext ? { delivery_context: deliveryContext } : {}),
				deferred_attempts: 1,
			};
		}
		const { data: markedDueRows, error: markDueError } = await supabase
			.from("notifications")
			.update({ scheduled_for: markDueAt, payload: duePayload })
			.eq("id", inserted.id)
			.eq("scheduled_for", immediateFencingToken)
			.select("id");
		if (markDueError) {
			// The INSERT reservation keeps the row discoverable even when this
			// immediate fallback cannot persist.  Keep the row id in the log so
			// operators can correlate the later idempotent repair attempt.
			console.error(
				`[notifications/send] failed to mark failed immediate send ${inserted.id} due for retry (deliverNow already failed with reason=${result.reason}; reservation remains):`,
				markDueError.message,
			);
		} else if ((markedDueRows ?? []).length === 0) {
			console.error(
				`[notifications/send] immediate retry marker for ${inserted.id} matched zero rows (lost ownership)`,
			);
		}
	}

	return result;
}

interface DeliverNowParams {
	notificationId: string;
	scenarioId: string;
	userId: string;
	matchId?: string | null;
	meetupId?: string | null;
	deepLink: string;
	deliveryContext?: NotificationDeliveryContext | null;
	participantIds?: readonly [string, string];
	now?: Date;
	clock?: () => Date;
	/**
	 * The row reservation/claim token.  Immediate rows receive one in the
	 * INSERT so a crash between INSERT and the provider call remains
	 * discoverable; deferred rows replace their due value with a claim token.
	 * When present,
	 * every write this function makes is guarded on it, so a caller whose
	 * claim has since expired and been taken over by someone else silently
	 * loses these writes instead of corrupting the new claimant's work
	 * (orchestrator review round 4, finding #3).
	 */
	fencingToken?: string;
}

type DeliverySuppressionResult = "suppressed" | "lost_ownership" | "error";

/** Terminally suppress only the exact still-unsent row this caller owns. */
async function suppressDeliveryPrecondition(
	supabase: SupabaseClient<Database>,
	params: DeliverNowParams,
): Promise<DeliverySuppressionResult> {
	let query = supabase
		.from("notifications")
		.update({ suppressed_reason: "delivery_precondition_failed" })
		.eq("id", params.notificationId)
		.eq("scenario_id", params.scenarioId)
		.eq("user_id", params.userId)
		.eq("payload->>deep_link", params.deepLink)
		.is("sent_at", null)
		.is("suppressed_reason", null)
		.is("onesignal_notification_id", null);
	query = params.matchId ? query.eq("match_id", params.matchId) : query.is("match_id", null);
	query = params.meetupId ? query.eq("meetup_id", params.meetupId) : query.is("meetup_id", null);
	query = params.fencingToken !== undefined ? query.eq("scheduled_for", params.fencingToken) : query.is("scheduled_for", null);
	try {
		const { data, error } = await query.select("id");
		if (error) return "error";
		return (data ?? []).length > 0 ? "suppressed" : "lost_ownership";
	} catch {
		return "error";
	}
}

/**
 * The actual OneSignal call + result bookkeeping, shared by the immediate
 * send path above and the deferred-send executor below so there is exactly
 * one place that talks to OneSignal and interprets its response
 * (step-04-notifications.md §5's "enumerate every sink" lesson starts by
 * there being only one sink to enumerate).
 */
async function deliverNow(
	supabase: SupabaseClient<Database>,
	env: NotificationsEnv,
	params: DeliverNowParams,
): Promise<SendNotificationResult> {
	const copy = getNotificationCopy(params.scenarioId);

	// env.ONESIGNAL_APP_ID / ONESIGNAL_API_KEY are checked by both callers
	// (sendNotification above, sendDeferredNotifications below) before a
	// notifications row that could reach this function is ever created or
	// selected, so a non-null assertion here would be safe — but this
	// function re-checks anyway rather than trusting the caller silently.
	if (!env.ONESIGNAL_APP_ID || !env.ONESIGNAL_API_KEY) {
		console.error("[notifications/deliver] OneSignal not configured");
		return { ok: false, notificationId: params.notificationId, reason: "send_failed" };
	}

	// Read participant identity before the final embedded snapshot. The helper
	// checks these ids again in its single final request, so a change between
	// the reads cannot redirect a notification to a different pair.
	let participantIds = params.participantIds;
	if (params.matchId && !participantIds) {
		const identity = await readNotificationMatchParticipants(supabase, params.matchId, params.userId);
		if (identity.ok === false) {
			return identity.reason === "error"
				? { ok: false, notificationId: params.notificationId, reason: "delivery_check_failed" }
				: { ok: false, notificationId: params.notificationId, reason: "lost_ownership" };
		}
		participantIds = identity.participantIds;
	}

	const access = await checkNotificationDeliveryAccess(supabase, {
		notificationId: params.notificationId,
		scenarioId: params.scenarioId,
		userId: params.userId,
		matchId: params.matchId,
		meetupId: params.meetupId,
		deepLink: params.deepLink,
		deliveryContext: params.deliveryContext,
		participantIds,
		fencingToken: params.fencingToken,
		now: params.now ?? new Date(),
		clock: params.clock ?? (() => new Date()),
	});
	if (access.ok === false) {
		if (access.reason === "error") return { ok: false, notificationId: params.notificationId, reason: "delivery_check_failed" };
		const suppression = await suppressDeliveryPrecondition(supabase, params);
		if (suppression === "lost_ownership") return { ok: false, notificationId: params.notificationId, reason: "lost_ownership" };
		if (suppression === "error") return { ok: false, notificationId: params.notificationId, reason: "delivery_check_failed" };
		return { ok: false, notificationId: params.notificationId, reason: "delivery_precondition_failed" };
	}

	if (hasRecordingRehearsalConfig(env)) {
		return { ok: false, notificationId: params.notificationId, reason: "delivery_precondition_failed" };
	}
	const result = await sendOneSignalNotification({
		appId: env.ONESIGNAL_APP_ID,
		apiKey: env.ONESIGNAL_API_KEY,
		externalUserId: params.userId,
		heading: copy.heading,
		content: copy.content,
		data: {
			scenario_id: params.scenarioId,
			notification_id: params.notificationId,
			deep_link: params.deepLink,
		},
	});

	if (!result.ok) {
		// The OneSignal error body never reaches this function's caller — it
		// was already logged (and only logged) inside sendOneSignalNotification.
		return { ok: false, notificationId: params.notificationId, reason: "send_failed" };
	}

	if (result.recipients === 0) {
		// Pre-send check 3/3: lost permission is not a send failure — record
		// the reason and hand off to the in-app badge path (4-B).
		let suppressQuery = supabase
			.from("notifications")
			.update({ suppressed_reason: "no_subscription", onesignal_notification_id: result.oneSignalId })
			.eq("id", params.notificationId)
			.eq("scenario_id", params.scenarioId)
			.eq("user_id", params.userId)
			.is("sent_at", null)
			.is("suppressed_reason", null)
			.is("onesignal_notification_id", null);
		if (params.fencingToken !== undefined) suppressQuery = suppressQuery.eq("scheduled_for", params.fencingToken);
		else suppressQuery = suppressQuery.is("scheduled_for", null);
		const { data: suppressRows, error: suppressError } = await suppressQuery.select("id");
		if (suppressError) {
			// Orchestrator review round 4, finding #2: this write failing
			// must not be reported as success — OneSignal already answered
			// (no subscription), but nothing local records that, so the row
			// must land in the SAME repair queue as an accepted-but-
			// unrecorded send and remain discoverable by its scheduled_for
			// reservation.
			console.error(`[notifications/deliver] failed to record no_subscription suppression for ${params.notificationId}:`, suppressError.message);
			return { ok: false, notificationId: params.notificationId, reason: "suppression_unrecorded", oneSignalId: result.oneSignalId };
		}
		if (params.fencingToken !== undefined && (suppressRows ?? []).length === 0) {
			// Fenced out: another invocation now owns this row. Not a
			// failure of any kind — just not ours to report on anymore.
			return { ok: false, notificationId: params.notificationId, reason: "lost_ownership" };
		}
		return { ok: true, notificationId: params.notificationId, outcome: "suppressed_no_subscription" };
	}

	// Orchestrator review round 2, finding #1: OneSignal has now ACCEPTED
	// this push (a real send, possibly already delivered). Persist
	// `onesignal_notification_id` in its own write, separately from
	// `sent_at`/the event insert, so that if the write below fails, the
	// external send is still recorded locally.
	let idQuery = supabase.from("notifications").update({ onesignal_notification_id: result.oneSignalId }).eq("id", params.notificationId);
	if (params.fencingToken !== undefined) idQuery = idQuery.eq("scheduled_for", params.fencingToken);
	const { data: idRows, error: idUpdateError } = await idQuery.select("id");
	if (idUpdateError) {
		// Return the accepted id to the caller so it can be stashed somewhere a
		// later run will find WITHOUT needing this exact write to have succeeded.
		// If that caller-side fallback also fails, the row still carries the
		// INSERT reservation (or the deferred claim value).  Once it is due,
		// the executor retries with this notification id as OneSignal's
		// idempotency key, then repairs local bookkeeping from the response.  The
		// two failures remain explicit server-side log evidence with the row id.
		console.error(`[notifications/deliver] failed to record onesignal_notification_id for ${params.notificationId}:`, idUpdateError.message);
		return { ok: false, notificationId: params.notificationId, reason: "send_accepted_but_unrecorded", oneSignalId: result.oneSignalId };
	}
	if (params.fencingToken !== undefined && (idRows ?? []).length === 0) {
		return { ok: false, notificationId: params.notificationId, reason: "lost_ownership" };
	}

	return finalizeAlreadySentNotification(supabase, {
		notificationId: params.notificationId,
		userId: params.userId,
		fencingToken: params.fencingToken,
	});
}

/**
 * A push OneSignal already answered about (accepted for delivery, or
 * reported no subscription) but whose local bookkeeping never fully
 * landed. Distinguishes WHICH answer it was, since the repair differs:
 * a `sent`-kind row needs {@link finalizeAlreadySentNotification}; a
 * `suppressed`-kind row just needs `suppressed_reason` persisted.
 */
type PendingOutcome = { kind: "sent"; oneSignalId: string } | { kind: "suppressed"; oneSignalId: string };

/**
 * Extracts a pending-outcome marker from `payload` — `pending_onesignal_id`
 * (round 3 finding #2: the accepted-send id-column write failed) or
 * `pending_suppression_id` (round 4 finding #2: the suppression write
 * failed). Both are fallback facts a later run uses to know "OneSignal
 * already answered" without needing that exact write to have landed.
 * Presence (`in`), not truthiness, is checked for the suppression case:
 * OneSignal's documented "no valid subscriptions" response can carry an
 * empty-string id (see lib/onesignal.ts), which is a legitimate value here,
 * not an absent one.
 */
function extractPendingOutcome(payload: unknown): PendingOutcome | null {
	if (!payload || typeof payload !== "object") return null;
	const p = payload as Record<string, unknown>;
	if (typeof p.pending_onesignal_id === "string" && p.pending_onesignal_id.length > 0) {
		return { kind: "sent", oneSignalId: p.pending_onesignal_id };
	}
	if ("pending_suppression_id" in p && typeof p.pending_suppression_id === "string") {
		return { kind: "suppressed", oneSignalId: p.pending_suppression_id };
	}
	return null;
}

/**
 * Finishes a notification OneSignal already answered about but whose
 * column write never landed — i.e. the row only carries a payload
 * fallback marker (see {@link extractPendingOutcome}), not
 * `onesignal_notification_id` / `suppressed_reason` itself. Retries
 * persisting the column (the write that failed before) and, only if that
 * succeeds, proceeds to record the final outcome — but NEVER calls
 * OneSignal again, satisfying round 3 finding #2's explicit requirement.
 * If `alreadyPersistedInColumn` is true (the ordinary repair case —
 * `onesignal_notification_id` is already set), this skips straight to
 * finalizing.
 */
async function repairPendingOutcome(
	supabase: SupabaseClient<Database>,
	params: { notificationId: string; userId: string; pending: PendingOutcome; alreadyPersistedInColumn: boolean; fencingToken: string },
): Promise<SendNotificationResult> {
	if (params.pending.kind === "suppressed") {
		let query = supabase
			.from("notifications")
			.update({ suppressed_reason: "no_subscription", onesignal_notification_id: params.pending.oneSignalId })
			.eq("id", params.notificationId)
			.eq("scheduled_for", params.fencingToken);
		const { data, error } = await query.select("id");
		if (error) {
			console.error(`[notifications/deliver] retry to record no_subscription suppression for ${params.notificationId} failed again:`, error.message);
			return { ok: false, notificationId: params.notificationId, reason: "suppression_unrecorded", oneSignalId: params.pending.oneSignalId };
		}
		if ((data ?? []).length === 0) {
			return { ok: false, notificationId: params.notificationId, reason: "lost_ownership" };
		}
		return { ok: true, notificationId: params.notificationId, outcome: "suppressed_no_subscription" };
	}

	// kind === "sent"
	if (!params.alreadyPersistedInColumn) {
		const { data, error } = await supabase
			.from("notifications")
			.update({ onesignal_notification_id: params.pending.oneSignalId })
			.eq("id", params.notificationId)
			.eq("scheduled_for", params.fencingToken)
			.select("id");
		if (error) {
			console.error(`[notifications/deliver] retry to record onesignal_notification_id for ${params.notificationId} failed again:`, error.message);
			// payload.pending_onesignal_id is untouched (still there from
			// before) — a future run tries this same repair again.
			return { ok: false, notificationId: params.notificationId, reason: "send_accepted_but_unrecorded", oneSignalId: params.pending.oneSignalId };
		}
		if ((data ?? []).length === 0) {
			return { ok: false, notificationId: params.notificationId, reason: "lost_ownership" };
		}
	}

	return finalizeAlreadySentNotification(supabase, {
		notificationId: params.notificationId,
		userId: params.userId,
		fencingToken: params.fencingToken,
	});
}

/**
 * Finishes local bookkeeping (`sent_at` + the `sent` event) for a
 * notification OneSignal has already accepted — i.e. `onesignal_notification_id`
 * is already persisted, from either the write just above in {@link deliverNow}
 * or a prior invocation. Never calls OneSignal. This is both the tail end
 * of a normal successful send and the "repair" path
 * {@link sendDeferredNotifications} uses for a row it finds already has
 * `onesignal_notification_id` set (orchestrator review round 2, finding #1).
 *
 * ROW LIFECYCLE / FENCING MODEL (rewritten in orchestrator review round 5,
 * after rounds 3 and 4 each shipped a fencing fix whose own gap became the
 * next round's finding — this is the coherent version, not another patch):
 *
 * `scheduled_for`, once a row is claimed by {@link claimDueNotification},
 * IS that claim's fencing token for this ENTIRE attempt — set once, and
 * never rewritten again until the attempt reaches a terminal write
 * (`sent_at`, `suppressed_reason`) or a backoff write starts the NEXT
 * attempt. There is no mid-flight "renew": round 4 introduced one to
 * extend the claim, but a renew changes `scheduled_for` to a NEW value
 * that every OTHER write in the same attempt then has to know about, and
 * two different pieces of code (this function's writes, and the
 * executor's failure-handling backoff) each independently held a STALE
 * copy of the token — that mismatch was round 5's finding #2. Removing
 * the renew removes the mismatch by construction: every fenced write in
 * an attempt checks against the exact same value, so there is nothing to
 * thread or go stale. `CLAIM_WINDOW_MS` (2 minutes) is sized generously
 * against this row's actual per-attempt work (a handful of writes and one
 * HTTP call, no LLM/long-running steps), so a genuinely-alive invocation
 * exceeding it — rather than being killed by the Worker's own execution
 * limits first — is not expected in practice; if it happens anyway, this
 * function's fencing (below) still resolves it correctly.
 *
 * Orchestrator review round 3, finding #3 / round 4, finding #3 / round 5,
 * finding #1: a delivery must never end up with `sent_at` set and no
 * `sent` event, and two concurrent claimants must never both be able to
 * insert one. Round 3's fix (check-then-insert) and round 4's fix
 * (fence only at function entry) both left a real gap: a claimant that
 * stalls between "confirm no event exists" and "insert one" — the exact
 * window neither of those closes — can still race a second claimant that
 * reclaimed the row in between, producing two `sent` events for the same
 * notification. No application-level check-then-write sequence against
 * `notification_events` can fully close that without either a DB
 * transaction/stored procedure (needs a migration) or a real uniqueness
 * constraint on the write itself.
 *
 * Round 5's fix uses one that already exists, no migration required:
 * `notification_events.id` is already `PRIMARY KEY`, which Postgres
 * enforces uniqueness on unconditionally. Instead of letting the DEFAULT
 * generate a random id and separately checking for a duplicate, this
 * function INSERTs the `sent` event with `id` set explicitly to
 * `notificationId` itself — deterministic per notification. Two concurrent
 * inserts for the same row now collide on the primary key at the database
 * level: the first commits, the second gets back a real `23505
 * unique_violation` from Postgres — closing the gap round 3 and round 4
 * could each only narrow, no pre-check needed on the common path.
 *
 * Orchestrator review round 6 (Codex): a `23505` alone is NOT proof the
 * conflicting row is THIS notification's own `sent` event — confirmed by
 * reading `notification_events_insert` in
 * supabase/migrations/20260812100400_notifications.sql, which constrains
 * `user_id` and `notification_id` but not `id`. This route
 * (routes/notification-events.ts) uses the service_role client, so RLS
 * isn't the enforcement path today, but its own doc comment states RLS
 * exists as "the second line of defence for a client that talks to
 * Supabase directly instead of through this API" — a live, designed-for
 * path, not a hypothetical one, even before such a client ships. Under
 * that policy, the notification's OWNER can insert e.g. an `opened` event
 * with `id` set to that notification's own id, occupying this exact
 * primary key before we ever write it — deliberately, to make their own
 * `sent` funnel event un-recordable. Round 5's fix would have read that
 * collision as "already recorded" and moved on, permanently undercounting
 * a push that really was delivered.
 *
 * {@link recordSentEvent} below fixes this: a `23505` collision is
 * followed by a check keyed on the notification_events IDENTITY that
 * actually matters (`notification_id` + `event_type = 'sent'`), never on
 * the `id` that happened to collide. If a genuine `sent` event already
 * exists under that identity (found by whoever actually recorded it,
 * with whatever id), that's the real "already recorded" case. If not, the
 * colliding row is foreign — the function falls back to a DB-generated
 * (non-deterministic) id for this one insert, which a client cannot have
 * pre-occupied because it doesn't exist until this statement runs. Both
 * extra steps (the identity check, the fallback insert) execute ONLY on
 * the collision path — the common case is still the single deterministic
 * insert. (This id scheme applies only to the `sent` event type, written
 * only from this one call site; `delivered` / `opened` / etc., reported
 * by the client via routes/notification-events.ts, are unaffected and
 * keep DB-generated random ids.)
 *
 * The final `sent_at` write is still a fenced conditional UPDATE
 * (`WHERE ... AND scheduled_for = fencingToken`, `.select("id")` to check
 * the affected-row count rather than assuming a non-error means a row
 * changed — round 5 finding #2's audit) — this is what determines whether
 * THIS invocation gets to claim "I finished this row," independent of
 * which invocation's insert actually landed the (now unique, so never
 * duplicated) event. `fencingToken` is omitted (skipping the fenced
 * write's WHERE clause) only for the immediate path (see
 * `sendNotification`'s call site comment for why no concurrent claimant
 * is possible there).
 */
async function finalizeAlreadySentNotification(
	supabase: SupabaseClient<Database>,
	params: { notificationId: string; userId: string; fencingToken?: string },
): Promise<SendNotificationResult> {
	const sentAt = new Date().toISOString();

	const eventRecorded = await recordSentEvent(supabase, params.notificationId, params.userId, sentAt);
	if (!eventRecorded) {
		return { ok: false, notificationId: params.notificationId, reason: "send_failed" };
	}

	let sentAtQuery = supabase.from("notifications").update({ sent_at: sentAt }).eq("id", params.notificationId);
	if (params.fencingToken !== undefined) sentAtQuery = sentAtQuery.eq("scheduled_for", params.fencingToken);
	const { data: sentAtRows, error: updateError } = await sentAtQuery.select("id");
	if (updateError) {
		console.error(`[notifications/deliver] failed to record sent_at for ${params.notificationId}:`, updateError.message);
		return { ok: false, notificationId: params.notificationId, reason: "send_failed" };
	}
	if (params.fencingToken !== undefined && (sentAtRows ?? []).length === 0) {
		// The event (real, and now provably not duplicated) stays — a
		// later, legitimate claimant's own attempt to record it will
		// correctly find it already exists (by identity, not by id) and
		// just proceed to set sent_at itself.
		return { ok: false, notificationId: params.notificationId, reason: "lost_ownership" };
	}

	return { ok: true, notificationId: params.notificationId, outcome: "sent" };
}

/**
 * Records this notification's `sent` event exactly once. See
 * {@link finalizeAlreadySentNotification}'s doc comment for the full
 * reasoning (orchestrator review round 6): the common case is a single
 * insert using a deterministic id (collision-proof against a SECOND
 * attempt at this SAME notification's sent event); the collision path —
 * reached only when that insert's primary key is already taken — verifies
 * by IDENTITY (`notification_id` + `event_type = 'sent'`), not by which
 * row happened to hold that id, before accepting the collision as
 * "already recorded". A forged/foreign row occupying the id falls back to
 * a DB-generated id instead, which nothing could have pre-occupied.
 * Returns `false` only on a real, unrecovered failure.
 *
 * Two things that used to be this function's job now belong to the database,
 * as of migration 20260820100000:
 *
 * 1. The identity check below trusted ANY row with `notification_id` +
 *    `event_type='sent'`, and `notification_events_insert` constrained
 *    ownership but not `event_type` — so a client on the direct-Supabase
 *    path could read its own `notifications` row (`notifications_select`
 *    allows the owner), learn the `notification_id`, and insert its OWN
 *    fabricated `sent` row ahead of the real one. The policy's WITH CHECK
 *    now rejects a client-supplied `sent` outright; service_role, the only
 *    genuine writer, bypasses RLS and is unaffected.
 * 2. The fallback insert below could be reached by two claimants at once,
 *    leaving two `sent` rows — not closable here, since a fixed id is
 *    forgeable and a generated id is not unique. A partial unique index on
 *    (`notification_id`) WHERE `event_type = 'sent'` now guarantees it.
 *
 * The application-level machinery is kept as the first line: it turns the
 * ordinary retry into a no-op without provoking a constraint violation.
 */
async function recordSentEvent(
	supabase: SupabaseClient<Database>,
	notificationId: string,
	userId: string,
	occurredAt: string,
): Promise<boolean> {
	const { error: insertError } = await supabase.from("notification_events").insert({
		id: notificationId,
		notification_id: notificationId,
		user_id: userId,
		event_type: "sent",
		occurred_at: occurredAt,
	});
	if (!insertError) return true;

	const isPrimaryKeyCollision = insertError.code === "23505" || /duplicate key/i.test(insertError.message ?? "");
	if (!isPrimaryKeyCollision) {
		console.error(`[notifications/deliver] failed to record sent event for ${notificationId}:`, insertError.message);
		return false;
	}

	// Collision path (rare — see the doc comment above). Check by identity,
	// not by id: this also makes the fallback insert below idempotent
	// across retries of this same function (a prior attempt's fallback
	// event, once recorded, is found here and we stop without inserting
	// again).
	const { data: existing, error: existingError } = await supabase
		.from("notification_events")
		.select("id")
		.eq("notification_id", notificationId)
		.eq("event_type", "sent")
		.limit(1);
	if (existingError) {
		console.error(`[notifications/deliver] failed to verify sent-event identity for ${notificationId} after a key collision:`, existingError.message);
		return false;
	}
	if (existing && existing.length > 0) {
		return true; // genuinely already recorded — by us, earlier, under whatever id
	}

	// The id is occupied by a row that is NOT this notification's own sent
	// event — most plausibly a foreign row a client inserted directly
	// (RLS's notification_events_insert policy doesn't constrain `id`; see
	// the doc comment above). Fall back to a non-deterministic id, safe
	// specifically because we just confirmed no genuine sent event exists
	// yet under this notification's identity.
	console.error(
		`[notifications/deliver] notification_events id ${notificationId} is occupied by a row that is not this notification's own sent event — falling back to a generated id`,
	);
	const { error: fallbackError } = await supabase.from("notification_events").insert({
		notification_id: notificationId,
		user_id: userId,
		event_type: "sent",
		occurred_at: occurredAt,
	});
	if (fallbackError) {
		// The partial unique index added in migration 20260820100000 fires here
		// when a concurrent claimant recorded the genuine sent event between
		// this function's identity check and this insert. That is precisely the
		// outcome we wanted — one sent row exists — so it is a success, not a
		// failure. Without this the index would convert a race the index itself
		// resolved correctly into a spurious "send_failed".
		if (fallbackError.code === "23505") {
			return true;
		}
		console.error(`[notifications/deliver] fallback sent-event insert failed for ${notificationId}:`, fallbackError.message);
		return false;
	}
	return true;
}

/**
 * Sets OneSignal segmentation tags (billing status / meetup experience /
 * timezone, step-04-notifications.md §3-1) for one user.
 *
 * Deliberately NOT called from {@link deliverNow} (orchestrator review
 * P1-a): tag values change rarely (a subscription state, a first
 * completed meetup, a timezone edit), so paying computeNotificationTags's
 * 3-4 subrequests plus 1 OneSignal PATCH on every single send burned most
 * of the deferred-send subrequest budget for no benefit most of the time.
 * Exposed as its own function so a caller that actually knows a tag
 * changed (e.g. a future entitlements-webhook handler, or a meetup
 * completing) can refresh just that one user's tags — wiring an actual
 * trigger point is follow-up work, matching the state `sendNotification`
 * itself is in today (built, not yet wired to a per-scenario trigger).
 */
export async function refreshNotificationTags(
	supabase: SupabaseClient<Database>,
	env: NotificationsEnv,
	userId: string,
): Promise<{ ok: boolean }> {
	if (!env.ONESIGNAL_APP_ID || !env.ONESIGNAL_API_KEY) {
		console.error("[notifications/tags] OneSignal not configured");
		return { ok: false };
	}
	try {
		const tagsResult = await computeNotificationTags(supabase, userId);
		// `tagsResult.ok === false` (not `!tagsResult.ok`): this repo's build
		// config (tsconfig.build.json) runs with `strict: false`, under which
		// TypeScript does not narrow a negated boolean-discriminant check on a
		// 3-member union reliably — confirmed by a minimal repro during this
		// fix. The explicit `=== false` form narrows correctly under both
		// configs.
		if (tagsResult.ok === false) {
			// Propagate the failure instead of guessing tag values — see
			// computeNotificationTags's own doc comment (orchestrator review
			// round 2, finding #4).
			console.error(`[notifications/tags] cannot compute tags: ${tagsResult.reason}`);
			return { ok: false };
		}
		if (hasRecordingRehearsalConfig(env)) return { ok: false };
		const result = await setOneSignalTags({
			appId: env.ONESIGNAL_APP_ID,
			apiKey: env.ONESIGNAL_API_KEY,
			externalUserId: userId,
			tags: tagsResult.tags as unknown as Record<string, string>,
		});
		if (!result.ok) {
			console.error(`[notifications/tags] tag update failed for user ${userId}`);
		}
		return result;
	} catch (e) {
		console.error("[notifications/tags] tag refresh threw:", e instanceof Error ? e.message : e);
		return { ok: false };
	}
}

export interface DeferredSendResult {
	processed: number;
	sent: number;
	suppressed: number;
	failed: number;
}

/**
 * Bounded retry policy for a deferred row that fails an UNSENT delivery
 * (OneSignal was never successfully contacted, or actively rejected the
 * request — `reason: "send_failed"`). Without this, a row that fails stays
 * at `scheduled_for` in the past forever — the due-query orders by
 * `scheduled_for` ascending, so that row is re-selected FIRST on every
 * future invocation, permanently occupying one of the very few slots
 * `DEFAULT_DEFERRED_SEND_LIMIT` allows and starving every legitimately-due
 * notification behind it.
 *
 * No migration is available, so retry state lives in the existing `payload`
 * jsonb column (`deferred_attempts`) and backoff reuses the existing
 * `scheduled_for` column: on a transient failure, `scheduled_for` is pushed
 * forward by an increasing delay. After `MAX_DEFERRED_SEND_ATTEMPTS`
 * failures the row is marked terminal via `suppressed_reason` (a free-text
 * column already used for the no-subscription terminal state) so it is
 * excluded by the due-query's `.is("suppressed_reason", null)` filter and
 * never retried again.
 *
 * Orchestrator review round 4, finding #1: this policy — and specifically
 * its terminal state — applies ONLY to genuine unsent-delivery failures.
 * A failure to REPAIR a row OneSignal already answered about
 * (`send_accepted_but_unrecorded` / `suppression_unrecorded` /
 * `lost_ownership`) must never share this counter or ever reach
 * `deferred_send_exhausted`: that would falsely record a push the user
 * actually received as one that was not delivered — exactly the kind of
 * corruption of the funnel this whole review chain has been about. Repair
 * failures use the separate, non-exhausting policy in
 * {@link REPAIR_BACKOFF_MINUTES} below instead.
 */
export const MAX_DEFERRED_SEND_ATTEMPTS = 5;
const DEFERRED_BACKOFF_MINUTES = [5, 15, 45, 120, 360];

/**
 * Backoff for a REPAIR failure (orchestrator review round 4, finding #1) —
 * OneSignal already answered (accepted the push, or reported no
 * subscription) but some piece of local bookkeeping keeps failing to
 * record that. Uses the same escalating delays as the unsent-delivery
 * policy for the same reason (spread retries out, don't hammer a possibly-
 * struggling DB), but the schedule never terminates: once `repair_attempts`
 * exceeds this array's length, retries continue indefinitely at the
 * longest interval (6h) rather than ever giving up and marking the row
 * `suppressed_reason` — a push that was actually delivered (or genuinely
 * had no subscriber) must never be recorded as neither.
 */
const REPAIR_BACKOFF_MINUTES = [5, 15, 45, 120, 360];

/**
 * How long a claim on a due row (see {@link claimDueNotification}) is
 * valid before it's treated as abandoned. Deliberately generous relative
 * to how long one row's processing normally takes (a handful of
 * subrequests, no LLM/long-running steps) — a genuinely-alive invocation
 * outlasting this is not expected in practice. If the claiming invocation
 * genuinely never finishes (a crash, a Worker eviction) OR is merely slow
 * enough to cross this window while still alive, the row becomes claimable
 * again by a second invocation once it elapses — self-healing is the
 * point. There is no mid-flight renewal of this window (round 4 added
 * one; round 5 removed it — see {@link finalizeAlreadySentNotification}'s
 * doc comment for why a renewed, drifting token was itself the source of
 * round 5's two findings). `scheduled_for` therefore holds exactly ONE
 * fencing value for a row's entire attempt, from claim to that attempt's
 * terminal or backoff write, and every write in between that touches
 * shared state is individually fenced against that same value.
 */
const CLAIM_WINDOW_MS = 2 * 60_000;

export interface ClaimResult {
	claimed: boolean;
	/** Present iff `claimed` — the value now on `scheduled_for`, which every
	 * subsequent write for this row in this invocation must verify against. */
	fencingToken?: string;
}

/**
 * Atomically claims one due row so two overlapping
 * {@link sendDeferredNotifications} invocations can't both act on it
 * (orchestrator review round 3, finding #4).
 *
 * Reuses `scheduled_for` as the claim marker rather than adding a new
 * column: pushing it into a short future window is exactly the same "not
 * due until this instant" meaning the column already carries for the
 * quiet-hours hold and the backoff policies, so claiming is just
 * "temporarily due later, on purpose." The returned `fencingToken` IS that
 * new value — round 4 finding #3 reuses it (not a separately-invented
 * field) as the value every downstream write in this invocation's
 * processing of this row must keep verifying, because a claim expiring
 * mid-flight is exactly the case a fencing token exists to handle; see
 * {@link finalizeAlreadySentNotification}.
 *
 * The safety property comes from Postgres, not from application logic:
 * the UPDATE's WHERE clause (`id` + the exact `scheduled_for` value this
 * invocation read in its due-query) is evaluated against the row's
 * CURRENT committed state at UPDATE time. If another invocation already
 * claimed (or finished) the row, `scheduled_for` has already changed, the
 * WHERE clause matches zero rows, and this call returns `claimed: false`.
 */
async function claimDueNotification(supabase: SupabaseClient<Database>, row: { id: string; scheduled_for: string }): Promise<ClaimResult> {
	const claimUntil = new Date(Date.now() + CLAIM_WINDOW_MS).toISOString();
	const { data, error } = await supabase
		.from("notifications")
		.update({ scheduled_for: claimUntil })
		.eq("id", row.id)
		.eq("scheduled_for", row.scheduled_for)
		.select("id");
	if (error) {
		console.error(`[notifications/deferred] claim query failed for ${row.id}:`, error.message);
		return { claimed: false };
	}
	if ((data ?? []).length === 0) return { claimed: false };
	return { claimed: true, fencingToken: claimUntil };
}

/**
 * Sends held notifications whose `scheduled_for` has passed (the quiet-hours
 * hold from {@link sendNotification}). Callable directly from
 * `services/daily-batch.ts`'s `handleScheduled` — deliberately NOT mounted
 * on `/api/internal/*` (that route family is disabled whenever
 * `INTERNAL_API_TOKEN` is unset, and this function must not depend on that).
 *
 * `limit` caps how many rows one invocation processes (Workers Free: 50
 * subrequests/invocation — see {@link DEFAULT_DEFERRED_SEND_LIMIT}'s
 * comment for the arithmetic) — defaults to `env.DEFERRED_SEND_LIMIT` if
 * set, else {@link DEFAULT_DEFERRED_SEND_LIMIT}, and can always be
 * overridden by the caller without a code change.
 *
 * `processed` in the returned counts is the number of rows THIS invocation
 * actually claimed and acted on — a row it lost the claim race for, or the
 * fencing gate for, is not this invocation's to count (orchestrator review
 * round 3 finding #4, round 4 finding #3).
 */
export async function sendDeferredNotifications(
	supabase: SupabaseClient<Database>,
	env: NotificationsEnv,
	limit?: number,
): Promise<DeferredSendResult> {
	const effectiveLimit = limit ?? (env.DEFERRED_SEND_LIMIT ? Number(env.DEFERRED_SEND_LIMIT) : DEFAULT_DEFERRED_SEND_LIMIT);

	if (!env.ONESIGNAL_APP_ID || !env.ONESIGNAL_API_KEY) {
		console.error("[notifications/deferred] OneSignal not configured; skipping this invocation");
		return { processed: 0, sent: 0, suppressed: 0, failed: 0 };
	}

	const nowIso = new Date().toISOString();
	const { data: due, error: dueError } = await supabase
		.from("notifications")
		// match_id is selected for the block revalidation below, not for the send.
		.select("id, scenario_id, user_id, match_id, meetup_id, payload, onesignal_notification_id, scheduled_for")
		.is("sent_at", null)
		.is("suppressed_reason", null)
		.not("scheduled_for", "is", null)
		.lte("scheduled_for", nowIso)
		.order("scheduled_for", { ascending: true })
		.limit(effectiveLimit);

	if (dueError) {
		console.error("[notifications/deferred] failed to query due notifications:", dueError.message);
		return { processed: 0, sent: 0, suppressed: 0, failed: 0 };
	}

	let processed = 0;
	let sent = 0;
	let suppressed = 0;
	let failed = 0;

	for (const row of due ?? []) {
		// scheduled_for is guaranteed non-null here — the due-query above
		// filters `.not("scheduled_for", "is", null)`.
		const claim = await claimDueNotification(supabase, { id: row.id, scheduled_for: row.scheduled_for as string });
		if (!claim.claimed || claim.fencingToken === undefined) {
			// Lost the claim race to another overlapping invocation, or the
			// row was already finished between the due-query and now — not
			// this invocation's to process.
			continue;
		}
		const fencingToken = claim.fencingToken;
		processed++;

		const priorAttempts = readCounter(row.payload, "deferred_attempts");
		const priorRepairAttempts = readCounter(row.payload, "repair_attempts");
		let result: SendNotificationResult;

		// Either the column or a payload fallback marker means OneSignal
		// already answered on a prior attempt (round 2 finding #1 / round 3
		// finding #2 / round 4 finding #2) — repair local bookkeeping
		// instead of sending it again.
		const pendingOutcome: PendingOutcome | null = row.onesignal_notification_id
			? { kind: "sent", oneSignalId: row.onesignal_notification_id }
			: extractPendingOutcome(row.payload);
		const attemptedRepair = pendingOutcome !== null;

		// Revalidate the relationship at DELIVERY, not just at creation
		// (Codex P0, review round 3): a quiet-hours hold can sit here for up
		// to ten hours, and the recipient may have blocked the other person in
		// that window. Sending anyway would be a post-block contact channel.
		//
		// Deliberately AFTER pendingOutcome, and skipped when one exists
		// (Codex P1, review round 4). A row carrying a pending outcome is one
		// OneSignal has ALREADY accepted — it is queued only so `sent_at` and
		// the `sent` event can be repaired without resending. Blocking someone
		// cannot unsend a push that has already gone out, so suppressing that
		// row would not protect anyone; it would only destroy the delivery
		// record of a push the recipient actually received, and corrupt the
		// funnel evidence for it. The check belongs on the paths that could
		// still CALL OneSignal, which is exactly what this condition selects.
		if (!pendingOutcome) {
			const deferredBlockState = await checkNotificationBlocked(supabase, row.match_id, row.user_id);
			if (deferredBlockState === "error") {
				// Fail closed and leave the row for the next invocation: an
				// unreadable block list must not read as "not blocked", and
				// this row is not terminal — the lookup may succeed next time.
				failed++;
				continue;
			}
			if (deferredBlockState === "blocked") {
				let blockedQuery = supabase
					.from("notifications")
					.update({ suppressed_reason: "blocked" })
					.eq("id", row.id)
					.eq("scenario_id", row.scenario_id)
					.eq("user_id", row.user_id)
					.is("sent_at", null)
					.is("suppressed_reason", null)
					.is("onesignal_notification_id", null)
					.eq("scheduled_for", fencingToken);
				blockedQuery = row.match_id ? blockedQuery.eq("match_id", row.match_id) : blockedQuery.is("match_id", null);
				blockedQuery = row.meetup_id ? blockedQuery.eq("meetup_id", row.meetup_id) : blockedQuery.is("meetup_id", null);
				const storedDeepLink = readStoredDeepLink(row.payload);
				blockedQuery = storedDeepLink ? blockedQuery.eq("payload->>deep_link", storedDeepLink) : blockedQuery.is("payload->>deep_link", null);
				const { data: blockedRows, error: blockedUpdateError } = await blockedQuery.select("id");
				if (blockedUpdateError) {
					console.error(`[notifications/deferred] failed to mark ${row.id} terminal for a block:`, blockedUpdateError.message);
					failed++;
				} else if ((blockedRows ?? []).length > 0) {
					// Affected-row count checked, not just the error — round 5's audit.
					suppressed++;
				}
				continue;
			}

			// Final fenced re-read immediately before the outbound call.
			//
			// The claim fences every write that FOLLOWS the send, but nothing
			// re-checked the row's own state between the claim and the outbound
			// call. Anything that suppresses or finishes a row concurrently —
			// another claimant, a block suppression, a future cancellation —
			// would therefore still have its push delivered, and then recorded
			// as sent (Codex P2, PR #31 review round 8).
			//
			// This narrows the window to (re-read -> OneSignal call) rather
			// than closing it: the send is an external call and cannot be made
			// transactional with a database row. That residual is the same one
			// accepted elsewhere in this file — a push in flight cannot be
			// recalled — and is why nothing here ever rewrites a row that has
			// already gone out.
			const { data: stillLive, error: stillLiveError } = await supabase
				.from("notifications")
				.select("id")
				.eq("id", row.id)
				.eq("scheduled_for", fencingToken)
				.is("suppressed_reason", null)
				.is("sent_at", null)
				.limit(1);
			if (stillLiveError) {
				// Fail closed: unable to confirm the row is still sendable is
				// not "it is". Left for the next invocation, not marked.
				console.error(`[notifications/deferred] could not re-confirm ${row.id} before sending:`, stillLiveError.message);
				failed++;
				continue;
			}
			if ((stillLive ?? []).length === 0) {
				// Suppressed, finished, or fenced out by another claimant
				// between our claim and now. Not this invocation's to send, and
				// not a failure of any kind.
				continue;
			}
		}
		if (pendingOutcome) {
			result = await repairPendingOutcome(supabase, {
				notificationId: row.id,
				userId: row.user_id,
				pending: pendingOutcome,
				alreadyPersistedInColumn: row.onesignal_notification_id !== null,
				fencingToken,
			});
		} else {
				const deepLink = extractDeepLink(row.payload);
			const deliveryContext =
				row.payload && typeof row.payload === "object"
					? parseNotificationDeliveryContext((row.payload as Record<string, unknown>).delivery_context)
					: null;

			if (!deepLink) {
				// A missing/disallowed deep_link is a structurally broken
				// payload — retrying it can never succeed, so mark it terminal
				// immediately rather than letting it consume the bounded-retry
				// budget below. This is an unsent-delivery terminal state
				// (nothing was ever sent), so it's fine for it to be final,
				// unlike the repair cases below.
				console.error(`[notifications/deferred] notification ${row.id} has no usable deep_link in payload; marking terminal`);
				let terminalQuery = supabase
					.from("notifications")
					.update({ suppressed_reason: "invalid_deep_link" })
					.eq("id", row.id)
					.eq("scenario_id", row.scenario_id)
					.eq("user_id", row.user_id)
					.is("sent_at", null)
					.is("suppressed_reason", null)
					.is("onesignal_notification_id", null)
					.eq("scheduled_for", fencingToken);
				terminalQuery = row.match_id ? terminalQuery.eq("match_id", row.match_id) : terminalQuery.is("match_id", null);
				terminalQuery = row.meetup_id ? terminalQuery.eq("meetup_id", row.meetup_id) : terminalQuery.is("meetup_id", null);
				const storedDeepLink = readStoredDeepLink(row.payload);
				terminalQuery = storedDeepLink ? terminalQuery.eq("payload->>deep_link", storedDeepLink) : terminalQuery.is("payload->>deep_link", null);
				const { data: terminalRows, error: updateError } = await terminalQuery.select("id");
				if (updateError) {
					console.error(`[notifications/deferred] failed to mark ${row.id} terminal for invalid_deep_link:`, updateError.message);
					failed++;
				} else if ((terminalRows ?? []).length === 0) {
					// Fenced out (round 5 finding #2's audit: every conditional
					// update must check affected-row count, not just error) —
					// not this invocation's row anymore; don't count it.
				} else {
					failed++;
				}
				continue;
			}

			result = await deliverNow(supabase, env, {
				notificationId: row.id,
				scenarioId: row.scenario_id,
				userId: row.user_id,
				matchId: row.match_id,
				meetupId: row.meetup_id,
				deepLink,
				deliveryContext,
				fencingToken,
				now: new Date(),
			});
		}

		if (result.ok && result.outcome === "sent") {
			sent++;
			continue;
		}
		if (result.ok && result.outcome === "suppressed_no_subscription") {
			suppressed++;
			continue;
		}
		if (result.ok === false && result.reason === "age_unverified") {
			// deliverNow already marked the row terminal. This is a policy
			// suppression, not an outbound failure: do not spend a retry or
			// move the row into deferred backoff.
			suppressed++;
			continue;
		}
		if (result.ok === false && result.reason === "delivery_precondition_failed") {
			// The final snapshot was validly owned but the current relationship,
			// scenario, or parent state no longer permits this notification. The
			// fenced suppression write already made it terminal.
			suppressed++;
			continue;
		}

		if (result.ok === false && result.reason === "lost_ownership") {
			// Another invocation now owns this row (its fencing gate/claim
			// won the race) — not a failure of any kind for THIS invocation
			// to count or act on. Don't touch deferred_attempts,
			// repair_attempts, or scheduled_for.
			continue;
		}

		const existingPayload = (row.payload && typeof row.payload === "object" ? row.payload : {}) as Record<string, unknown>;

		// Orchestrator review round 4, finding #1: a repair failure
		// (OneSignal already answered; only local bookkeeping is stuck) uses
		// its OWN counter and NEVER reaches deferred_send_exhausted — see
		// REPAIR_BACKOFF_MINUTES's doc comment. Classified two ways, both
		// needed: `attemptedRepair` (this row went through repairPendingOutcome
		// above) catches finalizeAlreadySentNotification's OWN internal
		// failures (a bad pre-insert check, event-check, event-insert, or
		// sent_at write) — those all return the generic `reason:
		// "send_failed"` regardless of which caller invoked them, so the
		// reason string alone can't tell a repair failure from a genuine
		// unsent-delivery one there. The `result.reason` check catches the
		// OTHER case: a FRESH delivery attempt (the `else` branch above, not
		// a repair) where deliverNow itself discovers, for the first time,
		// that OneSignal already answered but a write failed — that failure
		// must ALSO be treated as a repair failure from this point on, even
		// though it didn't arrive via the repair branch.
		const isRepairFailure =
			attemptedRepair ||
			(result.ok === false && (result.reason === "send_accepted_but_unrecorded" || result.reason === "suppression_unrecorded"));

		failed++;

		if (isRepairFailure) {
			const repairAttempts = priorRepairAttempts + 1;
			const repairPayload: Json = {
				...existingPayload,
				repair_attempts: repairAttempts,
				...(result.ok === false && result.reason === "send_accepted_but_unrecorded" ? { pending_onesignal_id: result.oneSignalId } : {}),
				...(result.ok === false && result.reason === "suppression_unrecorded" ? { pending_suppression_id: result.oneSignalId } : {}),
			} as unknown as Json;
			const backoffMinutes = REPAIR_BACKOFF_MINUTES[Math.min(repairAttempts - 1, REPAIR_BACKOFF_MINUTES.length - 1)];
			const nextAttemptAt = new Date(Date.now() + backoffMinutes * 60_000).toISOString();
			const { data: repairBackoffRows, error: updateError } = await supabase
				.from("notifications")
				.update({ scheduled_for: nextAttemptAt, payload: repairPayload })
				.eq("id", row.id)
				.eq("scheduled_for", fencingToken)
				.select("id");
			if (updateError) {
				console.error(`[notifications/deferred] failed to back off repair of ${row.id}:`, updateError.message);
			} else if ((repairBackoffRows ?? []).length === 0) {
				// Fenced out (round 5 finding #2's audit) — a later,
				// legitimate claimant owns backoff bookkeeping for this row
				// now; nothing further to do here.
				console.error(`[notifications/deferred] repair backoff for ${row.id} matched zero rows (lost ownership) — not applied by this invocation`);
			}
			continue;
		}

		// Genuine unsent-delivery failure (reason: "send_failed"): bounded
		// retry with backoff, allowed to exhaust to a terminal
		// suppressed_reason — see MAX_DEFERRED_SEND_ATTEMPTS's doc comment.
		const attempts = priorAttempts + 1;
		const backoffPayload: Json = { ...existingPayload, deferred_attempts: attempts } as unknown as Json;
		if (attempts >= MAX_DEFERRED_SEND_ATTEMPTS) {
			const { data: exhaustedRows, error: updateError } = await supabase
				.from("notifications")
				.update({ suppressed_reason: "deferred_send_exhausted", payload: backoffPayload })
				.eq("id", row.id)
				.eq("scheduled_for", fencingToken)
				.select("id");
			if (updateError) {
				console.error(`[notifications/deferred] failed to mark ${row.id} exhausted:`, updateError.message);
			} else if ((exhaustedRows ?? []).length === 0) {
				console.error(`[notifications/deferred] exhaustion write for ${row.id} matched zero rows (lost ownership) — not applied by this invocation`);
			}
		} else {
			const backoffMinutes = DEFERRED_BACKOFF_MINUTES[Math.min(attempts - 1, DEFERRED_BACKOFF_MINUTES.length - 1)];
			const nextAttemptAt = new Date(Date.now() + backoffMinutes * 60_000).toISOString();
			const { data: backoffRows, error: updateError } = await supabase
				.from("notifications")
				.update({ scheduled_for: nextAttemptAt, payload: backoffPayload })
				.eq("id", row.id)
				.eq("scheduled_for", fencingToken)
				.select("id");
			if (updateError) {
				console.error(`[notifications/deferred] failed to back off ${row.id}:`, updateError.message);
			} else if ((backoffRows ?? []).length === 0) {
				console.error(`[notifications/deferred] backoff for ${row.id} matched zero rows (lost ownership) — not applied by this invocation`);
			}
		}
	}

	return { processed, sent, suppressed, failed };
}

function extractDeepLink(payload: unknown): string | null {
	const value = readStoredDeepLink(payload);
	return value && isAllowedDeepLink(value) ? value : null;
}

function readStoredDeepLink(payload: unknown): string | null {
	if (payload && typeof payload === "object" && "deep_link" in payload) {
		const value = (payload as { deep_link?: unknown }).deep_link;
		if (typeof value === "string") return value;
	}
	return null;
}

function readCounter(payload: unknown, key: "deferred_attempts" | "repair_attempts"): number {
	if (payload && typeof payload === "object" && key in payload) {
		const value = (payload as Record<string, unknown>)[key];
		if (typeof value === "number" && Number.isFinite(value) && value >= 0) return value;
	}
	return 0;
}
