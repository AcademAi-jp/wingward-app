import { describe, expect, it, vi } from "vitest";
import { MATCHING_ELIGIBILITY_COLUMNS } from "./matching-eligibility";

vi.mock("./matching", async () => {
	const actual = await vi.importActual<typeof import("./matching")>("./matching");
	return {
		...actual,
		getProfileScoreDetailsForUsers: vi.fn(),
	};
});

const { getProfileScoreDetailsForUsers } = await import("./matching");
const { searchMatchCandidates } = await import("./fox-search");

type CandidateProfile = {
	id: string;
	gender: string;
	age_verified_at: string | null;
	gender_identity?: string | null;
	preferred_genders?: string[];
	preference_mode?: string;
	dating_market?: string;
	onboarding_settings_completed_at?: string | null;
};

function eligibilityProfile(profile: CandidateProfile) {
	const identity = profile.gender_identity !== undefined ? profile.gender_identity : profile.gender === "male" ? "man" : "woman";
	return {
		...profile,
		gender_identity: identity,
		preferred_genders: profile.preferred_genders !== undefined ? profile.preferred_genders : [profile.gender === "male" ? "woman" : "man"],
		preference_mode: profile.preference_mode !== undefined ? profile.preference_mode : "selected",
		dating_market: profile.dating_market !== undefined ? profile.dating_market : "JP",
		onboarding_settings_completed_at:
			profile.onboarding_settings_completed_at !== undefined
				? profile.onboarding_settings_completed_at
				: "2026-08-24T00:00:00Z",
	};
}

function makeSearchSupabase(
	candidateProfiles: CandidateProfile[] | null,
	candidateProfileError: { message: string } | null = null,
	matchesInsertError: { code: string; message: string } | null = null,
	refreshedCandidateProfiles: CandidateProfile[] | null = candidateProfiles,
	myProfileOverride: CandidateProfile = { id: "a-self", gender: "male", age_verified_at: "2026-08-24T00:00:00Z" },
) {
	const candidates = [
		{ user_id: "b-unverified" },
		{ user_id: "c-verified" },
	];
	const matchesInsertRows: Record<string, unknown>[] = [];
	let matchesInsertCallCount = 0;
	let candidateProfileLookupCount = 0;
	const matchesInsert = vi.fn((rows: Record<string, unknown>[]) => {
		matchesInsertRows.push(...rows);
		return {
			select: async () => {
				matchesInsertCallCount += 1;
				if (matchesInsertCallCount === 1 && matchesInsertError) {
					return { data: null, error: matchesInsertError };
				}
				return { data: rows.map(() => ({ id: "match-candidate-1" })), error: null };
			},
		};
	});
	const personaQuery = {
		eq: (_column: string, _value: string) => personaQuery,
		neq: async (_column: string, _value: string) => ({ data: candidates, error: null }),
		single: async () => ({ data: { id: "persona-self" }, error: null }),
	};
	const myProfile = eligibilityProfile(myProfileOverride);

	const supabase = {
		from(table: string) {
			if (table === "personas") {
				return { select: () => personaQuery };
			}
			if (table === "matches") {
				return {
					select: () => ({ or: async () => ({ data: [], error: null }) }),
					insert: matchesInsert,
				};
			}
			if (table === "blocks") {
				const blockChain = {
					eq: async () => ({ data: [], error: null }),
					then: (resolve: (value: unknown) => unknown, reject?: (error: unknown) => unknown) =>
						Promise.resolve({ data: [], error: null }).then(resolve, reject),
				};
				return { select: () => blockChain };
			}
			if (table === "user_profiles") {
				return {
					select: (columns: string) => {
						expect(columns).toBe(MATCHING_ELIGIBILITY_COLUMNS);
						return {
							in: async (_column: string, ids: string[]) => {
								if (ids.length === 1 && ids[0] === "a-self") return { data: [myProfile], error: null };
								candidateProfileLookupCount += 1;
								if (candidateProfileError) return { data: null, error: candidateProfileError };
								const availableProfiles =
									candidateProfileLookupCount === 1 ? candidateProfiles : refreshedCandidateProfiles;
								const byId = new Map(
									[myProfile, ...(availableProfiles?.map(eligibilityProfile) ?? [])].map((profile) => [profile.id, profile]),
								);
								return { data: ids.flatMap((id) => (byId.has(id) ? [byId.get(id)] : [])), error: null };
							},
						};
					},
				};
			}
			throw new Error(`unexpected table in search test double: ${table}`);
		},
	};

	return { supabase, matchesInsert, matchesInsertRows };
}

function mockSuccessfulScore() {
	vi.mocked(getProfileScoreDetailsForUsers).mockResolvedValue({
		profile_score: 90,
		final_score: 90,
		score_details: {},
		layerScores: { layer1: 0.9, layer2: 0.9, layer3: 0.9, finalScore: 90, featureScores: {} },
		featureScores: [],
	});
}

describe("searchMatchCandidates excludes unverified candidates", () => {
	it.each([
		[
			"one-way preference",
			{
				id: "c-verified",
				gender: "female",
				age_verified_at: "2026-08-24T00:00:00Z",
				gender_identity: "woman",
				preferred_genders: ["nonbinary"],
				preference_mode: "selected",
				dating_market: "JP",
				onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
			},
		],
		[
			"cross-market preference",
			{
				id: "c-verified",
				gender: "female",
				age_verified_at: "2026-08-24T00:00:00Z",
				gender_identity: "woman",
				preferred_genders: ["man"],
				preference_mode: "selected",
				dating_market: "US",
				onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
			},
		],
		[
			"missing completion marker",
			{
				id: "c-verified",
				gender: "female",
				age_verified_at: "2026-08-24T00:00:00Z",
				gender_identity: "woman",
				preferred_genders: ["man"],
				preference_mode: "selected",
				dating_market: "JP",
				onboarding_settings_completed_at: null,
			},
		],
	])("does not score or insert a complete candidate with %s", async (_name, changedCandidate) => {
		const scoreSpy = vi.mocked(getProfileScoreDetailsForUsers);
		scoreSpy.mockReset();
		mockSuccessfulScore();
		const { supabase, matchesInsert } = makeSearchSupabase([
			{ id: "b-unverified", gender: "male", age_verified_at: null },
			changedCandidate,
		]);

		await expect(searchMatchCandidates(supabase as never, "a-self")).rejects.toThrow("NO_CANDIDATES_FOUND");
		expect(scoreSpy).not.toHaveBeenCalled();
		expect(matchesInsert).not.toHaveBeenCalled();
	});

	it("scores and inserts a same-gender candidate after mutual eligibility passes", async () => {
		const scoreSpy = vi.mocked(getProfileScoreDetailsForUsers);
		scoreSpy.mockReset();
		mockSuccessfulScore();
		const { supabase, matchesInsert, matchesInsertRows } = makeSearchSupabase(
			[
				{ id: "b-unverified", gender: "male", age_verified_at: null },
				{
					id: "c-verified",
					gender: "female",
					age_verified_at: "2026-08-24T00:00:00Z",
					gender_identity: "woman",
					preferred_genders: ["woman"],
					preference_mode: "selected",
					dating_market: "JP",
					onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
				},
			],
			null,
			null,
			null,
			{ id: "a-self", gender: "female", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
		);

		const result = await searchMatchCandidates(supabase as never, "a-self");
		expect(result).toEqual([{ match_id: "match-candidate-1", partner_user_id: "c-verified" }]);
		expect(scoreSpy).toHaveBeenCalledTimes(1);
		expect(matchesInsert).toHaveBeenCalledTimes(1);
		expect(matchesInsertRows[0]).not.toHaveProperty("preferred_genders");
	});

	it("only shuffles, scores, and inserts verified candidates", async () => {
		const scoreSpy = vi.mocked(getProfileScoreDetailsForUsers);
		scoreSpy.mockReset();
		mockSuccessfulScore();
		const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0.999);

		try {
			const { supabase, matchesInsertRows } = makeSearchSupabase([
				{ id: "b-unverified", gender: "female", age_verified_at: null },
				{ id: "c-verified", gender: "female", age_verified_at: "2026-08-24T00:00:00Z" },
			]);

			const result = await searchMatchCandidates(supabase as never, "a-self");

			expect(result).toEqual([{ match_id: "match-candidate-1", partner_user_id: "c-verified" }]);
			expect(scoreSpy).toHaveBeenCalledTimes(1);
			expect(scoreSpy.mock.calls[0].slice(1)).toEqual(["a-self", "c-verified"]);
			expect(scoreSpy.mock.calls.flatMap((call) => call.slice(1))).not.toContain("b-unverified");
			expect(matchesInsertRows).toEqual([
				expect.objectContaining({ user_a_id: "a-self", user_b_id: "c-verified" }),
			]);
		} finally {
			randomSpy.mockRestore();
		}
	});

	it("returns NO_CANDIDATES_FOUND when every candidate is unverified", async () => {
		const scoreSpy = vi.mocked(getProfileScoreDetailsForUsers);
		scoreSpy.mockReset();
		mockSuccessfulScore();
		const { supabase, matchesInsert } = makeSearchSupabase([
			{ id: "b-unverified", gender: "female", age_verified_at: null },
			{ id: "c-verified", gender: "female", age_verified_at: null },
		]);

		await expect(searchMatchCandidates(supabase as never, "a-self")).rejects.toThrow("NO_CANDIDATES_FOUND");
		expect(scoreSpy).not.toHaveBeenCalled();
		expect(matchesInsert).not.toHaveBeenCalled();
	});

	it("fails explicitly when candidate profile lookup errors", async () => {
		const scoreSpy = vi.mocked(getProfileScoreDetailsForUsers);
		scoreSpy.mockReset();
		mockSuccessfulScore();
		const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const { supabase, matchesInsert } = makeSearchSupabase(null, { message: "database unavailable" });

		try {
			await expect(searchMatchCandidates(supabase as never, "a-self")).rejects.toThrow(
				"CANDIDATE_PROFILE_LOOKUP_FAILED",
			);
			expect(scoreSpy).not.toHaveBeenCalled();
			expect(matchesInsert).not.toHaveBeenCalled();
			expect(errorSpy).toHaveBeenCalledWith("[searchMatchCandidates] candidate user_profiles lookup failed");
		} finally {
			errorSpy.mockRestore();
		}
	});

	it("rechecks preference eligibility before retrying an individual 23514 insert", async () => {
		const scoreSpy = vi.mocked(getProfileScoreDetailsForUsers);
		scoreSpy.mockReset();
		mockSuccessfulScore();
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const initialCandidate = { id: "c-verified", gender: "female", age_verified_at: "2026-08-24T00:00:00Z" };
		const changedCandidate = {
			...initialCandidate,
			preferred_genders: ["nonbinary"],
		};
		const { supabase, matchesInsert, matchesInsertRows } = makeSearchSupabase(
			[
				{ id: "b-unverified", gender: "female", age_verified_at: null },
				initialCandidate,
			],
			null,
			{ code: "23514", message: "pair preference changed" },
			[
				{ id: "b-unverified", gender: "female", age_verified_at: null },
				changedCandidate,
			],
		);

		try {
			await expect(searchMatchCandidates(supabase as never, "a-self")).rejects.toThrow("ALL_MATCHES_FAILED");
			expect(scoreSpy).toHaveBeenCalledTimes(1);
			expect(matchesInsert).toHaveBeenCalledTimes(1);
			expect(matchesInsertRows).toHaveLength(1);
		} finally {
			consoleErrorSpy.mockRestore();
		}
	});
});
