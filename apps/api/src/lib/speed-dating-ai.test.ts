import { describe, expect, it } from "vitest";
import {
	ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT,
	ELEVENLABS_SIGNED_URL_ENDPOINT,
	ELEVENLABS_WEBSOCKET_ENDPOINT,
	buildSpeedDatingConversationBootstrap,
	buildSpeedDatingWebOverrides,
	isCanonicalUuid,
	isKnownElevenLabsModelId,
	isSafeElevenLabsSignedUrl,
	isValidTimestamp,
	parseSafeElevenLabsSignedUrlResponse,
	parseSafeElevenLabsConversationTokenResponse,
	readActiveSpeedDatingSession,
	readBoundedResponseTextWithSignal,
	readOwnedVirtualPersona,
	readSpeedDatingOwnerState,
	resolveElevenLabsLocaleBinding,
} from "./speed-dating-ai";

const ownerTimestamp = "2026-09-06T00:00:00.000Z";
const sessionId = "abcdefab-cdef-4abc-8def-abcdefabcdef";
const personaId = "33333333-3333-4333-8333-333333333333";

function makeBindings(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
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

function makeOwnerRow(language: "ja" | "en", extra: Record<string, unknown> = {}) {
	return {
		ui_locale: language === "ja" ? "en" : "ja",
		conversation_language: language,
		age_verified_at: ownerTimestamp,
		onboarding_settings_completed_at: ownerTimestamp,
		gender_identity: "woman",
		preferred_genders: ["man"],
		station_id: "jp-tokyo-shibuya",
		...extra,
	};
}

describe("speed-dating AI bootstrap validation", () => {
	it("resolves distinct locale-specific agent and voice bindings", () => {
		const ja = resolveElevenLabsLocaleBinding(makeBindings(), "ja");
		const en = resolveElevenLabsLocaleBinding(makeBindings(), "en");

		expect(ja).toMatchObject({ agentId: "agent-ja", voiceId: "voice-ja", modelId: "eleven_flash_v2_5" });
		expect(en).toMatchObject({ agentId: "agent-en", voiceId: "voice-en", modelId: "eleven_flash_v2_5" });
		expect(ja?.agentId).not.toBe(en?.agentId);
		expect(ja?.voiceId).not.toBe(en?.voiceId);
	});

	it.each([
		["missing API key", { ELEVENLABS_API_KEY: undefined }],
		["missing JA agent", { ELEVENLABS_AGENT_ID_JA: undefined }],
		["missing JA voice", { ELEVENLABS_VOICE_ID_JA: undefined }],
		["missing locale model", { ELEVENLABS_MODEL_ID_JA: undefined }],
		["unsupported model", { ELEVENLABS_MODEL_ID_JA: "multilingual_v2" }],
	])("fails closed before a provider call when %s", (_name, overrides) => {
		expect(resolveElevenLabsLocaleBinding(makeBindings(overrides), "ja")).toBeNull();
	});

	it("does not fall back to the legacy single-agent binding", () => {
		expect(resolveElevenLabsLocaleBinding({
			ELEVENLABS_API_KEY: "synthetic-key",
			ELEVENLABS_AGENT_ID: "legacy-agent",
		}, "en")).toBeNull();
		expect(isKnownElevenLabsModelId("eleven_flash_v2_5")).toBe(true);
		expect(isKnownElevenLabsModelId("eleven_v3_conversational")).toBe(true);
		expect(isKnownElevenLabsModelId("multilingual_v2")).toBe(false);
	});

	it("accepts the known v3 conversational model for readiness only", () => {
		const binding = resolveElevenLabsLocaleBinding(makeBindings({ ELEVENLABS_MODEL_ID_JA: "eleven_v3_conversational" }), "ja");
		expect(binding).toMatchObject({ modelId: "eleven_v3_conversational" });
	});

	it("reads only a complete saved owner gate and ignores private fields", () => {
		expect(readSpeedDatingOwnerState(makeOwnerRow("ja"))).toEqual({
		conversationLanguage: "ja",
		ageVerified: true,
		settingsCompleted: true,
	});
		expect(readSpeedDatingOwnerState({
		...makeOwnerRow("ja"),
		age_verified_at: null,
	})).toBeNull();
		expect(readSpeedDatingOwnerState({
		...makeOwnerRow("en"),
		onboarding_settings_completed_at: "2026-02-30T00:00:00.000Z",
	})).toBeNull();
		expect(readSpeedDatingOwnerState({
		conversation_language: "fr",
		age_verified_at: ownerTimestamp,
		onboarding_settings_completed_at: ownerTimestamp,
	})).toBeNull();
		expect(readSpeedDatingOwnerState([{ ...makeOwnerRow("ja") }])).toBeNull();
	});

	it.each([
		{
			name: "Japanese conversation overrides English UI",
			owner: makeOwnerRow("ja"),
			voice: "voice-ja",
			opening: "はじめまして！さくらです。よろしくね！",
			languageRule: "この会話では常に日本語で返答すること",
		},
		{
			name: "English conversation overrides Japanese UI",
			owner: makeOwnerRow("en"),
			voice: "voice-en",
			opening: "Hi! I'm Alex. Nice to meet you!",
			languageRule: "Always respond in English for this conversation",
		},
	])("uses saved conversation_language for prompt, greeting, and voice ($name)", ({ owner, voice, opening, languageRule }) => {
		const language = owner.conversation_language as "ja" | "en";
		const bootstrap = buildSpeedDatingConversationBootstrap({
			ownerRow: owner,
			personaDocument: "Reference text in the other language.",
			personaName: language === "ja" ? "さくら" : "Alex",
			voiceId: voice,
		});
		const binding = resolveElevenLabsLocaleBinding(makeBindings(), language);

		expect(bootstrap).not.toBeNull();
		expect(binding?.voiceId).toBe(voice);
		expect(bootstrap?.language).toBe(language);
		expect(bootstrap?.firstMessage).toBe(opening);
		expect(bootstrap?.systemPrompt).toContain(languageRule);
		expect(bootstrap?.overrides).toEqual({
			agent: { prompt: { prompt: bootstrap?.systemPrompt }, firstMessage: opening, language },
		tts: { voiceId: voice },
		});
	});

	it("fails closed for incomplete bootstrap inputs", () => {
		const valid = {
			ownerRow: makeOwnerRow("en"),
			personaDocument: "persona",
			personaName: "Alex",
			voiceId: "voice-en",
		};
		expect(buildSpeedDatingConversationBootstrap({ ...valid, ownerRow: { ...valid.ownerRow, onboarding_settings_completed_at: null } })).toBeNull();
		expect(buildSpeedDatingConversationBootstrap({ ...valid, personaName: "Alex\nInjected" })).toBeNull();
		expect(buildSpeedDatingConversationBootstrap({ ...valid, personaDocument: "x".repeat(32_001) })).toBeNull();
		expect(buildSpeedDatingConversationBootstrap({ ...valid, voiceId: " " })).toBeNull();
	});

	it("validates the exact signed WebSocket endpoint and strict response shape", () => {
		const safeUrl = `${ELEVENLABS_WEBSOCKET_ENDPOINT}?conversation_signature=synthetic`;
		expect(isSafeElevenLabsSignedUrl(safeUrl)).toBe(true);
		expect(isSafeElevenLabsSignedUrl("https://api.elevenlabs.io/v1/convai/conversation?token=x")).toBe(false);
		expect(isSafeElevenLabsSignedUrl("wss://evil.invalid/v1/convai/conversation?token=x")).toBe(false);
		expect(isSafeElevenLabsSignedUrl("wss://user:pass@api.elevenlabs.io/v1/convai/conversation?token=x")).toBe(false);
		expect(isSafeElevenLabsSignedUrl("wss://api.elevenlabs.io:444/v1/convai/conversation?token=x")).toBe(false);
		expect(isSafeElevenLabsSignedUrl("wss://api.elevenlabs.io/v1/convai/conversation/extra?token=x")).toBe(false);
		expect(isSafeElevenLabsSignedUrl("wss://api.elevenlabs.io/v1/convai/conversation?token=x#fragment")).toBe(false);
		expect(parseSafeElevenLabsSignedUrlResponse(JSON.stringify({ signed_url: safeUrl }))).toBe(safeUrl);
		expect(parseSafeElevenLabsSignedUrlResponse(JSON.stringify({ signed_url: "https://evil.invalid" }))).toBeNull();
		expect(parseSafeElevenLabsSignedUrlResponse(JSON.stringify({ signed_url: safeUrl, leak: "provider body" }))).toBeNull();
		expect(parseSafeElevenLabsSignedUrlResponse("x".repeat(8_193))).toBeNull();
		expect(ELEVENLABS_SIGNED_URL_ENDPOINT).toBe("https://api.elevenlabs.io/v1/convai/conversation/get-signed-url");
	});

	it("accepts only a bounded opaque WebRTC conversation token", () => {
		expect(parseSafeElevenLabsConversationTokenResponse(JSON.stringify({ token: "synthetic-token", conversation_id: "conv_synthetic" }))).toBe("synthetic-token");
		expect(parseSafeElevenLabsConversationTokenResponse(JSON.stringify({ token: "synthetic-token", conversation_id: "conv_synthetic", leak: "body" }))).toBeNull();
		expect(parseSafeElevenLabsConversationTokenResponse(JSON.stringify({ token: "token\nwith-control", conversation_id: "conv_synthetic" }))).toBeNull();
		expect(parseSafeElevenLabsConversationTokenResponse("x".repeat(8_193))).toBeNull();
		expect(ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT).toBe("https://api.elevenlabs.io/v1/convai/conversation/token");
	});

	it("bounds and validates provider response text", async () => {
		const body = JSON.stringify({ signed_url: `${ELEVENLABS_WEBSOCKET_ENDPOINT}?token=synthetic` });
		expect(await readBoundedResponseTextWithSignal(new Response(body), 512)).toBe(body);
		expect(await readBoundedResponseTextWithSignal(new Response("x".repeat(513)), 512)).toBeNull();
		expect(await readBoundedResponseTextWithSignal(new Response(new Uint8Array([0xc3, 0x28])), 512)).toBeNull();
		const controller = new AbortController();
		controller.abort();
		expect(await readBoundedResponseTextWithSignal(new Response(body), 512, controller.signal)).toBeNull();
	});

	it("requires active owner-bound sessions and personas", () => {
		const session = { id: sessionId, user_id: "owner-1", persona_id: personaId, status: "active" };
		expect(readActiveSpeedDatingSession(session, "owner-1", sessionId)).toMatchObject({ id: sessionId, personaId });
		expect(readActiveSpeedDatingSession({ ...session, status: "completed" }, "owner-1", sessionId)).toBeNull();
		expect(readActiveSpeedDatingSession({ ...session, user_id: "other" }, "owner-1", sessionId)).toBeNull();

		const persona = {
			id: personaId,
			user_id: "owner-1",
			persona_type: "virtual_similar",
			name: "Sakura",
			compiled_document: "persona",
		};
		expect(readOwnedVirtualPersona(persona, "owner-1", personaId)).toMatchObject({ name: "Sakura" });
		expect(readOwnedVirtualPersona({ ...persona, user_id: "other" }, "owner-1", personaId)).toBeNull();
		expect(readOwnedVirtualPersona({ ...persona, persona_type: "real_user" }, "owner-1", personaId)).toBeNull();
	});

	it("accepts only canonical identifiers and timestamps", () => {
		expect(isCanonicalUuid(sessionId)).toBe(true);
		expect(isCanonicalUuid(sessionId.toUpperCase())).toBe(false);
		expect(isValidTimestamp(ownerTimestamp)).toBe(true);
		expect(isValidTimestamp("2026-02-30T00:00:00.000Z")).toBe(false);
		expect(isValidTimestamp("2026-09-06")).toBe(false);
	});

	it("keeps the Web override contract closed", () => {
		const overrides = buildSpeedDatingWebOverrides("ja", "voice-ja", "system", "first");
		expect(overrides).toEqual({
			agent: { prompt: { prompt: "system" }, firstMessage: "first", language: "ja" },
			tts: { voiceId: "voice-ja" },
		});
		expect(overrides).not.toHaveProperty("model");
		expect(overrides).not.toHaveProperty("language_code");
		expect(overrides).not.toHaveProperty("agent.prompt.llm");
		expect(overrides).not.toHaveProperty("tts.model_id");
		expect(Object.keys(overrides.agent)).toEqual(["prompt", "firstMessage", "language"]);
		expect(Object.keys(overrides.tts)).toEqual(["voiceId"]);
	});
});
