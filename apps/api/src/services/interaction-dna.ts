import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { z } from "zod";
import { chatComplete, chatCompleteOnceBounded, MISTRAL_LARGE } from "./mistral";
import { buildInteractionDnaScoringPrompt } from "../prompts/interaction-dna-scoring";

export const SORA_PROFILE_REVISION_MAX_REQUEST_BYTES = 24_000;
export const SORA_PROFILE_REVISION_MAX_RESPONSE_BYTES = 64_000;

export type FrozenDnaSession = Readonly<{
	personaType: "virtual_similar" | "virtual_complementary" | "virtual_discovery";
	messages: readonly Readonly<{ role: "user" | "persona"; content: string }>[];
}>;
export type PreparedFrozenDnaScore = Readonly<{
	prompt: string;
	userTurns: ReadonlySet<number>;
	lang: "ja" | "en";
}>;

const DnaFeatureSchema = z.object({
	score: z.number().min(0).max(1),
	confidence: z.number().min(0).max(1),
	evidence_turns: z.array(z.number().int().min(1).max(90)).max(90),
	reasoning: z.string().max(400),
});

const InteractionDnaResultSchema = z.object({
	features: z.object({
		mere_exposure: DnaFeatureSchema,
		reciprocity: DnaFeatureSchema,
		similarity_complementarity: DnaFeatureSchema,
		attachment: DnaFeatureSchema,
		humor_sharing: DnaFeatureSchema,
		self_disclosure: DnaFeatureSchema,
		synchrony: DnaFeatureSchema,
		emotional_responsiveness: DnaFeatureSchema,
		self_expansion: DnaFeatureSchema,
		self_esteem_reception: DnaFeatureSchema,
		physiological: DnaFeatureSchema,
		economic_alignment: DnaFeatureSchema,
		conflict_resolution: DnaFeatureSchema,
	}),
	overall_interaction_signature: z.string().max(500),
	preferred_persona_type: z.enum([
		"virtual_similar",
		"virtual_complementary",
		"virtual_discovery",
	]),
});

type DnaFeatures = z.infer<typeof InteractionDnaResultSchema>["features"];

function deriveConflictStyle(score: number): string {
	if (score >= 0.7) return "dialogue";
	if (score >= 0.4) return "maintains";
	if (score >= 0.2) return "yields";
	return "avoids";
}

function deriveAttachmentTendency(score: number): string {
	if (score >= 0.65) return "secure";
	if (score >= 0.35) return "anxious";
	return "avoidant";
}

export function buildInteractionStyle(features: DnaFeatures, lang: "ja" | "en" = "ja") {
  // Missing evidence is unknown, not evidence of a low or average trait.
  const sanitized = Object.fromEntries(Object.entries(features).map(([key, value]) => {
    const evidence = value.evidence_turns.filter(turn => Number.isInteger(turn) && turn > 0);
    const unsupported = key === "physiological" || evidence.length === 0 || value.confidence === 0;
    return [key, unsupported
      ? { score: 0.5, confidence: 0, evidence_turns: [], reasoning: lang === "en" ? "Insufficient transcript evidence" : "会話の根拠不足" }
      : { ...value, evidence_turns: evidence }];
  })) as DnaFeatures;
  features = sanitized;
	const dnaScores: Record<string, { score: number; confidence: number; evidence_turns: number[]; reasoning: string }> = {};
	for (const [key, value] of Object.entries(features)) {
		dnaScores[key] = {
			score: value.score,
			confidence: value.confidence,
			evidence_turns: value.evidence_turns,
			reasoning: value.reasoning,
		};
	}

	return {
		// Backward-compatible old fields
		warmup_speed: features.mere_exposure.score,
		humor_responsiveness: features.humor_sharing.score,
		self_disclosure_depth: features.self_disclosure.score,
		emotional_responsiveness: features.emotional_responsiveness.score,
		conflict_style: features.conflict_resolution.confidence > 0 ? deriveConflictStyle(features.conflict_resolution.score) : "unknown",
		attachment_tendency: features.attachment.confidence > 0 ? deriveAttachmentTendency(features.attachment.score) : "unknown",
		rhythm_preference: "unknown",
		mirroring_tendency: features.synchrony.score,
		// New DNA fields
		dna_scores: dnaScores,
	};
}

/** Scores the exact already-loaded sessions used by Sora's profile request.
 * It performs one bounded provider request and has no database read/write path.
 */
export function prepareInteractionDnaFromFrozenSessions(
	sessions: readonly FrozenDnaSession[],
	lang: "ja" | "en",
): PreparedFrozenDnaScore {
	const expectedTypes = new Set(["virtual_similar", "virtual_complementary", "virtual_discovery"]);
	if (sessions.length !== 3 || new Set(sessions.map((session) => session.personaType)).size !== 3
		|| sessions.some((session) => !expectedTypes.has(session.personaType))) {
		throw new Error("Profile revision requires three distinct virtual interview sessions");
	}
	let turnNumber = 0;
	const userTurns = new Set<number>();
	const promptSessions = sessions.map((session) => ({
		personaType: session.personaType,
		transcript: session.messages.map((message) => {
			if (message.content.length > 2000 || (message.role !== "user" && message.role !== "persona")) {
				throw new Error("Frozen profile revision transcript exceeded its input limits");
			}
			const turn = ++turnNumber;
			if (message.role === "user") userTurns.add(turn);
			return `[Turn ${turn}] ${message.role}: ${message.content}`;
		}).join("\n"),
	}));
	if (turnNumber < 12 || turnNumber > 90) {
		throw new Error("Frozen profile revision transcript count is outside its input limits");
	}
	const prompt = buildInteractionDnaScoringPrompt(promptSessions, lang);
	if (new TextEncoder().encode(prompt).byteLength > SORA_PROFILE_REVISION_MAX_REQUEST_BYTES) {
		throw new Error("Interaction DNA prompt exceeds its configured byte limit");
	}
	return { prompt, userTurns, lang };
}

export async function scorePreparedInteractionDna(
	prepared: PreparedFrozenDnaScore,
	apiKey: string,
	complete: typeof chatCompleteOnceBounded = chatCompleteOnceBounded,
): Promise<{
	interactionStyle: Record<string, unknown>;
	overallSignature: string;
	preferredPersonaType: string;
  usage: { inputTokens: number; outputTokens: number };
}> {
	const response = await complete(apiKey, [{ role: "user", content: prepared.prompt }], {
		model: MISTRAL_LARGE,
		maxTokens: 2500,
		responseFormat: { type: "json_object" },
		maxRequestBytes: SORA_PROFILE_REVISION_MAX_REQUEST_BYTES + 2_000,
		maxResponseBytes: SORA_PROFILE_REVISION_MAX_RESPONSE_BYTES,
	});
	if (response.finishReason === "length") throw new Error("Interaction DNA response was truncated");
	let parsedValue: unknown;
	try {
		parsedValue = JSON.parse(response.content.trim());
	} catch {
		throw new Error("Interaction DNA response was not valid JSON");
	}
	const parsed = InteractionDnaResultSchema.parse(parsedValue);
	for (const feature of Object.values(parsed.features)) {
		feature.evidence_turns = feature.evidence_turns.filter((turn) => Number.isInteger(turn) && prepared.userTurns.has(turn));
	}
	return {
		interactionStyle: {
			...buildInteractionStyle(parsed.features, prepared.lang),
			overall_signature: parsed.overall_interaction_signature,
			preferred_persona_type: parsed.preferred_persona_type,
		},
		overallSignature: parsed.overall_interaction_signature,
		preferredPersonaType: parsed.preferred_persona_type,
		usage: { inputTokens: response.inputTokens, outputTokens: response.outputTokens },
	};
}

export async function scoreInteractionDnaFromFrozenSessions(
	sessions: readonly FrozenDnaSession[],
	apiKey: string,
	lang: "ja" | "en",
	complete: typeof chatCompleteOnceBounded = chatCompleteOnceBounded,
) {
	return scorePreparedInteractionDna(prepareInteractionDnaFromFrozenSessions(sessions, lang), apiKey, complete);
}

/**
 * Scores a user's interaction DNA from their 3 speed dating sessions.
 * Non-fatal: returns null on failure so the caller can still save the basic profile.
 */
export async function scoreInteractionDna(
	supabase: SupabaseClient<Database>,
	userId: string,
	apiKey: string,
	lang: "ja" | "en",
	complete: typeof chatComplete = chatComplete,
): Promise<{
	interactionStyle: Record<string, unknown>;
	overallSignature: string;
	preferredPersonaType: string;
} | null> {
	try {
		// Fetch completed sessions with persona type info
		const { data: sessions, error: sessionsError } = await supabase
			.from("speed_dating_sessions")
			.select("id, persona_id, completed_at")
			.eq("user_id", userId)
			.eq("status", "completed")
			.order("completed_at", { ascending: false, nullsFirst: false })
			.limit(3);
		if (sessionsError) throw new Error("Failed to load speed dating sessions");

		if (!sessions || sessions.length < 3) {
			console.warn("[scoreInteractionDna] Not enough completed sessions:", sessions?.length ?? 0);
			return null;
		}

		// Fetch persona types for each session
		const personaIds = sessions.map((s) => s.persona_id).filter(Boolean) as string[];
		const { data: personas, error: personasError } = await supabase
			.from("personas")
			.select("id, persona_type")
			.in("id", personaIds);
		if (personasError) throw new Error("Failed to load speed dating personas");

		const personaTypeMap = new Map<string, string>();
		for (const p of personas ?? []) {
			personaTypeMap.set(p.id, p.persona_type);
		}

		// Fetch transcripts for each session
		const sessionTranscripts: { personaType: string; transcript: string }[] = [];
    const userTurns = new Set<number>();
    let turnNumber = 0;
		for (const session of sessions.slice(0, 3).reverse()) {
			const { data: msgs, error: messagesError } = await supabase
				.from("speed_dating_messages")
				.select("role, content")
				.eq("session_id", session.id)
				.order("created_at", { ascending: true });
			if (messagesError) throw new Error("Failed to load speed dating messages");

			const transcript = (msgs ?? [])
				.map((m) => {
          const turn = ++turnNumber;
          if (m.role === "user") userTurns.add(turn);
          return `[Turn ${turn}] ${m.role}: ${m.content}`;
        })
				.join("\n");

			sessionTranscripts.push({
				personaType: personaTypeMap.get(session.persona_id ?? "") ?? "unknown",
				transcript,
			});
		}

		// Call Mistral Large for DNA scoring
		const prompt = buildInteractionDnaScoringPrompt(sessionTranscripts, lang);
		const raw = await complete(apiKey, [{ role: "user", content: prompt }], {
			model: MISTRAL_LARGE,
			maxTokens: 2500,
			responseFormat: { type: "json_object" },
		});

		const parsed = InteractionDnaResultSchema.parse(JSON.parse(raw.trim()));
		for (const feature of Object.values(parsed.features)) {
      feature.evidence_turns = feature.evidence_turns.filter(turn => userTurns.has(turn));
    }
    const interactionStyle = buildInteractionStyle(parsed.features, lang);

		return {
			interactionStyle: {
				...interactionStyle,
				overall_signature: parsed.overall_interaction_signature,
				preferred_persona_type: parsed.preferred_persona_type,
			},
			overallSignature: parsed.overall_interaction_signature,
			preferredPersonaType: parsed.preferred_persona_type,
		};
	} catch {
		console.error("[scoreInteractionDna] DNA scoring failed (non-fatal)");
		return null;
	}
}
