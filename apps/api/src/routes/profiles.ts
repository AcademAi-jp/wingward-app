import { isJudgeAccessActive } from "../services/judge-access";
import { judgeChatComplete } from "../services/judge-chat-complete";
import { Hono } from "hono";
import type { Env } from "../env";
import type { Database, Json } from "../db/types";
import { getSupabaseClient } from "../db/client";
import { requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { hasRecordingRehearsalConfig, isRecordingRehearsalActive, isRecordingRehearsalGenerationProfile, isRecordingRehearsalProfile, readRecordingRehearsalConfig, type ValidatedRecordingRehearsalConfig } from "../services/recording-rehearsal";
import { isCanonicalUuid } from "../lib/speed-dating-ai";
import { isInterviewGenerationWaiverActive } from "../lib/profile-generation-waiver";
import { generationError } from "../lib/generation-diagnostics";
import { chatCompleteOnceBounded, MISTRAL_LARGE } from "../services/mistral";
import { buildProfileGenerationPrompt } from "../prompts/profile-generation";
import { executeMatching } from "../services/matching";
import { prepareInteractionDnaFromFrozenSessions, scorePreparedInteractionDna, scoreInteractionDna } from "../services/interaction-dna";
import { loadSoraProfileRevisionInputs, SORA_PROFILE_REVISION_MAX_QUIZ_BYTES, SORA_PROFILE_REVISION_MAX_TRANSCRIPT_BYTES } from "../services/sora-profile-revision-inputs";
import { z } from "zod";
import { REFLECTION_TRAIT_VALUES } from "../services/meetup-reflection";

const profiles = new Hono<Env>();
const MIN_COMPLETED_SESSIONS = 3;
const WAIVER_COMPLETED_SESSIONS = 2;
const MIN_CONVERSATION_MESSAGES = 12;
const PROFILE_AI_UNAVAILABLE_MESSAGE = "AI profile generation unavailable";
const GENERATION_STATE_UNAVAILABLE_MESSAGE = "Generation state unavailable";
const GENERATION_EARLY_STAGES = new Set(["not_started", "quiz_completed", "speed_dating_completed"]);
const GENERATION_STAGES = new Set([
	"not_started",
	"quiz_completed",
	"speed_dating_completed",
	"profile_generated",
	"persona_generated",
	"confirmed",
]);
const PROFILE_STATES = new Set(["draft", "confirmed"]);
const EXPECTED_WINGFOX_SECTIONS = [
	"core_identity",
	"communication_rules",
	"personality_profile",
	"interests",
	"values",
	"romance_style",
	"conversation_references",
	"constraints",
] as const;
const SORA_PROFILE_REVISION_MAX_PROMPT_BYTES = 24_000;
const SORA_PROFILE_REVISION_MAX_REQUEST_BYTES = 26_000;
const SORA_PROFILE_REVISION_MAX_RESPONSE_BYTES = 64_000;
const ProfileScore = z.number().finite().min(0).max(1);
const BoundedProfileText = z.string().max(500);
const SoraRevisionProfileSchema = z.object({
	basic_info: z.object({
		age_range: z.string().max(40),
		location: z.string().max(160),
		occupation: z.string().max(160),
	}).strict(),
	personality_tags: z.array(z.string().min(1).max(100)).min(3).max(5),
	personality_analysis: z.object({
		introvert_extrovert: ProfileScore,
		planned_spontaneous: ProfileScore,
		logical_emotional: ProfileScore,
	}).strict(),
	interaction_style: z.object({
		warmup_speed: ProfileScore,
		humor_responsiveness: ProfileScore,
		self_disclosure_depth: ProfileScore,
		emotional_responsiveness: ProfileScore,
		conflict_style: z.enum(["yields", "maintains", "dialogue", "avoids"]),
		attachment_tendency: z.enum(["anxious", "avoidant", "secure"]),
		rhythm_preference: z.enum(["slow", "moderate", "fast"]),
		mirroring_tendency: ProfileScore,
	}).strict(),
	interests: z.array(z.object({
		category: z.string().min(1).max(100),
		items: z.array(z.string().min(1).max(120)).max(12),
	}).strict()).max(20),
	values: z.record(ProfileScore).refine((value) => Object.keys(value).length <= 20),
	romance_style: z.object({
		communication_frequency: BoundedProfileText,
		ideal_relationship: BoundedProfileText,
		dealbreakers: z.array(z.string().max(160)).max(20),
		preferred_partner_type: z.string().max(80),
	}).strict(),
	communication_style: z.object({
		message_length: z.string().max(40),
		question_ratio: ProfileScore,
		humor_level: ProfileScore,
		empathy_level: ProfileScore,
		topic_preferences: z.array(z.string().max(120)).max(20),
	}).strict(),
	lifestyle: z.object({
		weekend_activities: z.array(z.string().max(120)).max(20),
		diet: BoundedProfileText,
		exercise: BoundedProfileText,
	}).strict(),
}).strict();

const INVALID_GENERATION_STATE_ROW = Symbol("invalid generation state row");

type GenerationState = {
	user_id: string;
	profile_generated: boolean;
	wingfox_generated: boolean;
	profile_confirmed: boolean;
	required_interview_count: number;
	interview_waiver_active: boolean;
};

function isObjectRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function generationStateError(c: import("hono").Context<Env>, marker: string) {
	// Keep diagnostics fixed: no database/vendor messages, IDs, prompts, or
	// generated profile content are included in logs or responses.
	console.error(`[profiles/generation-state] ${marker}`);
	return jsonError(c, "INTERNAL_ERROR", GENERATION_STATE_UNAVAILABLE_MESSAGE);
}

function readGenerationStateOwner(
	value: unknown,
	ownerId: string,
): { id: string; onboarding_status: string } | typeof INVALID_GENERATION_STATE_ROW {
	if (!isObjectRecord(value) || value.id !== ownerId || typeof value.onboarding_status !== "string") {
		return INVALID_GENERATION_STATE_ROW;
	}
	if (!GENERATION_STAGES.has(value.onboarding_status)) return INVALID_GENERATION_STATE_ROW;
	return { id: ownerId, onboarding_status: value.onboarding_status };
}

function readGenerationStateProfile(
	value: unknown,
	ownerId: string,
): { id: string; user_id: string; status: string } | null | typeof INVALID_GENERATION_STATE_ROW {
	if (value === null || value === undefined) return null;
	if (
		!isObjectRecord(value)
		|| !isCanonicalUuid(value.id)
		|| value.user_id !== ownerId
		|| typeof value.status !== "string"
		|| !PROFILE_STATES.has(value.status)
	) {
		return INVALID_GENERATION_STATE_ROW;
	}
	return { id: value.id, user_id: ownerId, status: value.status };
}

function readGenerationStateWingfox(
	value: unknown,
	ownerId: string,
): { id: string; user_id: string; persona_type: "wingfox" } | null | typeof INVALID_GENERATION_STATE_ROW {
	if (value === null || value === undefined) return null;
	if (
		!isObjectRecord(value)
		|| !isCanonicalUuid(value.id)
		|| value.user_id !== ownerId
		|| value.persona_type !== "wingfox"
	) {
		return INVALID_GENERATION_STATE_ROW;
	}
	return { id: value.id, user_id: ownerId, persona_type: "wingfox" };
}

function hasCompleteWingfoxSections(value: unknown): boolean {
	if (!Array.isArray(value)) return false;
	const contentBySection = new Map<string, string>();
	for (const row of value) {
		if (!isObjectRecord(row) || typeof row.section_id !== "string" || typeof row.content !== "string") return false;
		if (contentBySection.has(row.section_id)) return false;
		contentBySection.set(row.section_id, row.content);
	}
	return EXPECTED_WINGFOX_SECTIONS.every((sectionId) => {
		const content = contentBySection.get(sectionId);
		return content !== undefined && content.trim().length > 0;
	});
}

function isSoraRecordingDraftRecovery(config: ValidatedRecordingRehearsalConfig | undefined, userId: string): boolean {
	return isRecordingRehearsalActive(config)
		&& config.pair === "sora-ren"
		&& config.generationPair[0] === userId;
}

async function readThreeDistinctCompletedInterviews(
	supabase: ReturnType<typeof getSupabaseClient>,
	userId: string,
): Promise<boolean | null> {
	try {
		const { data, error } = await supabase.from("speed_dating_sessions")
			.select("id, user_id, persona_id, status")
			.eq("user_id", userId)
			.eq("status", "completed");
		if (error || !Array.isArray(data)) return null;
		const personaIds = new Set<string>();
		for (const row of data) {
			if (!isObjectRecord(row)
				|| !isCanonicalUuid(row.id)
				|| row.user_id !== userId
				|| !isCanonicalUuid(row.persona_id)
				|| row.status !== "completed") return null;
			personaIds.add(row.persona_id);
		}
		return personaIds.size >= MIN_COMPLETED_SESSIONS;
	} catch {
		return null;
	}
}

function emptyGenerationState(
	userId: string,
	requiredInterviewCount: number,
	interviewWaiverActive: boolean,
): GenerationState {
	return {
		user_id: userId,
		profile_generated: false,
		wingfox_generated: false,
		profile_confirmed: false,
		required_interview_count: requiredInterviewCount,
		interview_waiver_active: interviewWaiverActive,
	};
}

function detectLangFromHeader(c: { req: { header: (name: string) => string | undefined } }): "ja" | "en" {
	const accept = c.req.header("accept-language") ?? "";
	return accept.startsWith("en") ? "en" : "ja";
}

type ProfileConfirmationAwait<T> = { ok: true; value: T } | { ok: false };

async function awaitProfileConfirmation<T>(
	config: ValidatedRecordingRehearsalConfig | undefined,
	operation: () => PromiseLike<T> | T,
): Promise<ProfileConfirmationAwait<T>> {
	if (config && !isRecordingRehearsalActive(config)) return { ok: false };
	try {
		const value = await operation();
		return config && !isRecordingRehearsalActive(config) ? { ok: false } : { ok: true, value };
	} catch (error) {
		if (config && !isRecordingRehearsalActive(config)) return { ok: false };
		throw error;
	}
}

function recordingConfirmationUnavailable(c: import("hono").Context<Env>) {
	c.header("Cache-Control", "private, no-store");
	return jsonError(c, "INTERNAL_ERROR", "Profile confirmation unavailable", 503);
}

async function generateSoraThreeInterviewProfileRevision(
	c: import("hono").Context<Env>,
	supabase: ReturnType<typeof getSupabaseClient>,
	userId: string,
	apiKey: string,
	config: ValidatedRecordingRehearsalConfig,
) {
	if (!isRecordingRehearsalActive(config) || config.pair !== "sora-ren"
		|| userId !== config.generationPair[0]
		|| c.env.RECORDING_REHEARSAL_OWNER_PREP_ONLY !== "enabled"
		|| c.env.RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED !== "enabled") {
		return jsonError(c, "CONFLICT", "Profile revision unavailable");
	}
	const reportFailure = (
		step: "input" | "claim" | "profile_request" | "profile_json" | "profile_schema"
			| "dna_request_or_validation" | "candidate_serialization" | "candidate_size" | "complete" | "read",
		stage: Parameters<typeof generationError>[1],
		message: string,
	) => {
		console.error(`[wingward/profile-revision] failure_step=${step}`);
		if (c.get("production_e2e_active") === true) {
			c.header("X-Wingward-Profile-Revision-Failure-Step", step);
		}
		return generationError(c, stage, message);
	};
	const expired = (step: "after_claim" | "after_profile" | "before_complete") => {
		console.error(`[wingward/profile-revision] failure_step=${step} reason=window_expired`);
		if (c.get("production_e2e_active") === true) {
			c.header("X-Wingward-Profile-Revision-Failure-Step", step);
		}
		return jsonError(c, "CONFLICT", "Profile revision window expired");
	};
	let prompt: string;
	let preparedDna: ReturnType<typeof prepareInteractionDnaFromFrozenSessions>;
	let inputs: Awaited<ReturnType<typeof loadSoraProfileRevisionInputs>>;
	try {
		inputs = await loadSoraProfileRevisionInputs(supabase, userId);
		prompt = buildProfileGenerationPrompt(inputs.quizText, inputs.conversationLogs, "en");
		if (new TextEncoder().encode(inputs.quizText).byteLength > SORA_PROFILE_REVISION_MAX_QUIZ_BYTES
			|| new TextEncoder().encode(inputs.conversationLogs).byteLength > SORA_PROFILE_REVISION_MAX_TRANSCRIPT_BYTES
			|| new TextEncoder().encode(prompt).byteLength > SORA_PROFILE_REVISION_MAX_PROMPT_BYTES) {
			throw new Error("Profile revision prompt exceeded its configured byte limits");
		}
		preparedDna = prepareInteractionDnaFromFrozenSessions(inputs.sessions, "en");
	} catch {
		return reportFailure("input", "profile_input", PROFILE_AI_UNAVAILABLE_MESSAGE);
	}
	// Freeze the exact three-session set before the first billable call. A claimed
	// run is never reclaimed, even when either model call or the save later fails.
	let claim: Awaited<ReturnType<typeof supabase.rpc<"claim_sora_three_interview_profile_revision">>>;
	try {
		claim = await supabase.rpc("claim_sora_three_interview_profile_revision", {
			p_user_id: userId,
			p_rehearsal_expires_at: config.expiresAt,
		});
	} catch {
		return reportFailure("claim", "profile_input", "Profile revision unavailable");
	}
	const claimRow = claim.data?.[0];
	const sourceProfileId = claimRow?.source_profile_id;
	const sourceVersion = claimRow?.source_version;
	if (claim.error || !claimRow) return reportFailure("claim", "profile_input", "Profile revision unavailable");
	if (claimRow.outcome !== "claimed" || typeof sourceProfileId !== "string" || !isCanonicalUuid(sourceProfileId)
		|| !Number.isSafeInteger(sourceVersion) || !Array.isArray(claimRow.session_ids)
		|| claimRow.session_ids.length !== 3
		|| claimRow.session_ids.some((id, index) => id !== inputs.sessionIds[index])) {
		return jsonError(c, "CONFLICT", "Profile revision unavailable");
	}
	if (!isRecordingRehearsalActive(config)) return expired("after_claim");

	let profileOutput: string;
	try {
		const response = await chatCompleteOnceBounded(apiKey, [{ role: "user", content: prompt }], {
			model: MISTRAL_LARGE,
			maxTokens: 1500,
			responseFormat: { type: "json_object" },
			maxRequestBytes: SORA_PROFILE_REVISION_MAX_REQUEST_BYTES,
			maxResponseBytes: SORA_PROFILE_REVISION_MAX_RESPONSE_BYTES,
		});
		profileOutput = response.content;
	} catch {
		return reportFailure("profile_request", "profile_model", PROFILE_AI_UNAVAILABLE_MESSAGE);
	}
	let profileValue: unknown;
	try {
		profileValue = JSON.parse(profileOutput.trim());
	} catch {
		return reportFailure("profile_json", "profile_model", "Failed to parse generated profile JSON");
	}
	const parsedProfile = SoraRevisionProfileSchema.safeParse(profileValue);
	if (!parsedProfile.success) {
		return reportFailure("profile_schema", "profile_model", "Generated profile did not match the required schema");
	}
	if (!isRecordingRehearsalActive(config)) return expired("after_profile");

	let dnaResult: Awaited<ReturnType<typeof scorePreparedInteractionDna>>;
	try {
		dnaResult = await scorePreparedInteractionDna(preparedDna, apiKey);
	} catch {
		return reportFailure("dna_request_or_validation", "profile_model", PROFILE_AI_UNAVAILABLE_MESSAGE);
	}
	const candidate = {
		basic_info: parsedProfile.data.basic_info,
		personality_tags: parsedProfile.data.personality_tags,
		personality_analysis: parsedProfile.data.personality_analysis,
		interaction_style: dnaResult.interactionStyle,
		interests: parsedProfile.data.interests,
		values: parsedProfile.data.values,
		romance_style: parsedProfile.data.romance_style,
		communication_style: parsedProfile.data.communication_style,
		lifestyle: parsedProfile.data.lifestyle,
	};
	let candidateText: string;
	try {
		candidateText = JSON.stringify(candidate);
	} catch {
		return reportFailure("candidate_serialization", "profile_model", "Generated profile could not be serialized");
	}
	if (new TextEncoder().encode(candidateText).byteLength > 55_000) {
		return reportFailure("candidate_size", "profile_model", "Generated profile exceeded its output limit");
	}
	if (!isRecordingRehearsalActive(config)) return expired("before_complete");
	let saved: Awaited<ReturnType<typeof supabase.rpc<"complete_sora_three_interview_profile_revision">>>;
	try {
		saved = await supabase.rpc("complete_sora_three_interview_profile_revision", {
			p_user_id: userId,
			p_rehearsal_expires_at: config.expiresAt,
			p_source_profile_id: sourceProfileId,
			p_source_version: sourceVersion!,
			p_candidate: candidate as unknown as Json,
		});
	} catch {
		return reportFailure("complete", "profile_save", "Failed to save revised profile");
	}
	if (saved.error || saved.data?.[0]?.outcome !== "saved") {
		return reportFailure("complete", "profile_save", "Failed to save revised profile");
	}
	const { data, error } = await supabase.from("profiles").select("*").eq("user_id", userId).single();
	if (error || !data) return reportFailure("read", "profile_read", "Failed to read revised profile");
	return jsonData(c, data);
}

/** POST /api/profiles/generate */
profiles.post("/generate", requireAuth, async (c) => {
	const userId = c.get("user_id");
	// Sora already has a saved draft. Recording recovery must never regenerate
	// and upsert over it, even if a future route configuration permits POST.
	const soraRevision = isSoraRecordingDraftRecovery(c.get("recording_rehearsal"), userId)
		&& c.env.RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED === "enabled"
		&& c.env.RECORDING_REHEARSAL_OWNER_PREP_ONLY === "enabled";
	if (isSoraRecordingDraftRecovery(c.get("recording_rehearsal"), userId) && !soraRevision) {
		return jsonError(c, "CONFLICT", "Review the existing profile draft");
	}
	const interviewWaiverActive = isInterviewGenerationWaiverActive(
		c.env,
		userId,
		c.get("production_e2e_active"),
	);
	const minimumCompletedSessions = interviewWaiverActive ? WAIVER_COMPLETED_SESSIONS : MIN_COMPLETED_SESSIONS;
	let lang = detectLangFromHeader(c);
	const apiKey = c.env.MISTRAL_API_KEY;
	if (typeof apiKey !== "string" || !apiKey.trim()) {
		return generationError(c, "profile_input", PROFILE_AI_UNAVAILABLE_MESSAGE);
	}
	let supabase: ReturnType<typeof getSupabaseClient>;
	try {
		supabase = getSupabaseClient(c.env);
	} catch (error) {
		return generationError(c, "profile_input", PROFILE_AI_UNAVAILABLE_MESSAGE, error);
	}
	if (soraRevision) {
		const config = c.get("recording_rehearsal");
		if (!config) return jsonError(c, "CONFLICT", "Profile revision unavailable");
		return generateSoraThreeInterviewProfileRevision(c, supabase, userId, apiKey, config);
	}
	let answersResult: { data: unknown; error: unknown };
	try {
		answersResult = await supabase
			.from("quiz_answers")
			.select("question_id, selected")
			.eq("user_id", userId);
	} catch (error) {
		return generationError(c, "profile_input", "Failed to load profile inputs", error);
	}
	const { data: answers, error: answersError } = answersResult;
	if (answersError) {
		return generationError(c, "profile_input", "Failed to load profile inputs", answersError);
	}
	if (!Array.isArray(answers)) {
		return generationError(c, "profile_input", "Failed to load profile inputs");
	}
	let sessionsResult: { data: Array<{ id: string; completed_at: string | null; persona_id?: unknown }> | null; error: unknown };
	try {
		sessionsResult = await supabase
			.from("speed_dating_sessions")
			.select("id, persona_id, completed_at")
			.eq("user_id", userId)
			.eq("status", "completed")
			.order("completed_at", { ascending: false, nullsFirst: false })
			.limit(3);
	} catch (error) {
		return generationError(c, "profile_input", "Failed to load profile inputs", error);
	}
	const { data: sessions, error: sessionsError } = sessionsResult;
	if (sessionsError) {
		return generationError(c, "profile_input", "Failed to load profile inputs", sessionsError);
	}
	if (!Array.isArray(sessions)) {
		return generationError(c, "profile_input", "Failed to load profile inputs");
	}
	if (sessions.some((session) => !session || typeof session !== "object" || typeof session.id !== "string" || session.id.length === 0)) {
		return generationError(c, "profile_input", "Failed to load profile inputs");
	}
	if ((sessions ?? []).length < minimumCompletedSessions) {
		return jsonError(c, "CONFLICT", "Not enough completed speed-dating sessions");
	}
	if (interviewWaiverActive) {
		const distinctPersonaIDs = new Set<string>();
		for (const session of sessions) {
			if (typeof session.persona_id !== "string" || !isCanonicalUuid(session.persona_id)) {
				return generationError(c, "profile_input", "Failed to load profile inputs");
			}
			distinctPersonaIDs.add(session.persona_id);
		}
		if (distinctPersonaIDs.size < minimumCompletedSessions) {
			return jsonError(c, "CONFLICT", "Not enough completed speed-dating sessions");
		}
	}
	const sessionIds = (sessions ?? []).map((s) => s.id);
	let conversationLogs = "";
	let totalMessages = 0;
	for (const sid of sessionIds) {
		let messagesResult: { data: Array<{ role: string; content: string }> | null; error: unknown };
		try {
			messagesResult = await supabase
				.from("speed_dating_messages")
				.select("role, content")
				.eq("session_id", sid)
				.order("created_at", { ascending: true });
		} catch (error) {
			return generationError(c, "profile_input", "Failed to load profile inputs", error);
		}
		const { data: msgs, error: messagesError } = messagesResult;
		if (messagesError) {
			return generationError(c, "profile_input", "Failed to load profile inputs", messagesError);
		}
		if (!Array.isArray(msgs)) {
			return generationError(c, "profile_input", "Failed to load profile inputs");
		}
		if (msgs.some((message) => !message || typeof message !== "object" || typeof message.role !== "string" || typeof message.content !== "string")) {
			return generationError(c, "profile_input", "Failed to load profile inputs");
		}
		conversationLogs += `--- Session ${sid} ---\n`;
		for (const m of msgs ?? []) {
			conversationLogs += `${m.role}: ${m.content}\n`;
			totalMessages += 1;
		}
	}
	if (totalMessages < MIN_CONVERSATION_MESSAGES) {
		return jsonError(c, "CONFLICT", "Not enough conversation data to generate profile");
	}
	// The temporary path is single-use for an already persisted draft. Keep the
	// regular edit/regeneration behavior unchanged for every other account.
	if (interviewWaiverActive) {
		let existingGenerationResult: { data: unknown; error: unknown };
		try {
			existingGenerationResult = await supabase
				.from("profiles")
				.select("id, status")
				.eq("user_id", userId)
				.maybeSingle();
		} catch (error) {
			return generationError(c, "profile_input", "Failed to load profile inputs", error);
		}
		if (existingGenerationResult.error) {
			return generationError(c, "profile_input", "Failed to load profile inputs", existingGenerationResult.error);
		}
		if (isObjectRecord(existingGenerationResult.data) &&
			(existingGenerationResult.data.status === "draft" || existingGenerationResult.data.status === "confirmed")) {
			return jsonError(c, "CONFLICT", "Profile already generated");
		}
	}
	// Native clients may omit Accept-Language or send the device language.
	// Generated display text must follow the authenticated owner's preference.
	try {
		const { data: owner, error } = await supabase.from("user_profiles")
			.select("ui_locale, conversation_language, language").eq("id", userId).single();
		if (error || !owner) return generationError(c, "profile_input", "Failed to load profile language");
		const preferred = owner.ui_locale ?? owner.conversation_language ?? owner.language;
		if (preferred !== undefined && preferred !== null) {
			if (preferred !== "ja" && preferred !== "en") return generationError(c, "profile_input", "Invalid profile language");
			lang = preferred;
		}
	} catch {
		return generationError(c, "profile_input", "Failed to load profile language");
	}
	let quizText: string;
	try {
		quizText = JSON.stringify(answers, null, 2);
	} catch (error) {
		return generationError(c, "profile_input", PROFILE_AI_UNAVAILABLE_MESSAGE, error);
	}
	let prompt: string;
	try {
		prompt = buildProfileGenerationPrompt(quizText, conversationLogs, lang);
	} catch (error) {
		return generationError(c, "profile_input", PROFILE_AI_UNAVAILABLE_MESSAGE, error);
	}
	let raw: string;
	try {
		raw = await judgeChatComplete(c, supabase, "profile_generate", apiKey, [{ role: "user", content: prompt }], {
			model: MISTRAL_LARGE,
			maxTokens: 1500,
			responseFormat: { type: "json_object" },
		});
	} catch (error) {
		return generationError(c, "profile_model", PROFILE_AI_UNAVAILABLE_MESSAGE, error);
	}
	let profileDataValue: unknown;
	try {
		profileDataValue = JSON.parse(raw.trim());
	} catch (_) {
		return generationError(c, "profile_model", "Failed to parse generated profile JSON");
	}
	if (profileDataValue === null || typeof profileDataValue !== "object" || Array.isArray(profileDataValue)) {
		return generationError(c, "profile_model", "Failed to parse generated profile JSON");
	}
	const profileData = profileDataValue as Record<string, unknown>;
	if (Object.keys(profileData).length === 0) {
		return generationError(c, "profile_model", "Generated profile is empty");
	}
	let existingResult: { data: { version?: unknown } | null; error: unknown };
	try {
		existingResult = await supabase
			.from("profiles")
			.select("id, version")
			.eq("user_id", userId)
			.maybeSingle();
	} catch (error) {
		return generationError(c, "profile_save", "Failed to load existing profile", error);
	}
	const { data: existing, error: existingError } = existingResult;
	if (existingError) {
		return generationError(c, "profile_save", "Failed to load existing profile", existingError);
	}
	const existingVersion = existing?.version;
	if (
		existingVersion !== undefined
		&& existingVersion !== null
		&& (typeof existingVersion !== "number" || !Number.isInteger(existingVersion) || existingVersion < 0)
	) {
		return generationError(c, "profile_save", "Failed to load existing profile");
	}
	const version = existingVersion === undefined || existingVersion === null ? 1 : (existingVersion as number) + 1;
	let profileResult: { data: unknown; error: unknown };
	try {
		profileResult = await supabase
			.from("profiles")
			.upsert(
				{
					user_id: userId,
					basic_info: profileData.basic_info ?? {},
					personality_tags: profileData.personality_tags ?? [],
					personality_analysis: profileData.personality_analysis ?? {},
					interaction_style: (profileData.interaction_style ?? {}) as Json,
					interests: profileData.interests ?? [],
					values: profileData.values ?? {},
					romance_style: profileData.romance_style ?? {},
					communication_style: profileData.communication_style ?? {},
					lifestyle: profileData.lifestyle ?? {},
					status: "draft",
					version,
					updated_at: new Date().toISOString(),
				} as Database["public"]["Tables"]["profiles"]["Insert"],
				{ onConflict: "user_id" },
			)
			.select()
			.single();
	} catch (error) {
		return generationError(c, "profile_save", "Failed to save profile", error);
	}
	const { data: profile, error } = profileResult;
	if (error || !profile) {
		return generationError(c, "profile_save", "Failed to save profile", error);
	}

	// DNA scoring: analyze all 3 speed dating transcripts for 13 psychological features.
	// Non-fatal — if it fails, the basic profile is still saved above.
	try {
		const dnaResult = await scoreInteractionDna(supabase, userId, apiKey, lang, (key, messages, options) => judgeChatComplete(c, supabase, "profile_generate", key, messages, options));
		if (dnaResult) {
			const { error: dnaUpdateError } = await supabase
				.from("profiles")
				.update({
					interaction_style: dnaResult.interactionStyle as Json,
					updated_at: new Date().toISOString(),
				})
				.eq("user_id", userId);
			if (dnaUpdateError) {
				console.error("[profiles/generate] DNA profile update failed (non-fatal)");
			}
		}
	} catch {
		console.error("[profiles/generate] DNA scoring failed (non-fatal)");
	}

	let onboardingResult: { error: unknown };
	try {
		onboardingResult = await supabase
			.from("user_profiles")
			.update({ onboarding_status: "profile_generated", updated_at: new Date().toISOString() })
			.eq("id", userId);
	} catch (error) {
		return generationError(c, "profile_save", "Failed to update onboarding status", error);
	}
	const { error: onboardingError } = onboardingResult;
	if (onboardingError) {
		return generationError(c, "profile_save", "Failed to update onboarding status", onboardingError);
	}

	// Re-fetch profile to include DNA scoring results
	let updatedProfileResult: { data: unknown; error: unknown };
	try {
		updatedProfileResult = await supabase
			.from("profiles")
			.select("*")
			.eq("user_id", userId)
			.single();
	} catch (error) {
		return generationError(c, "profile_read", "Failed to read saved profile", error);
	}
	const { data: updatedProfile, error: updatedProfileError } = updatedProfileResult;
	if (updatedProfileError || !updatedProfile) {
		return generationError(c, "profile_read", "Failed to read saved profile", updatedProfileError);
	}
	return jsonData(c, updatedProfile);
});

/** GET /api/profiles/me/generation-state */
profiles.get("/me/generation-state", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const interviewWaiverActive = isInterviewGenerationWaiverActive(
		c.env,
		userId,
		c.get("production_e2e_active"),
	);
	const requiredInterviewCount = interviewWaiverActive ? WAIVER_COMPLETED_SESSIONS : MIN_COMPLETED_SESSIONS;
	let supabase: ReturnType<typeof getSupabaseClient>;
	try {
		supabase = getSupabaseClient(c.env);
	} catch {
		return generationStateError(c, "client lookup failed");
	}

	let ownerResult: { data: unknown; error: unknown };
	try {
		ownerResult = await supabase
			.from("user_profiles")
			.select("id, onboarding_status")
			.eq("id", userId)
			.maybeSingle();
	} catch {
		return generationStateError(c, "owner lookup failed");
	}
	if (ownerResult.error) return generationStateError(c, "owner lookup failed");
	const owner = readGenerationStateOwner(ownerResult.data, userId);
	if (owner === INVALID_GENERATION_STATE_ROW) return generationStateError(c, "owner state validation failed");

	let profileResult: { data: unknown; error: unknown };
	try {
		profileResult = await supabase
			.from("profiles")
			.select("id, user_id, status")
			.eq("user_id", userId)
			.maybeSingle();
	} catch {
		return generationStateError(c, "profile lookup failed");
	}
	if (profileResult.error) return generationStateError(c, "profile lookup failed");
	const profile = readGenerationStateProfile(profileResult.data, userId);
	if (profile === INVALID_GENERATION_STATE_ROW) return generationStateError(c, "profile state validation failed");

	const recordingConfig = c.get("recording_rehearsal");
	if (profile && isSoraRecordingDraftRecovery(recordingConfig, userId)
		&& (GENERATION_EARLY_STAGES.has(owner.onboarding_status)
			|| owner.onboarding_status === "profile_generated")) {
		if (profile.status !== "draft") return generationStateError(c, "Sora draft state inconsistent");
		const completed = await readThreeDistinctCompletedInterviews(supabase, userId);
		if (completed === null) return generationStateError(c, "interview state lookup failed");
		if (completed) {
			const { data: wingfoxRow, error: wingfoxError } = await supabase.from("personas")
				.select("id, user_id, persona_type")
				.eq("user_id", userId)
				.eq("persona_type", "wingfox")
				.maybeSingle();
			if (wingfoxError) return generationStateError(c, "Wing Fox lookup failed");
			const wingfox = readGenerationStateWingfox(wingfoxRow, userId);
			if (!wingfox || wingfox === INVALID_GENERATION_STATE_ROW) return generationStateError(c, "Wing Fox state invalid");
			const { data: sections, error: sectionsError } = await supabase.from("persona_sections")
				.select("section_id, content")
				.eq("persona_id", wingfox.id);
			if (sectionsError || !hasCompleteWingfoxSections(sections)) return generationStateError(c, "Wing Fox sections invalid");
			if (!isRecordingRehearsalActive(recordingConfig)) return generationStateError(c, "recording window expired");
			let revisionFields: { profile_revision_status?: "available" | "claimed" | "completed"; can_regenerate_from_three?: boolean } = {};
			if (c.env.RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED === "enabled"
				&& c.env.RECORDING_REHEARSAL_OWNER_PREP_ONLY === "enabled") {
				let revisionState: Awaited<ReturnType<typeof supabase.rpc<"read_sora_three_interview_profile_revision_state">>>;
				try {
					revisionState = await supabase.rpc("read_sora_three_interview_profile_revision_state", {
						p_user_id: userId, p_rehearsal_expires_at: recordingConfig.expiresAt,
					});
				} catch {
					return generationStateError(c, "profile revision state lookup failed");
				}
				const state = revisionState.data?.[0]?.outcome;
				if (revisionState.error || (state !== "available" && state !== "claimed" && state !== "completed")) {
					return generationStateError(c, "profile revision state validation failed");
				}
				revisionFields = { profile_revision_status: state, can_regenerate_from_three: state === "available" };
			}
			return jsonData(c, {
				user_id: userId,
				profile_generated: true,
				wingfox_generated: true,
				profile_confirmed: false,
				required_interview_count: MIN_COMPLETED_SESSIONS,
				interview_waiver_active: false,
				...revisionFields,
			});
		}
		if (owner.onboarding_status === "speed_dating_completed" || owner.onboarding_status === "profile_generated") {
			return generationStateError(c, "completed interview state inconsistent");
		}
	}
	if (GENERATION_EARLY_STAGES.has(owner.onboarding_status)) {
		if (profile && profile.status !== "draft") return generationStateError(c, "early profile state inconsistent");
		return jsonData(c, emptyGenerationState(userId, requiredInterviewCount, interviewWaiverActive));
	}
	if (!profile) return generationStateError(c, "generated profile missing");

	if (owner.onboarding_status === "profile_generated") {
		if (profile.status !== "draft") return generationStateError(c, "profile-generated state inconsistent");
		return jsonData(c, {
			...emptyGenerationState(userId, requiredInterviewCount, interviewWaiverActive),
			profile_generated: true,
		});
	}

	let wingfoxResult: { data: unknown; error: unknown };
	try {
		wingfoxResult = await supabase
			.from("personas")
			.select("id, user_id, persona_type")
			.eq("user_id", userId)
			.eq("persona_type", "wingfox")
			.maybeSingle();
	} catch {
		return generationStateError(c, "Wing Fox lookup failed");
	}
	if (wingfoxResult.error) return generationStateError(c, "Wing Fox lookup failed");
	const wingfox = readGenerationStateWingfox(wingfoxResult.data, userId);
	if (wingfox === INVALID_GENERATION_STATE_ROW) return generationStateError(c, "Wing Fox state validation failed");
	if (!wingfox) return generationStateError(c, "Wing Fox state missing");

	let sectionResult: { data: unknown; error: unknown };
	try {
		sectionResult = await supabase
			.from("persona_sections")
			.select("section_id, content")
			.eq("persona_id", wingfox.id);
	} catch {
		return generationStateError(c, "Wing Fox section lookup failed");
	}
	if (sectionResult.error) return generationStateError(c, "Wing Fox section lookup failed");
	if (!hasCompleteWingfoxSections(sectionResult.data)) {
		return generationStateError(c, "Wing Fox sections incomplete");
	}

	if (owner.onboarding_status === "persona_generated") {
		if (profile.status !== "draft") return generationStateError(c, "Persona-generated state inconsistent");
		return jsonData(c, {
			user_id: userId,
			profile_generated: true,
			wingfox_generated: true,
			profile_confirmed: false,
			required_interview_count: requiredInterviewCount,
			interview_waiver_active: interviewWaiverActive,
		});
	}
	if (owner.onboarding_status === "confirmed") {
		if (profile.status !== "confirmed") return generationStateError(c, "Confirmed profile state inconsistent");
		return jsonData(c, {
			user_id: userId,
			profile_generated: true,
			wingfox_generated: true,
			profile_confirmed: true,
			required_interview_count: requiredInterviewCount,
			interview_waiver_active: interviewWaiverActive,
		});
	}
	return generationStateError(c, "generation state inconsistent");
});

type ConfirmedPersonaTraitKey = keyof typeof REFLECTION_TRAIT_VALUES;
type LatestConfirmedPersona = {
	version: number;
	traits: Record<string, string>;
	confirmed_at: string;
	changes?: { compared_to_version: number | null; added_keys: ConfirmedPersonaTraitKey[]; changed_keys: ConfirmedPersonaTraitKey[] } | null;
	changes_unavailable?: true;
};
type PersonaVersionQuery = {
	select(columns: string): PersonaVersionQuery;
	eq(column: string, value: string | number): PersonaVersionQuery;
	order(column: string, options: { ascending: boolean }): PersonaVersionQuery;
	limit(count: number): PersonaVersionQuery;
	maybeSingle(): Promise<{ data: unknown; error: unknown }>;
};

/** Owner-only, enum-only projection; an unavailable revision never replaces the existing profile. */
async function readLatestConfirmedPersona(supabase: ReturnType<typeof getSupabaseClient>, userId: string): Promise<{
	latest_confirmed_persona: LatestConfirmedPersona | null;
	latest_confirmed_persona_unavailable?: true;
}> {
	const unavailable = { latest_confirmed_persona: null, latest_confirmed_persona_unavailable: true as const };
	try {
		const client = supabase as unknown as { from(table: string): PersonaVersionQuery };
		const result = await client.from("user_persona_versions")
			.select("user_id,version,traits,confirmed_at").eq("user_id", userId)
			.order("version", { ascending: false }).limit(1).maybeSingle();
		if (result.error) return unavailable;
		if (result.data === null) return { latest_confirmed_persona: null };
		// Validate both snapshots with the same owner/enum/time boundaries.
		const validateRow = (row: unknown): LatestConfirmedPersona | null => {
			if (!isObjectRecord(row) || row.user_id !== userId || !Number.isSafeInteger(row.version)
				|| (row.version as number) < 1 || (row.version as number) > 2_000_000_000
				|| !isObjectRecord(row.traits) || Object.keys(row.traits).length < 1 || Object.keys(row.traits).length > 9
				|| !z.string().datetime({ offset: true }).safeParse(row.confirmed_at).success) return null;
			const confirmedAtMs = Date.parse(row.confirmed_at as string);
			if (!Number.isFinite(confirmedAtMs) || confirmedAtMs > Date.now()) return null;
			const traits: Record<string, string> = {};
			for (const [key, value] of Object.entries(row.traits)) {
				if (!Object.hasOwn(REFLECTION_TRAIT_VALUES, key) || typeof value !== "string"
					|| !(REFLECTION_TRAIT_VALUES[key as ConfirmedPersonaTraitKey] as readonly string[]).includes(value)) return null;
				traits[key] = value;
			}
			return { version: row.version as number, traits, confirmed_at: new Date(confirmedAtMs).toISOString() };
		};
		const latest = validateRow(result.data);
		if (!latest) return unavailable;
		const keys = Object.keys(latest.traits).sort() as ConfirmedPersonaTraitKey[];
		if (latest.version === 1) {
			return { latest_confirmed_persona: { ...latest, changes: { compared_to_version: null, added_keys: keys, changed_keys: [] } } };
		}
		const changesUnavailable = { latest_confirmed_persona: { ...latest, changes: null, changes_unavailable: true as const } };
		try {
			const previousResult = await client.from("user_persona_versions")
				.select("user_id,version,traits,confirmed_at").eq("user_id", userId)
				.eq("version", latest.version - 1).maybeSingle();
			if (previousResult.error) return changesUnavailable;
			const previous = validateRow(previousResult.data);
			if (!previous || previous.version !== latest.version - 1
				|| Date.parse(previous.confirmed_at) > Date.parse(latest.confirmed_at)
				|| Object.keys(previous.traits).some((key) => !Object.hasOwn(latest.traits, key))) return changesUnavailable;
			return { latest_confirmed_persona: { ...latest, changes: {
				compared_to_version: previous.version,
				added_keys: keys.filter((key) => !Object.hasOwn(previous.traits, key)),
				changed_keys: keys.filter((key) => Object.hasOwn(previous.traits, key) && previous.traits[key] !== latest.traits[key]),
			} } };
		} catch { return changesUnavailable; }
	} catch { return unavailable; }
}

/** GET /api/profiles/me */
profiles.get("/me", requireAuth, async (c) => {
	c.header("Cache-Control", "private, no-store");
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const { data, error } = await supabase.from("profiles").select("*").eq("user_id", userId).maybeSingle();
	if (error) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch profile");
	if (!data) {
		if (c.get("production_e2e_read_only") === true) {
			return jsonError(c, "NOT_FOUND", "Profile not found");
		}
		const { data: inserted, error: insertError } = await supabase
			.from("profiles")
			.insert({
				user_id: userId,
				basic_info: {},
				personality_tags: [],
				personality_analysis: {},
				interests: [],
				values: {},
				romance_style: {},
				communication_style: {},
				lifestyle: {},
				status: "draft",
				version: 1,
			})
			.select()
			.single();
		if (insertError || !inserted) return jsonError(c, "INTERNAL_ERROR", "Failed to create profile");
		return jsonData(c, { ...(inserted as Record<string, unknown>), ...await readLatestConfirmedPersona(supabase, userId) });
	}
	return jsonData(c, { ...(data as Record<string, unknown>), ...await readLatestConfirmedPersona(supabase, userId) });
});

const putProfileSchema = z.object({
	personality_tags: z.array(z.string().trim().min(1).max(100)).min(3).max(5).optional(),
	basic_info: z.object({ bio: z.string().max(1000) }).strict().optional(),
}).strict().refine(value => value.personality_tags !== undefined || value.basic_info !== undefined);

/** PUT /api/profiles/me */
profiles.put("/me", requireAuth, async (c) => {
	const userId = c.get("user_id");
	c.header("Cache-Control", "private, no-store");
	const judge = c.get("judge_access");
	if (judge && (judge.actorId !== userId || !isJudgeAccessActive(judge))) return jsonError(c, "FORBIDDEN", "Profile editing unavailable");
	let body: unknown;
	try {
		const reader = c.req.raw.body?.getReader(); if (!reader) return jsonError(c, "BAD_REQUEST", "Invalid profile edit");
		const chunks: Uint8Array[] = []; let size = 0;
		while (true) { const part = await reader.read(); if (part.done) break; size += part.value.byteLength;
			if (size > 8192) { await reader.cancel(); return jsonError(c, "BAD_REQUEST", "Invalid profile edit"); } chunks.push(part.value); }
		const bytes = new Uint8Array(size); let offset = 0; for (const part of chunks) { bytes.set(part, offset); offset += part.byteLength; }
		body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
	} catch { return jsonError(c, "BAD_REQUEST", "Invalid profile edit"); }
	const parsed = putProfileSchema.safeParse(body);
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", "Invalid profile edit");
	const supabase = getSupabaseClient(c.env);
	const { data: existing, error: existingError } = await supabase
		.from("profiles")
		.select("id, user_id, status, basic_info")
		.eq("user_id", userId)
		.maybeSingle();
	if (existingError) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch profile");
	if (!existing) return jsonError(c, "NOT_FOUND", "Profile not found");
	if (existing.user_id !== userId) return jsonError(c, "INTERNAL_ERROR", "Profile editing unavailable");
	if (existing.status !== "draft") return jsonError(c, "CONFLICT", "Profile already confirmed");
	const updates: Record<string, unknown> = { updated_at: new Date().toISOString() };
	if (parsed.data.personality_tags !== undefined) updates.personality_tags = parsed.data.personality_tags;
	if (parsed.data.basic_info !== undefined) {
		if (!isObjectRecord(existing.basic_info)) return jsonError(c, "INTERNAL_ERROR", "Profile editing unavailable");
		updates.basic_info = { ...existing.basic_info, bio: parsed.data.basic_info.bio };
	}
	if (judge && !isJudgeAccessActive(judge)) return jsonError(c, "FORBIDDEN", "Profile editing unavailable");
	const { data, error } = await supabase.from("profiles").update(updates)
		.eq("id", existing.id).eq("user_id", userId).eq("status", "draft").select().maybeSingle();
	if (error) return jsonError(c, "INTERNAL_ERROR", "Failed to update");
	if (!data) return jsonError(c, "CONFLICT", "Profile state changed; refresh and try again");
	return jsonData(c, data);
});

/** POST /api/profiles/me/confirm */
profiles.post("/me/confirm", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const judgeAccess = c.get("judge_access");
	if (judgeAccess && (judgeAccess.actorId !== userId || !isJudgeAccessActive(judgeAccess))) {
		return jsonError(c, "FORBIDDEN", "Profile confirmation unavailable");
	}
	const recordingConfig = c.get("recording_rehearsal");
	// A validated judge session uses its own admission, not stale recording bindings.
	const recordingBindingsPresent = hasRecordingRehearsalConfig(c.env) && (!judgeAccess || !!recordingConfig);
	if (recordingBindingsPresent) {
		const envConfig = readRecordingRehearsalConfig(c.env);
		if (
			!recordingConfig
			|| envConfig.kind !== "active"
			|| envConfig.config.issuedAt !== recordingConfig.issuedAt
			|| envConfig.config.expiresAt !== recordingConfig.expiresAt
			|| envConfig.config.pair !== recordingConfig.pair
		) return recordingConfirmationUnavailable(c);
	}
	if (recordingConfig) {
		c.header("Cache-Control", "private, no-store");
		if (!isRecordingRehearsalActive(recordingConfig)) return recordingConfirmationUnavailable(c);
		if (!isRecordingRehearsalProfile(recordingConfig, userId) || !isRecordingRehearsalGenerationProfile(recordingConfig, userId)) {
			return jsonError(c, "FORBIDDEN", "Forbidden");
		}
	}
	const supabase = getSupabaseClient(c.env);
	if (isSoraRecordingDraftRecovery(recordingConfig, userId)) {
		if (c.env.RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED === "enabled"
			&& c.env.RECORDING_REHEARSAL_OWNER_PREP_ONLY === "enabled") {
			if (!recordingConfig || !isRecordingRehearsalActive(recordingConfig)) return recordingConfirmationUnavailable(c);
			let revisionState: ProfileConfirmationAwait<Awaited<ReturnType<typeof supabase.rpc<"read_sora_three_interview_profile_revision_state">>>>;
			try {
				revisionState = await awaitProfileConfirmation(recordingConfig, () => supabase.rpc(
					"read_sora_three_interview_profile_revision_state",
					{ p_user_id: userId, p_rehearsal_expires_at: recordingConfig.expiresAt },
				));
			} catch {
				return recordingConfirmationUnavailable(c);
			}
			if (!revisionState.ok || revisionState.value.error) return recordingConfirmationUnavailable(c);
			if (revisionState.value.data?.[0]?.outcome !== "completed") {
				return jsonError(c, "CONFLICT", "Create the new profile from three interviews before confirming");
			}
		}
		const completed = await readThreeDistinctCompletedInterviews(supabase, userId);
		if (completed === null) return recordingConfirmationUnavailable(c);
		if (!completed) return jsonError(c, "CONFLICT", "Complete the third interview before confirming");
		const { data: existingDraft, error: draftError } = await supabase.from("profiles")
			.select("id, user_id, status")
			.eq("user_id", userId)
			.maybeSingle();
		if (draftError) return recordingConfirmationUnavailable(c);
		const draft = readGenerationStateProfile(existingDraft, userId);
		if (!draft || draft === INVALID_GENERATION_STATE_ROW || draft.status !== "draft") {
			return jsonError(c, "CONFLICT", "No reviewable profile draft");
		}
		if (!isRecordingRehearsalActive(recordingConfig)) return recordingConfirmationUnavailable(c);
	}
	const trustedProductionE2E = c.get("production_e2e_active") === true;
	const syntheticCohort = c.get("production_e2e_synthetic") === true;
	if (trustedProductionE2E && !syntheticCohort && !recordingConfig) {
		let settingsResult: { data: { preference_mode?: unknown } | null; error: unknown };
		try {
			const settingsRead = await awaitProfileConfirmation(recordingConfig, () => supabase
				.from("user_profiles")
				.select("preference_mode")
				.eq("id", userId)
				.maybeSingle());
			if (!settingsRead.ok) return recordingConfirmationUnavailable(c);
			settingsResult = settingsRead.value;
		} catch {
			console.error("[profiles/confirm] E2E preference lookup failed");
			return jsonError(c, "INTERNAL_ERROR", "Profile confirmation unavailable");
		}
		if (settingsResult.error) {
			console.error("[profiles/confirm] E2E preference lookup failed");
			return jsonError(c, "INTERNAL_ERROR", "Profile confirmation unavailable");
		}
		if (!settingsResult.data || settingsResult.data.preference_mode !== "no_answer") {
			// A trusted E2E profile must stay outside matching eligibility. Do not
			// repair or overwrite the saved setting from this confirmation route.
			console.error("[profiles/confirm] E2E preference eligibility guard rejected");
			return jsonError(c, "CONFLICT", "Profile confirmation unavailable");
		}
	}
	const wingfoxRead = await awaitProfileConfirmation(recordingConfig, () => supabase
		.from("personas")
		.select("id, user_id, persona_type")
		.eq("user_id", userId)
		.eq("persona_type", "wingfox")
		.maybeSingle());
	if (!wingfoxRead.ok) return recordingConfirmationUnavailable(c);
	const { data: wingfox, error: wingfoxError } = wingfoxRead.value;
	if (wingfoxError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify Wingfox persona");
	if (!wingfox) return jsonError(c, "CONFLICT", "Wingfox persona not generated");
	if (isSoraRecordingDraftRecovery(recordingConfig, userId)) {
		const ownedWingfox = readGenerationStateWingfox(wingfox, userId);
		if (!ownedWingfox || ownedWingfox === INVALID_GENERATION_STATE_ROW) return recordingConfirmationUnavailable(c);
		const sectionsRead = await awaitProfileConfirmation(recordingConfig, () => supabase
			.from("persona_sections")
			.select("section_id, content")
			.eq("persona_id", ownedWingfox.id));
		if (!sectionsRead.ok) return recordingConfirmationUnavailable(c);
		if (sectionsRead.value.error || !hasCompleteWingfoxSections(sectionsRead.value.data)) {
			return jsonError(c, "CONFLICT", "AI partner is incomplete");
		}
	}
	const profileUpdate = await awaitProfileConfirmation(recordingConfig, () => supabase
		.from("profiles")
		.update({
			status: "confirmed",
			confirmed_at: new Date().toISOString(),
			updated_at: new Date().toISOString(),
		})
		.eq("user_id", userId));
	if (!profileUpdate.ok) return recordingConfirmationUnavailable(c);
	if (profileUpdate.value.error) return jsonError(c, "INTERNAL_ERROR", "Failed to confirm");
	const onboardingUpdate = await awaitProfileConfirmation(recordingConfig, () => supabase
		.from("user_profiles")
		.update({ onboarding_status: "confirmed", updated_at: new Date().toISOString() })
		.eq("id", userId));
	if (!onboardingUpdate.ok) return recordingConfirmationUnavailable(c);
	if (onboardingUpdate.value.error) return jsonError(c, "INTERNAL_ERROR", "Failed to update onboarding status");

	if (!recordingConfig && (!trustedProductionE2E || syntheticCohort)) {
		// Run matching in the background without blocking the response.
		// Use waitUntil on Workers so the runtime keeps the task alive after response.
		const judgeAccess = c.get("judge_access");
		const matchingTask = judgeAccess
			? executeMatching(supabase, 1, undefined, { profileIds: [judgeAccess.actorId, judgeAccess.counterpartId], actorId: userId, mode: "start", canWrite: () => isJudgeAccessActive(judgeAccess) })
			: executeMatching(supabase, syntheticCohort ? 1 : 10, syntheticCohort ? "synthetic" : undefined);
		const monitoredMatching = matchingTask
			.then((count) => {
				console.log(`[matching] created ${count} matches after profile confirm`);
			})
			.catch(() => {
				console.error("[profiles/confirm] matching task failed after profile confirm");
			});
		try {
			c.executionCtx.waitUntil(monitoredMatching);
		} catch {
			// Node.js dev server — promise runs detached
		}
	}
	if (recordingConfig && !isRecordingRehearsalActive(recordingConfig)) return recordingConfirmationUnavailable(c);
	return jsonData(c, { status: "confirmed", confirmed_at: new Date().toISOString() });
});

/** POST /api/profiles/me/reset */
profiles.post("/me/reset", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const { error: onboardingError } = await supabase
		.from("user_profiles")
		.update({ onboarding_status: "not_started", updated_at: new Date().toISOString() })
		.eq("id", userId);
	if (onboardingError) return jsonError(c, "INTERNAL_ERROR", "Failed to reset onboarding");
	const { error: profileError } = await supabase
		.from("profiles")
		.update({ status: "draft", updated_at: new Date().toISOString() })
		.eq("user_id", userId);
	if (profileError) return jsonError(c, "INTERNAL_ERROR", "Failed to reset profile");
	return jsonData(c, { message: "Onboarding reset", onboarding_status: "not_started" });
});

export default profiles;
