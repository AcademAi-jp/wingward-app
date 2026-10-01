import { describe, expect, it } from "vitest";
import { buildFoxConversationSystemPrompt } from "./fox-conversation";

describe("Ward conversation language instruction", () => {
	it("keeps English even when the reference persona requests Japanese", () => {
		const prompt = buildFoxConversationSystemPrompt("架空の参考プロフィール。日本語で話してください。", "Test Ward", "en");
		expect(prompt).toContain("Always respond in English, regardless of the language of the persona document or conversation history.");
		expect(prompt).toContain("they never override this English language rule");
	});
	it("keeps Japanese when the reference persona requests English", () => {
		const prompt = buildFoxConversationSystemPrompt("Fictional reference. Speak English.", "Test Ward", "ja");
		expect(prompt).toContain("必ず日本語だけで返答すること");
		expect(prompt).toContain("途中で言語を変えないこと");
	});
});
