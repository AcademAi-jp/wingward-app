import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { z } from "zod";

const moderation = new Hono<Env>();

const blockSchema = z.object({ user_id: z.string().uuid() });
const reportSchema = z.object({
	user_id: z.string().uuid(),
	reason: z.enum(["harassment", "inappropriate", "spam", "other"]),
	description: z.string().optional(),
	message_id: z.string().uuid().optional(),
});

/** POST /api/moderation/blocks */
moderation.post("/blocks", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const parsed = blockSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	if (parsed.data.user_id === userId) return jsonError(c, "BAD_REQUEST", "Cannot block self");
	const supabase = getSupabaseClient(c.env);
	const { error: blockError } = await supabase.from("blocks").upsert(
		{ blocker_id: userId, blocked_id: parsed.data.user_id },
		{ onConflict: "blocker_id,blocked_id" },
	);
	if (blockError) {
		console.error("[moderation] block upsert failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to block user");
	}
	const targetId = parsed.data.user_id;
	const { data: match, error: matchError } = await supabase
		.from("matches")
		.select("id")
		.or(`and(user_a_id.eq.${userId},user_b_id.eq.${targetId}),and(user_a_id.eq.${targetId},user_b_id.eq.${userId})`)
		.limit(1)
		.maybeSingle();
	if (matchError) {
		console.error("[moderation] block match lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify block target");
	}
	if (match) {
		const { error: roomError } = await supabase.from("direct_chat_rooms").update({ status: "closed" }).eq("match_id", match.id).eq("status", "active");
		if (roomError) {
			console.error("[moderation] direct chat room close failed");
			return jsonError(c, "INTERNAL_ERROR", "Failed to close direct chat room");
		}
	}
	return jsonData(c, { message: "User blocked" });
});

/** DELETE /api/moderation/blocks/:userId */
moderation.delete("/blocks/:userId", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const targetId = c.req.param("userId");
	const supabase = getSupabaseClient(c.env);
	const { error } = await supabase.from("blocks").delete().eq("blocker_id", userId).eq("blocked_id", targetId);
	if (error) return jsonError(c, "INTERNAL_ERROR", "Failed to unblock user");
	return jsonData(c, { message: "User unblocked" });
});

/** POST /api/moderation/reports */
moderation.post("/reports", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const parsed = reportSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	const supabase = getSupabaseClient(c.env);
	const { data: report, error } = await supabase
		.from("reports")
		.insert({
			reporter_id: userId,
			reported_id: parsed.data.user_id,
			reason: parsed.data.reason,
			description: parsed.data.description,
			message_id: parsed.data.message_id,
		})
		.select("id, status")
		.single();
	if (error) return jsonError(c, "INTERNAL_ERROR", "Failed to report");
	return jsonData(c, { report_id: report.id, status: report.status });
});

export default moderation;
