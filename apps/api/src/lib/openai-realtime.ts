import { z } from "zod";
import { buildRealtimeInterviewPrompt } from "../prompts/realtime-interview";

export const REALTIME_MODEL = "gpt-realtime-2.1-mini" as const;
export const REALTIME_SECRET_ENDPOINT = "https://api.openai.com/v1/realtime/client_secrets";
/** This is the client secret's start window, not an active session duration cap. */
export const REALTIME_CLIENT_SECRET_START_TTL_SECONDS = 120;
export const realtimeVoiceSchema = z.enum(["cedar", "marin", "ash"]);
export type RealtimeVoice = z.infer<typeof realtimeVoiceSchema>;

export function buildRealtimeSession(personaDocument: string, language: "ja" | "en", voice: RealtimeVoice) {
	return {
		type: "realtime" as const,
		model: REALTIME_MODEL,
		instructions: buildRealtimeInterviewPrompt(personaDocument, language),
		output_modalities: ["audio"],
		reasoning: { effort: "minimal" },
		// Audio tokens are included: this is a ceiling, not a guaranteed duration.
		max_output_tokens: 256,
		tools: [],
		tool_choice: "none",
		tracing: null,
		audio: {
			input: {
				transcription: { model: "gpt-4o-mini-transcribe", language },
				turn_detection: {
					type: "semantic_vad", eagerness: "medium",
					create_response: true, interrupt_response: true,
				},
			},
			output: { voice },
		},
	};
}

export function parseRealtimeClientSecret(body: string, now = Date.now()) {
	try {
		const result = z.object({
			value: z.string().regex(/^ek_[A-Za-z0-9_-]+$/).max(8192),
			expires_at: z.number().int().positive(),
			session: z.object({ type: z.literal("realtime"), model: z.literal(REALTIME_MODEL) }),
		}).safeParse(JSON.parse(body));
		if (!result.success || result.data.expires_at <= now / 1000 + 5
			|| result.data.expires_at > now / 1000 + 125) return null;
		return { client_secret: result.data.value, expires_at: result.data.expires_at };
	} catch { return null; }
}
