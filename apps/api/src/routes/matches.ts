import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { requestFoxConversation } from "../services/fox-conversation-request";

const matches = new Hono<Env>();

/**
 * POST /api/matches/:id/fox-conversation — lazily create and start the
 * compatibility fox_conversation for a match. The only place a compatibility
 * fox_conversations row gets created (see services/fox-conversation-request.ts).
 */
matches.post("/:id/fox-conversation", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const matchId = c.req.param("id");
	const supabase = getSupabaseClient(c.env);

	const result = await requestFoxConversation(supabase, c.env, userId, matchId);
	if (result.ok === false) {
		if (result.code === "PAYMENT_REQUIRED") {
			// Deliberately no used_count/limit/period in the body.
			return jsonError(c, "PAYMENT_REQUIRED", "Free fox-conversation quota reached for this month");
		}
		return jsonError(c, result.code, result.message);
	}

	return jsonData(c, { fox_conversation_id: result.conversationId, match_id: matchId }, 201);
});

export default matches;
