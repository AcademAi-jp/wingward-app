import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import {
	checkFoxConversationCurrentAccess,
	readFoxConversationPublicAccess,
	type FoxConversationCurrentAccessResult,
	type FoxConversationPublicAccessResult,
} from "../services/fox-conversation-access";

const foxConversations = new Hono<Env>();

function publicAccessFailure(
	c: Parameters<typeof jsonError>[0],
	result: FoxConversationPublicAccessResult | FoxConversationCurrentAccessResult,
) {
	if (result.ok === true) return null;
	if (result.ok === false && result.reason === "not_found") return jsonError(c, "NOT_FOUND", "Conversation not found");
	if (result.ok === false && result.reason === "forbidden") return jsonError(c, "FORBIDDEN", "Access denied");
	return jsonError(c, "INTERNAL_ERROR", "Conversation access is unavailable");
}

function samePublicSnapshot(
	initial: Extract<FoxConversationPublicAccessResult, { ok: true }>,
	latest: Extract<FoxConversationCurrentAccessResult, { ok: true }>,
): boolean {
	return (
		latest.conversationStatus === initial.conversationStatus &&
		latest.matchStatus === initial.matchStatus &&
		latest.purpose === initial.purpose &&
		latest.matchId === initial.expectation.matchId &&
		latest.userA === initial.expectation.userA &&
		latest.userB === initial.expectation.userB
	);
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPublicHistoryRow(value: unknown, userA: string, userB: string): value is {
	id: string;
	speaker_user_id: string;
	content: string;
	round_number: number;
	created_at: string;
} {
	return (
		isRecord(value) &&
		typeof value.id === "string" &&
		value.id.length > 0 &&
		typeof value.speaker_user_id === "string" &&
		(value.speaker_user_id === userA || value.speaker_user_id === userB) &&
		typeof value.content === "string" &&
		Number.isInteger(value.round_number) &&
		(value.round_number as number) >= 0 &&
		typeof value.created_at === "string" &&
		value.created_at.length > 0
	);
}

/** GET /api/fox-conversations/:id */
foxConversations.get("/:id", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const supabase = getSupabaseClient(c.env);
	let initial: FoxConversationPublicAccessResult;
	try {
		initial = await readFoxConversationPublicAccess(supabase, id, userId);
	} catch {
		return jsonError(c, "INTERNAL_ERROR", "Conversation access is unavailable");
	}
	const initialFailure = publicAccessFailure(c, initial);
	if (initialFailure) return initialFailure;
	if (!initial.ok) return jsonError(c, "INTERNAL_ERROR", "Conversation access is unavailable");

	let latest: FoxConversationCurrentAccessResult;
	try {
		latest = await checkFoxConversationCurrentAccess(supabase, initial.expectation, "public_read");
	} catch {
		return jsonError(c, "INTERNAL_ERROR", "Conversation access is unavailable");
	}
	const latestFailure = publicAccessFailure(c, latest);
	if (latestFailure) return latestFailure;
	if (!latest.ok || !samePublicSnapshot(initial, latest)) {
		return jsonError(c, "FORBIDDEN", "Access denied");
	}
	return jsonData(c, initial.publicDetail);
});

/** GET /api/fox-conversations/:id/messages */
foxConversations.get("/:id/messages", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const limit = Math.min(Number(c.req.query("limit")) || 50, 100);
	const cursor = c.req.query("cursor");
	const supabase = getSupabaseClient(c.env);
	let initial: FoxConversationPublicAccessResult;
	try {
		initial = await readFoxConversationPublicAccess(supabase, id, userId);
	} catch {
		return jsonError(c, "INTERNAL_ERROR", "Conversation access is unavailable");
	}
	const initialFailure = publicAccessFailure(c, initial);
	if (initialFailure) return initialFailure;
	if (!initial.ok) return jsonError(c, "INTERNAL_ERROR", "Conversation access is unavailable");

	let q = supabase
		.from("fox_conversation_messages")
		.select("id, speaker_user_id, content, round_number, created_at")
		.eq("conversation_id", id)
		.order("round_number");
	if (cursor) q = q.lt("created_at", cursor);
	let messageResult: { data: unknown; error: unknown };
	try {
		messageResult = await q.limit(limit + 1) as unknown as { data: unknown; error: unknown };
	} catch {
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch conversation messages");
	}
	const { data: rows, error: rowsError } = messageResult;
	if (rowsError || !rows) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch conversation messages");
	if (!Array.isArray(rows) || !rows.every((row) => isPublicHistoryRow(row, initial.expectation.userA, initial.expectation.userB))) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch conversation messages");
	}

	let latest: FoxConversationCurrentAccessResult;
	try {
		latest = await checkFoxConversationCurrentAccess(supabase, initial.expectation, "public_read");
	} catch {
		return jsonError(c, "INTERNAL_ERROR", "Conversation access is unavailable");
	}
	const latestFailure = publicAccessFailure(c, latest);
	if (latestFailure) return latestFailure;
	if (!latest.ok || !samePublicSnapshot(initial, latest)) {
		return jsonError(c, "FORBIDDEN", "Access denied");
	}

	const hasMore = (rows?.length ?? 0) > limit;
	const list = (rows ?? []).slice(0, limit);
	const formatted = list.map((m) => ({
		id: m.id,
		speaker: m.speaker_user_id === initial.viewerId ? "my_fox" : "partner_fox",
		content: m.content,
		round_number: m.round_number,
		created_at: m.created_at,
	}));
	return c.json({
		data: formatted,
		next_cursor: hasMore ? list[list.length - 1]?.created_at ?? null : null,
		has_more: hasMore,
	});
});

export default foxConversations;
