import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { uuidSchema } from "../lib/validation";
import { jsonData, jsonError } from "../lib/response";
import { notifyInBackground } from "../lib/background";
import {
	arrangeMeetup,
	createMeetupIntent,
	getMeetupDetail,
	getMeetupDetailByMatch,
	getMeetupProposalGenerator,
	recordMeetupProposalResponse,
	retryMeetupArrangement,
	saveMeetupPreferences,
} from "../services/meetups";
import { notifyMeetupArrangement, notifyMeetupMutualIntent } from "../services/notification-triggers";
import type { MeetupArrangementNotificationContext } from "../services/meetups";

const meetups = new Hono<Env>();

const INVALID_REQUEST_MESSAGE = "Invalid request";
const NOT_FOUND_MESSAGE = "Meetup not found";
const INTERNAL_ERROR_MESSAGE = "Unable to process meetup";
const INVALID_STATE_MESSAGE = "Meetup cannot be updated";
const IDENTITY_VERIFICATION_MESSAGE = "Identity verification required";
const QUOTA_EXHAUSTED_MESSAGE = "Meetup arrangement is unavailable";

function invalidRequest(c: Parameters<typeof jsonError>[0]) {
	return jsonError(c, "BAD_REQUEST", INVALID_REQUEST_MESSAGE);
}

function mapServiceError(c: Parameters<typeof jsonError>[0], reason: "not_found" | "invalid_state" | "internal") {
	if (reason === "not_found") return jsonError(c, "NOT_FOUND", NOT_FOUND_MESSAGE);
	if (reason === "invalid_state") return jsonError(c, "CONFLICT", INVALID_STATE_MESSAGE);
	return jsonError(c, "INTERNAL_ERROR", INTERNAL_ERROR_MESSAGE);
}

async function readJson(c: Parameters<typeof jsonError>[0]): Promise<unknown> {
	try {
		return await c.req.json();
	} catch {
		return undefined;
	}
}

function mapArrangeError(c: Parameters<typeof jsonError>[0], reason: string, paywallSource = "meetup_arrange") {
	if (reason === "not_found") return jsonError(c, "NOT_FOUND", NOT_FOUND_MESSAGE);
	if (reason === "identity_verification_required") return jsonError(c, "CONFLICT", IDENTITY_VERIFICATION_MESSAGE);
	if (reason === "quota_exhausted") {
		// Keep the project-wide uppercase machine code and fixed, neutral copy.
		// The iOS client lowercases the code when mapping its allowlisted
		// paywall source; counts, periods, and billing state never cross this
		// boundary.
		return c.json(
			{ error: { code: "PAYMENT_REQUIRED", message: QUOTA_EXHAUSTED_MESSAGE, source: paywallSource } },
			402,
		);
	}
	if (reason === "bad_request") return invalidRequest(c);
	if (reason === "invalid_state") return mapServiceError(c, "invalid_state");
	return mapServiceError(c, "internal");
}

function readIdempotencyKey(c: Parameters<typeof jsonError>[0]): string | undefined {
	return c.req.header("Idempotency-Key") ?? c.req.header("X-Idempotency-Key") ?? undefined;
}

function queueArrangementNotifications(
	c: Parameters<typeof jsonError>[0],
	supabase: ReturnType<typeof getSupabaseClient>,
	contexts: MeetupArrangementNotificationContext[] | undefined,
): void {
	for (const context of contexts ?? []) {
		// Proposal/confirmation/failure notifications are durable side effects,
		// never part of the route acknowledgement. The trigger re-checks the
		// meetup relationship and state before it reaches sendNotification.
		notifyInBackground(c, () => notifyMeetupArrangement({ supabase, env: c.env }, context));
	}
}

async function readEmptyPostBody(c: Parameters<typeof jsonError>[0]): Promise<boolean> {
	const contentLength = c.req.header("Content-Length");
	if (contentLength === "0") return true;
	if (contentLength === undefined && c.req.header("Content-Type") === undefined) return true;
	const body = await readJson(c);
	return body === undefined || isEmptyObject(body);
}

function isEmptyObject(value: unknown): boolean {
	return typeof value === "object" && value !== null && !Array.isArray(value) && Object.keys(value).length === 0;
}

/** POST /api/meetups/intents */
meetups.post("/intents", requireAuth, requireAgeVerified, async (c) => {
	const body = await readJson(c);
	if (typeof body !== "object" || body === null || Array.isArray(body)) return invalidRequest(c);
	const requestBody = body as Record<string, unknown>;
	if (Object.keys(requestBody).length !== 1 || !Object.prototype.hasOwnProperty.call(requestBody, "match_id")) {
		return invalidRequest(c);
	}
	const matchId = requestBody.match_id;
	const parsedMatchId = uuidSchema.safeParse(matchId);
	if (parsedMatchId.success === false) return invalidRequest(c);

	const supabase = getSupabaseClient(c.env);
	const result = await createMeetupIntent(supabase, c.get("user_id"), parsedMatchId.data);
	if (result.ok === false) {
		// A syntactically valid intent request always has the same public
		// acknowledgement, including the service's non-disclosing not-found
		// fallback. Only an RPC/service failure is an HTTP error.
		if (result.reason === "not_found") return jsonData(c, { accepted: true });
		return mapServiceError(c, result.reason);
	}
	const notificationContext = result.notificationContext;
	if (notificationContext) {
		// Notification delivery is a best-effort side effect. The trigger and
		// notifyInBackground both contain failures so a OneSignal/database issue
		// cannot change the successful, non-disclosing intent acknowledgement.
		notifyInBackground(c, () =>
			notifyMeetupMutualIntent(
				{ supabase, env: c.env },
				notificationContext,
			),
		);
	}
	return jsonData(c, { accepted: true });
});

/** GET /api/meetups/by-match/:matchId — resume the caller's current meetup */
meetups.get("/by-match/:matchId", requireAuth, requireAgeVerified, async (c) => {
	const parsedMatchId = uuidSchema.safeParse(c.req.param("matchId"));
	if (parsedMatchId.success === false) return invalidRequest(c);

	const result = await getMeetupDetailByMatch(
		getSupabaseClient(c.env),
		c.get("user_id"),
		parsedMatchId.data,
	);
	if (result.ok === false) return mapServiceError(c, result.reason);
	return jsonData(c, result.data);
});

/** POST /api/meetups/:id/arrange */
meetups.post("/:id/arrange", requireAuth, requireAgeVerified, async (c) => {
	const parsedMeetupId = uuidSchema.safeParse(c.req.param("id"));
	if (parsedMeetupId.success === false) return invalidRequest(c);
	if (!(await readEmptyPostBody(c))) return invalidRequest(c);

	const supabase = getSupabaseClient(c.env);
	const result = await arrangeMeetup(
		supabase,
		c.get("user_id"),
		parsedMeetupId.data,
		getMeetupProposalGenerator(c.env?.MISTRAL_API_KEY),
		{ idempotencyKey: readIdempotencyKey(c) },
	);
	if (result.ok === false) return mapArrangeError(c, result.reason, "meetup_arrange");
	queueArrangementNotifications(c, supabase, result.notificationContexts);
	return jsonData(c, { accepted: true, status: "arranging" });
});

/** POST /api/meetups/:id/retry */
meetups.post("/:id/retry", requireAuth, requireAgeVerified, async (c) => {
	const parsedMeetupId = uuidSchema.safeParse(c.req.param("id"));
	if (parsedMeetupId.success === false) return invalidRequest(c);
	if (!(await readEmptyPostBody(c))) return invalidRequest(c);

	const supabase = getSupabaseClient(c.env);
	const result = await retryMeetupArrangement(
		supabase,
		c.get("user_id"),
		parsedMeetupId.data,
		getMeetupProposalGenerator(c.env?.MISTRAL_API_KEY),
		{ idempotencyKey: readIdempotencyKey(c) },
	);
	if (result.ok === false) return mapArrangeError(c, result.reason, "arrange_retry");
	queueArrangementNotifications(c, supabase, result.notificationContexts);
	return jsonData(c, { accepted: true, status: "arranging" });
});

/** POST /api/meetups/:id/proposals/:proposalId/responses */
meetups.post("/:id/proposals/:proposalId/responses", requireAuth, requireAgeVerified, async (c) => {
	const parsedMeetupId = uuidSchema.safeParse(c.req.param("id"));
	const parsedProposalId = uuidSchema.safeParse(c.req.param("proposalId"));
	if (parsedMeetupId.success === false || parsedProposalId.success === false) return invalidRequest(c);

	// The path is authorized before body validation by the service.  The body
	// itself is closed so a caller cannot smuggle a second participant or a
	// caller-selected proposal id through an ignored field.
	const body = await readJson(c);
	if (typeof body !== "object" || body === null || Array.isArray(body)) return invalidRequest(c);
	const requestBody = body as Record<string, unknown>;
	if (Object.keys(requestBody).length !== 1 || !Object.prototype.hasOwnProperty.call(requestBody, "selected_candidate_index")) return invalidRequest(c);
	const selectedCandidateIndex = requestBody.selected_candidate_index;
	if (typeof selectedCandidateIndex !== "number" || !Number.isInteger(selectedCandidateIndex) || selectedCandidateIndex < 0 || selectedCandidateIndex > 2) {
		return invalidRequest(c);
	}

	const supabase = getSupabaseClient(c.env);
	const result = await recordMeetupProposalResponse(
		supabase,
		c.get("user_id"),
		parsedMeetupId.data,
		parsedProposalId.data,
		selectedCandidateIndex,
	);
	if (result.ok === false) return mapArrangeError(c, result.reason, "arrange_retry");
	queueArrangementNotifications(c, supabase, result.notificationContexts);
	return jsonData(c, { accepted: true, status: result.status });
});

/** GET /api/meetups/:id */
meetups.get("/:id", requireAuth, requireAgeVerified, async (c) => {
	const parsedMeetupId = uuidSchema.safeParse(c.req.param("id"));
	if (parsedMeetupId.success === false) return invalidRequest(c);

	const result = await getMeetupDetail(getSupabaseClient(c.env), c.get("user_id"), parsedMeetupId.data);
	if (result.ok === false) return mapServiceError(c, result.reason);
	return jsonData(c, result.data);
});

/** PUT /api/meetups/:id/preferences */
meetups.put("/:id/preferences", requireAuth, requireAgeVerified, async (c) => {
	const parsedMeetupId = uuidSchema.safeParse(c.req.param("id"));
	if (parsedMeetupId.success === false) return invalidRequest(c);

	// Authorization runs before body validation so an unknown/non-participant
	// cannot distinguish a real meetup from an unavailable one by sending an
	// intentionally malformed preference payload.
	const body = await readJson(c);
	const result = await saveMeetupPreferences(
		getSupabaseClient(c.env),
		c.get("user_id"),
		parsedMeetupId.data,
		body,
	);
	if (result.ok === false) {
		if (result.reason === "bad_request") return invalidRequest(c);
		return mapServiceError(c, result.reason);
	}
	return jsonData(c, { saved: true });
});

export default meetups;
