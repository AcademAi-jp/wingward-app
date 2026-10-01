import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

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
vi.mock("../services/match-age-access", () => ({
	checkVerifiedPair: vi.fn(),
	filterVerifiedMatches: vi.fn(),
}));

import { getSupabaseClient } from "../db/client";
import { errorHandler } from "../middleware/error";
import { checkVerifiedPair, filterVerifiedMatches } from "../services/match-age-access";
import directChats from "./direct-chats";
import { getProfilePhotoAdapter } from "../services/onboarding-settings";
vi.mock("../services/onboarding-settings", () => ({ getProfilePhotoAdapter: vi.fn(() => null) }));
const photoSign = vi.fn().mockResolvedValue("https://storage.invalid/fresh");

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const mockedCheckVerifiedPair = vi.mocked(checkVerifiedPair);
const mockedFilterVerifiedMatches = vi.mocked(filterVerifiedMatches);

const match = { id: "match-1", user_a_id: "user-me", user_b_id: "user-partner" };

type FakeError = { message: string; code?: string };

interface FakeOpts {
	profileError?: FakeError | null;
	matchesError?: FakeError | null;
	roomsError?: FakeError | null;
	partnersError?: FakeError | null;
	lastMessageError?: FakeError | null;
	unreadError?: FakeError | null;
	afterSeenError?: FakeError | null;
	roomError?: FakeError | null;
	roomStatus?: "active" | "closed";
	matchError?: FakeError | null;
	blockRow?: { id: string } | null;
	blockRows?: Array<{ blocker_id: string; blocked_id: string }>;
	blockError?: FakeError | null;
	messagesError?: FakeError | null;
	targetError?: FakeError | null;
	readUpdateError?: FakeError | null;
}

let readUpdateCalls = 0;
let messageSelectCalls = 0;

function makeChain(result: unknown) {
	const chain: Record<string, (...args: unknown[]) => unknown> = {};
	for (const method of ["select", "eq", "neq", "gt", "gte", "lt", "lte", "order", "limit", "in", "or"]) {
		chain[method] = () => chain;
	}
	chain.single = () => Promise.resolve(result);
	chain.maybeSingle = () => Promise.resolve(result);
	chain.then = (resolve: unknown, reject?: unknown) => Promise.resolve(result).then(resolve as never, reject as never);
	return chain;
}

function makeCountChain(opts: FakeOpts) {
	let result: { count: number | null; error: FakeError | null } = {
		count: 2,
		error: opts.unreadError ?? null,
	};
	const chain: Record<string, (...args: unknown[]) => unknown> = {};
	for (const method of ["select", "eq", "neq"]) {
		chain[method] = () => chain;
	}
	chain.gt = () => {
		result = { count: 1, error: opts.afterSeenError ?? null };
		return chain;
	};
	chain.then = (resolve: unknown, reject?: unknown) => Promise.resolve(result).then(resolve as never, reject as never);
	return chain;
}

function makeMessageTable(opts: FakeOpts) {
	return {
		select(columns: string, options?: { head?: boolean }) {
			messageSelectCalls += 1;
			if (options?.head) return makeCountChain(opts);
			if (columns === "content, created_at, sender_id") {
				return makeChain({
					data: { content: "hello", created_at: "2026-08-30T00:00:00Z", sender_id: "user-partner" },
					error: opts.lastMessageError ?? null,
				});
			}
			if (columns === "id, created_at") {
				return makeChain({
					data: { id: "message-1", created_at: "2026-08-30T00:00:00Z" },
					error: opts.targetError ?? null,
				});
			}
			return makeChain({
				data: [
					{
						id: "message-1",
						sender_id: "user-partner",
						content: "hello",
						is_read: false,
						created_at: "2026-08-30T00:00:00Z",
					},
				],
				error: opts.messagesError ?? null,
			});
		},
		update: () => {
			readUpdateCalls += 1;
			return makeChain({ count: 1, error: opts.readUpdateError ?? null });
		},
	};
}

function makeFakeSupabase(opts: FakeOpts = {}) {
	return {
		from(table: string) {
			if (table === "user_profiles") {
				return {
					select: () => ({
						eq: () => ({
							single: async () => ({
								data: { notification_seen_at: "2026-08-29T00:00:00Z" },
								error: opts.profileError ?? null,
							}),
						}),
						in: async () => ({
							data: [{ id: "user-partner", nickname: "Partner", avatar_url: null, avatar_storage_path: "profile-photos/user-partner/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png" }],
							error: opts.partnersError ?? null,
						}),
					}),
				};
			}
			if (table === "matches") {
				return {
					select: () => ({
						or: async () => ({ data: [match], error: opts.matchesError ?? null }),
						eq: () => ({
							single: async () => ({ data: match, error: opts.matchError ?? null }),
						}),
					}),
				};
			}
			if (table === "direct_chat_rooms") {
				let activeOnly = false;
				const roomQuery = {
					eq(column: string, value: unknown) {
						if (column === "status" && value === "active") activeOnly = true;
						return roomQuery;
					},
					in: async () => ({ data: [{ id: "room-1", match_id: "match-1" }], error: opts.roomsError ?? null }),
					single: async () => {
						if (opts.roomError) return { data: null, error: opts.roomError };
						if (activeOnly && opts.roomStatus === "closed") {
							return { data: null, error: { message: "No rows", code: "PGRST116" } };
						}
						return { data: { match_id: "match-1" }, error: null };
					},
				};
				return {
					select: () => roomQuery,
				};
			}
			if (table === "blocks") {
				return {
					select: (columns: string) => {
						if (columns === "blocker_id, blocked_id") {
							return {
								or: async () => ({ data: opts.blockRows ?? [], error: opts.blockError ?? null }),
							};
						}
						return {
							or: () => ({
								limit: () => ({
									maybeSingle: async () => ({ data: opts.blockRow ?? null, error: opts.blockError ?? null }),
								}),
							}),
						};
					},
				};
			}
			if (table === "direct_chat_messages") return makeMessageTable(opts);
			throw new Error(`unexpected table ${table}`);
		},
	};
}

function buildApp() {
	const app = new Hono();
	app.onError(errorHandler);
	app.route("/api/direct-chats", directChats);
	return app;
}

beforeEach(() => {
 photoSign.mockClear();
 vi.mocked(getProfilePhotoAdapter).mockReturnValue({ storage: { createOwnerReadUrl: photoSign } } as never);
	readUpdateCalls = 0;
	messageSelectCalls = 0;
	mockedGetSupabaseClient.mockReset();
	mockedCheckVerifiedPair.mockReset().mockResolvedValue({ ok: true });
	mockedFilterVerifiedMatches.mockReset().mockResolvedValue({ ok: true, rows: [match] });
});

describe("GET /api/direct-chats data availability", () => {
	it.each([
		{ name: "notification metadata", options: { profileError: { message: "PWNED-CANARY-PROFILE" } } },
		{ name: "match metadata", options: { matchesError: { message: "PWNED-CANARY-MATCHES" } } },
		{ name: "block state", options: { blockError: { message: "PWNED-CANARY-BLOCKS" } } },
		{ name: "active rooms", options: { roomsError: { message: "PWNED-CANARY-ROOMS" } } },
		{ name: "partner metadata", options: { partnersError: { message: "PWNED-CANARY-PARTNERS" } } },
		{ name: "last message", options: { lastMessageError: { message: "PWNED-CANARY-LAST-MESSAGE" } } },
		{ name: "unread count", options: { unreadError: { message: "PWNED-CANARY-UNREAD" } } },
		{ name: "post-notification unread count", options: { afterSeenError: { message: "PWNED-CANARY-AFTER-SEEN" } } },
	] as const)("fails closed when the $name read fails", async ({ options }) => {
		const supabase = makeFakeSupabase(options);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats");
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toMatch(/PWNED-CANARY/);
		expect(mockedCheckVerifiedPair).not.toHaveBeenCalled();
	});

	it.each([
		{ blocker_id: "user-me", blocked_id: "user-partner" },
		{ blocker_id: "user-partner", blocked_id: "user-me" },
	])("omits active rooms and message previews after either participant blocks the other", async (blockRow) => {
		const supabase = makeFakeSupabase({
			blockRows: [blockRow],
		});
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats");
		const body = await response.text();

		expect(response.status).toBe(200);
		expect(body).toBe('{"data":[]}');
		expect(messageSelectCalls).toBe(0);
	});
});

describe("GET /api/direct-chats/:id/messages data availability", () => {
	it("returns an error instead of an empty transcript when the message read fails", async () => {
		const supabase = makeFakeSupabase({ messagesError: { message: "PWNED-CANARY-TRANSCRIPT" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages");
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-TRANSCRIPT");
	});

	it("hides message history after the room closes", async () => {
		const supabase = makeFakeSupabase({ roomStatus: "closed" });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages");

		expect(response.status).toBe(404);
		expect(messageSelectCalls).toBe(0);
		expect(mockedCheckVerifiedPair).not.toHaveBeenCalled();
	});

	it("hides message history when either participant has blocked the other", async () => {
		const supabase = makeFakeSupabase({ blockRow: { id: "block-1" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages");

		expect(response.status).toBe(403);
		expect(messageSelectCalls).toBe(0);
	});

	it("fails closed without reading messages when the block check fails", async () => {
		const supabase = makeFakeSupabase({ blockError: { message: "PWNED-CANARY-BLOCK" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages");
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-BLOCK");
		expect(messageSelectCalls).toBe(0);
	});
});

describe("POST /api/direct-chats/:id/messages access availability", () => {
	it.each([
		{ name: "room", options: { roomError: { message: "PWNED-CANARY-ROOM-ACCESS" } } },
		{ name: "match", options: { matchError: { message: "PWNED-CANARY-MATCH-ACCESS" } } },
	] as const)("fails closed when the $name access read fails", async ({ options }) => {
		const supabase = makeFakeSupabase(options);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ content: "hello" }),
		});
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toMatch(/PWNED-CANARY/);
		expect(mockedCheckVerifiedPair).not.toHaveBeenCalled();
	});
});

describe("PUT /api/direct-chats/:id/messages/:messageId/read data availability", () => {
	it("does not update read state after the room closes", async () => {
		const supabase = makeFakeSupabase({ roomStatus: "closed" });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages/message-1/read", { method: "PUT" });

		expect(response.status).toBe(404);
		expect(readUpdateCalls).toBe(0);
		expect(mockedCheckVerifiedPair).not.toHaveBeenCalled();
	});

	it("does not update read state when either participant has blocked the other", async () => {
		const supabase = makeFakeSupabase({ blockRow: { id: "block-1" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages/message-1/read", { method: "PUT" });

		expect(response.status).toBe(403);
		expect(readUpdateCalls).toBe(0);
	});

	it("fails closed without updating when the block check fails", async () => {
		const supabase = makeFakeSupabase({ blockError: { message: "PWNED-CANARY-BLOCK" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages/message-1/read", { method: "PUT" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-BLOCK");
		expect(readUpdateCalls).toBe(0);
	});

	it("does not report a successful read-state update when the update fails", async () => {
		const supabase = makeFakeSupabase({ readUpdateError: { message: "PWNED-CANARY-READ-UPDATE" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages/message-1/read", { method: "PUT" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-READ-UPDATE");
	});

	it("does not report success when the target message read fails", async () => {
		const supabase = makeFakeSupabase({ targetError: { message: "PWNED-CANARY-TARGET" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/direct-chats/room-1/messages/message-1/read", { method: "PUT" });
		const body = await response.text();

		expect(response.status).toBe(404);
		expect(body).not.toContain("PWNED-CANARY-TARGET");
	});
});

 it("renews only visible chat partner photos", async () => {
  mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({}) as never);
  const response = await buildApp().request("/api/direct-chats");
  expect(response.status).toBe(200);
  const body = await response.text();
  expect(body).toContain("https://storage.invalid/fresh");
  expect(body).not.toContain("avatar_storage_path");
  expect(photoSign).toHaveBeenCalledWith("user-partner", "profile-photos/user-partner/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png", 300);
 });
 it.each([
  { blocker_id: "user-me", blocked_id: "user-partner" },
  { blocker_id: "user-partner", blocked_id: "user-me" },
 ])("does not sign blocked chat photos", async (block) => {
  mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ blockRows: [block] }) as never);
  const response = await buildApp().request("/api/direct-chats");
  expect(response.status).toBe(200);
  expect(photoSign).not.toHaveBeenCalled();
 });
