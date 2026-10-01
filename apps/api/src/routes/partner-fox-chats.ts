import { judgeChatComplete } from "../services/judge-chat-complete";
import { Hono, type Context } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { detectLangFromDocument, normalizeUserLanguage } from "../lib/lang";
import { isRecordingRehearsalActive } from "../services/recording-rehearsal";
import { isFoxConversationPromptWithinRecordingWindow, resolveFoxConversationRecordingWindow } from "../services/fox-conversation-recording-window";
import { buildSpeedDatingSystemPrompt } from "../prompts/speed-dating";
import {
	claimPartnerFoxGreeting,
	claimPartnerFoxMessageSend,
	completePartnerFoxGreeting,
	completePartnerFoxMessageSend,
	finishPartnerFoxMessageSend,
	recoverPartnerFoxMessageSend,
	retryPartnerFoxGreetingBeforeProvider,
	type PartnerFoxMessageSendRow,
} from "../services/partner-fox-message-send";
import { sha256Hex } from "../services/message-idempotency";
import {
	checkPartnerFoxChatAccess,
	checkPartnerFoxChatStartAccess,
	type PartnerFoxChatAccessExpectation,
	type PartnerFoxChatAccessResult,
	type PartnerFoxChatStartResult,
} from "../services/partner-fox-chat-access";
import { z } from "zod";

const partnerFoxChats = new Hono<Env>();

const postChatSchema = z.object({ match_id: z.string().uuid().transform((id) => id.toLowerCase()) });
const postMessageSchema = z.object({
	content: z.string().min(1).max(2000),
	idempotency_key: z.string().uuid().optional(),
});
const recoverMessageSendSchema = z.object({
	idempotency_key: z.string().uuid(),
	content_sha256: z.string().regex(/^[0-9a-f]{64}$/),
});
type PartnerFoxChatRow = {
	id: string;
	match_id: string;
	user_id: string;
	partner_user_id: string;
	created_at: string;
};

type PartnerFoxMessageRow = {
	id: string;
	chat_id: string;
	role: "user" | "fox";
	content: string;
	created_at: string;
};

type PartnerFoxHistoryRow = {
	id: string;
	role: "user" | "fox";
	content: string;
};

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown): value is string {
	return typeof value === "string" && value.trim().length > 0;
}

function isMissingRowError(error: unknown): boolean {
	return isRecord(error) && error.code === "PGRST116";
}

function isUniqueViolation(error: unknown): boolean {
	return isRecord(error) && error.code === "23505";
}

function isChatRow(value: unknown, expectation?: Partial<PartnerFoxChatRow>): value is PartnerFoxChatRow {
	if (
		!isRecord(value) ||
		!isNonEmptyString(value.id) ||
		!isNonEmptyString(value.match_id) ||
		!isNonEmptyString(value.user_id) ||
		!isNonEmptyString(value.partner_user_id) ||
		value.user_id === value.partner_user_id ||
		!isNonEmptyString(value.created_at)
	) return false;
	return Object.entries(expectation ?? {}).every(([key, expected]) => value[key] === expected);
}

function isMessageRow(value: unknown, expectation?: Partial<PartnerFoxMessageRow>): value is PartnerFoxMessageRow {
	if (
		!isRecord(value) ||
		!isNonEmptyString(value.id) ||
		!isNonEmptyString(value.chat_id) ||
		(value.role !== "user" && value.role !== "fox") ||
		typeof value.content !== "string" ||
		!isNonEmptyString(value.created_at)
	) return false;
	return Object.entries(expectation ?? {}).every(([key, expected]) => value[key] === expected);
}

function isHistoryRow(value: unknown): value is PartnerFoxHistoryRow {
	return isRecord(value) && isNonEmptyString(value.id) && (value.role === "user" || value.role === "fox") && typeof value.content === "string";
}

function messagePairFromSendRpc(
	row: PartnerFoxMessageSendRow,
	chatId: string,
	expectedUserContent: string,
): { userMessage: PartnerFoxMessageRow; foxMessage: PartnerFoxMessageRow } | null {
	const userMessage = {
		id: row.user_message_id,
		chat_id: chatId,
		role: "user" as const,
		content: row.user_content,
		created_at: row.user_created_at,
	};
	const foxMessage = {
		id: row.fox_message_id,
		chat_id: chatId,
		role: "fox" as const,
		content: row.fox_content,
		created_at: row.fox_created_at,
	};
	if (
		!isMessageRow(userMessage, { chat_id: chatId, role: "user", content: expectedUserContent }) ||
		!isMessageRow(foxMessage, { chat_id: chatId, role: "fox" }) ||
		foxMessage.content.trim().length === 0
	) return null;
	return { userMessage, foxMessage };
}

function isDefiniteProviderRejection(error: unknown): boolean {
	if (!isRecord(error)) return false;
	const response = isRecord(error.response) ? error.response : null;
	const status = error.statusCode ?? error.status ?? response?.status;
	return typeof status === "number" && Number.isInteger(status) && status >= 400 && status < 500 && status !== 408;
}

function publicMessage(row: PartnerFoxMessageRow) {
	return { id: row.id, role: row.role, content: row.content, created_at: row.created_at };
}

function accessFailureResponse(c: Parameters<typeof jsonError>[0], result: PartnerFoxChatAccessResult) {
	if (result.ok === true) return null;
	return result.reason === "error"
		? jsonError(c, "INTERNAL_ERROR", "Partner chat access is unavailable")
		: jsonError(c, "NOT_FOUND", "Chat not found");
}

function startFailureResponse(c: Parameters<typeof jsonError>[0], result: PartnerFoxChatStartResult) {
	if (!isRecord(result) || typeof result.ok !== "boolean") return jsonError(c, "INTERNAL_ERROR", "Partner chat access is unavailable");
	if (result.ok === true) return null;
	if (result.reason === "error") return jsonError(c, "INTERNAL_ERROR", "Partner chat access is unavailable");
	if (result.reason === "not_ready") return jsonError(c, "CONFLICT", "Fox conversation not completed");
	return jsonError(c, "NOT_FOUND", "Match not found");
}

function recordingPairAvailable(c: Context<Env>, userId: string, partnerUserId: string): boolean {
	const config = c.get("recording_rehearsal");
	if (!config) return true;
	const ids = config.generationPair;
	return isRecordingRehearsalActive(config) && ids.some((id) => id === userId) && ids.some((id) => id === partnerUserId) && userId !== partnerUserId;
}

async function checkCurrentAccess(
	c: Context<Env>,
	supabase: ReturnType<typeof getSupabaseClient>,
	expectation: PartnerFoxChatAccessExpectation,
) {
	if (!recordingPairAvailable(c, expectation.userId, expectation.partnerUserId)) return jsonError(c, "NOT_FOUND", "Partner chat not found");
	let result: PartnerFoxChatAccessResult;
	try {
		result = await checkPartnerFoxChatAccess(supabase, expectation);
	} catch {
		return jsonError(c, "INTERNAL_ERROR", "Partner chat access is unavailable");
	}
	if (!isRecord(result) || typeof result.ok !== "boolean") {
		return jsonError(c, "INTERNAL_ERROR", "Partner chat access is unavailable");
	}
	if (result.ok && result.partnerUserId !== expectation.partnerUserId) {
		return jsonError(c, "INTERNAL_ERROR", "Partner chat access is unavailable");
	}
	if (!recordingPairAvailable(c, expectation.userId, expectation.partnerUserId)) return jsonError(c, "NOT_FOUND", "Partner chat not found");
	return accessFailureResponse(c, result);
}

async function readPartnerChat(
	supabase: ReturnType<typeof getSupabaseClient>,
	chatId: string,
	userId: string,
) {
	try {
		return await supabase
			.from("partner_fox_chats")
			.select("id, match_id, user_id, partner_user_id, created_at")
			.eq("id", chatId)
			.eq("user_id", userId)
			.maybeSingle();
	} catch {
		return { data: null, error: { readFailed: true } };
	}
}

async function readPartnerProfile(supabase: ReturnType<typeof getSupabaseClient>, userId: string) {
	try {
		return await supabase.from("user_profiles").select("nickname, conversation_language").eq("id", userId).single();
	} catch {
		return { data: null, error: { readFailed: true } };
	}
}

async function readPartnerPersona(supabase: ReturnType<typeof getSupabaseClient>, userId: string) {
	try {
		return await supabase
			.from("personas")
			.select("compiled_document")
			.eq("user_id", userId)
			.eq("persona_type", "wingfox")
			.single();
	} catch {
		return { data: null, error: { readFailed: true } };
	}
}

async function readExistingChat(
	supabase: ReturnType<typeof getSupabaseClient>,
	matchId: string,
	userId: string,
	partnerUserId: string,
) {
	try {
		return await supabase
			.from("partner_fox_chats")
			.select("id, match_id, user_id, partner_user_id, created_at")
			.eq("match_id", matchId)
			.eq("user_id", userId)
			.eq("partner_user_id", partnerUserId)
			.maybeSingle();
	} catch {
		return { data: null, error: { readFailed: true } };
	}
}

async function readOwnedChat(
	supabase: ReturnType<typeof getSupabaseClient>,
	matchId: string,
	userId: string,
) {
	try {
		return await supabase
			.from("partner_fox_chats")
			.select("id, match_id, user_id, partner_user_id, created_at")
			.eq("match_id", matchId)
			.eq("user_id", userId)
			.maybeSingle();
	} catch {
		return { data: null, error: { readFailed: true } };
	}
}

async function readMessages(supabase: ReturnType<typeof getSupabaseClient>, chatId: string) {
	try {
		return await supabase
			.from("partner_fox_messages")
			.select("id, chat_id, role, content, created_at")
			.eq("chat_id", chatId)
			.order("created_at");
	} catch {
		return { data: null, error: { readFailed: true } };
	}
}

async function readHistory(supabase: ReturnType<typeof getSupabaseClient>, chatId: string) {
	try {
		return await supabase
			.from("partner_fox_messages")
			.select("id, role, content")
			.eq("chat_id", chatId)
			.order("created_at");
	} catch {
		return { data: null, error: { readFailed: true } };
	}
}

/** POST /api/partner-fox-chats */
partnerFoxChats.post("/", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const parsed = postChatSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	const supabase = getSupabaseClient(c.env);
	let startAccess: PartnerFoxChatStartResult;
	try {
		startAccess = await checkPartnerFoxChatStartAccess(supabase, { matchId: parsed.data.match_id, userId });
	} catch {
		return jsonError(c, "INTERNAL_ERROR", "Partner chat access is unavailable");
	}
	const startFailure = startFailureResponse(c, startAccess);
	if (startFailure) return startFailure;
	if (!startAccess.ok) return jsonError(c, "NOT_FOUND", "Match not found");
	const initialStart = startAccess;
	if (!recordingPairAvailable(c, userId, initialStart.partnerUserId)) return jsonError(c, "NOT_FOUND", "Match not found");

	const existingResult = await readExistingChat(supabase, parsed.data.match_id, userId, initialStart.partnerUserId);
	if (existingResult.error && !isMissingRowError(existingResult.error)) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify existing partner chat");
	}
	let existingChat: PartnerFoxChatRow | null = null;
	if (existingResult.data !== null && existingResult.data !== undefined) {
		if (!isChatRow(existingResult.data, {
			match_id: parsed.data.match_id,
			user_id: userId,
			partner_user_id: initialStart.partnerUserId,
		})) return jsonError(c, "INTERNAL_ERROR", "Failed to verify existing partner chat");
		existingChat = existingResult.data;
		const existingMessagesResult = await readMessages(supabase, existingChat.id);
		if (
			existingMessagesResult.error ||
			!Array.isArray(existingMessagesResult.data) ||
			!existingMessagesResult.data.every((message) => isMessageRow(message, { chat_id: existingChat?.id }))
		) return jsonError(c, "INTERNAL_ERROR", "Failed to verify existing partner chat");
		if (existingMessagesResult.data.length > 0) {
			// A committed first Fox message is authoritative after a lost start
			// response. Replay it without requiring another provider call.
			const firstMessage = existingMessagesResult.data[0];
			if (
				firstMessage.role === "fox" && isNonEmptyString(firstMessage.content) && firstMessage.content.length <= 2000 &&
				Number.isFinite(Date.parse(firstMessage.created_at))
			) {
				const expectation: PartnerFoxChatAccessExpectation = {
					chatId: existingChat.id,
					matchId: parsed.data.match_id,
					userId,
					partnerUserId: initialStart.partnerUserId,
				};
				let denied = await checkCurrentAccess(c, supabase, expectation);
				if (denied) return denied;
				const existingProfile = await readPartnerProfile(supabase, initialStart.partnerUserId);
				if (
					existingProfile.error || !isRecord(existingProfile.data) ||
					(existingProfile.data.nickname !== null && typeof existingProfile.data.nickname !== "string")
				) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch partner profile");
				denied = await checkCurrentAccess(c, supabase, expectation);
				if (denied) return denied;
				return jsonData(c, {
					id: existingChat.id,
					match_id: parsed.data.match_id,
					partner: { nickname: existingProfile.data.nickname ?? "Partner" },
					first_message: publicMessage(firstMessage),
				});
			}
			return jsonError(c, "CONFLICT", "Chat already started");
		}
	}

	const apiKey = c.env?.MISTRAL_API_KEY?.trim();
	if (!apiKey) {
		return jsonError(c, "INTERNAL_ERROR", "Partner chat is temporarily unavailable", 503);
	}

	const partnerPersonaResult = await readPartnerPersona(supabase, initialStart.partnerUserId);
	if (partnerPersonaResult.error || !isRecord(partnerPersonaResult.data) || !isNonEmptyString(partnerPersonaResult.data.compiled_document)) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch partner persona");
	}
	const partnerDocument = partnerPersonaResult.data.compiled_document;
	const partnerProfileResult = await readPartnerProfile(supabase, initialStart.partnerUserId);
	if (
		partnerProfileResult.error ||
		!isRecord(partnerProfileResult.data) ||
		(partnerProfileResult.data.nickname !== null && typeof partnerProfileResult.data.nickname !== "string")
	) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch partner profile");

	// Re-read the immutable match participants immediately before creating the chat.
	let latestStart: PartnerFoxChatStartResult;
	try {
		latestStart = await checkPartnerFoxChatStartAccess(supabase, { matchId: parsed.data.match_id, userId });
	} catch {
		return jsonError(c, "INTERNAL_ERROR", "Partner chat access is unavailable");
	}
	const latestFailure = startFailureResponse(c, latestStart);
	if (latestFailure) return latestFailure;
	if (
		!latestStart.ok ||
		latestStart.partnerUserId !== initialStart.partnerUserId ||
		latestStart.userAId !== initialStart.userAId ||
		latestStart.userBId !== initialStart.userBId
	) return jsonError(c, "NOT_FOUND", "Match not found");

	if (!recordingPairAvailable(c, userId, initialStart.partnerUserId)) return jsonError(c, "NOT_FOUND", "Match not found");
	const savedLanguage = partnerProfileResult.data.conversation_language;
	const lang = normalizeUserLanguage(typeof savedLanguage === "string" ? savedLanguage : null) ?? detectLangFromDocument(partnerDocument);
	const partnerName = partnerProfileResult.data.nickname ?? (lang === "en" ? "Partner" : "相手");
	let createdChat: PartnerFoxChatRow;
	if (existingChat) {
		createdChat = existingChat;
	} else {
		let chatInsertResult: { data: unknown; error: unknown };
		try {
			chatInsertResult = await supabase
				.from("partner_fox_chats")
				.insert({ match_id: parsed.data.match_id, user_id: userId, partner_user_id: latestStart.partnerUserId })
				.select("id, match_id, user_id, partner_user_id, created_at")
				.single() as unknown as { data: unknown; error: unknown };
		} catch {
			return jsonError(c, "INTERNAL_ERROR", "Failed to create chat");
		}
		if (!chatInsertResult.error) {
			if (!isChatRow(chatInsertResult.data, {
				match_id: parsed.data.match_id,
				user_id: userId,
				partner_user_id: latestStart.partnerUserId,
			})) return jsonError(c, "INTERNAL_ERROR", "Failed to create chat");
			createdChat = chatInsertResult.data;
		} else {
			if (!isUniqueViolation(chatInsertResult.error)) return jsonError(c, "INTERNAL_ERROR", "Failed to create chat");
			// The unique (match_id, user_id) key is the only supported parallel
			// start handoff. Re-read that exact owner row and recover only while
			// it remains empty; never broaden this to a chat-wide delete/retry.
			const ownerChatResult = await readOwnedChat(supabase, parsed.data.match_id, userId);
			if (ownerChatResult.error && !isMissingRowError(ownerChatResult.error)) {
				return jsonError(c, "INTERNAL_ERROR", "Failed to verify existing partner chat");
			}
			if (!isChatRow(ownerChatResult.data, {
				match_id: parsed.data.match_id,
				user_id: userId,
				partner_user_id: latestStart.partnerUserId,
			})) return jsonError(c, "NOT_FOUND", "Match not found");
			const concurrentChat = ownerChatResult.data;
			const concurrentMessagesResult = await readMessages(supabase, concurrentChat.id);
			if (
				concurrentMessagesResult.error ||
				!Array.isArray(concurrentMessagesResult.data) ||
				!concurrentMessagesResult.data.every((message) => isMessageRow(message, { chat_id: concurrentChat.id }))
			) return jsonError(c, "INTERNAL_ERROR", "Failed to verify existing partner chat");
			if (
				concurrentMessagesResult.data.length > 0 &&
				concurrentMessagesResult.data[0]?.role !== "fox"
			) return jsonError(c, "CONFLICT", "Chat already started");
			createdChat = concurrentChat;
		}
	}
	const expectation: PartnerFoxChatAccessExpectation = {
		chatId: createdChat.id,
		matchId: parsed.data.match_id,
		userId,
		partnerUserId: latestStart.partnerUserId,
	};
	let denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;

	const claim = await claimPartnerFoxGreeting(supabase, {
		chatId: createdChat.id,
		matchId: parsed.data.match_id,
		userId,
		partnerUserId: latestStart.partnerUserId,
	});
	if (!claim) return jsonError(c, "INTERNAL_ERROR", "Failed to claim first message");
	if (claim.outcome === "not_found") return jsonError(c, "NOT_FOUND", "Match not found");
	if (claim.outcome === "message_present" || claim.outcome === "busy" || claim.outcome === "unknown" || claim.outcome === "missing") {
		return jsonError(c, "CONFLICT", "First message is already being resolved");
	}
	if (claim.outcome === "invalid_input") return jsonError(c, "INTERNAL_ERROR", "Failed to claim first message");

	if (claim.outcome === "completed") {
		denied = await checkCurrentAccess(c, supabase, expectation);
		if (denied) return denied;
		const firstMessage: PartnerFoxMessageRow = {
			id: claim.message_id as string,
			chat_id: createdChat.id,
			role: "fox",
			content: claim.message_content as string,
			created_at: claim.message_created_at as string,
		};
		return jsonData(c, {
			id: createdChat.id,
			match_id: parsed.data.match_id,
			partner: { nickname: partnerName },
			first_message: publicMessage(firstMessage),
		});
	}
	if (claim.outcome !== "claimed" || !claim.claim_token) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to claim first message");
	}

	// This check is before provider execution. The release RPC is safe here:
	// SQL rechecks current pair eligibility before making the claim retryable.
	denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) {
		await retryPartnerFoxGreetingBeforeProvider(supabase, {
			chatId: createdChat.id,
			claimToken: claim.claim_token,
		});
		return denied;
	}

	const greetingInstruction = lang === "en"
		? `\n\nThe user is speaking to you directly. Greet them naturally as ${partnerName} would. Keep it to one short sentence. Say "hello" at most once, or skip it.`
		: `\n\n相手のユーザーから直接話しかけられています。${partnerName}さんならこう話すだろう、という形で自然に挨拶してください。挨拶は短く1文で。『こんにちは』は一度だけか、省略してもよい。`;
	let firstContent: string;
	const greetingMessages = [
		{ role: "system" as const, content: `${buildSpeedDatingSystemPrompt(partnerDocument, lang)}${greetingInstruction}` },
		{ role: "user" as const, content: lang === "en" ? "Say hello." : "挨拶をしてください。" },
	];
	const recording = c.get("recording_rehearsal");
	if (recording && !isFoxConversationPromptWithinRecordingWindow(resolveFoxConversationRecordingWindow(c.env, userId, initialStart.partnerUserId), userId, initialStart.partnerUserId, greetingMessages)) {
		await retryPartnerFoxGreetingBeforeProvider(supabase, { chatId: createdChat.id, claimToken: claim.claim_token });
		return jsonError(c, "INTERNAL_ERROR", "Partner chat is temporarily unavailable", 503);
	}
	try {
		firstContent = await judgeChatComplete(c, supabase, "ward_greeting", apiKey, greetingMessages, recording || c.get("judge_access") ? { maxTokens: 80 } : {});
	} catch {
		// A provider/network error can happen after work was accepted. Leave
		// the lease alone so expiry seals it as unknown; never regenerate here.
		const accessAfterFailure = await checkCurrentAccess(c, supabase, expectation);
		if (accessAfterFailure) return accessAfterFailure;
		return jsonError(c, "INTERNAL_ERROR", "Failed to generate fox response");
	}
	if (typeof firstContent !== "string" || firstContent.trim().length === 0 || firstContent.length > 2000) {
		const malformedAccess = await checkCurrentAccess(c, supabase, expectation);
		if (malformedAccess) return malformedAccess;
		return jsonError(c, "INTERNAL_ERROR", "Failed to generate fox response");
	}
	denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;

	const completion = await completePartnerFoxGreeting(supabase, {
		chatId: createdChat.id,
		claimToken: claim.claim_token,
		content: firstContent,
	});
	if (!completion) return jsonError(c, "INTERNAL_ERROR", "Failed to persist first message");
	if (completion.outcome === "not_found") return jsonError(c, "NOT_FOUND", "Match not found");
	if (completion.outcome !== "completed") {
		if (completion.outcome === "stale" || completion.outcome === "unknown" || completion.outcome === "message_present") {
			return jsonError(c, "CONFLICT", "First message could not be safely completed");
		}
		return jsonError(c, "INTERNAL_ERROR", "Failed to persist first message");
	}
	const firstMessage: PartnerFoxMessageRow = {
		id: completion.message_id as string,
		chat_id: createdChat.id,
		role: "fox",
		content: completion.message_content as string,
		created_at: completion.message_created_at as string,
	};

	denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;
	return jsonData(c, {
		id: createdChat.id,
		match_id: parsed.data.match_id,
		partner: { nickname: partnerName },
		first_message: publicMessage(firstMessage),
	});
});

/** GET /api/partner-fox-chats/:id */
partnerFoxChats.get("/:id", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const chatId = c.req.param("id");
	const supabase = getSupabaseClient(c.env);
	const chatResult = await readPartnerChat(supabase, chatId, userId);
	if (chatResult.error || !isChatRow(chatResult.data, { id: chatId, user_id: userId })) {
		return jsonError(c, "NOT_FOUND", "Chat not found");
	}
	const chat = chatResult.data;
	const expectation: PartnerFoxChatAccessExpectation = {
		chatId: chat.id,
		matchId: chat.match_id,
		userId: chat.user_id,
		partnerUserId: chat.partner_user_id,
	};
	let denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;

	const partnerResult = await readPartnerProfile(supabase, chat.partner_user_id);
	if (
		partnerResult.error ||
		!isRecord(partnerResult.data) ||
		(partnerResult.data.nickname !== null && typeof partnerResult.data.nickname !== "string")
	) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch partner profile");
	denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;
	return jsonData(c, {
		id: chat.id,
		match_id: chat.match_id,
		user_id: chat.user_id,
		partner_user_id: chat.partner_user_id,
		created_at: chat.created_at,
		partner: { nickname: partnerResult.data.nickname },
	});
});

/** POST /api/partner-fox-chats/:id/messages/send-recovery. Keep the digest out of URLs and access logs. */
partnerFoxChats.post("/:id/messages/send-recovery", requireAuth, requireAgeVerified, async (c) => {
	const chatId = c.req.param("id");
	const parsed = recoverMessageSendSchema.safeParse(await c.req.json());
	if (!z.string().uuid().safeParse(chatId).success || !parsed.success) {
		return jsonError(c, "BAD_REQUEST", "Invalid send recovery receipt");
	}
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const chatResult = await readPartnerChat(supabase, chatId, userId);
	if (chatResult.error || !isChatRow(chatResult.data, { id: chatId, user_id: userId })) {
		return jsonError(c, "NOT_FOUND", "Chat not found");
	}
	const chat = chatResult.data;
	const expectation: PartnerFoxChatAccessExpectation = {
		chatId: chat.id,
		matchId: chat.match_id,
		userId: chat.user_id,
		partnerUserId: chat.partner_user_id,
	};
	const denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;
	const recovered = await recoverPartnerFoxMessageSend(supabase, {
		chatId: chat.id,
		ownerId: userId,
		idempotencyKey: parsed.data.idempotency_key,
		contentSha256: parsed.data.content_sha256,
	});
	if (!recovered) return jsonError(c, "INTERNAL_ERROR", "Failed to recover partner message");
	return jsonData(c, {
		outcome: recovered.outcome,
		user_message: recovered.outcome === "completed" ? {
			id: recovered.user_message_id,
			chat_id: chat.id,
			role: "user",
			content: recovered.user_content,
			created_at: recovered.user_created_at,
		} : null,
		fox_message: recovered.outcome === "completed" ? {
			id: recovered.fox_message_id,
			chat_id: chat.id,
			role: "fox",
			content: recovered.fox_content,
			created_at: recovered.fox_created_at,
		} : null,
	});
});

/** GET /api/partner-fox-chats/:id/messages */
partnerFoxChats.get("/:id/messages", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const chatId = c.req.param("id");
	const supabase = getSupabaseClient(c.env);
	const chatResult = await readPartnerChat(supabase, chatId, userId);
	if (chatResult.error || !isChatRow(chatResult.data, { id: chatId, user_id: userId })) {
		return jsonError(c, "NOT_FOUND", "Chat not found");
	}
	const chat = chatResult.data;
	const expectation: PartnerFoxChatAccessExpectation = {
		chatId: chat.id,
		matchId: chat.match_id,
		userId: chat.user_id,
		partnerUserId: chat.partner_user_id,
	};
	let denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;

	const messagesResult = await readMessages(supabase, chat.id);
	if (
		messagesResult.error ||
		!Array.isArray(messagesResult.data) ||
		!messagesResult.data.every((message) => isMessageRow(message, { chat_id: chat.id }))
	) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch partner chat messages");
	denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;
	return c.json({ data: messagesResult.data.map(publicMessage), next_cursor: null, has_more: false });
});

/** POST /api/partner-fox-chats/:id/messages */
partnerFoxChats.post("/:id/messages", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const chatId = c.req.param("id");
	const parsed = postMessageSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	const headerKey = c.req.header("Idempotency-Key");
	if (headerKey && !z.string().uuid().safeParse(headerKey).success) {
		return jsonError(c, "BAD_REQUEST", "Invalid idempotency key");
	}
	if (headerKey && parsed.data.idempotency_key && headerKey.toLowerCase() !== parsed.data.idempotency_key.toLowerCase()) {
		return jsonError(c, "BAD_REQUEST", "Conflicting idempotency keys");
	}
	// The body key is used by current clients. The header supports older callers
	// that can provide a stable key; requests without one keep the legacy shape.
	const idempotencyKey = parsed.data.idempotency_key ?? headerKey ?? crypto.randomUUID();
	const supabase = getSupabaseClient(c.env);
	const chatResult = await readPartnerChat(supabase, chatId, userId);
	if (chatResult.error || !isChatRow(chatResult.data, { id: chatId, user_id: userId })) {
		return jsonError(c, "NOT_FOUND", "Chat not found");
	}
	const chat = chatResult.data;
	const expectation: PartnerFoxChatAccessExpectation = {
		chatId: chat.id,
		matchId: chat.match_id,
		userId: chat.user_id,
		partnerUserId: chat.partner_user_id,
	};
	let denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;
	const apiKey = c.env?.MISTRAL_API_KEY?.trim();
	if (!apiKey) {
		return jsonError(c, "INTERNAL_ERROR", "Partner chat is temporarily unavailable", 503);
	}
	const send = await claimPartnerFoxMessageSend(supabase, {
		chatId: chat.id,
		ownerId: userId,
		idempotencyKey,
		content: parsed.data.content,
		contentSha256: await sha256Hex(parsed.data.content),
	});
	if (!send) return jsonError(c, "INTERNAL_ERROR", "Failed to start partner message");
	if (send.outcome === "replayed") {
		const pair = messagePairFromSendRpc(send, chat.id, parsed.data.content);
		if (!pair) return jsonError(c, "CONFLICT", "Stored message result is unavailable");
		denied = await checkCurrentAccess(c, supabase, expectation);
		if (denied) return denied;
		return jsonData(c, {
			user_message: publicMessage(pair.userMessage),
			fox_message: publicMessage(pair.foxMessage),
		});
	}
	if (send.outcome === "unknown") {
		return jsonError(c, "CONFLICT", "The provider result is unknown; this key will not generate another reply");
	}
	if (send.outcome === "processing" || send.outcome === "busy") {
		return jsonError(c, "CONFLICT", "A partner message is already being processed");
	}
	if (send.outcome === "conflict" || send.outcome === "missing" || send.outcome === "stale") {
		return jsonError(c, "CONFLICT", "This idempotency key cannot be reused");
	}
	if (send.outcome === "not_found") return jsonError(c, "NOT_FOUND", "Chat not found");
	if (send.outcome === "ineligible") return jsonError(c, "NOT_FOUND", "Chat not found");
	if (send.outcome === "invalid_input") return jsonError(c, "BAD_REQUEST", "Invalid message");
	if (send.outcome !== "claimed" || !isNonEmptyString(send.claim_token)) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to start partner message");
	}
	const claimToken = send.claim_token;
	const finishClaim = async (outcome: "failed" | "unknown") => {
		await finishPartnerFoxMessageSend(supabase, { idempotencyKey, claimToken, outcome, userContent: parsed.data.content });
	};
	const userMessage = {
		id: send.user_message_id,
		chat_id: chat.id,
		role: "user" as const,
		content: send.user_content,
		created_at: send.user_created_at,
	};
	if (!isMessageRow(userMessage, { chat_id: chat.id, role: "user", content: parsed.data.content })) {
		await finishClaim("failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to persist user message");
	}

	const personaResult = await readPartnerPersona(supabase, chat.partner_user_id);
	if (personaResult.error || !isRecord(personaResult.data) || !isNonEmptyString(personaResult.data.compiled_document)) {
		await finishClaim("failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch partner persona");
	}
	const personaDocument = personaResult.data.compiled_document;
	const historyResult = await readHistory(supabase, chat.id);
	if (
		historyResult.error || !Array.isArray(historyResult.data) ||
		!historyResult.data.every(isHistoryRow) ||
		!historyResult.data.some((row) => row.id === userMessage.id && row.role === "user" && row.content === userMessage.content)
	) {
		await finishClaim("failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch partner chat history");
	}
	const messagesForAi = historyResult.data.map((message) => ({
		role: message.role === "user" ? "user" as const : "assistant" as const,
		content: message.content,
	}));
	denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) {
		await finishClaim("failed");
		return denied;
	}

	const lang = detectLangFromDocument(personaDocument);
	let providerAccepted = false;
	let foxContent: string;
	try {
		const providerContent = await judgeChatComplete(c, supabase, "ward_chat", apiKey, [
			{ role: "system", content: buildSpeedDatingSystemPrompt(personaDocument, lang) },
			...messagesForAi,
		], { maxTokens: 512 });
		providerAccepted = true;
		if (
			typeof providerContent !== "string" || providerContent.trim().length === 0 ||
			providerContent.length > 2000
		) {
			await finishClaim("unknown");
			denied = await checkCurrentAccess(c, supabase, expectation);
			if (denied) return denied;
			return jsonError(c, "INTERNAL_ERROR", "Failed to generate fox response");
		}
		foxContent = providerContent;
	} catch (error) {
		await finishClaim(isDefiniteProviderRejection(error) ? "failed" : "unknown");
		denied = await checkCurrentAccess(c, supabase, expectation);
		if (denied) return denied;
		return jsonError(c, "INTERNAL_ERROR", "Failed to generate fox response");
	}
	denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) {
		await finishClaim(providerAccepted ? "unknown" : "failed");
		return denied;
	}

	const completed = await completePartnerFoxMessageSend(supabase, {
		idempotencyKey,
		claimToken,
		foxContent,
		userContent: parsed.data.content,
	});
	const pair = completed?.outcome === "completed"
		? messagePairFromSendRpc(completed, chat.id, parsed.data.content)
		: null;
	if (!pair) {
		// Completion may have committed even if its HTTP response was lost. The
		// same-key claim will then replay the pair; unknown is safe if it did not.
		await finishClaim("unknown");
		return jsonError(c, "INTERNAL_ERROR", "Failed to persist fox response");
	}
	denied = await checkCurrentAccess(c, supabase, expectation);
	if (denied) return denied;
	return jsonData(c, {
		user_message: publicMessage(pair.userMessage),
		fox_message: publicMessage(pair.foxMessage),
	});
});

export default partnerFoxChats;
