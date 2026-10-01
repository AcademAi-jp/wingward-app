import { describe, expect, it } from "vitest";
import { buildInteractionStyle } from "./interaction-dna";

const keys = ["mere_exposure", "reciprocity", "similarity_complementarity", "attachment", "humor_sharing", "self_disclosure", "synchrony", "emotional_responsiveness", "self_expansion", "self_esteem_reception", "physiological", "economic_alignment", "conflict_resolution"];
function features(evidence: number[]) {
  return Object.fromEntries(keys.map(key => [key, { score: 0.8, confidence: 0.9, evidence_turns: evidence, reasoning: "synthetic observation" }])) as Parameters<typeof buildInteractionStyle>[0];
}
describe("interaction evidence policy", () => {
  it("localizes missing evidence without changing scores", () => {
    const en = buildInteractionStyle(features([]), "en");
    const ja = buildInteractionStyle(features([]), "ja");
    expect(en.dna_scores.attachment.reasoning).toBe("Insufficient transcript evidence");
    expect(ja.dna_scores.attachment.reasoning).toBe("会話の根拠不足");
    expect(en.dna_scores.attachment.score).toBe(ja.dna_scores.attachment.score);
  });
  it("treats absent evidence as unknown even when the LLM gives high confidence", () => {
    const result = buildInteractionStyle(features([]));
    expect(result.dna_scores.humor_sharing).toMatchObject({ score: 0.5, confidence: 0, evidence_turns: [] });
    expect(result.attachment_tendency).toBe("unknown");
    expect(result.conflict_style).toBe("unknown");
  });
  it("preserves supported observations but never invents physiology from text", () => {
    const result = buildInteractionStyle(features([1, 3]));
    expect(result.dna_scores.self_expansion.score).toBe(0.8);
    expect(result.dna_scores.physiological.confidence).toBe(0);
    expect(result.rhythm_preference).toBe("unknown");
  });
  it("rejects invalid evidence numbers as missing evidence", () => {
    expect(buildInteractionStyle(features([-1, 0, 1.5])).dna_scores.attachment.confidence).toBe(0);
  });
});
