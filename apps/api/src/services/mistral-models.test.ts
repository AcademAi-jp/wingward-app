import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { MISTRAL_LARGE, MISTRAL_LIGHT } from "./mistral";

/**
 * `ministral-8b-2410` was the default model here until 2026-08-12, by which
 * point it had been retired for months — every fox conversation would have
 * failed against the live API. Nothing in the build or the test suite noticed,
 * because a model ID is just a string.
 *
 * These tests do not check that a model exists (that needs a live API key and
 * costs money). They check the two properties that let the previous failure go
 * unnoticed: that IDs are pinned rather than floating, and that the retired one
 * cannot come back.
 */

const RETIRED_MODEL_IDS = ["ministral-8b-2410"];

describe("Mistral model IDs", () => {
	it.each([
		["MISTRAL_LARGE", MISTRAL_LARGE],
		["MISTRAL_LIGHT", MISTRAL_LIGHT],
	])("%s is pinned to a dated version, not a -latest alias", (_name, id) => {
		expect(id).not.toMatch(/-latest$/);
		expect(id).toMatch(/-\d{4}$/);
	});

	it("does not reference any retired model ID anywhere in the API source", () => {
		const src = readFileSync(join(__dirname, "mistral.ts"), "utf8");
		for (const retired of RETIRED_MODEL_IDS) {
			expect(src).not.toContain(retired);
		}
	});

	it("uses no -latest alias in the model module", () => {
		const src = readFileSync(join(__dirname, "mistral.ts"), "utf8");
		// The comment block explains the rule; only string literals matter.
		const literals = src.match(/"[a-z0-9-]*-latest"/g) ?? [];
		expect(literals).toEqual([]);
	});
});
