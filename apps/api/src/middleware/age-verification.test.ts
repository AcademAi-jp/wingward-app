import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";

vi.mock("../db/client", () => ({
	getSupabaseAuthClient: vi.fn(),
	getSupabaseClient: vi.fn(),
}));

import { getSupabaseClient } from "../db/client";
import { requireAgeVerified } from "./auth";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

function makeApp(userId: string | null = "profile-1") {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		if (userId) c.set("user_id", userId);
		return requireAgeVerified(c as never, next);
	});
	app.get("/", (c) => c.text("allowed"));
	return app;
}

function mockAgeLookup(result: { data: { age_verified_at: string | null } | null; error: { message: string } | null }) {
	mockedGetSupabaseClient.mockReturnValue({
		from: () => ({
			select: () => ({
				eq: () => ({ maybeSingle: async () => result }),
			}),
		}),
	} as never);
}

beforeEach(() => {
	vi.clearAllMocks();
});

describe("requireAgeVerified", () => {
	it("allows a verified user", async () => {
		mockAgeLookup({ data: { age_verified_at: "2026-08-24T00:00:00Z" }, error: null });
		const res = await makeApp().request("/");
		expect(res.status).toBe(200);
		expect(await res.text()).toBe("allowed");
	});

	it.each([
		["unverified", { data: { age_verified_at: null }, error: null }],
		["missing profile", { data: null, error: null }],
	])("rejects %s with the age-gate machine code", async (_label, result) => {
		mockAgeLookup(result);
		const res = await makeApp().request("/");
		expect(res.status).toBe(403);
		expect(await res.json()).toEqual({
			error: { code: "AGE_VERIFICATION_REQUIRED", message: "Age verification required" },
		});
	});

	it("returns 500 on a lookup error", async () => {
		mockAgeLookup({ data: null, error: { message: "database unavailable" } });
		const res = await makeApp().request("/");
		expect(res.status).toBe(500);
		expect(await res.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to verify age status" },
		});
	});

	it("returns a safe 500 when the user context is missing", async () => {
		const res = await makeApp(null).request("/");
		expect(res.status).toBe(500);
		expect(await res.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Age verification is unavailable" },
		});
	});

	it("does not cache age state across requests", async () => {
		let callCount = 0;
		mockedGetSupabaseClient.mockReturnValue({
			from: () => ({
				select: () => ({
					eq: () => ({
						maybeSingle: async () => {
							callCount += 1;
							return { data: { age_verified_at: callCount === 1 ? null : "2026-08-24T00:00:00Z" }, error: null };
						},
					}),
				}),
			}),
		} as never);

		const app = makeApp();
		expect((await app.request("/")).status).toBe(403);
		expect((await app.request("/")).status).toBe(200);
		expect(callCount).toBe(2);
	});
});
