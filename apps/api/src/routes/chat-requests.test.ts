import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * Route-level coverage for POST /api/chat-requests, focused on the block
 * check added in review round 2 of PR #31 (Codex P0).
 *
 * The route never consulted `blocks`. A match row and a `partner_fox_chats`
 * row both survive a block, so a blocked requester could still create a chat
 * request against the person who blocked them — and once N-03 was wired, also
 * reach them with a push. That turns the block route's closing of direct-chat
 * rooms into decoration.
 *
 * Tested at the route rather than under it, because the check has to run
 * before the INSERT and before the notification dispatch, and only the handler
 * knows that ordering.
 */

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", testAuthUser.id);
		await next();
	},
	requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => {
		await next();
	},
}));

const testAuthUser = vi.hoisted(() => ({ id: "user-requester" }));

vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

const notifyChatRequestCreated = vi.fn();
vi.mock("../services/notification-triggers", () => ({
	notifyChatRequestCreated: (...args: unknown[]) => notifyChatRequestCreated(...args),
}));

import { getSupabaseClient } from "../db/client";
import { errorHandler } from "../middleware/error";
import chatRequests from "./chat-requests";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

interface FakeOpts {
  blockRow?: { id: string } | null;
  blockRows?: Array<{ id: string; blocker_id: string; blocked_id: string }>;
	blockError?: { message: string } | null;
	profileRows?: Array<Record<string, unknown>>;
	profileError?: { message: string } | null;
	match?: { id?: string; user_a_id: string; user_b_id: string } | null;
	matchError?: { code?: string; message: string } | null;
	pfc?: { id: string } | null;
	pfcError?: { code?: string; message: string } | null;
  existingRequest?: { id: string } | null;
  existingRequestError?: { code?: string; message: string } | null;
  matchRequest?: Record<string, unknown> | null;
  matchRequestError?: { code?: string; message: string } | null;
	matchUpdateError?: { message: string } | null;
	requestDeleteError?: { message: string } | null;
}

const inserted: Record<string, unknown>[] = [];
const requestDeletes: unknown[] = [];

function makeFakeSupabase(opts: FakeOpts) {
	return {
		from: (table: string) => {
			if (table === "matches") {
				const match = opts.match === undefined
					? { id: "match-1", user_a_id: "user-requester", user_b_id: "user-partner" }
					: opts.match;
				const matchResult = async () => ({ data: match, error: opts.matchError ?? null });
				return {
					select: () => ({ eq: () => ({ single: matchResult }) }),
					update: () => ({ eq: async () => ({ error: opts.matchUpdateError ?? null }) }),
				};
			}
			if (table === "user_profiles") {
				return { select: () => ({ in: async () => ({ data: opts.profileRows ?? [
					{ id: "user-requester", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
					{ id: "user-partner", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
				], error: opts.profileError ?? null }) }) };
			}
            if (table === "blocks") {
              return {
                select: () => ({
                  or: (filter: string) => ({
                    limit: () => ({
                      maybeSingle: async () => {
                        const matchedBlock = opts.blockRows?.find((row) =>
                          filter.includes(`and(blocker_id.eq.${row.blocker_id},blocked_id.eq.${row.blocked_id})`),
                        );
                        return {
                          data: matchedBlock ?? opts.blockRow ?? null,
                          error: opts.blockError ?? null,
                        };
                      },
                    }),
                  }),
                }),
				};
			}
			if (table === "partner_fox_chats") {
				const maybeSingleError = opts.pfcError?.code === "PGRST116" ? null : opts.pfcError ?? null;
				return {
					select: () => ({
						eq: () => ({
							eq: () => ({
								single: async () => ({ data: opts.pfc === undefined ? { id: "pfc-1" } : opts.pfc, error: opts.pfcError ?? null }),
								maybeSingle: async () => ({ data: opts.pfc === undefined ? { id: "pfc-1" } : opts.pfc, error: maybeSingleError }),
							}),
						}),
					}),
				};
			}
            if (table === "chat_requests") {
              const maybeSingleError = opts.existingRequestError?.code === "PGRST116" ? null : opts.existingRequestError ?? null;
              return {
                select: (columns: string) => {
                  const isMatchStateQuery = columns.includes("responder_id");
                  const row = isMatchStateQuery ? opts.matchRequest ?? null : opts.existingRequest ?? null;
                  const queryError = isMatchStateQuery ? opts.matchRequestError ?? null : maybeSingleError;
                  return {
                    eq: () => ({
                      eq: () => ({
                        single: async () => ({ data: row, error: opts.existingRequestError ?? null }),
                        maybeSingle: async () => ({ data: row, error: queryError }),
                      }),
                      single: async () => ({ data: row, error: opts.existingRequestError ?? null }),
                      maybeSingle: async () => ({ data: row, error: queryError }),
                    }),
                  };
                },
					insert: (row: Record<string, unknown>) => {
						inserted.push(row);
						return { select: () => ({ single: async () => ({ data: { id: "req-1", match_id: row.match_id, status: "pending", expires_at: row.expires_at }, error: null }) }) };
					},
					delete: () => ({
						eq: async (_column: string, value: unknown) => {
							requestDeletes.push(value);
							return { error: opts.requestDeleteError ?? null };
						},
					}),
				};
			}
			throw new Error(`unexpected table in test fake: ${table}`);
		},
	};
}

function makeApp() {
	const app = new Hono();
	app.onError(errorHandler);
	app.route("/api/chat-requests", chatRequests);
	return app;
}

async function post() {
	return makeApp().request("/api/chat-requests", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ match_id: "11111111-1111-4111-8111-111111111111" }),
	});
}

async function getMatchRequestState(matchID = "11111111-1111-4111-8111-111111111111") {
	return makeApp().request(`/api/chat-requests/by-match/${matchID}`, { method: "GET" });
}

beforeEach(() => {
	testAuthUser.id = "user-requester";
	mockedGetSupabaseClient.mockReset();
	inserted.length = 0;
	requestDeletes.length = 0;
	notifyChatRequestCreated.mockReset().mockResolvedValue(undefined);
});

describe("POST /api/chat-requests refuses blocked pairs (Codex P0, PR #31)", () => {
	it("creates the request and dispatches N-03 when there is no block", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ blockRow: null }) as never);

		const res = await post();

		expect(res.status).toBe(200);
		expect(inserted).toHaveLength(1);
		expect(notifyChatRequestCreated).toHaveBeenCalledTimes(1);
		expect(notifyChatRequestCreated.mock.calls[0][1]).toMatchObject({ responderId: "user-partner" });
	});

	it("refuses when a block exists in either direction — no row created and no push dispatched", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ blockRow: { id: "block-1" } }) as never);

		const res = await post();

		expect(res.status).toBe(404);
		// Both halves matter: a row that is never created cannot be pushed
		// about, and a push that is never dispatched cannot reach the blocker.
		expect(inserted).toHaveLength(0);
		expect(notifyChatRequestCreated).not.toHaveBeenCalled();
	});

	it("returns the same NOT_FOUND body as a non-participant would get, so it cannot be used to probe for a block", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ blockRow: { id: "block-1" } }) as never);

		const blocked = await post();
		const body = (await blocked.json()) as { error?: { message?: string } };

		expect(blocked.status).toBe(404);
		expect(body.error?.message).toBe("Match not found");
	});

	it("fails closed when the blocks lookup itself errors — an unreadable block list is not 'not blocked'", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ blockError: { message: "connection reset" } }) as never);

		const res = await post();

		expect(res.status).toBe(500);
		expect(inserted).toHaveLength(0);
		expect(notifyChatRequestCreated).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("does not create a request or dispatch N-03 when the counterpart is unverified", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ profileRows: [
				{ id: "user-requester", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
				{ id: "user-partner", age_verified_at: null, gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
			] }) as never,
		);

		const res = await post();

		expect(res.status).toBe(404);
		expect(inserted).toHaveLength(0);
		expect(notifyChatRequestCreated).not.toHaveBeenCalled();
	});

	it("fails closed when the pair age lookup errors", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ profileError: { message: "connection reset" } }) as never);

		const res = await post();

		expect(res.status).toBe(500);
		expect(inserted).toHaveLength(0);
		expect(notifyChatRequestCreated).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("returns NOT_FOUND for a missing match instead of treating PGRST116 as a server error", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ match: null, matchError: { code: "PGRST116", message: "0 rows" } }) as never,
		);

		const res = await post();

		expect(res.status).toBe(404);
		expect(inserted).toHaveLength(0);
	});

	it("keeps normal conflict responses for missing or existing chat-request prerequisites", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ pfc: null, pfcError: { code: "PGRST116", message: "0 rows" } }) as never,
		);
		expect((await post()).status).toBe(409);

		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({
				existingRequest: { id: "req-existing" },
			}) as never,
		);
		expect((await post()).status).toBe(409);
		expect(inserted).toHaveLength(0);
	});

	it("treats PGRST116 from a maybeSingle existing-request lookup as absence", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ existingRequest: null, existingRequestError: { code: "PGRST116", message: "0 rows" } }) as never,
		);

		const res = await post();

		expect(res.status).toBe(200);
		expect(inserted).toHaveLength(1);
	});

	it("rolls back the created request when the match status update fails", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ matchUpdateError: { message: "match update unavailable" } }) as never,
		);

		const res = await post();

		expect(res.status).toBe(500);
		expect(requestDeletes).toEqual(["req-1"]);
		expect(notifyChatRequestCreated).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("keeps the primary failure when request rollback also fails and logs only a generic message", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({
				matchUpdateError: { message: "match update unavailable" },
				requestDeleteError: { message: "delete unavailable" },
			}) as never,
		);

		const res = await post();

		expect(res.status).toBe(500);
		expect(requestDeletes).toHaveLength(1);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[chat-requests] failed to roll back request creation");
		consoleErrorSpy.mockRestore();
	});
});

describe("GET /api/chat-requests/by-match/:matchId", () => {
	const requestRow = (overrides: Record<string, unknown> = {}) => ({
		id: "req-1",
		match_id: "11111111-1111-4111-8111-111111111111",
		requester_id: "user-requester",
		responder_id: "user-partner",
		status: "pending",
		expires_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
		...overrides,
	});

	it("returns a requester's outgoing status to a verified match participant", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ matchRequest: requestRow() }) as never,
		);

		const res = await getMatchRequestState();
		const body = (await res.json()) as { data?: { request?: Record<string, unknown> } };

		expect(res.status).toBe(200);
		expect(body.data?.request).toMatchObject({
			match_id: "11111111-1111-4111-8111-111111111111",
			requester_id: "user-requester",
			responder_id: "user-partner",
			status: "pending",
		});
	});

	it("returns the same match-scoped state for the verified incoming participant", async () => {
		testAuthUser.id = "user-partner";
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ matchRequest: requestRow() }) as never,
		);

		const res = await getMatchRequestState();
		const body = (await res.json()) as { data?: { request?: Record<string, unknown> } };

		expect(res.status).toBe(200);
		expect(body.data?.request).toMatchObject({ requester_id: "user-requester", responder_id: "user-partner" });
	});

	it("returns an explicit empty state when no request exists", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ matchRequest: null }) as never);

		const res = await getMatchRequestState();
		const body = (await res.json()) as { data?: { request?: unknown } };

		expect(res.status).toBe(200);
		expect(body.data?.request).toBeNull();
	});

	it("rejects malformed match IDs before querying storage", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({}) as never);

		const res = await getMatchRequestState("not-a-uuid");

		expect(res.status).toBe(400);
		expect(mockedGetSupabaseClient).not.toHaveBeenCalled();
	});

	it("uses the non-disclosing not-found response for a peer outside the match", async () => {
		testAuthUser.id = "user-outsider";
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ matchRequest: requestRow() }) as never,
		);

		const res = await getMatchRequestState();
		const body = (await res.json()) as { error?: { message?: string } };

		expect(res.status).toBe(404);
		expect(body.error?.message).toBe("Match not found");
	});

	it.each([
		{ blocker: "user-requester", blocked: "user-partner" },
		{ blocker: "user-partner", blocked: "user-requester" },
	])("hides request state when either participant blocked the other", async ({ blocker, blocked }) => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({
				blockRows: [{ id: "block-1", blocker_id: blocker, blocked_id: blocked }],
				matchRequest: requestRow(),
			}) as never,
		);

		const res = await getMatchRequestState();
		const body = (await res.json()) as { error?: { message?: string } };

		expect(res.status).toBe(404);
		expect(body.error?.message).toBe("Match not found");
	});

	it("fails closed when the match-scoped request lookup fails", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ matchRequestError: { message: "connection reset" } }) as never,
		);

		const res = await getMatchRequestState();

		expect(res.status).toBe(500);
		consoleErrorSpy.mockRestore();
	});

	it("fails closed when the blocks lookup fails", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ blockError: { message: "connection reset" } }) as never,
		);

		const res = await getMatchRequestState();

		expect(res.status).toBe(500);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[chat-requests] blocks lookup failed");
		consoleErrorSpy.mockRestore();
	});

	it.each([
		["requester is outside the match", { requester_id: "user-outsider" }],
		["responder is outside the match", { responder_id: "user-outsider" }],
		["both participants are the same user", { responder_id: "user-requester" }],
		["request belongs to another match", { match_id: "22222222-2222-4222-8222-222222222222" }],
	])("rejects a corrupted request row when %s", async (_description, overrides) => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ matchRequest: requestRow(overrides) }) as never,
		);

		const res = await getMatchRequestState();

		expect(res.status).toBe(500);
		consoleErrorSpy.mockRestore();
	});

	it("fails closed when the stored request status is invalid", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ matchRequest: requestRow({ status: "unknown" }) }) as never,
		);

		const res = await getMatchRequestState();

		expect(res.status).toBe(500);
		consoleErrorSpy.mockRestore();
	});

	it.each(["not-a-timestamp", "", "   ", null, 123])("fails closed when the stored expiry is invalid: %s", async (expiresAt) => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ matchRequest: requestRow({ expires_at: expiresAt }) }) as never,
		);

		const res = await getMatchRequestState();

		expect(res.status).toBe(500);
		consoleErrorSpy.mockRestore();
	});

	it("reports a stored pending request as expired after its deadline", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({
				matchRequest: requestRow({ expires_at: "2000-01-01T00:00:00.000Z" }),
			}) as never,
		);

		const res = await getMatchRequestState();
		const body = (await res.json()) as { data?: { request?: Record<string, unknown> } };

		expect(res.status).toBe(200);
		expect(body.data?.request?.status).toBe("expired");
	});
});

/**
 * PUT /api/chat-requests/:id with action "accept" — HOLE 2 of the round-2
 * Codex review on PR #32: the room INSERT had no block check of its own, so
 * accepting could open a direct_chat_rooms row for a pair that blocked each
 * other after the request was created. reject_blocked_pair_by_match
 * (20260821100000_blocked_pair_invariant.sql) is the database backstop; this
 * covers the application-level check that returns a clean error and stops
 * before the INSERT.
 */
interface FakePutOpts {
	blockRow?: { id: string } | null;
	blockError?: { message: string } | null;
	request?: Record<string, unknown> | null;
	requestError?: { code?: string; message: string } | null;
	chatRequestUpdateError?: { message: string } | null;
	matchUpdateError?: { message: string } | null;
	roomDeleteError?: { message: string } | null;
}

const roomsInserted: Record<string, unknown>[] = [];
const roomsDeleted: unknown[] = [];
const requestUpdates: Record<string, unknown>[] = [];

function makeFakePutSupabase(opts: FakePutOpts) {
	return {
		from: (table: string) => {
			if (table === "chat_requests") {
				const request = opts.request === undefined
					? {
							id: "req-1",
							match_id: "match-1",
							requester_id: "user-requester",
							responder_id: "user-responder",
							status: "pending",
							expires_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
						}
					: opts.request;
				const maybeSingleError = opts.requestError?.code === "PGRST116" ? null : opts.requestError ?? null;
				return {
					select: () => ({
						eq: () => ({
							eq: () => ({
								eq: () => ({
									single: async () => ({
										data: request,
										error: opts.requestError ?? null,
									}),
									maybeSingle: async () => ({ data: request, error: maybeSingleError }),
								}),
							}),
						}),
					}),
					update: (row: Record<string, unknown>) => ({
						eq: async () => {
							requestUpdates.push(row);
							return { error: opts.chatRequestUpdateError ?? null };
						},
					}),
				};
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
			if (table === "direct_chat_rooms") {
				return {
					insert: (row: Record<string, unknown>) => {
						roomsInserted.push(row);
						return { select: () => ({ single: async () => ({ data: { id: "room-1" }, error: null }) }) };
					},
					delete: () => ({
						eq: async (_column: string, value: unknown) => {
							roomsDeleted.push(value);
							return { error: opts.roomDeleteError ?? null };
						},
					}),
				};
			}
			if (table === "matches") {
				return {
					select: () => ({ eq: () => ({ single: async () => ({ data: { user_a_id: "user-requester", user_b_id: "user-responder" }, error: null }) }) }),
					update: () => ({ eq: async () => ({ error: opts.matchUpdateError ?? null }) }),
				};
			}
			if (table === "user_profiles") {
				return { select: () => ({ in: async () => ({ data: [
					{ id: "user-requester", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
					{ id: "user-responder", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
				], error: null }) }) };
			}
			throw new Error(`unexpected table in test fake: ${table}`);
		},
	};
}

async function put(id: string, action: "accept" | "decline") {
	return makeApp().request(`/api/chat-requests/${id}`, {
		method: "PUT",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ action }),
	});
}

describe("PUT /api/chat-requests/:id accept refuses blocked pairs (Codex round-2, PR #32)", () => {
	beforeEach(() => {
		roomsInserted.length = 0;
		roomsDeleted.length = 0;
		requestUpdates.length = 0;
	});

	it("accepts and creates a room when there is no block", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakePutSupabase({ blockRow: null }) as never);

		const res = await put("req-1", "accept");
		const body = (await res.json()) as { data?: { status?: string; direct_chat_room_id?: string } };

		expect(res.status).toBe(200);
		expect(body.data?.status).toBe("accepted");
		expect(body.data?.direct_chat_room_id).toBe("room-1");
		expect(roomsInserted).toHaveLength(1);
	});

	it("refuses with the same NOT_FOUND text as a missing request, and never inserts a room, when a block exists", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakePutSupabase({ blockRow: { id: "block-1" } }) as never);

		const res = await put("req-1", "accept");
		const body = (await res.json()) as { error?: { message?: string } };

		expect(res.status).toBe(404);
		expect(body.error?.message).toBe("Request not found");
		expect(roomsInserted).toHaveLength(0);
	});

	it("fails closed when the blocks lookup itself errors, and never inserts a room", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(makeFakePutSupabase({ blockError: { message: "connection reset" } }) as never);

		const res = await put("req-1", "accept");

		expect(res.status).toBe(500);
		expect(roomsInserted).toHaveLength(0);
		consoleErrorSpy.mockRestore();
	});

	it("returns NOT_FOUND for a missing request instead of treating PGRST116 as a server error", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakePutSupabase({ request: null, requestError: { code: "PGRST116", message: "0 rows" } }) as never,
		);

		const res = await put("missing-request", "accept");

		expect(res.status).toBe(404);
		expect(roomsInserted).toHaveLength(0);
	});

	it("deletes the room when accepting cannot update the request", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakePutSupabase({ chatRequestUpdateError: { message: "request update unavailable" } }) as never,
		);

		const res = await put("req-1", "accept");

		expect(res.status).toBe(500);
		expect(roomsInserted).toHaveLength(1);
		expect(roomsDeleted).toEqual(["room-1"]);
	});

	it("rolls back both request and room when accepting cannot update the match", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakePutSupabase({ matchUpdateError: { message: "match update unavailable" } }) as never,
		);

		const res = await put("req-1", "accept");

		expect(res.status).toBe(500);
		expect(requestUpdates).toEqual([
			{ status: "accepted", responded_at: expect.any(String) },
			{ status: "pending", responded_at: null },
		]);
		expect(roomsDeleted).toEqual(["room-1"]);
	});

	it("rolls the request back when declining cannot update the match", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakePutSupabase({ matchUpdateError: { message: "match update unavailable" } }) as never,
		);

		const res = await put("req-1", "decline");

		expect(res.status).toBe(500);
		expect(requestUpdates).toEqual([
			{ status: "declined", responded_at: expect.any(String) },
			{ status: "pending", responded_at: null },
		]);
	});

	it("attempts room cleanup even when that cleanup reports an error", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakePutSupabase({
				chatRequestUpdateError: { message: "request update unavailable" },
				roomDeleteError: { message: "delete unavailable" },
			}) as never,
		);

		const res = await put("req-1", "accept");

		expect(res.status).toBe(500);
		expect(roomsDeleted).toEqual(["room-1"]);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[chat-requests] failed to roll back direct chat room");
		consoleErrorSpy.mockRestore();
	});
});

describe("judge chat request metadata", () => {
  function judgeApp(counterpart = "user-partner") {
    const app = new Hono<import("../env").Env>();
    app.use("*", async (c, next) => { c.set("judge_access", { actorId: testAuthUser.id, counterpartId: counterpart, accountKind: "judge", expiresAtMs: Date.parse("2026-10-13T19:00:00Z") }); await next(); });
    app.route("/api/chat-requests", chatRequests);
    return app;
  }
  it("marks only an exactpair new request", async () => {
    mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({}) as never);
    const r = await judgeApp().request("/api/chat-requests", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ match_id: "11111111-1111-4111-8111-111111111111" }) });
    expect(r.status).toBe(200);
    expect(await r.json()).toMatchObject({ data: { simulated_counterpart: true } });
  });
  it("rejects another counterpart before creating or notifying a request", async () => {
    mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({}) as never);
    const r = await judgeApp("other-peer").request("/api/chat-requests", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ match_id: "11111111-1111-4111-8111-111111111111" }) });
    expect(r.status).toBe(404); expect(inserted).toEqual([]); expect(notifyChatRequestCreated).not.toHaveBeenCalled();
  });
  it("marks pending request row for safe reopen acceptance recovery", async () => {
    mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ matchRequest: { id: "req-1", match_id: "11111111-1111-4111-8111-111111111111", requester_id: "user-requester", responder_id: "user-partner", status: "pending", expires_at: new Date(Date.now()+60_000).toISOString() } }) as never);
    const r = await judgeApp().request("/api/chat-requests/by-match/11111111-1111-4111-8111-111111111111");
    expect(r.status).toBe(200); expect(await r.json()).toMatchObject({ data: { request: { id: "req-1", status: "pending", simulated_counterpart: true } } });
  });
  it("marks exactpair request-state recovery with the bound match id", async () => {
    mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({}) as never);
    const r = await judgeApp().request("/api/chat-requests/by-match/11111111-1111-4111-8111-111111111111");
    expect(r.status).toBe(200); expect(await r.json()).toEqual({ data: { request: null, simulated_counterpart: true, judge_match_id: "11111111-1111-4111-8111-111111111111" } });
  });
});
