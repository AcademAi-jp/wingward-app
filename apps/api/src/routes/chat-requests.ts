import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { isJudgeAccessActive } from "../services/judge-access";
import { z } from "zod";
import { notifyInBackground } from "../lib/background";
import { notifyChatRequestCreated } from "../services/notification-triggers";
import { checkVerifiedMatch, filterVerifiedMatches, isVerifiedMatch } from "../services/match-age-access";

const chatRequests = new Hono<Env>();

const postSchema = z.object({ match_id: z.string().uuid().transform((id) => id.toLowerCase()) });
const putSchema = z.object({ action: z.enum(["accept", "decline"]) });

type CleanupOperation = () => Promise<{ error: unknown | null }>;

/** Run every compensating write and collapse all failures to a safe log. */
async function bestEffortCleanup(operations: CleanupOperation[], logMessage: string): Promise<void> {
	let cleanupFailed = false;
	for (const operation of operations) {
		try {
			const { error } = await operation();
			cleanupFailed ||= Boolean(error);
		} catch {
			cleanupFailed = true;
		}
	}
	if (cleanupFailed) console.error(logMessage);
}

/** POST /api/chat-requests */
chatRequests.post("/", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const parsed = postSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	const supabase = getSupabaseClient(c.env);
	const verifiedMatch = await checkVerifiedMatch(supabase, parsed.data.match_id, userId);
	if (!isVerifiedMatch(verifiedMatch)) {
		return verifiedMatch.reason === "error"
			? jsonError(c, "INTERNAL_ERROR", "Failed to verify match eligibility")
			: jsonError(c, "NOT_FOUND", "Match not found");
	}
	const partnerId = verifiedMatch.partnerId;
	const judge = c.get("judge_access");
	if (judge && (judge.actorId !== userId || !isJudgeAccessActive(judge) || judge.counterpartId !== partnerId)) return jsonError(c, "NOT_FOUND", "Match not found");

	// A block in EITHER direction ends this route. The match and the
	// partner_fox_chats row both survive a block, so without this a blocked
	// requester could still create a chat request against the person who
	// blocked them — and, since N-03 is dispatched below, reach them with a
	// push. That would make the block route's closing of direct-chat rooms
	// cosmetic. Same shape as requestFoxConversation's check, deliberately, so
	// the two paths cannot drift.
	const { data: blockRow, error: blockError } = await supabase
		.from("blocks")
		.select("id")
		.or(`and(blocker_id.eq.${userId},blocked_id.eq.${partnerId}),and(blocker_id.eq.${partnerId},blocked_id.eq.${userId})`)
		.limit(1)
		.maybeSingle();
	if (blockError) {
		// Fail closed: a transient failure of the block lookup must never read
		// as "not blocked". INTERNAL_ERROR rather than NOT_FOUND, so the answer
		// still carries no information about whether a block exists.
		console.error("[chat-requests] blocks lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify match eligibility");
	}
	// Identical to the not-a-participant response above, so this cannot be used
	// to probe whether a given user has blocked you.
	if (blockRow) return jsonError(c, "NOT_FOUND", "Match not found");

	const { data: pfc, error: pfcError } = await supabase.from("partner_fox_chats").select("id").eq("match_id", parsed.data.match_id).eq("user_id", userId).maybeSingle();
	if (pfcError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify match eligibility");
	if (!pfc) return jsonError(c, "CONFLICT", "Partner fox chat not started");
	const { data: existing, error: existingError } = await supabase.from("chat_requests").select("id").eq("match_id", parsed.data.match_id).maybeSingle();
	if (existingError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify match eligibility");
	if (existing) return jsonError(c, "CONFLICT", "Request already sent");
	const expiresAt = new Date();
	expiresAt.setHours(expiresAt.getHours() + 48);
	const { data: req, error } = await supabase
		.from("chat_requests")
		.insert({
			match_id: parsed.data.match_id,
			requester_id: userId,
			responder_id: partnerId,
			expires_at: expiresAt.toISOString(),
		})
		.select("id, match_id, status, expires_at")
		.single();
	if (error || !req) return jsonError(c, "INTERNAL_ERROR", "Failed to create request");
	const { error: matchUpdateError } = await supabase.from("matches").update({ status: "direct_chat_requested", updated_at: new Date().toISOString() }).eq("id", parsed.data.match_id);
	if (matchUpdateError) {
		// Compensate: delete the chat_request we just created
		await bestEffortCleanup(
			[async () => supabase.from("chat_requests").delete().eq("id", req.id)],
			"[chat-requests] failed to roll back request creation",
		);
		return jsonError(c, "INTERNAL_ERROR", "Failed to update match status");
	}

	// N-03. Deliberately below the compensating delete above: a request that was
	// rolled back must not produce a push for a row that no longer exists.
	// Handed to waitUntil so the requester's response is not held behind an
	// outbound OneSignal call, and so a slow send cannot turn a successful
	// action into a timeout. The trigger contains its own errors.
	notifyInBackground(c, () =>
		notifyChatRequestCreated(
			{ supabase, env: c.env },
			{ chatRequestId: req.id, matchId: parsed.data.match_id, responderId: partnerId },
		),
	);

	return jsonData(c, { ...req, ...(judge ? { simulated_counterpart: true } : {}) });
});

/** GET /api/chat-requests - list received pending */
chatRequests.get("/", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const { data: list, error: listError } = await supabase
		.from("chat_requests")
		.select("id, match_id, requester_id, status, expires_at, created_at")
		.eq("responder_id", userId)
		.eq("status", "pending")
		.gt("expires_at", new Date().toISOString());
	if (listError || !list) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch chat requests");
	if (!list.length) return jsonData(c, []);
	const matchIds = list.map((r) => r.match_id);
	const { data: matches, error: matchesError } = await supabase
		.from("matches")
		.select("id, final_score, user_a_id, user_b_id")
		.in("id", matchIds);
	if (matchesError || !matches) return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	const verifiedMatches = await filterVerifiedMatches(supabase, matches);
	if (!verifiedMatches.ok) return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	const verifiedMatchIds = new Set(verifiedMatches.rows.map((m) => m.id));
	const scoreMap = new Map(verifiedMatches.rows.map((m) => [m.id, m.final_score]));
	const visibleRequests = list.filter((r) => verifiedMatchIds.has(r.match_id));
	if (!visibleRequests.length) return jsonData(c, []);
	const requesterIds = [...new Set(visibleRequests.map((r) => r.requester_id))];
	const { data: profiles, error: profilesError } = await supabase.from("user_profiles").select("id, nickname").in("id", requesterIds);
	if (profilesError || !profiles) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch chat requests");
	if (requesterIds.some((requesterId) => !profiles.some((profile) => profile.id === requesterId))) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch chat requests");
	}
	const profileMap = new Map(profiles.map((p) => [p.id, p]));
	const results = visibleRequests.map((r) => ({
		...r,
		requester: profileMap.get(r.requester_id) ?? { nickname: "相手" },
		final_score: scoreMap.get(r.match_id),
	}));
	return jsonData(c, results);
});

/** GET /api/chat-requests/by-match/:matchId - participant-only status lookup */
chatRequests.get("/by-match/:matchId", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const parsedMatchId = z.string().uuid().safeParse(c.req.param("matchId"));
	if (!parsedMatchId.success) return jsonError(c, "BAD_REQUEST", "Invalid match id");
	const matchId = parsedMatchId.data;
	const supabase = getSupabaseClient(c.env);
	const verifiedMatch = await checkVerifiedMatch(supabase, matchId, userId);
	if (!isVerifiedMatch(verifiedMatch)) {
		return verifiedMatch.reason === "error"
			? jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility")
			: jsonError(c, "NOT_FOUND", "Match not found");
	}
	const judge = c.get("judge_access");
	if (judge && (judge.actorId !== userId || !isJudgeAccessActive(judge) || judge.counterpartId !== verifiedMatch.partnerId)) return jsonError(c, "NOT_FOUND", "Match not found");

	// Match membership alone does not make a stale request visible after a
	// block. Keep this lookup fail-closed and return the same non-disclosing
	// response for either block direction.
	const { data: blockRow, error: blockError } = await supabase
		.from("blocks")
		.select("id")
		.or(`and(blocker_id.eq.${userId},blocked_id.eq.${verifiedMatch.partnerId}),and(blocker_id.eq.${verifiedMatch.partnerId},blocked_id.eq.${userId})`)
		.limit(1)
		.maybeSingle();
	if (blockError) {
		console.error("[chat-requests] blocks lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	}
	if (blockRow) return jsonError(c, "NOT_FOUND", "Match not found");

	const { data: request, error: requestError } = await supabase
		.from("chat_requests")
		.select("id, match_id, requester_id, responder_id, status, expires_at")
		.eq("match_id", matchId)
		.maybeSingle();
	if (requestError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	if (!request) return jsonData(c, { request: null, ...(judge ? { simulated_counterpart: true, judge_match_id: matchId } : {}) });

	const participants = new Set([verifiedMatch.match.user_a_id, verifiedMatch.match.user_b_id]);
	if (
		request.match_id !== matchId ||
		!participants.has(request.requester_id) ||
		!participants.has(request.responder_id) ||
		request.requester_id === request.responder_id ||
		(request.requester_id !== userId && request.responder_id !== userId)
	) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	}
	if (!["pending", "accepted", "declined", "expired"].includes(request.status)) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	}

	if (typeof request.expires_at !== "string" || request.expires_at.trim().length === 0) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	}
	const expiresAt = new Date(request.expires_at);
	if (!Number.isFinite(expiresAt.getTime())) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	}
	const status = request.status === "pending" && expiresAt.getTime() <= Date.now()
		? "expired"
		: request.status;
	return jsonData(c, {
		request: { ...request, status, ...(judge ? { simulated_counterpart: true } : {}) },
		...(judge ? { simulated_counterpart: true, judge_match_id: matchId } : {}),
	});
});

/** PUT /api/chat-requests/:id */
chatRequests.put("/:id", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const parsed = putSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	const supabase = getSupabaseClient(c.env);
	const { data: req, error: reqError } = await supabase.from("chat_requests").select("*").eq("id", id).eq("responder_id", userId).eq("status", "pending").maybeSingle();
	if (reqError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	if (!req) return jsonError(c, "NOT_FOUND", "Request not found");
	const verifiedMatch = await checkVerifiedMatch(supabase, req.match_id, userId);
	if (!isVerifiedMatch(verifiedMatch)) {
		return verifiedMatch.reason === "error"
			? jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility")
			: jsonError(c, "NOT_FOUND", "Request not found");
	}
	const participantIds = new Set([verifiedMatch.match.user_a_id, verifiedMatch.match.user_b_id]);
	if (!participantIds.has(req.requester_id) || !participantIds.has(req.responder_id) || req.requester_id === req.responder_id) {
		return jsonError(c, "NOT_FOUND", "Request not found");
	}
	if (new Date(req.expires_at) < new Date()) {
		const { error: expireError } = await supabase.from("chat_requests").update({ status: "expired" }).eq("id", id);
		if (expireError) return jsonError(c, "INTERNAL_ERROR", "Failed to update request");
		return jsonError(c, "CONFLICT", "Request expired");
	}
	if (parsed.data.action === "decline") {
		const { error: declineError } = await supabase.from("chat_requests").update({ status: "declined", responded_at: new Date().toISOString() }).eq("id", id);
		if (declineError) return jsonError(c, "INTERNAL_ERROR", "Failed to update request");
		const { error: declineMatchError } = await supabase.from("matches").update({ status: "chat_request_declined", updated_at: new Date().toISOString() }).eq("id", req.match_id);
		if (declineMatchError) {
			await bestEffortCleanup(
				[async () => supabase.from("chat_requests").update({ status: "pending", responded_at: null }).eq("id", id)],
				"[chat-requests] failed to roll back declined request",
			);
			return jsonError(c, "INTERNAL_ERROR", "Failed to update request");
		}
		return jsonData(c, { request_id: id, status: "declined" });
	}
	// Same shape as the POST handler's block check above, deliberately, so the
	// two paths cannot drift: a block in EITHER direction stops this before
	// the room INSERT the reject_blocked_pair_by_match trigger backstops. The
	// trigger is the actual guarantee; this exists only to return a clean
	// error and stop earlier instead of surfacing a raised exception.
	const { data: acceptBlockRow, error: acceptBlockError } = await supabase
		.from("blocks")
		.select("id")
		.or(`and(blocker_id.eq.${req.requester_id},blocked_id.eq.${req.responder_id}),and(blocker_id.eq.${req.responder_id},blocked_id.eq.${req.requester_id})`)
		.limit(1)
		.maybeSingle();
	if (acceptBlockError) {
		// Fail closed, same as the POST handler: an unreadable block list is
		// never "not blocked".
		console.error("[chat-requests] blocks lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify request eligibility");
	}
	// Same NOT_FOUND text the top of this handler already returns when the
	// request itself can't be found, so this adds no new information.
	if (acceptBlockRow) return jsonError(c, "NOT_FOUND", "Request not found");

	// Step 1: Create room
	const { data: room, error: roomErr } = await supabase
		.from("direct_chat_rooms")
		.insert({ match_id: req.match_id })
		.select("id")
		.single();
	if (roomErr || !room) return jsonError(c, "INTERNAL_ERROR", "Failed to create room");
	// Step 2: Update chat_request status
	const { error: crUpdateErr } = await supabase.from("chat_requests").update({ status: "accepted", responded_at: new Date().toISOString() }).eq("id", id);
	if (crUpdateErr) {
		// Compensate: delete the room
		await bestEffortCleanup(
			[async () => supabase.from("direct_chat_rooms").delete().eq("id", room.id)],
			"[chat-requests] failed to roll back direct chat room",
		);
		return jsonError(c, "INTERNAL_ERROR", "Failed to update chat request");
	}
	// Step 3: Update match status
	const { error: matchUpdateErr } = await supabase.from("matches").update({ status: "direct_chat_active", updated_at: new Date().toISOString() }).eq("id", req.match_id);
	if (matchUpdateErr) {
		// Compensate: rollback chat_request and delete room
		await bestEffortCleanup(
			[
				async () => supabase.from("chat_requests").update({ status: "pending", responded_at: null }).eq("id", id),
				async () => supabase.from("direct_chat_rooms").delete().eq("id", room.id),
			],
			"[chat-requests] failed to roll back accepted request",
		);
		return jsonError(c, "INTERNAL_ERROR", "Failed to update match status");
	}
	return jsonData(c, { request_id: id, status: "accepted", direct_chat_room_id: room.id });
});

export default chatRequests;
