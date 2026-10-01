import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

const PROFILE_ID = "11111111-1111-4111-8111-111111111111";
const AUTH_USER_ID = "33333333-3333-4333-8333-333333333333";
const OTHER_PROFILE_ID = "22222222-2222-4222-8222-222222222222";
const OTHER_AUTH_USER_ID = "44444444-4444-4444-8444-444444444444";

let authEnabled = true;
let ageVerified = true;
let identityResult: { data: unknown; error: unknown } = {
	data: { id: PROFILE_ID, auth_user_id: AUTH_USER_ID },
	error: null,
};
let entitlementResult: { data: unknown; error: unknown } = { data: null, error: null };
let creditResult: { data: unknown; error: unknown } = { data: null, error: null };
let calls: Array<{ method: string; args: unknown[] }> = [];

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		if (!authEnabled) return c.json({ error: { code: "UNAUTHORIZED", message: "unauthorized" } }, 401);
		c.set("user_id", PROFILE_ID);
		c.set("auth_user_id", AUTH_USER_ID);
		await next();
	},
	requireAgeVerified: async (c: import("hono").Context, next: () => Promise<void>) => {
		if (!ageVerified) return c.json({ error: { code: "AGE_VERIFICATION_REQUIRED", message: "age required" } }, 403);
		await next();
	},
}));

vi.mock("../db/client", () => ({
	getSupabaseClient: vi.fn(() => ({
		from: (table: string) => {
			const query: Record<string, unknown> = {};
			query.select = (...args: unknown[]) => {
				calls.push({ method: `${table}.select`, args });
				return query;
			};
			query.eq = (...args: unknown[]) => {
				calls.push({ method: `${table}.eq`, args });
				return query;
			};
			query.maybeSingle = async () => {
				if (table === "user_profiles") return identityResult;
				if (table === "entitlements") return entitlementResult;
				if (table === "consumable_credit_balances") return creditResult;
				return { data: null, error: null };
			};
			return query;
		},
	})),
}));

import { createBillingRoute } from "./billing";

function buildApp(nowMs = () => Date.parse("2026-09-09T00:00:00.000Z")) {
	const app = new Hono();
	app.route("/api/billing", createBillingRoute({ nowMs }));
	return app;
}

beforeEach(() => {
	authEnabled = true;
	ageVerified = true;
	identityResult = {
		data: { id: PROFILE_ID, auth_user_id: AUTH_USER_ID },
		error: null,
	};
	entitlementResult = { data: null, error: null };
	creditResult = { data: null, error: null };
	calls = [];
});

describe("GET /api/billing/identity", () => {
	it("returns separate canonical profile and Supabase auth IDs", async () => {
		const response = await buildApp().request("/api/billing/identity", {}, {
			SUPABASE_URL: "https://example.supabase.co",
			SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: { profile_id: PROFILE_ID, app_user_id: AUTH_USER_ID },
		});
		expect(calls).toEqual([
			{ method: "user_profiles.select", args: ["id, auth_user_id"] },
			{ method: "user_profiles.eq", args: ["id", PROFILE_ID] },
			{ method: "user_profiles.eq", args: ["auth_user_id", AUTH_USER_ID] },
		]);
	});

	it("requires both authentication and age verification", async () => {
		authEnabled = false;
		let response = await buildApp().request("/api/billing/identity");
		expect(response.status).toBe(401);
		expect(calls).toEqual([]);

		authEnabled = true;
		ageVerified = false;
		response = await buildApp().request("/api/billing/identity");
		expect(response.status).toBe(403);
		expect(calls).toEqual([]);
	});

	it("returns a safe 404 for an absent or mismatched row", async () => {
		identityResult = {
			data: { id: OTHER_PROFILE_ID, auth_user_id: OTHER_AUTH_USER_ID },
			error: null,
		};
		const response = await buildApp().request("/api/billing/identity");
		const body = await response.text();

		expect(response.status).toBe(404);
		expect(body).toBe(JSON.stringify({ error: { code: "NOT_FOUND", message: "Billing identity unavailable" } }));
		expect(body).not.toContain(OTHER_AUTH_USER_ID);
	});

	it("fails closed with the same safe 404 when the profile query errors", async () => {
		identityResult = { data: null, error: { message: "PWNED-CANARY" } };
		const response = await buildApp().request("/api/billing/identity");
		const body = await response.text();

		expect(response.status).toBe(404);
		expect(body).not.toContain("PWNED-CANARY");
	});
});

describe("GET /api/billing/status", () => {
	it("returns inactive nulls and zero credits when both rows are absent", async () => {
		const response = await buildApp().request("/api/billing/status");

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				is_active: false,
				product_id: null,
				store: null,
				current_period_end: null,
				consumable_credits: 0,
			},
		});
		expect(calls).toContainEqual({ method: "entitlements.eq", args: ["user_id", PROFILE_ID] });
		expect(calls).toContainEqual({ method: "consumable_credit_balances.eq", args: ["user_id", PROFILE_ID] });
	});

	it("returns the active mirror and server-owned credit balance", async () => {
		entitlementResult = {
			data: {
				is_active: true,
				product_id: "wingward_premium_monthly",
				store: "TEST_STORE",
				current_period_end: "2026-09-10T00:00:00.000Z",
			},
			error: null,
		};
		creditResult = { data: { balance: 3 }, error: null };

		const response = await buildApp().request("/api/billing/status");

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				is_active: true,
				product_id: "wingward_premium_monthly",
				store: "TEST_STORE",
				current_period_end: "2026-09-10T00:00:00.000Z",
				consumable_credits: 3,
			},
		});
	});

	it("collapses expired and explicitly inactive mirrors to the closed inactive shape", async () => {
		entitlementResult = {
			data: {
				is_active: true,
				product_id: "wingward_premium_monthly",
				store: "TEST_STORE",
				current_period_end: "2026-09-08T00:00:00.000Z",
			},
			error: null,
		};
		let response = await buildApp().request("/api/billing/status");
		expect((await response.json()) as { data: unknown }).toEqual({
			data: {
				is_active: false,
				product_id: null,
				store: null,
				current_period_end: null,
				consumable_credits: 0,
			},
		});

		entitlementResult = {
			data: {
				is_active: false,
				product_id: "wingward_premium_monthly",
				store: "TEST_STORE",
				current_period_end: "2026-09-10T00:00:00.000Z",
			},
			error: null,
		};
		response = await buildApp().request("/api/billing/status");
		expect((await response.json()) as { data: unknown }).toEqual({
			data: {
				is_active: false,
				product_id: null,
				store: null,
				current_period_end: null,
				consumable_credits: 0,
			},
		});
	});

	it("returns a fixed 500 without disclosure for database or malformed-row errors", async () => {
		entitlementResult = { data: null, error: { message: "PWNED-ENTITLEMENT" } };
		let response = await buildApp().request("/api/billing/status");
		let body = await response.text();
		expect(response.status).toBe(500);
		expect(body).toBe(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "Billing status unavailable" } }));
		expect(body).not.toContain("PWNED-ENTITLEMENT");

		entitlementResult = {
			data: {
				is_active: true,
				product_id: null,
				store: "TEST_STORE",
				current_period_end: null,
			},
			error: null,
		};
		response = await buildApp().request("/api/billing/status");
		body = await response.text();
		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED");

		entitlementResult = { data: null, error: null };
		creditResult = { data: { balance: -1 }, error: null };
		response = await buildApp().request("/api/billing/status");
		expect(response.status).toBe(500);
	});
});
