import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "user-a");
		await next();
	},
	requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => {
		await next();
	},
}));

vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import matching from "./matching";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

type QueryResult = { data: unknown; error: unknown };

/** Small thenable query double for the three matching read endpoints. */
function query(result: QueryResult, singleResult?: QueryResult) {
	const q: Record<string, unknown> = {};
	for (const method of ["select", "eq", "or", "in", "order", "limit", "lt"]) {
		q[method] = () => q;
	}
	q.single = async () => singleResult ?? result;
	q.maybeSingle = async () => singleResult ?? result;
	q.then = (resolve: (value: QueryResult) => unknown, reject?: (reason: unknown) => unknown) =>
		Promise.resolve(result).then(resolve, reject);
	return q;
}

function makeUnverifiedSupabase() {
	const match = {
		id: "match-ab",
		user_a_id: "user-a",
		user_b_id: "user-b",
		final_score: 0.9,
		profile_score: 0.9,
		conversation_score: null,
		status: "pending",
		score_details: {},
		created_at: "2026-08-24T00:00:00Z",
	};
	const profiles = [
		{ id: "user-a", age_verified_at: "2026-08-24T00:00:00Z" },
		{ id: "user-b", age_verified_at: null },
	];
	return {
		from: (table: string) => {
			if (table === "matches") {
				return {
					select: () => query({ data: [match], error: null }, { data: match, error: null }),
				};
			}
			if (table === "daily_match_pairs") return { select: () => query({ data: [{ match_id: match.id }], error: null }) };
			if (table === "user_profiles") {
				return {
					select: () => {
						const profilesQuery = query({ data: profiles, error: null }, { data: null, error: null });
						profilesQuery.in = (_column: string, values: string[]) => values.length === 0 ? query({ data: [], error: null }) : profilesQuery;
						return profilesQuery;
					},
				};
			}
			if (table === "blocks") return { select: () => query({ data: [], error: null }) };
		if (table === "personas" || table === "fox_conversations") return { select: () => query({ data: [], error: null }) };
			throw new Error(`unexpected table: ${table}`);
		},
	};
}

function app() {
	const app = new Hono();
	app.route("/api/matching", matching);
	return app;
}

beforeEach(() => {
	mockedGetSupabaseClient.mockReturnValue(makeUnverifiedSupabase() as never);
});

describe("matching endpoints hide an existing match with an unverified counterpart", () => {
	it("matching list omits the unverified counterpart", async () => {
		const response = await app().request("/api/matching/results");
		expect(response.status).toBe(200);
		const body = (await response.json()) as { data: unknown[]; has_more: boolean };
		expect(body.data).toEqual([]);
		expect(body.has_more).toBe(false);
	});

	it("matching detail returns a stable not-found response", async () => {
		const response = await app().request("/api/matching/results/match-ab");
		expect(response.status).toBe(404);
		expect((await response.json()) as unknown).toMatchObject({ error: { message: "Match not found" } });
	});

	it("daily matching list omits the unverified counterpart", async () => {
		const response = await app().request("/api/matching/daily-results?date=2026-08-24");
		expect(response.status).toBe(200);
		const body = (await response.json()) as { data: { matches: unknown[]; total_matches: number } };
		expect(body.data.matches).toEqual([]);
		expect(body.data.total_matches).toBe(0);
	});
});
