import { judgeChatComplete } from "../services/judge-chat-complete";
import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { detectLangFromDocument } from "../lib/lang";
import { isCanonicalUuid } from "../lib/speed-dating-ai";
import { isInterviewGenerationWaiverActive } from "../lib/profile-generation-waiver";
import { generationError } from "../lib/generation-diagnostics";
import { isRecordingRehearsalActive } from "../services/recording-rehearsal";
import { MISTRAL_LARGE } from "../services/mistral";
import { buildWingfoxSectionPrompt, getConstraintsContent } from "../prompts/wingfox-generation";
import { getRandomIconUrlForGender } from "../lib/fox-icons";
import { z } from "zod";

const personas = new Hono<Env>();
const WINGFOX_MAX_SESSIONS = 3;
const WINGFOX_WAIVER_SESSIONS = 2;
const WINGFOX_MAX_MESSAGES_PER_SESSION = 24;
const WINGFOX_MAX_MESSAGE_CHARS = 400;
const WINGFOX_MIN_MESSAGES = 6;
const WINGFOX_MAX_EXCERPT_CHARS = 12_000;
const WINGFOX_AI_UNAVAILABLE_MESSAGE = "AI persona generation unavailable";

const WINGFOX_EDITABLE_SECTIONS = [
	"core_identity",
	"communication_rules",
	"personality_profile",
	"interests",
	"values",
	"romance_style",
];

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** POST /api/personas/wingfox/generate */
personas.post("/wingfox/generate", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const recordingConfig = c.get("recording_rehearsal");
	if (isRecordingRehearsalActive(recordingConfig)
		&& recordingConfig.pair === "sora-ren"
		&& recordingConfig.generationPair[0] === userId) {
		return jsonError(c, "CONFLICT", "Review the existing AI partner");
	}
	const interviewWaiverActive = isInterviewGenerationWaiverActive(
		c.env,
		userId,
		c.get("production_e2e_active"),
	);
	const requiredSessions = interviewWaiverActive ? WINGFOX_WAIVER_SESSIONS : WINGFOX_MAX_SESSIONS;
	const apiKey = c.env.MISTRAL_API_KEY;
	if (!apiKey?.trim()) return generationError(c, "wingfox_input", WINGFOX_AI_UNAVAILABLE_MESSAGE);
	let supabase: ReturnType<typeof getSupabaseClient>;
	try {
		supabase = getSupabaseClient(c.env);
	} catch (error) {
		return generationError(c, "wingfox_input", WINGFOX_AI_UNAVAILABLE_MESSAGE, error);
	}
	let profileResult: { data: unknown; error: unknown };
	try {
		profileResult = await supabase
			.from("profiles")
			.select("*")
			.eq("user_id", userId)
			.maybeSingle();
	} catch (error) {
		return generationError(c, "wingfox_input", "Failed to load profile", error);
	}
	const { data: profile, error: profileError } = profileResult;
	if (profileError) {
		return generationError(c, "wingfox_input", "Failed to load profile", profileError);
	}
	if (!profile) return jsonError(c, "CONFLICT", "Profile not generated");
	// The temporary path is single-use once Wing Fox has been persisted. Keep
	// the regular regeneration/edit behavior unchanged for other accounts.
	if (interviewWaiverActive) {
		let existingWingfoxResult: { data: unknown; error: unknown };
		try {
			existingWingfoxResult = await supabase
				.from("personas")
				.select("id, user_id, persona_type")
				.eq("user_id", userId)
				.eq("persona_type", "wingfox")
				.maybeSingle();
		} catch (error) {
			return generationError(c, "wingfox_input", "Failed to load generation inputs", error);
		}
		if (existingWingfoxResult.error) {
			return generationError(c, "wingfox_input", "Failed to load generation inputs", existingWingfoxResult.error);
		}
		if (existingWingfoxResult.data !== null && existingWingfoxResult.data !== undefined) {
			if (!isRecord(existingWingfoxResult.data) ||
				existingWingfoxResult.data.user_id !== userId ||
				existingWingfoxResult.data.persona_type !== "wingfox" ||
				!isCanonicalUuid(existingWingfoxResult.data.id)) {
				return generationError(c, "wingfox_input", "Failed to load generation inputs");
			}
			return jsonError(c, "CONFLICT", "AI partner already generated");
		}
	}
	let sessionsResult: { data: Array<{ id: string; completed_at: string | null; persona_id?: unknown }> | null; error: unknown };
	try {
		sessionsResult = await supabase
			.from("speed_dating_sessions")
			.select("id, persona_id, completed_at")
			.eq("user_id", userId)
			.eq("status", "completed")
			.order("completed_at", { ascending: false, nullsFirst: false })
			.limit(WINGFOX_MAX_SESSIONS);
	} catch (error) {
		return generationError(c, "wingfox_input", "Failed to load generation inputs", error);
	}
	const { data: sessions, error: sessionsError } = sessionsResult;
	if (sessionsError) {
		return generationError(c, "wingfox_input", "Failed to load generation inputs", sessionsError);
	}
	if (!Array.isArray(sessions)) return generationError(c, "wingfox_input", "Failed to load generation inputs");
	if (sessions.some((session) => !session || typeof session !== "object" || typeof session.id !== "string" || session.id.length === 0)) {
		return generationError(c, "wingfox_input", "Failed to load generation inputs");
	}
	const sessionIds = (sessions ?? []).map((s) => s.id);
	if (sessionIds.length < requiredSessions) {
		return jsonError(c, "CONFLICT", "Not enough completed speed-dating sessions");
	}
	if (interviewWaiverActive) {
		const distinctPersonaIDs = new Set<string>();
		for (const session of sessions) {
			if (typeof session.persona_id !== "string" || !isCanonicalUuid(session.persona_id)) {
				return generationError(c, "wingfox_input", "Failed to load generation inputs");
			}
			distinctPersonaIDs.add(session.persona_id);
		}
		if (distinctPersonaIDs.size < requiredSessions) {
			return jsonError(c, "CONFLICT", "Not enough completed speed-dating sessions");
		}
	}
	let conversationExcerpts = "";
	let totalMessages = 0;
	for (let i = 0; i < sessionIds.length; i += 1) {
		const sid = sessionIds[i];
		conversationExcerpts += `--- Session ${i + 1} (${sid}) ---\n`;
		let messagesResult: { data: Array<{ role: string; content: string }> | null; error: unknown };
		try {
			messagesResult = await supabase
				.from("speed_dating_messages")
				.select("role, content")
				.eq("session_id", sid)
				.order("created_at", { ascending: true })
				.limit(WINGFOX_MAX_MESSAGES_PER_SESSION);
		} catch (error) {
			return generationError(c, "wingfox_input", "Failed to load generation inputs", error);
		}
		const { data: msgs, error: messagesError } = messagesResult;
		if (messagesError) {
			return generationError(c, "wingfox_input", "Failed to load generation inputs", messagesError);
		}
		if (!Array.isArray(msgs)) return generationError(c, "wingfox_input", "Failed to load generation inputs");
		for (const m of msgs) {
			if (!m || typeof m !== "object" || typeof m.role !== "string" || typeof m.content !== "string") {
				return generationError(c, "wingfox_input", "Failed to load generation inputs");
			}
			conversationExcerpts += `${m.role}: ${m.content.slice(0, WINGFOX_MAX_MESSAGE_CHARS)}\n`;
			totalMessages += 1;
		}
	}
	if (totalMessages < WINGFOX_MIN_MESSAGES) {
		return jsonError(c, "CONFLICT", "Not enough conversation data to generate wingfox persona");
	}
	if (conversationExcerpts.length > WINGFOX_MAX_EXCERPT_CHARS) {
		conversationExcerpts = conversationExcerpts.slice(0, WINGFOX_MAX_EXCERPT_CHARS);
	}
	let profileJson: string;
	try {
		profileJson = JSON.stringify(profile, null, 2);
	} catch (error) {
		return generationError(c, "wingfox_input", WINGFOX_AI_UNAVAILABLE_MESSAGE, error);
	}
	if (typeof profileJson !== "string") return generationError(c, "wingfox_input", WINGFOX_AI_UNAVAILABLE_MESSAGE);
	const lang = detectLangFromDocument(conversationExcerpts);
	const sections: { section_id: string; content: string }[] = [];
	for (const sectionId of WINGFOX_EDITABLE_SECTIONS) {
		const title = sectionId;
		const noDataFallback = lang === "en" ? "(none)" : "（なし）";
		let prompt: string;
		try {
			prompt = buildWingfoxSectionPrompt(sectionId, title, profileJson, conversationExcerpts || noDataFallback, lang);
		} catch (error) {
			return generationError(c, "wingfox_input", WINGFOX_AI_UNAVAILABLE_MESSAGE, error);
		}
		let content: string;
		try {
			content = await judgeChatComplete(c, supabase, "ward_generate", apiKey, [{ role: "user", content: prompt }], { model: MISTRAL_LARGE, maxTokens: 500 });
		} catch (error) {
			return generationError(c, "wingfox_model", WINGFOX_AI_UNAVAILABLE_MESSAGE, error);
		}
		if (typeof content !== "string") return generationError(c, "wingfox_model", WINGFOX_AI_UNAVAILABLE_MESSAGE);
		sections.push({ section_id: sectionId, content: content || `（${sectionId}）` });
	}
	const conversationRefLabel = lang === "en"
		? "The following are reference logs extracted from speed dating conversations (read-only):"
		: "以下はスピードデーティング会話から抽出した参照ログ（編集不可）:";
	sections.push({
		section_id: "conversation_references",
		content: `${conversationRefLabel}\n\n${conversationExcerpts}`,
	});
	sections.push({ section_id: "constraints", content: getConstraintsContent(lang) });
	const compiledDocument = sections.map((s) => `## ${s.section_id}\n\n${s.content}`).join("\n\n");
	let userProfileResult: { data: { gender: string | null; nickname: string } | null; error: unknown };
	try {
		userProfileResult = await supabase
			.from("user_profiles")
			.select("gender, nickname")
			.eq("id", userId)
			.maybeSingle();
	} catch (error) {
		return generationError(c, "wingfox_input", "Failed to load user profile", error);
	}
	const { data: userProfile, error: userProfileError } = userProfileResult;
	if (userProfileError || !userProfile) {
		return generationError(c, "wingfox_input", "Failed to load user profile", userProfileError);
	}
	if (
		(userProfile.gender !== null && typeof userProfile.gender !== "string")
		|| typeof userProfile.nickname !== "string"
	) {
		return generationError(c, "wingfox_input", "Failed to load user profile");
	}
	const iconUrl = getRandomIconUrlForGender(userProfile?.gender ?? "");
	const displayName = `${(userProfile?.nickname ?? "User").toString().trim()}Fox`;
	let personaResult: {
		data: {
			id: string;
			user_id: string;
			persona_type: string;
			name: string;
			compiled_document: string;
			version: number;
		} | null;
		error: unknown;
	};
	try {
		personaResult = await supabase
			.from("personas")
			.upsert(
				{
					user_id: userId,
					persona_type: "wingfox",
					name: displayName,
					compiled_document: compiledDocument,
					icon_url: iconUrl,
					updated_at: new Date().toISOString(),
				},
				{ onConflict: "user_id,persona_type" },
			)
			.select("id, user_id, persona_type, name, compiled_document, version")
			.single();
	} catch (error) {
		return generationError(c, "wingfox_save", "Failed to save persona", error);
	}
	const { data: persona, error } = personaResult;
	if (error || !persona || !isCanonicalUuid(persona.id) || persona.user_id !== userId) {
		return generationError(c, "wingfox_save", "Failed to save persona", error);
	}
	for (const s of sections) {
		let sectionResult: { error: unknown };
		try {
			sectionResult = await supabase.from("persona_sections").upsert(
				{
					persona_id: persona.id,
					section_id: s.section_id,
					content: s.content,
				},
				{ onConflict: "persona_id,section_id" },
			);
		} catch (error) {
			return generationError(c, "wingfox_save", "Failed to save persona sections", error);
		}
		const { error: sectionError } = sectionResult;
		if (sectionError) {
			return generationError(c, "wingfox_save", "Failed to save persona sections", sectionError);
		}
	}
	let onboardingResult: { error: unknown };
	try {
		onboardingResult = await supabase
			.from("user_profiles")
			.update({ onboarding_status: "persona_generated", updated_at: new Date().toISOString() })
			.eq("id", userId);
	} catch (error) {
		return generationError(c, "wingfox_save", "Failed to update onboarding status", error);
	}
	const { error: onboardingError } = onboardingResult;
	if (onboardingError) {
		return generationError(c, "wingfox_save", "Failed to update onboarding status", onboardingError);
	}
	let sectionsResult: {
		data: Array<{ section_id: string; content: string; source: string | null }> | null;
		error: unknown;
	};
	try {
		sectionsResult = await supabase
			.from("persona_sections")
			.select("section_id, content, source")
			.eq("persona_id", persona.id);
	} catch (error) {
		return generationError(c, "wingfox_read", "Failed to read persona sections", error);
	}
	const { data: secList, error: sectionsError } = sectionsResult;
	if (sectionsError || !secList) {
		return generationError(c, "wingfox_read", "Failed to read persona sections", sectionsError);
	}
	if (secList.some((section) =>
		!section
		|| typeof section !== "object"
		|| typeof section.section_id !== "string"
		|| typeof section.content !== "string"
		|| (section.source !== null && typeof section.source !== "string"),
	)) {
		return generationError(c, "wingfox_read", "Failed to read persona sections");
	}
	let definitionsResult: { data: Array<{ id: string; title: string; editable: boolean }> | null; error: unknown };
	try {
		definitionsResult = await supabase
			.from("persona_section_definitions")
			.select("id, title, editable");
	} catch (error) {
		return generationError(c, "wingfox_read", "Failed to read persona definitions", error);
	}
	const { data: sectionDefs, error: definitionsError } = definitionsResult;
	if (definitionsError || !sectionDefs) {
		return generationError(c, "wingfox_read", "Failed to read persona definitions", definitionsError);
	}
	if (sectionDefs.some((definition) =>
		!definition
		|| typeof definition !== "object"
		|| typeof definition.id !== "string"
		|| typeof definition.title !== "string"
		|| typeof definition.editable !== "boolean",
	)) {
		return generationError(c, "wingfox_read", "Failed to read persona definitions");
	}
	const editableMap = new Map((sectionDefs ?? []).map((d) => [d.id, d.editable]));
	return jsonData(c, {
		...persona,
		sections: (secList ?? []).map((s) => ({
			section_id: s.section_id,
			title: s.section_id,
			content: s.content,
			source: s.source,
			editable: editableMap.get(s.section_id) ?? false,
		})),
	});
});

/** GET /api/personas */
personas.get("/", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const typeFilter = c.req.query("persona_type");
	const supabase = getSupabaseClient(c.env);
	let q = supabase.from("personas").select("id, persona_type, name, version, icon_url, created_at, updated_at").eq("user_id", userId);
	if (typeFilter) q = q.eq("persona_type", typeFilter);
	const { data, error } = await q;
	if (error) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch personas");
	return jsonData(c, data ?? []);
});

/** GET /api/personas/section-definitions */
personas.get("/section-definitions", requireAuth, async (c) => {
	const supabase = getSupabaseClient(c.env);
	const typeFilter = c.req.query("persona_type");
	const { data, error } = await supabase
		.from("persona_section_definitions")
		.select("id, title, description, sort_order, editable, applicable_persona_types")
		.order("sort_order");
	if (error) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch definitions");
	let list = data ?? [];
	if (typeFilter) {
		list = list.filter((row) => (row.applicable_persona_types ?? []).includes(typeFilter));
	}
	return jsonData(c, list);
});

/** GET /api/personas/:personaId */
personas.get("/:personaId", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const personaId = c.req.param("personaId");
	const supabase = getSupabaseClient(c.env);
	const { data, error } = await supabase
		.from("personas")
		.select("*")
		.eq("id", personaId)
		.eq("user_id", userId)
		.single();
	if (error || !data) return jsonError(c, "NOT_FOUND", "Persona not found");
	return jsonData(c, data);
});

/** GET /api/personas/:personaId/sections */
personas.get("/:personaId/sections", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const personaId = c.req.param("personaId");
	const supabase = getSupabaseClient(c.env);
	// Run ownership check, sections fetch, and definitions fetch in parallel
	const [ownerResult, sectionsResult, defsResult] = await Promise.all([
		supabase.from("personas").select("id").eq("id", personaId).eq("user_id", userId).single(),
		supabase.from("persona_sections").select("id, section_id, content, source, updated_at").eq("persona_id", personaId),
		supabase.from("persona_section_definitions").select("id, title, editable"),
	]);
	if (ownerResult.error && ownerResult.error.code !== "PGRST116") {
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify persona ownership");
	}
	if (!ownerResult.data) return jsonError(c, "NOT_FOUND", "Persona not found");
	if (sectionsResult.error || !sectionsResult.data || defsResult.error || !defsResult.data) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to fetch persona sections");
	}
	const defMap = new Map(defsResult.data.map((d) => [d.id, d]));
	const list = sectionsResult.data.map((s) => ({
		...s,
		title: defMap.get(s.section_id)?.title ?? s.section_id,
		editable: defMap.get(s.section_id)?.editable ?? false,
	}));
	return jsonData(c, list);
});

/** GET /api/personas/:personaId/sections/:sectionId */
personas.get("/:personaId/sections/:sectionId", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const personaId = c.req.param("personaId");
	const sectionId = c.req.param("sectionId");
	const supabase = getSupabaseClient(c.env);
	const { data: p, error: personaError } = await supabase.from("personas").select("id").eq("id", personaId).eq("user_id", userId).single();
	if (personaError && personaError.code !== "PGRST116") return jsonError(c, "INTERNAL_ERROR", "Failed to verify persona ownership");
	if (!p) return jsonError(c, "NOT_FOUND", "Persona not found");
	const { data: section, error: sectionError } = await supabase
		.from("persona_sections")
		.select("*")
		.eq("persona_id", personaId)
		.eq("section_id", sectionId)
		.single();
	if (sectionError && sectionError.code !== "PGRST116") return jsonError(c, "INTERNAL_ERROR", "Failed to fetch persona section");
	if (!section) return jsonError(c, "NOT_FOUND", "Section not found");
	const { data: def, error: definitionError } = await supabase.from("persona_section_definitions").select("id, title, description, editable").eq("id", sectionId).single();
	if (definitionError || !def) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch section definition");
	return jsonData(c, {
		...section,
		title: def.title,
		description: def.description ?? "",
		editable: def.editable,
	});
});

const putSectionSchema = z.object({ content: z.string() });

/** PUT /api/personas/:personaId/sections/:sectionId */
personas.put("/:personaId/sections/:sectionId", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const personaId = c.req.param("personaId");
	const sectionId = c.req.param("sectionId");
	const parsed = putSectionSchema.safeParse(await c.req.json());
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", parsed.error.message);
	const supabase = getSupabaseClient(c.env);
	const { data: persona, error: personaError } = await supabase.from("personas").select("id").eq("id", personaId).eq("user_id", userId).single();
	if (personaError) return jsonError(c, "INTERNAL_ERROR", "Failed to verify persona ownership");
	if (!persona) return jsonError(c, "NOT_FOUND", "Persona not found");
	const { data: def, error: definitionError } = await supabase
		.from("persona_section_definitions")
		.select("editable")
		.eq("id", sectionId)
		.single();
	if (definitionError) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch section definition");
	if (!def || !def.editable) return jsonError(c, "FORBIDDEN", "Section not editable");
	const { error: sectionUpdateError } = await supabase
		.from("persona_sections")
		.update({ content: parsed.data.content, source: "manual", updated_at: new Date().toISOString() })
		.eq("persona_id", personaId)
		.eq("section_id", sectionId);
	if (sectionUpdateError) return jsonError(c, "INTERNAL_ERROR", "Failed to update persona section");
	const { data: sections, error: sectionsError } = await supabase
		.from("persona_sections")
		.select("section_id, content")
		.eq("persona_id", personaId)
		.order("section_id");
	if (sectionsError || !sections) return jsonError(c, "INTERNAL_ERROR", "Failed to read persona sections");
	const compiledDocument = (sections ?? []).map((s) => `## ${s.section_id}\n\n${s.content}`).join("\n\n");
	const { error: personaUpdateError } = await supabase
		.from("personas")
		.update({ compiled_document: compiledDocument, updated_at: new Date().toISOString() })
		.eq("id", personaId);
	if (personaUpdateError) return jsonError(c, "INTERNAL_ERROR", "Failed to update persona");
	const { data: updated, error: updatedError } = await supabase
		.from("persona_sections")
		.select("id, section_id, content, source, updated_at")
		.eq("persona_id", personaId)
		.eq("section_id", sectionId)
		.single();
	if (updatedError || !updated) return jsonError(c, "INTERNAL_ERROR", "Failed to read updated persona section");
	return jsonData(c, updated);
});

/** POST /api/personas/:personaId/icon - set random fox icon by user gender, save path to DB */
personas.post("/:personaId/icon", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const personaId = c.req.param("personaId");
	const supabase = getSupabaseClient(c.env);
	const { data: p, error: personaError } = await supabase.from("personas").select("id").eq("id", personaId).eq("user_id", userId).single();
	if (personaError && personaError.code !== "PGRST116") return jsonError(c, "INTERNAL_ERROR", "Failed to verify persona ownership");
	if (!p) return jsonError(c, "NOT_FOUND", "Persona not found");
	const { data: profile, error: profileError } = await supabase.from("user_profiles").select("gender").eq("id", userId).single();
	if (profileError || !profile) return jsonError(c, "INTERNAL_ERROR", "Failed to fetch user profile");
	const iconUrl = getRandomIconUrlForGender(profile?.gender ?? "");
	const { error: updateError } = await supabase
		.from("personas")
		.update({ icon_url: iconUrl, updated_at: new Date().toISOString() })
		.eq("id", personaId)
		.eq("user_id", userId);
	if (updateError) return jsonError(c, "INTERNAL_ERROR", "Failed to update icon");
	return jsonData(c, { icon_url: iconUrl });
});

export default personas;
