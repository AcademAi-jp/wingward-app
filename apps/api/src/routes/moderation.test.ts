import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

const BLOCKER_ID = "11111111-1111-4111-8111-111111111111";
const BLOCKED_ID = "22222222-2222-4222-8222-222222222222";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", BLOCKER_ID);
		await next();
	},
}));

vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import { errorHandler } from "../middleware/error";
import moderation from "./moderation";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const matchFilters: string[] = [];
const roomUpdates: Array<{ values: Record<string, unknown>; filters: Array<[string, unknown]> }> = [];

interface FakeError {
	message: string;
	code?: string;
}

interface FakeOpts {
	blockError?: FakeError | null;
	matchError?: FakeError | null;
	matchId?: string | null;
	roomError?: FakeError | null;
	unblockError?: FakeError | null;
	// Kept as aliases for the main-side persistence negative controls. The
	// merged implementation performs one pair-scoped match lookup instead of
	// enumerating every active room and match.
	roomsError?: FakeError | null;
	matchesError?: FakeError | null;
}

function makeFakeSupabase(opts: FakeOpts = {}) {
	const matchId = opts.matchId === undefined ? "pair-match" : opts.matchId;
	const pairLookupError = opts.matchError ?? opts.matchesError ?? opts.roomsError ?? null;
	return {
		from: (table: string) => {
			if (table === "blocks") {
				return {
					upsert: async () => ({ error: opts.blockError ?? null }),
					delete: () => ({
						eq: () => ({
							eq: async () => ({ error: opts.unblockError ?? null }),
						}),
					}),
				};
			}
			if (table === "matches") {
				return {
					select: () => ({
						or: (filter: string) => {
							matchFilters.push(filter);
							return {
								limit: () => ({
									maybeSingle: async () => ({
										data: matchId ? { id: matchId } : null,
										error: pairLookupError,
									}),
								}),
							};
						},
					}),
				};
			}
			if (table === "direct_chat_rooms") {
				return {
					update: (values: Record<string, unknown>) => {
						const update = { values, filters: [] as Array<[string, unknown]> };
						roomUpdates.push(update);
						const query = {
							error: opts.roomError ?? null,
							eq: (column: string, value: unknown) => {
								update.filters.push([column, value]);
								return query;
							},
						};
						return query;
					},
				};
			}
			throw new Error(`unexpected table in test fake: ${table}`);
		},
	};
}

function buildApp() {
	const app = new Hono();
	app.onError(errorHandler);
	app.route("/api/moderation", moderation);
	return app;
}

async function block(opts: FakeOpts = {}) {
	mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase(opts) as never);
	return buildApp().request("/api/moderation/blocks", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ user_id: BLOCKED_ID }),
	});
}

async function unblock(opts: FakeOpts = {}) {
	mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase(opts) as never);
	return buildApp().request(`/api/moderation/blocks/${BLOCKED_ID}`, { method: "DELETE" });
}

beforeEach(() => {
	vi.restoreAllMocks();
	matchFilters.length = 0;
	roomUpdates.length = 0;
});

describe("POST /api/moderation/blocks closes only the blocker's room with the blocked user", () => {
	it("resolves a match from both participants before closing its active room", async () => {
		const res = await block();

		expect(res.status).toBe(200);
		expect(matchFilters).toEqual([
			`and(user_a_id.eq.${BLOCKER_ID},user_b_id.eq.${BLOCKED_ID}),and(user_a_id.eq.${BLOCKED_ID},user_b_id.eq.${BLOCKER_ID})`,
		]);
		expect(roomUpdates).toEqual([
			{
				values: { status: "closed" },
				filters: [
					["match_id", "pair-match"],
					["status", "active"],
				],
			},
		]);
	});

	it("closes no room when the blocker and blocked user have no match", async () => {
		const res = await block({ matchId: null });

		expect(res.status).toBe(200);
		expect(matchFilters).toHaveLength(1);
		expect(roomUpdates).toHaveLength(0);
	});

	it("returns an error instead of claiming success when the block write fails", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const res = await block({ blockError: { message: "private database detail" } });

		expect(res.status).toBe(500);
		expect(matchFilters).toHaveLength(0);
		expect(roomUpdates).toHaveLength(0);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[moderation] block upsert failed");
		expect(consoleErrorSpy.mock.calls.flat()).not.toContain("private database detail");
		consoleErrorSpy.mockRestore();
	});

	it("returns an error instead of claiming success when the pair lookup fails", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const res = await block({ matchError: { message: "private database detail" } });

		expect(res.status).toBe(500);
		expect(matchFilters).toHaveLength(1);
		expect(roomUpdates).toHaveLength(0);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[moderation] block match lookup failed");
		expect(consoleErrorSpy.mock.calls.flat()).not.toContain("private database detail");
		consoleErrorSpy.mockRestore();
	});

	it("returns an error instead of claiming success when room closure fails", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const res = await block({ roomError: { message: "private database detail" } });

		expect(res.status).toBe(500);
		expect(roomUpdates).toHaveLength(1);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[moderation] direct chat room close failed");
		expect(consoleErrorSpy.mock.calls.flat()).not.toContain("private database detail");
		consoleErrorSpy.mockRestore();
	});
});

describe("moderation block persistence failures", () => {
	it("does not report success when the block upsert fails", async () => {
		const response = await block({ blockError: { message: "PWNED-CANARY-BLOCK" } });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-BLOCK");
		expect(JSON.parse(body)).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to block user" },
		});
	});

	it("does not report success when the active-room lookup fails", async () => {
		const response = await block({ roomsError: { message: "active rooms unavailable" } });

		expect(response.status).toBe(500);
		const body = (await response.json()) as { error: { code: string } };
		expect(body.error.code).toBe("INTERNAL_ERROR");
	});

	it("does not report success when the match lookup fails", async () => {
		const response = await block({ matchesError: { message: "matches unavailable" } });

		expect(response.status).toBe(500);
		const body = (await response.json()) as { error: { code: string } };
		expect(body.error.code).toBe("INTERNAL_ERROR");
	});

	it("does not report success when closing an active room fails", async () => {
		const response = await block({ roomError: { message: "PWNED-CANARY-ROOM" } });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-ROOM");
	});
});

describe("moderation unblock persistence failures", () => {
	it("does not report success when the unblock delete fails", async () => {
		const response = await unblock({ unblockError: { message: "PWNED-CANARY-UNBLOCK" } });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-UNBLOCK");
		expect(JSON.parse(body)).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to unblock user" },
		});
	});
});
