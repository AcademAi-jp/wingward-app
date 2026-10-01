import { Hono } from "hono";
import type { Env } from "../env";
import { beforeEach, describe, expect, it, vi } from "vitest";

const OWNER_ID = vi.hoisted(() => "11111111-1111-4111-8111-111111111111");

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", OWNER_ID);
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import profiles from "./profiles";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

function makeMissingProfileSupabase() {
	const inserts: unknown[] = [];
	return {
		inserts,
		from(table: string) {
			if (table !== "profiles") throw new Error(`unexpected table ${table}`);
			const query: Record<string, unknown> = {};
			query.select = () => query;
			query.eq = () => query;
			query.maybeSingle = () => query;
			query.insert = (payload: unknown) => {
				inserts.push(payload);
				return query;
			};
			query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) =>
				Promise.resolve({ data: null, error: null }).then(resolve, reject);
			return query;
		},
	};
}

function buildApp() {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		c.set("production_e2e_active", true);
		c.set("production_e2e_read_only", true);
		await next();
	});
	app.route("/api/profiles", profiles);
	return app;
}

beforeEach(() => vi.restoreAllMocks());

describe("GET /api/profiles/me in trusted read-only E2E mode", () => {
	it("returns a generic 404 for a missing profile without inserting a placeholder", async () => {
		const supabase = makeMissingProfileSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/profiles/me");
		const body = await response.text();

		expect(response.status).toBe(404);
		expect(body).toBe(JSON.stringify({ error: { code: "NOT_FOUND", message: "Profile not found" } }));
		expect(supabase.inserts).toHaveLength(0);
	});
});
