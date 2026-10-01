import { readFileSync } from "node:fs";
import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const PROFILE_ID = "11111111-1111-4111-8111-111111111111";
const OTHER_PROFILE_ID = "22222222-2222-4222-8222-222222222222";
const FUTURE_EXPIRY = "2099-01-01T00:00:00.000Z";

const gateState = vi.hoisted(() => ({
	resolveAuthUser: vi.fn(),
	getSupabaseClient: vi.fn(),
	routeUserId: "11111111-1111-4111-8111-111111111111",
	executeMatching: vi.fn(),
}));

vi.mock("./middleware/auth", async () => {
	const actual = await vi.importActual<typeof import("./middleware/auth")>("./middleware/auth");
	return {
		...actual,
		resolveAuthUser: gateState.resolveAuthUser,
		requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
			c.set("auth_user_id", "auth-test");
			c.set("user_id", gateState.routeUserId);
			await next();
		},
	};
});

vi.mock("./db/client", () => ({
	getSupabaseAuthClient: vi.fn(),
	getSupabaseClient: gateState.getSupabaseClient,
}));
vi.mock("./services/matching", async () => {
	const actual = await vi.importActual<typeof import("./services/matching")>("./services/matching");
	return { ...actual, executeMatching: gateState.executeMatching };
});

import { app } from "./app";
import { productionE2EGate, PRODUCTION_E2E_ALLOWED_ROUTES } from "./middleware/production-e2e-gate";
import type { Env } from "./env";
import { SYNTHETIC_MATCHING_PROFILE_IDS as SYNTHETIC_IDS, SYNTHETIC_MATCHING_EXPIRES_AT } from "./services/synthetic-matching-cohort";

const APP_SOURCE = readFileSync(new URL("./app.ts", import.meta.url), "utf8");

function activeEnv(overrides: Record<string, string | undefined> = {}) {
	return {
		PRODUCTION_E2E_PROFILE_IDS: PROFILE_ID,
		PRODUCTION_E2E_EXPIRES_AT: FUTURE_EXPIRY,
		...overrides,
	};
}

function installQuizClient() {
	gateState.getSupabaseClient.mockReturnValue({
		from: (table: string) => {
			if (table !== "quiz_questions") throw new Error(`unexpected table: ${table}`);
			return {
				select: () => ({
					order: async () => ({ data: [{ id: "q1", category: "values", allow_multiple: false, sort_order: 1 }], error: null }),
				}),
			};
		},
	});
}

function installReflectionClient() {
	const rpc = vi.fn(async (name: string) => {
		if (name !== "get_meetup_reflection_state") throw new Error(`unexpected RPC: ${name}`);
		return {
			data: { outcome: "ok", current_version: 0, traits: {}, confirmed_at: null },
			error: null,
		};
	});
	gateState.getSupabaseClient.mockReturnValue({ rpc });
	return rpc;
}


function installProfileConfirmationClient() {
	type Trace = { table: string; operation: "read" | "update"; filters: Array<[string, unknown]>; columns?: string };
	const traces: Trace[] = [];
	const updates: Array<{ table: string; payload: Record<string, unknown>; filters: Array<[string, unknown]> }> = [];
	const client = {
		from(table: string) {
			const trace: Trace = { table, operation: "read", filters: [] };
			traces.push(trace);
			const query: Record<string, unknown> = {};
			query.select = (columns?: string) => { trace.columns = columns; return query; };
			query.eq = (column: string, value: unknown) => { trace.filters.push([column, value]); return query; };
			query.maybeSingle = async () => ({
				data: table === "personas" ? { id: "44444444-4444-4444-8444-444444444444" } : { preference_mode: "selected" },
				error: null,
			});
			query.update = (payload: Record<string, unknown>) => {
				trace.operation = "update";
				updates.push({ table, payload, filters: trace.filters.slice() });
				return query;
			};
			query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) =>
				Promise.resolve({ data: null, error: null }).then(resolve, reject);
			return query;
		},
	};
	gateState.getSupabaseClient.mockReturnValue(client);
	return { traces, updates };
}

async function request(path: string, init: RequestInit = {}, env?: Record<string, string | undefined>) {
	return env === undefined ? app.request(path, init) : app.request(path, init, env);
}

beforeEach(() => {
	gateState.resolveAuthUser.mockReset();
	gateState.getSupabaseClient.mockReset();
	gateState.routeUserId = PROFILE_ID;
	gateState.executeMatching.mockReset();
	gateState.executeMatching.mockResolvedValue(0);
	vi.useRealTimers();
});

afterEach(() => {
	vi.useRealTimers();
});

describe("production E2E gate wiring and route scope", () => {
	it("is mounted before the first app route and exposes the reviewed native route list", () => {
		const gateMount = APP_SOURCE.indexOf('app.use("*", productionE2EGate)');
		const firstRoute = APP_SOURCE.indexOf('app.get("/api/hello"');
		expect(gateMount).toBeGreaterThanOrEqual(0);
		expect(firstRoute).toBeGreaterThan(gateMount);
		expect(PRODUCTION_E2E_ALLOWED_ROUTES).toEqual([
			{ method: "GET", path: "/api/auth/me" },
			{ method: "POST", path: "/api/auth/me/photo" },
			{ method: "GET", path: "/api/billing/identity" },
			{ method: "GET", path: "/api/billing/status" },
			{ method: "GET", path: "/api/auth/me/onboarding-settings" },
			{ method: "PUT", path: "/api/auth/me/onboarding-settings" },
			{ method: "GET", path: "/api/auth/me/onboarding-options" },
			{ method: "PUT", path: "/api/auth/me/age-verification" },
			{ method: "GET", path: "/api/quiz/questions" },
			{ method: "GET", path: "/api/quiz/answers" },
			{ method: "POST", path: "/api/quiz/answers" },
			{ method: "GET", path: "/api/profiles/me" },
			{ method: "POST", path: "/api/profiles/generate" },
			{ method: "POST", path: "/api/personas/wingfox/generate" },
			{ method: "POST", path: "/api/profiles/me/confirm" },
			{ method: "GET", path: "/api/profiles/me/generation-state" },
			{ method: "GET", path: "/api/speed-dating/personas" },
			{ method: "POST", path: "/api/speed-dating/personas" },
			{ method: "POST", path: "/api/speed-dating/sessions" },
			{ method: "GET", path: "/api/speed-dating/sessions/:id" },
			{ method: "GET", path: "/api/speed-dating/sessions/:id/native-bootstrap" },
			{ method: "POST", path: "/api/speed-dating/sessions/:id/realtime-bootstrap" },
			{ method: "POST", path: "/api/speed-dating/sessions/:id/complete" },
			{ method: "GET", path: "/api/matching/daily-results" },
		]);
	});

	it.each([
    {env: activeEnv({PRODUCTION_E2E_READ_ONLY:"true"}), status:403},
    {env: activeEnv({PRODUCTION_E2E_EXPIRES_AT:"2020-01-01T00:00:00Z"}), status:503},
    {env: activeEnv(), status:401},
  ])("protects Realtime bootstrap under the existing window", async ({env, status}) => {
    const result = await request(`/api/speed-dating/sessions/${PROFILE_ID}/realtime-bootstrap`, {method:"POST"}, env);
    expect(result.status).toBe(status);
    expect(gateState.getSupabaseClient).not.toHaveBeenCalled();
  });

	it("keeps existing behavior when both gate bindings are absent", async () => {
		const hello = await request("/api/hello", {});
		expect(hello.status).toBe(200);

		const internal = await request(
			"/api/internal/daily-batch/status",
			{ method: "GET" },
			{ INTERNAL_API_TOKEN: "configured-secret" },
		);
		expect(internal.status).toBe(401);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});

	it.each([
		{ name: "malformed profile IDs", env: activeEnv({ PRODUCTION_E2E_PROFILE_IDS: "not-a-uuid" }) },
		{ name: "empty profile IDs", env: activeEnv({ PRODUCTION_E2E_PROFILE_IDS: "" }) },
		{ name: "more than three profile IDs", env: activeEnv({ PRODUCTION_E2E_PROFILE_IDS: `${PROFILE_ID},${OTHER_PROFILE_ID},33333333-3333-4333-8333-333333333333,44444444-4444-4444-8444-444444444444` }) },
		{ name: "empty ID between commas", env: activeEnv({ PRODUCTION_E2E_PROFILE_IDS: `${PROFILE_ID},` }) },
		{ name: "missing expiry", env: { PRODUCTION_E2E_PROFILE_IDS: PROFILE_ID } },
		{ name: "malformed expiry", env: activeEnv({ PRODUCTION_E2E_EXPIRES_AT: "2026-09-09T00:00:00+09:00" }) },
		{ name: "normalized invalid calendar date", env: activeEnv({ PRODUCTION_E2E_EXPIRES_AT: "2026-02-30T00:00:00Z" }) },
		{ name: "non-canonical fractional seconds", env: activeEnv({ PRODUCTION_E2E_EXPIRES_AT: "2099-01-01T00:00:00.00Z" }) },
		{ name: "malformed read-only flag", env: activeEnv({ PRODUCTION_E2E_READ_ONLY: "yes" }) },
		{ name: "read-only flag without gate bindings", env: { PRODUCTION_E2E_READ_ONLY: "true" } },
	])("fails closed with 503 for $name without attempting auth", async ({ env }) => {
		const response = await request("/api/quiz/questions", { method: "GET" }, env);
		expect(response.status).toBe(503);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
		expect(await response.text()).not.toContain(PROFILE_ID);
	});

	it("fails closed with 503 after expiry without attempting auth", async () => {
		const response = await request(
			"/api/quiz/questions",
			{ method: "GET", headers: { Authorization: "Bearer forged.jwt.value" } },
			activeEnv({ PRODUCTION_E2E_EXPIRES_AT: "2020-01-01T00:00:00Z" }),
		);
		expect(response.status).toBe(503);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});

	it("rejects a forged or invalid token with generic 401", async () => {
		gateState.resolveAuthUser.mockResolvedValue(null);

		const response = await request(
			"/api/quiz/questions",
			{ method: "GET", headers: { Authorization: "Bearer forged.jwt.value" } },
			activeEnv(),
		);
		expect(response.status).toBe(401);
		expect(await response.text()).not.toContain(PROFILE_ID);
	});

	it("rejects a verified but non-allowlisted profile with generic 403", async () => {
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-other", userId: OTHER_PROFILE_ID });

		const response = await request(
			"/api/quiz/questions",
			{ method: "GET", headers: { Authorization: "Bearer verified-but-other" } },
			activeEnv(),
		);
		expect(response.status).toBe(403);
		expect(await response.text()).not.toContain(OTHER_PROFILE_ID);
	});

	it.each([
		"/api/internal/daily-batch/status",
		"/api/webhooks/revenuecat",
		"/api/fox-search/ws/11111111-1111-4111-8111-111111111111",
		"/api/hello",
		"/api/quiz/questions/",
		"/api/%71uiz/questions",
		"/api/profiles/me/",
		"/api/profiles/me/edit",
		"/api/profiles/generate/",
		"/api/profiles/me/confirm/",
		"/api/personas/wingfox/generate/",
		"/api/personas/wingfox/generate/extra",
		"/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/native-bootstrap/",
	])("rejects forbidden path %s before resolving auth", async (path) => {
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-test", userId: PROFILE_ID });

		const response = await request(
			path,
			{ method: "GET", headers: { Authorization: "Bearer verified-allowlisted" } },
			activeEnv(),
		);
		expect(response.status).toBe(403);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});

	it.each([
		{ method: "POST", path: "/api/profiles/generate" },
		{ method: "POST", path: "/api/auth/me/photo" },
		{ method: "POST", path: "/api/personas/wingfox/generate" },
		{ method: "POST", path: "/api/profiles/me/confirm" },
		{ method: "POST", path: "/api/speed-dating/sessions" },
		{ method: "POST", path: "/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/complete" },
		{ method: "PUT", path: "/api/auth/me/onboarding-settings" },
		{ method: "GET", path: "/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/native-bootstrap" },
	])("rejects side-effect route $method $path in read-only mode before auth", async ({ method, path }) => {
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-test", userId: PROFILE_ID });

		const response = await request(
			path,
			{ method, headers: { Authorization: "Bearer verified-allowlisted" } },
			activeEnv({ PRODUCTION_E2E_READ_ONLY: "true" }),
		);
		expect(response.status).toBe(403);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});

	it("does not invoke the provider for native bootstrap in read-only mode", async () => {
		const fetchSpy = vi.spyOn(globalThis, "fetch");
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-test", userId: PROFILE_ID });

		const response = await request(
			"/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/native-bootstrap",
			{ method: "GET", headers: { Authorization: "Bearer verified-allowlisted" } },
			activeEnv({ PRODUCTION_E2E_READ_ONLY: "true" }),
		);

		expect(response.status).toBe(403);
		expect(fetchSpy).not.toHaveBeenCalled();
		fetchSpy.mockRestore();
	});

	it.each([
		"/api/profiles/me/generation-state",
		"/api/speed-dating/personas",
		"/api/auth/me/onboarding-settings",
		"/api/matching/daily-results",
	])("allows reviewed GET route %s in read-only mode", async (path) => {
		const probe = new Hono<Env>();
		probe.use("*", productionE2EGate);
		probe.all("*", (c) => c.json({ ok: true }));
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-test", userId: PROFILE_ID });

		const response = await probe.request(
			path,
			{ method: "GET", headers: { Authorization: "Bearer verified-allowlisted" } },
			activeEnv({ PRODUCTION_E2E_READ_ONLY: "true" }),
		);
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ ok: true });
	});

	it("lets an allowlisted request reach the existing quiz handler", async () => {
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-test", userId: PROFILE_ID });
		installQuizClient();

		const response = await request(
			"/api/quiz/questions",
			{ method: "GET", headers: { Authorization: "Bearer verified-allowlisted" } },
			activeEnv(),
		);
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: [{ id: "q1", category: "values", allow_multiple: false, sort_order: 1 }],
		});
		expect(gateState.resolveAuthUser).toHaveBeenCalledTimes(1);
		expect(gateState.getSupabaseClient).toHaveBeenCalledTimes(1);
	});

	it("denies a request whose auth verification crosses the expiry boundary", async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-09-09T00:00:00.500Z"));
		let release!: (value: { authUserId: string; userId: string }) => void;
		gateState.resolveAuthUser.mockImplementation(() => new Promise((resolve) => { release = resolve; }));
		installQuizClient();

		const pending = request(
			"/api/quiz/questions",
			{ method: "GET", headers: { Authorization: "Bearer slow-verification" } },
			activeEnv({ PRODUCTION_E2E_EXPIRES_AT: "2026-09-09T00:00:01.000Z" }),
		);
		await Promise.resolve();
		vi.setSystemTime(new Date("2026-09-09T00:00:01.001Z"));
		release({ authUserId: "auth-test", userId: PROFILE_ID });

		const response = await pending;
		expect(response.status).toBe(503);
		expect(gateState.getSupabaseClient).not.toHaveBeenCalled();
	});
});


describe("three-account production test scope", () => {
  const third = "33333333-3333-4333-8333-333333333333";
  const fourth = "44444444-4444-4444-8444-444444444444";
  it.each([PROFILE_ID, OTHER_PROFILE_ID, third, fourth])("checks the verified identity for %s", async (id) => {
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "synthetic-auth", userId: id });
    const harness = new Hono<Env>();
    harness.use("*", productionE2EGate);
    harness.get("/api/auth/me", (c) => c.json({ id: c.get("user_id") }));
    const response = await harness.request("/api/auth/me", {
      headers: { Authorization: "Bearer synthetic-test-token" },
    }, activeEnv({ PRODUCTION_E2E_PROFILE_IDS: [PROFILE_ID, OTHER_PROFILE_ID, third].join(",") }));
    expect(response.status).toBe(id === fourth ? 403 : 200);
    if (id !== fourth) expect(await response.json()).toEqual({ id });
  });
  it("still rejects duplicate profiles before authentication", async () => {
    const response = await request("/api/auth/me", {}, activeEnv({ PRODUCTION_E2E_PROFILE_IDS: [PROFILE_ID, OTHER_PROFILE_ID, PROFILE_ID].join(",") }));
    expect(response.status).toBe(503);
    expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
  });
});

describe("owner photo upload during the bounded test window", () => {
  it.each([
    { owner: PROFILE_ID, readOnly: "false", expiry: FUTURE_EXPIRY, path: "/api/auth/me/photo", status: 200 },
    { owner: OTHER_PROFILE_ID, readOnly: "false", expiry: FUTURE_EXPIRY, path: "/api/auth/me/photo", status: 403 },
    { owner: PROFILE_ID, readOnly: "true", expiry: FUTURE_EXPIRY, path: "/api/auth/me/photo", status: 403 },
    { owner: PROFILE_ID, readOnly: "false", expiry: "2020-01-01T00:00:00Z", path: "/api/auth/me/photo", status: 503 },
    { owner: PROFILE_ID, readOnly: "false", expiry: FUTURE_EXPIRY, path: "/api/auth/me/photo/extra", status: 403 },
  ])("permits only the authenticated owner and exact writable route: $status", async ({ owner, readOnly, expiry, path, status }) => {
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "synthetic-auth", userId: owner });
    const savePhoto = vi.fn();
    const harness = new Hono<Env>();
    harness.use("*", productionE2EGate);
    harness.post("/api/auth/me/photo", (c) => { savePhoto(c.get("user_id")); return c.json({ ok: true }); });
    const response = await harness.request(path, {
      method: "POST", headers: { Authorization: "Bearer synthetic-test-token", "Content-Type": "image/png" }, body: new Uint8Array([1]),
    }, activeEnv({ PRODUCTION_E2E_READ_ONLY: readOnly, PRODUCTION_E2E_EXPIRES_AT: expiry }));
    expect(response.status).toBe(status);
    if (status === 200) expect(savePhoto).toHaveBeenCalledWith(PROFILE_ID);
    else expect(savePhoto).not.toHaveBeenCalled();
  });
});


describe("test-store webhook authentication boundary", () => {
  it("routes only the exact POST through vendor authentication without accepting a user JWT", async () => {
    const response = await request("/api/webhooks/revenuecat", { method: "POST", body: "{}" }, activeEnv({ PRODUCTION_E2E_READ_ONLY: "false" }));
    expect(response.status).toBe(503); // Webhook credentials absent: route stays closed.
    expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
    expect(gateState.getSupabaseClient).not.toHaveBeenCalled();
  });
  it("rejects webhook writes during a read-only window", async () => {
    const response = await request("/api/webhooks/revenuecat", { method: "POST", body: "{}" }, activeEnv({ PRODUCTION_E2E_READ_ONLY: "true" }));
    expect(response.status).toBe(403);
    expect(gateState.getSupabaseClient).not.toHaveBeenCalled();
  });
});

describe("separate synthetic matching route scope", () => {
  const env = () => activeEnv({ PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS: SYNTHETIC_IDS.join(","), PRODUCTION_E2E_EXPIRES_AT: SYNTHETIC_MATCHING_EXPIRES_AT });
  it.each([
    { user: PROFILE_ID, path: "/api/matching/results", method: "GET", status: 403 },
    { user: SYNTHETIC_IDS[0], path: "/api/matching/results", method: "GET", status: 200 },
    { user: SYNTHETIC_IDS[0], path: `/api/matches/${PROFILE_ID}/fox-conversation`, method: "POST", status: 200 },
    { user: SYNTHETIC_IDS[0], path: "/api/meetups/intents", method: "POST", status: 403 },
    { user: SYNTHETIC_IDS[0], path: "/api/internal/matching/execute", method: "POST", status: 403 },
    { user: OTHER_PROFILE_ID, path: "/api/auth/me", method: "GET", status: 403 },
  ])("enforces synthetic-only routes: $method $path $status", async ({ user, path, method, status }) => {
    vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-22T09:00:00Z"));
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "test-auth", userId: user });
    const harness = new Hono<Env>(); harness.use("*", productionE2EGate);
    harness.all("*", c => c.json({ synthetic: c.get("production_e2e_synthetic") }));
    const response = await harness.request(path, { method, headers: { Authorization: "Bearer synthetic-token" } }, env());
    expect(response.status).toBe(status);
    if (status === 200) expect(await response.json()).toEqual({ synthetic: true });
  });
  it.each([
    { PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS: PROFILE_ID },
    { PRODUCTION_E2E_EXPIRES_AT: "2099-01-01T00:00:00Z" },
    { PRODUCTION_E2E_PROFILE_IDS: SYNTHETIC_IDS[0] },
  ])("rejects invalid registry or extension before authentication", async overrides => {
    const response = await request("/api/auth/me", {}, { ...env(), ...overrides });
    expect(response.status).toBe(503);
    expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
  });
});

describe("owner-requested Sora audio recording retake", () => {
  const sora = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";
  const recordingEnv = { PRODUCTION_E2E_RECORDING_WINDOW: "2026-09-22T12:00:00Z" };
  it.each([
    { user: sora, path: "/api/auth/me", method: "GET", status: 200 },
    { user: sora, path: "/api/speed-dating/personas", method: "GET", status: 200 },
    { user: sora, path: "/api/speed-dating/sessions", method: "POST", status: 200 },
    { user: sora, path: `/api/speed-dating/sessions/${PROFILE_ID}/complete`, method: "POST", status: 200 },
    { user: PROFILE_ID, path: "/api/auth/me", method: "GET", status: 403 },
    { user: SYNTHETIC_IDS[0], path: "/api/auth/me", method: "GET", status: 403 },
    { user: sora, path: "/api/matching/results", method: "GET", status: 403 },
    { user: sora, path: "/api/profiles/generate", method: "POST", status: 403 },
    { user: sora, path: "/api/webhooks/revenuecat", method: "POST", status: 403 },
  ])("restricts recording to one owner and voice routes: $method $path $status", async ({user,path,method,status}) => {
    vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-22T11:40:00Z"));
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "recording-auth", userId: user });
    const harness = new Hono<Env>(); harness.use("*", productionE2EGate); harness.all("*", c => c.json({ok:true}));
    expect((await harness.request(path, {method,headers:{Authorization:"Bearer test-token"}}, recordingEnv)).status).toBe(status);
  });
  it.each(["2026-09-22T12:00:00Z","2026-09-22T12:00:01Z"])("closes at the fixed deadline %s", async now => {
    vi.useFakeTimers(); vi.setSystemTime(new Date(now));
    expect((await request("/api/auth/me",{},recordingEnv)).status).toBe(503);
    expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
  });
  it("rejects attempts to extend the fixed recording deadline", async () => {
    expect((await request("/api/auth/me",{}, {PRODUCTION_E2E_RECORDING_WINDOW:"2099-01-01T00:00:00Z"})).status).toBe(503);
  });
});


describe("explicit recording rehearsal runtime gate", () => {
  const owner = "96b31c0a-b8c4-4536-ada2-f3537dadd146";
  const outsider = "22222222-2222-4222-8222-222222222222";
  const issuedAt = "2026-09-26T19:30:00.000Z";
  const expiresAt = "2026-09-26T21:30:00.000Z";
  const rehearsalEnv = (overrides: Record<string, string | undefined> = {}) => ({
    RECORDING_REHEARSAL_ENABLED: "enabled",
    RECORDING_REHEARSAL_ISSUED_AT: issuedAt,
    RECORDING_REHEARSAL_EXPIRES_AT: expiresAt,
    RECORDING_REHEARSAL_PAIR: "aoi-ren",
    ...overrides,
  });
  const atStart = () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-26T20:00:00.000Z"));
  };

  it("does not fall through to a valid legacy allowlist when any rehearsal field is present but incomplete", async () => {
    atStart();
    const response = await request("/api/auth/me", {
      headers: { Authorization: "Bearer verified-allowlisted" },
    }, activeEnv({ RECORDING_REHEARSAL_PAIR: "aoi-ren" }));
    expect(response.status).toBe(503);
    expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
  });

  it("rejects a verified account outside the exact registered cohort", async () => {
    atStart();
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-outsider", userId: outsider });
    const probe = new Hono<Env>();
    probe.use("*", productionE2EGate);
    probe.get("/api/auth/me", (c) => c.json({ id: c.get("user_id") }));
    const response = await probe.request("/api/auth/me", {
      headers: { Authorization: "Bearer verified-outsider" },
    }, rehearsalEnv());
    expect(response.status).toBe(403);
  });

  const roomId = "11111111-1111-4111-8111-111111111111";
  const messageId = "22222222-2222-4222-8222-222222222222";
  it.each([
    ["GET", "/api/direct-chats"],
    ["GET", `/api/direct-chats/${roomId}/messages?limit=50`],
    ["POST", `/api/direct-chats/${roomId}/messages`],
    ["POST", `/api/direct-chats/${roomId}/messages/send-recovery`],
    ["PUT", `/api/direct-chats/${roomId}/messages/${messageId}/read`],
  ] as const)("allows the authenticated native direct-chat route %s %s", async (method, path) => {
    atStart();
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-owner", userId: owner });
    const probe = new Hono<Env>();
    probe.use("*", productionE2EGate);
    probe.all("*", (c) => c.json({ userId: c.get("user_id"), pair: c.get("recording_rehearsal")?.pair }));
    const headers: Record<string, string> = { Authorization: "Bearer verified-owner" };
    const init: RequestInit = { method, headers };
    if (method === "POST") {
      headers["Content-Type"] = "application/json";
      init.body = "{}";
    }
    const response = await probe.request(path, init, rehearsalEnv());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ userId: owner, pair: "aoi-ren" });
  });

  it.each([
    ["GET", `/api/direct-chats/not-a-uuid/messages`],
    ["POST", `/api/direct-chats/${roomId}/messages/send-recovery/extra`],
    ["PUT", `/api/direct-chats/${roomId}/messages/${messageId}/read/extra`],
    ["PUT", `/api/direct-chats/${roomId}/messages/invalid/read`],
  ] as const)("denies malformed UUID or escaped direct-chat path %s %s before auth", async (method, path) => {
    atStart();
    const response = await request(path, {
      method,
      headers: { Authorization: "Bearer verified-allowlisted" },
    }, rehearsalEnv());
    expect(response.status).toBe(403);
    expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
  });

  it.each([
    ["GET", "/api/chat-meetups/rooms/not-a-uuid"],
    ["GET", "/api/chat-meetups/rooms/11111111-1111-4111-8111-111111111111/ward-conversation/extra"],
    ["GET", "/api/meetup-reflections/11111111-1111-4111-8111-111111111111/drafts"],
  ] as const)("rejects malformed or escaped native subroute %s %s before auth", async (method, path) => {
    atStart();
    const response = await request(path, {
      method,
      headers: { Authorization: "Bearer verified-allowlisted" },
    }, rehearsalEnv());
    expect(response.status).toBe(403);
    expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
  });

  it.each([
    ["GET", "/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/native-bootstrap"],
    ["POST", "/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/realtime-bootstrap"],
  ] as const)("does not allow paid provider bootstrap %s %s in rehearsal", async (method, path) => {
    atStart();
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const response = await request(path, {
      method,
      headers: { Authorization: "Bearer verified-allowlisted" },
    }, rehearsalEnv());
    expect(response.status).toBe(403);
    expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });

  it("confirms a selected rehearsal profile through the mounted gate without reading or changing saved preferences", async () => {
    atStart();
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-owner", userId: owner });
    gateState.routeUserId = owner;
    const supabase = installProfileConfirmationClient();
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    try {
      const response = await request("/api/profiles/me/confirm", {
        method: "POST",
        headers: { Authorization: "Bearer verified-owner" },
      }, rehearsalEnv());
      expect(response.status).toBe(200);
      expect(response.headers.get("cache-control")).toContain("no-store");
      expect(gateState.resolveAuthUser).toHaveBeenCalledTimes(1);
      expect(gateState.getSupabaseClient).toHaveBeenCalledTimes(1);
      expect(supabase.traces).not.toContainEqual(expect.objectContaining({
        table: "user_profiles",
        operation: "read",
        columns: "preference_mode",
      }));
      expect(supabase.updates.map(({ table }) => table)).toEqual(["profiles", "user_profiles"]);
      expect(supabase.updates.map(({ payload }) => payload)).not.toContainEqual(expect.objectContaining({ preference_mode: expect.anything() }));
      expect(gateState.executeMatching).not.toHaveBeenCalled();
      expect(fetchSpy).not.toHaveBeenCalled();
    } finally {
      fetchSpy.mockRestore();
    }
  });

  it("lets the selected rehearsal actor reach the reflection handler but keeps provider bootstrap disabled", async () => {
    atStart();
    const owner = "96b31c0a-b8c4-4536-ada2-f3537dadd146";
    const meetupId = "11111111-1111-4111-8111-111111111111";
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-owner", userId: owner });
    gateState.routeUserId = owner;
    const rpc = installReflectionClient();
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    try {
      const response = await request(`/api/meetup-reflections/${meetupId}/bootstrap`, {
        method: "POST",
        headers: { Authorization: "Bearer verified-owner", "Content-Type": "application/json" },
        body: JSON.stringify({ voice: "cedar" }),
      }, rehearsalEnv({ CHAT_MEETUP_ENABLED: "enabled", MEETUP_REFLECTION_REALTIME_ENABLED: "disabled" }));
      expect(response.status).toBe(503);
      expect(response.headers.get("cache-control")).toBe("private, no-store");
      expect(gateState.resolveAuthUser).toHaveBeenCalledTimes(1);
      expect(gateState.getSupabaseClient).toHaveBeenCalledTimes(1);
      expect(rpc).toHaveBeenCalledWith("get_meetup_reflection_state", {
        p_meetup_id: meetupId,
        p_user_id: owner,
      });
      expect(fetchSpy).not.toHaveBeenCalled();
    } finally {
      fetchSpy.mockRestore();
    }
  });

  it.each([
    { name: "missing bearer", authorization: undefined, resolved: undefined, status: 401 },
    { name: "verified outsider", authorization: "Bearer verified-outsider", resolved: { authUserId: "auth-outsider", userId: "22222222-2222-4222-8222-222222222222" }, status: 403 },
  ])("denies $name before the reflection handler", async ({ authorization, resolved, status }) => {
    atStart();
    if (resolved) gateState.resolveAuthUser.mockResolvedValue(resolved);
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (authorization) headers.Authorization = authorization;
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    try {
      const response = await request("/api/meetup-reflections/11111111-1111-4111-8111-111111111111/bootstrap", {
        method: "POST",
        headers,
        body: JSON.stringify({ voice: "cedar" }),
      }, rehearsalEnv({ CHAT_MEETUP_ENABLED: "enabled", MEETUP_REFLECTION_REALTIME_ENABLED: "enabled" }));
      expect(response.status).toBe(status);
      expect(gateState.getSupabaseClient).not.toHaveBeenCalled();
      expect(fetchSpy).not.toHaveBeenCalled();
      if (authorization) expect(gateState.resolveAuthUser).toHaveBeenCalledTimes(1);
      else expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
    } finally {
      fetchSpy.mockRestore();
    }
  });

  it("does not accept rehearsal configuration from request headers or JSON", async () => {
    atStart();
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-owner", userId: owner });
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    try {
      const response = await request("/api/meetup-reflections/11111111-1111-4111-8111-111111111111/bootstrap", {
        method: "POST",
        headers: {
          Authorization: "Bearer verified-owner",
          "Content-Type": "application/json",
          "X-Recording-Rehearsal-Enabled": "enabled",
          "X-Recording-Rehearsal-Issued-At": issuedAt,
          "X-Recording-Rehearsal-Expires-At": expiresAt,
          "X-Recording-Rehearsal-Pair": "aoi-ren",
        },
        body: JSON.stringify({
          voice: "cedar",
          RECORDING_REHEARSAL_ENABLED: "enabled",
          RECORDING_REHEARSAL_ISSUED_AT: issuedAt,
          RECORDING_REHEARSAL_EXPIRES_AT: expiresAt,
          RECORDING_REHEARSAL_PAIR: "aoi-ren",
        }),
      }, activeEnv({ CHAT_MEETUP_ENABLED: "enabled", MEETUP_REFLECTION_REALTIME_ENABLED: "enabled" }));
      expect(response.status).toBe(403);
      expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
      expect(gateState.getSupabaseClient).not.toHaveBeenCalled();
      expect(fetchSpy).not.toHaveBeenCalled();
    } finally {
      fetchSpy.mockRestore();
    }
  });

  it("keeps the verified profile ID immutable when the body names a different profile", async () => {
    atStart();
    gateState.resolveAuthUser.mockResolvedValue({ authUserId: "auth-owner", userId: owner });
    const probe = new Hono<Env>();
    probe.use("*", productionE2EGate);
    probe.post("/api/chat-requests", async (c) => {
      const body = await c.req.json<{ profile_id?: string }>();
      return c.json({ authenticatedProfileId: c.get("user_id"), requestedProfileId: body.profile_id });
    });
    const response = await probe.request("/api/chat-requests", {
      method: "POST",
      headers: { Authorization: "Bearer verified-owner", "Content-Type": "application/json" },
      body: JSON.stringify({ profile_id: outsider }),
    }, rehearsalEnv());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ authenticatedProfileId: owner, requestedProfileId: outsider });
  });

  it("closes when authentication crosses the rehearsal expiry boundary", async () => {
    atStart();
    vi.setSystemTime(new Date("2026-09-26T21:29:59.500Z"));
    let release!: (value: { authUserId: string; userId: string }) => void;
    gateState.resolveAuthUser.mockImplementation(() => new Promise((resolve) => { release = resolve; }));
    const probe = new Hono<Env>();
    probe.use("*", productionE2EGate);
    probe.get("/api/auth/me", (c) => c.json({ id: c.get("user_id") }));
    const pending = probe.request("/api/auth/me", {
      headers: { Authorization: "Bearer slow-verification" },
    }, rehearsalEnv({ RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T21:30:00.000Z" }));
    await Promise.resolve();
    vi.setSystemTime(new Date("2026-09-26T21:30:00.001Z"));
    release({ authUserId: "auth-owner", userId: owner });
    const response = await pending;
    expect(response.status).toBe(503);
  });
});

describe("Sora third-interview exception inside a read-only rehearsal", () => {
	const sora = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";
	const sessionId = "33333333-3333-4333-8333-333333333333";
	const soraInterviewEnv = (overrides: Record<string, string | undefined> = {}) => ({
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: "2026-09-26T19:30:00.000Z",
		RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T21:30:00.000Z",
		RECORDING_REHEARSAL_PAIR: "sora-ren",
		RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "enabled",
		RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: "2026-09-26T20:00:00.000Z",
		RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-26T20:30:00.000Z",
		PRODUCTION_E2E_READ_ONLY: "true",
		...overrides,
	});
	const atStart = () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-09-26T20:00:00.000Z"));
	};

	it.each([
		["/api/speed-dating/sessions", "{}"],
		[`/api/speed-dating/sessions/${sessionId}/realtime-bootstrap`, "{\"voice\":\"cedar\"}"],
		[`/api/speed-dating/sessions/${sessionId}/complete`, "{\"transcript\":[{\"source\":\"user\",\"message\":\"synthetic\"}]}"] ,
	] as const)("passes only Sora's admitted interview write %s", async (path, body) => {
		atStart();
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "sora-auth", userId: sora });
		const probe = new Hono<Env>();
		probe.use("*", productionE2EGate);
		probe.all("*", (c) => c.json({ userId: c.get("user_id"), readOnly: c.get("production_e2e_read_only") }));
		const response = await probe.request(path, {
			method: "POST",
			headers: { Authorization: "Bearer sora-token", "Content-Type": "application/json" },
			body,
		}, soraInterviewEnv());
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ userId: sora, readOnly: true });
	});

	it.each([OTHER_PROFILE_ID, SYNTHETIC_IDS[0]])("rejects other registered profiles from Sora interview writes", async userId => {
		atStart();
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "other-auth", userId });
		const probe = new Hono<Env>();
		probe.use("*", productionE2EGate);
		probe.post(`/api/speed-dating/sessions/${sessionId}/complete`, (c) => c.json({ ok: true }));
		const response = await probe.request(`/api/speed-dating/sessions/${sessionId}/complete`, {
			method: "POST", headers: { Authorization: "Bearer other-token" }, body: "{}",
		}, soraInterviewEnv());
		expect(response.status).toBe(403);
	});

	it.each([
		{ label: "missing admission bindings", env: { ...soraInterviewEnv(), RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: undefined } },
		{ label: "writable mode", env: soraInterviewEnv({ PRODUCTION_E2E_READ_ONLY: "false" }) },
	])("keeps the exception closed for $label", async ({ env }) => {
		atStart();
		const response = await request(`/api/speed-dating/sessions/${sessionId}/complete`, {
			method: "POST", headers: { Authorization: "Bearer sora-token" }, body: "{}",
		}, env);
		expect(response.status).toBe(503);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});

	it.each(["/api/profiles/generate", "/api/recording-rehearsal/matching/start", "/api/speed-dating/sessions/not-a-uuid/complete"]) (
		"does not widen the Sora exception to %s", async path => {
			atStart();
			const response = await request(path, {
				method: "POST", headers: { Authorization: "Bearer sora-token" }, body: "{}",
			}, soraInterviewEnv());
			expect(response.status).toBe(403);
			expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
		},
	);

	it("closes the exception at the interview subwindow deadline", async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-09-26T20:30:00.000Z"));
		const response = await request(`/api/speed-dating/sessions/${sessionId}/complete`, {
			method: "POST", headers: { Authorization: "Bearer sora-token" }, body: "{}",
		}, soraInterviewEnv());
		expect(response.status).toBe(503);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});

	it("allows the separate writable parent window after the explicit Sora tombstone", async () => {
		atStart();
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "sora-auth", userId: sora });
		const probe = new Hono<Env>();
		probe.use("*", productionE2EGate);
		probe.post("/api/profiles/me/confirm", (c) => c.json({ userId: c.get("user_id"), readOnly: c.get("production_e2e_read_only") }));
		const response = await probe.request("/api/profiles/me/confirm", {
			method: "POST",
			headers: { Authorization: "Bearer sora-token" },
		}, soraInterviewEnv({
			RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled",
			PRODUCTION_E2E_READ_ONLY: "false",
		}));
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ userId: sora, readOnly: false });

		const blocked = await probe.request(`/api/speed-dating/sessions/${sessionId}/complete`, {
			method: "POST",
			headers: { Authorization: "Bearer sora-token" },
			body: "{}",
		}, soraInterviewEnv({
			RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled",
			PRODUCTION_E2E_READ_ONLY: "false",
		}));
		expect(blocked.status).toBe(403);
	});
});

describe("Sora/Ren owner preparation window", () => {
	const sora = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";
	const ren = "9d836fee-7b93-41ce-b577-34a63006aaea";
	const admissionId = "33333333-3333-4333-8333-333333333333";
	const env = (overrides: Record<string, string | undefined> = {}) => ({
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: "2026-09-26T19:30:00.000Z",
		RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T21:30:00.000Z",
		RECORDING_REHEARSAL_PAIR: "sora-ren",
		RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled",
		RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: "2026-09-26T20:00:00.000Z",
		RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-26T20:30:00.000Z",
		RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enabled",
		PRODUCTION_E2E_READ_ONLY: "false",
		...overrides,
	});
	const atWindowStart = () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-09-26T20:05:00.000Z"));
	};
	const probe = () => {
		const app = new Hono<Env>();
		app.use("*", productionE2EGate);
		app.all("*", (c) => c.json({ userId: c.get("user_id"), readOnly: c.get("production_e2e_read_only") }));
		return app;
	};

	it.each([
		{ method: "GET", path: "/api/profiles/me", actor: sora },
		{ method: "GET", path: "/api/profiles/me/generation-state", actor: sora },
		{ method: "GET", path: "/api/auth/me/onboarding-settings", actor: ren },
		{ method: "GET", path: "/api/matching/results", actor: ren },
		{ method: "PUT", path: "/api/auth/me/onboarding-settings", actor: sora },
		{ method: "PUT", path: "/api/auth/me/onboarding-settings", actor: ren },
		{ method: "POST", path: "/api/profiles/me/confirm", actor: sora },
		{ method: "POST", path: "/api/recording-rehearsal/matching/preview", actor: ren },
	])("allows only reviewed owner preparation operation $method $path for $actor", async ({ method, path, actor }) => {
		atWindowStart();
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "owner-auth", userId: actor });
		const response = await probe().request(path, {
			method,
			headers: { Authorization: "Bearer owner-token" },
		}, env());
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ userId: actor, readOnly: path === "/api/profiles/me" });
	});

	it.each([
		["POST", "/api/profiles/generate"],
		["POST", "/api/personas/wingfox/generate"],
		["POST", "/api/recording-rehearsal/matching/start"],
		["POST", `/api/speed-dating/sessions/${admissionId}/realtime-bootstrap`],
		["POST", `/api/speed-dating/sessions/${admissionId}/complete`],
		["GET", `/api/speed-dating/sessions/${admissionId}/native-bootstrap`],
		["POST", "/api/chat-requests"],
		["POST", `/api/meetup-reflections/${admissionId}/bootstrap`],
	] as const)("rejects provider, matching, and Chat operation %s %s before auth", async (method, path) => {
		atWindowStart();
		const response = await probe().request(path, { method, headers: { Authorization: "Bearer owner-token" } }, env());
		expect(response.status).toBe(403);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});

	it.each([
		{ actor: SYNTHETIC_IDS[0], method: "GET", path: "/api/auth/me" },
		{ actor: SYNTHETIC_IDS[0], method: "PUT", path: "/api/auth/me/onboarding-settings" },
		{ actor: ren, method: "POST", path: "/api/profiles/me/confirm" },
	])("keeps Aoi out and reserves draft confirmation for Sora", async ({ actor, method, path }) => {
		atWindowStart();
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "owner-auth", userId: actor });
		const response = await probe().request(path, { method, headers: { Authorization: "Bearer owner-token" } }, env());
		expect(response.status).toBe(403);
	});

	it.each([
		{ name: "missing Sora tombstone", override: { RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: undefined } },
		{ name: "active Sora interview", override: { RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "enabled" } },
		{ name: "read-only conflict", override: { PRODUCTION_E2E_READ_ONLY: "true" } },
		{ name: "malformed owner-prep flag", override: { RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enable" } },
	])("fails closed for $name", async ({ override }) => {
		atWindowStart();
		const response = await probe().request("/api/auth/me", {}, env(override));
		expect(response.status).toBe(503);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});

	it("expires at the parent deadline", async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-09-26T21:30:00.000Z"));
		const response = await probe().request("/api/auth/me", {}, env());
		expect(response.status).toBe(503);
	});

	it("requires an explicit disabled flag before the later full recording window", async () => {
		atWindowStart();
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "sora-auth", userId: sora });
		const response = await probe().request("/api/recording-rehearsal/matching/start", {
			method: "POST",
			headers: { Authorization: "Bearer sora-token" },
		}, env({ RECORDING_REHEARSAL_OWNER_PREP_ONLY: "disabled" }));
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ userId: sora, readOnly: false });
	});
});


describe("Maya/Ren recording gate", () => {
	const maya = "a88a89e2-5421-5ce9-a33b-76d512898c37";
	const ren = SYNTHETIC_IDS[1];
	const id = "33333333-3333-4333-8333-333333333333";
	const env = (overrides: Record<string, string | undefined> = {}) => ({
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: "2026-09-30T02:20:00.000Z",
		RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-30T04:20:00.000Z",
		RECORDING_REHEARSAL_PAIR: "demo-maya-ren",
		RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enabled", ...overrides,
	});
	function probe(actor = maya) {
		vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-30T02:25:00.000Z"));
		gateState.resolveAuthUser.mockResolvedValue({ authUserId: "synthetic-auth", userId: actor });
		const app = new Hono<Env>(); app.use("*", productionE2EGate);
		app.all("*", (c) => c.json({ userId: c.get("user_id"), readOnly: c.get("production_e2e_read_only") }));
		return app;
	}
	it.each([maya, ren])("allows ordinary settings and nonwriting preview for %s", async (actor) => {
		const app = probe(actor);
		for (const [method, path] of [["PUT", "/api/auth/me/onboarding-settings"], ["POST", "/api/recording-rehearsal/matching/preview"]]) {
			expect((await app.request(path, { method, headers: { Authorization: "Bearer test" } }, env())).status).toBe(200);
		}
		expect(await (await app.request("/api/profiles/me", { headers: { Authorization: "Bearer test" } }, env())).json()).toEqual({ userId: actor, readOnly: true });
	});
	it.each([SYNTHETIC_IDS[0], SYNTHETIC_IDS[2], "e7c595cb-ff44-5611-aff1-44fb0ca8bf58"])("rejects other synthetic actors in both modes %s", async (actor) => {
		const app = probe(actor);
		for (const flag of ["enabled", "disabled"]) expect((await app.request("/api/auth/me", { headers: { Authorization: "Bearer test" } }, env({ RECORDING_REHEARSAL_OWNER_PREP_ONLY: flag }))).status).toBe(403);
	});
	it.each([
		"/api/recording-rehearsal/matching/start", "/api/chat-requests", `/api/direct-chats/${id}/messages`,
		`/api/chat-meetups/rooms/${id}/actions`, `/api/meetup-reflections/${id}/bootstrap`, `/api/meetup-reflections/${id}/drafts`,
		`/api/matches/${id}/fox-conversation`, "/api/profiles/generate", "/api/personas/wingfox/generate", "/api/speed-dating/sessions",
	])("blocks prep mutation %s before auth", async (path) => {
		const app = probe();
		expect((await app.request(path, { method: "POST", headers: { Authorization: "Bearer test" } }, env())).status).toBe(403);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});
	it("accepts complete expired disabled Sora tombstones without admitting interviews", async () => {
		const app = probe();
		const tombstone = env({
			RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled",
			RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: "2026-09-30T01:40:00Z",
			RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-30T02:10:00Z",
		});
		expect((await app.request("/api/auth/me", { headers: { Authorization: "Bearer test" } }, tombstone)).status).toBe(200);
		expect((await app.request("/api/speed-dating/sessions", { method: "POST", headers: { Authorization: "Bearer test" } }, tombstone)).status).toBe(403);
	});
	it("admits flow routes only in full mode", async () => {
		const app = probe();
		for (const path of ["/api/recording-rehearsal/matching/start", "/api/chat-requests", `/api/chat-meetups/rooms/${id}/actions`, `/api/meetup-reflections/${id}/bootstrap`]) expect((await app.request(path, { method: "POST", headers: { Authorization: "Bearer test" } }, env({ RECORDING_REHEARSAL_OWNER_PREP_ONLY: "disabled" }))).status).toBe(200);
	});
	it("keeps expired own reads available but refuses stale Sora permission, malformed prep or revision flags", async () => {
		const app = probe();
		expect((await app.request("/api/auth/me", { headers: { Authorization: "Bearer test" } }, env({ RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-30T02:25:00.000Z" }))).status).toBe(200);
		gateState.resolveAuthUser.mockClear();
		for (const override of [
			{ RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled" },
			{ RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enable" }, { RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED: "enabled" },
		]) expect((await app.request("/api/auth/me", { headers: { Authorization: "Bearer test" } }, env(override))).status).toBe(503);
		expect(gateState.resolveAuthUser).not.toHaveBeenCalled();
	});
});
