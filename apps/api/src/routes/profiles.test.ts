import { Hono } from "hono";
import { describe, expect, it, vi, beforeEach } from "vitest";
import type { Env } from "../env";

/**
 * Regression test for round-1's fix at profiles.ts:105 (Codex PR #26
 * review's second finding). `profiles.ts` builds its own response instead
 * of going through the global `errorHandler`, so a regression there (e.g.
 * someone "simplifying" the upsert error branch back to `error.message`)
 * stays green against middleware/error.test.ts alone. This drives
 * POST /api/profiles/generate through its real preconditions (quiz
 * answers, >=3 completed speed-dating sessions, >=12 total messages) with a
 * mocked Mistral call and a mocked Supabase client whose `profiles` upsert
 * fails with a PostgREST error carrying a distinctive canary string in
 * `message`.
 */

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "da3da1d3-c9ce-46df-8841-d856c7c12c66");
		await next();
	},
}));
vi.mock("../services/mistral", () => ({
	chatComplete: vi.fn(async () => JSON.stringify({ basic_info: { name: "test" } })),
	MISTRAL_LARGE: "mistral-large-test",
}));
vi.mock("../services/interaction-dna", () => ({ scoreInteractionDna: vi.fn(async () => null) }));
vi.mock("../services/matching", () => ({ executeMatching: vi.fn(async () => 0) }));

import { chatComplete } from "../services/mistral";
import { executeMatching } from "../services/matching";

const CANARY_ERROR = {
	message: 'duplicate key value violates unique constraint "PWNED-CANARY-PROFILE"',
	code: "23505",
	details: "Key (user_id)=(user-1) already exists.",
};

type FakeError = { message?: string; code?: string; details?: string };

interface FakeOpts {
	languageData?: Record<string, unknown>;
	answersError?: FakeError | null;
	sessionsError?: FakeError | null;
	sessionsData?: Array<Record<string, unknown>>;
	initialProfile?: Record<string, unknown> | null;
	messagesError?: FakeError | null;
	existingError?: FakeError | null;
	upsertError?: FakeError | null;
	upsertData?: Record<string, unknown> | null;
	onboardingError?: FakeError | null;
	updatedProfileError?: FakeError | null;
	updatedProfile?: Record<string, unknown> | null;
}

/** Minimal chainable + thenable Supabase query-builder stand-in (see fox-conversation-request.test.ts for the same pattern's rationale). */
function makeChain(result: unknown) {
	const chain: Record<string, unknown> = {};
	for (const method of ["select", "eq", "order", "limit", "single", "maybeSingle", "or", "upsert", "update", "insert", "delete"]) {
		chain[method] = () => chain;
	}
	chain.then = (resolve: (v: unknown) => unknown, reject?: (e: unknown) => unknown) => Promise.resolve(result).then(resolve, reject);
	return chain;
}

function makeFakeSupabase(opts: FakeOpts = {}) {
	let profilesCallCount = 0;
	return {
		from: (table: string) => {
			if (table === "quiz_answers") return makeChain({ data: [], error: opts.answersError ?? null });
			if (table === "speed_dating_sessions") {
				return makeChain({
					data: opts.sessionsData ?? [{ id: "s1", completed_at: "2026-01-01" }, { id: "s2", completed_at: "2026-01-02" }, { id: "s3", completed_at: "2026-01-03" }],
					error: opts.sessionsError ?? null,
				});
			}
			if (table === "speed_dating_messages") {
				return makeChain({
					data: Array.from({ length: 12 }, (_, i) => ({ role: "user", content: `message ${i}` })),
					error: opts.messagesError ?? null,
				});
			}
			if (table === "profiles") {
				profilesCallCount++;
				if (profilesCallCount === 1) return makeChain({ data: opts.initialProfile ?? null, error: opts.existingError ?? null }); // waiver guard lookup (none yet)
				if (profilesCallCount === 2) {
					return makeChain({
						data: opts.upsertData ?? { id: "profile-1", version: 1 },
						error: opts.upsertError === undefined ? CANARY_ERROR : opts.upsertError,
					});
				}
				return makeChain({ data: opts.updatedProfile ?? { id: "profile-1", version: 1 }, error: opts.updatedProfileError ?? null });
			}
			if (table === "user_profiles") {
				const chain = makeChain({ data: { onboarding_status: "not_started" }, error: opts.onboardingError ?? null });
				chain.select = () => makeChain({ data: { ...opts.languageData }, error: null });
				return chain;
			}
			throw new Error(`unexpected table in test fake: ${table}`);
		},
	};
}

vi.mock("../db/client", () => ({
	getSupabaseClient: vi.fn(),
}));

import { getSupabaseClient } from "../db/client";
import profiles from "./profiles";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const mockedExecuteMatching = vi.mocked(executeMatching);

function buildApp(activeE2E = false) {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		if (activeE2E) c.set("production_e2e_active", true);
		await next();
	});
	app.route("/api/profiles", profiles);
	return app;
}

beforeEach(() => {
	mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase() as never);
	vi.mocked(chatComplete).mockClear();
	mockedExecuteMatching.mockClear();
});

describe("POST /api/profiles/generate", () => {
	it.each([undefined, "ja-JP"])("uses English account preference regardless of native header %s", async (header) => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ languageData: { ui_locale: "en", conversation_language: "ja" } }) as never);
		await buildApp().request("/api/profiles/generate", { method: "POST", headers: header ? { "accept-language": header } : {} }, { MISTRAL_API_KEY: "test-key" });
		expect(vi.mocked(chatComplete).mock.calls[0]?.[1]).toEqual(expect.arrayContaining([expect.objectContaining({ content: expect.stringContaining("Write every human-readable description, tag, and explanation in English") })]));
	});

	it("honors a Japanese account even when the device header is English", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ languageData: { ui_locale: "ja" } }) as never);
		await buildApp().request("/api/profiles/generate", { method: "POST", headers: { "accept-language": "en-US" } }, { MISTRAL_API_KEY: "test-key" });
		expect(vi.mocked(chatComplete).mock.calls[0]?.[1]).not.toEqual(expect.arrayContaining([expect.objectContaining({ content: expect.stringContaining("Write every human-readable description, tag, and explanation in English") })]));
		expect(chatComplete).toHaveBeenCalled();
	});
	it("accepts exactly two distinct real sessions only for the trusted active waiver", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({
			upsertError: null,
			sessionsData: [
				{ id: "s1", persona_id: "33333333-3333-4333-8333-333333333333", completed_at: "2026-01-02" },
				{ id: "s2", persona_id: "44444444-4444-4444-8444-444444444444", completed_at: "2026-01-01" },
			],
		}) as never);

		const app = buildApp(true);
		const response = await app.request(
			"/api/profiles/generate",
			{ method: "POST" },
			{
				MISTRAL_API_KEY: "test-key",
				PROFILE_GENERATION_WAIVER_USER_ID: "da3da1d3-c9ce-46df-8841-d856c7c12c66",
				PROFILE_GENERATION_WAIVER_EXPIRES_AT: "2099-01-01T00:00:00.000Z",
			},
		);

		expect(response.status).toBe(200);
	});

	it("keeps the three-session minimum when the trusted waiver is absent", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({
			sessionsData: [
				{ id: "s1", persona_id: "33333333-3333-4333-8333-333333333333", completed_at: "2026-01-02" },
				{ id: "s2", persona_id: "44444444-4444-4444-8444-444444444444", completed_at: "2026-01-01" },
			],
		}) as never);

		const response = await buildApp().request(
			"/api/profiles/generate",
			{ method: "POST" },
			{ MISTRAL_API_KEY: "test-key" },
		);

		expect(response.status).toBe(409);
		expect(await response.json()).toEqual({
			error: { code: "CONFLICT", message: "Not enough completed speed-dating sessions" },
		});
		expect(chatComplete).not.toHaveBeenCalled();
	});

	it("does not invoke the provider again after a waiver profile is already persisted", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({
			initialProfile: { id: "profile-1", status: "draft" },
			sessionsData: [
				{ id: "s1", persona_id: "33333333-3333-4333-8333-333333333333", completed_at: "2026-01-02" },
				{ id: "s2", persona_id: "44444444-4444-4444-8444-444444444444", completed_at: "2026-01-01" },
			],
		}) as never);

		const response = await buildApp(true).request(
			"/api/profiles/generate",
			{ method: "POST" },
			{
				MISTRAL_API_KEY: "test-key",
				PROFILE_GENERATION_WAIVER_USER_ID: "da3da1d3-c9ce-46df-8841-d856c7c12c66",
				PROFILE_GENERATION_WAIVER_EXPIRES_AT: "2099-01-01T00:00:00.000Z",
			},
		);

		expect(response.status).toBe(409);
		expect(await response.json()).toEqual({
			error: { code: "CONFLICT", message: "Profile already generated" },
		});
		expect(chatComplete).not.toHaveBeenCalled();
	});

	it("does not reflect the raw Postgres error message when the profile upsert fails", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		const app = buildApp();
		const res = await app.request(
			"/api/profiles/generate",
			{ method: "POST" },
			{ MISTRAL_API_KEY: "test-key" },
		);
		const bodyText = await res.text();

		expect(res.status).toBe(500);
		expect(bodyText).not.toContain("PWNED-CANARY-PROFILE");
		expect(JSON.parse(bodyText)).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to save profile" },
		});

		consoleErrorSpy.mockRestore();
	});

	it("fails closed when quiz answers cannot be loaded", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ answersError: { code: "XX000", message: "PWNED-CANARY-ANSWERS" } }) as never,
		);

		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-ANSWERS");
		expect(JSON.parse(body)).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to load profile inputs" },
		});
		expect(chatComplete).not.toHaveBeenCalled();
	});

	it("fails closed when the existing profile lookup errors instead of defaulting the version", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ upsertError: null, existingError: { code: "XX000", message: "PWNED-CANARY-EXISTING" } }) as never,
		);

		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-EXISTING");
		expect(JSON.parse(body)).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to load existing profile" },
		});
	});

	it.each([
		{ name: "completed sessions", options: { upsertError: null, sessionsError: { message: "canary" } }, message: "Failed to load profile inputs" },
		{ name: "conversation history", options: { upsertError: null, messagesError: { message: "canary" } }, message: "Failed to load profile inputs" },
		{ name: "onboarding update", options: { upsertError: null, onboardingError: { message: "canary" } }, message: "Failed to update onboarding status" },
		{ name: "saved profile read", options: { upsertError: null, updatedProfileError: { message: "canary" } }, message: "Failed to read saved profile" },
	] as const)("fails closed when the $name fails", async ({ options, message }) => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase(options) as never);
		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await response.text();
		expect(response.status).toBe(500);
		expect(body).not.toContain("canary");
		expect(JSON.parse(body)).toEqual({ error: { code: "INTERNAL_ERROR", message } });
	});

	it("normalizes a chatComplete failure without raw provider text in the response or marker", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		vi.mocked(chatComplete).mockRejectedValueOnce({ message: "PWNED-CANARY-PROVIDER", body: "PWNED-CANARY-BODY" });

		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY");
		expect(JSON.parse(body)).toEqual({
			error: { code: "INTERNAL_ERROR", message: "AI profile generation unavailable" },
		});
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/generation] stage=profile_model");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("PWNED-CANARY");

		consoleErrorSpy.mockRestore();
	});

	it("rejects a non-object generated JSON value before profile persistence", async () => {
		vi.mocked(chatComplete).mockResolvedValueOnce("null");

		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).toEqual(JSON.stringify({
			error: { code: "INTERNAL_ERROR", message: "Failed to parse generated profile JSON" },
	}));
	});

	it("exposes only a verified upstream status in trusted E2E diagnostics", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		vi.mocked(chatComplete).mockRejectedValueOnce({
			statusCode: 429,
			message: "PWNED-CANARY-PROVIDER",
			body: "PWNED-CANARY-BODY",
		});

		const response = await buildApp(true).request("/api/profiles/generate", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY");
		expect(response.headers.get("X-Wingward-Generation-Stage")).toBe("profile_model");
		expect(response.headers.get("X-Wingward-Generation-Upstream-Status")).toBe("429");
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/generation] stage=profile_model upstream_status=429");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("PWNED-CANARY");

		consoleErrorSpy.mockRestore();
	});
});

type ConfirmOptions = {
	preferenceMode?: unknown;
	preferenceError?: unknown;
};

function makeConfirmSupabase(options: ConfirmOptions = {}) {
	const updates: Array<{ table: string; payload: unknown }> = [];
	return {
		updates,
		from(table: string) {
			let operation = "read";
			const query: Record<string, unknown> = {};
			for (const method of ["select", "eq", "maybeSingle"]) query[method] = () => query;
			query.update = (payload: unknown) => {
				operation = "update";
				updates.push({ table, payload });
				return query;
			};
			query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => {
				let result: unknown = { data: null, error: null };
				if (table === "user_profiles") {
					result = operation === "read"
						? {
								data: { preference_mode: options.preferenceMode },
								error: options.preferenceError ?? null,
							}
						: { data: null, error: null };
				} else if (table === "personas") {
					result = { data: { id: "persona-1" }, error: null };
				}
				return Promise.resolve(result).then(resolve, reject);
			};
			return query;
		},
	};
}

function buildConfirmApp(trustedE2E: boolean) {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		if (trustedE2E) c.set("production_e2e_active", true);
		await next();
	});
	app.route("/api/profiles", profiles);
	return app;
}

describe("POST /api/profiles/me/confirm production E2E boundary", () => {
	it.each([undefined, "selected"] as const)("rejects a trusted E2E confirmation with preference_mode=%s", async (preferenceMode) => {
		const supabase = makeConfirmSupabase({ preferenceMode });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildConfirmApp(true).request("/api/profiles/me/confirm", { method: "POST" });
		const body = await response.text();

		expect(response.status).toBe(409);
		expect(body).toEqual(JSON.stringify({ error: { code: "CONFLICT", message: "Profile confirmation unavailable" } }));
		expect(supabase.updates).toHaveLength(0);
		expect(mockedExecuteMatching).not.toHaveBeenCalled();
	});

	it("fails closed on a trusted E2E preference read error without exposing provider data", async () => {
		const supabase = makeConfirmSupabase({ preferenceError: { message: "PWNED-CANARY-PREFERENCE" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildConfirmApp(true).request("/api/profiles/me/confirm", { method: "POST" });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-PREFERENCE");
		expect(supabase.updates).toHaveLength(0);
		expect(mockedExecuteMatching).not.toHaveBeenCalled();
	});

	it("confirms a trusted no-answer profile without running immediate matching or overwriting the preference", async () => {
		const supabase = makeConfirmSupabase({ preferenceMode: "no_answer" });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildConfirmApp(true).request("/api/profiles/me/confirm", { method: "POST" });

		expect(response.status).toBe(200);
		expect(mockedExecuteMatching).not.toHaveBeenCalled();
		expect(supabase.updates).toHaveLength(2);
		expect(supabase.updates.map(({ payload }) => payload)).not.toContainEqual(expect.objectContaining({ preference_mode: expect.anything() }));
	});

	it("keeps normal production confirmation matching behavior", async () => {
		const supabase = makeConfirmSupabase({ preferenceMode: "selected" });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildConfirmApp(false).request("/api/profiles/me/confirm", { method: "POST" });

		expect(response.status).toBe(200);
		expect(mockedExecuteMatching).toHaveBeenCalledTimes(1);
	});

	it("does not treat a spoofed E2E header as trusted context", async () => {
		const supabase = makeConfirmSupabase({ preferenceMode: "selected" });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildConfirmApp(false).request("/api/profiles/me/confirm", {
			method: "POST",
			headers: { "X-Wingward-E2E": "true" },
		});

		expect(response.status).toBe(200);
		expect(mockedExecuteMatching).toHaveBeenCalledTimes(1);
	});
});
