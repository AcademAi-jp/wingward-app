import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * Route-level coverage for POST /api/direct-chats/:id/messages. The route
 * checks both that the room is active and that the pair is eligible before
 * inserting. The database triggers are the backstops for changes that race
 * the application checks; these tests cover the clean, non-disclosing API
 * responses and the no-INSERT guarantees.
 */

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "user-me");
		await next();
	},
	requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => {
		await next();
	},
}));

vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import { sha256Hex } from "../services/message-idempotency";
import { errorHandler } from "../middleware/error";
import directChats from "./direct-chats";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

interface FakeOpts {
	directRpcData?: unknown;
	directRecoveryData?: unknown;
	blockRow?: { id: string } | null;
	blockError?: { message: string } | null;
	profileRows?: Array<Record<string, unknown>>;
	matchUsers?: { user_a_id: string; user_b_id: string };
	roomStatus?: "active" | "closed" | "missing";
	roomError?: { code?: string; message?: string } | null;
}

type RoomQuery = {
	eq: (column: string, value: unknown) => RoomQuery;
	single: () => Promise<{
		data: { match_id: string } | null;
		error: { code?: string; message?: string } | null;
	}>;
};

const messagesInserted: Record<string, unknown>[] = [];
const roomFilters: Array<[string, unknown]> = [];
const directRpcCalls: Array<Record<string, unknown>> = [];
const directMessagesByKey = new Map<string, Record<string, unknown>>();

function makeFakeSupabase(opts: FakeOpts) {
	return {
		rpc: async (name: string, args: Record<string, unknown>) => {
			directRpcCalls.push({ name, ...args });
			if (name === "recover_direct_chat_message_send") {
				if (opts.directRecoveryData !== undefined) return { data: opts.directRecoveryData, error: null };
				const row = directMessagesByKey.get(String(args.p_idempotency_key));
				if (!row || row.room_id !== args.p_room_id || row.sender_id !== args.p_sender_id) {
					return { data: [{ outcome: "not_found", message_id: null, message_content: null, message_created_at: null }], error: null };
				}
				if (row.content_sha256 !== args.p_content_sha256) {
					return { data: [{ outcome: "conflict", message_id: null, message_content: null, message_created_at: null }], error: null };
				}
				return { data: [{ outcome: "found", message_id: row.id, message_content: row.content, message_created_at: row.created_at }], error: null };
			}
			if (name !== "persist_direct_chat_message") return { data: null, error: { message: "unexpected RPC" } };
			if (opts.directRpcData !== undefined) return { data: opts.directRpcData, error: null };
			const key = String(args.p_idempotency_key);
			const existing = directMessagesByKey.get(key);
			if (existing) {
				if (
					existing.room_id !== args.p_room_id || existing.sender_id !== args.p_sender_id ||
					existing.content_sha256 !== args.p_content_sha256 || existing.content !== args.p_content
				) return { data: [{ outcome: "conflict", message_id: null, message_content: null, message_created_at: null }], error: null };
				return { data: [{
					outcome: "replayed",
					message_id: existing.id,
					message_content: existing.content,
					message_created_at: existing.created_at,
				}], error: null };
			}
			const row = {
				id: `90000000-0000-4000-8000-${String(directMessagesByKey.size + 1).padStart(12, "0")}`,
				room_id: args.p_room_id,
				sender_id: args.p_sender_id,
				content_sha256: args.p_content_sha256,
				content: args.p_content,
				created_at: "2026-09-26T00:00:00Z",
			};
			directMessagesByKey.set(key, row);
			messagesInserted.push(row);
			return { data: [{
				outcome: "inserted",
				message_id: row.id,
				message_content: row.content,
				message_created_at: row.created_at,
			}], error: null };
		},
		from: (table: string) => {
			if (table === "direct_chat_rooms") {
				const roomQuery: RoomQuery = {
					eq: (column: string, value: unknown) => {
						roomFilters.push([column, value]);
						return roomQuery;
					},
					single: async () => {
						const status = opts.roomStatus ?? "active";
						const activeFilterApplied = roomFilters.some(([column, value]) => column === "status" && value === "active");
						const roomVisible = status === "active" || (status === "closed" && !activeFilterApplied);
						if (opts.roomError !== undefined) return { data: null, error: opts.roomError };
						return roomVisible
							? { data: { match_id: "match-1" }, error: null }
							: { data: null, error: { code: "PGRST116", message: "No rows returned" } };
					},
				};
				return { select: () => roomQuery };
			}
			if (table === "matches") {
				return { select: () => ({ eq: () => ({ single: async () => ({ data: opts.matchUsers ?? { user_a_id: "user-me", user_b_id: "user-partner" }, error: null }) }) }) };
			}
			if (table === "user_profiles") {
				return { select: () => ({ in: async () => ({ data: opts.profileRows ?? [
					{ id: "user-me", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
					{ id: "user-partner", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
				], error: null }) }) };
			}
			if (table === "blocks") {
				return {
					select: () => ({
						or: () => ({
							limit: () => ({
								maybeSingle: async () => ({ data: opts.blockRow ?? null, error: opts.blockError ?? null }),
							}),
						}),
					}),
				};
			}
			if (table === "direct_chat_messages") {
				return {
					insert: (row: Record<string, unknown>) => {
						messagesInserted.push(row);
						return { select: () => ({ single: async () => ({ data: { id: "msg-1", content: row.content, created_at: "2026-08-22T00:00:00.000Z" }, error: null }) }) };
					},
				};
			}
			throw new Error(`unexpected table in test fake: ${table}`);
		},
	};
}

function makeApp() {
	const app = new Hono();
	app.onError(errorHandler);
	app.route("/api/direct-chats", directChats);
	return app;
}

async function postMessage(opts: FakeOpts = {}) {
	mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase(opts) as never);
	return makeApp().request("/api/direct-chats/room-1/messages", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ content: "hello" }),
	});
}

beforeEach(() => {
	messagesInserted.length = 0;
	roomFilters.length = 0;
	directRpcCalls.length = 0;
	directMessagesByKey.clear();
});

describe("POST /api/direct-chats/:id/messages enforces active-room and pair authorization", () => {
	it("sends the message when there is no block", async () => {
		const res = await postMessage({ blockRow: null });

		expect(res.status).toBe(200);
		expect(messagesInserted).toHaveLength(1);
		expect(roomFilters).toEqual([
			["status", "active"],
			["id", "room-1"],
		]);
	});

	it("replays one committed row after the client retries the same key and content", async () => {
		const supabase = makeFakeSupabase({ blockRow: null });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		const request = (content: string) => makeApp().request("/api/direct-chats/room-1/messages", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content, idempotency_key: "80000000-0000-4000-8000-00000000d271" }),
		});

		const first = await request("hello");
		const firstBody = await first.json() as { data?: { id?: string } };
		const retry = await request("hello");
		const retryBody = await retry.json() as { data?: { id?: string } };

		expect(first.status).toBe(200);
		expect(retry.status).toBe(200);
		expect(retryBody.data?.id).toBe(firstBody.data?.id);
		expect(messagesInserted).toHaveLength(1);
		expect(directRpcCalls).toHaveLength(2);
		expect(directRpcCalls[0]).toEqual(expect.objectContaining({
			p_room_id: "room-1",
			p_sender_id: "user-me",
			p_idempotency_key: "80000000-0000-4000-8000-00000000d271",
			p_content: "hello",
		}));

		const changed = await request("different content");
		expect(changed.status).toBe(409);
		expect(messagesInserted).toHaveLength(1);
	});

	it("rejects conflicting body and header idempotency keys before writing", async () => {
		const supabase = makeFakeSupabase({ blockRow: null });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		const response = await makeApp().request("/api/direct-chats/room-1/messages", {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				"Idempotency-Key": "80000000-0000-4000-8000-00000000d274",
			},
			body: JSON.stringify({ content: "hello", idempotency_key: "80000000-0000-4000-8000-00000000d275" }),
		});

		expect(response.status).toBe(400);
		expect(directRpcCalls).toHaveLength(0);
		expect(messagesInserted).toHaveLength(0);
	});

	it("rejects malformed successful RPC rows before returning a message", async () => {
		const supabase = makeFakeSupabase({
			blockRow: null,
			directRpcData: [{
				outcome: "inserted",
				message_id: "not-a-uuid",
				message_content: "hello",
				message_created_at: "2026-09-26T00:00:00Z",
			}],
		});
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await makeApp().request("/api/direct-chats/room-1/messages", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello", idempotency_key: "80000000-0000-4000-8000-00000000d277" }),
		});

		expect(response.status).toBe(500);
		expect(messagesInserted).toHaveLength(0);
	});

	it("recovers a committed row after the app loses the send response", async () => {
		const supabase = makeFakeSupabase({ blockRow: null });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		const roomID = "80000000-0000-4000-8000-00000000d280";
		const key = "80000000-0000-4000-8000-00000000d279";
		const send = await makeApp().request(`/api/direct-chats/${roomID}/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello", idempotency_key: key }),
		});
		const recovery = await makeApp().request(`/api/direct-chats/${roomID}/messages/send-recovery`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ idempotency_key: key, content_sha256: await sha256Hex("hello") }),
		});
		const body = await recovery.json() as { data?: { outcome?: string; message?: { content?: string } } };

		expect(send.status).toBe(200);
		expect(recovery.status).toBe(200);
		expect(body.data?.outcome).toBe("found");
		expect(body.data?.message?.content).toBe("hello");
		expect(messagesInserted).toHaveLength(1);
		expect(directRpcCalls.at(-1)).toEqual(expect.objectContaining({
			name: "recover_direct_chat_message_send",
			p_room_id: roomID,
			p_sender_id: "user-me",
			p_idempotency_key: key,
			p_content_sha256: await sha256Hex("hello"),
		}));
	});

	it("refuses to return recovered text when the live content no longer matches its stored hash", async () => {
		const key = "80000000-0000-4000-8000-00000000d282";
		const roomID = "80000000-0000-4000-8000-00000000d283";
		const supabase = makeFakeSupabase({
			blockRow: null,
			directRecoveryData: [{
				outcome: "found",
				message_id: "90000000-0000-4000-8000-000000000001",
				message_content: "tampered text",
				message_created_at: "2026-09-26T00:00:00Z",
			}],
		});
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		const recovery = await makeApp().request(`/api/direct-chats/${roomID}/messages/send-recovery`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ idempotency_key: key, content_sha256: await sha256Hex("original text") }),
		});

		expect(recovery.status).toBe(500);
		expect(await recovery.text()).not.toContain("tampered text");
	});

	it("refuses a caller who is not one of the match participants before inserting", async () => {
		const res = await postMessage({
			matchUsers: { user_a_id: "user-other-a", user_b_id: "user-other-b" },
		});

		expect(res.status).toBe(403);
		expect(await res.json()).toEqual({ error: { code: "FORBIDDEN", message: "Access denied" } });
		expect(messagesInserted).toHaveLength(0);
	});

	it("refuses with the same FORBIDDEN text as a non-participant, and never inserts a message, when a block exists", async () => {
		const res = await postMessage({ blockRow: { id: "block-1" } });
		const body = (await res.json()) as { error?: { message?: string } };

		expect(res.status).toBe(403);
		expect(body.error?.message).toBe("Access denied");
		expect(messagesInserted).toHaveLength(0);
	});

	it("fails closed when the blocks lookup itself errors — an unreadable block list is not 'not blocked'", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const res = await postMessage({ blockError: { message: "connection reset" } });

		expect(res.status).toBe(500);
		expect(messagesInserted).toHaveLength(0);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[direct-chats] blocks lookup failed");
		expect(consoleErrorSpy.mock.calls.flat()).not.toContain("connection reset");
		expect(consoleErrorSpy.mock.calls.flat()).not.toContain("room-1");
		consoleErrorSpy.mockRestore();
	});

	it("treats a closed room like an unknown room without inserting or exposing room state", async () => {
		const closedRes = await postMessage({ roomStatus: "closed" });
		const closedBody = await closedRes.json();

		expect(closedRes.status).toBe(404);
		expect(messagesInserted).toHaveLength(0);

		const missingRes = await postMessage({ roomStatus: "missing" });
		const missingBody = await missingRes.json();

		expect(missingRes.status).toBe(404);
		expect(missingBody).toEqual(closedBody);
		expect(messagesInserted).toHaveLength(0);
	});

	it("fails closed on an active-room lookup error without exposing the database error or identifier", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const res = await postMessage({
			roomError: { code: "XX000", message: "connection reset" },
		});

		expect(res.status).toBe(500);
		expect(messagesInserted).toHaveLength(0);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[direct-chats] active room lookup failed");
		expect(consoleErrorSpy.mock.calls.flat()).not.toContain("connection reset");
		expect(consoleErrorSpy.mock.calls.flat()).not.toContain("room-1");
		consoleErrorSpy.mockRestore();
	});

	it("does not read or write messages when the counterpart is unverified", async () => {
		const res = await postMessage({ profileRows: [
			{ id: "user-me", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
			{ id: "user-partner", age_verified_at: null, gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
		] });

		expect(res.status).toBe(403);
		expect(messagesInserted).toHaveLength(0);
	});
});
