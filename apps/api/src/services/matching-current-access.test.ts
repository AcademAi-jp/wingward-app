import { describe, expect, it } from "vitest";
import {
	MAX_MATCHING_CURRENT_SNAPSHOT_EXPECTATIONS,
	MATCHING_CURRENT_SNAPSHOT_SELECT,
	readMatchingCurrentSnapshot,
	type MatchingCurrentSnapshotExpectation,
} from "./matching-current-access";

const USER_A = "10000000-0000-0000-0000-000000000001";
const USER_B = "10000000-0000-0000-0000-000000000002";
const USER_C = "10000000-0000-0000-0000-000000000003";
const MATCH_ID = "20000000-0000-0000-0000-000000000001";
const CONVERSATION_ID = "30000000-0000-0000-0000-000000000001";

type QueryResult = { data: unknown; error: unknown };
type Trace = { table: string; select?: string; filters: Array<[string, unknown]> };

function profile(id: string, gender: "woman" | "man", preferred: "woman" | "man", blocks_sent: unknown[] = []) {
	return {
		id,
		nickname: id,
		avatar_url: null,
		age_verified_at: "2026-09-01T00:00:00.000Z",
		gender_identity: gender,
		preferred_genders: [preferred],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-09-01T00:00:00.000Z",
		blocks_sent,
	};
}

function row(overrides: Record<string, unknown> = {}) {
	return {
		id: MATCH_ID,
		user_a_id: USER_A,
		user_b_id: USER_B,
		final_score: 0.9,
		profile_score: 0.8,
		conversation_score: 0.7,
		status: "fox_conversation_completed",
		score_details: { summary: "ok" },
		layer_scores: {},
		created_at: "2026-09-01T00:00:00.000Z",
		profile_a: profile(USER_A, "woman", "man"),
		profile_b: profile(USER_B, "man", "woman"),
		compatibility_conversations: [
			{ id: CONVERSATION_ID, match_id: MATCH_ID, purpose: "compatibility", status: "completed" },
		],
		...overrides,
	};
}

function expectation(overrides: Partial<MatchingCurrentSnapshotExpectation> = {}): MatchingCurrentSnapshotExpectation {
	return {
		matchId: MATCH_ID,
		ownerId: USER_A,
		participantIds: [USER_A, USER_B],
		...overrides,
	};
}

function fakeSupabase(result: QueryResult) {
	const traces: Trace[] = [];
	const from = (table: string) => {
		const trace: Trace = { table, filters: [] };
		traces.push(trace);
		const query: Record<string, unknown> = {};
		query.select = (columns: string) => {
			trace.select = columns;
			return query;
		};
		query.in = (column: string, values: unknown) => {
			trace.filters.push(["in:" + column, values]);
			return query;
		};
		query.eq = (column: string, value: unknown) => {
			trace.filters.push(["eq:" + column, value]);
			return query;
		};
		query.then = (resolve: (value: QueryResult) => unknown, reject?: (reason: unknown) => unknown) =>
			Promise.resolve(result).then(resolve, reject);
		return query;
	};
	return { from, traces };
}

describe("readMatchingCurrentSnapshot", () => {
	it("reads one embedded snapshot with bounded all-participant block filters and keeps input order", async () => {
		const secondMatch = "20000000-0000-0000-0000-000000000002";
		const first = row();
		const second = row({
			id: secondMatch,
			user_a_id: USER_B,
			user_b_id: USER_C,
			profile_a: profile(USER_B, "man", "woman"),
			profile_b: profile(USER_C, "woman", "man"),
			compatibility_conversations: [],
		});
		const supabase = fakeSupabase({ data: [second, first], error: null });
		const result = await readMatchingCurrentSnapshot(supabase as never, [
			expectation({ matchId: MATCH_ID }),
			expectation({ matchId: secondMatch, ownerId: USER_B, participantIds: [USER_B, USER_C] }),
		]);
		expect(result.ok).toBe(true);
		if (result.ok) expect([...result.rows.keys()]).toEqual([MATCH_ID, secondMatch]);
		const trace = supabase.traces[0];
		expect(trace.select).toBe(MATCHING_CURRENT_SNAPSHOT_SELECT);
		expect(trace.filters).toContainEqual(["eq:compatibility_conversations.purpose", "compatibility"]);
		expect(trace.filters).toContainEqual(["in:profile_a.blocks_sent.blocked_id", [USER_A, USER_B, USER_C]]);
		expect(trace.filters).toContainEqual(["in:profile_b.blocks_sent.blocked_id", [USER_A, USER_B, USER_C]]);
	});

	it("accepts unrelated block rows but denies either exact opposite direction", async () => {
		const unrelated = row({
			profile_a: profile(USER_A, "woman", "man", [{ id: "other", blocker_id: USER_A, blocked_id: USER_C }]),
		});
		const allowed = await readMatchingCurrentSnapshot(fakeSupabase({ data: [unrelated], error: null }) as never, [expectation()]);
		expect(allowed).toMatchObject({ ok: true, rows: new Map([[MATCH_ID, expect.any(Object)]]) });

		const aToB = row({
			profile_a: profile(USER_A, "woman", "man", [{ id: "block-a", blocker_id: USER_A, blocked_id: USER_B }]),
		});
		const bToA = row({
			profile_b: profile(USER_B, "man", "woman", [{ id: "block-b", blocker_id: USER_B, blocked_id: USER_A }]),
		});
		await expect(readMatchingCurrentSnapshot(fakeSupabase({ data: [aToB], error: null }) as never, [expectation()])).resolves.toMatchObject({ ok: true, rows: new Map() });
		await expect(readMatchingCurrentSnapshot(fakeSupabase({ data: [bToA], error: null }) as never, [expectation()])).resolves.toMatchObject({ ok: true, rows: new Map() });
	});

	it.each([
		["age", { profile_b: { ...profile(USER_B, "man", "woman"), age_verified_at: null } }],
		["preference", { profile_b: { ...profile(USER_B, "man", "woman"), preferred_genders: ["man"] } }],
		["market", { profile_b: { ...profile(USER_B, "man", "woman"), dating_market: "US" } }],
		["malformed blocks", { profile_b: { ...profile(USER_B, "man", "woman"), blocks_sent: [[{ id: "nested" }]] } }],
	] as const)("suppresses a final row after %s changes", async (_label, overrides) => {
		const result = await readMatchingCurrentSnapshot(fakeSupabase({ data: [row(overrides)], error: null }) as never, [expectation()]);
		expect(result).toMatchObject({ ok: true, rows: new Map() });
	});

	it("suppresses an exact participant or owner mismatch without leaking the replacement row", async () => {
		const swapped = row({
			user_b_id: USER_C,
			profile_b: profile(USER_C, "man", "woman"),
		});
		await expect(readMatchingCurrentSnapshot(fakeSupabase({ data: [swapped], error: null }) as never, [expectation()])).resolves.toMatchObject({ ok: true, rows: new Map() });
		await expect(readMatchingCurrentSnapshot(fakeSupabase({ data: [row()], error: null }) as never, [expectation({ ownerId: USER_C })])).resolves.toEqual({ ok: false, reason: "error" });
	});

	it.each([
		["none", []],
		["one", [{ id: CONVERSATION_ID, match_id: MATCH_ID, purpose: "compatibility", status: "completed" }]],
		["duplicate", [
			{ id: CONVERSATION_ID, match_id: MATCH_ID, purpose: "compatibility", status: "completed" },
			{ id: "duplicate", match_id: MATCH_ID, purpose: "compatibility", status: "completed" },
		]],
	] as const)("handles compatibility conversation %s without choosing an arbitrary scheduling row", async (_label, conversations) => {
		const result = await readMatchingCurrentSnapshot(fakeSupabase({ data: [row({ compatibility_conversations: conversations })], error: null }) as never, [expectation()]);
		if (_label === "duplicate") {
			expect(result).toMatchObject({ ok: true, rows: new Map() });
		} else {
			expect(result).toMatchObject({ ok: true });
			if (result.ok) expect(result.rows.get(MATCH_ID)?.compatibilityConversation?.id ?? null).toBe(_label === "one" ? CONVERSATION_ID : null);
		}
	});

	it("suppresses malformed compatibility rows instead of treating them as the current conversation", async () => {
		const result = await readMatchingCurrentSnapshot(
			fakeSupabase({
				data: [row({ compatibility_conversations: [{ id: "", match_id: MATCH_ID, purpose: "compatibility", status: "completed" }] })],
				error: null,
			}) as never,
			[expectation()],
		);
		expect(result).toMatchObject({ ok: true, rows: new Map() });
	});

	it("returns query errors separately from unavailable rows", async () => {
		await expect(readMatchingCurrentSnapshot(fakeSupabase({ data: null, error: { message: "down" } }) as never, [expectation()])).resolves.toEqual({ ok: false, reason: "error" });
		await expect(readMatchingCurrentSnapshot(fakeSupabase({ data: [], error: null }) as never, [expectation()])).resolves.toEqual({ ok: true, rows: new Map() });
	});

	it("rejects malformed top-level and duplicate result rows", async () => {
		await expect(readMatchingCurrentSnapshot(fakeSupabase({ data: {}, error: null }) as never, [expectation()])).resolves.toEqual({ ok: false, reason: "error" });
		await expect(readMatchingCurrentSnapshot(fakeSupabase({ data: [row(), row()], error: null }) as never, [expectation()])).resolves.toEqual({ ok: false, reason: "error" });
	});

	it("enforces the 128-row bound before reading and includes all owners in the 128-row request", async () => {
		const expectations = Array.from({ length: MAX_MATCHING_CURRENT_SNAPSHOT_EXPECTATIONS }, (_, index) => ({
			matchId: "match-" + index,
			ownerId: USER_A,
			participantIds: [USER_A, "partner-" + index] as const,
		}));
		const supabase = fakeSupabase({ data: [], error: null });
		const result = await readMatchingCurrentSnapshot(supabase as never, expectations);
		expect(result).toMatchObject({ ok: true, rows: new Map() });
		expect(supabase.traces[0].filters).toContainEqual([
			"in:profile_a.blocks_sent.blocked_id",
			expect.arrayContaining([USER_A, "partner-0"]),
		]);
		expect(supabase.traces[0].filters).toContainEqual([
			"in:profile_b.blocks_sent.blocked_id",
			expect.arrayContaining([USER_A, "partner-0"]),
		]);

		const over = await readMatchingCurrentSnapshot(fakeSupabase({ data: [], error: null }) as never, [
			...expectations,
			{ matchId: "match-over", ownerId: USER_A, participantIds: [USER_A, USER_C] },
		]);
		expect(over).toEqual({ ok: false, reason: "too_many_expectations" });
	});

	it("rejects duplicate expectations and duplicate participant IDs before the query", async () => {
		const supabase = fakeSupabase({ data: [], error: null });
		await expect(readMatchingCurrentSnapshot(supabase as never, [expectation(), expectation()])).resolves.toEqual({ ok: false, reason: "error" });
		await expect(readMatchingCurrentSnapshot(supabase as never, [expectation({ participantIds: [USER_A, USER_A] })])).resolves.toEqual({ ok: false, reason: "error" });
		expect(supabase.traces).toHaveLength(0);
	});
});
