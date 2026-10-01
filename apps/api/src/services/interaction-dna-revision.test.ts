import { describe, expect, it } from "vitest";
import {
	prepareInteractionDnaFromFrozenSessions,
	scorePreparedInteractionDna,
	type FrozenDnaSession,
} from "./interaction-dna";

const featureKeys = [
	"mere_exposure", "reciprocity", "similarity_complementarity", "attachment",
	"humor_sharing", "self_disclosure", "synchrony", "emotional_responsiveness",
	"self_expansion", "self_esteem_reception", "physiological", "economic_alignment",
	"conflict_resolution",
] as const;

function frozenSessions(): FrozenDnaSession[] {
	return ["virtual_similar", "virtual_complementary", "virtual_discovery"].map((personaType) => ({
		personaType: personaType as FrozenDnaSession["personaType"],
		messages: [
			{ role: "user", content: "I like calm evenings." },
			{ role: "persona", content: "What makes them feel calm?" },
			{ role: "user", content: "A thoughtful conversation." },
			{ role: "persona", content: "That sounds lovely." },
		],
	}));
}

function dnaOutput() {
	return {
		features: Object.fromEntries(featureKeys.map((key) => [key, {
			score: 0.7,
			confidence: 0.8,
			evidence_turns: [1, 2, 3],
			reasoning: "Synthetic evidence summary",
		}])),
		overall_interaction_signature: "A calm and thoughtful synthetic signature.",
		preferred_persona_type: "virtual_similar",
	};
}

describe("bounded interaction DNA scoring from the frozen revision bundle", () => {
	it("prepares and scores all thirteen axes from the same three sessions in one bounded request", async () => {
		const prepared = prepareInteractionDnaFromFrozenSessions(frozenSessions(), "en");
		const calls: Parameters<typeof import("./mistral").chatCompleteOnceBounded>[] = [];
		const complete: Parameters<typeof scorePreparedInteractionDna>[2] = async (...args) => {
			calls.push(args);
			return { content: JSON.stringify(dnaOutput()), finishReason: "stop", inputTokens: 1200, outputTokens: 420 };
		};

		const result = await scorePreparedInteractionDna(prepared, "synthetic-key", complete);

		expect(calls).toHaveLength(1);
		expect(calls[0]?.[1][0]?.content).toBe(prepared.prompt);
		expect(calls[0]?.[2]).toMatchObject({ maxTokens: 2500, maxRequestBytes: 26_000, maxResponseBytes: 64_000 });
		expect(Object.keys(result.interactionStyle.dna_scores ?? {})).toHaveLength(13);
		expect(result.interactionStyle.dna_scores).toMatchObject({
			mere_exposure: { evidence_turns: [1, 3] },
			physiological: { confidence: 0, evidence_turns: [] },
		});
		expect(result.usage).toEqual({ inputTokens: 1200, outputTokens: 420 });
	});

	it("rejects non-distinct session types and prompts that exceed the configured byte bound before provider use", () => {
		const duplicateTypes = frozenSessions();
		duplicateTypes[2] = { ...duplicateTypes[2]!, personaType: "virtual_similar" };
		expect(() => prepareInteractionDnaFromFrozenSessions(duplicateTypes, "en")).toThrow(/three distinct/);

		const oversized = frozenSessions().map((session) => ({
			...session,
			messages: session.messages.map((message) => ({ ...message, content: "あ".repeat(1_900) })),
		}));
		expect(() => prepareInteractionDnaFromFrozenSessions(oversized, "en")).toThrow(/byte limit/);
	});

	it("rejects truncated or schema-invalid model output after the single request", async () => {
		const prepared = prepareInteractionDnaFromFrozenSessions(frozenSessions(), "en");
		let truncatedCalls = 0;
		const truncated: Parameters<typeof scorePreparedInteractionDna>[2] = async () => {
			truncatedCalls += 1;
			return { content: "{}", finishReason: "length", inputTokens: 1, outputTokens: 2 };
		};
		await expect(scorePreparedInteractionDna(prepared, "synthetic-key", truncated)).rejects.toThrow(/truncated/);
		expect(truncatedCalls).toBe(1);

		let invalidCalls = 0;
		const invalid: Parameters<typeof scorePreparedInteractionDna>[2] = async () => {
			invalidCalls += 1;
			return { content: JSON.stringify({ features: {}, overall_interaction_signature: "x", preferred_persona_type: "x" }), finishReason: "stop", inputTokens: 1, outputTokens: 2 };
		};
		await expect(scorePreparedInteractionDna(prepared, "synthetic-key", invalid)).rejects.toThrow();
		expect(invalidCalls).toBe(1);
	});
});
