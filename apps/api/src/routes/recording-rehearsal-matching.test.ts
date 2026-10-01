import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Hono, type Context, type Next } from "hono";
import type { Env } from "../env";

/**
 * These route tests use the real production E2E gate and route, but controlled
 * auth, age, and matcher doubles. They verify trusted-context wiring and
 * fail-closed behavior; they do not test JWT signature verification.
 */
const routeState = vi.hoisted(() => ({
	resolveAuthUser: vi.fn(),
	getSupabaseClient: vi.fn(),
	runMatching: vi.fn(),
	resolvedUserId: null as string | null,
	ageStatus: "verified" as "verified" | "unverified" | "error",
}));

vi.mock("../middleware/auth", async () => {
	const actual = await vi.importActual<typeof import("../middleware/auth")>("../middleware/auth");
	return {
		...actual,
		resolveAuthUser: routeState.resolveAuthUser,
		requireAuth: async (c: Context<Env>, next: Next) => {
			const authorization = c.req.header("Authorization");
			if (!authorization?.startsWith("Bearer ") || authorization.length === 7) {
				return c.json({ error: { code: "UNAUTHORIZED", message: "Missing or invalid Authorization header" } }, 401);
			}
			const resolved = await routeState.resolveAuthUser(c, authorization.slice(7));
			if (!resolved) {
				return c.json({ error: { code: "UNAUTHORIZED", message: "Invalid or expired token" } }, 401);
			}
			c.set("auth_user_id", resolved.authUserId);
			c.set("user_id", resolved.userId);
			await next();
		},
		// A deterministic middleware double exercises the route's age boundary
		// without claiming that this suite verifies the profile lookup itself.
		requireAgeVerified: async (c: Context<Env>, next: Next) => {
			if (!c.get("user_id")) {
				return c.json({ error: { code: "INTERNAL_ERROR", message: "Age verification is unavailable" } }, 500);
			}
			if (routeState.ageStatus === "error") {
				return c.json({ error: { code: "INTERNAL_ERROR", message: "Failed to verify age status" } }, 500);
			}
			if (routeState.ageStatus !== "verified") {
				return c.json({ error: { code: "AGE_VERIFICATION_REQUIRED", message: "Age verification required" } }, 403);
			}
			await next();
		},
	};
});

vi.mock("../db/client", () => ({
	getSupabaseAuthClient: vi.fn(),
	getSupabaseClient: routeState.getSupabaseClient,
}));

vi.mock("../services/recording-rehearsal-matching", async () => {
	const actual = await vi.importActual<typeof import("../services/recording-rehearsal-matching")>("../services/recording-rehearsal-matching");
	return {
		...actual,
		runRecordingRehearsalMatching: routeState.runMatching,
	};
});

import { productionE2EGate } from "../middleware/production-e2e-gate";
import {
	RECORDING_REHEARSAL_GENERATION_PAIRS,
	RECORDING_REHEARSAL_PROFILE_IDS,
} from "../services/recording-rehearsal";
import recordingRehearsalMatching from "./recording-rehearsal-matching";

const NOW = Date.parse("2026-09-26T20:00:00.000Z");
const ISSUED_AT = "2026-09-26T19:30:00.000Z";
const EXPIRES_AT = "2026-09-26T21:30:00.000Z";
const SELECTED_PAIR = RECORDING_REHEARSAL_GENERATION_PAIRS["sora-ren"];
const OTHER_COHORT_MEMBER = RECORDING_REHEARSAL_PROFILE_IDS.find(
	(profileId) => !SELECTED_PAIR.includes(profileId as (typeof SELECTED_PAIR)[number]),
)!;
const OUTSIDER = "11111111-1111-4111-8111-111111111111";
const TEST_AUTH_USER = "synthetic-auth-user";
const TEST_TOKEN = "controlled-test-token";
const TEST_SUPABASE = { testOnly: true };

const app = new Hono<Env>();
app.use("*", productionE2EGate);
app.route("/api/recording-rehearsal", recordingRehearsalMatching);

function activeEnv(overrides: Record<string, string | undefined> = {}) {
	return {
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: ISSUED_AT,
		RECORDING_REHEARSAL_EXPIRES_AT: EXPIRES_AT,
		RECORDING_REHEARSAL_PAIR: "sora-ren",
		...overrides,
	};
}

function authenticateAs(profileId: string) {
	routeState.resolvedUserId = profileId;
	routeState.resolveAuthUser.mockResolvedValue({
		authUserId: TEST_AUTH_USER,
		userId: profileId,
	});
}

function expectPrivateNoStore(response: Response) {
	expect(response.headers.get("Cache-Control")).toBe("private, no-store");
}

async function request(
	path: string,
	init: RequestInit = {},
	env: Record<string, string | undefined> = activeEnv(),
) {
	return app.request(path, init, env as never);
}

beforeEach(() => {
	vi.useFakeTimers();
	vi.setSystemTime(NOW);
	routeState.resolveAuthUser.mockReset();
	routeState.getSupabaseClient.mockReset().mockReturnValue(TEST_SUPABASE);
	routeState.runMatching.mockReset().mockResolvedValue({ outcome: "eligible", count: 1 });
	routeState.resolvedUserId = null;
	routeState.ageStatus = "verified";
});

afterEach(() => {
	vi.useRealTimers();
});

describe("recording rehearsal matching route boundary", () => {
	it("returns the route's closed response when rehearsal configuration is absent", async () => {
		authenticateAs(SELECTED_PAIR[0]);
		const response = await request(
			"/api/recording-rehearsal/matching/preview",
			{ method: "POST", headers: { Authorization: `Bearer ${TEST_TOKEN}` } },
			{},
		);

		expect(response.status).toBe(503);
		expect(await response.json()).toEqual({ data: { outcome: "expired", count: 0 } });
		expectPrivateNoStore(response);
		expect(routeState.runMatching).not.toHaveBeenCalled();
		expect(routeState.getSupabaseClient).not.toHaveBeenCalled();
	});

	it.each([
		["partial configuration", { RECORDING_REHEARSAL_ENABLED: "enabled" }, NOW],
		["expired configuration", activeEnv(), Date.parse(EXPIRES_AT)],
	] as const)("rejects %s before auth or matching work", async (_label, env, now) => {
		vi.setSystemTime(now);
		const response = await request(
			"/api/recording-rehearsal/matching/start",
			{ method: "POST", headers: { Authorization: `Bearer ${TEST_TOKEN}` } },
			env,
		);

		expect(response.status).toBe(503);
		expect(routeState.resolveAuthUser).not.toHaveBeenCalled();
		expect(routeState.getSupabaseClient).not.toHaveBeenCalled();
		expect(routeState.runMatching).not.toHaveBeenCalled();
	});

	it("rejects malformed pair configuration before auth or matching work", async () => {
		const response = await request(
			"/api/recording-rehearsal/matching/start",
			{ method: "POST", headers: { Authorization: `Bearer ${TEST_TOKEN}` } },
			activeEnv({ RECORDING_REHEARSAL_PAIR: "aoi-sora" }),
		);

		expect(response.status).toBe(503);
		expect(routeState.resolveAuthUser).not.toHaveBeenCalled();
		expect(routeState.getSupabaseClient).not.toHaveBeenCalled();
		expect(routeState.runMatching).not.toHaveBeenCalled();
	});

	it("denies a missing bearer token before the matcher is reached", async () => {
		const response = await request(
			"/api/recording-rehearsal/matching/preview",
			{ method: "POST" },
			{},
		);

		expect(response.status).toBe(401);
		expect(await response.json()).toEqual({
			error: { code: "UNAUTHORIZED", message: "Missing or invalid Authorization header" },
		});
		expectPrivateNoStore(response);
		expect(routeState.resolveAuthUser).not.toHaveBeenCalled();
		expect(routeState.runMatching).not.toHaveBeenCalled();
	});

	it("denies an unverified actor before matching work", async () => {
		authenticateAs(SELECTED_PAIR[0]);
		routeState.ageStatus = "unverified";
		const response = await request("/api/recording-rehearsal/matching/preview", {
			method: "POST",
			headers: { Authorization: `Bearer ${TEST_TOKEN}` },
		});

		expect(response.status).toBe(403);
		expect(await response.json()).toEqual({
			error: { code: "AGE_VERIFICATION_REQUIRED", message: "Age verification required" },
		});
		expectPrivateNoStore(response);
		expect(routeState.resolveAuthUser).toHaveBeenCalledTimes(2);
		expect(routeState.getSupabaseClient).not.toHaveBeenCalled();
		expect(routeState.runMatching).not.toHaveBeenCalled();
	});

	it("does not run matching for GET requests", async () => {
		authenticateAs(SELECTED_PAIR[0]);
		const response = await request(
			"/api/recording-rehearsal/matching/preview",
			{ method: "GET", headers: { Authorization: `Bearer ${TEST_TOKEN}` } },
		);

		expect(response.status).toBe(403);
		expect(routeState.resolveAuthUser).not.toHaveBeenCalled();
		expect(routeState.getSupabaseClient).not.toHaveBeenCalled();
		expect(routeState.runMatching).not.toHaveBeenCalled();
	});

	it.each([
		{
			path: "/api/recording-rehearsal/matching/preview",
			mode: "preview",
			result: { outcome: "eligible", count: 1 },
			spoofMode: "start",
		},
		{
			path: "/api/recording-rehearsal/matching/start",
			mode: "start",
			result: { outcome: "started", count: 1 },
			spoofMode: "preview",
		},
	] as const)("passes trusted config, server actor, and endpoint mode for $mode", async ({ path, mode, result, spoofMode }) => {
		authenticateAs(SELECTED_PAIR[0]);
		routeState.runMatching.mockResolvedValueOnce(result);
		const response = await request(path, {
			method: "POST",
			headers: {
				Authorization: `Bearer ${TEST_TOKEN}`,
				"Content-Type": "application/json",
				"X-Profile-ID": OUTSIDER,
				"X-Actor-ID": OUTSIDER,
				"X-Recording-Rehearsal-Pair": "aoi-ren",
			},
			body: JSON.stringify({
				actor_id: OUTSIDER,
				profile_ids: [OUTSIDER],
				generation_pair: [OUTSIDER, SELECTED_PAIR[1]],
				pair: "aoi-ren",
				mode: spoofMode,
			}),
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: result });
		expectPrivateNoStore(response);
		expect(routeState.runMatching).toHaveBeenCalledOnce();
		const [supabase, config, actorId, actualMode] = routeState.runMatching.mock.calls[0];
		expect(supabase).toBe(TEST_SUPABASE);
		expect(config).toMatchObject({
			kind: "active",
			pair: "sora-ren",
			generationPair: SELECTED_PAIR,
			profileIds: RECORDING_REHEARSAL_PROFILE_IDS,
			issuedAt: ISSUED_AT,
			expiresAt: EXPIRES_AT,
			expiresAtMs: Date.parse(EXPIRES_AT),
		});
		expect(Object.isFrozen(config)).toBe(true);
		expect(actorId).toBe(SELECTED_PAIR[0]);
		expect(actualMode).toBe(mode);
	});

	it.each([
		["another cohort member", OTHER_COHORT_MEMBER],
		["a noncohort profile", OUTSIDER],
	] as const)("denies %s without exposing profile details or running matching", async (_label, profileId) => {
		authenticateAs(profileId);
		const response = await request("/api/recording-rehearsal/matching/preview", {
			method: "POST",
			headers: { Authorization: `Bearer ${TEST_TOKEN}` },
		});

		expect(response.status).toBe(403);
		const body = await response.text();
		expect(body).not.toContain(profileId);
		expect(body).not.toContain(SELECTED_PAIR[0]);
		expect(routeState.runMatching).not.toHaveBeenCalled();
	});

	it("maps a matcher no-profile result to the same generic response", async () => {
		authenticateAs(SELECTED_PAIR[0]);
		routeState.runMatching.mockResolvedValueOnce({ outcome: "not_selected_member", count: 0 });
		const response = await request("/api/recording-rehearsal/matching/start", {
			method: "POST",
			headers: { Authorization: `Bearer ${TEST_TOKEN}` },
		});

		expect(response.status).toBe(403);
		expect(await response.json()).toEqual({
			error: { code: "FORBIDDEN", message: "Matching rehearsal is unavailable" },
		});
		expectPrivateNoStore(response);
		expect(routeState.runMatching).toHaveBeenCalledOnce();
	});

	it("returns a safe no-store error when matching throws", async () => {
		authenticateAs(SELECTED_PAIR[0]);
		routeState.runMatching.mockRejectedValueOnce(new Error("synthetic matcher detail"));
		const response = await request("/api/recording-rehearsal/matching/start", {
			method: "POST",
			headers: { Authorization: `Bearer ${TEST_TOKEN}` },
		});

		expect(response.status).toBe(500);
		const body = await response.text();
		expect(body).toContain('"code":"INTERNAL_ERROR"');
		expect(body).toContain("Matching rehearsal could not be completed");
		expect(body).not.toContain("synthetic matcher detail");
		expectPrivateNoStore(response);
		expect(routeState.runMatching).toHaveBeenCalledOnce();
	});
});
