import { describe, expect, it } from "vitest";
import {
	DURABLE_DAILY_BATCH_PAGE_SIZE,
	executeDurableDailyBatch,
	type DurableDailyPairSnapshot,
} from "./durable-daily-batch";

const BATCH_ID = "11111111-1111-4111-8111-111111111111";
const LEASE_TOKEN = "22222222-2222-4222-8222-222222222222";
const USER_A = "33333333-3333-4333-8333-333333333333";
const USER_B = "44444444-4444-4444-8444-444444444444";

function claim(overrides: Record<string, unknown> = {}) {
	return {
		state: "claimed",
		batch_id: BATCH_ID,
		lease_token: LEASE_TOKEN,
		lease_generation: 1,
		member_cursor: null,
		member_scan_complete: true,
		pair_cursor_user_a: null,
		pair_cursor_user_b: null,
		pair_scan_complete: false,
		total_users: 2,
		users_matched: 0,
		total_matches: 0,
		...overrides,
	};
}

function profile(userId: string) {
	return {
		user_id: userId,
		basic_info: {},
		personality_tags: [],
		personality_analysis: {},
		interaction_style: {},
		interests: [],
		values: {},
		communication_style: {},
	};
}

function eligibility(userId: string) {
	return {
		id: userId,
		age_verified_at: "2026-09-01T00:00:00Z",
		gender_identity: "man",
		preferred_genders: ["woman"],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-09-01T00:00:00Z",
	};
}

function pair(): DurableDailyPairSnapshot {
	return {
		user_a_id: USER_A,
		user_b_id: USER_B,
		eligibility_a: eligibility(USER_A),
		eligibility_b: eligibility(USER_B),
		profile_a: profile(USER_A),
		profile_b: profile(USER_B),
		persona_traits_a: {},
		persona_traits_b: { priority_value: "learning" },
		profile_version_a: 1,
		profile_version_b: 1,
		profile_updated_at_a: "2026-09-01T00:00:00Z",
		profile_updated_at_b: "2026-09-01T00:00:00Z",
		persona_version_a: 0,
		persona_version_b: 1,
		blocked: false,
		existing_match: false,
	};
}

function makeSupabase(responses: Record<string, unknown[]>) {
	const calls: { name: string; args: Record<string, unknown> }[] = [];
	const supabase = {
		rpc(name: string, args: Record<string, unknown>) {
			calls.push({ name, args });
			const response = responses[name]?.shift();
			return Promise.resolve({ data: response ?? null, error: null });
		},
	};
	return { supabase: supabase as never, calls };
}

function completedPage(overrides: Record<string, unknown> = {}) {
	return {
		pairs: [pair()],
		next_user_a_id: USER_A,
		next_user_b_id: USER_B,
		done: true,
		...overrides,
	};
}

const score = (snapshot: DurableDailyPairSnapshot) => ({
	user_a_id: snapshot.user_a_id,
	user_b_id: snapshot.user_b_id,
	score: 0.87,
	score_details: { mutual_preferences: 0.87 },
	layer_scores: {},
	feature_scores: [],
});

describe("durable daily matching coordinator", () => {
	it("returns busy without doing page or publication work", async () => {
		const { supabase, calls } = makeSupabase({
			claim_durable_daily_matching_batch: [claim({ state: "busy", lease_token: null })],
		});

		const result = await executeDurableDailyBatch(supabase, "2026-09-26", score);

		expect(result).toMatchObject({ state: "busy", batchId: BATCH_ID });
		expect(calls.map((call) => call.name)).toEqual(["claim_durable_daily_matching_batch"]);
	});

	it("rejects an invalid page budget before claiming a lease", async () => {
		const { supabase, calls } = makeSupabase({});

		await expect(executeDurableDailyBatch(supabase, "2026-09-26", score, { pageBudget: 0 }))
			.rejects.toThrow(/page budget/);
		expect(calls).toHaveLength(0);
	});

	it("does not create a batch when called in resume-only mode before a batch exists", async () => {
		const { supabase, calls } = makeSupabase({
			claim_durable_daily_matching_batch: [claim({ state: "not_started", batch_id: null, lease_token: null })],
		});

		const result = await executeDurableDailyBatch(supabase, "2026-09-26", score, { resumeOnly: true });

		expect(result.state).toBe("not_started");
		expect(calls[0].args.p_resume_only).toBe(true);
		expect(calls).toHaveLength(1);
	});

	it("yields a bounded member scan and releases the same lease for a later resume", async () => {
		const { supabase, calls } = makeSupabase({
			claim_durable_daily_matching_batch: [claim({ member_scan_complete: false })],
			scan_durable_daily_matching_member_page: [{ next_user_id: USER_A, done: false, scanned_count: 1 }],
			release_durable_daily_matching_lease: [true],
		});

		const result = await executeDurableDailyBatch(supabase, "2026-09-26", score, { pageBudget: 1 });

		expect(result).toMatchObject({ state: "resumable", batchId: BATCH_ID });
		expect(calls.map((call) => call.name)).toEqual([
			"claim_durable_daily_matching_batch",
			"scan_durable_daily_matching_member_page",
			"release_durable_daily_matching_lease",
		]);
		expect(calls[1].args).toMatchObject({ p_after_user_id: null, p_limit: DURABLE_DAILY_BATCH_PAGE_SIZE });
		expect(calls[2].args).toMatchObject({ p_batch_id: BATCH_ID, p_lease_token: LEASE_TOKEN, p_lease_generation: 1 });
	});

	it("publishes only after a complete pair page was scored and staged", async () => {
		const { supabase, calls } = makeSupabase({
			claim_durable_daily_matching_batch: [claim()],
			read_durable_daily_matching_pair_page: [completedPage()],
			stage_durable_daily_matching_candidate_page: [true],
			publish_durable_daily_matching_batch: [{
				state: "completed", batch_id: BATCH_ID, total_users: 2, users_matched: 2, total_matches: 1,
			}],
		});
		const scored: DurableDailyPairSnapshot[] = [];

		const result = await executeDurableDailyBatch(supabase, "2026-09-26", (snapshot) => {
			scored.push(snapshot);
			return score(snapshot);
		});

		expect(result).toEqual({ state: "completed", batchId: BATCH_ID, totalUsers: 2, usersMatched: 2, totalMatches: 1 });
		expect(scored).toHaveLength(1);
		expect(calls.map((call) => call.name)).toEqual([
			"claim_durable_daily_matching_batch",
			"read_durable_daily_matching_pair_page",
			"stage_durable_daily_matching_candidate_page",
			"publish_durable_daily_matching_batch",
		]);
		expect(calls[2].args).toMatchObject({ p_candidates: [expect.objectContaining({ score: 0.87 })], p_done: true });
		expect(calls[3].args.p_max_per_user).toBe(1);
	});

	it("stages a partial pair page, releases the lease, and does not publish early", async () => {
		const { supabase, calls } = makeSupabase({
			claim_durable_daily_matching_batch: [claim()],
			read_durable_daily_matching_pair_page: [completedPage({ done: false })],
			stage_durable_daily_matching_candidate_page: [true],
			release_durable_daily_matching_lease: [true],
		});

		const result = await executeDurableDailyBatch(supabase, "2026-09-26", score, { pageBudget: 2 });

		expect(result.state).toBe("resumable");
		expect(calls.map((call) => call.name)).toEqual([
			"claim_durable_daily_matching_batch",
			"read_durable_daily_matching_pair_page",
			"stage_durable_daily_matching_candidate_page",
			"release_durable_daily_matching_lease",
		]);
	});

	it("rejects an oversized provider page and never stages or publishes it", async () => {
		const { supabase, calls } = makeSupabase({
			claim_durable_daily_matching_batch: [claim()],
			read_durable_daily_matching_pair_page: [completedPage({
				pairs: Array.from({ length: DURABLE_DAILY_BATCH_PAGE_SIZE + 1 }, () => pair()),
			})],
			release_durable_daily_matching_lease: [true],
		});
		const scorer = () => score(pair());

		await expect(executeDurableDailyBatch(supabase, "2026-09-26", scorer)).rejects.toThrow(/invalid response/);
		expect(calls.map((call) => call.name)).toEqual([
			"claim_durable_daily_matching_batch",
			"read_durable_daily_matching_pair_page",
			"release_durable_daily_matching_lease",
		]);
	});
});
