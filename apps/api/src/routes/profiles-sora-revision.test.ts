import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";

const mocks = vi.hoisted(() => ({
	boundedCall: vi.fn(),
	legacyChat: vi.fn(),
	prepareDna: vi.fn(),
	scoreDna: vi.fn(),
	legacyDna: vi.fn(),
	loadInputs: vi.fn(),
}));

const soraId = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";
const renId = "a4d629ef-9c8a-4e56-8496-42543c87eed3";
const sessionIds = [
	"20000000-0000-0000-0000-00000000d001",
	"20000000-0000-0000-0000-00000000d002",
	"20000000-0000-0000-0000-00000000d003",
];
const personaIds = [
	"11000000-0000-0000-0000-00000000d001",
	"11000000-0000-0000-0000-00000000d002",
	"11000000-0000-0000-0000-00000000d003",
];
const wingfoxId = "11000000-0000-0000-0000-00000000d004";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", soraId);
		await next();
	},
	resolveAuthUser: async (_c: import("hono").Context, bearer: string) => ({
		authUserId: `synthetic-auth-${bearer}`,
		userId: bearer === "ren" ? renId : soraId,
	}),
}));
vi.mock("../services/mistral", () => ({
	chatComplete: mocks.legacyChat,
	chatCompleteOnceBounded: mocks.boundedCall,
	MISTRAL_LARGE: "mistral-large-test",
}));
vi.mock("../services/interaction-dna", () => ({
	scoreInteractionDna: mocks.legacyDna,
	prepareInteractionDnaFromFrozenSessions: mocks.prepareDna,
	scorePreparedInteractionDna: mocks.scoreDna,
}));
vi.mock("../services/sora-profile-revision-inputs", () => ({
	loadSoraProfileRevisionInputs: mocks.loadInputs,
	SORA_PROFILE_REVISION_MAX_QUIZ_BYTES: 6_000,
	SORA_PROFILE_REVISION_MAX_TRANSCRIPT_BYTES: 16_000,
}));
vi.mock("../services/matching", () => ({ executeMatching: vi.fn(async () => 0) }));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import { chatCompleteOnceBounded, chatComplete } from "../services/mistral";
import { scoreInteractionDna, scorePreparedInteractionDna } from "../services/interaction-dna";
import { productionE2EGate } from "../middleware/production-e2e-gate";
import profiles from "./profiles";

type RpcOptions = { claimOutcomes?: string[]; revisionState?: string; completeOutcome?: string; afterClaim?: () => void };

function makeFakeSupabase(options: RpcOptions = {}) {
	const rpcCalls: Array<{ name: string; args: Record<string, unknown> }> = [];
	const writes: Array<{ table: string; method: string; value: unknown }> = [];
	const claimOutcomes = [...(options.claimOutcomes ?? ["claimed"])];
	const profileRow = {
		id: "30000000-0000-0000-0000-00000000d001",
		user_id: soraId,
		status: "draft",
		version: 8,
		basic_info: { sentinel: "old synthetic draft" },
		personality_tags: ["preserve until success"],
	};
	const revisedRow = { ...profileRow, version: 9, personality_tags: ["new synthetic profile"] };
	const completedSessions = sessionIds.map((id, index) => ({ id, user_id: soraId, persona_id: personaIds[index], status: "completed" }));
	const wingfox = { id: wingfoxId, user_id: soraId, persona_type: "wingfox" };
	const sections = ["core_identity", "communication_rules", "personality_profile", "interests", "values", "romance_style", "conversation_references", "constraints"]
		.map((section_id) => ({ section_id, content: `synthetic ${section_id}` }));

	const dataFor = (table: string, filters: Record<string, unknown>, selection: string) => {
		if (table === "profiles") return { data: selection === "*" ? revisedRow : profileRow, error: null };
		if (table === "user_profiles") return { data: { id: soraId, onboarding_status: "speed_dating_completed" }, error: null };
		if (table === "speed_dating_sessions") return { data: completedSessions, error: null };
		if (table === "personas") return { data: filters.persona_type === "wingfox" ? wingfox : null, error: null };
		if (table === "persona_sections") return { data: sections, error: null };
		throw new Error(`unexpected table in synthetic route test: ${table}`);
	};

	const client = {
		rpc: async (name: string, args: Record<string, unknown>) => {
			rpcCalls.push({ name, args });
			if (name === "claim_sora_three_interview_profile_revision") {
				const outcome = claimOutcomes.shift() ?? "already_claimed";
				options.afterClaim?.();
				return { data: [{ outcome, source_profile_id: profileRow.id, source_version: 8, session_ids: sessionIds }], error: null };
			}
			if (name === "complete_sora_three_interview_profile_revision") return { data: [{ outcome: options.completeOutcome ?? "saved", target_version: 9 }], error: null };
			if (name === "read_sora_three_interview_profile_revision_state") return { data: [{ outcome: options.revisionState ?? "available" }], error: null };
			throw new Error(`unexpected synthetic RPC: ${name}`);
		},
		from(table: string) {
			const filters: Record<string, unknown> = {};
			let selection = "*";
			const query: Record<string, unknown> = {};
			query.select = (columns = "*") => { selection = columns; return query; };
			query.eq = (column: string, value: unknown) => { filters[column] = value; return query; };
			query.order = () => query;
			query.limit = () => query;
			query.in = (column: string, value: unknown) => { filters[column] = value; return query; };
			query.maybeSingle = () => Promise.resolve(dataFor(table, filters, selection));
			query.single = () => Promise.resolve(dataFor(table, filters, selection));
			query.update = (value: unknown) => { writes.push({ table, method: "update", value }); return query; };
			query.upsert = (value: unknown) => { writes.push({ table, method: "upsert", value }); return query; };
			query.insert = (value: unknown) => { writes.push({ table, method: "insert", value }); return query; };
			query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) =>
				Promise.resolve(dataFor(table, filters, selection)).then(resolve, reject);
			return query;
		},
	};
	return { client, rpcCalls, writes, profileRow };
}

const fixedConfig = (() => {
	const now = Date.now();
	const issuedAt = new Date(now - 60_000).toISOString();
	const expiresAt = new Date(now + 90 * 60_000).toISOString();
	return {
		kind: "active" as const,
		issuedAt,
		expiresAt,
		issuedAtMs: now - 60_000,
		expiresAtMs: now + 90 * 60_000,
		soraInterviewIssuedAt: issuedAt,
		soraInterviewExpiresAt: new Date(now + 20 * 60_000).toISOString(),
		profileIds: [soraId, renId, "e95cbf04-5a5b-4b6b-b146-cbc948a8899b"] as [string, string, string],
		pair: "sora-ren" as const,
		generationPair: [soraId, renId] as [string, string],
	};
})();

function buildApp(config = fixedConfig, trustedDiagnostics = false) {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		c.set("recording_rehearsal", config as never);
		c.set("production_e2e_active", trustedDiagnostics);
		await next();
	});
	app.route("/api/profiles", profiles);
	return app;
}

function testEnv(config = fixedConfig, additional: Record<string, unknown> = {}) {
	return {
		MISTRAL_API_KEY: "synthetic-key",
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: config.issuedAt,
		RECORDING_REHEARSAL_EXPIRES_AT: config.expiresAt,
		RECORDING_REHEARSAL_PAIR: "sora-ren",
		RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled",
		RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: config.issuedAt,
		RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: config.soraInterviewExpiresAt,
		RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enabled",
		RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED: "enabled",
		...additional,
	};
}

function validProfileOutput() {
	return JSON.stringify({
		basic_info: { age_range: "25-29", location: "", occupation: "" },
		personality_tags: ["curious and open-minded", "warm once comfortable", "thoughtful listener"],
		personality_analysis: { introvert_extrovert: 0.5, planned_spontaneous: 0.6, logical_emotional: 0.5 },
		interaction_style: { warmup_speed: 0.5, humor_responsiveness: 0.5, self_disclosure_depth: 0.5, emotional_responsiveness: 0.5, conflict_style: "dialogue", attachment_tendency: "secure", rhythm_preference: "moderate", mirroring_tendency: 0.5 },
		interests: [{ category: "Music", items: ["Jazz"] }],
		values: { work_life_balance: 0.7 },
		romance_style: { communication_frequency: "daily", ideal_relationship: "supportive", dealbreakers: [], preferred_partner_type: "similar" },
		communication_style: { message_length: "medium", question_ratio: 0.4, humor_level: 0.6, empathy_level: 0.8, topic_preferences: [] },
		lifestyle: { weekend_activities: [], diet: "", exercise: "" },
	});
}

beforeEach(() => {
	vi.clearAllMocks();
	mocks.legacyChat.mockResolvedValue(validProfileOutput());
	mocks.boundedCall.mockResolvedValue({ content: validProfileOutput(), finishReason: "stop", inputTokens: 300, outputTokens: 800 });
	mocks.prepareDna.mockReturnValue({ prompt: "synthetic bounded DNA prompt", userTurns: new Set([1, 3]), lang: "en" });
	mocks.scoreDna.mockResolvedValue({
		interactionStyle: { dna_scores: { mere_exposure: { score: 0.6, confidence: 0.8, evidence_turns: [1], reasoning: "synthetic" } } },
		overallSignature: "synthetic signature",
		preferredPersonaType: "virtual_similar",
		usage: { inputTokens: 250, outputTokens: 90 },
	});
	mocks.scoreDna.mockImplementation(async (prepared: { prompt: string }, apiKey: string) => {
		await mocks.boundedCall(apiKey, [{ role: "user", content: prepared.prompt }], {
			model: "mistral-large-test",
			maxTokens: 2500,
			responseFormat: { type: "json_object" },
			maxRequestBytes: 26_000,
			maxResponseBytes: 64_000,
		});
		return {
			interactionStyle: { dna_scores: { mere_exposure: { score: 0.6, confidence: 0.8, evidence_turns: [1], reasoning: "synthetic" } } },
			overallSignature: "synthetic signature",
			preferredPersonaType: "virtual_similar",
			usage: { inputTokens: 250, outputTokens: 90 },
		};
	});
	mocks.legacyDna.mockResolvedValue(null);
	mocks.loadInputs.mockResolvedValue({
		quizText: "[{\"question_id\":\"q1\",\"selected\":[\"synthetic\"]}]",
		conversationLogs: "--- Interview 1 ---\nuser: synthetic\npersona: synthetic",
		sessionIds,
		sessions: ["virtual_similar", "virtual_complementary", "virtual_discovery"].map((personaType) => ({
			personaType,
			messages: [
				{ role: "user", content: "synthetic user" },
				{ role: "persona", content: "synthetic persona" },
				{ role: "user", content: "synthetic user again" },
				{ role: "persona", content: "synthetic persona again" },
			],
		})),
	});
});

describe("Sora three-interview revision API", () => {
	it.each(["profile_request", "profile_json", "profile_schema", "dna_request_or_validation", "complete"] as const)(
		"reports only safe metadata for failure at %s and leaves the consumed run unretried",
		async (failureStep) => {
			const canary = "PRIVATE_GENERATED_CONTENT_OR_ERROR_BODY";
			const fake = makeFakeSupabase({ completeOutcome: failureStep === "complete" ? "not_eligible" : "saved" });
			vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
			if (failureStep === "profile_request") mocks.boundedCall.mockRejectedValueOnce(new Error(canary));
			if (failureStep === "profile_json") mocks.boundedCall.mockResolvedValueOnce({ content: canary });
			if (failureStep === "profile_schema") mocks.boundedCall.mockResolvedValueOnce({ content: JSON.stringify({ privateText: canary }) });
			if (failureStep === "dna_request_or_validation") mocks.scoreDna.mockRejectedValueOnce(new Error(canary));
			const log = vi.spyOn(console, "error").mockImplementation(() => {});
			try {
				const response = await buildApp(fixedConfig, true).request("/api/profiles/generate", { method: "POST" }, testEnv());
				expect(response.status).toBe(500);
				expect(response.headers.get("X-Wingward-Profile-Revision-Failure-Step")).toBe(failureStep);
				expect(log).toHaveBeenCalledWith(`[wingward/profile-revision] failure_step=${failureStep}`);
				expect(JSON.stringify(log.mock.calls)).not.toContain(canary);
				expect(await response.text()).not.toContain(canary);
				expect(fake.rpcCalls.filter((call) => call.name === "claim_sora_three_interview_profile_revision")).toHaveLength(1);
				expect(fake.writes).toEqual([]);
				expect(mocks.legacyChat).not.toHaveBeenCalled();
				expect(fake.rpcCalls.some((call) => call.name === "complete_sora_three_interview_profile_revision")).toBe(failureStep === "complete");
			} finally {
				log.mockRestore();
			}
		},
	);

	it("does not expose revision diagnostic headers without the trusted E2E context", async () => {
		const fake = makeFakeSupabase();
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		mocks.boundedCall.mockRejectedValueOnce(new Error("PRIVATE_ERROR_BODY"));
		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, testEnv());
		expect(response.status).toBe(500);
		expect(response.headers.has("X-Wingward-Profile-Revision-Failure-Step")).toBe(false);
		expect(response.headers.has("X-Wingward-Generation-Stage")).toBe(false);
	});

	it("claims before exactly two bounded provider requests, then atomically saves the new profile", async () => {
		const fake = makeFakeSupabase();
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);

		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, testEnv());
		const body = await response.json() as Record<string, unknown>;

		expect(response.status).toBe(200);
		expect(body.data).toMatchObject({ id: fake.profileRow.id, version: 9, status: "draft" });
		expect(fake.rpcCalls.map((call) => call.name)).toEqual([
			"claim_sora_three_interview_profile_revision",
			"complete_sora_three_interview_profile_revision",
		]);
		expect(chatCompleteOnceBounded).toHaveBeenCalledTimes(2);
		expect(chatCompleteOnceBounded).toHaveBeenNthCalledWith(1, "synthetic-key", [expect.objectContaining({ content: expect.stringContaining("Write every human-readable description") })], expect.objectContaining({ maxTokens: 1500, maxRequestBytes: 26_000, maxResponseBytes: 64_000 }));
		expect(chatCompleteOnceBounded).toHaveBeenNthCalledWith(2, "synthetic-key", [{ role: "user", content: "synthetic bounded DNA prompt" }], expect.objectContaining({ maxTokens: 2500, maxRequestBytes: 26_000, maxResponseBytes: 64_000 }));
		expect(scorePreparedInteractionDna).toHaveBeenCalledTimes(1);
		expect(scoreInteractionDna).not.toHaveBeenCalled();
		expect(chatComplete).not.toHaveBeenCalled();
		expect(fake.writes).toEqual([]);
	});

	it("does not score DNA after the second bounded provider call fails", async () => {
		const fake = makeFakeSupabase();
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		mocks.scoreDna.mockRejectedValueOnce(new Error("synthetic DNA provider failure"));
		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, testEnv());
		expect(response.status).toBe(500);
		expect(chatCompleteOnceBounded).toHaveBeenCalledTimes(1);
		expect(fake.rpcCalls.some((call) => call.name === "complete_sora_three_interview_profile_revision")).toBe(false);
		expect(fake.writes).toEqual([]);
	});

	it("rejects an out-of-range nested score before the DNA request", async () => {
		const fake = makeFakeSupabase();
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		const invalidProfile = JSON.parse(validProfileOutput());
		invalidProfile.personality_analysis.introvert_extrovert = 1.1;
		mocks.boundedCall.mockResolvedValueOnce({ content: JSON.stringify(invalidProfile), finishReason: "stop", inputTokens: 300, outputTokens: 800 });
		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, testEnv());
		expect(response.status).toBe(500);
		expect(chatCompleteOnceBounded).toHaveBeenCalledTimes(1);
		expect(scorePreparedInteractionDna).not.toHaveBeenCalled();
		expect(fake.rpcCalls.some((call) => call.name === "complete_sora_three_interview_profile_revision")).toBe(false);
		expect(fake.writes).toEqual([]);
	});

	it("rechecks expiry after claim wait and before the first paid request", async () => {
		const fake = makeFakeSupabase({ afterClaim: () => vi.spyOn(Date, "now").mockReturnValue(fixedConfig.expiresAtMs + 1) });
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, testEnv());
		expect(response.status).toBe(409);
		expect(chatCompleteOnceBounded).not.toHaveBeenCalled();
		expect(fake.rpcCalls.map((call) => call.name)).toEqual(["claim_sora_three_interview_profile_revision"]);
		expect(fake.writes).toEqual([]);
		vi.restoreAllMocks();
	});

	it("rechecks expiry after the profile request and skips DNA when the window elapsed", async () => {
		const fake = makeFakeSupabase();
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		mocks.boundedCall.mockImplementationOnce(async () => {
			vi.spyOn(Date, "now").mockReturnValue(fixedConfig.expiresAtMs + 1);
			return { content: validProfileOutput(), finishReason: "stop", inputTokens: 300, outputTokens: 800 };
		});
		const response = await buildApp().request("/api/profiles/generate", { method: "POST" }, testEnv());
		expect(response.status).toBe(409);
		expect(chatCompleteOnceBounded).toHaveBeenCalledTimes(1);
		expect(scorePreparedInteractionDna).not.toHaveBeenCalled();
		expect(fake.rpcCalls.some((call) => call.name === "complete_sora_three_interview_profile_revision")).toBe(false);
		expect(fake.writes).toEqual([]);
		vi.restoreAllMocks();
	});

	it("keeps a failed paid attempt consumed and never makes a third provider request", async () => {
		const fake = makeFakeSupabase({ claimOutcomes: ["claimed", "already_claimed"] });
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		mocks.boundedCall.mockRejectedValueOnce(new Error("synthetic provider failure"));

		const first = await buildApp().request("/api/profiles/generate", { method: "POST" }, testEnv());
		const second = await buildApp().request("/api/profiles/generate", { method: "POST" }, testEnv());

		expect(first.status).toBe(500);
		expect(second.status).toBe(409);
		expect(chatCompleteOnceBounded).toHaveBeenCalledTimes(1);
		expect(fake.rpcCalls.filter((call) => call.name === "claim_sora_three_interview_profile_revision")).toHaveLength(2);
		expect(fake.rpcCalls.some((call) => call.name === "complete_sora_three_interview_profile_revision")).toBe(false);
		expect(fake.writes).toEqual([]);
	});

	it.each([
		["available", true],
		["claimed", false],
		["completed", false],
	])("reports revision status %s without losing the existing Wingfox", async (revisionState, canRegenerate) => {
		const fake = makeFakeSupabase({ revisionState });
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		const response = await buildApp().request("/api/profiles/me/generation-state", { method: "GET" }, testEnv());
		const body = await response.json() as Record<string, unknown>;
		expect(response.status).toBe(200);
		expect(body.data).toMatchObject({
			profile_generated: true,
			wingfox_generated: true,
			profile_revision_status: revisionState,
			can_regenerate_from_three: canRegenerate,
		});
		expect(fake.writes).toEqual([]);
	});

	it("rejects confirming the old draft while the claim is consumed", async () => {
		const fake = makeFakeSupabase({ revisionState: "claimed" });
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		const response = await buildApp().request("/api/profiles/me/confirm", { method: "POST" }, testEnv());
		expect(response.status).toBe(409);
		expect(fake.writes).toEqual([]);
		expect(fake.rpcCalls[0]?.name).toBe("read_sora_three_interview_profile_revision_state");
	});

	it("confirms only after completion and leaves the existing Wingfox read-only", async () => {
		const fake = makeFakeSupabase({ revisionState: "completed" });
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		const response = await buildApp().request("/api/profiles/me/confirm", { method: "POST" }, testEnv());
		expect(response.status).toBe(200);
		expect(fake.writes.map((write) => write.table)).toEqual(["profiles", "user_profiles"]);
	});
});

describe("Sora revision access through the production E2E gate", () => {
	function gatedApp() {
		const app = new Hono<Env>();
		app.use("*", productionE2EGate);
		app.route("/api/profiles", profiles);
		return app;
	}

	it("allows only the fixed Sora generation route and keeps matching closed", async () => {
		const fake = makeFakeSupabase();
		vi.mocked(getSupabaseClient).mockReturnValue(fake.client as never);
		const env = testEnv(fixedConfig, { PRODUCTION_E2E_READ_ONLY: "false" });
		const soraResponse = await gatedApp().request("/api/profiles/generate", {
			method: "POST", headers: { Authorization: "Bearer sora" },
		}, env);
		expect(soraResponse.status).toBe(200);

		const requestCount = vi.mocked(chatCompleteOnceBounded).mock.calls.length;
		const renResponse = await gatedApp().request("/api/profiles/generate", {
			method: "POST", headers: { Authorization: "Bearer ren" },
		}, env);
		expect(renResponse.status).toBe(403);
		expect(chatCompleteOnceBounded).toHaveBeenCalledTimes(requestCount);

		const matchingResponse = await gatedApp().request("/api/matching/start", {
			method: "POST", headers: { Authorization: "Bearer sora" },
		}, env);
		expect(matchingResponse.status).toBe(403);
	});

	it.each([
		["read-only mode", { PRODUCTION_E2E_READ_ONLY: "true" }],
		["owner-prep disabled", { RECORDING_REHEARSAL_OWNER_PREP_ONLY: "disabled" }],
		["revision disabled", { RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED: "disabled" }],
	])("fails closed when %s", async (_label, overrides) => {
		const app = gatedApp();
		const response = await app.request("/api/profiles/generate", {
			method: "POST", headers: { Authorization: "Bearer sora" },
		}, testEnv(fixedConfig, overrides));
		expect([403, 503]).toContain(response.status);
		expect(chatCompleteOnceBounded).not.toHaveBeenCalled();
	});
});
