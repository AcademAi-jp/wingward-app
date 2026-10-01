import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { searchMatchCandidates } from "../services/fox-search";
import { runFoxConversation } from "../services/fox-conversation";
import { consumeFoxConversationQuota, refundFoxConversationQuota } from "../services/fox-conversation-request";
import { checkFoxConversationParticipant } from "../services/fox-conversation-access";
import { checkVerifiedPair } from "../services/match-age-access";

const foxSearch = new Hono<Env>();

async function markRetryFailedBestEffort(
	supabase: ReturnType<typeof getSupabaseClient>,
	conversationId: string,
	matchId: string,
): Promise<void> {
	const results = await Promise.allSettled([
		supabase.from("fox_conversations").update({ status: "failed" }).eq("id", conversationId),
		supabase.from("matches").update({ status: "fox_conversation_failed" }).eq("id", matchId),
	]);
	if (results.some((result) => result.status === "rejected" || Boolean(result.value.error))) {
		console.error("[fox-search/retry] failed to clean up retry state");
	}
}

/**
 * POST /api/fox-search/start — search for a partner fox and create match
 * candidates only. Does NOT create a fox_conversations row or start the DO
 * — under lazy generation, conversation creation happens exclusively via
 * POST /api/matches/:id/fox-conversation (services/fox-conversation-request.ts).
 * This route used to also start the conversation; that was an unmetered
 * bypass of the quota system (see step-3a security impact report §1, §5.1).
 */
foxSearch.post("/start", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);

	// Guard: reject if user already has an in_progress fox conversation.
	// Still meaningful under lazy generation — conversations can still reach
	// in_progress via the new route, and we don't want to pile up match
	// candidates while one is actively running (Mistral rate-limit concern).
	const { data: userMatches, error: userMatchesError } = await supabase
		.from("matches")
		.select("id")
		.or(`user_a_id.eq.${userId},user_b_id.eq.${userId}`);
	if (userMatchesError || !userMatches) {
		console.error("[fox-search/start] failed to read active match guard");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify active fox conversation");
	}

	if (userMatches.length > 0) {
		const { data: activeConvs, error: activeConvsError } = await supabase
			.from("fox_conversations")
			.select("id")
			.in("match_id", userMatches.map((m) => m.id))
			.eq("status", "in_progress")
			.limit(1);
		if (activeConvsError || !activeConvs) {
			console.error("[fox-search/start] failed to read active conversation guard");
			return jsonError(c, "INTERNAL_ERROR", "Failed to verify active fox conversation");
		}

		if (activeConvs.length > 0) {
			return jsonError(c, "CONFLICT", "A fox conversation is already in progress");
		}
	}

	let results: Array<{ match_id: string; partner_user_id: string }>;
	try {
		results = await searchMatchCandidates(supabase, userId);
	} catch (e: unknown) {
		const msg = e instanceof Error ? e.message : "Unknown error";
		if (msg === "WINGFOX_PERSONA_NOT_FOUND") {
			return jsonError(c, "BAD_REQUEST", "You need a wingfox persona first");
		}
		if (msg === "NO_CANDIDATES_FOUND") {
			return jsonError(c, "NOT_FOUND", "No eligible partners found");
		}
		console.error("[fox-search/start] search failed:", msg);
		return jsonError(c, "INTERNAL_ERROR", "An unexpected error occurred");
	}

	return jsonData(c, {
		matches: results.map((r) => ({
			match_id: r.match_id,
		})),
	});
});

/** GET /api/fox-search/status/:conversationId — poll conversation progress */
foxSearch.get("/status/:conversationId", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const conversationId = c.req.param("conversationId");
	const supabase = getSupabaseClient(c.env);

	const access = await checkFoxConversationParticipant(supabase, conversationId, userId);
	if (access.ok === false) {
		return access.reason === "not_found"
			? jsonError(c, "NOT_FOUND", "Conversation not found")
			: jsonError(c, "FORBIDDEN", "Access denied");
	}

	const { data: conv, error } = await supabase
		.from("fox_conversations")
		.select("id, match_id, status, current_round, total_rounds, completed_at")
		.eq("id", conversationId)
		.single();
	if (error || !conv) return jsonError(c, "NOT_FOUND", "Conversation not found");

	return jsonData(c, {
		status: conv.status,
		current_round: conv.current_round,
		total_rounds: conv.total_rounds,
		completed_at: conv.completed_at,
	});
});

/** POST /api/fox-search/retry/:matchId — retry/re-run fox conversation (failed match: resume; completed match: re-run from round 1) */
foxSearch.post("/retry/:matchId", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const matchId = c.req.param("matchId");
	const supabase = getSupabaseClient(c.env);
	const apiKey = c.env.MISTRAL_API_KEY;
	if (!apiKey) return jsonError(c, "INTERNAL_ERROR", "Mistral API not configured");

	const { data: match, error: matchError } = await supabase
		.from("matches")
		.select("id, user_a_id, user_b_id, status")
		.eq("id", matchId)
		.single();
	if (matchError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify match");
	if (!match || (match.user_a_id !== userId && match.user_b_id !== userId)) {
		return jsonError(c, "NOT_FOUND", "Match not found");
	}
	const agePair = await checkVerifiedPair(supabase, match.user_a_id, match.user_b_id);
	if (agePair.ok === false) return jsonError(c, agePair.reason === "error" ? "INTERNAL_ERROR" : "NOT_FOUND", agePair.reason === "error" ? "Failed to verify match eligibility" : "Match not found");
	// Allow retry for both failed and completed (re-measure)
	const allowedStatuses = ["fox_conversation_failed", "fox_conversation_completed"];
	if (!allowedStatuses.includes(match.status)) {
		return jsonError(c, "BAD_REQUEST", "Match is not in failed or completed state");
	}

	const { data: fc, error: conversationError } = await supabase
		.from("fox_conversations")
		.select("id, status")
		.eq("match_id", matchId)
		.single();
	if (conversationError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify fox conversation");
	if (!fc) return jsonError(c, "NOT_FOUND", "No fox conversation for this match");
	// failed: expect fc.status === "failed"; completed: expect fc.status === "completed"
	if (match.status === "fox_conversation_failed" && fc.status !== "failed") {
		return jsonError(c, "NOT_FOUND", "No failed fox conversation for this match");
	}
	if (match.status === "fox_conversation_completed" && fc.status !== "completed") {
		return jsonError(c, "BAD_REQUEST", "Fox conversation is not completed");
	}

	// Quota policy (user decision, step-3a): retrying a FAILED conversation is
	// free — the quota unit was already spent and our own failure shouldn't be
	// charged twice. Re-running a COMPLETED conversation counts as a NEW
	// conversation and consumes quota like the main lazy-generation route does.
	let quotaConsumedForRetry = false;
	// The period the retry unit was charged to; a refund must target this exact
	// period, not a freshly computed one (a rollover would refund the wrong month).
	let quotaPeriodForRetry: string | null = null;
	if (match.status === "fox_conversation_completed") {
		const { data: entitlement, error: entitlementError } = await supabase
			.from("entitlements")
			.select("is_active")
			.eq("user_id", userId)
			.maybeSingle();
		if (entitlementError) {
			console.error("[fox-search/retry] failed to read entitlement");
			return jsonError(c, "INTERNAL_ERROR", "Failed to verify fox conversation entitlement");
		}
		if (entitlement?.is_active !== true) {
			const quota = await consumeFoxConversationQuota(supabase, userId);
			if (!quota.ok) {
				// No internal state (used_count, limit) in the response.
				return jsonError(c, "PAYMENT_REQUIRED", "Free fox-conversation quota reached for this month");
			}
			quotaConsumedForRetry = quota.consumed;
			quotaPeriodForRetry = quota.periodStart;
		}
	}

	// Guard: no other in_progress fox conversation for this user
	const { data: userMatches, error: userMatchesError } = await supabase
		.from("matches")
		.select("id")
		.or(`user_a_id.eq.${userId},user_b_id.eq.${userId}`);
	if (userMatchesError || !userMatches) {
		if (quotaConsumedForRetry && quotaPeriodForRetry) await refundFoxConversationQuota(supabase, userId, quotaPeriodForRetry);
		console.error("[fox-search/retry] failed to read active match guard");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify active fox conversation");
	}
	const otherMatchIds = userMatches.filter((m) => m.id !== matchId).map((m) => m.id);
	if (otherMatchIds.length > 0) {
		const { data: activeConvs, error: activeConvsError } = await supabase
			.from("fox_conversations")
			.select("id")
			.in("match_id", otherMatchIds)
			.eq("status", "in_progress")
			.limit(1);
		if (activeConvsError || !activeConvs) {
			if (quotaConsumedForRetry && quotaPeriodForRetry) await refundFoxConversationQuota(supabase, userId, quotaPeriodForRetry);
			console.error("[fox-search/retry] failed to read active conversation guard");
			return jsonError(c, "INTERNAL_ERROR", "Failed to verify active fox conversation");
		}
		if (activeConvs.length > 0) {
			if (quotaConsumedForRetry && quotaPeriodForRetry) await refundFoxConversationQuota(supabase, userId, quotaPeriodForRetry);
			return jsonError(c, "CONFLICT", "A fox conversation is already in progress");
		}
	}

	// Reset: always clear messages so DO starts fresh with history: []
	const { error: messagesDeleteError } = await supabase.from("fox_conversation_messages").delete().eq("conversation_id", fc.id);
	if (messagesDeleteError) {
		if (quotaConsumedForRetry && quotaPeriodForRetry) await refundFoxConversationQuota(supabase, userId, quotaPeriodForRetry);
		await markRetryFailedBestEffort(supabase, fc.id, matchId);
		return jsonError(c, "INTERNAL_ERROR", "Failed to reset fox conversation");
	}
	const { error: conversationResetError } = await supabase
		.from("fox_conversations")
		.update({
			status: "pending",
			current_round: 0,
			started_at: null,
			completed_at: null,
			conversation_analysis: null,
		})
		.eq("id", fc.id);
	if (conversationResetError) {
		if (quotaConsumedForRetry && quotaPeriodForRetry) await refundFoxConversationQuota(supabase, userId, quotaPeriodForRetry);
		await markRetryFailedBestEffort(supabase, fc.id, matchId);
		return jsonError(c, "INTERNAL_ERROR", "Failed to reset fox conversation");
	}
	const { error: matchResetError } = await supabase
		.from("matches")
		.update({ status: "fox_conversation_in_progress", updated_at: new Date().toISOString() })
		.eq("id", matchId);
	if (matchResetError) {
		if (quotaConsumedForRetry && quotaPeriodForRetry) await refundFoxConversationQuota(supabase, userId, quotaPeriodForRetry);
		await markRetryFailedBestEffort(supabase, fc.id, matchId);
		return jsonError(c, "INTERNAL_ERROR", "Failed to reset fox conversation");
	}

	// DOでアラームチェーン実行（初回フローと同じ）
	if (c.env.FOX_CONVERSATION) {
		let started = false;
		try {
			const doId = c.env.FOX_CONVERSATION.idFromName(fc.id);
			const stub = c.env.FOX_CONVERSATION.get(doId);
			// A non-2xx response does not throw, so the status has to be checked
			// explicitly: otherwise a rejected init leaves the retry charged and
			// the rows stuck in progress while the route reports success.
			const response = await stub.fetch(new Request("https://do/init", {
				method: "POST",
				body: JSON.stringify({ conversationId: fc.id, matchId }),
			}));
			started = response.ok;
			if (!started) console.error("[fox-search/retry] Fox conversation start was rejected");
		} catch {
			console.error("[fox-search/retry] Failed to start fox conversation");
		}
		if (!started) {
			if (quotaConsumedForRetry && quotaPeriodForRetry) await refundFoxConversationQuota(supabase, userId, quotaPeriodForRetry);
			await markRetryFailedBestEffort(supabase, fc.id, matchId);
			return jsonError(c, "INTERNAL_ERROR", "Failed to start fox conversation");
		}
	} else {
		// フォールバック: DO未対応環境（ローカル開発）
		const bgTask = (async () => {
			try {
				await runFoxConversation(supabase, apiKey, fc.id);
			} catch {
				console.error("[fox-search/retry] Background fox conversation failed");
				await markRetryFailedBestEffort(supabase, fc.id, matchId);
			}
		})();
		try {
			c.executionCtx.waitUntil(bgTask);
		} catch {
			// Node.js dev server
		}
	}

	return jsonData(c, {
		match_id: matchId,
		fox_conversation_id: fc.id,
	});
});

export default foxSearch;
