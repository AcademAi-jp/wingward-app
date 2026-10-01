import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Step-3d (loop unification) source-wiring checks, acceptance conditions 6
 * and 7. See docs/spec/impl/step-03d-unify-conversation-loop.md.
 *
 * Before this PR, `durable-objects/fox-conversation-do.ts` (the production
 * path) hardcoded `TOTAL_ROUNDS = 10` while `services/fox-conversation.ts`
 * (the local-dev fallback) read `total_rounds` from the row — and the row's
 * schema default was 15. Those two numbers had already drifted (L-1 in the
 * spec). Likewise `max_tokens` for round generation was 500 in the DO and
 * 200 in the service (L-2). Both were only possible because two independent
 * implementations existed to disagree with each other. These tests assert,
 * from the actual file contents, that this class of drift is now
 * structurally impossible: the DO carries no round-count literal and no
 * `max_tokens` for round generation at all, because it no longer generates
 * rounds — services/fox-conversation-engine.ts is the only file that does.
 */

const API_SRC = join(__dirname, "..");

function read(relPath: string): string {
	return readFileSync(join(API_SRC, relPath), "utf8");
}

describe("acceptance condition 6: round count has exactly one resolution path", () => {
	const doSrc = read("durable-objects/fox-conversation-do.ts");

	it("fox-conversation-do.ts contains no hardcoded round-count constant (e.g. TOTAL_ROUNDS = 10)", () => {
		expect(doSrc).not.toMatch(/TOTAL_ROUNDS/);
	});

	it("fox-conversation-do.ts never imports chatCompleteWithUsage (it no longer generates rounds itself)", () => {
		expect(doSrc).not.toMatch(/chatCompleteWithUsage/);
	});

	it("fox-conversation-do.ts imports runConversationLoop from the engine and calls it exactly once", () => {
		expect(doSrc).toMatch(/import\s*\{\s*runConversationLoop\s*\}\s*from\s*["']\.\.\/services\/fox-conversation-engine["']/);
		const callSites = doSrc.match(/runConversationLoop\(/g) ?? [];
		expect(callSites.length).toBe(1);
	});

	it("fox-conversation-engine.ts (the sole loop implementation) resolves round count from the row, not a literal", () => {
		const engineSrc = read("services/fox-conversation-engine.ts");
		expect(engineSrc).toMatch(/conv\.total_rounds/);
	});
});

describe("acceptance condition 7: maxTokens for round generation is specified exactly once, codebase-wide", () => {
	/**
	 * Scans every .ts file under src/ (excluding tests) for a `maxTokens: 200`
	 * round-generation call. Deliberately whole-tree rather than "just check
	 * the two files we know about": the point of D-2 is that this number must
	 * have exactly one home, wherever that home is.
	 */
	function listSourceFiles(dir: string): string[] {
		const entries = readdirSync(dir, { withFileTypes: true });
		const files: string[] = [];
		for (const entry of entries) {
			const full = join(dir, entry.name);
			if (entry.isDirectory()) {
				if (entry.name === "node_modules") continue;
				files.push(...listSourceFiles(full));
			} else if (entry.name.endsWith(".ts") && !entry.name.endsWith(".test.ts")) {
				files.push(full);
			}
		}
		return files;
	}

	it("maxTokens: 200 appears in exactly one file, services/fox-conversation-engine.ts", () => {
		const files = listSourceFiles(API_SRC);
		const hits = files
			.map((f) => ({ f, src: readFileSync(f, "utf8") }))
			.filter(({ src }) => /maxTokens:\s*200\b/.test(src))
			.map(({ f }) => f.slice(API_SRC.length + 1));

		expect(hits).toEqual(["services/fox-conversation-engine.ts"]);
	});
});
