import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "synthetic-user");
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));
vi.mock("../lib/speed-dating-ai", async (importOriginal) => {
	const actual = await importOriginal<typeof import("../lib/speed-dating-ai")>();
	return {
		...actual,
		buildSpeedDatingConversationBootstrap: vi.fn(actual.buildSpeedDatingConversationBootstrap),
	};
});

import { getSupabaseClient } from "../db/client";
import {
	buildSpeedDatingConversationBootstrap,
	ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT,
} from "../lib/speed-dating-ai";
import speedDating from "./speed-dating";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const mockedBuildBootstrap = vi.mocked(buildSpeedDatingConversationBootstrap);
const sessionId = "22222222-2222-4222-8222-222222222222";
const personaId = "33333333-3333-4333-8333-333333333333";
const ownerTimestamp = "2026-09-06T00:00:00.000Z";
const POISON = "POISONED_MESSAGE body=POISONED_BODY key=POISONED_KEY token=POISONED_TOKEN";

function validOwner(language: "ja" | "en" = "ja"): Record<string, unknown> {
	return {
		conversation_language: language,
		age_verified_at: ownerTimestamp,
		onboarding_settings_completed_at: ownerTimestamp,
		// These fields must never cross the provider boundary.
		preferred_genders: [POISON],
		station_id: POISON,
	};
}

function validPersona(): Record<string, unknown> {
	return {
		id: personaId,
		user_id: "synthetic-user",
		persona_type: "virtual_similar",
		name: "Sakura",
		compiled_document: "gender: male\n## Core Identity\nA calm reference.",
	};
}

function validSession(status: "active" | "completed" = "active"): Record<string, unknown> {
	return {
		id: sessionId,
		user_id: "synthetic-user",
		persona_id: personaId,
		status,
		personas: validPersona(),
	};
}

function chain(result: unknown, rejection?: unknown) {
	const query: Record<string, unknown> = {};
	for (const method of ["select", "eq"]) query[method] = () => query;
	query.maybeSingle = () => rejection === undefined
		? Promise.resolve(result)
		: Promise.reject(rejection);
	return query;
}

type SupabaseFixtureOptions = {
	owners?: Array<{ data: unknown; error?: unknown }>;
	sessions?: Array<{ data: unknown; error?: unknown }>;
	ownerThrows?: Array<unknown | undefined>;
	sessionThrows?: Array<unknown | undefined>;
};

function makeSupabase(options: SupabaseFixtureOptions = {}) {
	const owners = options.owners ?? [{ data: validOwner() }, { data: validOwner() }];
	const sessions = options.sessions ?? [{ data: validSession() }, { data: validSession() }];
	let ownerCalls = 0;
	let sessionCalls = 0;
	return {
		from(table: string) {
			if (table === "user_profiles") {
				const index = Math.min(ownerCalls++, owners.length - 1);
				const result = owners[index] ?? { data: null };
				return chain(result, options.ownerThrows?.[index]);
			}
			if (table === "speed_dating_sessions") {
				const index = Math.min(sessionCalls++, sessions.length - 1);
				const result = sessions[index] ?? { data: null };
				return chain(result, options.sessionThrows?.[index]);
			}
			throw new Error(`unexpected table ${table}`);
		},
	};
}

function providerBindings(overrides: Record<string, unknown> = {}) {
	return {
		SPEED_DATING_AI_SERVER_ACTIVATION: "enabled",
		ELEVENLABS_API_KEY: "synthetic-elevenlabs-key",
		ELEVENLABS_AGENT_ID_JA: "agent-ja",
		ELEVENLABS_AGENT_ID_EN: "agent-en",
		ELEVENLABS_VOICE_ID_JA: "voice-ja",
		ELEVENLABS_VOICE_ID_EN: "voice-en",
		ELEVENLABS_MODEL_ID_JA: "eleven_v3_conversational",
		ELEVENLABS_MODEL_ID_EN: "eleven_v3_conversational",
		...overrides,
	};
}

function makeApp(activeE2E = false) {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		if (activeE2E) c.set("production_e2e_active", true);
		await next();
	});
	app.route("/api/speed-dating", speedDating);
	return app;
}

async function requestNative(options: {
	activeE2E?: boolean;
	bindings?: Record<string, unknown>;
	headers?: Record<string, string>;
	fixture?: SupabaseFixtureOptions;
	clientThrow?: unknown;
} = {}) {
	if (options.clientThrow !== undefined) {
		mockedGetSupabaseClient.mockImplementation(() => {
			throw options.clientThrow;
		});
	} else {
		const supabase = makeSupabase(options.fixture);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
	}
	return makeApp(options.activeE2E).request(
		`/api/speed-dating/sessions/${sessionId}/native-bootstrap`,
		{ headers: options.headers },
		{ ...providerBindings(), ...options.bindings } as never,
	);
}

async function expectInternalFailure(
	response: Response,
	stage: string,
	statusCode = 0,
	activeE2E = true,
) {
	const body = await response.text();
	expect(response.status).toBe(500);
	expect(body).toBe(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "AI session unavailable" } }));
	expect(body).not.toContain(POISON);
	if (activeE2E) {
		expect(response.headers.get("X-Wingward-E2E-Stage")).toBe(stage);
		if (statusCode === 0) {
			expect(response.headers.has("X-Wingward-E2E-Upstream-Status")).toBe(false);
		} else {
			expect(response.headers.get("X-Wingward-E2E-Upstream-Status")).toBe(String(statusCode));
		}
	} else {
		expect(response.headers.has("X-Wingward-E2E-Stage")).toBe(false);
		expect(response.headers.has("X-Wingward-E2E-Upstream-Status")).toBe(false);
	}
}

describe("GET /api/speed-dating/sessions/:id/native-bootstrap diagnostics", () => {
	let consoleErrorSpy: ReturnType<typeof vi.spyOn>;
	let consoleInfoSpy: ReturnType<typeof vi.spyOn>;

	beforeEach(() => {
		vi.clearAllMocks();
		mockedGetSupabaseClient.mockReset();
		mockedBuildBootstrap.mockClear();
		vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("synthetic fetch guard"));
		consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		consoleInfoSpy = vi.spyOn(console, "info").mockImplementation(() => {});
	});

	afterEach(() => {
		vi.restoreAllMocks();
	});

	it("reports a fixed binding stage and does no provider or database work when disabled", async () => {
		const fetchSpy = vi.spyOn(globalThis, "fetch");
		const response = await requestNative({
			activeE2E: true,
			bindings: { SPEED_DATING_AI_SERVER_ACTIVATION: "disabled" },
		});

		await expectInternalFailure(response, "binding");
		expect(mockedGetSupabaseClient).not.toHaveBeenCalled();
		expect(fetchSpy).not.toHaveBeenCalled();
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=binding status=0");
	});

	it("reports incomplete locale binding without exposing bindings", async () => {
		const fetchSpy = vi.spyOn(globalThis, "fetch");
		const response = await requestNative({
			activeE2E: true,
			bindings: { ELEVENLABS_MODEL_ID_JA: undefined },
		});

		await expectInternalFailure(response, "binding");
		expect(fetchSpy).not.toHaveBeenCalled();
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=binding status=0");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	const ownerFailureCases: Array<[
		string,
		string,
		number,
		{ clientThrow?: unknown; fixture?: SupabaseFixtureOptions },
	]> = [
		["client construction", "owner_lookup", 401, { clientThrow: { statusCode: 401, message: POISON } }],
		["owner lookup response", "owner_lookup", 403, { fixture: { owners: [{ data: null, error: { statusCode: 403, body: POISON } }] } }],
	];

	it.each(ownerFailureCases)("sanitizes %s failures", async (_name, stage, statusCode, options) => {
		const response = await requestNative({ activeE2E: true, ...options });

		await expectInternalFailure(response, stage, statusCode);
		expect(consoleErrorSpy).toHaveBeenCalledWith(
			`[wingward/native-bootstrap] stage=${stage} status=${statusCode}`,
		);
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	it("reports session lookup and ownership failures as a fixed not-found result", async () => {
		const fetchSpy = vi.spyOn(globalThis, "fetch");
		const response = await requestNative({
			activeE2E: true,
			fixture: { sessions: [{ data: { ...validSession(), user_id: "other-user" } }] },
		});

		const body = await response.text();
		expect(response.status).toBe(404);
		expect(body).toBe(JSON.stringify({ error: { code: "NOT_FOUND", message: "Session not found" } }));
		expect(response.headers.get("X-Wingward-E2E-Stage")).toBe("session_lookup");
		expect(response.headers.has("X-Wingward-E2E-Upstream-Status")).toBe(false);
		expect(fetchSpy).not.toHaveBeenCalled();
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=session_lookup status=0");
	});

	it("reports an invalid attached persona without exposing its fields", async () => {
		const response = await requestNative({
			activeE2E: true,
			fixture: { sessions: [{ data: { ...validSession(), personas: { ...validPersona(), user_id: "other-user", compiled_document: POISON } } }] },
		});

		const body = await response.text();
		expect(response.status).toBe(404);
		expect(body).toBe(JSON.stringify({ error: { code: "NOT_FOUND", message: "Session not found" } }));
		expect(response.headers.get("X-Wingward-E2E-Stage")).toBe("persona_lookup");
		expect(response.headers.has("X-Wingward-E2E-Upstream-Status")).toBe(false);
		expect(body).not.toContain(POISON);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=persona_lookup status=0");
	});

	it("reports an override builder failure without passing the thrown value to logging", async () => {
		mockedBuildBootstrap.mockReturnValueOnce(null);
		const fetchSpy = vi.spyOn(globalThis, "fetch");
		const response = await requestNative({ activeE2E: true });

		await expectInternalFailure(response, "overrides");
		expect(fetchSpy).not.toHaveBeenCalled();
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=overrides status=0");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	it("records a network failure with no arbitrary error data", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase() as never);
		const fetchSpy = vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(new Error(POISON));
		const response = await requestNative({ activeE2E: true });

		await expectInternalFailure(response, "provider_fetch");
		expect(fetchSpy).toHaveBeenCalledWith(
			expect.stringContaining(`${ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT}?agent_id=agent-ja`),
			expect.objectContaining({ redirect: "manual", headers: { "xi-api-key": "synthetic-elevenlabs-key" } }),
		);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=provider_fetch status=0");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	it("reports an abort timeout without leaking the thrown value or retaining its timer", async () => {
		vi.useFakeTimers();
		let fetchStartedResolve: (() => void) | undefined;
		const fetchStarted = new Promise<void>((resolve) => {
			fetchStartedResolve = resolve;
		});
		vi.spyOn(globalThis, "fetch").mockImplementation((_input, init) => {
			fetchStartedResolve?.();
			return new Promise((_resolve, reject) => {
				init?.signal?.addEventListener("abort", () => reject(new Error(POISON)), { once: true });
			});
		});

		try {
			const responsePromise = requestNative({ activeE2E: true });
			await fetchStarted;
			await vi.advanceTimersByTimeAsync(8_000);
			const response = await responsePromise;

			await expectInternalFailure(response, "provider_fetch");
			expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=provider_fetch status=0");
			expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
			expect(vi.getTimerCount()).toBe(0);
		} finally {
			vi.useRealTimers();
		}
	});

	it("reads an error status once so a changing getter cannot replace it with a sentinel", async () => {
		let statusReads = 0;
		const changingError = {
			get statusCode() {
				statusReads += 1;
				return statusReads === 1 ? 401 : POISON;
			},
			message: POISON,
		};
		vi.spyOn(globalThis, "fetch").mockRejectedValueOnce(changingError);
		const response = await requestNative({ activeE2E: true });

		await expectInternalFailure(response, "provider_fetch", 401);
		expect(statusReads).toBe(1);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=provider_fetch status=401");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	it.each([401, 403])("reports provider HTTP %s as status only", async (statusCode) => {
		vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(POISON, { status: statusCode }));
		const response = await requestNative({ activeE2E: true });

		await expectInternalFailure(response, "provider_status", statusCode);
		expect(consoleErrorSpy).toHaveBeenCalledWith(
			`[wingward/native-bootstrap] stage=provider_status status=${statusCode}`,
		);
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	it.each([
		["oversized body", new Response("x".repeat(8_193), { status: 200 })],
		["stream failure", new Response(new ReadableStream({ start(controller) { controller.error(new Error(POISON)); } }), { status: 200 })],
	] as const)("reports bounded-body %s without buffering or logging it", async (_name, providerResponse) => {
		vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(providerResponse);
		const response = await requestNative({ activeE2E: true });

		await expectInternalFailure(response, "provider_body");
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=provider_body status=0");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	it("reports malformed provider schema without exposing provider fields", async () => {
		vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(JSON.stringify({
			token: "synthetic-token",
			conversation_id: "conv_synthetic",
			leak: POISON,
		}), { status: 200 }));
		const response = await requestNative({ activeE2E: true });

		await expectInternalFailure(response, "provider_schema");
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=provider_schema status=0");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	it("reports postfetch owner changes and does not return a provider token", async () => {
		vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(JSON.stringify({
			token: "synthetic-token",
			conversation_id: "conv_synthetic",
		}), { status: 200 }));
		const response = await requestNative({
			activeE2E: true,
			fixture: { owners: [{ data: validOwner("ja") }, { data: validOwner("en") }] },
		});

		await expectInternalFailure(response, "postfetch_owner");
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=postfetch_owner status=0");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("synthetic-token");
	});

	it("reports postfetch session invalidation and keeps the token private", async () => {
		vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(JSON.stringify({
			token: "synthetic-token",
			conversation_id: "conv_synthetic",
		}), { status: 200 }));
		const response = await requestNative({
			activeE2E: true,
			fixture: { sessions: [{ data: validSession() }, { data: validSession("completed") }] },
		});

		await expectInternalFailure(response, "postfetch_session");
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=postfetch_session status=0");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("synthetic-token");
	});

	it("returns the unchanged token and four overrides, with a trusted ready marker only", async () => {
		vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(JSON.stringify({
			token: "synthetic-token",
			conversation_id: "conv_synthetic",
		}), { status: 200 }));
		const response = await requestNative({ activeE2E: true });
		const body = (await response.json()) as { data: Record<string, unknown> };

		expect(response.status).toBe(200);
		expect(body.data).toMatchObject({ session_id: sessionId, conversation_token: "synthetic-token" });
		const overrides = body.data.overrides as {
			agent: { prompt: { prompt: string }; firstMessage: string; language: string };
			tts: { voiceId: string };
		};
		expect(Object.keys(overrides)).toEqual(["agent", "tts"]);
		expect(Object.keys(overrides.agent)).toEqual(["prompt", "firstMessage", "language"]);
		expect(Object.keys(overrides.tts)).toEqual(["voiceId"]);
		expect(overrides.agent.language).toBe("ja");
		expect(overrides.agent.firstMessage).toBe("はじめまして！Sakuraです。よろしくね！");
		expect(overrides.tts.voiceId).toBe("voice-ja");
		expect(JSON.stringify(body.data)).not.toContain("synthetic-elevenlabs-key");
		expect(JSON.stringify(body.data)).not.toContain(POISON);
		expect(response.headers.has("X-Wingward-E2E-Stage")).toBe(false);
		expect(consoleErrorSpy).not.toHaveBeenCalled();
		expect(consoleInfoSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=ready status=200");
	});

	it("does not let an untrusted request header enable response diagnostics", async () => {
		vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(POISON, { status: 403 }));
		const response = await requestNative({
			activeE2E: false,
			headers: {
				"X-Wingward-E2E-Active": "true",
				"X-Wingward-E2E-Stage": "spoofed",
			},
		});

		await expectInternalFailure(response, "provider_status", 403, false);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/native-bootstrap] stage=provider_status status=403");
		expect(consoleInfoSpy).not.toHaveBeenCalled();
	});

	it("does not emit a ready marker for a normal successful request", async () => {
		vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(JSON.stringify({
			token: "synthetic-token",
			conversation_id: "conv_synthetic",
		}), { status: 200 }));
		const response = await requestNative({ activeE2E: false });

		expect(response.status).toBe(200);
		expect(response.headers.has("X-Wingward-E2E-Stage")).toBe(false);
		expect(consoleErrorSpy).not.toHaveBeenCalled();
		expect(consoleInfoSpy).not.toHaveBeenCalled();
	});
});
