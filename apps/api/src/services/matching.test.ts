import { describe, expect, it, vi } from "vitest";
import { applyConfirmedPersonaTraits, executeMatching } from "./matching";
import { MATCHING_ELIGIBILITY_COLUMNS } from "./matching-eligibility";

vi.mock("./compatibility", async () => {
	const actual = await vi.importActual<typeof import("./compatibility")>("./compatibility");
	return {
		...actual,
		computeProfileFeatureScores: vi.fn(),
		saveFeatureScores: vi.fn().mockResolvedValue(undefined),
	};
});

const { computeProfileFeatureScores, saveFeatureScores } = await import("./compatibility");

/**
 * Codex round 4: `executeMatching` (services/matching.ts:214) had the same
 * unhandled shape as the daily-matching bulk insert — the blocked-pair
 * trigger can abort a multi-row INSERT as a whole, and the undestructured
 * `await supabase...insert(...)` treated that as a successful zero-match
 * run (`count: 0`, HTTP 200) instead of a failure. Both call sites now share
 * `insertMatchesRejectingBlockedPairs` (services/insert-matches.ts). This
 * drives `executeMatching` through three users, two valid opposite-gender
 * pairs sharing user-1, a first insert that fails with 23514 (simulating a
 * block that committed after the initial `blocks` read), a re-read of
 * `blocks` that reveals user-1 has since blocked user-3, and a retry that
 * inserts only the surviving pair.
 */
function supabaseForMixedBulkInsert() {
	const profiles = [
		{ user_id: "user-1", status: "confirmed" },
		{ user_id: "user-2", status: "confirmed" },
		{ user_id: "user-3", status: "confirmed" },
	];
	const userProfiles = [
		{ id: "user-1", gender: "male", gender_identity: "man", preferred_genders: ["woman"], dating_market: "JP", preference_mode: "selected", onboarding_settings_completed_at: "2026-08-24T00:00:00Z", age_verified_at: "2026-08-24T00:00:00Z" },
		{ id: "user-2", gender: "female", gender_identity: "woman", preferred_genders: ["man"], dating_market: "JP", preference_mode: "selected", onboarding_settings_completed_at: "2026-08-24T00:00:00Z", age_verified_at: "2026-08-24T00:00:00Z" },
		{ id: "user-3", gender: "female", gender_identity: "woman", preferred_genders: ["man"], dating_market: "JP", preference_mode: "selected", onboarding_settings_completed_at: "2026-08-24T00:00:00Z", age_verified_at: "2026-08-24T00:00:00Z" },
	];

	let blocksCallCount = 0;
	let matchesInsertCallCount = 0;
	const matchesInsertRowsByCall: { user_a_id: string; user_b_id: string }[][] = [];

	// biome-ignore lint/suspicious/noExplicitAny: minimal test double
	const supabase: any = {
		from(table: string) {
			if (table === "profiles") {
				return { select: () => ({ eq: async () => ({ data: profiles, error: null }) }) };
			}
			if (table === "user_profiles") {
				return { select: () => ({ in: async () => ({ data: userProfiles, error: null }) }) };
			}
			if (table === "blocks") {
				return {
					select: async () => {
						blocksCallCount++;
						// First read (before the first insert attempt): nobody
						// blocked. Second read (the trigger's 23514 retry path):
						// user-1 has since blocked user-3.
						if (blocksCallCount === 1) {
							return { data: [], error: null };
						}
						return {
							data: [{ blocker_id: "user-1", blocked_id: "user-3" }],
							error: null,
						};
					},
				};
			}
			if (table === "matches") {
				return {
					select: async () => ({ data: [], error: null }), // existing matches
					insert: (rows: { user_a_id: string; user_b_id: string }[]) => ({
						select: async () => {
							matchesInsertCallCount++;
							matchesInsertRowsByCall.push(rows);
							if (matchesInsertCallCount === 1) {
								return {
									data: null,
									error: { message: "blocked pair: user-1 and user-3 cannot be connected", code: "23514" },
								};
							}
							return {
								data: rows.map((_, i) => ({ id: `match-${i + 1}` })),
								error: null,
							};
						},
					}),
				};
			}
			throw new Error(`unexpected table in test double: ${table}`);
		},
	};

	return { supabase, matchesInsertRowsByCall, getBlocksCallCount: () => blocksCallCount };
}

describe("executeMatching retries the matches insert after the blocked-pair trigger rejects one pair", () => {
	it("keeps the unrelated valid pair instead of discarding the whole batch, with index alignment into saveFeatureScores", async () => {
		const consoleWarnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

		const scoreFor: Record<string, number> = {
			"user-1:user-2": 0.9,
			"user-1:user-3": 0.7,
		};
		vi.mocked(computeProfileFeatureScores).mockImplementation((a: { user_id: string }, b: { user_id: string }) => {
			const key = `${a.user_id}:${b.user_id}`;
			const normalizedScore = scoreFor[key] ?? 0;
			return [
				{
					featureId: 1,
					featureName: key,
					rawScore: normalizedScore,
					normalizedScore,
					confidence: 1,
					evidence: {},
					sourcePhase: "quiz",
				},
			];
		});

		const { supabase, matchesInsertRowsByCall, getBlocksCallCount } = supabaseForMixedBulkInsert();

		const count = await executeMatching(supabase as never);

		// Two insert attempts: the original 2-pair batch, then a 1-pair retry
		// with the blocked pair (user-1, user-3) filtered out.
		expect(matchesInsertRowsByCall).toHaveLength(2);
		expect(matchesInsertRowsByCall[0]).toHaveLength(2);
		expect(matchesInsertRowsByCall[1]).toHaveLength(1);
		expect(matchesInsertRowsByCall[1][0]).toMatchObject({ user_a_id: "user-1", user_b_id: "user-2" });

		// blocks was re-read once, to learn which pair is now blocked.
		expect(getBlocksCallCount()).toBe(2);

		// The returned count reflects only the rows actually inserted.
		expect(count).toBe(1);

		// featureScores saved for match-1 must be user-1/user-2's, not
		// user-1/user-3's — the index-alignment the filtering has to preserve.
		expect(saveFeatureScores).toHaveBeenCalledTimes(1);
		expect(vi.mocked(saveFeatureScores).mock.calls[0][1]).toBe("match-1");
		expect(vi.mocked(saveFeatureScores).mock.calls[0][2]).toMatchObject([
			{ featureName: "user-1:user-2", normalizedScore: 0.9 },
		]);

		expect(consoleWarnSpy).toHaveBeenCalledWith(expect.stringContaining("dropped 1 pair(s)"));
		consoleWarnSpy.mockRestore();
	});
});

describe("executeMatching throws on a non-blocked-pair matches insert error instead of reporting a false zero-match success", () => {
	it("throws rather than returning a zero-match count", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		vi.mocked(computeProfileFeatureScores).mockImplementation(() => [
			{
				featureId: 1,
				featureName: "pair",
				rawScore: 0.9,
				normalizedScore: 0.9,
				confidence: 1,
				evidence: {},
				sourcePhase: "quiz",
			},
		]);

		// biome-ignore lint/suspicious/noExplicitAny: minimal test double
		const supabase: any = {
			from(table: string) {
				if (table === "profiles") {
					return {
						select: () => ({
							eq: async () => ({
								data: [
									{ user_id: "user-1", status: "confirmed" },
									{ user_id: "user-2", status: "confirmed" },
								],
								error: null,
							}),
						}),
					};
				}
				if (table === "user_profiles") {
					return {
						select: () => ({
							in: async () => ({
								data: [
									{ id: "user-1", gender: "male", gender_identity: "man", preferred_genders: ["woman"], dating_market: "JP", preference_mode: "selected", onboarding_settings_completed_at: "2026-08-24T00:00:00Z", age_verified_at: "2026-08-24T00:00:00Z" },
									{ id: "user-2", gender: "female", gender_identity: "woman", preferred_genders: ["man"], dating_market: "JP", preference_mode: "selected", onboarding_settings_completed_at: "2026-08-24T00:00:00Z", age_verified_at: "2026-08-24T00:00:00Z" },
								],
								error: null,
							}),
						}),
					};
				}
				if (table === "blocks") {
					return { select: async () => ({ data: [], error: null }) };
				}
				if (table === "matches") {
					return {
						select: async () => ({ data: [], error: null }),
						insert: () => ({
							select: async () => ({
								data: null,
								error: { message: "connection reset", code: "08006" },
							}),
						}),
					};
				}
				throw new Error(`unexpected table in test double: ${table}`);
			},
		};

		await expect(executeMatching(supabase as never)).rejects.toThrow(/matches insert failed/);

		expect(consoleErrorSpy).toHaveBeenCalledWith("[executeMatching] matches insert failed");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("connection reset");
		consoleErrorSpy.mockRestore();
	});
});

function neutralFeatureScores() {
	return Array.from({ length: 14 }, (_, index) => ({
		featureId: index + 1,
		featureName: `feature-${index + 1}`,
		rawScore: 0.9,
		normalizedScore: 0.9,
		confidence: 1,
		evidence: {},
		sourcePhase: "quiz" as const,
	}));
}

function supabaseForAgeGatedMatching(
	userProfiles: Array<{ id: string; gender: string; age_verified_at: string | null }>,
	userProfileError: { message: string } | null = null,
) {
	const profiles = userProfiles.map((profile) => ({ user_id: profile.id, status: "confirmed" }));
	const eligibilityProfiles = userProfiles.map((profile) => ({
		...profile,
		gender_identity: profile.gender === "male" ? "man" : "woman",
		preferred_genders: [profile.gender === "male" ? "woman" : "man"],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
	}));
	const matchesInsert = vi.fn((rows: Record<string, unknown>[]) => ({
		select: async () => ({
			data: rows.map((_, index) => ({ id: `age-gate-match-${index + 1}` })),
			error: null,
		}),
	}));

	// biome-ignore lint/suspicious/noExplicitAny: minimal test double for the Supabase query surface
	const supabase: any = {
		from(table: string) {
			if (table === "profiles") {
				return { select: () => ({ eq: async () => ({ data: profiles, error: null }) }) };
			}
			if (table === "user_profiles") {
				return {
					select: () => ({
					in: async () => ({ data: userProfileError ? null : eligibilityProfiles, error: userProfileError }),
					}),
				};
			}
			if (table === "blocks") {
				return { select: async () => ({ data: [], error: null }) };
			}
			if (table === "matches") {
				return {
					select: async () => ({ data: [], error: null }),
					insert: matchesInsert,
				};
			}
			throw new Error(`unexpected table in age verification test double: ${table}`);
		},
	};

	return { supabase, matchesInsert };
}

function supabaseForEligibilityGate(eligibilityProfiles: ReadonlyArray<Record<string, unknown>>) {
	const profiles = eligibilityProfiles.map((profile) => ({ user_id: profile.id, status: "confirmed" }));
	const matchesInsert = vi.fn((rows: Record<string, unknown>[]) => ({
		select: async () => ({
			data: rows.map((_, index) => ({ id: `eligibility-match-${index + 1}` })),
			error: null,
		}),
	}));

	// biome-ignore lint/suspicious/noExplicitAny: minimal test double for the Supabase query surface
	const supabase: any = {
		from(table: string) {
			if (table === "profiles") {
				return { select: () => ({ eq: async () => ({ data: profiles, error: null }) }) };
			}
			if (table === "user_profiles") {
				return {
					select: (columns: string) => {
						expect(columns).toBe(MATCHING_ELIGIBILITY_COLUMNS);
						return { in: async () => ({ data: eligibilityProfiles, error: null }) };
					},
				};
			}
			if (table === "blocks") return { select: async () => ({ data: [], error: null }) };
			if (table === "matches") {
				return {
					select: async () => ({ data: [], error: null }),
					insert: matchesInsert,
				};
			}
			throw new Error(`unexpected table in eligibility test double: ${table}`);
		},
	};

	return { supabase, matchesInsert };
}

function completeEligibilityProfile(
	id: string,
	genderIdentity: "woman" | "man" | "nonbinary",
	preferredGenders: Array<"woman" | "man" | "nonbinary">,
	datingMarket: "JP" | "US" = "JP",
) {
	return {
		id,
		age_verified_at: "2026-08-24T00:00:00Z",
		gender_identity: genderIdentity,
		preferred_genders: preferredGenders,
		preference_mode: "selected",
		dating_market: datingMarket,
		onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
	};
}

describe("executeMatching applies the mutual eligibility gate before scoring", () => {
	it.each([
		[
			"one-way preference",
			[
				completeEligibilityProfile("user-a", "woman", ["man"]),
				completeEligibilityProfile("user-b", "man", ["nonbinary"]),
			],
		],
		[
			"cross-market preference",
			[
				completeEligibilityProfile("user-a", "woman", ["man"], "JP"),
				completeEligibilityProfile("user-b", "man", ["woman"], "US"),
			],
		],
	] as const)("does not score or insert a complete pair with %s", async (_name, eligibilityProfiles) => {
		const scoreSpy = vi.mocked(computeProfileFeatureScores);
		scoreSpy.mockReset();
		scoreSpy.mockImplementation(neutralFeatureScores);
		const saveSpy = vi.mocked(saveFeatureScores);
		saveSpy.mockReset();
		saveSpy.mockResolvedValue(undefined);
		const { supabase, matchesInsert } = supabaseForEligibilityGate(eligibilityProfiles);

		await expect(executeMatching(supabase as never)).resolves.toBe(0);
		expect(scoreSpy).not.toHaveBeenCalled();
		expect(matchesInsert).not.toHaveBeenCalled();
	});

	it("allows a same-gender pair when both profiles explicitly select each other", async () => {
		const scoreSpy = vi.mocked(computeProfileFeatureScores);
		scoreSpy.mockReset();
		scoreSpy.mockImplementation(neutralFeatureScores);
		const saveSpy = vi.mocked(saveFeatureScores);
		saveSpy.mockReset();
		saveSpy.mockResolvedValue(undefined);
		const { supabase, matchesInsert } = supabaseForEligibilityGate([
			completeEligibilityProfile("user-a", "woman", ["woman"]),
			completeEligibilityProfile("user-b", "woman", ["woman"]),
		]);

		await expect(executeMatching(supabase as never)).resolves.toBe(1);
		expect(scoreSpy).toHaveBeenCalledTimes(1);
		expect(matchesInsert).toHaveBeenCalledTimes(1);
	});
});

describe("executeMatching excludes unverified candidates", () => {
	it("does not score or insert a confirmed profile without age_verified_at", async () => {
		const scoreSpy = vi.mocked(computeProfileFeatureScores);
		scoreSpy.mockReset();
		scoreSpy.mockImplementation(neutralFeatureScores);
		const saveSpy = vi.mocked(saveFeatureScores);
		saveSpy.mockReset();
		saveSpy.mockResolvedValue(undefined);

		const { supabase, matchesInsert } = supabaseForAgeGatedMatching([
			{ id: "a-self", gender: "male", age_verified_at: "2026-08-24T00:00:00Z" },
			{ id: "b-unverified", gender: "female", age_verified_at: null },
			{ id: "c-verified", gender: "female", age_verified_at: "2026-08-24T00:00:00Z" },
		]);

		const count = await executeMatching(supabase as never);

		expect(count).toBe(1);
		expect(scoreSpy).toHaveBeenCalledTimes(1);
		expect(scoreSpy.mock.calls.flatMap((call) => call.map((profile) => profile.user_id))).not.toContain("b-unverified");
		expect(matchesInsert).toHaveBeenCalledTimes(1);
		expect(matchesInsert.mock.calls[0][0]).toEqual([
			expect.objectContaining({ user_a_id: "a-self", user_b_id: "c-verified" }),
		]);
	});

	it("fails closed when the verified profile lookup errors", async () => {
		const scoreSpy = vi.mocked(computeProfileFeatureScores);
		scoreSpy.mockReset();
		scoreSpy.mockImplementation(neutralFeatureScores);
		const saveSpy = vi.mocked(saveFeatureScores);
		saveSpy.mockReset();
		saveSpy.mockResolvedValue(undefined);

		const { supabase, matchesInsert } = supabaseForAgeGatedMatching(
			[
				{ id: "a-self", gender: "male", age_verified_at: "2026-08-24T00:00:00Z" },
				{ id: "b-candidate", gender: "female", age_verified_at: "2026-08-24T00:00:00Z" },
			],
			{ message: "database unavailable" },
		);

		await expect(executeMatching(supabase as never)).rejects.toThrow(/verified profile data could not be read/);
		expect(scoreSpy).not.toHaveBeenCalled();
		expect(matchesInsert).not.toHaveBeenCalled();
	});
});


describe("applyConfirmedPersonaTraits", () => {
	const baseProfile = {
		user_id: "user-1",
		personality_analysis: { introvert_extrovert: 0.4, logical_emotional: 0.6 },
		interaction_style: { attachment_tendency: "secure", humor_responsiveness: 0.7 },
		communication_style: { message_length: "medium", tone: "warm" },
		values: { work_life_balance: 0.8 },
		interests: [{ category: "hobby", items: ["walking"] }],
	} as unknown as Parameters<typeof applyConfirmedPersonaTraits>[0];

	it("maps only the nine confirmed enum keys into the existing score inputs", () => {
		const scored = applyConfirmedPersonaTraits(baseProfile, {
			social_energy: "extroverted",
			planning_style: "spontaneous",
			decision_style: "analytical",
			attachment_tendency: "anxious",
			conflict_style: "dialogue",
			rhythm_preference: "moderate",
			communication_preference: "detailed",
			priority_value: "learning",
			favorite_activity: "music",
			free_text: "ignored",
		});

		expect(scored.personality_analysis).toMatchObject({
			introvert_extrovert: 0.8,
			planned_spontaneous: 0.8,
			logical_emotional: 0.2,
		});
		expect(scored.interaction_style).toMatchObject({ attachment_tendency: "anxious", conflict_style: "dialogue", rhythm_preference: "moderate" });
		expect(scored.communication_style).toMatchObject({ message_length: "detailed", tone: "warm" });
		expect(scored.values).toMatchObject({ work_life_balance: 0.8, "confirmed_priority:learning": 1 });
		expect(scored.interests).toEqual([
			{ category: "hobby", items: ["walking"] },
			{ category: "self_reflection", items: ["confirmed_activity:music"] },
		]);
		expect(JSON.stringify(scored)).not.toContain("ignored");
	});

	it("ignores unknown enum values and keeps the profile unchanged", () => {
		const scored = applyConfirmedPersonaTraits(baseProfile, {
			social_energy: "write a prompt",
			priority_value: "wealth",
			favorite_activity: 3,
			unknown: "unbounded text",
		});
		expect(scored).toBe(baseProfile);
	});
});
