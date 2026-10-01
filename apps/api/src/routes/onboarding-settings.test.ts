import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const testAuth = vi.hoisted(() => ({ reject: false }));

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		if (testAuth.reject) {
			return c.json({ error: { code: "UNAUTHORIZED", message: "Authentication required" } }, 401);
		}
		c.set("user_id", "profile-1");
		c.set("auth_user_id", "auth-1");
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import auth from "./auth";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

const completeSettings = {
	ui_locale: "ja",
	dating_market: "JP",
	conversation_language: "en",
	timezone: "Asia/Tokyo",
	distance_unit: "km",
	gender_identity: "woman",
	gender_visibility: "private",
	preferred_genders: ["woman", "nonbinary"],
	preference_mode: "selected",
	location_mode: "station",
	station_id: "jp-tokyo-shimokitazawa",
	coarse_area_id: "jp-tokyo-setagaya",
} as const;

const noAnswerSettings = {
	...completeSettings,
	gender_identity: null,
	preferred_genders: [],
	preference_mode: "no_answer",
	location_mode: "not_set",
	station_id: null,
	coarse_area_id: null,
} as const;

type FakeOptions = {
	row?: Record<string, unknown> | null;
	selectError?: { message: string } | null;
	updateError?: { message: string } | null;
};

function makeRow(settings: Record<string, unknown> = completeSettings, completed = true): Record<string, unknown> {
	return {
		...settings,
		onboarding_settings_completed_at: completed ? "2026-09-05T00:00:00.000Z" : null,
	};
}

function makeSupabase(options: FakeOptions = {}) {
	const updateCalls: Record<string, unknown>[] = [];
	const eqCalls: Array<[string, unknown]> = [];
	const row = options.row === undefined ? makeRow() : options.row;
	return {
		updateCalls,
		eqCalls,
		from(table: string) {
			if (table !== "user_profiles") throw new Error(`unexpected table: ${table}`);
			return {
				select: () => ({
					eq: (column: string, value: unknown) => {
						eqCalls.push([column, value]);
						return {
							maybeSingle: async () => ({ data: row, error: options.selectError ?? null }),
							single: async () => ({ data: row, error: options.selectError ?? null }),
						};
					},
				}),
				update: (payload: Record<string, unknown>) => {
					updateCalls.push(payload);
					return {
						eq: (column: string, value: unknown) => {
							eqCalls.push([column, value]);
							return {
								select: () => ({
									single: async () => ({
										data: options.updateError ? null : makeRow(payload),
										error: options.updateError ?? null,
									}),
								}),
							};
						},
					};
				},
			};
		},
	};
}

function makeApp() {
	const app = new Hono();
	app.route("/api/auth", auth);
	return app;
}

function finiteOversizedPhotoStream(bytes: Uint8Array, onCancel: () => void): ReadableStream<Uint8Array> {
	let emitted = false;
	return new ReadableStream<Uint8Array>({
		pull(controller) {
			if (emitted) {
				controller.close();
				return;
			}
			emitted = true;
			controller.enqueue(bytes);
		},
		cancel() {
			onCancel();
		},
	});
}

beforeEach(() => {
	vi.useFakeTimers();
	vi.setSystemTime(new Date("2026-09-05T12:00:00.000Z"));
	mockedGetSupabaseClient.mockReset();
	testAuth.reject = false;
});

afterEach(() => {
	vi.useRealTimers();
});

describe("GET /api/auth/me/onboarding-settings", () => {
	it("returns null for a legacy row that has not completed the new settings save", async () => {
		const fake = makeSupabase({ row: makeRow(completeSettings, false) });
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const response = await makeApp().request("/api/auth/me/onboarding-settings");

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: null });
		expect(fake.eqCalls).toContainEqual(["id", "profile-1"]);
	});

	it("returns only the exact private DTO after completion", async () => {
		const fake = makeSupabase({
			row: {
				...makeRow(),
				language: "en",
				region: "US",
				gender: "female",
				nickname: "private-user",
			},
		});
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const response = await makeApp().request("/api/auth/me/onboarding-settings");
		const body = (await response.json()) as { data: Record<string, unknown> };

		expect(response.status).toBe(200);
		expect(body.data).toEqual(completeSettings);
		expect(body.data).not.toHaveProperty("onboarding_settings_completed_at");
		expect(body.data).not.toHaveProperty("language");
		expect(body.data).not.toHaveProperty("region");
		expect(body.data).not.toHaveProperty("gender");
		expect(fake.eqCalls).toContainEqual(["id", "profile-1"]);
	});

	it("fails closed when the stored completed row is malformed", async () => {
		const fake = makeSupabase({ row: makeRow({ ...completeSettings, preferred_genders: ["not-a-category"] }) });
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const response = await makeApp().request("/api/auth/me/onboarding-settings");

		expect(response.status).toBe(500);
		expect(await response.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Onboarding settings are unavailable" },
		});
	});
});

describe("GET /api/auth/me/onboarding-options", () => {
	it("returns the Japanese fixture catalog with draft terms", async () => {
		const response = await makeApp().request(
			"/api/auth/me/onboarding-options?dating_market=JP&ui_locale=ja",
		);

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				stations: [
					{ id: "jp-tokyo-shimokitazawa", name: "下北沢", coarse_area_id: "jp-tokyo-setagaya" },
					{ id: "jp-tokyo-shibuya", name: "渋谷", coarse_area_id: "jp-tokyo-shibuya" },
				],
				areas: [
					{ id: "jp-tokyo-setagaya", name: "世田谷区" },
					{ id: "jp-tokyo-shibuya", name: "渋谷区" },
				],
				terms: { market: "JP", status: "draft" },
				catalog_status: "fixture",
			},
		});
	});

	it("rejects unknown or missing query parameters without exposing parser details", async () => {
		const unknown = await makeApp().request(
			"/api/auth/me/onboarding-options?dating_market=JP&ui_locale=ja&station=home",
		);
		const missing = await makeApp().request("/api/auth/me/onboarding-options?dating_market=JP");

		expect(unknown.status).toBe(400);
		expect(missing.status).toBe(400);
		expect(await unknown.json()).toEqual({ error: { code: "BAD_REQUEST", message: "Invalid onboarding options" } });
	});
});

describe("onboarding route authentication", () => {
	it.each([
		["GET settings", "/api/auth/me/onboarding-settings", undefined],
		["GET options", "/api/auth/me/onboarding-options?dating_market=JP&ui_locale=ja", undefined],
		[
			"PUT settings",
			"/api/auth/me/onboarding-settings",
			{
				method: "PUT",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify(completeSettings),
			},
		],
		[
			"POST photo",
			"/api/auth/me/photo",
			{
				method: "POST",
				headers: { "Content-Type": "image/jpeg" },
				body: new Uint8Array([0xff, 0xd8, 0xff, 0xd9]),
			},
		],
	] as const)("rejects unauthenticated %s before any database call", async (_label, path, init) => {
		testAuth.reject = true;
		const response = await makeApp().request(path, init);

		expect(response.status).toBe(401);
		expect(await response.json()).toEqual({
			error: { code: "UNAUTHORIZED", message: "Authentication required" },
		});
		expect(mockedGetSupabaseClient).not.toHaveBeenCalled();
	});
});

describe("PUT /api/auth/me/onboarding-settings", () => {
	it.each([
		["unknown field", { ...completeSettings, extra: true }],
		["no-answer with selected values", { ...completeSettings, preference_mode: "no_answer" }],
		["empty selected values", { ...completeSettings, preferred_genders: [], preference_mode: "selected" }],
		["duplicate preferences", { ...completeSettings, preferred_genders: ["woman", "woman"] }],
		["invalid timezone", { ...completeSettings, timezone: "Not/AZone" }],
		["numeric offset timezone", { ...completeSettings, timezone: "+01:00" }],
		["cross-market station", { ...completeSettings, dating_market: "US", station_id: "jp-tokyo-shimokitazawa", coarse_area_id: "jp-tokyo-setagaya" }],
		["freeform station", { ...completeSettings, station_id: "someone-home", coarse_area_id: "jp-tokyo-setagaya" }],
		["submitted owner id", { ...completeSettings, user_id: "profile-2" }],
	])("rejects %s before any write", async (_label, payload) => {
		const fake = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const response = await makeApp().request("/api/auth/me/onboarding-settings", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(payload),
		});

		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: { code: "BAD_REQUEST", message: "Invalid onboarding settings" } });
		expect(fake.updateCalls).toHaveLength(0);
		expect(fake.eqCalls).toHaveLength(0);
	});

	it("accepts a complete explicit no-answer save with a null identity", async () => {
		const fake = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const response = await makeApp().request("/api/auth/me/onboarding-settings", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(noAnswerSettings),
		});
		const body = (await response.json()) as { data: Record<string, unknown> };

		expect(response.status).toBe(200);
		expect(body.data).toEqual(noAnswerSettings);
		expect(fake.updateCalls[0]).toMatchObject({
			...noAnswerSettings,
			language: "ja",
			region: "JP",
		});
	});

	it("writes the full object, synchronizes legacy aliases, and returns the exact DTO", async () => {
		const fake = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const response = await makeApp().request("/api/auth/me/onboarding-settings", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(completeSettings),
		});
		const body = (await response.json()) as { data: Record<string, unknown> };

		expect(response.status).toBe(200);
		expect(body.data).toEqual(completeSettings);
		expect(fake.updateCalls).toHaveLength(1);
		expect(fake.updateCalls[0]).toMatchObject({
			...completeSettings,
			language: "ja",
			region: "JP",
			onboarding_settings_completed_at: "2026-09-05T12:00:00.000Z",
			updated_at: "2026-09-05T12:00:00.000Z",
		});
		expect(fake.eqCalls).toContainEqual(["id", "profile-1"]);
	});

	it("does not report success when persistence fails", async () => {
		const fake = makeSupabase({ updateError: { message: "db failure" } });
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const response = await makeApp().request("/api/auth/me/onboarding-settings", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(completeSettings),
		});

		expect(response.status).toBe(500);
		expect(await response.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to save onboarding settings" },
		});
	});
});

describe("POST /api/auth/me/photo", () => {
	it("rejects invalid content before the disabled adapter boundary", async () => {
		const response = await makeApp().request("/api/auth/me/photo", {
			method: "POST",
			headers: { "Content-Type": "image/jpeg" },
			body: new Uint8Array([1, 2, 3]),
		});

		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: { code: "BAD_REQUEST", message: "Invalid profile photo" } });
	});

	it("returns unavailable for a valid image while no decoder/storage is injected", async () => {
		const response = await makeApp().request("/api/auth/me/photo", {
			method: "POST",
			headers: { "Content-Type": "image/jpeg" },
			body: new Uint8Array([0xff, 0xd8, 0xff, 0xd9]),
		});

		expect(response.status).toBe(503);
		expect(await response.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Profile photo upload is unavailable" },
		});
	});

	it("bounds a chunked body before buffering more than the configured maximum", async () => {
		const oversized = new Uint8Array(5 * 1024 * 1024 + 1);
		oversized.set([0xff, 0xd8, 0xff]);
		let cancelled = false;
		const stream = finiteOversizedPhotoStream(oversized, () => {
			cancelled = true;
		});
		const request = new Request("http://localhost/api/auth/me/photo", {
			method: "POST",
			headers: { "Content-Type": "image/jpeg" },
			body: stream,
			duplex: "half",
		} as RequestInit);

		const response = await makeApp().fetch(request);

		expect(response.status).toBe(400);
		expect(cancelled).toBe(true);
	});

	it("still bounds an oversized chunk when Content-Length is deceptive", async () => {
		const oversized = new Uint8Array(5 * 1024 * 1024 + 1);
		oversized.set([0xff, 0xd8, 0xff]);
		let cancelled = false;
		const stream = finiteOversizedPhotoStream(oversized, () => {
			cancelled = true;
		});
		const request = new Request("http://localhost/api/auth/me/photo", {
			method: "POST",
			headers: { "Content-Type": "image/jpeg", "Content-Length": "4" },
			body: stream,
			duplex: "half",
		} as RequestInit);

		const response = await makeApp().fetch(request);

		expect(response.status).toBe(400);
		expect(cancelled).toBe(true);
	});
});
