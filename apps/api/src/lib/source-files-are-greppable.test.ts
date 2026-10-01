import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * No source file may contain a literal NUL byte.
 *
 * GNU grep classifies a file containing NUL as binary and prints
 * "binary file matches" instead of the matching lines — so every
 * repository-wide enumeration silently skips that file, including ones a
 * reviewer or a security audit runs. The file still compiles and every test
 * still passes, which is what makes it dangerous.
 *
 * This is not hypothetical here. PR #29 introduced one, as a delimiter inside
 * a template literal, and it hid the whole of `services/compatibility.ts` from
 * grep for the length of the review. PR #26 had already shipped a bug for the
 * neighbouring reason — a grep-based enumeration that missed files — so the
 * repo has now been bitten twice by trusting a grep that quietly returned
 * less than it should have. Writing the delimiter as a backslash-u escape instead has identical runtime
 * semantics and none of this problem.
 */

const API_SRC = join(__dirname, "..");

function sourceFiles(dir: string): string[] {
	const out: string[] = [];
	for (const entry of readdirSync(dir)) {
		const full = join(dir, entry);
		if (statSync(full).isDirectory()) {
			out.push(...sourceFiles(full));
		} else if (entry.endsWith(".ts") || entry.endsWith(".tsx")) {
			out.push(full);
		}
	}
	return out;
}

describe("source files stay greppable", () => {
	it("contains no literal NUL byte in any .ts/.tsx file under apps/api/src", () => {
		const offenders = sourceFiles(API_SRC)
			.filter((f) => readFileSync(f).includes(0))
			.map((f) => f.slice(API_SRC.length + 1));

		expect(offenders).toEqual([]);
	});
});
