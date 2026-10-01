import { describe, expect, it } from "vitest";
import { buildVirtualPersonaPrompt } from "./virtual-persona";

describe("virtual persona prompt privacy boundary", () => {
	it("does not request an opposite-gender persona or emit the owner's private preferences", () => {
		const prompt = buildVirtualPersonaPrompt(
			JSON.stringify([{ question_id: "q1", selected: ["coffee"] }]),
			"virtual_similar",
			[],
			"en",
		);

		expect(prompt).not.toContain("opposite gender");
		expect(prompt).not.toContain("gender:");
		expect(prompt).not.toContain("preferred_genders");
		expect(prompt).not.toContain("station_id");
	});

	it("keeps the requested saved locale for persona text", () => {
		expect(buildVirtualPersonaPrompt("[]", "virtual_discovery", [], "ja")).toContain("仮想ペルソナ");
		expect(buildVirtualPersonaPrompt("[]", "virtual_discovery", [], "en")).toContain("virtual personas");
	});

	it("normalizes the forbidden phrase from dynamic quiz reference text", () => {
		const prompt = buildVirtualPersonaPrompt("[{\"selected\":\"成人向け\"}]", "virtual_discovery", [], "ja");
		expect(prompt).not.toContain("成人向け");
		expect(prompt).toContain("利用者向け");
	});
});
