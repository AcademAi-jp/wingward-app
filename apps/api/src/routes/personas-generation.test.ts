import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
import { readRecordingRehearsalConfig } from "../services/recording-rehearsal";

const OWNER_ID = vi.hoisted(() => "11111111-1111-4111-8111-111111111111");
const OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222";
const WINGFOX_PERSONA_ID = "33333333-3333-4333-8333-333333333333";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", c.req.header("x-test-user") ?? OWNER_ID);
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));
vi.mock("../services/mistral", () => ({ chatComplete: vi.fn(async () => "generated"), MISTRAL_LARGE: "large-test" }));
vi.mock("../lib/fox-icons", () => ({ getRandomIconUrlForGender: vi.fn(() => "/fox.png") }));

import { getSupabaseClient } from "../db/client";
import { chatComplete } from "../services/mistral";
import personas from "./personas";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const mockedChatComplete = vi.mocked(chatComplete);
const SORA_ID = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";

describe("Sora recording draft preservation", () => {
	it("blocks existing Wingfox regeneration before database or provider access", async () => {
		const now = Date.now();
		const parsed = readRecordingRehearsalConfig({
			RECORDING_REHEARSAL_ENABLED: "enabled",
			RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 60_000).toISOString(),
			RECORDING_REHEARSAL_EXPIRES_AT: new Date(now + 30 * 60_000).toISOString(),
			RECORDING_REHEARSAL_PAIR: "sora-ren",
		}, now);
		if (parsed.kind !== "active") throw new Error("Expected active rehearsal configuration");
		mockedGetSupabaseClient.mockClear();
		mockedChatComplete.mockClear();
		const app = new Hono<Env>();
		app.use("*", async (c, next) => {
			c.set("recording_rehearsal", parsed.config);
			await next();
		});
		app.route("/api/personas", personas);
		const response = await app.request("/api/personas/wingfox/generate", {
			method: "POST",
			headers: { "x-test-user": SORA_ID },
		});
		expect(response.status).toBe(409);
		expect(mockedGetSupabaseClient).not.toHaveBeenCalled();
		expect(mockedChatComplete).not.toHaveBeenCalled();
	});
});
type Failure = "profile" | "sessions" | "messages" | "user_profile" | "section_save" | "onboarding" | "section_read" | "definitions";

function chain(result: unknown) {
	const q: Record<string, unknown> = {};
	for (const method of ["select", "eq", "order", "limit", "maybeSingle", "single", "upsert", "update"]) q[method] = () => q;
	q.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve(result).then(resolve, reject);
	return q;
}

function makeSupabase(failure: Failure) {
	let userProfileCalls = 0;
	let sectionCalls = 0;
	return {
		from(table: string) {
			if (table === "profiles") return chain({ data: failure === "profile" ? null : { id: "profile-1" }, error: failure === "profile" ? { message: "canary" } : null });
			if (table === "speed_dating_sessions") return chain({ data: failure === "sessions" ? null : [{ id: "s1" }, { id: "s2" }, { id: "s3" }], error: failure === "sessions" ? { message: "canary" } : null });
			if (table === "speed_dating_messages") return chain({ data: failure === "messages" ? null : [{ role: "user", content: "hello" }, { role: "persona", content: "hi" }], error: failure === "messages" ? { message: "canary" } : null });
			if (table === "user_profiles") {
				userProfileCalls += 1;
				if (userProfileCalls === 1) return chain({ data: failure === "user_profile" ? null : { gender: "female", nickname: "Fox" }, error: failure === "user_profile" ? { message: "canary" } : null });
				return chain({ data: null, error: failure === "onboarding" ? { message: "canary" } : null });
			}
			if (table === "personas") return chain({
				data: failure === "profile" ? null : {
					id: WINGFOX_PERSONA_ID,
					user_id: OWNER_ID,
					persona_type: "wingfox",
					name: "Fox",
					compiled_document: "doc",
					version: 1,
				},
				error: null,
			});
			if (table === "persona_sections") {
				sectionCalls += 1;
				if (sectionCalls <= 8) return chain({ data: null, error: failure === "section_save" && sectionCalls === 1 ? { message: "canary" } : null });
				return chain({ data: failure === "section_read" ? null : [{ section_id: "core_identity", content: "generated", source: "ai" }], error: failure === "section_read" ? { message: "canary" } : null });
			}
			if (table === "persona_section_definitions") return chain({ data: failure === "definitions" ? null : [{ id: "core_identity", title: "Core", editable: true }], error: failure === "definitions" ? { message: "canary" } : null });
			throw new Error(`unexpected table ${table}`);
		},
	};
}

function makeSuccessfulWingfoxSupabase(
	personaOwnerID = OWNER_ID,
	options: { sessionRows?: Array<Record<string, unknown>>; existingWingfox?: unknown } = {},
) {
	const calls = new Map<string, number>();
	const generatedSections = [{ section_id: "core_identity", content: "generated", source: "ai" }];
	return {
		from(table: string) {
			const callNumber = (calls.get(table) ?? 0) + 1;
			calls.set(table, callNumber);
			const query: Record<string, unknown> = {};
			let operation: "read" | "upsert" | "update" = "read";
			for (const method of ["select", "eq", "order", "limit", "maybeSingle", "single"]) query[method] = () => query;
			query.upsert = () => {
				operation = "upsert";
				return query;
			};
			query.update = () => {
				operation = "update";
				return query;
			};
			query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => {
				let result: unknown = { data: null, error: null };
				if (table === "profiles") {
					result = { data: { id: "profile-1" }, error: null };
				} else if (table === "speed_dating_sessions") {
					result = {
						data: options.sessionRows ?? [{ id: "session-1" }, { id: "session-2" }, { id: "session-3" }],
						error: null,
					};
				} else if (table === "speed_dating_messages") {
					result = {
						data: [
							{ role: "user", content: "hello" },
							{ role: "persona", content: "hi" },
							{ role: "user", content: "How are you?" },
						],
						error: null,
					};
				} else if (table === "user_profiles") {
					result = operation === "update"
						? { data: null, error: null }
						: { data: { gender: "female", nickname: "Fox" }, error: null };
				} else if (table === "personas") {
					result = {
						data: operation === "read" && callNumber === 1 ? (options.existingWingfox ?? null) : {
							id: WINGFOX_PERSONA_ID,
							user_id: personaOwnerID,
							persona_type: "wingfox",
							name: "Fox",
							compiled_document: "doc",
							version: 1,
						},
						error: null,
					};
				} else if (table === "persona_sections") {
					result = callNumber <= 8
						? { data: null, error: null }
						: { data: generatedSections, error: null };
				} else if (table === "persona_section_definitions") {
					result = {
						data: [{ id: "core_identity", title: "Core", editable: true }],
						error: null,
					};
				}
				return Promise.resolve(result).then(resolve, reject);
			};
			return query;
		},
	};
}

beforeEach(() => vi.restoreAllMocks());

describe("POST /api/personas/wingfox/generate Supabase failures", () => {
	it.each(["profile", "sessions", "messages", "user_profile", "section_save", "onboarding", "section_read", "definitions"] as const)(
		"fails closed when %s fails",
		async (failure) => {
			mockedGetSupabaseClient.mockReturnValue(makeSupabase(failure) as never);
			const app = new Hono();
			app.route("/api/personas", personas);
			const response = await app.request("/api/personas/wingfox/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
			const body = await response.text();
			expect(response.status).toBe(500);
			expect(body).not.toContain("canary");
		},
	);
});

describe("POST /api/personas/wingfox/generate acknowledgement", () => {
	beforeEach(() => {
		mockedChatComplete.mockResolvedValue("name: Sakura\n## Core Identity\nA calm listener.");
	});

	it("includes the server-selected owner ID in the acknowledgement", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSuccessfulWingfoxSupabase() as never);
		const app = new Hono();
		app.route("/api/personas", personas);

		const response = await app.request("/api/personas/wingfox/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = (await response.json()) as { data: { id: string; user_id: string } };

		expect(response.status).toBe(200);
		expect(body.data.id).toBe(WINGFOX_PERSONA_ID);
		expect(body.data.user_id).toBe(OWNER_ID);
	});

	it("accepts exactly two distinct real sessions only for the trusted active waiver", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSuccessfulWingfoxSupabase(OWNER_ID, {
			sessionRows: [
				{ id: "session-1", persona_id: "33333333-3333-4333-8333-333333333333" },
				{ id: "session-2", persona_id: "44444444-4444-4444-8444-444444444444" },
			],
		}) as never);
		const app = new Hono<Env>();
		app.use("*", async (c, next) => {
			c.set("production_e2e_active", true);
			await next();
		});
		app.route("/api/personas", personas);

		const response = await app.request(
			"/api/personas/wingfox/generate",
			{ method: "POST" },
			{
				MISTRAL_API_KEY: "test-key",
				PROFILE_GENERATION_WAIVER_USER_ID: OWNER_ID,
				PROFILE_GENERATION_WAIVER_EXPIRES_AT: "2099-01-01T00:00:00.000Z",
			},
		);

		expect(response.status).toBe(200);
	});

	it("keeps the three-session minimum when the trusted waiver is absent", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSuccessfulWingfoxSupabase(OWNER_ID, {
			sessionRows: [
				{ id: "session-1", persona_id: "33333333-3333-4333-8333-333333333333" },
				{ id: "session-2", persona_id: "44444444-4444-4444-8444-444444444444" },
			],
		}) as never);
		const app = new Hono();
		app.route("/api/personas", personas);

		const response = await app.request(
			"/api/personas/wingfox/generate",
			{ method: "POST" },
			{ MISTRAL_API_KEY: "test-key" },
		);

		expect(response.status).toBe(409);
		expect(await response.json()).toEqual({
			error: { code: "CONFLICT", message: "Not enough completed speed-dating sessions" },
		});
		expect(mockedChatComplete).not.toHaveBeenCalled();
	});

	it("does not invoke the provider again after a waiver Wing Fox is already persisted", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSuccessfulWingfoxSupabase(OWNER_ID, {
			existingWingfox: {
				id: WINGFOX_PERSONA_ID,
				user_id: OWNER_ID,
				persona_type: "wingfox",
			},
		}) as never);
		const app = new Hono<Env>();
		app.use("*", async (c, next) => {
			c.set("production_e2e_active", true);
			await next();
		});
		app.route("/api/personas", personas);

		const response = await app.request(
			"/api/personas/wingfox/generate",
			{ method: "POST" },
			{
				MISTRAL_API_KEY: "test-key",
				PROFILE_GENERATION_WAIVER_USER_ID: OWNER_ID,
				PROFILE_GENERATION_WAIVER_EXPIRES_AT: "2099-01-01T00:00:00.000Z",
			},
		);

		expect(response.status).toBe(409);
		expect(await response.json()).toEqual({
			error: { code: "CONFLICT", message: "AI partner already generated" },
		});
		expect(mockedChatComplete).not.toHaveBeenCalled();
	});

	it("fails closed when the persisted acknowledgement belongs to another owner", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSuccessfulWingfoxSupabase(OTHER_OWNER_ID) as never);
		const app = new Hono();
		app.route("/api/personas", personas);

		const response = await app.request("/api/personas/wingfox/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain(OTHER_OWNER_ID);
	});

	it("normalizes a chatComplete failure without arbitrary provider data", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(makeSuccessfulWingfoxSupabase() as never);
		mockedChatComplete.mockRejectedValueOnce({ message: "PWNED-CANARY-PROVIDER", body: "PWNED-CANARY-BODY" });
		const app = new Hono();
		app.route("/api/personas", personas);

		const response = await app.request("/api/personas/wingfox/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY");
		expect(JSON.parse(body)).toEqual({
			error: { code: "INTERNAL_ERROR", message: "AI persona generation unavailable" },
		});
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/generation] stage=wingfox_model");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("PWNED-CANARY");

		consoleErrorSpy.mockRestore();
	});

	it("adds only a verified upstream status to trusted E2E diagnostics", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(makeSuccessfulWingfoxSupabase() as never);
		mockedChatComplete.mockRejectedValueOnce({
			statusCode: 401,
			message: "PWNED-CANARY-PROVIDER",
			body: "PWNED-CANARY-BODY",
		});
		const app = new Hono<Env>();
		app.use("*", async (c, next) => {
			c.set("production_e2e_active", true);
			await next();
		});
		app.route("/api/personas", personas);

		const response = await app.request("/api/personas/wingfox/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY");
		expect(response.headers.get("X-Wingward-Generation-Stage")).toBe("wingfox_model");
		expect(response.headers.get("X-Wingward-Generation-Upstream-Status")).toBe("401");
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/generation] stage=wingfox_model upstream_status=401");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("PWNED-CANARY");

		consoleErrorSpy.mockRestore();
	});
});
