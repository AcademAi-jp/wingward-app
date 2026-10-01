import { judgeChatComplete } from "../services/judge-chat-complete";
import { dispatchJudgeVoice, readJudgeVoiceBody, stopJudgeVoice } from "./judge-realtime";
import { isJudgeAccessActive } from "../services/judge-access";
import { Hono } from "hono";
import { z } from "zod";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import {
	buildMeetupReflectionRealtimeSession,
	createMeetupReflectionService,
	createMistralReflectionDraftProvider,
	type ReflectionProviderRehearsalGuard,
	type ReflectionLocale,
	type ReflectionStore,
} from "../services/meetup-reflection";
import { parseRealtimeClientSecret, REALTIME_MODEL, REALTIME_SECRET_ENDPOINT, realtimeVoiceSchema } from "../lib/openai-realtime";
import {
	isRecordingRehearsalMeetupReady,
	reserveRecordingRehearsalReflectionAttempt,
} from "../services/meetup-reflection-recording-window";
import {
	isRecordingRehearsalActive,
	isRecordingRehearsalGenerationProfile,
	type ValidatedRecordingRehearsalConfig,
} from "../services/recording-rehearsal";

import { checkSyntheticRecordingAdmission, recordingAdmissionRpc } from "../services/synthetic-recording-admission";

type RpcClient = {
	rpc(functionName: string, args: Record<string, unknown>): Promise<{ data: unknown; error: unknown }>;
};

type Query = {
	select(columns?: string): Query;
	eq(column: string, value: unknown): Query;
	maybeSingle(): Promise<{ data: unknown; error: unknown }>;
};

type ReflectionBindings = Env["Bindings"] & {
	CHAT_MEETUP_ENABLED?: string;
	MEETUP_REFLECTION_REALTIME_ENABLED?: string;
	MEETUP_REFLECTION_DRAFTS_ENABLED?: string;
};

const meetupIdSchema = z.string().uuid();
const bootstrapBodySchema = z.object({ voice: realtimeVoiceSchema }).strict();
const draftsBodySchema = z.object({ statements: z.unknown() }).strict();

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function makeStore(supabase: ReturnType<typeof getSupabaseClient>, config?: ValidatedRecordingRehearsalConfig): ReflectionStore {
	const rpc = supabase as unknown as RpcClient;
	return {
		async readState(userId, meetupId) {
			const admission = config?.syntheticTestAdmissionId ? await checkSyntheticRecordingAdmission(rpc, config, userId, { meetupId }) : undefined;
			if (config?.syntheticTestAdmissionId && !admission) return { data: null, error: "Synthetic test admission unavailable" };
			return recordingAdmissionRpc(rpc, "get_meetup_reflection_state", {
				p_meetup_id: meetupId,
				p_user_id: userId,
			}, admission ?? undefined);
		},
		async confirm(input) {
			const admission = config?.syntheticTestAdmissionId ? await checkSyntheticRecordingAdmission(rpc, config, input.userId, { meetupId: input.meetupId }) : undefined;
			if (config?.syntheticTestAdmissionId && !admission) return { data: null, error: "Synthetic test admission unavailable" };
			return recordingAdmissionRpc(rpc, "confirm_meetup_reflection", {
				p_meetup_id: input.meetupId,
				p_user_id: input.userId,
				p_idempotency_key: input.idempotencyKey,
				p_expected_version: input.expectedVersion,
				p_traits: input.traits,
			}, admission ?? undefined);
		},
	};
}

function privateData(c: Parameters<typeof jsonData>[0], data: unknown, status = 200) {
	c.header("Cache-Control", "private, no-store");
	return jsonData(c, data, status);
}

function privateError(
	c: Parameters<typeof jsonError>[0],
	code: Parameters<typeof jsonError>[1],
	message: string,
	status?: number,
) {
	c.header("Cache-Control", "private, no-store");
	return jsonError(c, code, message, status);
}

function resultError(c: Parameters<typeof jsonError>[0], reason: string) {
	if (reason === "bad_request") return privateError(c, "BAD_REQUEST", "Invalid reflection request", 400);
	if (reason === "not_found") return privateError(c, "NOT_FOUND", "Meetup reflection not found");
	if (reason === "conflict") return privateError(c, "CONFLICT", "Reflection changed; review the latest version and try again");
	if (reason === "unavailable") return privateError(c, "INTERNAL_ERROR", "Meetup reflection is temporarily unavailable", 503);
	return privateError(c, "INTERNAL_ERROR", "Meetup reflection is temporarily unavailable", 503);
}

async function readBoundedJson(
	c: Parameters<typeof privateData>[0],
	maxBytes: number,
	stillActive: () => boolean = () => true,
): Promise<unknown | null> {
	const reader = c.req.raw.body?.getReader();
	if (!reader) return null;
	const chunks: Uint8Array[] = [];
	let size = 0;
	try {
		while (true) {
			const part = await reader.read();
			if (!stillActive()) {
				void reader.cancel().catch(() => {});
				return null;
			}
			if (part.done) break;
			size += part.value.byteLength;
			if (size > maxBytes) {
				await reader.cancel();
				return null;
			}
			chunks.push(part.value);
		}
		const bytes = new Uint8Array(size);
		let offset = 0;
		for (const chunk of chunks) {
			bytes.set(chunk, offset);
			offset += chunk.byteLength;
		}
		return JSON.parse(new TextDecoder().decode(bytes)) as unknown;
	} catch {
		return null;
	}
}

async function readOwnerContext(
	supabase: ReturnType<typeof getSupabaseClient>,
	userId: string,
	stillActive: () => boolean = () => true,
): Promise<{ language: ReflectionLocale; personaDocument: string } | null> {
	try {
		const profileQuery = supabase
			.from("user_profiles")
			.select("id, conversation_language")
			.eq("id", userId) as unknown as Query;
		const profileResult = await profileQuery.maybeSingle();
		if (!stillActive()) return null;
		if (profileResult.error || !isRecord(profileResult.data) || profileResult.data.id !== userId) return null;
		const language = profileResult.data.conversation_language;
		if (language !== "ja" && language !== "en") return null;

		const personaQuery = supabase
			.from("personas")
			.select("id, user_id, persona_type, compiled_document")
			.eq("user_id", userId)
			.eq("persona_type", "wingfox") as unknown as Query;
		const personaResult = await personaQuery.maybeSingle();
		if (!stillActive()) return null;
		if (
			personaResult.error
			|| !isRecord(personaResult.data)
			|| personaResult.data.user_id !== userId
			|| personaResult.data.persona_type !== "wingfox"
			|| typeof personaResult.data.compiled_document !== "string"
			|| personaResult.data.compiled_document.length > 16_000
		) {
			return null;
		}
		return { language, personaDocument: personaResult.data.compiled_document };
	} catch {
		return null;
	}
}

async function readBoundedResponseText(
	response: Response,
	maxBytes: number,
	signal: AbortSignal,
	stillActive: () => boolean = () => true,
): Promise<string | null> {
	const reader = response.body?.getReader();
	if (!reader) return null;
	const chunks: Uint8Array[] = [];
	let size = 0;
	try {
		while (true) {
			if (!stillActive()) {
				void reader.cancel().catch(() => {});
				return null;
			}
			if (signal.aborted) {
				await reader.cancel();
				return null;
			}
			const part = await reader.read();
			if (!stillActive()) {
				void reader.cancel().catch(() => {});
				return null;
			}
			if (part.done) break;
			size += part.value.byteLength;
			if (size > maxBytes) {
				await reader.cancel();
				return null;
			}
			chunks.push(part.value);
		}
		const bytes = new Uint8Array(size);
		let offset = 0;
		for (const chunk of chunks) {
			bytes.set(chunk, offset);
			offset += chunk.byteLength;
		}
		return new TextDecoder().decode(bytes);
	} catch {
		return null;
	}
}

async function createRealtimeCredential(
	apiKey: string,
	language: ReflectionLocale,
	voice: "cedar" | "marin" | "ash",
	personaDocument: string,
	confirmedTraits: Record<string, string>,
	rehearsalGuard?: ReflectionProviderRehearsalGuard,
): Promise<{ client_secret: string; expires_at: number; prompt: string } | null> {
	const session = buildMeetupReflectionRealtimeSession(language, voice, personaDocument, confirmedTraits);
	const instructionBytes = new TextEncoder().encode(session.instructions).byteLength;
	if (rehearsalGuard ? instructionBytes > 8_192 : session.instructions.length > 32_000) return null;
	const requestBody = JSON.stringify({
		expires_after: { anchor: "created_at", seconds: 120 },
		session,
	});
	const controller = new AbortController();
	const timeout = setTimeout(() => controller.abort(), 8_000);
	try {
		if (rehearsalGuard) {
			if (!rehearsalGuard.isActive()) return null;
			if (rehearsalGuard.beforeAttempt) {
				const allowed = await rehearsalGuard.beforeAttempt();
				if (!allowed || !rehearsalGuard.isActive()) return null;
			}
			if (!rehearsalGuard.isActive() || !rehearsalGuard.reserveAttempt()) return null;
		}
		const response = await fetch(REALTIME_SECRET_ENDPOINT, {
			method: "POST",
			headers: { Authorization: "Bearer " + apiKey, "Content-Type": "application/json" },
			body: requestBody,
			redirect: "manual",
			signal: controller.signal,
		});
		if (rehearsalGuard && !rehearsalGuard.isActive()) {
			void response.body?.cancel().catch(() => {});
			return null;
		}
		if (!response.ok) return null;
		const body = await readBoundedResponseText(
			response,
			65_536,
			controller.signal,
			rehearsalGuard ? rehearsalGuard.isActive : undefined,
		);
		if (!body || (rehearsalGuard && !rehearsalGuard.isActive())) return null;
		const credential = parseRealtimeClientSecret(body);
		if (rehearsalGuard && !rehearsalGuard.isActive()) return null;
		return credential ? { ...credential, prompt: session.instructions } : null;
	} catch {
		return null;
	} finally {
		clearTimeout(timeout);
	}
}

async function rehearsalMeetupReady(
	supabase: ReturnType<typeof getSupabaseClient>,
	userId: string,
	meetupId: string,
	config: ValidatedRecordingRehearsalConfig,
	stillActive: () => boolean,
): Promise<boolean> {
	if (!stillActive() || !isRecordingRehearsalGenerationProfile(config, userId)) return false;
	if (config.syntheticTestAdmissionId && !await checkSyntheticRecordingAdmission(supabase as unknown as RpcClient, config, userId, { meetupId })) return false;
	try {
		const query = supabase
			.from("chat_meetup_sessions")
			.select("meetup_id, match_id, room_id, user_a_id, user_b_id, status, confirmed_ends_at, completed_a_at, completed_b_at")
			.eq("meetup_id", meetupId) as unknown as Query;
		const result = await query.maybeSingle();
		if (!stillActive()) return false;
		return !result.error && isRecordingRehearsalMeetupReady(config, meetupId, userId, result.data);
	} catch {
		return false;
	}
}

function isRehearsalWindowActive(config: ValidatedRecordingRehearsalConfig | undefined): boolean {
	return config === undefined || isRecordingRehearsalActive(config);
}

const meetupReflections = new Hono<Env>();

function reflectionFeatureEnabled(env: Env["Bindings"]): boolean {
	return (env as ReflectionBindings).CHAT_MEETUP_ENABLED === "enabled";
}

meetupReflections.get("/:meetupId", requireAuth, async (c) => {
	if (!reflectionFeatureEnabled(c.env)) return resultError(c, "unavailable");
	const meetupId = c.req.param("meetupId");
	if (!meetupIdSchema.safeParse(meetupId).success) {
		return privateError(c, "NOT_FOUND", "Meetup reflection not found");
	}
	const userId = c.get("user_id");
	const service = createMeetupReflectionService(makeStore(getSupabaseClient(c.env), c.get("recording_rehearsal")), null);
	const result = await service.readState(userId, meetupId);
	if (!result.ok) return resultError(c, result.reason);
	const judge = c.get("judge_access");
	if (judge) {
		if (judge.actorId !== userId || !isJudgeAccessActive(judge)) return resultError(c, "not_found");
		type PairQuery = { select(columns: string): PairQuery; eq(column: string, value: string): PairQuery; maybeSingle(): Promise<{ data: unknown; error: unknown }> };
		const pairClient = getSupabaseClient(c.env) as unknown as { from(table: "chat_meetup_sessions"): PairQuery };
		const pair = await pairClient.from("chat_meetup_sessions")
			.select("user_a_id,user_b_id").eq("meetup_id", meetupId).maybeSingle();
		const identity = z.object({ user_a_id: z.string().uuid(), user_b_id: z.string().uuid() }).safeParse(pair.data);
		if (pair.error || !identity.success || !isJudgeAccessActive(judge)
			|| !((identity.data.user_a_id === userId && identity.data.user_b_id === judge.counterpartId)
				|| (identity.data.user_b_id === userId && identity.data.user_a_id === judge.counterpartId))) return resultError(c, "not_found");
		return privateData(c, { ...result.data, simulated_counterpart: true });
	}
	return privateData(c, result.data);
});

meetupReflections.post("/:meetupId/realtime-call", requireAuth, async (c) => {
 c.header("Cache-Control", "no-store");
 try {
  const access=c.get("judge_access"),meetupId=c.req.param("meetupId");
  if(!isJudgeAccessActive(access) || access.actorId!==c.get("user_id") || !reflectionFeatureEnabled(c.env)
    || c.env.MEETUP_REFLECTION_REALTIME_ENABLED!=="enabled" || !c.env.JUDGE_REALTIME_CALLS) return resultError(c,"unavailable");
  if(!meetupIdSchema.safeParse(meetupId).success) return resultError(c,"not_found");
  const input=await readJudgeVoiceBody(c);if(!input)return privateError(c,"BAD_REQUEST","Invalid reflection connection",400);
  const db=getSupabaseClient(c.env),service=createMeetupReflectionService(makeStore(db),null);
  const state=await service.readState(access.actorId,meetupId);if(!state.ok)return resultError(c,state.reason);
  const owner=await readOwnerContext(db,access.actorId,()=>isJudgeAccessActive(access));if(!owner)return resultError(c,"unavailable");
  return dispatchJudgeVoice(c,meetupId,"reflection",{sdp:input.sdp,voice:input.voice,language:owner.language,personaDocument:owner.personaDocument,confirmedTraits:state.data.confirmed_traits});
 }catch{return resultError(c,"unavailable");}
});
meetupReflections.post("/:meetupId/realtime-stop",requireAuth,async c=>{
 try{return await stopJudgeVoice(c,c.req.param("meetupId"),"reflection");}catch{return resultError(c,"unavailable");}
});
meetupReflections.post("/:meetupId/bootstrap", requireAuth, async (c) => {
	if (!reflectionFeatureEnabled(c.env)) return resultError(c, "unavailable");
	const rehearsal = c.get("recording_rehearsal");
	const stillActive = () => isRehearsalWindowActive(rehearsal);
	if (!stillActive()) return resultError(c, "unavailable");
	const meetupId = c.req.param("meetupId");
	if (!meetupIdSchema.safeParse(meetupId).success) {
		return privateError(c, "NOT_FOUND", "Meetup reflection not found");
	}
	const body = await readBoundedJson(c, 4_096, stillActive);
	if (!stillActive()) return resultError(c, "unavailable");
	const parsedBody = bootstrapBodySchema.safeParse(body);
	if (!parsedBody.success) return privateError(c, "BAD_REQUEST", "Invalid reflection request", 400);

	const userId = c.get("user_id");
	if (rehearsal && !isRecordingRehearsalGenerationProfile(rehearsal, userId)) {
		return resultError(c, "unavailable");
	}
	const supabase = getSupabaseClient(c.env);
	const service = createMeetupReflectionService(makeStore(supabase, rehearsal), null);
	const before = await service.readState(userId, meetupId);
	if (!stillActive()) return resultError(c, "unavailable");
	if (!before.ok) return resultError(c, before.reason);

	const bindings = c.env as ReflectionBindings;
	const apiKey = bindings.OPENAI_API_KEY;
	if (bindings.MEETUP_REFLECTION_REALTIME_ENABLED !== "enabled" || !apiKey?.trim()) {
		return resultError(c, "unavailable");
	}
	if (rehearsal && !await rehearsalMeetupReady(supabase, userId, meetupId, rehearsal, stillActive)) {
		return resultError(c, "unavailable");
	}
	if (!stillActive()) return resultError(c, "unavailable");

	const owner = await readOwnerContext(supabase, userId, stillActive);
	if (!stillActive() || !owner) return resultError(c, "unavailable");
	if (rehearsal && owner.language !== "en") return resultError(c, "unavailable");
	const judgeAccess = c.get("judge_access");
	if (judgeAccess) {
		if (!isJudgeAccessActive(judgeAccess) || judgeAccess.actorId !== userId || !c.env.JUDGE_REALTIME_CALLS) return resultError(c, "unavailable");
		const session = buildMeetupReflectionRealtimeSession(owner.language, parsedBody.data.voice, owner.personaDocument, before.data.confirmed_traits);
		if (new TextEncoder().encode(session.instructions).byteLength > 16_000) return resultError(c, "unavailable");
		return privateData(c, {
			session_id: meetupId, mode: "server_bounded", model: REALTIME_MODEL,
			expires_at: Math.floor(Math.min(Date.now() + 120_000, judgeAccess.expiresAtMs) / 1000),
			max_duration_seconds: 180,
			overrides: { agent: { prompt: { prompt: session.instructions }, firstMessage: owner.language === "ja" ? "おつかれさま。今の気持ちを少し振り返ってみようか？" : "How are you feeling after meeting? We can reflect together.", language: owner.language }, tts: { voiceId: parsedBody.data.voice } },
		});
	}
	const providerGuard: ReflectionProviderRehearsalGuard | undefined = rehearsal
		? {
				isActive: stillActive,
				reserveAttempt: () => reserveRecordingRehearsalReflectionAttempt(rehearsal, "voice"),
				beforeAttempt: () => rehearsalMeetupReady(supabase, userId, meetupId, rehearsal, stillActive),
			}
		: undefined;
	const credential = await createRealtimeCredential(
		apiKey,
		owner.language,
		parsedBody.data.voice,
		owner.personaDocument,
		before.data.confirmed_traits,
		providerGuard,
	);
	if (!stillActive() || !credential) return resultError(c, "unavailable");

	const after = await service.readState(userId, meetupId);
	if (!stillActive()) return resultError(c, "unavailable");
	if (
		!after.ok
		|| after.data.current_persona_version !== before.data.current_persona_version
	) {
		return resultError(c, after.ok ? "conflict" : after.reason);
	}
	if (rehearsal) {
		const sessionStillReady = await rehearsalMeetupReady(supabase, userId, meetupId, rehearsal, stillActive);
		if (!stillActive() || !sessionStillReady) return resultError(c, "unavailable");
	}

	const { prompt, ...credentialData } = credential;
	return privateData(c, {
		session_id: crypto.randomUUID(),
		...credentialData,
		model: REALTIME_MODEL,
		overrides: {
			agent: {
				prompt: { prompt },
				firstMessage: owner.language === "ja" ? "おつかれさま。今の気持ちを少し振り返ってみようか？" : "How are you feeling after meeting? We can reflect together.",
				language: owner.language,
			},
			tts: { voiceId: parsedBody.data.voice },
		},
	});
});
meetupReflections.post("/:meetupId/drafts", requireAuth, async (c) => {
	if (!reflectionFeatureEnabled(c.env)) return resultError(c, "unavailable");
	const rehearsal = c.get("recording_rehearsal");
	const stillActive = () => isRehearsalWindowActive(rehearsal);
	if (!stillActive()) return resultError(c, "unavailable");
	const meetupId = c.req.param("meetupId");
	if (!meetupIdSchema.safeParse(meetupId).success) {
		return privateError(c, "NOT_FOUND", "Meetup reflection not found");
	}
	const body = await readBoundedJson(c, 16_384, stillActive);
	if (!stillActive()) return resultError(c, "unavailable");
	const parsedBody = draftsBodySchema.safeParse(body);
	if (!parsedBody.success) return privateError(c, "BAD_REQUEST", "Invalid reflection request", 400);

	const userId = c.get("user_id");
	if (rehearsal && !isRecordingRehearsalGenerationProfile(rehearsal, userId)) {
		return resultError(c, "unavailable");
	}
	const supabase = getSupabaseClient(c.env);
	const store = makeStore(supabase, rehearsal);
	const service = createMeetupReflectionService(store, null);
	const before = await service.readState(userId, meetupId);
	if (!stillActive()) return resultError(c, "unavailable");
	if (!before.ok) return resultError(c, before.reason);

	if (rehearsal && !await rehearsalMeetupReady(supabase, userId, meetupId, rehearsal, stillActive)) {
		return resultError(c, "unavailable");
	}
	if (!stillActive()) return resultError(c, "unavailable");
	const bindings = c.env as ReflectionBindings;
	const mistralApiKey = bindings.MISTRAL_API_KEY;
	if (bindings.MEETUP_REFLECTION_DRAFTS_ENABLED !== "enabled" || !mistralApiKey?.trim()) {
		return resultError(c, "unavailable");
	}
	const owner = await readOwnerContext(supabase, userId, stillActive);
	if (!stillActive() || !owner) return resultError(c, "unavailable");
	if (rehearsal && owner.language !== "en") return resultError(c, "unavailable");

	const draftGuard: ReflectionProviderRehearsalGuard | undefined = rehearsal
		? {
				isActive: stillActive,
				reserveAttempt: () => reserveRecordingRehearsalReflectionAttempt(rehearsal, "draft"),
				beforeAttempt: () => rehearsalMeetupReady(supabase, userId, meetupId, rehearsal, stillActive),
			}
		: undefined;
	const draftService = createMeetupReflectionService(
		store,
		createMistralReflectionDraftProvider(mistralApiKey, draftGuard, (key, messages, options) => judgeChatComplete(c, supabase, "reflection_draft", key, messages, options)),
	);
	const result = await draftService.createDraft(
		userId,
		meetupId,
		owner.language,
		parsedBody.data.statements,
		rehearsal ? { isActive: stillActive } : undefined,
	);
	if (!stillActive()) return resultError(c, "unavailable");
	if (!result.ok) return resultError(c, result.reason);
	if (rehearsal) {
		const sessionStillReady = await rehearsalMeetupReady(supabase, userId, meetupId, rehearsal, stillActive);
		if (!stillActive() || !sessionStillReady) return resultError(c, "unavailable");
	}
	return privateData(c, result.data);
});

meetupReflections.post("/:meetupId/confirm", requireAuth, async (c) => {
	if (!reflectionFeatureEnabled(c.env)) return resultError(c, "unavailable");
	const meetupId = c.req.param("meetupId");
	if (!meetupIdSchema.safeParse(meetupId).success) {
		return privateError(c, "NOT_FOUND", "Meetup reflection not found");
	}
	const body = await readBoundedJson(c, 16_384);
	const userId = c.get("user_id");
	const service = createMeetupReflectionService(makeStore(getSupabaseClient(c.env), c.get("recording_rehearsal")), null);
	const result = await service.confirm(userId, meetupId, body);
	if (!result.ok) return resultError(c, result.reason);
	return privateData(c, {
		version: result.data.version,
		confirmed_at: result.data.confirmed_at,
		confirmed_traits: result.data.traits,
		replayed: result.data.replayed,
	});
});

export default meetupReflections;
