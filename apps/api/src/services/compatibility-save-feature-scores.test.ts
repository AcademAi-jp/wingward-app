import { describe, expect, it, vi } from "vitest";
import { calculateCompatibility, loadFeatureScores, saveFeatureScores } from "./compatibility";

/**
 * `saveFeatureScores` used to upsert one row per feature — up to 14
 * subrequests per match, issued inside `executeDailyMatching`'s per-match loop,
 * against a Workers Free ceiling of 50 external subrequests per invocation.
 * These tests pin the batched shape (step 4-C).
 *
 * The subtle part is duplicate conflict keys. A sequential loop applied
 * same-key rows one after another, so the LAST one won; a single multi-row
 * upsert cannot, because Postgres rejects a statement carrying two rows with
 * the same conflict target ("ON CONFLICT DO UPDATE command cannot affect row a
 * second time"). Collapsing them here is what keeps the two shapes equivalent
 * rather than merely similar.
 */

interface UpsertCall {
	rows: Record<string, unknown>[];
	options: unknown;
}

function makeSupabase(error: { message: string } | null = null) {
	const calls: UpsertCall[] = [];
	const supabase = {
		from: () => ({
			upsert: (rows: Record<string, unknown>[], options: unknown) => {
				calls.push({ rows, options });
				return Promise.resolve({ data: null, error });
			},
		}),
	};
	return { supabase, calls };
}

function score(featureId: number, sourcePhase: string, rawScore: number) {
	return {
		featureId,
		featureName: `feature-${featureId}`,
		rawScore,
		normalizedScore: rawScore,
		confidence: 0.9,
		evidence: { note: `raw ${rawScore}` },
		sourcePhase,
	};
}

describe("saveFeatureScores writes every feature in one subrequest (step 4-C)", () => {
	it("issues exactly ONE upsert for fourteen feature scores, not fourteen", async () => {
		const { supabase, calls } = makeSupabase();
		const scores = Array.from({ length: 14 }, (_, i) => score(i + 1, "profile", (i + 1) / 100));

		await saveFeatureScores(supabase as never, "match-1", scores as never);

		expect(calls).toHaveLength(1);
		expect(calls[0].rows).toHaveLength(14);
		expect(calls[0].options).toEqual({ onConflict: "match_id,feature_id,source_phase" });
		expect(calls[0].rows.every((r) => r.match_id === "match-1")).toBe(true);
	});

	it("makes no request at all for an empty score list", async () => {
		const { supabase, calls } = makeSupabase();

		await saveFeatureScores(supabase as never, "match-1", []);

		expect(calls).toHaveLength(0);
	});

	it("collapses duplicate (feature_id, source_phase) pairs keeping the LAST — what the sequential loop produced", async () => {
		const { supabase, calls } = makeSupabase();
		const scores = [score(1, "profile", 0.1), score(2, "profile", 0.2), score(1, "profile", 0.9)];

		await saveFeatureScores(supabase as never, "match-1", scores as never);

		expect(calls[0].rows).toHaveLength(2);
		const feature1 = calls[0].rows.find((r) => r.feature_id === 1);
		expect(feature1?.raw_score).toBe(0.9);
	});

	it("does NOT collapse the same feature recorded under a different source_phase — that is a distinct row, not a duplicate", async () => {
		const { supabase, calls } = makeSupabase();
		const scores = [score(1, "profile", 0.1), score(1, "conversation", 0.7)];

		await saveFeatureScores(supabase as never, "match-1", scores as never);

		expect(calls[0].rows).toHaveLength(2);
	});

	it("logs a PostgREST error instead of discarding it — the previous loop ignored its result entirely", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const { supabase } = makeSupabase({ message: "permission denied" });

		await saveFeatureScores(supabase as never, "match-1", [score(1, "profile", 0.1)] as never);

		expect(consoleErrorSpy).toHaveBeenCalledWith("[saveFeatureScores] failed to upsert feature scores");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("match-1");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("permission denied");

		consoleErrorSpy.mockRestore();
	});

	it("does not throw on that error — callers have no handling for one, and aborting the batch would be a behaviour change", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const { supabase } = makeSupabase({ message: "permission denied" });

		await expect(saveFeatureScores(supabase as never, "match-1", [score(1, "profile", 0.1)] as never)).resolves.toBeUndefined();

		consoleErrorSpy.mockRestore();
	});

	it("can opt into a checked failure for rehearsal writes without changing legacy callers", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const { supabase } = makeSupabase({ message: "permission denied" });

		await expect(
			saveFeatureScores(supabase as never, "match-1", [score(1, "profile", 0.1)] as never, { throwOnError: true }),
		).rejects.toThrow("Failed to save feature scores");

		consoleErrorSpy.mockRestore();
	});
});

describe("compatibility state reads and writes fail closed", () => {
	it("throws when feature-score loading returns a PostgREST error", async () => {
		const query: Record<string, unknown> = {};
		for (const method of ["select", "eq"]) query[method] = () => query;
		query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) =>
			Promise.resolve({ data: null, error: { message: "canary" } }).then(resolve, reject);
		await expect(loadFeatureScores({ from: () => query } as never, "match-1")).rejects.toThrow("Failed to load feature scores");
	});

	it("throws when the final match-score update returns a PostgREST error", async () => {
		let calls = 0;
		const supabase = {
			from() {
				calls += 1;
				const result = calls === 1
					? { data: null, error: null }
					: calls === 2
						? { data: [], error: null }
						: { data: null, error: { message: "canary" } };
				const query: Record<string, unknown> = {};
				for (const method of ["upsert", "select", "eq", "update"]) query[method] = () => query;
				query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve(result).then(resolve, reject);
				return query;
			},
		};
		await expect(calculateCompatibility(supabase as never, "match-1", {} as never, {} as never)).rejects.toThrow("Failed to update match scores");
	});
});
