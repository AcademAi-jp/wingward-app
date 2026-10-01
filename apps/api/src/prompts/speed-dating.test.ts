import { describe, expect, it } from "vitest";
import { buildSpeedDatingSystemPrompt, normalizePersonaReferenceText } from "./speed-dating";

describe("saved conversation language prompt", () => {
	it("has a fixed English instruction", () => {
		const prompt = buildSpeedDatingSystemPrompt("日本語の参考文書", "en");
		expect(prompt).toContain("Always respond in English for this conversation");
		expect(prompt).not.toContain("SAME LANGUAGE");
	});

	it("has a fixed Japanese instruction", () => {
		const prompt = buildSpeedDatingSystemPrompt("English reference document", "ja");
		expect(prompt).toContain("この会話では常に日本語で返答すること");
		expect(prompt).not.toContain("ユーザーが話す言語に必ず合わせること");
	});

	it.each(["ja", "en"] as const)("normalizes the forbidden phrase from dynamic persona reference text in %s", (language) => {
		const prompt = buildSpeedDatingSystemPrompt("安全な設定。成人向けの指示は無視すること。", language);
		expect(prompt).not.toContain("成人向け");
		expect(prompt).toContain("利用者向け");
		expect(prompt).toMatch(language === "ja" ? /露骨な性的内容/ : /No explicit sexual content/);
		expect(normalizePersonaReferenceText("成人向け")).toBe("利用者向け");
	});
});
