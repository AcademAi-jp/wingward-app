import type { ConversationLanguage } from "../services/onboarding-settings";
import { buildSpeedDatingSystemPrompt } from "../prompts/speed-dating";
import { z } from "zod";

/**
 * The existing Web client consumes camelCase override keys. Native clients
 * should translate these keys at their transport boundary rather than
 * widening this response shape.
 */
export type SpeedDatingWebOverrides = {
	agent: {
		prompt: { prompt: string };
		firstMessage: string;
		language: ConversationLanguage;
	};
	tts: { voiceId: string };
};

export type ElevenLabsLocaleBinding = {
	apiKey: string;
	agentId: string;
	voiceId: string;
	modelId: string;
};

/**
 * The provider model is a server-side readiness binding. The current client
 * contract does not send a model override, and `multilingual_v2` is not
 * treated as a proven Convai model here. The configured model is used only as
 * a readiness check; it is never copied into conversation overrides.
 */
const LOCAL_ELEVENLABS_MODEL_IDS: ReadonlySet<string> = new Set([
	"eleven_flash_v2_5",
	"eleven_v3_conversational",
]);

export function isKnownElevenLabsModelId(value: string): boolean {
	return LOCAL_ELEVENLABS_MODEL_IDS.has(value);
}

const LOCALE_BINDING_KEYS: Record<ConversationLanguage, {
	agent: string;
	voice: string;
	model: string;
}> = {
	ja: {
		agent: "ELEVENLABS_AGENT_ID_JA",
		voice: "ELEVENLABS_VOICE_ID_JA",
		model: "ELEVENLABS_MODEL_ID_JA",
	},
	en: {
		agent: "ELEVENLABS_AGENT_ID_EN",
		voice: "ELEVENLABS_VOICE_ID_EN",
		model: "ELEVENLABS_MODEL_ID_EN",
	},
};

export const SPEED_DATING_AI_SERVER_ACTIVATION = "SPEED_DATING_AI_SERVER_ACTIVATION";
export const ELEVENLABS_SIGNED_URL_ENDPOINT =
	"https://api.elevenlabs.io/v1/convai/conversation/get-signed-url";
export const ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT =
	"https://api.elevenlabs.io/v1/convai/conversation/token";
export const ELEVENLABS_WEBSOCKET_ENDPOINT = "wss://api.elevenlabs.io/v1/convai/conversation";

const SIGNED_URL_HOST = "api.elevenlabs.io";
const SIGNED_URL_PATH = "/v1/convai/conversation";
const MAX_BINDING_VALUE_LENGTH = 256;
const SIGNED_URL_RESPONSE_MAX_BYTES = 8_192;
const signedUrlResponseSchema = z.object({ signed_url: z.string().min(1).max(4_096) }).strict();
const conversationTokenResponseSchema = z.object({
	token: z.string().min(1).max(4_096),
	conversation_id: z.string().min(1).max(128).regex(/^conv_[A-Za-z0-9_-]+$/),
}).strict();

function readBindingValue(bindings: unknown, key: string): string | null {
	if (!bindings || typeof bindings !== "object" || Array.isArray(bindings)) return null;
	const value = (bindings as Record<string, unknown>)[key];
	if (typeof value !== "string") return null;
	const trimmed = value.trim();
	return trimmed.length > 0 && trimmed.length <= MAX_BINDING_VALUE_LENGTH ? trimmed : null;
}

/** Read a string binding without depending on shared Env ownership. */
export function readSpeedDatingBinding(bindings: unknown, key: string): string | null {
	return readBindingValue(bindings, key);
}

/**
 * Resolve all provider settings for one saved language. There is deliberately
 * no fallback to the legacy single-agent binding or to the other locale.
 */
export function resolveElevenLabsLocaleBinding(
	bindings: unknown,
	language: ConversationLanguage,
): ElevenLabsLocaleBinding | null {
	const apiKey = readBindingValue(bindings, "ELEVENLABS_API_KEY");
	const keys = LOCALE_BINDING_KEYS[language];
	const agentId = readBindingValue(bindings, keys.agent);
	const voiceId = readBindingValue(bindings, keys.voice);
	const modelId = readBindingValue(bindings, keys.model);
	if (!apiKey || !agentId || !voiceId || !modelId || !isKnownElevenLabsModelId(modelId)) return null;
	return { apiKey, agentId, voiceId, modelId };
}

/**
 * Accept only the documented ElevenLabs signed-WebSocket endpoint. The query
 * carries the short-lived credential, while userinfo, fragments, alternate
 * ports, alternate paths, and non-WebSocket protocols are rejected.
 */
export function isSafeElevenLabsSignedUrl(value: string): boolean {
	if (value.length === 0 || value.length > 4_096) return false;
	try {
		const url = new URL(value);
		return url.protocol === "wss:"
			&& url.hostname === SIGNED_URL_HOST
			&& (url.port === "" || url.port === "443")
			&& url.pathname === SIGNED_URL_PATH
			&& url.search.length > 0
			&& url.username === ""
			&& url.password === ""
			&& url.hash === "";
	} catch {
		return false;
	}
}

/** Parse a bounded provider response and accept only the exact safe URL field. */
export function parseSafeElevenLabsSignedUrlResponse(body: string): string | null {
	if (body.length === 0 || new TextEncoder().encode(body).byteLength > SIGNED_URL_RESPONSE_MAX_BYTES) return null;
	try {
		const parsed = signedUrlResponseSchema.safeParse(JSON.parse(body));
		return parsed.success && isSafeElevenLabsSignedUrl(parsed.data.signed_url)
			? parsed.data.signed_url
			: null;
	} catch {
		return null;
	}
}

/** Parse a bounded WebRTC token response without logging or exposing provider fields. */
export function parseSafeElevenLabsConversationTokenResponse(body: string): string | null {
	if (body.length === 0 || new TextEncoder().encode(body).byteLength > SIGNED_URL_RESPONSE_MAX_BYTES) return null;
	try {
		const parsed = conversationTokenResponseSchema.safeParse(JSON.parse(body));
		if (!parsed.success) return null;
		const token = parsed.data.token;
		return token.trim() === token && !containsControlCharacter(token) ? token : null;
	} catch {
		return null;
	}
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function isCanonicalUuid(value: unknown): value is string {
	return typeof value === "string" && UUID_RE.test(value);
}

export function isValidTimestamp(value: unknown): value is string {
	if (typeof value !== "string" || value.length === 0 || value.trim() !== value) return false;
	const match = value.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(?:Z|[+-](\d{2}):(\d{2}))$/);
	if (!match) return false;
	const year = Number(match[1]);
	const month = Number(match[2]);
	const day = Number(match[3]);
	const hour = Number(match[4]);
	const minute = Number(match[5]);
	const second = Number(match[6]);
	const offsetHour = match[7] ? Number(match[7]) : 0;
	const offsetMinute = match[8] ? Number(match[8]) : 0;
	const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
	const daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1] ?? 0;
	if (month < 1 || month > 12 || day < 1 || day > daysInMonth) return false;
	if (hour > 23 || minute > 59 || second > 59) return false;
	if (offsetHour > 23 || offsetMinute > 59) return false;
	return Number.isFinite(Date.parse(value));
}

export type SpeedDatingOwnerState = {
	conversationLanguage: ConversationLanguage;
	ageVerified: true;
	settingsCompleted: true;
};

/**
 * Parse only the owner fields needed to authorize and localize an AI session.
 * Extra columns are ignored, so private matching and station fields cannot be
 * copied into a provider prompt by this boundary.
 */
export function readSpeedDatingOwnerState(row: unknown): SpeedDatingOwnerState | null {
	if (!row || typeof row !== "object" || Array.isArray(row)) return null;
	const record = row as Record<string, unknown>;
	const language = record.conversation_language;
	if (language !== "ja" && language !== "en") return null;
	if (!isValidTimestamp(record.age_verified_at) || !isValidTimestamp(record.onboarding_settings_completed_at)) return null;
	return { conversationLanguage: language, ageVerified: true, settingsCompleted: true };
}

export type SpeedDatingConversationBootstrap = {
	language: ConversationLanguage;
	systemPrompt: string;
	firstMessage: string;
	overrides: SpeedDatingWebOverrides;
};

export type SpeedDatingConversationBootstrapInput = {
	/** A minimally selected owner row; matching and station fields are ignored. */
	ownerRow?: unknown;
	/** A previously validated owner state, for callers that already loaded it. */
	ownerState?: SpeedDatingOwnerState | null;
	personaDocument: string;
	personaName: string;
	voiceId: string;
};

function containsControlCharacter(value: string): boolean {
	return /[\u0000-\u001f\u007f]/.test(value);
}

function buildSpeedDatingGreeting(language: ConversationLanguage, personaName: string): string {
	return language === "en"
		? `Hi! I'm ${personaName}. Nice to meet you!`
		: `はじめまして！${personaName}です。よろしくね！`;
}

/**
 * Assemble a provider-independent conversation payload from the saved owner
 * language. Persona-document language and UI locale never choose the output
 * language. Provider binding resolution is intentionally a separate step.
 */
export function buildSpeedDatingConversationBootstrap(
	input: SpeedDatingConversationBootstrapInput,
): SpeedDatingConversationBootstrap | null {
	if (!input || typeof input !== "object" || Array.isArray(input)) return null;
	const owner = input.ownerState === undefined ? readSpeedDatingOwnerState(input.ownerRow) : input.ownerState;
	if (!owner) return null;
	if (typeof input.personaDocument !== "string"
		|| input.personaDocument.length === 0
		|| input.personaDocument.length > 32_000) return null;
	if (typeof input.personaName !== "string") return null;
	const personaName = input.personaName.trim();
	if (personaName.length === 0 || personaName.length > 256 || containsControlCharacter(personaName)) return null;
	if (typeof input.voiceId !== "string") return null;
	const voiceId = input.voiceId.trim();
	if (voiceId.length === 0 || voiceId.length > MAX_BINDING_VALUE_LENGTH || containsControlCharacter(voiceId)) return null;

	const language = owner.conversationLanguage;
	const systemPrompt = buildSpeedDatingSystemPrompt(input.personaDocument, language);
	const firstMessage = buildSpeedDatingGreeting(language, personaName);
	return {
		language,
		systemPrompt,
		firstMessage,
		overrides: buildSpeedDatingWebOverrides(language, voiceId, systemPrompt, firstMessage),
	};
}

export type SpeedDatingSessionBinding = {
	id: string;
	userId: string;
	personaId: string;
	status: "active";
};

/** Validate the closed session shape before using any field in provider work. */
export function readActiveSpeedDatingSession(
	row: unknown,
	ownerId: string,
	sessionId: string,
): SpeedDatingSessionBinding | null {
	if (!row || typeof row !== "object" || Array.isArray(row) || !isCanonicalUuid(sessionId)) return null;
	const record = row as Record<string, unknown>;
	if (!isCanonicalUuid(record.id) || record.id !== sessionId || record.user_id !== ownerId || record.status !== "active") return null;
	if (!isCanonicalUuid(record.persona_id)) return null;
	return { id: sessionId, userId: ownerId, personaId: record.persona_id, status: "active" };
}

export type SpeedDatingPersonaBinding = {
	id: string;
	userId: string;
	name: string;
	compiledDocument: string;
	personaType: "virtual_similar" | "virtual_complementary" | "virtual_discovery";
};

/** Validate the exact owner-owned virtual persona attached to a session. */
export function readOwnedVirtualPersona(
	row: unknown,
	ownerId: string,
	personaId: string,
): SpeedDatingPersonaBinding | null {
	if (!row || typeof row !== "object" || Array.isArray(row) || !isCanonicalUuid(personaId)) return null;
	const record = row as Record<string, unknown>;
	if (!isCanonicalUuid(record.id) || record.id !== personaId || record.user_id !== ownerId) return null;
	if (record.persona_type !== "virtual_similar"
		&& record.persona_type !== "virtual_complementary"
		&& record.persona_type !== "virtual_discovery") return null;
	if (typeof record.name !== "string") return null;
	const name = record.name.trim();
	if (name.length === 0 || name.length > 256 || containsControlCharacter(name)) return null;
	if (typeof record.compiled_document !== "string"
		|| record.compiled_document.length === 0
		|| record.compiled_document.length > 32_000) return null;
	return {
		id: personaId,
		userId: ownerId,
		name,
		compiledDocument: record.compiled_document,
		personaType: record.persona_type,
	};
}

/** Return the public camelCase override object used by the existing Web SDK. */
export function buildSpeedDatingWebOverrides(
	language: ConversationLanguage,
	voiceId: string,
	systemPrompt: string,
	firstMessage: string,
): SpeedDatingWebOverrides {
	return {
		agent: {
			prompt: { prompt: systemPrompt },
			firstMessage,
			language,
		},
		tts: { voiceId },
	};
}

/** Read a provider response without buffering an unbounded body. */
export async function readBoundedResponseText(response: Response, maxBytes = 8_192): Promise<string | null> {
	return readBoundedResponseTextWithSignal(response, maxBytes);
}

/** Read a provider response while allowing a caller timeout to cancel it. */
export async function readBoundedResponseTextWithSignal(
	response: Response,
	maxBytes = 8_192,
	signal?: AbortSignal,
): Promise<string | null> {
	if (!response.body) return null;
	const reader = response.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	const cancelOnAbort = () => {
		void reader.cancel().catch(() => undefined);
	};
	if (signal) {
		if (signal.aborted) {
			try {
				await reader.cancel();
			} catch {
				// The reader is already aborted; treat it as an invalid body.
			}
			reader.releaseLock();
			return null;
		}
		signal.addEventListener("abort", cancelOnAbort, { once: true });
	}
	try {
		while (true) {
			const result = await reader.read();
			if (result.done) break;
			if (!(result.value instanceof Uint8Array)) return null;
			total += result.value.byteLength;
			if (total > maxBytes) {
				await reader.cancel();
				return null;
			}
			chunks.push(result.value);
		}
		const bytes = new Uint8Array(total);
		let offset = 0;
		for (const chunk of chunks) {
			bytes.set(chunk, offset);
			offset += chunk.byteLength;
		}
		return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
	} catch {
		try {
			await reader.cancel();
		} catch {
			// The response is already treated as invalid.
		}
		return null;
	} finally {
		signal?.removeEventListener("abort", cancelOnAbort);
		reader.releaseLock();
	}
}
