/**
 * Lazy fox-conversation request: the only place a `fox_conversations` row
 * (purpose = 'compatibility') gets created for a match.
 *
 * See step-3a security impact report for why this exists: matches used to
 * get a fox_conversations row automatically at creation time (daily batch,
 * /api/internal/matching/execute, and /api/fox-search/start); all three were
 * unmetered. Conversation creation now funnels exclusively through
 * `requestFoxConversation`, called from `POST /api/matches/:id/fox-conversation`.
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import type { Env } from "../env";
import { getUtcMonthPeriod } from "../lib/date";
import { checkVerifiedPair } from "./match-age-access";
import {
	isFoxConversationGenerationAllowed,
	resolveFoxConversationGenerationWindow,
	type FoxConversationRecordingWindow,
} from "./fox-conversation-recording-window";

/** Free monthly fox-conversation allowance; also applies to a "completed -> retry" re-run (see routes/fox-search.ts). */
export const FREE_FOX_CONVERSATION_LIMIT = 3;
export const FOX_CONVERSATION_QUOTA_KEY = "fox_conversation";

export type RequestFoxConversationResult =
	| { ok: true; conversationId: string }
	| { ok: false; code: "NOT_FOUND" | "CONFLICT" | "PAYMENT_REQUIRED" | "INTERNAL_ERROR"; message: string };

/**
 * `periodStart` is the period the unit was actually charged to. It is carried
 * back to the caller so a refund targets that same period: consuming at
 * 23:59 UTC and failing at 00:00 would otherwise refund against the new
 * month, leaving the charged counter untouched and decrementing a fresh one.
 */
export type ConsumeQuotaOutcome = { consumed: boolean; ok: boolean; periodStart: string | null };

/**
 * Attempts to consume one unit of the caller's free monthly fox-conversation
 * quota via the atomic `consume_quota` Postgres function (see
 * supabase/migrations/20260812110000_consume_quota.sql). Never does a
 * select-then-update against usage_counters — that would race under
 * concurrent requests, which is exactly what this function must not do.
 *
 * Returns `consumed: true` when a unit was actually taken, `ok: false` when
 * the free quota is exhausted (or the RPC itself failed — fail closed).
 * Exported so routes/fox-search.ts's retry-of-a-completed-conversation path
 * (which also charges quota, per step-3a's retry policy) shares this exact
 * logic instead of re-implementing the RPC call.
 */
export async function consumeFoxConversationQuota(supabase: SupabaseClient<Database>, userId: string): Promise<ConsumeQuotaOutcome> {
	const { periodStart, periodEnd } = getUtcMonthPeriod();
	const { data, error } = await supabase.rpc("consume_quota", {
		p_user_id: userId,
		p_quota_key: FOX_CONVERSATION_QUOTA_KEY,
		p_period_start: periodStart,
		p_period_end: periodEnd,
		p_limit: FREE_FOX_CONVERSATION_LIMIT,
	});
	if (error) {
		// Fail closed: an unreadable quota state must never be treated as "has quota".
		console.error(`[fox-conversation-quota] consume_quota RPC failed for user ${userId}:`, error);
		return { consumed: false, ok: false, periodStart: null };
	}
	if (data === null) {
		// No row returned: the caller was already at or above the limit.
		return { consumed: false, ok: false, periodStart: null };
	}
	return { consumed: true, ok: true, periodStart };
}

/**
 * `consumeFoxConversationQuota`, but a no-op when `bypassQuota` (active
 * entitlement) is true.
 */
async function consumeQuotaOrBypass(
	supabase: SupabaseClient<Database>,
	userId: string,
	bypassQuota: boolean,
): Promise<ConsumeQuotaOutcome> {
	if (bypassQuota) return { consumed: false, ok: true, periodStart: null };
	return consumeFoxConversationQuota(supabase, userId);
}

/** Recheck only the new rehearsal permit at each awaited operation boundary. */
function isRecordingWindowStillActive(
	window: FoxConversationRecordingWindow,
	userA: string,
	userB: string,
): boolean {
	return (window.kind !== "active" && window.kind !== "judge" && window.kind !== "registered-judge")
		|| isFoxConversationGenerationAllowed(window, userA, userB);
}

/**
 * Refunds a quota unit. `periodStart` must be the value returned by the
 * `consumeFoxConversationQuota` call being compensated -- never a freshly
 * computed one, which would target the wrong month across a rollover.
 */
export async function refundFoxConversationQuota(
	supabase: SupabaseClient<Database>,
	userId: string,
	periodStart: string,
): Promise<void> {
	const { error } = await supabase.rpc("refund_quota", {
		p_user_id: userId,
		p_quota_key: FOX_CONVERSATION_QUOTA_KEY,
		p_period_start: periodStart,
	});
	if (error) {
		console.error(`[requestFoxConversation] refund_quota RPC failed for user ${userId}:`, error);
	}
}

/**
 * Best-effort cleanup for a conversation that cannot be started.  Both
 * status writes are attempted even when one fails, and their returned errors
 * (as well as thrown errors) are collapsed to one constant log message.
 */
async function markFoxConversationFailed(
	supabase: SupabaseClient<Database>,
	conversationId: string,
	matchId: string,
	includeUpdatedAt = true,
): Promise<void> {
	let conversationUpdateFailed = false;
	try {
		const { error } = await supabase.from("fox_conversations").update({ status: "failed" }).eq("id", conversationId);
		conversationUpdateFailed = Boolean(error);
	} catch {
		conversationUpdateFailed = true;
	}

	let matchUpdateFailed = false;
	try {
		const patch = includeUpdatedAt
			? { status: "fox_conversation_failed" as const, updated_at: new Date().toISOString() }
			: { status: "fox_conversation_failed" as const };
		const { error } = await supabase.from("matches").update(patch).eq("id", matchId);
		matchUpdateFailed = Boolean(error);
	} catch {
		matchUpdateFailed = true;
	}

	if (conversationUpdateFailed || matchUpdateFailed) {
		console.error("[requestFoxConversation] failed to clean up fox conversation");
	}
}

/**
 * Starts the FoxConversationDO for a freshly created conversation, using the
 * same `/init` fetch contract as routes/fox-search.ts. Returns whether the
 * start succeeded; on the Workers path (env.FOX_CONVERSATION present) a
 * thrown error or non-2xx response counts as failure. On the local-dev path
 * (no DO binding) the conversation runs in the background and is always
 * reported as "started" — matching the existing fox-search.ts fallback,
 * which has the same limitation.
 */
async function startFoxConversationDO(
	supabase: SupabaseClient<Database>,
	env: Env["Bindings"],
	conversationId: string,
	matchId: string,
	recordingWindow: FoxConversationRecordingWindow,
): Promise<boolean> {
	if (env.FOX_CONVERSATION) {
		try {
			const doId = env.FOX_CONVERSATION.idFromName(conversationId);
			const stub = env.FOX_CONVERSATION.get(doId);
			const response = await stub.fetch(
				new Request("https://do/init", {
					method: "POST",
					body: JSON.stringify({ conversationId, matchId }),
				}),
			);
			return response.ok;
		} catch {
			console.error("[requestFoxConversation] Failed to start fox conversation");
			return false;
		}
	}

	// Local dev / no DO binding: fall back to running inline in the background.
	// We cannot observe failure synchronously here (same limitation as the
	// existing fox-search.ts fallback), so this path is always reported as
	// "started"; a background failure still marks the conversation/match
	// failed via runFoxConversation's own error handling, it just won't
	// trigger a quota refund.
	const apiKey = env.MISTRAL_API_KEY;
	if (!apiKey) {
		// Neither a Durable Object binding nor an API key: nothing can run this
		// conversation. Report failure so the caller refunds the quota instead
		// of charging for a conversation that will never start.
		console.error("[requestFoxConversation] No FOX_CONVERSATION binding and no MISTRAL_API_KEY: cannot run conversation");
		return false;
	}
	{
		const { runFoxConversation } = await import("./fox-conversation");
		void runFoxConversation(supabase, apiKey, conversationId, recordingWindow).catch(async () => {
			console.error("[requestFoxConversation] Background conversation failed");
			await markFoxConversationFailed(supabase, conversationId, matchId, false);
		});
	}
	return true;
}

/**
 * Creates and starts a compatibility fox_conversation for `matchId` on
 * behalf of `userId`, enforcing participant authorization, the block list,
 * match status, entitlement/quota, and the DO-start-failure refund.
 *
 * Order of checks matters (cheapest / least-sensitive-info-leaking first):
 *   1. participant check (404 for both "no such match" and "not yours" —
 *      never confirms a match's existence to a non-participant)
 *   2. blocks check (404 — never reveals that a block exists)
 *   3. match status must be 'pending' (409 otherwise)
 *   4. no existing compatibility conversation for this match (409)
 *   5. entitlements.is_active bypasses quota; otherwise consume_quota
 *   6. create fox_conversations, start the DO, record requested_at/_by
 */
export async function requestFoxConversation(
	supabase: SupabaseClient<Database>,
	env: Env["Bindings"],
	userId: string,
	matchId: string,
): Promise<RequestFoxConversationResult> {
	const { data: match, error: matchError } = await supabase
		.from("matches")
		.select("id, user_a_id, user_b_id, status")
		.eq("id", matchId)
		.single();
	if (matchError || !match || (match.user_a_id !== userId && match.user_b_id !== userId)) {
		return { ok: false, code: "NOT_FOUND", message: "Match not found" };
	}

	const partnerId = match.user_a_id === userId ? match.user_b_id : match.user_a_id;
	const recordingWindow = await resolveFoxConversationGenerationWindow(supabase, env, match.user_a_id, match.user_b_id, userId);
	if (!isFoxConversationGenerationAllowed(recordingWindow, match.user_a_id, match.user_b_id)) {
		return { ok: false, code: "CONFLICT", message: "Conversation unavailable" };
	}
	const agePair = await checkVerifiedPair(supabase, userId, partnerId);
	if (agePair.ok === false) {
		return agePair.reason === "error"
			? { ok: false, code: "INTERNAL_ERROR", message: "Failed to verify match eligibility" }
			: { ok: false, code: "NOT_FOUND", message: "Match not found" };
	}
	const { data: blockRow, error: blockError } = await supabase
		.from("blocks")
		.select("id")
		.or(`and(blocker_id.eq.${userId},blocked_id.eq.${partnerId}),and(blocker_id.eq.${partnerId},blocked_id.eq.${userId})`)
		.limit(1)
		.maybeSingle();
	if (blockError) {
		// Fail closed. A transient failure of the block lookup must never be
		// read as "not blocked": this app can put these two people in a room
		// together, so an unreadable block list has to stop the request, not
		// wave it through. INTERNAL_ERROR rather than NOT_FOUND, so the answer
		// still carries no information about whether a block exists.
		console.error(`[requestFoxConversation] blocks lookup failed for match ${matchId}:`, blockError);
		return { ok: false, code: "INTERNAL_ERROR", message: "Failed to verify match eligibility" };
	}
	if (blockRow) {
		return { ok: false, code: "NOT_FOUND", message: "Match not found" };
	}

	if (match.status !== "pending") {
		return { ok: false, code: "CONFLICT", message: "Match is not eligible for a new fox conversation" };
	}

	let existingConv: { id: string } | null = null;
	try {
		const result = await supabase
			.from("fox_conversations")
			.select("id")
			.eq("match_id", matchId)
			.eq("purpose", "compatibility")
			.maybeSingle();
		if (result.error) {
			console.error("[requestFoxConversation] failed to read existing fox conversation");
			return { ok: false, code: "INTERNAL_ERROR", message: "Failed to verify fox conversation eligibility" };
		}
		existingConv = result.data;
	} catch {
		console.error("[requestFoxConversation] failed to read existing fox conversation");
		return { ok: false, code: "INTERNAL_ERROR", message: "Failed to verify fox conversation eligibility" };
	}
	if (existingConv) {
		return { ok: false, code: "CONFLICT", message: "A fox conversation already exists for this match" };
	}

	let entitlement: { is_active: boolean } | null = null;
	try {
		const result = await supabase.from("entitlements").select("is_active").eq("user_id", userId).maybeSingle();
		if (result.error) {
			console.error("[requestFoxConversation] failed to read entitlement");
			return { ok: false, code: "INTERNAL_ERROR", message: "Failed to verify fox conversation entitlement" };
		}
		entitlement = result.data;
	} catch {
		console.error("[requestFoxConversation] failed to read entitlement");
		return { ok: false, code: "INTERNAL_ERROR", message: "Failed to verify fox conversation entitlement" };
	}
	const hasActiveEntitlement = entitlement?.is_active === true;

	if (!isRecordingWindowStillActive(recordingWindow, match.user_a_id, match.user_b_id)) {
		return { ok: false, code: "CONFLICT", message: "Conversation unavailable" };
	}
	const quotaResult = await consumeQuotaOrBypass(supabase, userId, hasActiveEntitlement);
	if (!quotaResult.ok) {
		// No internal state (used_count, limit, period) in the response — an
		// attacker probing quota state must learn nothing beyond "blocked".
		return { ok: false, code: "PAYMENT_REQUIRED", message: "Fox conversation quota reached" };
	}
	if (!isRecordingWindowStillActive(recordingWindow, match.user_a_id, match.user_b_id)) {
		if (quotaResult.consumed && quotaResult.periodStart) {
			await refundFoxConversationQuota(supabase, userId, quotaResult.periodStart);
		}
		return { ok: false, code: "CONFLICT", message: "Conversation unavailable" };
	}
	const { data: conv, error: convError } = await supabase
		.from("fox_conversations")
		// total_rounds: 10 explicit — the column default was 15 (schema), but
		// this is the value the engine has actually always run against (see
		// step-03d D-1). Explicit here so the row is correct even if the
		// column default is ever changed again.
		.insert({ match_id: matchId, status: "pending", purpose: "compatibility", total_rounds: 10 })
		.select("id")
		.single();
	if (convError || !conv) {
		if (quotaResult.consumed && quotaResult.periodStart) await refundFoxConversationQuota(supabase, userId, quotaResult.periodStart);
		console.error(`[requestFoxConversation] Failed to create fox_conversations row for match ${matchId}:`, convError);
		return { ok: false, code: "INTERNAL_ERROR", message: "Failed to create fox conversation" };
	}
	if (!isRecordingWindowStillActive(recordingWindow, match.user_a_id, match.user_b_id)) {
		// The insert began while authorized but crossed the expiry while its
		// response was in flight. Compensate the partial start; never start paid
		// work under an expired rehearsal window.
		if (quotaResult.consumed && quotaResult.periodStart) {
			await refundFoxConversationQuota(supabase, userId, quotaResult.periodStart);
		}
		await markFoxConversationFailed(supabase, conv.id, matchId);
		return { ok: false, code: "CONFLICT", message: "Conversation unavailable" };
	}

	if (!isRecordingWindowStillActive(recordingWindow, match.user_a_id, match.user_b_id)) {
		if (quotaResult.consumed && quotaResult.periodStart) {
			await refundFoxConversationQuota(supabase, userId, quotaResult.periodStart);
		}
		await markFoxConversationFailed(supabase, conv.id, matchId);
		return { ok: false, code: "CONFLICT", message: "Conversation unavailable" };
	}
	let matchStatusUpdateFailed = false;
	try {
		const { error: matchStatusError } = await supabase
			.from("matches")
			.update({
				status: "fox_conversation_in_progress",
				fox_conversation_requested_at: new Date().toISOString(),
				fox_conversation_requested_by: userId,
				updated_at: new Date().toISOString(),
			})
			.eq("id", matchId);
		matchStatusUpdateFailed = Boolean(matchStatusError);
	} catch {
		matchStatusUpdateFailed = true;
	}
	if (matchStatusUpdateFailed) {
		if (quotaResult.consumed && quotaResult.periodStart) await refundFoxConversationQuota(supabase, userId, quotaResult.periodStart);
		await markFoxConversationFailed(supabase, conv.id, matchId);
		console.error("[requestFoxConversation] failed to mark match in progress");
		return { ok: false, code: "INTERNAL_ERROR", message: "Failed to start fox conversation" };
	}
	if (!isRecordingWindowStillActive(recordingWindow, match.user_a_id, match.user_b_id)) {
		if (quotaResult.consumed && quotaResult.periodStart) {
			await refundFoxConversationQuota(supabase, userId, quotaResult.periodStart);
		}
		await markFoxConversationFailed(supabase, conv.id, matchId);
		return { ok: false, code: "CONFLICT", message: "Conversation unavailable" };
	}

	const started = await startFoxConversationDO(supabase, env, conv.id, matchId, recordingWindow);
	const windowStillActiveAfterStart = isRecordingWindowStillActive(recordingWindow, match.user_a_id, match.user_b_id);
	if (!started || !windowStillActiveAfterStart) {
		// The conversation was created and the user was charged for it, but it
		// never actually ran: refund the unit and mark both rows failed so the
		// user isn't left with a phantom "in progress" match.
		if (quotaResult.consumed && quotaResult.periodStart) await refundFoxConversationQuota(supabase, userId, quotaResult.periodStart);
		await markFoxConversationFailed(supabase, conv.id, matchId);
		return {
			ok: false,
			code: windowStillActiveAfterStart ? "INTERNAL_ERROR" : "CONFLICT",
			message: windowStillActiveAfterStart ? "Failed to start fox conversation" : "Conversation unavailable",
		};
	}

	return { ok: true, conversationId: conv.id };
}
