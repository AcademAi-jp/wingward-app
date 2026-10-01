import { describe, expect, it } from "vitest";
import {
	MATCHING_ELIGIBILITY_COLUMNS,
	areMutuallyEligible,
	indexMatchingEligibilityProfiles,
	isMatchingProfileComplete,
	isMutuallyEligiblePair,
	loadMatchingEligibilityProfiles,
} from "./matching-eligibility";

const VERIFIED = "2026-09-05T00:00:00.000Z";

function profile(
	id: string,
	identity: string = "woman",
	preferred: string[] = ["man"],
	market: string = "JP",
) {
	return {
		id,
		age_verified_at: VERIFIED,
		gender_identity: identity,
		preferred_genders: preferred,
		preference_mode: "selected",
		dating_market: market,
		onboarding_settings_completed_at: VERIFIED,
	};
}

describe("matching eligibility", () => {
	it("accepts every reciprocal three-category combination, including same-gender and nonbinary pairs", () => {
		const categories = ["woman", "man", "nonbinary"];
		for (const firstCategory of categories) {
			for (const secondCategory of categories) {
				expect(
					isMutuallyEligiblePair(
						profile("a", firstCategory, [secondCategory]),
						profile("b", secondCategory, [firstCategory]),
					),
				).toBe(true);
			}
		}
	});

	it.each([
		["one-way selection", profile("a", "woman", ["man"]), profile("b", "man", ["nonbinary"])],
		["cross-market", profile("a", "woman", ["man"], "JP"), profile("b", "man", ["woman"], "US")],
		["no-answer mode", profile("a", "woman", ["man"]), { ...profile("b", "man", ["woman"]), preference_mode: "no_answer" }],
		["null identity", profile("a", "woman", ["man"]), { ...profile("b", "man", ["woman"]), gender_identity: null }],
		["unknown identity", profile("a", "woman", ["man"]), { ...profile("b", "alien", ["woman"]) }],
		["empty preferences", profile("a", "woman", ["man"]), { ...profile("b", "man", ["woman"]), preferred_genders: [] }],
		["unknown preference category", profile("a", "woman", ["man"]), { ...profile("b", "man", ["woman", "alien"]) }],
		["duplicate preference categories", profile("a", "woman", ["man"]), { ...profile("b", "man", ["woman", "woman"]) }],
		["missing completion marker", profile("a", "woman", ["man"]), { ...profile("b", "man", ["woman"]), onboarding_settings_completed_at: null }],
		["missing age verification", profile("a", "woman", ["man"]), { ...profile("b", "man", ["woman"]), age_verified_at: null }],
		["same profile", profile("a", "woman", ["woman"]), profile("a", "woman", ["woman"])],
	] as const)("rejects %s", (_name, first, second) => {
		expect(isMutuallyEligiblePair(first, second)).toBe(false);
	});

	it("does not infer new eligibility from legacy gender or region fields", () => {
		const first = { ...profile("a", "woman", ["man"]), gender: "female", region: "JP" };
		const second = { ...profile("b", "man", ["woman"]), gender: "female", region: "JP" };
		expect(isMutuallyEligiblePair(first, second)).toBe(true);
		expect(isMutuallyEligiblePair(
			{ ...first, gender_identity: null, preferred_genders: [] },
			{ ...second, gender_identity: null, preferred_genders: [] },
		)).toBe(false);
	});

	it("rejects malformed completion and identity values as incomplete", () => {
		expect(isMatchingProfileComplete({ ...profile("a"), onboarding_settings_completed_at: "not-a-date" })).toBe(false);
		expect(isMatchingProfileComplete({ ...profile("a"), age_verified_at: true })).toBe(false);
		expect(isMatchingProfileComplete({ ...profile("a"), gender_identity: "" })).toBe(false);
		expect(isMatchingProfileComplete({ ...profile("a"), preferred_genders: "man" })).toBe(false);
	});

	it("keeps malformed fields raw until the explicit validator rejects them", () => {
		const malformed = { ...profile("a"), preferred_genders: ["alien"] };
		const indexed = indexMatchingEligibilityProfiles([malformed], ["a"]);
		expect(indexed?.get("a")).toEqual(malformed);
		expect(isMatchingProfileComplete(indexed?.get("a"))).toBe(false);
	});

	it("rejects duplicate, unexpected, and malformed returned IDs", () => {
		const first = profile("a");
		expect(indexMatchingEligibilityProfiles([first, { ...first }], ["a"])).toBeNull();
		expect(indexMatchingEligibilityProfiles([first, profile("unexpected")], ["a", "b"])).toBeNull();
		expect(indexMatchingEligibilityProfiles([null], ["a"])).toBeNull();
		expect(indexMatchingEligibilityProfiles([{ ...first, id: "" }], ["a"])).toBeNull();
		expect(indexMatchingEligibilityProfiles([first], ["a", "b"])).toEqual(new Map([["a", first]]));
	});

	it("uses the closed eligibility column selection and indexes current rows", async () => {
		let selectedColumns = "";
		const first = profile("a", "woman", ["man"]);
		const second = profile("b", "man", ["woman"]);
		const supabase = {
			from(table: string) {
				expect(table).toBe("user_profiles");
				return {
					select(columns: string) {
						selectedColumns = columns;
						return { in: async () => ({ data: [first, second], error: null }) };
					},
				};
			},
		};

		const result = await loadMatchingEligibilityProfiles(supabase as never, ["a", "b"]);
		expect(selectedColumns).toBe(MATCHING_ELIGIBILITY_COLUMNS);
		expect(result.get("a")).toEqual(first);
		expect(result.get("b")).toEqual(second);
	});
});
