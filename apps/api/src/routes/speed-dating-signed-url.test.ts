import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "synthetic-user");
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));
vi.mock("../services/mistral", () => ({ chatComplete: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import { chatComplete } from "../services/mistral";
import {
	ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT,
	ELEVENLABS_SIGNED_URL_ENDPOINT,
	ELEVENLABS_WEBSOCKET_ENDPOINT,
} from "../lib/speed-dating-ai";
import speedDating from "./speed-dating";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const mockedChatComplete = vi.mocked(chatComplete);
const sessionId = "22222222-2222-4222-8222-222222222222";
const personaId = "33333333-3333-4333-8333-333333333333";
const ownerTimestamp = "2026-09-06T00:00:00.000Z";
const REDIRECT_STATUSES = [301, 302, 303, 307, 308] as const;
const REDIRECT_LOCATION = "https://evil.invalid/redirect?leak=POISONED_LOCATION";
const REDIRECT_BODY = "POISONED_REDIRECT_BODY token=POISONED_TOKEN";

type OwnerLanguage = "ja" | "en";

function makeOwner(language: OwnerLanguage): Record<string, unknown> {
	return {
		ui_locale: language === "ja" ? "en" : "ja",
		conversation_language: language,
		age_verified_at: ownerTimestamp,
		onboarding_settings_completed_at: ownerTimestamp,
		gender_identity: "woman",
		preferred_genders: ["man"],
		station_id: "private-station",
	};
}

function makeSupabase(ownerRows: Record<string, unknown>[], sessionStatuses: Array<"active" | "completed"> = ["active", "active"]) {
	let ownerCalls = 0;
	let sessionCalls = 0;
	return {
		from(table: string) {
			const query: Record<string, unknown> = {};
			for (const method of ["select", "eq"]) query[method] = () => query;
			if (table === "user_profiles") {
				query.maybeSingle = async () => ({ data: ownerRows[Math.min(ownerCalls++, ownerRows.length - 1)], error: null });
				return query;
			}
			if (table === "speed_dating_sessions") {
				query.maybeSingle = async () => ({
					data: {
						id: sessionId,
						user_id: "synthetic-user",
						persona_id: personaId,
						status: sessionStatuses[Math.min(sessionCalls++, sessionStatuses.length - 1)],
						personas: {
							id: personaId,
							user_id: "synthetic-user",
							persona_type: "virtual_similar",
							name: "Sakura",
							compiled_document: "gender: male\n## Core Identity\nA calm reference.\n成人向け",
						},
					},
					error: null,
				});
				return query;
			}
			throw new Error(`unexpected table ${table}`);
		},
	};
}

function makeApp() {
	const app = new Hono();
	app.route("/api/speed-dating", speedDating);
	return app;
}

function providerBindings(overrides: Record<string, unknown> = {}) {
	return {
		SPEED_DATING_AI_SERVER_ACTIVATION: "enabled",
		ELEVENLABS_API_KEY: "synthetic-elevenlabs-key",
		ELEVENLABS_AGENT_ID_JA: "agent-ja",
		ELEVENLABS_AGENT_ID_EN: "agent-en",
		ELEVENLABS_VOICE_ID_JA: "voice-ja",
		ELEVENLABS_VOICE_ID_EN: "voice-en",
		ELEVENLABS_MODEL_ID_JA: "eleven_flash_v2_5",
		ELEVENLABS_MODEL_ID_EN: "eleven_flash_v2_5",
		...overrides,
	};
}

beforeEach(() => {
	vi.restoreAllMocks();
	mockedGetSupabaseClient.mockReset();
	mockedChatComplete.mockReset();
});

describe("GET /api/speed-dating/sessions/:id/native-bootstrap", () => {
	it("stays disabled until server activation is explicit", async () => {
		const fetchSpy = vi.spyOn(globalThis, "fetch");
		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/native-bootstrap`,
			undefined,
			providerBindings({ SPEED_DATING_AI_SERVER_ACTIVATION: "disabled" }) as never,
		);

		expect(response.status).toBe(500);
		expect(await response.text()).toContain("AI session unavailable");
		expect(mockedGetSupabaseClient).not.toHaveBeenCalled();
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it("returns the saved-locale native token bootstrap without exposing provider credentials", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("ja"), makeOwner("ja")]) as never);
		const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
			new Response(JSON.stringify({ token: "synthetic-conversation-token", conversation_id: "conv_synthetic" }), { status: 200 }),
		);

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/native-bootstrap`,
			{ headers: { "Accept-Language": "en" } },
			providerBindings() as never,
		);
		const body = (await response.json()) as { data: Record<string, unknown> };

		expect(response.status).toBe(200);
		expect(body.data).toMatchObject({
			session_id: sessionId,
			conversation_token: "synthetic-conversation-token",
		});
		expect(body.data).not.toHaveProperty("conversation_id");
		expect(JSON.stringify(body.data)).not.toContain("synthetic-elevenlabs-key");
		expect(body.data.overrides).toMatchObject({
			agent: { language: "ja", firstMessage: "はじめまして！Sakuraです。よろしくね！" },
			tts: { voiceId: "voice-ja" },
		});
		expect(JSON.stringify(body.data.overrides)).not.toContain("成人向け");
		expect(fetchSpy).toHaveBeenCalledWith(
			expect.stringContaining(`${ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT}?agent_id=agent-ja`),
			expect.objectContaining({ redirect: "manual", headers: { "xi-api-key": "synthetic-elevenlabs-key" } }),
		);
		expect(mockedChatComplete).not.toHaveBeenCalled();
	});

	it("fails before fetch when the selected native locale is incomplete", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("en")]) as never);
		const fetchSpy = vi.spyOn(globalThis, "fetch");

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/native-bootstrap`,
			undefined,
			providerBindings({ ELEVENLABS_MODEL_ID_EN: undefined }) as never,
		);

		expect(response.status).toBe(500);
		expect(await response.text()).toContain("AI session unavailable");
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it("does not return a malformed token body", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("en")]) as never);
		vi.spyOn(globalThis, "fetch").mockResolvedValue(
			new Response(JSON.stringify({ token: "token\nwith-control", conversation_id: "conv_synthetic" }), { status: 200 }),
		);

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/native-bootstrap`,
			undefined,
			providerBindings() as never,
		);

		expect(response.status).toBe(500);
		expect(await response.text()).toEqual(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "AI session unavailable" } }));
	});

	it.each(REDIRECT_STATUSES)("rejects native provider redirect %s without following or exposing it", async (statusCode) => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("ja"), makeOwner("ja")]) as never);
		const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(REDIRECT_BODY, {
			status: statusCode,
			headers: { Location: REDIRECT_LOCATION },
		}));

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/native-bootstrap`,
			undefined,
			providerBindings() as never,
		);
		const text = await response.text();

		expect(response.status).toBe(500);
		expect(text).toEqual(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "AI session unavailable" } }));
		expect(text).not.toContain(REDIRECT_BODY);
		expect(text).not.toContain(REDIRECT_LOCATION);
		expect(text).not.toContain("synthetic-elevenlabs-key");
		expect([...response.headers.values()]).not.toContain(REDIRECT_LOCATION);
		expect(fetchSpy).toHaveBeenCalledTimes(1);
		expect(fetchSpy).toHaveBeenCalledWith(
			`${ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT}?agent_id=agent-ja`,
			expect.objectContaining({ redirect: "manual", headers: { "xi-api-key": "synthetic-elevenlabs-key" } }),
		);
	});
});

describe("GET /api/speed-dating/sessions/:id/signed-url", () => {
	it("keeps the provider path disabled until server activation is explicit", async () => {
		const fetchSpy = vi.spyOn(globalThis, "fetch");
		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/signed-url`,
			undefined,
			providerBindings({ SPEED_DATING_AI_SERVER_ACTIVATION: "disabled" }) as never,
		);

		expect(response.status).toBe(500);
		expect(await response.text()).toContain("AI session unavailable");
		expect(mockedGetSupabaseClient).not.toHaveBeenCalled();
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it("uses saved conversation_language and locale binding despite contradictory headers/persona text", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("ja"), makeOwner("ja")]) as never);
		const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
			new Response(JSON.stringify({ signed_url: `${ELEVENLABS_WEBSOCKET_ENDPOINT}?conversation_signature=synthetic` }), { status: 200 }),
		);

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/signed-url`,
			{ headers: { "Accept-Language": "en" } },
			providerBindings() as never,
		);
		const body = (await response.json()) as { data: Record<string, unknown> };

		expect(response.status).toBe(200);
		expect(body.data.overrides).toMatchObject({
			agent: {
				language: "ja",
				firstMessage: "はじめまして！Sakuraです。よろしくね！",
			},
			tts: { voiceId: "voice-ja" },
		});
		expect(JSON.stringify(body.data.overrides)).not.toContain("成人向け");
		expect(JSON.stringify(body.data.overrides)).not.toContain("preferred_genders");
		expect(JSON.stringify(body.data.overrides)).not.toContain("private-station");
		expect(fetchSpy).toHaveBeenCalledWith(
			expect.stringContaining("agent_id=agent-ja"),
			expect.objectContaining({ redirect: "manual", headers: { "xi-api-key": "synthetic-elevenlabs-key" } }),
		);
		expect(mockedChatComplete).not.toHaveBeenCalled();
	});

	it("fails before fetch when the selected locale is missing provider configuration", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("ja")]) as never);
		const fetchSpy = vi.spyOn(globalThis, "fetch");

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/signed-url`,
			undefined,
			providerBindings({ ELEVENLABS_VOICE_ID_JA: undefined }) as never,
		);
		const text = await response.text();

		expect(response.status).toBe(500);
		expect(text).toContain("AI session unavailable");
		expect(text).not.toContain("synthetic-elevenlabs-key");
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it.each([
		["malformed JSON", new Response("not-json", { status: 200 })],
		["unsafe URL", new Response(JSON.stringify({ signed_url: "https://evil.invalid" }), { status: 200 })],
		["provider failure", new Response(JSON.stringify({ error: "credential body" }), { status: 502 })],
	])("returns a fixed non-disclosing error for %s", async (_name, providerResponse) => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("en")]) as never);
		const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(providerResponse);

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/signed-url`,
			undefined,
			providerBindings() as never,
		);
		const text = await response.text();

		expect(response.status).toBe(500);
		expect(text).toEqual(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "AI session unavailable" } }));
		expect(text).not.toContain("credential body");
		expect(fetchSpy).toHaveBeenCalledTimes(1);
	});

	it.each(REDIRECT_STATUSES)("rejects signed-url provider redirect %s without following or exposing it", async (statusCode) => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("ja"), makeOwner("ja")]) as never);
		const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response(REDIRECT_BODY, {
			status: statusCode,
			headers: { Location: REDIRECT_LOCATION },
		}));

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/signed-url`,
			undefined,
			providerBindings() as never,
		);
		const text = await response.text();

		expect(response.status).toBe(500);
		expect(text).toEqual(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "AI session unavailable" } }));
		expect(text).not.toContain(REDIRECT_BODY);
		expect(text).not.toContain(REDIRECT_LOCATION);
		expect(text).not.toContain("synthetic-elevenlabs-key");
		expect([...response.headers.values()]).not.toContain(REDIRECT_LOCATION);
		expect(fetchSpy).toHaveBeenCalledTimes(1);
		expect(fetchSpy).toHaveBeenCalledWith(
			`${ELEVENLABS_SIGNED_URL_ENDPOINT}?agent_id=agent-ja`,
			expect.objectContaining({ redirect: "manual", headers: { "xi-api-key": "synthetic-elevenlabs-key" } }),
		);
	});

	it("drops the provider result if the owner changes locale during the await", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("ja"), makeOwner("en")]) as never);
		vi.spyOn(globalThis, "fetch").mockResolvedValue(
			new Response(JSON.stringify({ signed_url: `${ELEVENLABS_WEBSOCKET_ENDPOINT}?token=synthetic` }), { status: 200 }),
		);

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/signed-url`,
			undefined,
			providerBindings() as never,
		);

		expect(response.status).toBe(500);
		expect(await response.text()).toContain("AI session unavailable");
	});

	it("drops the provider result if the session is completed during the await", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase([makeOwner("ja"), makeOwner("ja")], ["active", "completed"]) as never);
		vi.spyOn(globalThis, "fetch").mockResolvedValue(
			new Response(JSON.stringify({ signed_url: `${ELEVENLABS_WEBSOCKET_ENDPOINT}?token=synthetic` }), { status: 200 }),
		);

		const response = await makeApp().request(
			`/api/speed-dating/sessions/${sessionId}/signed-url`,
			undefined,
			providerBindings() as never,
		);

		expect(response.status).toBe(500);
		expect(await response.text()).toContain("AI session unavailable");
	});
});
