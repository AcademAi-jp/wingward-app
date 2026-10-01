import { beforeEach, describe, expect, it, vi } from "vitest";
import { executeDailyMatching } from "./daily-matching";
import type { DurableDailyPairSnapshot } from "./durable-daily-batch";

const executeDurableDailyBatch = vi.fn();
vi.mock("./durable-daily-batch", () => ({
	executeDurableDailyBatch: (...args: unknown[]) => executeDurableDailyBatch(...args),
}));

const supabase = { rpc: vi.fn() } as never;

beforeEach(() => executeDurableDailyBatch.mockReset());

function eligibility(userId: string, gender: "man" | "woman", preferred: "man" | "woman") {
	return {
		id: userId,
		age_verified_at: "2026-09-01T00:00:00Z",
		gender_identity: gender,
		preferred_genders: [preferred],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-09-01T00:00:00Z",
	};
}

function profile(userId: string) {
	return {
		user_id: userId,
		basic_info: { location: "Tokyo" },
		personality_tags: ["curious"],
		personality_analysis: { introvert_extrovert: 0.5 },
		interaction_style: { attachment_tendency: "secure" },
		interests: [],
		values: {},
		communication_style: { message_length: "balanced" },
	};
}

function pairSnapshot(personaTraits: Record<string, unknown> = {}): DurableDailyPairSnapshot {
	const userA = "10000000-0000-4000-8000-000000000001";
	const userB = "10000000-0000-4000-8000-000000000002";
	return {
		user_a_id: userA,
		user_b_id: userB,
		eligibility_a: eligibility(userA, "man", "woman"),
		eligibility_b: eligibility(userB, "woman", "man"),
		profile_a: profile(userA),
		profile_b: profile(userB),
		persona_traits_a: personaTraits,
		persona_traits_b: personaTraits,
		profile_version_a: 1,
		profile_version_b: 1,
		profile_updated_at_a: "2026-09-01T00:00:00Z",
		profile_updated_at_b: "2026-09-01T00:00:00Z",
		persona_version_a: personaTraits.priority_value ? 1 : 0,
		persona_version_b: personaTraits.priority_value ? 1 : 0,
		blocked: false,
		existing_match: false,
	};
}

describe("executeDailyMatching rollout and durable delegation", () => {
	it("fails closed when the explicit durable rollout gate is absent", async () => {
		const result = await executeDailyMatching(supabase, "2026-09-26");

		expect(result).toEqual({ status: "disabled", batchId: null, totalUsers: 0, usersMatched: 0, totalMatches: 0 });
		expect(executeDurableDailyBatch).not.toHaveBeenCalled();
	});

	it("fails closed when the new store reports no batch during resume-only", async () => {
		executeDurableDailyBatch.mockResolvedValueOnce({
			state: "not_started", batchId: null, totalUsers: 0, usersMatched: 0, totalMatches: 0,
		});

		const result = await executeDailyMatching(supabase, "2026-09-26", 1, {
			durableEnabled: true,
			resumeOnly: true,
		});

		expect(result.status).toBe("not_started");
		expect(executeDurableDailyBatch).toHaveBeenCalledWith(
			supabase,
			"2026-09-26",
			expect.any(Function),
			{ durableEnabled: true, resumeOnly: true },
		);
	});

	it("does not allow a policy override to publish multiple matches per user", async () => {
		await expect(executeDailyMatching(supabase, "2026-09-26", 2, { durableEnabled: true }))
			.rejects.toThrow(/at most one match per user/);
		expect(executeDurableDailyBatch).not.toHaveBeenCalled();
	});

	it("feeds only the confirmed closed-enum reflection into the legacy scorer", async () => {
		executeDurableDailyBatch.mockResolvedValueOnce({
			state: "resumable", batchId: "batch-1", totalUsers: 2, usersMatched: 0, totalMatches: 0,
		});
		await executeDailyMatching(supabase, "2026-09-26", 1, { durableEnabled: true });
		const scorePair = executeDurableDailyBatch.mock.calls[0][2] as (
			snapshot: DurableDailyPairSnapshot,
		) => { score: number; feature_scores: unknown } | null;

		const legacy = scorePair(pairSnapshot({ free_text: "must never reach the scorer" }));
		const confirmed = scorePair(pairSnapshot({
			social_energy: "ambiverted",
			priority_value: "learning",
			favorite_activity: "reading",
			free_text: "must never reach the scorer",
		}));

		expect(legacy).not.toBeNull();
		expect(confirmed).not.toBeNull();
		expect(confirmed!.score).toBeGreaterThan(legacy!.score);
		expect(JSON.stringify(confirmed)).not.toContain("must never reach the scorer");
	});

	it("propagates only batch metadata from durable publication", async () => {
		executeDurableDailyBatch.mockResolvedValueOnce({
			state: "completed", batchId: "batch-1", totalUsers: 20, usersMatched: 10, totalMatches: 5,
		});

		await expect(executeDailyMatching(supabase, "2026-09-26", 1, { durableEnabled: true }))
			.resolves.toEqual({
				status: "completed", batchId: "batch-1", totalUsers: 20, usersMatched: 10, totalMatches: 5,
			});
	});
});
