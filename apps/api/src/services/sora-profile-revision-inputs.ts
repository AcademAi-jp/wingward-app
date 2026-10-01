import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import type { FrozenDnaSession } from "./interaction-dna";

export const SORA_PROFILE_REVISION_MAX_QUIZ_ANSWERS = 10;
export const SORA_PROFILE_REVISION_MAX_QUIZ_BYTES = 6_000;
export const SORA_PROFILE_REVISION_MAX_MESSAGES_PER_SESSION = 40;
export const SORA_PROFILE_REVISION_MAX_MESSAGES_TOTAL = 90;
export const SORA_PROFILE_REVISION_MAX_TRANSCRIPT_BYTES = 16_000;
export const SORA_PROFILE_REVISION_MAX_MESSAGE_CHARS = 2_000;
export const SORA_PROFILE_REVISION_MIN_MESSAGES = 12;

const PERSONA_TYPES = new Set([
	"virtual_similar",
	"virtual_complementary",
	"virtual_discovery",
]);
const CANONICAL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type SoraProfileRevisionInputs = Readonly<{
	quizText: string;
	conversationLogs: string;
	sessionIds: readonly string[];
	sessions: readonly FrozenDnaSession[];
}>;

/** Loads one bounded, frozen input bundle for both profile and DNA prompts. */
export async function loadSoraProfileRevisionInputs(
	supabase: SupabaseClient<Database>,
	userId: string,
): Promise<SoraProfileRevisionInputs> {
	const [answersResult, sessionsResult] = await Promise.all([
		supabase.from("quiz_answers")
			.select("question_id, selected")
			.eq("user_id", userId)
			.order("question_id", { ascending: true })
			.limit(SORA_PROFILE_REVISION_MAX_QUIZ_ANSWERS + 1),
		supabase.from("speed_dating_sessions")
			.select("id, persona_id, completed_at")
			.eq("user_id", userId)
			.eq("status", "completed")
			.order("completed_at", { ascending: false, nullsFirst: false })
			.order("id", { ascending: false })
			.limit(4),
	]);
	if (answersResult.error || sessionsResult.error) throw new Error("Profile revision inputs unavailable");
	if (!Array.isArray(answersResult.data) || answersResult.data.length > SORA_PROFILE_REVISION_MAX_QUIZ_ANSWERS) {
		throw new Error("Profile revision quiz input exceeded its bounds");
	}
	const answerRows = answersResult.data.map((row) => {
		if (typeof row.question_id !== "string" || row.question_id.length < 1 || row.question_id.length > 80
			|| !Array.isArray(row.selected) || row.selected.length < 1 || row.selected.length > 4
			|| row.selected.some((choice) => typeof choice !== "string" || choice.length < 1 || choice.length > 120)) {
			throw new Error("Profile revision quiz input is invalid");
		}
		return { question_id: row.question_id, selected: row.selected };
	});
	const quizText = JSON.stringify(answerRows);
	if (utf8Length(quizText) > SORA_PROFILE_REVISION_MAX_QUIZ_BYTES) {
		throw new Error("Profile revision quiz input exceeded its byte limit");
	}

	if (!Array.isArray(sessionsResult.data) || sessionsResult.data.length !== 3) {
		throw new Error("Profile revision requires exactly three completed interviews");
	}
	const sessions = sessionsResult.data.map((row) => {
		if (!CANONICAL_UUID.test(row.id) || !CANONICAL_UUID.test(row.persona_id ?? "")
			|| typeof row.completed_at !== "string" || !Number.isFinite(Date.parse(row.completed_at))) {
			throw new Error("Profile revision interview state is invalid");
		}
		return { id: row.id, personaId: row.persona_id!, completedAt: row.completed_at };
	});
	if (new Set(sessions.map((session) => session.id)).size !== 3
		|| new Set(sessions.map((session) => session.personaId)).size !== 3) {
		throw new Error("Profile revision requires three distinct interviews");
	}

	const personaResult = await supabase.from("personas")
		.select("id, user_id, persona_type")
		.in("id", sessions.map((session) => session.personaId));
	if (personaResult.error || !Array.isArray(personaResult.data) || personaResult.data.length !== 3) {
		throw new Error("Profile revision persona state is invalid");
	}
	const personaTypeById = new Map<string, FrozenDnaSession["personaType"]>();
	for (const persona of personaResult.data) {
		if (persona.user_id !== userId || !PERSONA_TYPES.has(persona.persona_type)
			|| personaTypeById.has(persona.id)) {
			throw new Error("Profile revision persona ownership is invalid");
		}
		personaTypeById.set(persona.id, persona.persona_type as FrozenDnaSession["personaType"]);
	}
	if (new Set(personaTypeById.values()).size !== 3) {
		throw new Error("Profile revision requires all three distinct interview types");
	}

	let totalMessageCount = 0;
	let totalTranscriptBytes = 0;
	const frozenSessions: FrozenDnaSession[] = [];
	for (const session of sessions) {
		const { data, error } = await supabase.from("speed_dating_messages")
			.select("role, content")
			.eq("session_id", session.id)
			.order("created_at", { ascending: true })
			.order("id", { ascending: true })
			.limit(SORA_PROFILE_REVISION_MAX_MESSAGES_PER_SESSION + 1);
		if (error || !Array.isArray(data) || data.length > SORA_PROFILE_REVISION_MAX_MESSAGES_PER_SESSION) {
			throw new Error("Profile revision transcript exceeded its bounds");
		}
		const messages = data.map((message) => {
			if ((message.role !== "user" && message.role !== "persona")
				|| typeof message.content !== "string"
				|| message.content.length > SORA_PROFILE_REVISION_MAX_MESSAGE_CHARS) {
				throw new Error("Profile revision transcript is invalid");
			}
			totalMessageCount += 1;
			totalTranscriptBytes += utf8Length(message.content);
			return { role: message.role as "user" | "persona", content: message.content };
		});
		if (!messages.some((message) => message.role === "user" && message.content.trim().length > 0)
			|| !messages.some((message) => message.role === "persona" && message.content.trim().length > 0)) {
			throw new Error("Each profile revision interview must contain both sides of the conversation");
		}
		const personaType = personaTypeById.get(session.personaId);
		if (!personaType) throw new Error("Profile revision persona is missing");
		frozenSessions.push({ personaType, messages });
	}
	if (totalMessageCount < SORA_PROFILE_REVISION_MIN_MESSAGES
		|| totalMessageCount > SORA_PROFILE_REVISION_MAX_MESSAGES_TOTAL
		|| totalTranscriptBytes > SORA_PROFILE_REVISION_MAX_TRANSCRIPT_BYTES) {
		throw new Error("Profile revision transcript exceeded its aggregate bounds");
	}

	const conversationLogs = frozenSessions.map((session, index) =>
		`--- Interview ${index + 1} (${session.personaType}) ---\n${session.messages
			.map((message) => `${message.role}: ${message.content}`)
			.join("\n")}`,
	).join("\n\n");
	return {
		quizText,
		conversationLogs,
		sessionIds: sessions.map((session) => session.id),
		sessions: frozenSessions,
	};
}

function utf8Length(value: string): number {
	return new TextEncoder().encode(value).byteLength;
}
