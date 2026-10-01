import { judgeChatComplete } from "../services/judge-chat-complete";
import { Hono, type Context } from "hono";
import judgeRealtime from "./judge-realtime";
import { isJudgeAccessActive } from "../services/judge-access";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { chatComplete } from "../services/mistral";
import { buildVirtualPersonaPrompt } from "../prompts/virtual-persona";
import { getRandomIconUrlForGender } from "../lib/fox-icons";
import { buildSpeedDatingSystemPrompt } from "../prompts/speed-dating";
import {
	buildSpeedDatingConversationBootstrap,
	ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT,
	ELEVENLABS_SIGNED_URL_ENDPOINT,
	isCanonicalUuid,
	parseSafeElevenLabsConversationTokenResponse,
	parseSafeElevenLabsSignedUrlResponse,
	readActiveSpeedDatingSession,
	readOwnedVirtualPersona,
	readSpeedDatingBinding,
	readSpeedDatingOwnerState,
	readBoundedResponseTextWithSignal,
	resolveElevenLabsLocaleBinding,
} from "../lib/speed-dating-ai";
import { z } from "zod";
import {
	buildRealtimeSession,
	parseRealtimeClientSecret,
	REALTIME_CLIENT_SECRET_START_TTL_SECONDS,
	REALTIME_SECRET_ENDPOINT,
	REALTIME_MODEL,
	realtimeVoiceSchema,
} from "../lib/openai-realtime";
import {
	RECORDING_REHEARSAL_SORA_PROFILE_ID,
	RECORDING_REHEARSAL_SORA_INTERVIEW_MIN_BOOTSTRAP_REMAINING_MS,
	isRecordingRehearsalSoraInterviewActive,
	type ValidatedRecordingRehearsalConfig,
} from "../services/recording-rehearsal";

const speedDating = new Hono<Env>();
speedDating.route("/", judgeRealtime);

async function deleteSpeedDatingMessagesBestEffort(
	supabase: ReturnType<typeof getSupabaseClient>,
	messageIds: string[],
): Promise<void> {
	let failed = false;
	for (const messageId of messageIds) {
		try {
			const { error } = await supabase.from("speed_dating_messages").delete().eq("id", messageId);
			failed ||= Boolean(error);
		} catch {
			failed = true;
		}
	}
	if (failed) console.error("[speed-dating/messages] failed to roll back partial messages");
}

const SECTION_ORDER = [
	"core_identity",
	"communication_rules",
	"personality_profile",
	"interests",
	"values",
	"constraints",
] as const;

const VIRTUAL_PERSONA_TYPES = [
	"virtual_similar",
	"virtual_complementary",
	"virtual_discovery",
] as const;

type VirtualPersonaType = (typeof VIRTUAL_PERSONA_TYPES)[number];

const INVALID_COMPLETED_SESSION_ID = Symbol("invalid completed session");

type SoraInterviewAdmissionContext = {
	rehearsal: ValidatedRecordingRehearsalConfig & NonNullable<Pick<ValidatedRecordingRehearsalConfig, "soraInterviewAdmission">>;
	admission: NonNullable<ValidatedRecordingRehearsalConfig["soraInterviewAdmission"]>;
};

function isSoraRenRecordingRequest(c: Context<Env>): boolean {
	return c.get("recording_rehearsal")?.pair === "sora-ren";
}

function readSoraInterviewAdmissionContext(c: Context<Env>): SoraInterviewAdmissionContext | null {
	const rehearsal = c.get("recording_rehearsal");
	if (c.get("user_id") !== RECORDING_REHEARSAL_SORA_PROFILE_ID
		|| c.get("production_e2e_read_only") !== true
		|| !isRecordingRehearsalSoraInterviewActive(rehearsal)) return null;
	return { rehearsal, admission: rehearsal.soraInterviewAdmission };
}

function soraInterviewAdmissionWindowArgs(context: SoraInterviewAdmissionContext, userId: string) {
	return {
		p_user_id: userId,
		p_rehearsal_expires_at: context.rehearsal.expiresAt,
		p_admission_issued_at: context.admission.issuedAt,
		p_admission_expires_at: context.admission.expiresAt,
	};
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Validate the service-role persona row before exposing it to the caller. */
function readOwnedSpeedDatingPersonaSummary(
	value: unknown,
	ownerId: string,
): {
	id: string;
	persona_type: VirtualPersonaType;
	name: string;
	compiled_document: string;
} | null {
	if (!isRecord(value)) return null;
	const personaType = value.persona_type;
	if (
		!isCanonicalUuid(value.id)
		|| value.user_id !== ownerId
		|| typeof personaType !== "string"
		|| !(VIRTUAL_PERSONA_TYPES as readonly string[]).includes(personaType)
		|| typeof value.name !== "string"
		|| typeof value.compiled_document !== "string"
	) {
		return null;
	}
	return {
		id: value.id,
		persona_type: personaType as VirtualPersonaType,
		name: value.name,
		compiled_document: value.compiled_document,
	};
}

/**
 * A completed-session lookup is already filtered by owner/persona/status, but
 * service-role results remain untrusted at this boundary. Keep an invalid row
 * distinct from an ordinary no-session result so it cannot become a false
 * nullable success.
 */
function readOwnedCompletedSessionId(
	value: unknown,
	ownerId: string,
	personaId: string,
): string | null | typeof INVALID_COMPLETED_SESSION_ID {
	if (value === null || value === undefined) return null;
	if (
		!isRecord(value)
		|| !isCanonicalUuid(value.id)
		|| value.user_id !== ownerId
		|| value.persona_id !== personaId
		|| value.status !== "completed"
	) {
		return INVALID_COMPLETED_SESSION_ID;
	}
	return value.id;
}

function readSpeedDatingPersonaSections(value: unknown): Array<{ section_id: string; title: string; content: string }> | null {
	if (!Array.isArray(value)) return null;
	const sections: Array<{ section_id: string; title: string; content: string }> = [];
	for (const section of value) {
		if (!isRecord(section) || typeof section.section_id !== "string" || typeof section.content !== "string") return null;
		sections.push({ section_id: section.section_id, title: section.section_id, content: section.content });
	}
	return sections;
}

function parsePersonaMarkdown(text: string): { name: string; gender: "male" | "female"; sections: Record<string, string> } {
	const sections: Record<string, string> = {};
	let name = "";
	let gender: "male" | "female" = "female";
	const lines = text.split("\n");
	let currentSection = "";
	let currentContent: string[] = [];

	for (const line of lines) {
		if (line.startsWith("name:")) {
			name = line.replace(/^name:\s*/, "").trim().replace(/[*_#`"'"'「」]/g, "");
			continue;
		}
		if (line.startsWith("gender:")) {
			const val = line.replace(/^gender:\s*/, "").trim().toLowerCase();
			gender = val === "male" ? "male" : "female";
			continue;
		}
		const match = line.match(/^##\s+(.+)$/);
		if (match) {
			if (currentSection) {
				sections[currentSection] = currentContent.join("\n").trim();
			}
			currentSection = match[1].trim().toLowerCase().replace(/\s+/g, "_");
			// Japanese headers
			if (currentSection === "コアアイデンティティ") currentSection = "core_identity";
			else if (currentSection === "コミュニケーションルール") currentSection = "communication_rules";
			else if (currentSection === "パーソナリティプロファイル") currentSection = "personality_profile";
			else if (currentSection === "興味・関心マップ") currentSection = "interests";
			else if (currentSection === "価値観") currentSection = "values";
			else if (currentSection === "制約事項") currentSection = "constraints";
			// English headers
			else if (currentSection === "core_identity") { /* already correct */ }
			else if (currentSection === "communication_rules") { /* already correct */ }
			else if (currentSection === "personality_profile") { /* already correct */ }
			else if (currentSection === "interests_map") currentSection = "interests";
			else if (currentSection === "values") { /* already correct */ }
			else if (currentSection === "constraints") { /* already correct */ }
			currentContent = [];
		} else {
			currentContent.push(line);
		}
	}
	if (currentSection) {
		sections[currentSection] = currentContent.join("\n").trim();
	}

	// Fallback: if the LLM embedded the name inside the core identity text
	// instead of outputting it as a separate "name:" line, try to extract it.
	if (!name && sections.core_identity) {
		const nameMatch = sections.core_identity.match(/(?:名前|name)[：:]\s*(.+?)(?:[。.、,\n]|$)/i);
		if (nameMatch?.[1]) {
			name = nameMatch[1].trim().replace(/[*_#`"'"'「」]/g, "");
		}
	}

	return { name: name || "ペルソナ", gender, sections };
}

const AI_UNAVAILABLE_MESSAGE = "AI session unavailable";
const AI_RESPONSE_UNAVAILABLE_MESSAGE = "AI response unavailable";
const OWNER_AI_COLUMNS = "conversation_language, age_verified_at, onboarding_settings_completed_at";

type PersonaGenerationFailureStage =
	| "config"
	| "owner_lookup"
	| "answers_lookup"
	| "mistral_request"
	| "persona_persist"
	| "section_persist";

type PersonaGenerationErrorKind =
	| "SDKValidationError"
	| "SDKError"
	| "HTTPValidationError"
	| "AbortError"
	| "TimeoutError"
	| "Error"
	| "unknown";

function readPersonaGenerationStatusCode(error: unknown): number | undefined {
	if (!error || typeof error !== "object") return undefined;
	const statusCode = (error as { statusCode?: unknown }).statusCode;
	return typeof statusCode === "number" && Number.isInteger(statusCode) && statusCode >= 400 && statusCode <= 599
		? statusCode
		: undefined;
}

function readPersonaGenerationErrorKind(error: unknown): PersonaGenerationErrorKind {
	if (!error || typeof error !== "object") return "unknown";
	const name = (error as { name?: unknown }).name;
	return name === "SDKValidationError" || name === "SDKError" || name === "HTTPValidationError"
		|| name === "AbortError" || name === "TimeoutError" || name === "Error"
		? name
		: "unknown";
}

function reportPersonaGenerationFailure(stage: PersonaGenerationFailureStage, error?: unknown): number | undefined {
	const statusCode = readPersonaGenerationStatusCode(error);
	const errorKind = readPersonaGenerationErrorKind(error);
	// Keep this line intentionally fixed: do not add error messages, bodies,
	// headers, keys, IDs, prompts, or model output to the diagnostic.
	console.error(`[wingward/persona-generation] stage=${stage} status=${statusCode ?? 0} kind=${errorKind}`);
	return statusCode;
}

function personaGenerationError(
	c: import("hono").Context<Env>,
	stage: PersonaGenerationFailureStage,
	message: string,
	error?: unknown,
) {
	const statusCode = reportPersonaGenerationFailure(stage, error);
	if (c.get("production_e2e_active") === true) {
		c.header("X-Wingward-E2E-Stage", stage);
		if (statusCode !== undefined) c.header("X-Wingward-E2E-Upstream-Status", String(statusCode));
	}
	return jsonError(c, "INTERNAL_ERROR", message);
}

async function loadSpeedDatingOwnerState(
	supabase: ReturnType<typeof getSupabaseClient>,
	userId: string,
	onError?: (error: unknown) => void,
): Promise<ReturnType<typeof readSpeedDatingOwnerState>> {
	const { data, error } = await supabase
		.from("user_profiles")
		.select(OWNER_AI_COLUMNS)
		.eq("id", userId)
		.maybeSingle();
	if (error || !data) {
		onError?.(error);
		return null;
	}
	return readSpeedDatingOwnerState(data);
}

/** POST /api/speed-dating/personas - generate 3 virtual personas */
speedDating.post("/personas", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const apiKey = readSpeedDatingBinding(c.env, "MISTRAL_API_KEY");
	if (!apiKey) return personaGenerationError(c, "config", AI_UNAVAILABLE_MESSAGE);
	let supabase: ReturnType<typeof getSupabaseClient>;
	try {
		supabase = getSupabaseClient(c.env);
	} catch (error) {
		return personaGenerationError(c, "owner_lookup", AI_UNAVAILABLE_MESSAGE, error);
	}

	let ownerLookupError: unknown;
	let owner: ReturnType<typeof readSpeedDatingOwnerState>;
	try {
		owner = await loadSpeedDatingOwnerState(supabase, userId, (error) => {
			ownerLookupError = error;
		});
	} catch (error) {
		return personaGenerationError(c, "owner_lookup", AI_UNAVAILABLE_MESSAGE, error);
	}
	if (!owner) {
		return personaGenerationError(c, "owner_lookup", AI_UNAVAILABLE_MESSAGE, ownerLookupError);
	}

	let answers: unknown[] | null;
	let answersError: unknown;
	try {
		const result = await supabase
			.from("quiz_answers")
			.select("question_id, selected")
			.eq("user_id", userId);
		answers = result.data;
		answersError = result.error;
	} catch (error) {
		return personaGenerationError(c, "answers_lookup", "Failed to load persona inputs", error);
	}
	if (answersError || !answers) {
		return personaGenerationError(c, "answers_lookup", "Failed to load persona inputs", answersError);
	}
	const quizSummary = JSON.stringify(answers ?? [], null, 2);

	const types = ["virtual_similar", "virtual_complementary", "virtual_discovery"] as const;
	// Recover a partially saved judging catalog without rewriting a persona
	// whose interview may already be complete. Validate owner-bound rows first.
	let existing: NonNullable<ReturnType<typeof readOwnedSpeedDatingPersonaSummary>>[] = [];
	if (c.get("judge_access")) {
		try {
			const saved = await supabase.from("personas")
				.select("id, user_id, persona_type, name, compiled_document")
				.eq("user_id", userId).in("persona_type", [...types]);
			if (saved.error || !Array.isArray(saved.data)) return personaGenerationError(c, "persona_persist", "Failed to verify saved personas");
			for (const row of saved.data) {
				const persona = readOwnedSpeedDatingPersonaSummary(row, userId);
				if (!persona || existing.some(p => p.id === persona.id || p.persona_type === persona.persona_type))
					return personaGenerationError(c, "persona_persist", "Failed to verify saved personas");
				existing.push(persona);
			}
		} catch { return personaGenerationError(c, "persona_persist", "Failed to verify saved personas"); }
	}
	const missingTypes = types.filter(type => !existing.some(p => p.persona_type === type));

	// Independent character requests run together; no provider call depends on another.
	let rawResults: { personaType: typeof types[number]; raw: string }[];
	try {
		const generate = async (personaType: typeof types[number]) => {
			const prompt = buildVirtualPersonaPrompt(quizSummary, personaType, [], owner.conversationLanguage);
			const raw = await judgeChatComplete(c, supabase, "personas_generate", apiKey, [{ role: "user", content: prompt }],
				{ maxTokens: 1500, temperature: 1.0 });
			return { personaType, raw };
		};
		if (c.get("judge_access")) {
			rawResults = [];
			for (const personaType of missingTypes) rawResults.push(await generate(personaType));
		} else rawResults = await Promise.all(types.map(generate));
	} catch (error) {
		return personaGenerationError(c, "mistral_request", AI_UNAVAILABLE_MESSAGE, error);
	}

	// Save to DB in parallel
	let persistFailure: { stage: "persona_persist" | "section_persist"; error?: unknown } | undefined;
	const recordPersistFailure = (stage: "persona_persist" | "section_persist", error?: unknown) => {
		if (!persistFailure) persistFailure = { stage, error };
	};
	const results = await Promise.all(
		rawResults.map(async ({ personaType, raw }) => {
			try {
				const { name, sections } = parsePersonaMarkdown(raw);
				// Persona icons are intentionally independent of the owner's private identity.
				const iconUrl = getRandomIconUrlForGender("");
				let persona: { id: string } | null;
				let insertErr: unknown;
				try {
					const result = await supabase
						.from("personas")
						.upsert(
							{
								user_id: userId,
								persona_type: personaType,
								name: name || personaType,
								compiled_document: raw,
								icon_url: iconUrl,
							},
							{ onConflict: "user_id,persona_type" },
						)
						.select("id")
						.single();
					persona = result.data as { id: string } | null;
					insertErr = result.error;
				} catch (error) {
					recordPersistFailure("persona_persist", error);
					return null;
				}
				if (insertErr || !persona) {
					recordPersistFailure("persona_persist", insertErr);
					return null;
				}
				let sectionResults: Array<{ error: unknown }>;
				try {
					sectionResults = await Promise.all(
						SECTION_ORDER.filter((id) => sections[id]).map((sectionId) =>
							supabase.from("persona_sections").upsert(
								{ persona_id: persona.id, section_id: sectionId, content: sections[sectionId] },
								{ onConflict: "persona_id,section_id" },
							),
						),
					);
				} catch (error) {
					recordPersistFailure("section_persist", error);
					return null;
				}
				const sectionError = sectionResults.find((result) => result.error)?.error;
				if (sectionError) {
					recordPersistFailure("section_persist", sectionError);
					return null;
				}
				return {
					id: persona.id,
					persona_type: personaType,
					name: name || personaType,
					compiled_document: raw,
					sections: SECTION_ORDER.filter((id) => sections[id]).map((id) => ({
						section_id: id, title: id, content: sections[id],
					})),
				};
			} catch (error) {
				recordPersistFailure("persona_persist", error);
				return null;
			}
		}),
	);

	if (results.some((result) => result === null)) {
		return personaGenerationError(
			c,
			persistFailure?.stage ?? "persona_persist",
			"Failed to save virtual personas",
			persistFailure?.error,
		);
	}
	return jsonData(c, [...existing.map(p => ({ ...p, sections: [] })), ...results.filter((result): result is NonNullable<typeof result> => result !== null)]);
});

/** GET /api/speed-dating/personas */
speedDating.get("/personas", requireAuth, async (c) => {
	const userId = c.get("user_id");
	let supabase: ReturnType<typeof getSupabaseClient>;
	try {
		supabase = getSupabaseClient(c.env);
	} catch {
		console.error("[speed-dating/personas] persona lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch personas");
	}
	let personaResult: { data: unknown; error: unknown };
	try {
		personaResult = await supabase
			.from("personas")
			.select("id, user_id, persona_type, name, compiled_document")
			.eq("user_id", userId)
			.in("persona_type", [...VIRTUAL_PERSONA_TYPES]);
	} catch {
		console.error("[speed-dating/personas] persona lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch personas");
	}
	const { data, error } = personaResult;
	if (error || !Array.isArray(data)) {
		console.error("[speed-dating/personas] persona lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch personas");
	}
	const personaIds = new Set<string>();
	const withSections = await Promise.all(
		(data ?? []).map(async (p) => {
			const persona = readOwnedSpeedDatingPersonaSummary(p, userId);
			if (!persona || personaIds.has(persona.id)) {
				console.error("[speed-dating/personas] persona ownership validation failed");
				return null;
			}
			personaIds.add(persona.id);
			try {
				const [sectionsResult, completedSessionResult] = await Promise.all([
					supabase
						.from("persona_sections")
						.select("section_id, content")
						.eq("persona_id", persona.id),
					supabase
						.from("speed_dating_sessions")
						.select("id, user_id, persona_id, status, completed_at")
						.eq("user_id", userId)
						.eq("persona_id", persona.id)
						.eq("status", "completed")
						.order("completed_at", { ascending: false, nullsFirst: false })
						.limit(1)
						.maybeSingle(),
				]);
				if (sectionsResult.error || !Array.isArray(sectionsResult.data)) {
					console.error("[speed-dating/personas] section read failed");
					return null;
				}
				if (completedSessionResult.error) {
					console.error("[speed-dating/personas] completed session lookup failed");
					return null;
				}
				const completedSessionId = readOwnedCompletedSessionId(
					completedSessionResult.data,
					userId,
					persona.id,
				);
				if (completedSessionId === INVALID_COMPLETED_SESSION_ID) {
					console.error("[speed-dating/personas] completed session ownership validation failed");
					return null;
				}
				const sections = readSpeedDatingPersonaSections(sectionsResult.data);
				if (!sections) {
					console.error("[speed-dating/personas] section shape validation failed");
					return null;
				}
				return { ...persona, sections, completed_session_id: completedSessionId };
			} catch {
				console.error("[speed-dating/personas] persona reads failed");
				return null;
			}
		}),
	);
	if (withSections.some((persona) => persona === null)) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to read persona sections");
	}
	return jsonData(c, withSections.filter((persona): persona is NonNullable<typeof persona> => persona !== null));
});

const postSessionSchema = z.object({ persona_id: z.string().uuid() });
const postMessageSchema = z.object({ content: z.string().min(1).max(2000) });
const soraSessionReservationRowSchema = z.discriminatedUnion("outcome", [
	z.object({
		session_id: z.string().uuid(),
		persona_id: z.string().uuid(),
		outcome: z.enum(["reserved", "already_reserved"]),
	}).strict(),
	z.object({
		session_id: z.null(),
		persona_id: z.string().uuid(),
		outcome: z.enum(["not_eligible", "conflict"]),
	}).strict(),
]);

/** POST /api/speed-dating/sessions */
speedDating.post("/sessions", requireAuth, async (c) => {
	const startedAt = Date.now();
	const userId = c.get("user_id");
	const soraInterviewAdmission = isSoraRenRecordingRequest(c) ? readSoraInterviewAdmissionContext(c) : null;
	if (isSoraRenRecordingRequest(c) && !soraInterviewAdmission) {
		return jsonError(c, "FORBIDDEN", "Voice interview is not admitted", 403);
	}
	const parsed = postSessionSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	const supabase = getSupabaseClient(c.env);
	const personaLookupStartedAt = Date.now();
	const { data: persona, error: personaError } = await supabase
		.from("personas")
		.select("id, compiled_document, name")
		.eq("id", parsed.data.persona_id)
		.eq("user_id", userId)
		.in("persona_type", ["virtual_similar", "virtual_complementary", "virtual_discovery"])
		.maybeSingle();
	const personaLookupMs = Date.now() - personaLookupStartedAt;
	if (personaError) {
		console.error("[speed-dating/sessions] persona lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify persona");
	}
	if (!persona) return jsonError(c, "NOT_FOUND", "Persona not found");
	if (soraInterviewAdmission) {
		if (!isRecordingRehearsalSoraInterviewActive(soraInterviewAdmission.rehearsal)) {
			return jsonError(c, "FORBIDDEN", "Voice interview is not admitted", 403);
		}
		let reservation: { data: unknown; error: unknown };
		try {
			reservation = await supabase.rpc("reserve_sora_recording_interview", {
				p_user_id: userId,
				p_persona_id: persona.id,
				p_rehearsal_expires_at: soraInterviewAdmission.rehearsal.expiresAt,
				p_admission_issued_at: soraInterviewAdmission.admission.issuedAt,
				p_admission_expires_at: soraInterviewAdmission.admission.expiresAt,
			});
		} catch {
			return jsonError(c, "INTERNAL_ERROR", "Failed to reserve interview", 503);
		}
		if (reservation.error || !Array.isArray(reservation.data) || reservation.data.length !== 1) {
			return jsonError(c, "INTERNAL_ERROR", "Failed to reserve interview", 503);
		}
		const reservationRow = soraSessionReservationRowSchema.safeParse(reservation.data[0]);
		if (!reservationRow.success || reservationRow.data.persona_id !== persona.id) {
			return jsonError(c, "INTERNAL_ERROR", "Failed to reserve interview", 503);
		}
		if (reservationRow.data.outcome === "not_eligible" || reservationRow.data.outcome === "conflict") {
			return jsonError(c, "CONFLICT", "Interview state changed; review the saved interview status", 409);
		}
		if (!reservationRow.data.session_id) {
			return jsonError(c, "INTERNAL_ERROR", "Failed to reserve interview", 503);
		}
		return jsonData(c, {
			session_id: reservationRow.data.session_id,
			persona: { id: persona.id, name: persona.name, personality_summary: persona.compiled_document.slice(0, 200) },
		});
	}
	const insertStartedAt = Date.now();
	const { data: session, error: sessionErr } = await supabase
		.from("speed_dating_sessions")
		.insert({ user_id: userId, persona_id: persona.id })
		.select("id")
		.single();
	const insertMs = Date.now() - insertStartedAt;
	if (sessionErr || !session) return jsonError(c, "INTERNAL_ERROR", "Failed to create session");
	const totalMs = Date.now() - startedAt;
	if (totalMs > 1000) {
		console.warn(
			`[speed-dating/sessions] slow request ${totalMs}ms (persona_lookup=${personaLookupMs}ms, insert=${insertMs}ms)`,
		);
	}
	return jsonData(c, {
		session_id: session.id,
		persona: { id: persona.id, name: persona.name, personality_summary: persona.compiled_document.slice(0, 200) },
	});
});

/** GET /api/speed-dating/sessions/:id/signed-url */
speedDating.get("/sessions/:id/signed-url", requireAuth, async (c) => {
	if (readSpeedDatingBinding(c.env, "SPEED_DATING_AI_SERVER_ACTIVATION") !== "enabled") {
		console.warn("[speed-dating/signed-url] provider path disabled");
		return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
	}
	const userId = c.get("user_id");
	const id = c.req.param("id");
	if (!isCanonicalUuid(id)) return jsonError(c, "NOT_FOUND", "Session not found");
	const supabase = getSupabaseClient(c.env);
	const owner = await loadSpeedDatingOwnerState(supabase, userId);
	if (!owner) return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
	const binding = resolveElevenLabsLocaleBinding(c.env, owner.conversationLanguage);
	if (!binding) return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);

	const { data: session, error: sessionError } = await supabase
		.from("speed_dating_sessions")
		.select("id, user_id, persona_id, status, personas(id, user_id, persona_type, name, compiled_document)")
		.eq("id", id)
		.eq("user_id", userId)
		.maybeSingle();
	if (sessionError) {
		console.error("[speed-dating/signed-url] session lookup failed");
		return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
	}
	if (!session) return jsonError(c, "NOT_FOUND", "Session not found");
	const sessionBinding = readActiveSpeedDatingSession(session, userId, id);
	if (!sessionBinding) return jsonError(c, "NOT_FOUND", "Session not found");
	const nestedPersona = Array.isArray(session.personas) ? session.personas[0] : session.personas;
	const persona = readOwnedVirtualPersona(nestedPersona, userId, sessionBinding.personaId);
	if (!persona) return jsonError(c, "NOT_FOUND", "Session not found");
	const bootstrap = buildSpeedDatingConversationBootstrap({
		ownerState: owner,
		personaDocument: persona.compiledDocument,
		personaName: persona.name,
		voiceId: binding.voiceId,
	});
	if (!bootstrap) return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);

	const url = `${ELEVENLABS_SIGNED_URL_ENDPOINT}?agent_id=${encodeURIComponent(binding.agentId)}`;
	const controller = new AbortController();
	const timeout = setTimeout(() => controller.abort(), 8_000);
	let providerResponse: Response;
	try {
		providerResponse = await fetch(url, {
			headers: { "xi-api-key": binding.apiKey },
			redirect: "manual",
			signal: controller.signal,
		});
	} catch {
		clearTimeout(timeout);
		console.warn("[speed-dating/signed-url] provider request failed");
		return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
	}
	if (!providerResponse.ok) {
		clearTimeout(timeout);
		return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
	}
	let body: string | null;
	try {
		body = await readBoundedResponseTextWithSignal(providerResponse, 8_192, controller.signal);
	} finally {
		clearTimeout(timeout);
	}
	const signedUrl = body ? parseSafeElevenLabsSignedUrlResponse(body) : null;
	if (!signedUrl) return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);

	// Settings can change while the provider request is in flight. Do not return
	// a URL or prompt assembled for the old locale after that change.
	const ownerAfter = await loadSpeedDatingOwnerState(supabase, userId);
	if (!ownerAfter || ownerAfter.conversationLanguage !== owner.conversationLanguage) {
		return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
	}
	const { data: sessionAfter, error: sessionAfterError } = await supabase
		.from("speed_dating_sessions")
		.select("id, user_id, persona_id, status")
		.eq("id", id)
		.eq("user_id", userId)
		.maybeSingle();
	if (sessionAfterError || !readActiveSpeedDatingSession(sessionAfter, userId, id)) {
		return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
	}
	return jsonData(c, {
		signed_url: signedUrl,
		overrides: bootstrap.overrides,
		persona: { name: persona.name },
	});
});

/**
 * GET /api/speed-dating/sessions/:id/native-bootstrap
 *
 * Native ElevenLabs clients use the WebRTC conversation token endpoint. This
 * route is deliberately behind the same disabled server activation gate as
 * the Web signed-URL path and never returns the provider API key.
 */
type NativeBootstrapFailureStage =
	| "binding"
	| "admission"
	| "owner_lookup"
	| "session_lookup"
	| "persona_lookup"
	| "overrides"
	| "provider_fetch"
	| "provider_status"
	| "provider_body"
	| "provider_schema"
	| "postfetch_owner"
	| "postfetch_session";

function readNativeBootstrapHttpStatus(value: unknown): number | undefined {
	const isWhitelistedHttpStatus = (status: unknown): status is number =>
		typeof status === "number"
		&& Number.isInteger(status)
		&& status >= 400
		&& status <= 599;
	if (isWhitelistedHttpStatus(value)) return value;
	try {
		if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
		const record = value as Record<string, unknown>;
		const statusCode = record.statusCode;
		if (isWhitelistedHttpStatus(statusCode)) return statusCode;
		const status = record.status;
		if (isWhitelistedHttpStatus(status)) return status;
	} catch {
		// A thrown or hostile status accessor is an invalid diagnostic value.
	}
	return undefined;
}

function reportNativeBootstrapFailure(stage: NativeBootstrapFailureStage, value?: unknown): number | undefined {
	const statusCode = readNativeBootstrapHttpStatus(value);
	// Keep this line fixed: do not add messages, names, bodies, headers, keys,
	// tokens, prompts, identifiers, or transcripts to route diagnostics.
	console.error(`[wingward/native-bootstrap] stage=${stage} status=${statusCode ?? 0}`);
	return statusCode;
}

function nativeBootstrapError(
	c: import("hono").Context<Env>,
	stage: NativeBootstrapFailureStage,
	value?: unknown,
	notFound = false,
) {
	const statusCode = reportNativeBootstrapFailure(stage, value);
	if (c.get("production_e2e_active") === true) {
		c.header("X-Wingward-E2E-Stage", stage);
		if (statusCode !== undefined) c.header("X-Wingward-E2E-Upstream-Status", String(statusCode));
	}
	return notFound
		? jsonError(c, "NOT_FOUND", "Session not found")
		: jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
}

speedDating.get("/sessions/:id/native-bootstrap", requireAuth, async (c) => {
	let stage: NativeBootstrapFailureStage = "binding";
	try {
		if (readSpeedDatingBinding(c.env, "SPEED_DATING_AI_SERVER_ACTIVATION") !== "enabled") {
			return nativeBootstrapError(c, stage);
		}

		const userId = c.get("user_id");
		const id = c.req.param("id");
		stage = "session_lookup";
		if (!isCanonicalUuid(id)) return nativeBootstrapError(c, stage, undefined, true);

		stage = "owner_lookup";
		const supabase = getSupabaseClient(c.env);
		let ownerLookupError: unknown;
		const owner = await loadSpeedDatingOwnerState(supabase, userId, (error) => {
			ownerLookupError = error;
		});
		if (!owner) return nativeBootstrapError(c, stage, ownerLookupError);

		stage = "binding";
		const binding = resolveElevenLabsLocaleBinding(c.env, owner.conversationLanguage);
		if (!binding) return nativeBootstrapError(c, stage);

		stage = "session_lookup";
		const sessionResult = await supabase
			.from("speed_dating_sessions")
			.select("id, user_id, persona_id, status, personas(id, user_id, persona_type, name, compiled_document)")
			.eq("id", id)
			.eq("user_id", userId)
			.maybeSingle();
		const session = sessionResult.data;
		const sessionError = sessionResult.error;
		if (sessionError) return nativeBootstrapError(c, stage, sessionError);
		if (!session) return nativeBootstrapError(c, stage, undefined, true);
		const sessionBinding = readActiveSpeedDatingSession(session, userId, id);
		if (!sessionBinding) return nativeBootstrapError(c, stage, undefined, true);

		stage = "persona_lookup";
		const sessionRecord = session as Record<string, unknown>;
		const nestedPersona = Array.isArray(sessionRecord.personas) ? sessionRecord.personas[0] : sessionRecord.personas;
		const persona = readOwnedVirtualPersona(nestedPersona, userId, sessionBinding.personaId);
		if (!persona) return nativeBootstrapError(c, stage, undefined, true);

		stage = "overrides";
		const bootstrap = buildSpeedDatingConversationBootstrap({
			ownerState: owner,
			personaDocument: persona.compiledDocument,
			personaName: persona.name,
			voiceId: binding.voiceId,
		});
		if (!bootstrap) return nativeBootstrapError(c, stage);

		stage = "provider_fetch";
		const url = `${ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT}?agent_id=${encodeURIComponent(binding.agentId)}`;
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), 8_000);
		let providerResponse: Response;
		let body: string | null = null;
		try {
			providerResponse = await fetch(url, {
				headers: { "xi-api-key": binding.apiKey },
				redirect: "manual",
				signal: controller.signal,
			});
			stage = "provider_status";
			if (!providerResponse.ok) {
				const statusCode = readNativeBootstrapHttpStatus(providerResponse.status);
				return nativeBootstrapError(c, stage, statusCode);
			}
			stage = "provider_body";
			body = await readBoundedResponseTextWithSignal(providerResponse, 8_192, controller.signal);
		} finally {
			clearTimeout(timeout);
		}
		if (!body) return nativeBootstrapError(c, stage);

		stage = "provider_schema";
		const conversationToken = parseSafeElevenLabsConversationTokenResponse(body);
		if (!conversationToken) return nativeBootstrapError(c, stage);

		stage = "postfetch_owner";
		let ownerAfterLookupError: unknown;
		const ownerAfter = await loadSpeedDatingOwnerState(supabase, userId, (error) => {
			ownerAfterLookupError = error;
		});
		if (!ownerAfter || ownerAfter.conversationLanguage !== owner.conversationLanguage) {
			return nativeBootstrapError(c, stage, ownerAfterLookupError);
		}

		stage = "postfetch_session";
		const sessionAfterResult = await supabase
			.from("speed_dating_sessions")
			.select("id, user_id, persona_id, status")
			.eq("id", id)
			.eq("user_id", userId)
			.maybeSingle();
		const sessionAfter = sessionAfterResult.data;
		const sessionAfterError = sessionAfterResult.error;
		const sessionAfterValid = readActiveSpeedDatingSession(sessionAfter, userId, id) !== null;
		if (sessionAfterError || !sessionAfterValid) return nativeBootstrapError(c, stage, sessionAfterError);

		if (c.get("production_e2e_active") === true) {
			console.info("[wingward/native-bootstrap] stage=ready status=200");
		}
		return jsonData(c, {
			session_id: id,
			conversation_token: conversationToken,
			overrides: bootstrap.overrides,
		});
	} catch (error) {
		return nativeBootstrapError(c, stage, error);
	}
});

function realtimeBootstrapError(...args: Parameters<typeof nativeBootstrapError>) {
  return jsonError(args[0], args[3] ? "NOT_FOUND" : "INTERNAL_ERROR",
    "Voice interview is temporarily unavailable", args[3] ? 404 : 503);
}

/** Explicitly opt-in Realtime bootstrap; never falls back to a paid provider. */
speedDating.post("/sessions/:id/realtime-bootstrap", requireAuth, async (c) => {
	c.header("Cache-Control", "no-store");
	let stage: NativeBootstrapFailureStage = "binding";
	try {
		const soraInterviewAdmission = isSoraRenRecordingRequest(c) ? readSoraInterviewAdmissionContext(c) : null;
		if (isSoraRenRecordingRequest(c) && !soraInterviewAdmission) {
			return jsonError(c, "FORBIDDEN", "Voice interview is not admitted", 403);
		}
		if (readSpeedDatingBinding(c.env, "OPENAI_REALTIME_ENABLED") !== "enabled") {
			return realtimeBootstrapError(c, stage);
		}

		const input = z.object({ voice: realtimeVoiceSchema }).strict().safeParse(await c.req.json().catch(() => null));
		if (!input.success) return jsonError(c, "BAD_REQUEST", "Invalid voice selection", 400);
		const userId = c.get("user_id");
		const id = c.req.param("id");
		stage = "session_lookup";
		if (!isCanonicalUuid(id)) return realtimeBootstrapError(c, stage, undefined, true);

		stage = "owner_lookup";
		const supabase = getSupabaseClient(c.env);
		let ownerLookupError: unknown;
		const owner = await loadSpeedDatingOwnerState(supabase, userId, (error) => {
			ownerLookupError = error;
		});
		if (!owner) return realtimeBootstrapError(c, stage, ownerLookupError);

		stage = "binding";
		const apiKey = readSpeedDatingBinding(c.env, "OPENAI_API_KEY");
		if (!apiKey) return realtimeBootstrapError(c, stage);

		stage = "session_lookup";
		const sessionResult = await supabase
			.from("speed_dating_sessions")
			.select("id, user_id, persona_id, status, personas(id, user_id, persona_type, name, compiled_document)")
			.eq("id", id)
			.eq("user_id", userId)
			.maybeSingle();
		const session = sessionResult.data;
		const sessionError = sessionResult.error;
		if (sessionError) return realtimeBootstrapError(c, stage, sessionError);
		if (!session) return realtimeBootstrapError(c, stage, undefined, true);
		const sessionBinding = readActiveSpeedDatingSession(session, userId, id);
		if (!sessionBinding) return realtimeBootstrapError(c, stage, undefined, true);

		stage = "persona_lookup";
		const sessionRecord = session as Record<string, unknown>;
		const nestedPersona = Array.isArray(sessionRecord.personas) ? sessionRecord.personas[0] : sessionRecord.personas;
		const persona = readOwnedVirtualPersona(nestedPersona, userId, sessionBinding.personaId);
		if (!persona) return realtimeBootstrapError(c, stage, undefined, true);

		stage = "overrides";
		const sessionConfig = buildRealtimeSession(persona.compiledDocument, owner.conversationLanguage, input.data.voice);
		if (sessionConfig.instructions.length > 32_000) return realtimeBootstrapError(c, stage);
		const judgeAccess = c.get("judge_access");
		if (judgeAccess) {
			if (!isJudgeAccessActive(judgeAccess) || judgeAccess.actorId !== userId || !c.env.JUDGE_REALTIME_CALLS || new TextEncoder().encode(sessionConfig.instructions).byteLength > 16_000) return realtimeBootstrapError(c, stage);
			return jsonData(c, {
				session_id: id, mode: "server_bounded", model: REALTIME_MODEL,
				expires_at: Math.floor(Math.min(Date.now() + 120_000, judgeAccess.expiresAtMs) / 1000),
				max_duration_seconds: 180,
				overrides: { agent: { prompt: { prompt: sessionConfig.instructions }, language: owner.conversationLanguage }, tts: { voiceId: input.data.voice } },
			});
		}
		// A client-secret expiry only bounds connection startup, not paid call time.
		// Ordinary accounts have no server-owned voice lease/reservation yet.
		// Keep credential issuance closed until that boundary exists; operator
		// enablement and an owned active session alone are not spend admission.
		if (!soraInterviewAdmission) return realtimeBootstrapError(c, "admission");
		if (soraInterviewAdmission) {
			stage = "admission";
			const activeWindowExpiresAtMs = Math.min(
				soraInterviewAdmission.rehearsal.expiresAtMs,
				soraInterviewAdmission.admission.expiresAtMs,
			);
			if (activeWindowExpiresAtMs - Date.now() < RECORDING_REHEARSAL_SORA_INTERVIEW_MIN_BOOTSTRAP_REMAINING_MS) {
				return jsonError(c, "FORBIDDEN", "Voice interview is not admitted", 403);
			}
			if (!isRecordingRehearsalSoraInterviewActive(soraInterviewAdmission.rehearsal)) {
				return jsonError(c, "FORBIDDEN", "Voice interview is not admitted", 403);
			}
			let tokenClaim: { data: unknown; error: unknown };
			try {
				tokenClaim = await supabase.rpc("issue_sora_recording_interview_token", {
					...soraInterviewAdmissionWindowArgs(soraInterviewAdmission, userId),
					p_session_id: id,
				});
			} catch {
				return realtimeBootstrapError(c, stage);
			}
			if (tokenClaim.error) return realtimeBootstrapError(c, stage, tokenClaim.error);
			if (tokenClaim.data !== true) return jsonError(c, "FORBIDDEN", "Voice interview is not admitted", 403);
			// The claim is consumed even if the deadline expires before the provider fetch.
			if (!isRecordingRehearsalSoraInterviewActive(soraInterviewAdmission.rehearsal)) {
				return realtimeBootstrapError(c, stage);
			}
		}
		stage = "provider_fetch";
		const controller = new AbortController();
		const timeout = setTimeout(() => controller.abort(), 8_000);
		let providerResponse: Response;
		let body: string | null = null;
		try {
			providerResponse = await fetch(REALTIME_SECRET_ENDPOINT, {
				method: "POST",
				headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
				// This bounds when the client secret can start; it does not cap active conversation time.
				body: JSON.stringify({ expires_after: { anchor: "created_at", seconds: REALTIME_CLIENT_SECRET_START_TTL_SECONDS }, session: sessionConfig }),
				redirect: "manual",
				signal: controller.signal,
			});
			stage = "provider_status";
			if (!providerResponse.ok) {
				const statusCode = readNativeBootstrapHttpStatus(providerResponse.status);
				return realtimeBootstrapError(c, stage, statusCode);
			}
			stage = "provider_body";
			body = await readBoundedResponseTextWithSignal(providerResponse, 65_536, controller.signal);
		} finally {
			clearTimeout(timeout);
		}
		if (!body) return realtimeBootstrapError(c, stage);

		stage = "provider_schema";
		const credential = parseRealtimeClientSecret(body);
		if (!credential) return realtimeBootstrapError(c, stage);

		stage = "postfetch_owner";
		let ownerAfterLookupError: unknown;
		const ownerAfter = await loadSpeedDatingOwnerState(supabase, userId, (error) => {
			ownerAfterLookupError = error;
		});
		if (!ownerAfter || ownerAfter.conversationLanguage !== owner.conversationLanguage) {
			return realtimeBootstrapError(c, stage, ownerAfterLookupError);
		}

		stage = "postfetch_session";
		const sessionAfterResult = await supabase
			.from("speed_dating_sessions")
			.select("id, user_id, persona_id, status")
			.eq("id", id)
			.eq("user_id", userId)
			.maybeSingle();
		const sessionAfter = sessionAfterResult.data;
		const sessionAfterError = sessionAfterResult.error;
		const sessionAfterValid = readActiveSpeedDatingSession(sessionAfter, userId, id)?.personaId === sessionBinding.personaId;
		if (sessionAfterError || !sessionAfterValid) return realtimeBootstrapError(c, stage, sessionAfterError);

		return jsonData(c, {
			session_id: id, ...credential, model: REALTIME_MODEL,
			overrides: { agent: { prompt: { prompt: sessionConfig.instructions }, language: owner.conversationLanguage }, tts: { voiceId: input.data.voice } },
		});
	} catch (error) {
		return realtimeBootstrapError(c, stage, error);
	}
});

/** GET /api/speed-dating/sessions/:id */
speedDating.get("/sessions/:id", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const supabase = getSupabaseClient(c.env);
	const { data: session, error } = await supabase
		.from("speed_dating_sessions")
		.select("*, personas(name)")
		.eq("id", id)
		.eq("user_id", userId)
		.maybeSingle();
	if (error) return jsonError(c, "INTERNAL_ERROR", "Failed to load session");
	if (!session) return jsonError(c, "NOT_FOUND", "Session not found");
	const { data: messages, error: messagesError } = await supabase
		.from("speed_dating_messages")
		.select("id, role, content, created_at")
		.eq("session_id", id)
		.order("created_at", { ascending: true });
	if (messagesError || !messages) return jsonError(c, "INTERNAL_ERROR", "Failed to load session messages");
	return jsonData(c, { ...session, messages: messages ?? [] });
});

/** POST /api/speed-dating/sessions/:id/messages */
speedDating.post("/sessions/:id/messages", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const parsed = postMessageSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	const supabase = getSupabaseClient(c.env);
	const apiKey = readSpeedDatingBinding(c.env, "MISTRAL_API_KEY");
	if (!apiKey) return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
	const owner = await loadSpeedDatingOwnerState(supabase, userId);
	if (!owner) return jsonError(c, "INTERNAL_ERROR", AI_UNAVAILABLE_MESSAGE);
	const { data: session, error: sessionError } = await supabase
		.from("speed_dating_sessions")
		.select("id, persona_id")
		.eq("id", id)
		.eq("user_id", userId)
		.maybeSingle();
	if (sessionError) return jsonError(c, "INTERNAL_ERROR", "Failed to load session");
	if (!session) return jsonError(c, "NOT_FOUND", "Session not found");
	const { data: persona, error: personaError } = await supabase
		.from("personas")
		.select("compiled_document")
		.eq("id", session.persona_id)
		.maybeSingle();
	if (personaError) return jsonError(c, "INTERNAL_ERROR", "Failed to load persona");
	if (!persona) return jsonError(c, "INTERNAL_ERROR", "Session persona not found");
	const userMessageId = crypto.randomUUID();
	const { error: userMessageError } = await supabase.from("speed_dating_messages").insert({
		id: userMessageId,
		session_id: id,
		role: "user",
		content: parsed.data.content,
	});
	if (userMessageError) return jsonError(c, "INTERNAL_ERROR", "Failed to save message");
	const { data: history, error: historyError } = await supabase
		.from("speed_dating_messages")
		.select("role, content")
		.eq("session_id", id)
		.order("created_at", { ascending: true });
	if (historyError || !history) {
		await deleteSpeedDatingMessagesBestEffort(supabase, [userMessageId]);
		return jsonError(c, "INTERNAL_ERROR", "Failed to load message history");
	}
	const messagesForAi = (history ?? []).map((m) => ({
		role: m.role === "user" ? "user" as const : "assistant" as const,
		content: m.content,
	}));
	let personaContent = owner.conversationLanguage === "en" ? "(Failed to generate response)" : "（応答を生成できませんでした）";
	try {
		const systemPrompt = buildSpeedDatingSystemPrompt(persona.compiled_document, owner.conversationLanguage);
		personaContent = await chatComplete(apiKey, [
			{ role: "system", content: systemPrompt },
			...messagesForAi,
		], { maxTokens: 512 });
	} catch {
		await deleteSpeedDatingMessagesBestEffort(supabase, [userMessageId]);
		return jsonError(c, "INTERNAL_ERROR", AI_RESPONSE_UNAVAILABLE_MESSAGE);
	}
	const { data: personaMsg, error: personaMessageError } = await supabase
		.from("speed_dating_messages")
		.insert({ session_id: id, role: "persona", content: personaContent })
		.select("id, role, content, created_at")
		.single();
	if (personaMessageError || !personaMsg) {
		await deleteSpeedDatingMessagesBestEffort(supabase, [userMessageId]);
		return jsonError(c, "INTERNAL_ERROR", "Failed to save persona message");
	}
	const { data: countRow, error: countError } = await supabase
		.from("speed_dating_sessions")
		.select("message_count")
		.eq("id", id)
		.maybeSingle();
	if (countError || !countRow) {
		await deleteSpeedDatingMessagesBestEffort(supabase, [userMessageId, personaMsg.id]);
		return jsonError(c, "INTERNAL_ERROR", "Failed to load message count");
	}
	const count = (countRow?.message_count ?? 0) + 2;
	const { error: countUpdateError } = await supabase
		.from("speed_dating_sessions")
		.update({ message_count: count })
		.eq("id", id);
	if (countUpdateError) {
		await deleteSpeedDatingMessagesBestEffort(supabase, [userMessageId, personaMsg.id]);
		return jsonError(c, "INTERNAL_ERROR", "Failed to update message count");
	}
	return jsonData(c, {
		user_message: { id: userMessageId, role: "user", content: parsed.data.content, created_at: new Date().toISOString() },
		persona_message: personaMsg,
		message_count: count,
	});
});

const completeSessionTranscriptEntrySchema = z
	.object({
		source: z.enum(["user", "ai"]),
		message: z.string().min(1).max(2000).refine((value) => value.trim().length > 0),
	})
	.strict();

const completeSessionSchema = z
	.object({
		transcript: z.array(completeSessionTranscriptEntrySchema).min(1).max(200).optional(),
	})
	.strict();

const completeSessionRpcRowSchema = z.object({
	session_id: z.string().uuid().nullable(),
	status: z.string().nullable(),
	message_count: z.number().int().nonnegative().nullable(),
	all_sessions_completed: z.boolean(),
	outcome: z.enum(["stored", "already_completed", "not_found", "invalid_input", "invalid_state", "conflict"]),
});

/** POST /api/speed-dating/sessions/:id/complete */
speedDating.post("/sessions/:id/complete", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const soraInterviewAdmission = isSoraRenRecordingRequest(c) ? readSoraInterviewAdmissionContext(c) : null;
	if (isSoraRenRecordingRequest(c) && !soraInterviewAdmission) {
		return jsonError(c, "FORBIDDEN", "Voice interview is not admitted", 403);
	}
	if (!isCanonicalUuid(id)) return jsonError(c, "NOT_FOUND", "Session not found");
	let body: unknown = {};
	try {
		const rawBody = await c.req.text();
		if (rawBody.trim().length > 0) body = JSON.parse(rawBody) as unknown;
	} catch {
		return jsonError(c, "BAD_REQUEST", "Invalid completion payload");
	}
	const parsed = completeSessionSchema.safeParse(body);
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", "Invalid completion payload");
	const transcript = parsed.data.transcript;
	const supabase = getSupabaseClient(c.env);
	let rpcResult: { data: unknown; error: unknown };
	try {
		if (soraInterviewAdmission) {
			if (!isRecordingRehearsalSoraInterviewActive(soraInterviewAdmission.rehearsal)) {
				return jsonError(c, "FORBIDDEN", "Voice interview is not admitted", 403);
			}
			if (!transcript
				|| !transcript.some((entry) => entry.source === "user")
				|| !transcript.some((entry) => entry.source === "ai")) {
				return jsonError(c, "BAD_REQUEST", "Interview transcript must include both speakers");
			}
			rpcResult = await supabase.rpc("complete_sora_recording_interview", {
				p_session_id: id,
				...soraInterviewAdmissionWindowArgs(soraInterviewAdmission, userId),
				p_transcript: transcript ?? null,
			});
		} else {
			rpcResult = await supabase.rpc("complete_speed_dating_session", {
				p_session_id: id,
				p_user_id: userId,
				p_transcript: transcript ?? null,
			});
		}
	} catch {
		return jsonError(c, "INTERNAL_ERROR", "Failed to complete session");
	}
	if (rpcResult.error || !Array.isArray(rpcResult.data) || rpcResult.data.length !== 1) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to complete session");
	}
	const completion = completeSessionRpcRowSchema.safeParse(rpcResult.data[0]);
	if (!completion.success) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to complete session");
	}
	switch (completion.data.outcome) {
		case "not_found":
			return jsonError(c, "NOT_FOUND", "Session not found");
		case "invalid_input":
			return jsonError(c, "BAD_REQUEST", "Invalid completion payload");
		case "conflict":
			return jsonError(c, "CONFLICT", "Session completion conflicts with saved transcript");
		case "invalid_state":
			return jsonError(c, "CONFLICT", "Session cannot be completed");
		case "stored":
		case "already_completed":
			if (
				completion.data.session_id !== id
				|| completion.data.status !== "completed"
				|| completion.data.message_count === null
			) {
				return jsonError(c, "INTERNAL_ERROR", "Failed to complete session");
			}
			return jsonData(c, {
				session_id: completion.data.session_id,
				status: completion.data.status,
				all_sessions_completed: completion.data.all_sessions_completed,
			});
	}
});

export default speedDating;
