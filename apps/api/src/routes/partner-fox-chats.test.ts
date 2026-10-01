import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
import { readRecordingRehearsalConfig, type ValidatedRecordingRehearsalConfig } from "../services/recording-rehearsal";

const authActor = vi.hoisted(() => ({ id: "user-a" }));

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", authActor.id);
		await next();
	},
	requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => {
		await next();
	},
}));

vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));
vi.mock("../services/partner-fox-chat-access", () => ({
	checkPartnerFoxChatAccess: vi.fn(),
	checkPartnerFoxChatStartAccess: vi.fn(),
}));
vi.mock("../services/mistral", () => ({ chatComplete: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import { chatComplete } from "../services/mistral";
import { sha256Hex } from "../services/message-idempotency";
import { checkPartnerFoxChatAccess, checkPartnerFoxChatStartAccess } from "../services/partner-fox-chat-access";
import { errorHandler } from "../middleware/error";
import partnerFoxChats from "./partner-fox-chats";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const mockedChatComplete = vi.mocked(chatComplete);
const mockedCheckPartnerFoxChatAccess = vi.mocked(checkPartnerFoxChatAccess);
const mockedCheckPartnerFoxChatStartAccess = vi.mocked(checkPartnerFoxChatStartAccess);

const MATCH_ID = "11111111-1111-4111-8111-111111111111";
const CHAT_ID = "80000000-0000-4000-8000-00000000d281";

interface ServiceRoleFakeOpts {
	matchError?: { code?: string; message: string } | null;
	foxConversationError?: { code?: string; message: string } | null;
	existingChat?: { id: string } | null;
	existingChatError?: { code?: string; message: string } | null;
	partnerPersona?: { compiled_document: string } | null;
	partnerPersonaError?: { code?: string; message: string } | null;
	partnerProfile?: { nickname: string | null } | null;
	partnerProfileError?: { code?: string; message: string } | null;
	chatInsertError?: { code?: string; message: string } | null;
	matchUpdateError?: { code?: string; message: string } | null;
	firstMessage?: Record<string, unknown> | null;
	firstMessageError?: { code?: string; message: string } | null;
	messageHistory?: Record<string, unknown>[] | null;
	messageHistoryError?: { code?: string; message: string } | null;
	userMessage?: Record<string, unknown> | null;
	userMessageError?: { code?: string; message: string } | null;
	foxMessage?: Record<string, unknown> | null;
	foxMessageError?: { code?: string; message: string } | null;
	messageDeleteError?: { code?: string; message: string } | null;
}

type Call = { table: string; method: string; args: unknown[] };

/**
 * A service-role-like fake deliberately returns the existing match/chat and
 * derived rows regardless of age. The route-level pair check must therefore
 * be the only thing stopping access before any counterparty data is read or
 * written.
 */
function makeServiceRoleLikeSupabase(opts: ServiceRoleFakeOpts = {}) {
	const calls: Call[] = [];
	const match = { user_a_id: "user-a", user_b_id: "user-b", status: "fox_conversation_completed" };
	const conversation = { status: "completed" };
	const chat = {
		id: CHAT_ID,
		match_id: MATCH_ID,
		user_id: "user-a",
		partner_user_id: "user-b",
		transcript: "derived-chat-secret",
	};
	const message = {
		id: "message-secret",
		role: "fox",
		content: "derived-message-secret",
		created_at: "2026-08-24T00:00:00Z",
	};

	const from = (table: string) => {
		let selection = "";
		let inserted = false;
		let insertedRow: Record<string, unknown> | null = null;
		let updated = false;
		let deleted = false;
		const query: Record<string, unknown> = {};
		const record = (method: string, args: unknown[]) => calls.push({ table, method, args });

		for (const method of ["select", "eq", "in", "order"]) {
			query[method] = (...args: unknown[]) => {
				record(method, args);
				if (method === "select") selection = String(args[0] ?? "");
				return query;
			};
		}
		query.insert = (row: unknown) => {
			record("insert", [row]);
			inserted = true;
			insertedRow = row as Record<string, unknown>;
			return query;
		};
		query.update = (row: unknown) => {
			record("update", [row]);
			updated = true;
			return query;
		};
		query.delete = () => {
			record("delete", []);
			deleted = true;
			return query;
		};
		query.single = async () => {
			record("single", []);
			if (table === "matches") return { data: match, error: opts.matchError ?? null };
			if (table === "fox_conversations") return { data: conversation, error: opts.foxConversationError ?? null };
			if (table === "personas") return { data: opts.partnerPersona === undefined ? { compiled_document: "persona-secret" } : opts.partnerPersona, error: opts.partnerPersonaError ?? null };
			if (table === "user_profiles") return { data: opts.partnerProfile === undefined ? { nickname: "Partner" } : opts.partnerProfile, error: opts.partnerProfileError ?? null };
			if (table === "partner_fox_chats") {
				if (inserted) return { data: { id: CHAT_ID }, error: opts.chatInsertError ?? null };
				if (selection === "id") return { data: opts.existingChat ?? null, error: opts.existingChatError ?? null };
				return { data: chat, error: null };
			}
			if (table === "partner_fox_messages" && inserted) {
				if (insertedRow?.role === "user") {
					return { data: opts.userMessage === undefined ? { id: insertedRow.id, created_at: message.created_at } : opts.userMessage, error: opts.userMessageError ?? null };
				}
				return { data: opts.firstMessage === undefined ? message : opts.firstMessage, error: opts.firstMessageError ?? null };
			}
			return { data: null, error: null };
		};
		query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => {
			const result =
			deleted
					? { data: null, error: opts.messageDeleteError ?? null }
					: updated && table === "matches"
						? { data: null, error: opts.matchUpdateError ?? null }
						: table === "partner_fox_messages" && !inserted
							? { data: opts.messageHistory === undefined ? [message] : opts.messageHistory, error: opts.messageHistoryError ?? null }
							: { data: null, error: null };
			return Promise.resolve(result).then(resolve, reject);
		};
		return query;
	};

	return { from, calls };
}

function buildApp(recording?: ValidatedRecordingRehearsalConfig) {
	const app = new Hono<Env>();
	if (recording) app.use("*", async (c, next) => { c.set("recording_rehearsal", recording); await next(); });
	app.onError(errorHandler);
	app.route("/api/partner-fox-chats", partnerFoxChats);
	return app;
}

beforeEach(() => {
	authActor.id = "user-a";
	mockedGetSupabaseClient.mockReset();
	mockedCheckPartnerFoxChatAccess.mockReset();
	mockedCheckPartnerFoxChatStartAccess.mockReset();
	mockedChatComplete.mockReset();
	mockedCheckPartnerFoxChatAccess.mockResolvedValue({ ok: false, reason: "forbidden" });
	mockedCheckPartnerFoxChatStartAccess.mockResolvedValue({ ok: false, reason: "forbidden" });
});

describe("partner-fox-chats blocks every derived-content handler for an unverified counterparty", () => {
	it("POST create returns NOT_FOUND before creating a partner chat or greeting", async () => {
		const supabase = makeServiceRoleLikeSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });

		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("derived-");
		expect(mockedCheckPartnerFoxChatStartAccess).toHaveBeenCalledTimes(1);
		expect(supabase.calls).not.toEqual(expect.arrayContaining([
			expect.objectContaining({ table: "partner_fox_chats", method: "insert" }),
		]));
		expect(supabase.calls).not.toEqual(expect.arrayContaining([
			expect.objectContaining({ table: "partner_fox_messages" }),
		]));
	});

	it("GET chat returns NOT_FOUND before reading the partner profile", async () => {
		const supabase = makeServiceRoleLikeSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}`);

		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("derived-");
		expect(mockedCheckPartnerFoxChatAccess).not.toHaveBeenCalled();
		expect(supabase.calls).not.toEqual(expect.arrayContaining([
			expect.objectContaining({ table: "user_profiles" }),
		]));
	});

	it("GET messages returns NOT_FOUND before reading partner-fox messages", async () => {
		const supabase = makeServiceRoleLikeSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`);

		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("derived-");
		expect(mockedCheckPartnerFoxChatAccess).not.toHaveBeenCalled();
		expect(supabase.calls).not.toEqual(expect.arrayContaining([
			expect.objectContaining({ table: "partner_fox_messages" }),
		]));
	});

	it("POST message returns NOT_FOUND before reading persona or writing either message", async () => {
		const supabase = makeServiceRoleLikeSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello" }),
		});

		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("derived-");
		expect(mockedCheckPartnerFoxChatAccess).not.toHaveBeenCalled();
		expect(supabase.calls).not.toEqual(expect.arrayContaining([
			expect.objectContaining({ table: "personas" }),
		]));
		expect(supabase.calls).not.toEqual(expect.arrayContaining([
			expect.objectContaining({ table: "partner_fox_messages" }),
		]));
	});
});

type StatefulRouteState = {
	chat: { id: string; match_id: string; user_id: string; partner_user_id: string; created_at: string };
	matchStatus: string;
	existingChat: Record<string, unknown> | null;
	persona: string;
	nickname: string | null;
	conversationLanguage?: "en" | "ja";
	messages: Record<string, unknown>[];
	accessAllowed: boolean;
	startAllowed: boolean;
	startStatus: string;
	foxInsertError: { code?: string; message: string } | null;
	greetingRpcError?: { code?: string; message: string } | null;
	greetingRpcData?: unknown;
	sendRpcData?: Record<string, unknown>;
	hideExistingChatOnce?: boolean;
	deletedIds: string[];
	accessCalls: number;
	startCalls: number;
	onMatchUpdate?: () => void;
	onPartnerProfileRead?: () => void;
	onAccessCall?: (call: number) => void;
	onMessagesRead?: () => void;
	onMessageInsert?: (role: string) => void;
	onGreetingRpc?: (content: string) => void;
};

function makeStatefulRouteSupabase(state: StatefulRouteState) {
	const calls: Call[] = [];
	type SendEntry = {
		key: string;
		chatId: string;
		ownerId: string;
		content: string;
		contentSha256: string;
		status: "processing" | "completed" | "failed" | "unknown";
		claimToken: string | null;
		userMessageId: string | null;
		foxMessageId: string | null;
	};
	const sendLedger = new Map<string, SendEntry>();
	let sendNumber = 0;
	let greetingNumber = 0;
	let greetingStatus: "processing" | "retryable" | "completed" | "unknown" | null = null;
	let greetingToken: string | null = null;
	let greetingMessageId: string | null = null;
	const sendUuid = (value: number) => `90000000-0000-4000-8000-${String(value).padStart(12, "0")}`;
	const sendRpcResponse = (name: string, data: unknown) => ({
		data: state.sendRpcData?.[name] ?? data,
		error: null,
	});
	const greetingRpcRow = (
		outcome: string,
		claimToken: string | null = null,
		message: Record<string, unknown> | null = null,
		transitioned = false,
	) => ({
		data: [{
			outcome,
			claim_token: claimToken,
			message_id: message?.id ?? null,
			message_role: message?.role ?? null,
			message_content: message?.content ?? null,
			message_created_at: message?.created_at ?? null,
			match_status: state.matchStatus,
			transitioned,
		}],
		error: null,
	});
	const sendRpcRow = (entry: SendEntry | null, outcome: string) => {
		const user = entry?.userMessageId ? state.messages.find((message) => message.id === entry.userMessageId) : null;
		const fox = entry?.foxMessageId ? state.messages.find((message) => message.id === entry.foxMessageId) : null;
		return [{
			outcome,
			user_message_id: user?.id ?? null,
			user_content: user?.content ?? null,
			user_created_at: user?.created_at ?? null,
			fox_message_id: fox?.id ?? null,
			fox_content: fox?.content ?? null,
			fox_created_at: fox?.created_at ?? null,
			claim_token: entry?.claimToken ?? null,
		}];
	};
	const sendRecoveryRow = (entry: SendEntry | null, outcome: string) => {
		const user = entry?.userMessageId ? state.messages.find((message) => message.id === entry.userMessageId) : null;
		const fox = entry?.foxMessageId ? state.messages.find((message) => message.id === entry.foxMessageId) : null;
		return [{
			outcome,
			user_message_id: user?.id ?? null,
			user_content: user?.content ?? null,
			user_created_at: user?.created_at ?? null,
			fox_message_id: fox?.id ?? null,
			fox_content: fox?.content ?? null,
			fox_created_at: fox?.created_at ?? null,
		}];
	};
	const createUserMessage = (entry: SendEntry) => {
		const row = {
			id: sendUuid(++sendNumber),
			chat_id: state.chat.id,
			role: "user",
			content: entry.content,
			created_at: `2026-08-24T00:00:${String(sendNumber).padStart(2, "0")}Z`,
		};
		state.onMessageInsert?.("user");
		state.messages.push(row);
		entry.userMessageId = row.id;
	};
	const from = (table: string) => {
		let selection = "";
		let action = "read";
		let insertedRow: Record<string, unknown> | null = null;
		let updateRow: Record<string, unknown> | null = null;
		const filters: Record<string, unknown> = {};
		const query: Record<string, unknown> = {};
		const record = (method: string, args: unknown[]) => calls.push({ table, method, args });
		query.select = (...args: unknown[]) => {
			record("select", args);
			selection = String(args[0] ?? "");
			return query;
		};
		query.eq = (...args: unknown[]) => {
			record("eq", args);
			filters[String(args[0])] = args[1];
			return query;
		};
		query.order = (...args: unknown[]) => {
			record("order", args);
			return query;
		};
		query.insert = (row: unknown) => {
			record("insert", [row]);
			action = "insert";
			insertedRow = row as Record<string, unknown>;
			return query;
		};
		query.update = (row: unknown) => {
			record("update", [row]);
			action = "update";
			updateRow = row as Record<string, unknown>;
			return query;
		};
		query.delete = () => {
			record("delete", []);
			action = "delete";
			return query;
		};
		const result = () => {
			if (action === "delete") {
				const id = String(filters.id ?? "");
				const chatId = String(filters.chat_id ?? "");
				if (id && chatId === state.chat.id) {
					state.deletedIds.push(id);
					state.messages = state.messages.filter((message) => message.id !== id);
				}
				return { data: null, error: null };
			}
			if (action === "update" && table === "matches") {
				const identityMatches = filters.id === MATCH_ID && filters.user_a_id === "user-a" && filters.user_b_id === "user-b";
				const statusMatchesBeforeHook = filters.status === undefined || filters.status === state.matchStatus;
				if (!identityMatches || !statusMatchesBeforeHook) return { data: null, error: { code: "PGRST116", message: "state changed" } };
				const concurrentUpdate = state.onMatchUpdate;
				state.onMatchUpdate = undefined;
				concurrentUpdate?.();
				if (filters.status !== undefined && filters.status !== state.matchStatus) {
					return { data: null, error: { code: "PGRST116", message: "state changed" } };
				}
				if (typeof updateRow?.status !== "string") return { data: null, error: { code: "PGRST116", message: "state changed" } };
				state.matchStatus = updateRow.status;
				return {
					data: { id: MATCH_ID, user_a_id: "user-a", user_b_id: "user-b", status: state.matchStatus, ...updateRow },
					error: null,
				};
			}
			if (action === "insert" && table === "partner_fox_chats") {
				if (state.existingChat) return { data: null, error: { code: "23505", message: "duplicate chat" } };
				const created = { ...state.chat, ...(insertedRow ?? {}) };
				state.chat = created as StatefulRouteState["chat"];
				state.existingChat = created;
				return { data: created, error: null };
			}
			if (action === "insert" && table === "partner_fox_messages") {
				const role = String(insertedRow?.role ?? "");
				state.onMessageInsert?.(role);
				if (role === "fox" && state.foxInsertError) return { data: null, error: state.foxInsertError };
				const created = { id: insertedRow?.id ?? `message-${state.messages.length + 1}`, created_at: "2026-08-24T00:00:00Z", ...insertedRow };
				state.messages.push(created);
				return { data: created, error: null };
			}
			if (table === "partner_fox_chats") {
				const byId = filters.id === state.chat.id;
				const byOwner = filters.user_id === state.chat.user_id;
				const existingQuery = filters.match_id === MATCH_ID && filters.user_id === "user-a" && filters.partner_user_id === "user-b" && filters.id === undefined;
				const ownerQuery = filters.match_id === MATCH_ID && filters.user_id === "user-a" && filters.partner_user_id === undefined && filters.id === undefined;
				if (existingQuery && state.hideExistingChatOnce) {
					state.hideExistingChatOnce = false;
					return { data: null, error: null };
				}
				if (existingQuery || ownerQuery) return { data: state.existingChat, error: null };
				return { data: byId && byOwner ? state.chat : null, error: null };
			}
			if (table === "user_profiles") {
				state.onPartnerProfileRead?.();
				return { data: { nickname: state.nickname, conversation_language: state.conversationLanguage }, error: null };
			}
			if (table === "personas") return { data: { compiled_document: state.persona }, error: null };
			if (table === "partner_fox_messages") {
				if (selection === "id, role, content") return { data: state.messages.map((message) => ({ id: message.id, role: message.role, content: message.content })), error: null };
				state.onMessagesRead?.();
				return { data: state.messages, error: null };
			}
			return { data: null, error: null };
		};
		query.single = async () => {
			record("single", []);
			return result();
		};
		query.maybeSingle = async () => {
			record("maybeSingle", []);
			return result();
		};
		query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve(result()).then(resolve, reject);
		return query;
	};
	const rpc = async (name: string, args: Record<string, unknown>) => {
		calls.push({ table: "rpc", method: name, args: [args] });
		if (name === "recover_partner_fox_message_send") {
			const entry = sendLedger.get(String(args.p_idempotency_key ?? ""));
			if (!entry || entry.chatId !== args.p_chat_id || entry.ownerId !== args.p_owner_id) {
				return { data: sendRecoveryRow(null, "not_found"), error: null };
			}
			if (entry.contentSha256 !== args.p_content_sha256) {
				return { data: sendRecoveryRow(null, "conflict"), error: null };
			}
			const outcome = entry.status === "completed" && (!entry.userMessageId || !entry.foxMessageId) ? "missing" : entry.status;
			return { data: sendRecoveryRow(outcome === "completed" ? entry : null, outcome), error: null };
		}
		if (name === "claim_partner_fox_message_send") {
			const key = String(args.p_idempotency_key ?? "");
			const content = String(args.p_content ?? "");
			const contentSha256 = String(args.p_content_sha256 ?? "");
			const existing = sendLedger.get(key);
			if (existing && (
				existing.chatId !== args.p_chat_id || existing.ownerId !== args.p_owner_id ||
				existing.contentSha256 !== contentSha256 || existing.content !== content
			)) return { data: sendRpcRow(null, "conflict"), error: null };
			if (existing?.status === "completed") {
				const user = state.messages.find((message) => message.id === existing.userMessageId);
				const fox = state.messages.find((message) => message.id === existing.foxMessageId);
				if (!user || !fox) return { data: sendRpcRow(existing, "missing"), error: null };
				return { data: sendRpcRow(existing, "replayed"), error: null };
			}
			if (existing?.status === "unknown") return { data: sendRpcRow(existing, "unknown"), error: null };
			if (existing?.status === "processing") return { data: sendRpcRow(existing, "processing"), error: null };
			if ([...sendLedger.values()].some((entry) => entry.status === "processing")) {
				return { data: sendRpcRow(existing ?? null, "busy"), error: null };
			}
			const entry: SendEntry = existing ?? {
				key,
				chatId: String(args.p_chat_id),
				ownerId: String(args.p_owner_id),
				content,
				contentSha256,
				status: "processing",
				claimToken: null,
				userMessageId: null,
				foxMessageId: null,
			};
			entry.status = "processing";
			entry.claimToken = sendUuid(sendNumber + 1000);
			entry.foxMessageId = null;
			createUserMessage(entry);
			sendLedger.set(key, entry);
			return sendRpcResponse(name, sendRpcRow(entry, "claimed"));
		}
		if (name === "complete_partner_fox_message_send") {
			const entry = sendLedger.get(String(args.p_idempotency_key ?? ""));
			if (!entry || entry.status !== "processing" || entry.claimToken !== args.p_claim_token) {
				return { data: sendRpcRow(entry ?? null, "stale"), error: null };
			}
			const fox = {
				id: sendUuid(++sendNumber),
				chat_id: state.chat.id,
				role: "fox",
				content: String(args.p_fox_content ?? ""),
				created_at: `2026-08-24T00:00:${String(sendNumber).padStart(2, "0")}Z`,
			};
			state.onMessageInsert?.("fox");
			state.messages.push(fox);
			entry.foxMessageId = fox.id;
			entry.status = "completed";
			entry.claimToken = null;
			return sendRpcResponse(name, sendRpcRow(entry, "completed"));
		}
		if (name === "finish_partner_fox_message_send") {
			const entry = sendLedger.get(String(args.p_idempotency_key ?? ""));
			const outcome = args.p_outcome;
			if (outcome !== "failed" && outcome !== "unknown") return { data: sendRpcRow(entry ?? null, "invalid_input"), error: null };
			if (!entry || entry.status !== "processing" || entry.claimToken !== args.p_claim_token) {
				return { data: sendRpcRow(entry ?? null, "stale"), error: null };
			}
			entry.status = outcome;
			entry.claimToken = null;
			if (outcome === "failed" && entry.userMessageId) {
				state.deletedIds.push(entry.userMessageId);
				state.messages = state.messages.filter((message) => message.id !== entry.userMessageId);
				entry.userMessageId = null;
			}
			return sendRpcResponse(name, sendRpcRow(entry, outcome));
		}
		if (name === "claim_partner_fox_greeting") {
			if (greetingStatus === "completed") {
				const message = state.messages.find((row) => row.id === greetingMessageId && row.role === "fox");
				return message ? greetingRpcRow("completed", null, message) : greetingRpcRow("missing");
			}
			const first = state.messages[0];
			if (first) {
				if (first.role === "fox") {
					greetingStatus = "completed";
					greetingMessageId = String(first.id);
					return greetingRpcRow("completed", null, first);
				}
				greetingStatus = "unknown";
				return greetingRpcRow("message_present");
			}
			if (greetingStatus === "unknown") return greetingRpcRow("unknown");
			if (greetingStatus === "processing") return greetingRpcRow("busy");
			greetingStatus = "processing";
			greetingToken = sendUuid(5000 + ++greetingNumber);
			return greetingRpcRow("claimed", greetingToken);
		}
		if (name === "complete_partner_fox_greeting") {
			if (state.greetingRpcError) return { data: null, error: state.greetingRpcError };
			if (state.greetingRpcData !== undefined) return { data: state.greetingRpcData, error: null };
			const token = String(args.p_claim_token ?? "");
			if (greetingStatus !== "processing" || token !== greetingToken) return greetingRpcRow("stale");
			const content = String(args.p_content ?? "");
			state.onGreetingRpc?.(content);
			const first = state.messages[0];
			if (first) {
				if (first.role === "fox") {
					return greetingRpcRow("completed", null, first);
				}
				greetingStatus = "unknown";
				return greetingRpcRow("message_present");
			}
			const created = {
				id: sendUuid(6000 + ++greetingNumber),
				chat_id: state.chat.id,
				role: "fox",
				content,
				created_at: "2026-08-24T00:00:00Z",
			};
			state.messages.push(created);
			const transitioned = state.matchStatus === "fox_conversation_completed";
			if (transitioned) state.matchStatus = "partner_chat_started";
			greetingStatus = "completed";
			greetingMessageId = created.id;
			greetingToken = null;
			return greetingRpcRow("completed", null, created, transitioned);
		}
		if (name === "retry_partner_fox_greeting_before_provider") {
			if (greetingStatus !== "processing" || String(args.p_claim_token ?? "") !== greetingToken) {
				return { data: [{ outcome: "stale", claim_token: null }], error: null };
			}
			greetingStatus = "retryable";
			greetingToken = null;
			return { data: [{ outcome: "retryable", claim_token: null }], error: null };
		}
		return { data: null, error: { message: "unexpected rpc" } };
	};
	return { from, rpc, calls, state, sendLedger };
}

function makeRouteState(overrides: Partial<StatefulRouteState> = {}): StatefulRouteState {
	return {
		chat: { id: CHAT_ID, match_id: MATCH_ID, user_id: "user-a", partner_user_id: "user-b", created_at: "2026-08-24T00:00:00Z" },
		matchStatus: "fox_conversation_completed",
		existingChat: null,
		persona: "A calm partner persona",
		nickname: "Partner",
		messages: [{ id: "older-fox", chat_id: CHAT_ID, role: "fox", content: "history-secret", created_at: "2026-08-24T00:00:00Z" }],
		accessAllowed: true,
		startAllowed: true,
		startStatus: "fox_conversation_completed",
		foxInsertError: null,
		greetingRpcError: null,
		deletedIds: [],
		accessCalls: 0,
		startCalls: 0,
		...overrides,
	};
}

function allowRouteGuards(state: StatefulRouteState) {
	 mockedCheckPartnerFoxChatStartAccess.mockImplementation(async () => {
		state.startCalls += 1;
		return state.startAllowed
			? { ok: true, matchStatus: state.startStatus as "fox_conversation_completed", userAId: state.chat.user_id, userBId: state.chat.partner_user_id, partnerUserId: state.chat.partner_user_id }
			: { ok: false, reason: "forbidden" };
	});
	 mockedCheckPartnerFoxChatAccess.mockImplementation(async (_supabase, expectation) => {
		state.accessCalls += 1;
		state.onAccessCall?.(state.accessCalls);
		if (!state.accessAllowed || expectation.partnerUserId !== state.chat.partner_user_id || expectation.chatId !== state.chat.id) return { ok: false, reason: "forbidden" };
		return { ok: true, matchStatus: state.matchStatus as "partner_chat_started", partnerUserId: state.chat.partner_user_id };
	});
}

	describe("partner-fox-chats rechecks current access around every output boundary", () => {
	it("canonicalizes the uppercase UUID emitted by native JSONEncoder before exact ownership checks", async () => {
		const canonicalMatch = "730ccffd-95dd-4771-bba3-693eb15818b8";
		const state = makeRouteState({ messages: [], chat: { id: CHAT_ID, match_id: canonicalMatch, user_id: "user-a", partner_user_id: "user-b", created_at: "2026-08-24T00:00:00Z" } });
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(makeStatefulRouteSupabase(state) as never);
		mockedChatComplete.mockResolvedValueOnce("Hello there.");
		const response = await buildApp().request("/api/partner-fox-chats", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ match_id: canonicalMatch.toUpperCase() }) }, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(200);
		expect(mockedCheckPartnerFoxChatStartAccess).toHaveBeenCalledWith(expect.anything(), { matchId: canonicalMatch, userId: "user-a" });
		expect(await response.json()).toMatchObject({ data: { match_id: canonicalMatch } });
		expect(mockedChatComplete).toHaveBeenCalledTimes(1);
	});
	it("denies a greeting when the pair is revoked during provider await", async () => {
		const state = makeRouteState({ messages: [] });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockImplementation(async () => {
			state.accessAllowed = false;
			return "provider-secret";
		});

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("provider-secret");
		expect(mockedChatComplete).toHaveBeenCalledTimes(1);
		expect(state.messages).toHaveLength(0);
	});

	it("returns a provider greeting for an unblocked later contact state", async () => {
		const state = makeRouteState({ matchStatus: "partner_chat_started", startStatus: "partner_chat_started", messages: [] });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockResolvedValue("greeting");

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });
		const body = await response.json() as { data?: { first_message?: Record<string, unknown> } };
		expect(response.status).toBe(200);
		expect(body.data?.first_message).toEqual(expect.objectContaining({ role: "fox", content: "greeting" }));
		expect(body.data?.first_message).not.toHaveProperty("chat_id");
	});

	it("claims an empty chat before provider work so concurrent starts generate once", async () => {
		const state = makeRouteState({ messages: [] });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		let markProviderStarted!: () => void;
		let releaseProvider!: () => void;
		const providerStarted = new Promise<void>((resolve) => { markProviderStarted = resolve; });
		const providerGate = new Promise<void>((resolve) => { releaseProvider = resolve; });
		mockedChatComplete.mockImplementation(async () => {
			markProviderStarted();
			await providerGate;
			return "single greeting";
		});
		const request = () => buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });

		const firstPromise = request();
		await providerStarted;
		const second = await request();
		expect(second.status).toBe(409);
		expect(mockedChatComplete).toHaveBeenCalledTimes(1);
		releaseProvider();
		const first = await firstPromise;
		expect(first.status).toBe(200);
		expect(state.messages.filter((message) => message.role === "fox")).toHaveLength(1);
	});

	it("replays an existing authoritative first Fox message without provider access", async () => {
		const state = makeRouteState({
			existingChat: { id: CHAT_ID, match_id: MATCH_ID, user_id: "user-a", partner_user_id: "user-b", created_at: "2026-08-24T00:00:00Z" },
			messages: [{ id: "stored-greeting", chat_id: CHAT_ID, role: "fox", content: "Already saved", created_at: "2026-08-24T00:00:00Z" }],
		});
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		});
		const body = await response.json() as { data?: { first_message?: { id?: string; content?: string } } };

		expect(response.status).toBe(200);
		expect(body.data?.first_message).toEqual({ id: "stored-greeting", role: "fox", content: "Already saved", created_at: "2026-08-24T00:00:00Z" });
		expect(mockedChatComplete).not.toHaveBeenCalled();
	});

	it("does not create a chat or fabricated greeting when provider configuration is absent", async () => {
		const state = makeRouteState({ messages: [] });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		});

		expect(response.status).toBe(503);
		expect(state.existingChat).toBeNull();
		expect(state.messages).toHaveLength(0);
		expect(mockedChatComplete).not.toHaveBeenCalled();
	});

	it("keeps an ambiguous greeting provider failure unresolved and refuses a second generation", async () => {
		const state = makeRouteState({ messages: [] });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockRejectedValueOnce(new Error("provider failed"));

		const firstResponse = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(firstResponse.status).toBe(500);
		expect(state.existingChat).toEqual(expect.objectContaining({ id: CHAT_ID }));
		expect(state.messages).toHaveLength(0);
		expect(state.deletedIds).toHaveLength(0);

		mockedChatComplete.mockResolvedValueOnce("retry greeting");
		const retryResponse = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(retryResponse.status).toBe(409);
		expect(mockedChatComplete).toHaveBeenCalledTimes(1);
		expect(state.messages).toHaveLength(0);
		expect(state.deletedIds).toHaveLength(0);
	});

	it("keeps a populated chat without a first Fox reply on the conflict path", async () => {
		const state = makeRouteState({
			existingChat: { id: CHAT_ID, match_id: MATCH_ID, user_id: "user-a", partner_user_id: "user-b", created_at: "2026-08-24T00:00:00Z" },
			messages: [{ id: "only-user", chat_id: CHAT_ID, role: "user", content: "hello", created_at: "2026-08-24T00:00:00Z" }],
		});
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockResolvedValue("must not run");

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(409);
		expect(mockedChatComplete).not.toHaveBeenCalled();
	});

	it("recovers the exact owner row after a unique chat insert race", async () => {
		const state = makeRouteState({
			existingChat: { id: CHAT_ID, match_id: MATCH_ID, user_id: "user-a", partner_user_id: "user-b", created_at: "2026-08-24T00:00:00Z" },
			messages: [],
			hideExistingChatOnce: true,
		});
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockResolvedValue("race retry");

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(200);
		expect((await response.json() as { data?: { first_message?: { content?: string } } }).data?.first_message?.content).toBe("race retry");
		expect(state.messages).toHaveLength(1);
		expect(supabase.calls).toEqual(expect.arrayContaining([
			expect.objectContaining({ table: "partner_fox_chats", method: "eq", args: ["match_id", MATCH_ID] }),
			expect.objectContaining({ table: "partner_fox_chats", method: "eq", args: ["user_id", "user-a"] }),
		]));
	});

	it("does not replace a user message that wins before greeting persistence", async () => {
		const state = makeRouteState({ messages: [], onGreetingRpc: () => {
			state.messages.push({ id: "user-winner", chat_id: CHAT_ID, role: "user", content: "hello", created_at: "2026-08-24T00:00:00Z" });
		} });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockResolvedValue("provider greeting");

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(409);
		expect(state.messages.map((message) => message.id)).toEqual(["user-winner"]);
		expect(state.deletedIds).toHaveLength(0);
	});

	it("does not expose a greeting when access expires after atomic persistence", async () => {
		const state = makeRouteState({ messages: [], onGreetingRpc: () => { state.accessAllowed = false; } });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockResolvedValue("provider greeting");

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });

		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("provider greeting");
		expect(state.messages).toEqual([
			expect.objectContaining({ role: "fox", content: "provider greeting" }),
		]);
		expect(state.deletedIds).toHaveLength(0);
	});

	it("rejects malformed greeting claim/completion DTO rows", async () => {
		const validRow = {
			outcome: "completed",
			claim_token: null,
			message_id: "90000000-0000-4000-8000-000000000001",
			message_role: "fox",
			message_content: "greeting",
			message_created_at: "2026-08-24T00:00:00Z",
			match_status: "partner_chat_started",
			transitioned: true,
		};
		const invoke = async (rpcData: unknown) => {
			const state = makeRouteState({ messages: [], greetingRpcData: rpcData });
			const supabase = makeStatefulRouteSupabase(state);
			allowRouteGuards(state);
			mockedGetSupabaseClient.mockReturnValue(supabase as never);
			return buildApp().request("/api/partner-fox-chats", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ match_id: MATCH_ID }),
			}, { MISTRAL_API_KEY: "test-key" });
		};
		mockedChatComplete.mockResolvedValue("greeting");

		let response = await invoke([{ ...validRow, message_content: "" }]);
		expect(response.status).toBe(500);
		response = await invoke([validRow, validRow]);
		expect(response.status).toBe(500);
		response = await invoke([{ ...validRow, message_content: "x".repeat(2001) }]);
		expect(response.status).toBe(500);
	});

	it("keeps an uncertain user attempt when the exact chat is reassigned during provider await", async () => {
		const state = makeRouteState();
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockImplementation(async () => {
			state.chat.partner_user_id = "user-c";
			return "provider-secret";
		});

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello" }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("provider-secret");
		expect(state.messages.map((message) => message.role)).toEqual(["fox", "user"]);
		expect(state.deletedIds).toHaveLength(0);
	});

	it("seals an ambiguous provider failure as unknown and refuses same-key regeneration", async () => {
		const state = makeRouteState();
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockRejectedValue(new Error("provider failed"));
		const key = "80000000-0000-4000-8000-00000000d271";
		const request = () => buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello", idempotency_key: key }),
		}, { MISTRAL_API_KEY: "test-key" });

		const response = await request();
		expect(response.status).toBe(500);
		expect(state.deletedIds).toHaveLength(0);
		expect(state.messages.filter((message) => message.role === "user" && message.content === "hello")).toHaveLength(1);

		const retry = await request();
		expect(retry.status).toBe(409);
		expect(mockedChatComplete).toHaveBeenCalledTimes(1);
		expect(state.messages.filter((message) => message.role === "user" && message.content === "hello")).toHaveLength(1);
	});

	it("returns NOT_FOUND and keeps the user attempt when an ambiguous provider failure follows access revocation", async () => {
		const state = makeRouteState();
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockImplementation(async () => {
			state.accessAllowed = false;
			throw new Error("provider failed after revocation");
		});

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello" }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("provider failed after revocation");
		expect(state.deletedIds).toHaveLength(0);
		expect(state.messages.map((message) => message.role)).toEqual(["fox", "user"]);
	});

	it("replays a completed Partner Ward send after the client loses the response", async () => {
		const state = makeRouteState();
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockResolvedValue("one generated reply");
		const key = "80000000-0000-4000-8000-00000000d272";
		const request = (content: string) => buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content, idempotency_key: key }),
		}, { MISTRAL_API_KEY: "test-key" });

		// Drop the first response as a client would after a transport interruption.
		const first = await request("hello");
		expect(first.status).toBe(200);
		const recovery = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages/send-recovery`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ idempotency_key: key, content_sha256: await sha256Hex("hello") }),
		});
		const recoveredBody = await recovery.json() as { data?: { outcome?: string; user_message?: { content?: string }; fox_message?: { content?: string } } };
		const retry = await request("hello");
		const retriedPair = (await retry.json() as { data: { user_message: { id: string }; fox_message: { id: string } } }).data;

		expect(recovery.status).toBe(200);
		expect(recoveredBody.data?.outcome).toBe("completed");
		expect(recoveredBody.data?.user_message?.content).toBe("hello");
		expect(recoveredBody.data?.fox_message?.content).toBe("one generated reply");
		expect(retry.status).toBe(200);
		expect(state.messages.filter((message) => message.role === "user" && message.content === "hello")).toHaveLength(1);
		expect(state.messages.filter((message) => message.role === "fox" && message.content === "one generated reply")).toHaveLength(1);
		expect(mockedChatComplete).toHaveBeenCalledTimes(1);
		const firstPair = supabase.sendLedger.get(key);
		expect(retriedPair.user_message.id).toBe(firstPair?.userMessageId);
		expect(retriedPair.fox_message.id).toBe(firstPair?.foxMessageId);

		const changedContent = await request("different body");
		expect(changedContent.status).toBe(409);
		expect(mockedChatComplete).toHaveBeenCalledTimes(1);
		expect(state.messages.filter((message) => message.role === "user")).toHaveLength(1);
	});

	it("rejects a malformed claimed RPC row before starting provider generation", async () => {
		const state = makeRouteState({
			sendRpcData: {
				claim_partner_fox_message_send: [{
					outcome: "claimed",
					user_message_id: "90000000-0000-4000-8000-000000000001",
					user_content: "hello",
					user_created_at: "2026-08-24T00:00:01Z",
					fox_message_id: null,
				fox_content: null,
				fox_created_at: null,
				claim_token: "not-a-uuid",
				}],
		},
		});
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello", idempotency_key: "80000000-0000-4000-8000-00000000d278" }),
		}, { MISTRAL_API_KEY: "test-key" });

		expect(response.status).toBe(500);
		expect(mockedChatComplete).not.toHaveBeenCalled();
		expect(state.messages.filter((message) => message.role === "fox")).toHaveLength(1);
	});

	it("does not expose a recovered pair when the stored user body fails its receipt hash", async () => {
		const state = makeRouteState();
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockResolvedValue("one reply");
		const key = "80000000-0000-4000-8000-00000000d284";
		const send = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello", idempotency_key: key }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(send.status).toBe(200);
		const entry = supabase.sendLedger.get(key);
		const userMessage = state.messages.find((message) => message.id === entry?.userMessageId);
		if (userMessage) userMessage.content = "tampered partner text";

		const recovery = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages/send-recovery`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ idempotency_key: key, content_sha256: await sha256Hex("hello") }),
		});
		expect(recovery.status).toBe(500);
		expect(await recovery.text()).not.toContain("tampered partner text");
		expect(mockedChatComplete).toHaveBeenCalledTimes(1);
	});

	it("allows the same key to recover after an explicit pre-provider rejection", async () => {
		const state = makeRouteState();
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete
			.mockRejectedValueOnce(Object.assign(new Error("rate limited"), { statusCode: 429 }))
			.mockResolvedValueOnce("recovered reply");
		const key = "80000000-0000-4000-8000-00000000d273";
		const request = () => buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello", idempotency_key: key }),
		}, { MISTRAL_API_KEY: "test-key" });

		const rejected = await request();
		expect(rejected.status).toBe(500);
		expect(state.messages.filter((message) => message.role === "user" && message.content === "hello")).toHaveLength(0);
		const recovered = await request();
		expect(recovered.status).toBe(200);
		expect(mockedChatComplete).toHaveBeenCalledTimes(2);
		expect(state.messages.filter((message) => message.role === "user" && message.content === "hello")).toHaveLength(1);
		expect(state.messages.filter((message) => message.role === "fox" && message.content === "recovered reply")).toHaveLength(1);
	});

	it("preserves a later match state and never cleans a shared greeting", async () => {
		const state = makeRouteState({ matchStatus: "direct_chat_active", startStatus: "direct_chat_active", messages: [] });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockResolvedValue("greeting");

		const response = await buildApp().request("/api/partner-fox-chats", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(200);
		expect(state.matchStatus).toBe("direct_chat_active");
		expect(state.deletedIds).toHaveLength(0);
		expect(state.messages).toHaveLength(1);
		const matchUpdates = supabase.calls.filter((call) => call.table === "matches" && call.method === "update");
		expect(matchUpdates).toHaveLength(0);
		expect(supabase.calls).not.toEqual(expect.arrayContaining([expect.objectContaining({ table: "partner_fox_chats", method: "delete" })]));
	});

	it("does not return detail content when access expires after the partner profile read", async () => {
		const state = makeRouteState({ onPartnerProfileRead: () => { state.accessAllowed = false; } });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}`);
		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("Partner");
	});

	it("does not return history when access expires after the messages read", async () => {
		const state = makeRouteState({ onMessagesRead: () => { state.accessAllowed = false; } });
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`);
		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("history-secret");
	});

	it("keeps the committed pair when access expires after the atomic fox save", async () => {
		const state = makeRouteState({
			messages: [{ id: "other-attempt", chat_id: CHAT_ID, role: "fox", content: "keep-me", created_at: "2026-08-24T00:00:00Z" }],
			onMessageInsert: (role) => { if (role === "fox") state.accessAllowed = false; },
		});
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockResolvedValue("reply-secret");

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello" }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("reply-secret");
		expect(state.messages.map((message) => message.role)).toEqual(["fox", "user", "fox"]);
		expect(state.deletedIds).toHaveLength(0);
	});

	it("returns unavailable without a provider key and persists no fabricated reply", async () => {
		const state = makeRouteState();
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello" }),
		});
		expect(response.status).toBe(503);
		expect(mockedChatComplete).not.toHaveBeenCalled();
		expect(state.messages).toEqual([expect.objectContaining({ id: "older-fox", role: "fox" })]);
		expect(supabase.sendLedger.size).toBe(0);
	});

	it("rejects conflicting body and header idempotency keys before claiming a send", async () => {
		const state = makeRouteState();
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				"Idempotency-Key": "80000000-0000-4000-8000-00000000d274",
			},
			body: JSON.stringify({ content: "hello", idempotency_key: "80000000-0000-4000-8000-00000000d275" }),
		}, { MISTRAL_API_KEY: "test-key" });
		expect(response.status).toBe(400);
		expect(mockedChatComplete).not.toHaveBeenCalled();
		expect(supabase.sendLedger.size).toBe(0);
		expect(state.messages).toHaveLength(1);
	});

	it("keeps HTTP 408 provider outcomes unknown and does not regenerate on retry", async () => {
		const state = makeRouteState();
		const supabase = makeStatefulRouteSupabase(state);
		allowRouteGuards(state);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		mockedChatComplete.mockRejectedValueOnce(Object.assign(new Error("provider timeout"), { statusCode: 408 }));
		const key = "80000000-0000-4000-8000-00000000d276";
		const request = () => buildApp().request(`/api/partner-fox-chats/${CHAT_ID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello", idempotency_key: key }),
		}, { MISTRAL_API_KEY: "test-key" });

		const first = await request();
		expect(first.status).toBe(500);
		const retry = await request();
		expect(retry.status).toBe(409);
		expect(mockedChatComplete).toHaveBeenCalledTimes(1);
		expect(state.deletedIds).toHaveLength(0);
		expect(state.messages.filter((message) => message.role === "user" && message.content === "hello")).toHaveLength(1);
	});
});


describe("fixed recording pair Partner Ward greeting", () => {
 const ren = "9d836fee-7b93-41ce-b577-34a63006aaea";
 const maya = "a88a89e2-5421-5ce9-a33b-76d512898c37";
 const bindings = { MISTRAL_API_KEY: "test-key", RECORDING_REHEARSAL_ENABLED: "enabled", RECORDING_REHEARSAL_PAIR: "demo-maya-ren", RECORDING_REHEARSAL_ISSUED_AT: "2026-09-30T08:00:00Z", RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-30T10:00:00Z" };
 function setup(peer = maya) {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-30T08:40:00Z")); authActor.id = ren;
  const parsed = readRecordingRehearsalConfig(bindings); if (parsed.kind !== "active") throw new Error("test window");
  const state = makeRouteState({ chat: { id: CHAT_ID, match_id: MATCH_ID, user_id: ren, partner_user_id: peer, created_at: "2026-09-30T08:35:00Z" }, messages: [], persona: "日本語の架空プロフィール。日本語で話してください。", conversationLanguage: "en" });
  const supabase = makeStatefulRouteSupabase(state); allowRouteGuards(state); mockedGetSupabaseClient.mockReturnValue(supabase as never);
  const request = () => buildApp(parsed.config).request("/api/partner-fox-chats", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ match_id: MATCH_ID }) }, bindings);
  return { state, supabase, request };
 }
 it("uses saved English and caps the one greeting despite Japanese reference text", async () => {
  try { const { request } = setup(); mockedChatComplete.mockResolvedValueOnce("Hello! Shall we talk?"); const response = await request(); expect(response.status).toBe(200); expect(mockedChatComplete).toHaveBeenCalledTimes(1); expect(mockedChatComplete.mock.calls[0][1][0].content).toContain("Always respond in English"); expect(mockedChatComplete.mock.calls[0][2]).toMatchObject({ maxTokens: 80 }); } finally { vi.useRealTimers(); }
 });
 it("rejects another synthetic counterpart before the greeting or chat write", async () => {
  try { const { state, request } = setup("96b31c0a-b8c4-4536-ada2-f3537dadd146"); const response = await request(); expect(response.status).toBe(404); expect(mockedChatComplete).not.toHaveBeenCalled(); expect(state.existingChat).toBeNull(); expect(state.messages).toHaveLength(0); } finally { vi.useRealTimers(); }
 });
 it("suppresses a greeting that returns after the real window deadline", async () => {
  try { const { state, request } = setup(); mockedChatComplete.mockImplementationOnce(async () => { vi.setSystemTime(new Date("2026-09-30T10:00:00Z")); return "Hello!"; }); const response = await request(); expect(response.status).toBe(404); expect(mockedChatComplete).toHaveBeenCalledTimes(1); expect(state.messages).toHaveLength(0); } finally { vi.useRealTimers(); }
 });
});
