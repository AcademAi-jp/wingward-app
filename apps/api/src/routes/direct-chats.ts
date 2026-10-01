import { resolveAuthorizedPeerProfilePhotoUrl } from "../lib/profile-photo";
import { getProfilePhotoAdapter } from "../services/onboarding-settings";
import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { checkVerifiedPair, filterVerifiedMatches } from "../services/match-age-access";
import { persistDirectChatMessage, recoverDirectChatMessageSend } from "../services/direct-chat-message-send";
import { sha256Hex } from "../services/message-idempotency";
import { z } from "zod";

const directChats = new Hono<Env>();

const postMessageSchema = z.object({
	content: z.string().min(1).max(1000),
	idempotency_key: z.string().uuid().optional(),
});
const recoverMessageSendSchema = z.object({
	idempotency_key: z.string().uuid(),
	content_sha256: z.string().regex(/^[0-9a-f]{64}$/),
});

/** GET /api/direct-chats */
directChats.get("/", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const { data: profile, error: profileError } = await supabase
		.from("user_profiles")
		.select("notification_seen_at")
		.eq("id", userId)
		.single();
	if (profileError || !profile) {
		console.error("[direct-chats] failed to read notification metadata");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch chats");
	}
	const notificationSeenAt = profile?.notification_seen_at ?? null;

	const { data: myMatches, error: matchesError } = await supabase
		.from("matches")
		.select("id, user_a_id, user_b_id")
		.or(`user_a_id.eq.${userId},user_b_id.eq.${userId}`);
	if (matchesError || !myMatches) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch chats");
	const verifiedMatches = await filterVerifiedMatches(supabase, myMatches ?? []);
	if (!verifiedMatches.ok) return jsonError(c, "INTERNAL_ERROR", "Failed to verify chat eligibility");
	const ageVerifiedMatches = verifiedMatches.rows;
	if (ageVerifiedMatches.length === 0) return jsonData(c, []);
	const { data: blockRows, error: blocksError } = await supabase
		.from("blocks")
		.select("blocker_id, blocked_id")
		.or(`blocker_id.eq.${userId},blocked_id.eq.${userId}`);
	if (blocksError || !blockRows) {
		console.error("[direct-chats] failed to read block state");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch chats");
	}
	const blockedProfileIds = new Set(
		blockRows.map((row) => (row.blocker_id === userId ? row.blocked_id : row.blocker_id)),
	);
	const visibleMatches = ageVerifiedMatches.filter((match) => {
		const partnerId = match.user_a_id === userId ? match.user_b_id : match.user_a_id;
		return !blockedProfileIds.has(partnerId);
	});
	if (visibleMatches.length === 0) return jsonData(c, []);
	const matchIds = visibleMatches.map((m) => m.id);
	const { data: rooms, error: roomsError } = await supabase
		.from("direct_chat_rooms")
		.select("id, match_id")
		.eq("status", "active")
		.in("match_id", matchIds);
	if (roomsError || !rooms) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch chats");
	const roomIdByMatch = new Map(visibleMatches.map((m) => [m.id, m]));
	const roomsForUser = rooms;
	if (roomsForUser.length === 0) return jsonData(c, []);
	const partnerIds = roomsForUser.map((r) => {
		const m = roomIdByMatch.get(r.match_id);
		return m && (m.user_a_id === userId ? m.user_b_id : m.user_a_id);
	}).filter(Boolean) as string[];
	const { data: partners, error: partnersError } = await supabase
		.from("user_profiles")
		.select("id, nickname, avatar_url, avatar_storage_path")
		.in("id", partnerIds);
	if (partnersError || !partners) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch chats");
	const photoAdapter = getProfilePhotoAdapter(c.env);
	const partnerMap = new Map(partners.map((p) => [p.id, p]));
	try {
		const results = await Promise.all(
			roomsForUser.map(async (r) => {
				const m = roomIdByMatch.get(r.match_id);
				const partnerId = m && (m.user_a_id === userId ? m.user_b_id : m.user_a_id);
				const partner = partnerId ? partnerMap.get(partnerId) : null;
				const { data: lastMsg, error: lastMsgError } = await supabase
					.from("direct_chat_messages")
					.select("content, created_at, sender_id")
					.eq("room_id", r.id)
					.order("created_at", { ascending: false })
					.limit(1)
					.single();
				if (lastMsgError && lastMsgError.code !== "PGRST116") throw new Error("last message lookup failed");
				const { count, error: unreadError } = await supabase
					.from("direct_chat_messages")
					.select("id", { count: "exact", head: true })
					.eq("room_id", r.id)
					.neq("sender_id", userId)
					.eq("is_read", false);
				if (unreadError) throw new Error("unread count lookup failed");
				const unreadCount = count ?? 0;
				let unreadCountAfterSeen = unreadCount;
				if (notificationSeenAt) {
					const { count: countAfter, error: countAfterError } = await supabase
						.from("direct_chat_messages")
						.select("id", { count: "exact", head: true })
						.eq("room_id", r.id)
						.neq("sender_id", userId)
						.eq("is_read", false)
						.gt("created_at", notificationSeenAt);
					if (countAfterError) throw new Error("post-notification unread count lookup failed");
					unreadCountAfterSeen = countAfter ?? 0;
				}
				return {
					id: r.id,
					match_id: r.match_id,
					partner: partner && m ? { nickname: partner.nickname, avatar_url: await resolveAuthorizedPeerProfilePhotoUrl(photoAdapter, userId, m, partner) } : null,
					last_message: lastMsg ? { content: lastMsg.content, created_at: lastMsg.created_at, is_mine: lastMsg.sender_id === userId } : null,
					unread_count: unreadCount,
					unread_count_after_seen: unreadCountAfterSeen,
					status: "active",
				};
			}),
		);
		return jsonData(c, results);
	} catch {
		console.error("[direct-chats] failed to read chat metadata");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch chats");
	}
});

/** GET /api/direct-chats/:id/messages */
directChats.get("/:id/messages", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const limit = Math.min(Number(c.req.query("limit")) || 50, 100);
	const cursor = c.req.query("cursor");
	const supabase = getSupabaseClient(c.env);
	const { data: room, error: roomError } = await supabase
		.from("direct_chat_rooms")
		.select("match_id")
		.eq("status", "active")
		.eq("id", id)
		.single();
	if (roomError || !room) return jsonError(c, "NOT_FOUND", "Room not found");
	const { data: match, error: matchError } = await supabase.from("matches").select("user_a_id, user_b_id").eq("id", room.match_id).single();
	if (matchError || !match || (match.user_a_id !== userId && match.user_b_id !== userId)) return jsonError(c, "FORBIDDEN", "Access denied");
	const partnerId = match.user_a_id === userId ? match.user_b_id : match.user_a_id;
	const agePair = await checkVerifiedPair(supabase, userId, partnerId);
	if (agePair.ok === false) return jsonError(c, "FORBIDDEN", "Access denied");
	const { data: blockRow, error: blockError } = await supabase
		.from("blocks")
		.select("id")
		.or(`and(blocker_id.eq.${userId},blocked_id.eq.${partnerId}),and(blocker_id.eq.${partnerId},blocked_id.eq.${userId})`)
		.limit(1)
		.maybeSingle();
	if (blockError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify message eligibility");
	if (blockRow) return jsonError(c, "FORBIDDEN", "Access denied");
	let q = supabase
		.from("direct_chat_messages")
		.select("id, sender_id, content, is_read, created_at")
		.eq("room_id", id)
		.order("created_at", { ascending: false });
	if (cursor) q = q.lt("created_at", cursor);
	const { data: rows, error: rowsError } = await q.limit(limit + 1);
	if (rowsError || !rows) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch messages");
	const hasMore = (rows?.length ?? 0) > limit;
	const list = (rows ?? []).slice(0, limit).reverse();
	const formatted = list.map((m) => ({
		id: m.id,
		sender_id: m.sender_id,
		is_mine: m.sender_id === userId,
		content: m.content,
		is_read: m.is_read,
		created_at: m.created_at,
	}));
	return c.json({ data: formatted, next_cursor: hasMore ? list[0]?.created_at ?? null : null, has_more: hasMore });
});

/** POST /api/direct-chats/:id/messages/send-recovery. Keep the digest out of URLs and access logs. */
directChats.post("/:id/messages/send-recovery", requireAuth, requireAgeVerified, async (c) => {
	const roomId = c.req.param("id");
	const parsed = recoverMessageSendSchema.safeParse(await c.req.json());
	if (!z.string().uuid().safeParse(roomId).success || !parsed.success) {
		return jsonError(c, "BAD_REQUEST", "Invalid send recovery receipt");
	}
	const supabase = getSupabaseClient(c.env);
	const recovered = await recoverDirectChatMessageSend(supabase, {
		roomId,
		senderId: c.get("user_id"),
		idempotencyKey: parsed.data.idempotency_key,
		contentSha256: parsed.data.content_sha256,
	});
	if (!recovered) return jsonError(c, "INTERNAL_ERROR", "Failed to recover direct message");
	return jsonData(c, {
		outcome: recovered.outcome,
		message: recovered.outcome === "found" ? {
			id: recovered.message_id,
			content: recovered.message_content,
			created_at: recovered.message_created_at,
		} : null,
	});
});

/** POST /api/direct-chats/:id/messages */
directChats.post("/:id/messages", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const parsed = postMessageSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	const supabase = getSupabaseClient(c.env);
	let room: { match_id: string } | null = null;
	try {
		const roomResult = await supabase
			.from("direct_chat_rooms")
			.select("match_id")
			.eq("status", "active")
			.eq("id", id)
			.single();
		if (roomResult.error) {
			// An inactive or missing room is deliberately indistinguishable from
			// an unknown room. Other lookup failures fail closed without exposing
			// the database error or the requested room identifier.
			if ((roomResult.error as { code?: string }).code === "PGRST116") {
				return jsonError(c, "NOT_FOUND", "Room not found");
			}
			console.error("[direct-chats] active room lookup failed");
			return jsonError(c, "INTERNAL_ERROR", "Failed to verify message eligibility");
		}
		room = roomResult.data;
	} catch {
		console.error("[direct-chats] active room lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify message eligibility");
	}
	if (!room) return jsonError(c, "NOT_FOUND", "Room not found");
	const { data: match, error: matchError } = await supabase.from("matches").select("user_a_id, user_b_id").eq("id", room.match_id).single();
	if (matchError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify room access");
	if (!match || (match.user_a_id !== userId && match.user_b_id !== userId)) return jsonError(c, "FORBIDDEN", "Access denied");
	const partnerId = match.user_a_id === userId ? match.user_b_id : match.user_a_id;
	const agePair = await checkVerifiedPair(supabase, userId, partnerId);
	if (agePair.ok === false) return jsonError(c, "FORBIDDEN", "Access denied");

	// The reject_blocked_pair_by_room trigger is the actual backstop for this;
	// this check exists only to return a clean error and stop earlier. Reuses
	// the FORBIDDEN "Access denied" text the membership check above already
	// returns, so a block cannot be distinguished from not being a participant.
	const { data: blockRow, error: blockError } = await supabase
		.from("blocks")
		.select("id")
		.or(`and(blocker_id.eq.${userId},blocked_id.eq.${partnerId}),and(blocker_id.eq.${partnerId},blocked_id.eq.${userId})`)
		.limit(1)
		.maybeSingle();
	if (blockError) {
		// Fail closed: an unreadable block list is never "not blocked".
		console.error("[direct-chats] blocks lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify message eligibility");
	}
	if (blockRow) return jsonError(c, "FORBIDDEN", "Access denied");

	const headerKey = c.req.header("Idempotency-Key");
	if (headerKey && !z.string().uuid().safeParse(headerKey).success) {
		return jsonError(c, "BAD_REQUEST", "Invalid idempotency key");
	}
	if (headerKey && parsed.data.idempotency_key && headerKey.toLowerCase() !== parsed.data.idempotency_key.toLowerCase()) {
		return jsonError(c, "BAD_REQUEST", "Conflicting idempotency keys");
	}
	const idempotencyKey = parsed.data.idempotency_key ?? headerKey;
	if (idempotencyKey) {
		const sendResult = await persistDirectChatMessage(supabase, {
			roomId: id,
			senderId: userId,
			idempotencyKey,
			content: parsed.data.content,
			contentSha256: await sha256Hex(parsed.data.content),
		});
		if (!sendResult) return jsonError(c, "INTERNAL_ERROR", "Failed to send");
		if (sendResult.outcome === "inserted" || sendResult.outcome === "replayed") {
			if (!sendResult.message_id || sendResult.message_content !== parsed.data.content || !sendResult.message_created_at) {
				return jsonError(c, "INTERNAL_ERROR", "Failed to send");
			}
			return jsonData(c, {
				id: sendResult.message_id,
				content: sendResult.message_content,
				created_at: sendResult.message_created_at,
			});
		}
		if (sendResult.outcome === "conflict" || sendResult.outcome === "missing") {
			return jsonError(c, "CONFLICT", "Idempotency key cannot be reused");
		}
		if (sendResult.outcome === "ineligible") return jsonError(c, "FORBIDDEN", "Access denied");
		if (sendResult.outcome === "not_found") return jsonError(c, "NOT_FOUND", "Room not found");
		if (sendResult.outcome === "invalid_input") return jsonError(c, "BAD_REQUEST", "Invalid message");
		return jsonError(c, "INTERNAL_ERROR", "Failed to send");
	}

	const { data: msg, error } = await supabase
		.from("direct_chat_messages")
		.insert({ room_id: id, sender_id: userId, content: parsed.data.content })
		.select("id, content, created_at")
		.single();
	if (error) return jsonError(c, "INTERNAL_ERROR", "Failed to send");
	return jsonData(c, msg);
});

/** PUT /api/direct-chats/:id/messages/:messageId/read */
directChats.put("/:id/messages/:messageId/read", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const messageId = c.req.param("messageId");
	const supabase = getSupabaseClient(c.env);
	const { data: room, error: roomError } = await supabase
		.from("direct_chat_rooms")
		.select("match_id")
		.eq("status", "active")
		.eq("id", id)
		.single();
	if (roomError || !room) return jsonError(c, "NOT_FOUND", "Room not found");
	const { data: match, error: matchError } = await supabase.from("matches").select("user_a_id, user_b_id").eq("id", room.match_id).single();
	if (matchError || !match || (match.user_a_id !== userId && match.user_b_id !== userId)) return jsonError(c, "FORBIDDEN", "Access denied");
	const partnerId = match.user_a_id === userId ? match.user_b_id : match.user_a_id;
	const agePair = await checkVerifiedPair(supabase, userId, partnerId);
	if (agePair.ok === false) return jsonError(c, "FORBIDDEN", "Access denied");
	const { data: blockRow, error: blockError } = await supabase
		.from("blocks")
		.select("id")
		.or(`and(blocker_id.eq.${userId},blocked_id.eq.${partnerId}),and(blocker_id.eq.${partnerId},blocked_id.eq.${userId})`)
		.limit(1)
		.maybeSingle();
	if (blockError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify message eligibility");
	if (blockRow) return jsonError(c, "FORBIDDEN", "Access denied");
	const { data: target, error: targetError } = await supabase.from("direct_chat_messages").select("id, created_at").eq("id", messageId).eq("room_id", id).single();
	if (targetError || !target) return jsonError(c, "NOT_FOUND", "Message not found");
	const { count, error: readUpdateError } = await supabase
		.from("direct_chat_messages")
		.update({ is_read: true })
		.eq("room_id", id)
		.neq("sender_id", userId)
		.lte("created_at", target.created_at);
	if (readUpdateError) return jsonError(c, "INTERNAL_ERROR", "Failed to mark messages as read");
	return jsonData(c, { read_count: count ?? 0 });
});

export default directChats;
