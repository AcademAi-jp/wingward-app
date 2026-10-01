import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
import { readRecordingRehearsalConfig, type ValidatedRecordingRehearsalConfig } from "../services/recording-rehearsal";

const OWNER_ID = vi.hoisted(() => "11111111-1111-4111-8111-111111111111");
const OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222";
const PROFILE_ID = "33333333-3333-4333-8333-333333333333";
const WINGFOX_ID = "44444444-4444-4444-8444-444444444444";
const SORA_ID = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", c.req.header("x-test-user") ?? OWNER_ID);
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import profiles from "./profiles";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

const EXPECTED_SECTIONS = [
	"core_identity",
	"communication_rules",
	"personality_profile",
	"interests",
	"values",
	"romance_style",
	"conversation_references",
	"constraints",
] as const;

type StateOptions = {
	owner?: unknown;
	ownerError?: unknown;
	profile?: unknown;
	profileError?: unknown;
	wingfox?: unknown;
	wingfoxError?: unknown;
	sections?: unknown;
	sectionsError?: unknown;
	sessions?: unknown;
	sessionsError?: unknown;
};

function makeSupabase(options: StateOptions = {}) {
	const owner = options.owner === undefined
		? { id: OWNER_ID, onboarding_status: "not_started" }
		: options.owner;
	const profile = options.profile === undefined
		? { id: PROFILE_ID, user_id: OWNER_ID, status: "draft" }
		: options.profile;
	const wingfox = options.wingfox === undefined
		? { id: WINGFOX_ID, user_id: OWNER_ID, persona_type: "wingfox" }
		: options.wingfox;
	const sections = options.sections === undefined
		? EXPECTED_SECTIONS.map((section_id) => ({ section_id, content: `content for ${section_id}` }))
		: options.sections;
	const tables: string[] = [];
	const operations: string[] = [];

	return {
		tables,
		operations,
		from(table: string) {
			tables.push(table);
			const query: Record<string, unknown> = {};
			for (const method of ["select", "eq", "maybeSingle"]) query[method] = () => query;
			query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => {
				operations.push(`${table}:read`);
				let result: unknown = { data: null, error: null };
				if (table === "user_profiles") result = { data: owner, error: options.ownerError ?? null };
				if (table === "profiles") result = { data: profile, error: options.profileError ?? null };
				if (table === "personas") result = { data: wingfox, error: options.wingfoxError ?? null };
				if (table === "persona_sections") result = { data: sections, error: options.sectionsError ?? null };
				if (table === "speed_dating_sessions") result = { data: options.sessions ?? [], error: options.sessionsError ?? null };
				return Promise.resolve(result).then(resolve, reject);
			};
			return query;
		},
	};
}

function buildApp(activeE2E = false, recordingConfig?: ValidatedRecordingRehearsalConfig) {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		if (activeE2E) c.set("production_e2e_active", true);
		if (recordingConfig) c.set("recording_rehearsal", recordingConfig);
		await next();
	});
	app.route("/api/profiles", profiles);
	return app;
}

async function readState(options: StateOptions = {}, activeE2E = false, bindings: Record<string, string> = {}, recordingConfig?: ValidatedRecordingRehearsalConfig) {
	const supabase = makeSupabase(options);
	mockedGetSupabaseClient.mockReturnValue(supabase as never);
	const response = await buildApp(activeE2E, recordingConfig).request("/api/profiles/me/generation-state", {
		headers: recordingConfig ? { "x-test-user": SORA_ID } : {},
	}, {
		SUPABASE_URL: "https://example.test",
		SUPABASE_SERVICE_ROLE_KEY: "test",
		...bindings,
	});
	return { response, supabase };
}

beforeEach(() => {
	vi.restoreAllMocks();
});

describe("GET /api/profiles/me/generation-state", () => {
	function soraRecordingConfig(): ValidatedRecordingRehearsalConfig {
		const now = Date.now();
		const parsed = readRecordingRehearsalConfig({
			RECORDING_REHEARSAL_ENABLED: "enabled",
			RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 60_000).toISOString(),
			RECORDING_REHEARSAL_EXPIRES_AT: new Date(now + 30 * 60_000).toISOString(),
			RECORDING_REHEARSAL_PAIR: "sora-ren",
		}, now);
		if (parsed.kind !== "active") throw new Error("Expected active recording configuration");
		return parsed.config;
	}

	function completedSessions(count: number) {
		return Array.from({ length: count }, (_, index) => ({
			id: `60000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
			user_id: SORA_ID,
			persona_id: `70000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
			status: "completed",
		}));
	}

	it("shows Sora's saved draft only after three distinct completed interviews", async () => {
		const config = soraRecordingConfig();
		const base = {
			owner: { id: SORA_ID, onboarding_status: "quiz_completed" },
			profile: { id: PROFILE_ID, user_id: SORA_ID, status: "draft" },
			wingfox: { id: WINGFOX_ID, user_id: SORA_ID, persona_type: "wingfox" },
		};
		const before = await readState({ ...base, sessions: completedSessions(2) }, true, {}, config);
		expect(before.response.status).toBe(200);
		expect(await before.response.json()).toMatchObject({ data: { profile_generated: false, wingfox_generated: false } });
		expect(before.supabase.tables).not.toContain("persona_sections");

		const after = await readState({
			...base,
			owner: { id: SORA_ID, onboarding_status: "speed_dating_completed" },
			sessions: completedSessions(3),
		}, true, {}, config);
		expect(after.response.status).toBe(200);
		expect(await after.response.json()).toMatchObject({ data: {
			profile_generated: true,
			wingfox_generated: true,
			profile_confirmed: false,
			required_interview_count: 3,
		} });
		expect(after.supabase.operations).not.toContain("profiles:update");
	});

	it("blocks profile regeneration for Sora during recording recovery before any provider or database call", async () => {
		const config = soraRecordingConfig();
		mockedGetSupabaseClient.mockClear();
		const response = await buildApp(true, config).request("/api/profiles/generate", {
			method: "POST",
			headers: { "x-test-user": SORA_ID },
		}, {
			SUPABASE_URL: "https://example.test",
			SUPABASE_SERVICE_ROLE_KEY: "test",
			MISTRAL_API_KEY: "synthetic-test-only",
		});
		expect(response.status).toBe(409);
		expect(mockedGetSupabaseClient).not.toHaveBeenCalled();
	});

	it("does not adopt a saved draft when three completions cover only two personas", async () => {
		const config = soraRecordingConfig();
		const sessions = completedSessions(3);
		sessions[2]!.persona_id = sessions[1]!.persona_id;
		const result = await readState({
			owner: { id: SORA_ID, onboarding_status: "speed_dating_completed" },
			profile: { id: PROFILE_ID, user_id: SORA_ID, status: "draft" },
			sessions,
		}, true, {}, config);
		expect(result.response.status).toBe(500);
	});
	it("returns false flags for an existing early onboarding state without reading persona data", async () => {
		const { response, supabase } = await readState({
			owner: { id: OWNER_ID, onboarding_status: "quiz_completed" },
			profile: null,
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				user_id: OWNER_ID,
				profile_generated: false,
				wingfox_generated: false,
				profile_confirmed: false,
				required_interview_count: 3,
				interview_waiver_active: false,
			},
		});
		expect(supabase.tables).toEqual(["user_profiles", "profiles"]);
		expect(supabase.tables).not.toContain("persona_sections");
		expect(supabase.operations).not.toContain("profiles:insert");
	});

	it("returns all false for a missing profile at the initial onboarding state", async () => {
		const { response } = await readState({
			owner: { id: OWNER_ID, onboarding_status: "not_started" },
			profile: null,
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				user_id: OWNER_ID,
				profile_generated: false,
				wingfox_generated: false,
				profile_confirmed: false,
				required_interview_count: 3,
				interview_waiver_active: false,
			},
		});
	});

	it.each([
		["profile_generated", { profile_generated: true, wingfox_generated: false, profile_confirmed: false }],
		["persona_generated", { profile_generated: true, wingfox_generated: true, profile_confirmed: false }],
		["confirmed", { profile_generated: true, wingfox_generated: true, profile_confirmed: true }],
	] as const)("reports the exact generated flags for %s", async (stage, expected) => {
		const { response } = await readState({
			owner: { id: OWNER_ID, onboarding_status: stage },
			profile: { id: PROFILE_ID, user_id: OWNER_ID, status: stage === "confirmed" ? "confirmed" : "draft" },
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				user_id: OWNER_ID,
				...expected,
				required_interview_count: 3,
				interview_waiver_active: false,
			},
		});
	});

	it("reports the temporary two-interview requirement only in the trusted exact-owner window", async () => {
		const { response } = await readState(
			{ owner: { id: OWNER_ID, onboarding_status: "quiz_completed" }, profile: null },
			true,
			{
				PROFILE_GENERATION_WAIVER_USER_ID: OWNER_ID,
				PROFILE_GENERATION_WAIVER_EXPIRES_AT: "2099-01-01T00:00:00.000Z",
			},
		);

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				user_id: OWNER_ID,
				profile_generated: false,
				wingfox_generated: false,
				profile_confirmed: false,
				required_interview_count: 2,
				interview_waiver_active: true,
			},
		});
	});

	it("requires all eight non-empty Wing Fox sections before reporting persona generation", async () => {
		const sections = EXPECTED_SECTIONS
			.filter((section_id) => section_id !== "constraints")
			.map((section_id) => ({ section_id, content: "present" }));
		const { response, supabase } = await readState({
			owner: { id: OWNER_ID, onboarding_status: "persona_generated" },
			sections,
		});

		expect(response.status).toBe(500);
		expect((await response.text())).not.toContain("present");
		expect(supabase.tables).toContain("persona_sections");
	});

	it.each([
		["late stage without profile", { owner: { id: OWNER_ID, onboarding_status: "persona_generated" }, profile: null }],
		["confirmed stage with draft profile", { owner: { id: OWNER_ID, onboarding_status: "confirmed" } }],
		["persona stage with missing Wing Fox", { owner: { id: OWNER_ID, onboarding_status: "persona_generated" }, wingfox: null }],
	] as const)("rejects inconsistent claimed state: %s", async (_name, options) => {
		const { response } = await readState(options);
		expect(response.status).toBe(500);
	});

	it.each([
		["owner", { ownerError: { message: "PWNED-CANARY-OWNER" } }],
		["profile", { profileError: { message: "PWNED-CANARY-PROFILE" } }],
		["Wing Fox", { wingfoxError: { message: "PWNED-CANARY-WINGFOX" }, owner: { id: OWNER_ID, onboarding_status: "persona_generated" } }],
		["sections", { sectionsError: { message: "PWNED-CANARY-SECTIONS" }, owner: { id: OWNER_ID, onboarding_status: "persona_generated" } }],
	] as const)("fails closed on %s query errors without exposing details", async (_name, options) => {
		const { response } = await readState(options);
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toMatch(/PWNED-CANARY/);
	});

	it("rejects malformed or cross-owner rows before reporting success", async () => {
		const malformed = await readState({
			owner: { id: OWNER_ID, onboarding_status: "profile_generated" },
			profile: { id: "not-a-uuid", user_id: OWNER_ID, status: "draft" },
		});
		expect(malformed.response.status).toBe(500);

		const crossOwner = await readState({
			owner: { id: OWNER_ID, onboarding_status: "profile_generated" },
			profile: { id: PROFILE_ID, user_id: OTHER_OWNER_ID, status: "draft" },
		});
		expect(crossOwner.response.status).toBe(500);
	});
});
