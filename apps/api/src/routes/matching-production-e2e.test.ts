import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";

const OWNER_ID = "11111111-1111-4111-8111-111111111111";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", OWNER_ID);
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

type OwnerResult = { data: unknown; error: unknown };

function makeSupabase(ownerResult: OwnerResult) {
	const reads: string[] = [];
	return {
		reads,
		from(table: string) {
			reads.push(table);
			if (table !== "user_profiles") throw new Error(`unexpected table: ${table}`);
			const query: Record<string, unknown> = {};
			query.select = () => query;
			query.eq = () => query;
			query.maybeSingle = async () => ownerResult;
			return query;
		},
	};
}

function buildApp() {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		c.set("production_e2e_active", true);
		await next();
	});
	app.route("/api/matching", matching);
	return app;
}

beforeEach(() => vi.clearAllMocks());

describe("GET /api/matching/daily-results in trusted production E2E mode", () => {
	it("returns the existing empty envelope for a strict no-answer owner before global reads", async () => {
		const supabase = makeSupabase({ data: { preference_mode: "no_answer" }, error: null });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/matching/daily-results?date=2026-09-22");

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				batch_date: "2026-09-22",
				batch_status: "completed",
				matches: [],
				is_new: false,
				conversations_completed: 0,
				conversations_failed: 0,
				total_matches: 0,
			},
		});
		expect(supabase.reads).toEqual(["user_profiles"]);
	});

	it.each([
		["selected", { data: { preference_mode: "selected" }, error: null }],
		["missing", { data: null, error: null }],
		["lookup error", { data: null, error: { message: "provider unavailable" } }],
	] as const)("fails closed for a %s owner state", async (_name, ownerResult) => {
		const supabase = makeSupabase(ownerResult);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/matching/daily-results?date=2026-09-22");

		expect(response.status).toBe(403);
		expect(await response.json()).toEqual({ error: { code: "FORBIDDEN", message: "Forbidden" } });
		expect(supabase.reads).toEqual(["user_profiles"]);
	});
});
