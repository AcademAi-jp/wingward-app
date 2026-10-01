import { Hono } from "hono";
import { z } from "zod";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { jsonData, jsonError } from "../lib/response";
import { executeMatching } from "../services/matching";
import { runFoxConversation } from "../services/fox-conversation";
import { runDailyBatch } from "../services/daily-batch";
import { getBatchTimeZone, getTodayInTimeZone } from "../lib/date";

const internal = new Hono<Env>();

/** Minutes after which an in_progress fox_conversation is considered stuck */
const STUCK_IN_PROGRESS_MINUTES = 2;

async function checkedSupabase<T>(
	operation: PromiseLike<{ data: T; error: unknown | null }>,
	operationName: string,
): Promise<T> {
	const { data, error } = await operation;
	if (error) {
		console.error(`[internal] Supabase operation failed: ${operationName}`);
		throw new Error(`Internal Supabase operation failed: ${operationName}`);
	}
	return data;
}

/** POST /api/internal/matching/execute - run matching and create match candidates (fox_conversations are created lazily via POST /api/matches/:id/fox-conversation) */
internal.post("/matching/execute", async (c) => {
	const supabase = getSupabaseClient(c.env);
	const count = await executeMatching(supabase, 10);
	return jsonData(c, { message: "Matching executed", count });
});

/** POST /api/internal/fox-conversations/execute - run one or all pending fox conversations */
internal.post("/fox-conversations/execute", async (c) => {
	const supabase = getSupabaseClient(c.env);
	const apiKey = c.env.MISTRAL_API_KEY;
	if (!apiKey) return jsonError(c, "INTERNAL_ERROR", "Mistral API not configured");
	const body = (await c.req.json().catch(() => ({}))) as { conversation_id?: string };
	if (body.conversation_id) {
		await runFoxConversation(supabase, apiKey, body.conversation_id);
		return jsonData(c, { message: "Conversation executed" });
	}
	const pending = await checkedSupabase(supabase
		.from("fox_conversations")
		.select("id")
		.in("status", ["pending"])
		.limit(5), "load pending conversations");
	for (const row of pending ?? []) {
		await runFoxConversation(supabase, apiKey, row.id);
	}
	return jsonData(c, { message: "Batch executed", count: pending?.length ?? 0 });
});

/** POST /api/internal/chat-requests/expire */
internal.post("/chat-requests/expire", async (c) => {
	const supabase = getSupabaseClient(c.env);
	const data = await checkedSupabase(supabase
		.from("chat_requests")
		.update({ status: "expired" })
		.eq("status", "pending")
		.lt("expires_at", new Date().toISOString())
		.select("id, match_id"), "expire chat requests");
	// Also update corresponding matches status
	for (const req of data ?? []) {
		await checkedSupabase(supabase
			.from("matches")
			.update({ status: "chat_request_expired", updated_at: new Date().toISOString() })
			.eq("id", req.match_id)
			.eq("status", "direct_chat_requested"), "mark expired chat request match");
	}
	return jsonData(c, { message: "Expired", count: data?.length ?? 0 });
});

/**
 * POST /api/internal/fox-conversations/retry-failed - reset failed fox conversations for retry.
 * Operator tool behind requireInternalAuth (shared secret), not user-facing: deliberately does
 * not touch usage_counters. Quota only applies to the user-initiated paths
 * (POST /api/matches/:id/fox-conversation and POST /api/fox-search/retry/:matchId).
 */
internal.post("/fox-conversations/retry-failed", async (c) => {
	const supabase = getSupabaseClient(c.env);
	const failed = await checkedSupabase(supabase
		.from("fox_conversations")
		.select("id, match_id")
		.eq("status", "failed")
		.limit(10), "load failed conversations");
	if (!failed?.length) return jsonData(c, { message: "No failed conversations", count: 0 });
	let resetCount = 0;
	for (const conv of failed) {
		// Delete existing messages for a clean restart
		await checkedSupabase(supabase.from("fox_conversation_messages").delete().eq("conversation_id", conv.id), "delete failed conversation messages");
		// Reset fox_conversation to pending
		await checkedSupabase(supabase
			.from("fox_conversations")
			.update({ status: "pending", current_round: 0, started_at: null, completed_at: null, conversation_analysis: null })
			.eq("id", conv.id), "reset failed conversation");
		// Reset match status to fox_conversation_in_progress
		await checkedSupabase(supabase
			.from("matches")
			.update({ status: "fox_conversation_in_progress", updated_at: new Date().toISOString() })
			.eq("id", conv.match_id), "reset failed conversation match");
		resetCount++;
	}
	return jsonData(c, { message: "Failed conversations reset", count: resetCount });
});

/** POST /api/internal/data-integrity/check - detect and repair inconsistent data */
internal.post("/data-integrity/check", async (c) => {
	const supabase = getSupabaseClient(c.env);
	const fixes: string[] = [];

	// 1. Matches with fox_conversation_in_progress but no fox_conversation
	const inProgressMatches = await checkedSupabase(supabase
		.from("matches")
		.select("id")
		.eq("status", "fox_conversation_in_progress"), "load in-progress matches");
	for (const m of inProgressMatches ?? []) {
		const fc = await checkedSupabase(supabase
			.from("fox_conversations")
			.select("id")
			.eq("match_id", m.id)
			.limit(1), "load match conversation");
		if (!fc?.length) {
			await checkedSupabase(supabase.from("matches").update({ status: "fox_conversation_failed", updated_at: new Date().toISOString() }).eq("id", m.id), "repair match without conversation");
			fixes.push(`Match ${m.id}: fox_conversation_in_progress without fox_conversation -> fox_conversation_failed`);
		}
	}

	// 2. Matches with direct_chat_requested but chat_request is expired/declined
	const requestedMatches = await checkedSupabase(supabase
		.from("matches")
		.select("id")
		.eq("status", "direct_chat_requested"), "load requested matches");
	for (const m of requestedMatches ?? []) {
		const cr = await checkedSupabase(supabase
			.from("chat_requests")
			.select("id, status")
			.eq("match_id", m.id)
			.maybeSingle(), "load chat request state");
		if (cr?.status === "expired") {
			await checkedSupabase(supabase.from("matches").update({ status: "chat_request_expired", updated_at: new Date().toISOString() }).eq("id", m.id), "repair expired chat request match");
			fixes.push(`Match ${m.id}: direct_chat_requested with expired chat_request -> chat_request_expired`);
		} else if (cr?.status === "declined") {
			await checkedSupabase(supabase.from("matches").update({ status: "chat_request_declined", updated_at: new Date().toISOString() }).eq("id", m.id), "repair declined chat request match");
			fixes.push(`Match ${m.id}: direct_chat_requested with declined chat_request -> chat_request_declined`);
		}
	}

	// 3. Matches with pending but fox_conversation is failed
	const pendingMatches = await checkedSupabase(supabase
		.from("matches")
		.select("id")
		.eq("status", "pending"), "load pending matches");
	for (const m of pendingMatches ?? []) {
		const fc = await checkedSupabase(supabase
			.from("fox_conversations")
			.select("id, status")
			.eq("match_id", m.id)
			.maybeSingle(), "load pending match conversation");
		if (fc?.status === "failed") {
			await checkedSupabase(supabase.from("matches").update({ status: "fox_conversation_failed", updated_at: new Date().toISOString() }).eq("id", m.id), "repair pending match");
			fixes.push(`Match ${m.id}: pending with failed fox_conversation -> fox_conversation_failed`);
		}
	}

	// 4. Fox conversations stuck in_progress (started_at older than threshold)
	const stuckCutoff = new Date(Date.now() - STUCK_IN_PROGRESS_MINUTES * 60 * 1000).toISOString();
	const stuckConvs = await checkedSupabase(supabase
		.from("fox_conversations")
		.select("id, match_id")
		.eq("status", "in_progress")
		.lt("started_at", stuckCutoff), "load stuck conversations");
	for (const conv of stuckConvs ?? []) {
		await checkedSupabase(supabase
			.from("fox_conversations")
			.update({ status: "failed" })
			.eq("id", conv.id), "fail stuck conversation");
		await checkedSupabase(supabase
			.from("matches")
			.update({ status: "fox_conversation_failed", updated_at: new Date().toISOString() })
			.eq("id", conv.match_id), "fail stuck conversation match");
		fixes.push(`Fox conversation ${conv.id} (match ${conv.match_id}): in_progress > ${STUCK_IN_PROGRESS_MINUTES}min -> failed`);
	}

	return jsonData(c, { message: "Integrity check completed", fixes_applied: fixes.length, fixes });
});

// Daily matching uses one durable coordinator for first run and retries.
const batchDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((date) => {
	const parsed = new Date(`${date}T00:00:00Z`);
	return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === date;
});
const batchRequestSchema = z.object({ batch_date: batchDateSchema.optional() }).strict();

async function executeDurableBatch(c: Parameters<typeof jsonData>[0]) {
	if (c.env.DURABLE_DAILY_BATCH_ENABLED !== "enabled") {
		return jsonError(c, "INTERNAL_ERROR", "Daily matching is not connected", 503);
	}
	let raw: unknown;
	try { raw = await c.req.json(); } catch { return jsonError(c, "BAD_REQUEST", "Invalid request"); }
	const body = batchRequestSchema.safeParse(raw);
	if (!body.success) return jsonError(c, "BAD_REQUEST", "Invalid request");
	try {
		const supabase = getSupabaseClient(c.env);
		const result = await runDailyBatch(supabase, c.env.MISTRAL_API_KEY ?? "", getBatchTimeZone(c.env), body.data.batch_date, {
			durableEnabled: true,
			foxConversationDO: c.env.FOX_CONVERSATION,
		});
		return jsonData(c, {
			message: "Daily batch processed",
			batch_date: result.batchDate,
			status: result.status,
			conversation_status: result.conversationStatus,
			conversations_pending: result.conversationsPending,
			total_matches: result.totalMatches,
			conversations_completed: result.conversationsCompleted,
			conversations_failed: result.conversationsFailed,
		});
	} catch {
		console.error("[internal/daily-batch] batch failed");
		return jsonError(c, "INTERNAL_ERROR", "An unexpected error occurred");
	}
}

internal.post("/daily-batch/execute", executeDurableBatch);
// A retry resumes the same date/lease/checkpoint; it never deletes prior turns.
internal.post("/daily-batch/retry", executeDurableBatch);

internal.get("/daily-batch/status", async (c) => {
	const supplied = c.req.query("date");
	if (supplied !== undefined && !batchDateSchema.safeParse(supplied).success) {
		return jsonError(c, "BAD_REQUEST", "Invalid request");
	}
	try {
		const date = supplied ?? getTodayInTimeZone(getBatchTimeZone(c.env));
		const result = await getSupabaseClient(c.env).from("daily_match_batches")
			.select("batch_date,status,total_matches,conversations_completed,conversations_failed,completed_at")
			.eq("batch_date", date).maybeSingle();
		if (result.error) throw new Error("Batch status unavailable");
		if (!result.data) return jsonData(c, { batch_date: date, status: "not_started", total_matches: 0,
			conversations_completed: 0, conversations_failed: 0 });
		const row = result.data;
		if (!['pending','matching','conversations_running','completed','failed'].includes(row.status)
			|| ![row.total_matches,row.conversations_completed,row.conversations_failed].every((value) => Number.isInteger(value) && value >= 0)
			|| (row.status === 'completed' && !row.completed_at)) throw new Error("Invalid batch status");
		return jsonData(c, row);
	} catch {
		console.error("[internal/daily-batch] status unavailable");
		return jsonError(c, "INTERNAL_ERROR", "An unexpected error occurred");
	}
});

export default internal;
