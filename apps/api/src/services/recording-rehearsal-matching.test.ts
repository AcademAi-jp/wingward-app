import { beforeEach, describe, expect, it, vi } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { readRecordingRehearsalConfig } from "./recording-rehearsal";
import { runRecordingRehearsalMatching } from "./recording-rehearsal-matching";

vi.mock("./compatibility", async () => {
	const actual = await vi.importActual<typeof import("./compatibility")>("./compatibility");
	return {
		...actual,
		computeProfileFeatureScores: vi.fn(),
		saveFeatureScores: vi.fn().mockResolvedValue(undefined),
	};
});

const { computeProfileFeatureScores, saveFeatureScores } = await import("./compatibility");

const NOW = Date.parse("2026-09-26T20:00:00.000Z");
const VALID_ENV = {
	RECORDING_REHEARSAL_ENABLED: "enabled",
	RECORDING_REHEARSAL_ISSUED_AT: "2026-09-26T19:30:00.000Z",
	RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T21:30:00.000Z",
	RECORDING_REHEARSAL_PAIR: "sora-ren",
} as const;
const configResult = readRecordingRehearsalConfig(VALID_ENV, NOW);
if (configResult.kind !== "active") throw new Error("Expected active test rehearsal");
const config = configResult.config;
const PAIR = config.generationPair;
const FEATURE_SCORES = [
	{ featureId: 7, featureName: "self-disclosure", rawScore: 0.5, normalizedScore: 0.5, confidence: 0.6, evidence: {}, sourcePhase: "quiz" as const },
	{ featureId: 14, featureName: "conflict-resolution", rawScore: 0.5, normalizedScore: 0.5, confidence: 0.6, evidence: {}, sourcePhase: "quiz" as const },
];

type QueryRecord = {
	table: string;
	action: "select" | "insert";
	filters: Array<{ kind: "in" | "eq"; column: string; value: unknown }>;
	rows?: Array<{ user_a_id: string; user_b_id: string }>;
};

function profile(userId: string) {
	return {
		user_id: userId,
		status: "confirmed",
		basic_info: { location: "Seattle" },
		personality_analysis: {},
		personality_tags: [],
		interests: [],
		values: {},
		interaction_style: {},
		communication_style: {},
	};
}

function eligibility(id: string, identity: "woman" | "man") {
	return {
		id,
		age_verified_at: "2026-09-01T00:00:00.000Z",
		gender_identity: identity,
		preferred_genders: [identity === "woman" ? "man" : "woman"],
		preference_mode: "selected",
		dating_market: "US",
		onboarding_settings_completed_at: "2026-09-01T00:00:00.000Z",
	};
}

function makeSupabase(options: {
	pair?: readonly [string, string];
	existing?: Array<{ user_a_id: string; user_b_id: string }>;
	blocks?: Array<{ blocker_id: string; blocked_id: string }>;
	firstInsertError?: { code: string; message: string };
	onAwait?: (query: QueryRecord) => void;
	onInsertError?: (existing: Array<{ user_a_id: string; user_b_id: string }>) => void;
}) {
	const pair = options.pair ?? PAIR;
	const queries: QueryRecord[] = [];
	const inserts: Array<Array<{ user_a_id: string; user_b_id: string }>> = [];
	const created: Array<{ id: string; user_a_id: string; user_b_id: string }> = [];
	const existing = [...(options.existing ?? [])];
	const supabase = {
		from(table: string) {
			const query: QueryRecord = { table, action: "select", filters: [] };
			const builder = {
				select(_columns?: string) {
					return builder;
				},
				eq(column: string, value: unknown) {
					query.filters.push({ kind: "eq", column, value });
					return builder;
				},
				in(column: string, value: unknown) {
					query.filters.push({ kind: "in", column, value });
					return builder;
				},
				insert(rows: Array<{ user_a_id: string; user_b_id: string }>) {
					query.action = "insert";
					query.rows = rows;
					return builder;
				},
				then(resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) {
					queries.push({
						table: query.table,
						action: query.action,
						filters: [...query.filters],
						rows: query.rows,
					});
					options.onAwait?.(query);
					let result: unknown;
					if (query.table === "profiles" && query.action === "select") {
						result = { data: pair.map(profile), error: null };
					} else if (query.table === "user_profiles" && query.action === "select") {
						result = { data: [eligibility(pair[0], "woman"), eligibility(pair[1], "man")], error: null };
					} else if (query.table === "blocks" && query.action === "select") {
						result = { data: options.blocks ?? [], error: null };
					} else if (query.table === "matches" && query.action === "select") {
						result = { data: existing, error: null };
					} else if (query.table === "matches" && query.action === "insert") {
						inserts.push(query.rows ?? []);
						if (inserts.length === 1 && options.firstInsertError) {
							options.onInsertError?.(existing);
							result = { data: null, error: options.firstInsertError };
						} else {
							for (const row of query.rows ?? []) {
								created.push({ id: "match-" + String(created.length + 1), ...row });
								existing.push({ user_a_id: row.user_a_id, user_b_id: row.user_b_id });
							}
							result = { data: (query.rows ?? []).map((_, index) => ({ id: "match-" + String(index + 1) })), error: null };
						}
					} else {
						throw new Error("Unexpected query table or action");
					}
					return Promise.resolve(result).then(resolve, reject);
				},
			};
			return builder;
		},
	};
	return {
		supabase: supabase as unknown as SupabaseClient<Database>,
		queries,
		inserts,
		created,
		existing,
	};
}

beforeEach(() => {
	vi.mocked(computeProfileFeatureScores).mockClear().mockReturnValue(FEATURE_SCORES as never);
	vi.mocked(saveFeatureScores).mockClear().mockResolvedValue(undefined);
});

describe("recording rehearsal matching", () => {
	it("previews the selected pair with the production score path and performs zero writes", async () => {
		const db = makeSupabase({});
		const result = await runRecordingRehearsalMatching(db.supabase, config, PAIR[0], "preview", () => NOW);

		expect(result).toEqual({ outcome: "eligible", count: 1 });
		expect(db.inserts).toHaveLength(0);
		expect(db.created).toHaveLength(0);
		expect(saveFeatureScores).not.toHaveBeenCalled();
		expect(computeProfileFeatureScores).toHaveBeenCalledOnce();
		for (const table of ["profiles", "blocks", "matches"]) {
			const query = db.queries.find((item) => item.table === table && item.action === "select");
			expect(query?.filters.filter((item) => item.kind === "in")).toEqual(
				expect.arrayContaining([
					expect.objectContaining({ value: PAIR }),
				]),
			);
		}
	});

	it("returns an existing pair without changing its row or saving scores", async () => {
		const row = {
			user_a_id: PAIR[0] < PAIR[1] ? PAIR[0] : PAIR[1],
			user_b_id: PAIR[0] < PAIR[1] ? PAIR[1] : PAIR[0],
		};
		const db = makeSupabase({ existing: [row] });

		const result = await runRecordingRehearsalMatching(db.supabase, config, PAIR[0], "start", () => NOW);

		expect(result).toEqual({ outcome: "already_exists", count: 0 });
		expect(db.inserts).toHaveLength(0);
		expect(db.created).toHaveLength(0);
		expect(saveFeatureScores).not.toHaveBeenCalled();
	});

	it("returns already-existing on a repeated start without a second insert", async () => {
		const db = makeSupabase({});
		const first = await runRecordingRehearsalMatching(db.supabase, config, PAIR[0], "start", () => NOW);
		const second = await runRecordingRehearsalMatching(db.supabase, config, PAIR[0], "start", () => NOW);

		expect(first).toEqual({ outcome: "started", count: 1 });
		expect(second).toEqual({ outcome: "already_exists", count: 0 });
		expect(db.inserts).toHaveLength(1);
		expect(db.created).toHaveLength(1);
	});

	it("rejects an account outside the selected pair before any database read", async () => {
		const db = makeSupabase({});
		const result = await runRecordingRehearsalMatching(db.supabase, config, "11111111-1111-4111-8111-111111111111", "start", () => NOW);

		expect(result).toEqual({ outcome: "not_selected_member", count: 0 });
		expect(db.queries).toHaveLength(0);
		expect(db.inserts).toHaveLength(0);
	});

	it("stops after a profile await that reaches expiry and issues no later reads or writes", async () => {
		let clock = NOW;
		const db = makeSupabase({
			onAwait(query) {
				if (query.table === "profiles") clock = config.expiresAtMs;
			},
		});
		const result = await runRecordingRehearsalMatching(db.supabase, config, PAIR[0], "start", () => clock);

		expect(result).toEqual({ outcome: "expired", count: 0 });
		expect(db.queries.map((query) => query.table)).toEqual(["profiles"]);
		expect(db.inserts).toHaveLength(0);
	});

	it("rechecks expiry after insert and reports a retained partial row without feature writes", async () => {
		let clock = NOW;
		const db = makeSupabase({
			onAwait(query) {
				if (query.table === "matches" && query.action === "insert") clock = config.expiresAtMs;
			},
		});
		const result = await runRecordingRehearsalMatching(db.supabase, config, PAIR[0], "start", () => clock);

		expect(result).toEqual({ outcome: "started_partial", count: 1 });
		expect(db.created).toHaveLength(1);
		expect(saveFeatureScores).not.toHaveBeenCalled();
	});

	it("reports partial when the checked feature-score write fails and keeps the inserted match", async () => {
		const db = makeSupabase({});
		vi.mocked(saveFeatureScores).mockRejectedValueOnce(new Error("database detail"));

		const result = await runRecordingRehearsalMatching(db.supabase, config, PAIR[0], "start", () => NOW);

		expect(result).toEqual({ outcome: "started_partial", count: 1 });
		expect(db.created).toHaveLength(1);
		expect(saveFeatureScores).toHaveBeenCalledWith(
			db.supabase,
			expect.stringMatching(/^match-/),
			FEATURE_SCORES,
			{ throwOnError: true },
		);
	});

	it("uses one bounded 23514 refresh/retry with pair-scoped block reads", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		const db = makeSupabase({ firstInsertError: { code: "23514", message: "constraint detail" } });

		try {
			const result = await runRecordingRehearsalMatching(db.supabase, config, PAIR[0], "start", () => NOW);
			expect(result).toEqual({ outcome: "started", count: 1 });
			expect(db.inserts).toHaveLength(2);
			const refreshedBlocks = db.queries.find((query) => query.table === "blocks");
			expect(refreshedBlocks?.filters).toEqual([
				{ kind: "in", column: "blocker_id", value: PAIR },
				{ kind: "in", column: "blocked_id", value: PAIR },
			]);
			expect(saveFeatureScores).toHaveBeenCalledOnce();
		} finally {
			warn.mockRestore();
		}
	});

	it("treats a concurrent unique insert as already existing without resetting it", async () => {
		const db = makeSupabase({
			firstInsertError: { code: "23505", message: "unique detail" },
			onInsertError(existing) {
				existing.push({
					user_a_id: PAIR[0] < PAIR[1] ? PAIR[0] : PAIR[1],
					user_b_id: PAIR[0] < PAIR[1] ? PAIR[1] : PAIR[0],
				});
			},
		});

		const result = await runRecordingRehearsalMatching(db.supabase, config, PAIR[0], "start", () => NOW);

		expect(result).toEqual({ outcome: "already_exists", count: 0 });
		expect(db.inserts).toHaveLength(1);
		expect(db.created).toHaveLength(0);
		expect(saveFeatureScores).not.toHaveBeenCalled();
	});
});


it("Maya/Ren owner prep previews normal matching scores with exact scoped reads and no writes", async () => {
	const result = readRecordingRehearsalConfig({ ...VALID_ENV, RECORDING_REHEARSAL_PAIR: "demo-maya-ren", RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enabled" }, NOW);
	if (result.kind !== "active") throw new Error("Expected Maya/Ren prep");
	const pair = result.config.generationPair;
	const db = makeSupabase({ pair });
	await expect(runRecordingRehearsalMatching(db.supabase, result.config, pair[0], "preview", () => NOW)).resolves.toEqual({ outcome: "eligible", count: 1 });
	expect(db.inserts).toHaveLength(0);
	expect(db.created).toHaveLength(0);
	expect(saveFeatureScores).not.toHaveBeenCalled();
	expect(computeProfileFeatureScores).toHaveBeenCalledOnce();
	for (const query of db.queries) {
		for (const filter of query.filters.filter(item => item.kind === "in")) expect(filter.value).toEqual(pair);
	}
});
