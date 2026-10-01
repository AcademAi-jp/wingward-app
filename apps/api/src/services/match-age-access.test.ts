import { describe, expect, it } from "vitest";
import { checkVerifiedMatch, checkVerifiedPair, filterVerifiedMatches } from "./match-age-access";

function makeSupabase(opts: {
	profiles?: unknown[] | null;
	profileError?: unknown;
	match?: unknown;
	matchError?: unknown;
}) {
	return {
		from: (table: string) => {
			if (table === "user_profiles") {
				return { select: () => ({ in: async () => ({ data: opts.profiles ?? [], error: opts.profileError ?? null }) }) };
			}
			if (table === "matches") {
				return { select: () => ({ eq: () => ({ single: async () => ({ data: opts.match ?? null, error: opts.matchError ?? null }) }) }) };
			}
			throw new Error(`unexpected table: ${table}`);
		},
	};
}

const VERIFIED = [
	{ id: "user-a", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["man"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
	{ id: "user-b", age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "man", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
];

describe("match age access", () => {
	it("allows a pair only when both profiles are verified", async () => {
		await expect(checkVerifiedPair(makeSupabase({ profiles: VERIFIED }) as never, "user-a", "user-b")).resolves.toEqual({ ok: true });
	});

	it.each([
		["reverse preference", { ...VERIFIED[1], preferred_genders: ["nonbinary"] }],
		["cross-market", { ...VERIFIED[1], dating_market: "US" }],
		["incomplete settings", { ...VERIFIED[1], onboarding_settings_completed_at: null }],
	])("denies a pair when current eligibility is %s", async (_name, changedPartner) => {
		await expect(
			checkVerifiedPair(makeSupabase({ profiles: [VERIFIED[0], changedPartner] }) as never, "user-a", "user-b"),
		).resolves.toEqual({ ok: false, reason: "unverified" });
	});

	it("fails closed for an unverified or missing counterpart", async () => {
		await expect(
				checkVerifiedPair(makeSupabase({ profiles: [VERIFIED[0]] }) as never, "user-a", "user-b"),
		).resolves.toEqual({ ok: false, reason: "unverified" });
	});

	it("fails closed on a profile lookup error", async () => {
		await expect(checkVerifiedPair(makeSupabase({ profileError: { message: "unavailable" } }) as never, "user-a", "user-b")).resolves.toEqual({ ok: false, reason: "error" });
	});

	it("fails closed when the profile response contains null or duplicate rows", async () => {
		await expect(
			checkVerifiedPair(makeSupabase({ profiles: [VERIFIED[0], VERIFIED[1], null] }) as never, "user-a", "user-b"),
		).resolves.toEqual({ ok: false, reason: "error" });
		await expect(
			checkVerifiedPair(makeSupabase({ profiles: [VERIFIED[0], VERIFIED[1], { ...VERIFIED[1] }] }) as never, "user-a", "user-b"),
		).resolves.toEqual({ ok: false, reason: "error" });
	});

	it("does not return an unverified match in a list", async () => {
		const rows = [
			{ id: "match-a", user_a_id: "user-a", user_b_id: "user-b" },
			{ id: "match-b", user_a_id: "user-a", user_b_id: "user-c" },
		];
		const result = await filterVerifiedMatches(makeSupabase({ profiles: [...VERIFIED, { id: "user-c", age_verified_at: null, gender_identity: "man", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" }] }) as never, rows);
		expect(result).toEqual({ ok: true, rows: [rows[0]] });
	});

	it("returns a stable denial for an unverified counterpart on a single match", async () => {
		await expect(
			checkVerifiedMatch(
				makeSupabase({
					match: { id: "match-a", user_a_id: "user-a", user_b_id: "user-b" },
					profiles: [VERIFIED[0], { ...VERIFIED[1], age_verified_at: null }],
				}) as never,
				"match-a",
				"user-a",
			),
		).resolves.toEqual({ ok: false, reason: "not_found" });
	});

	it("treats a missing match as a non-disclosing denial", async () => {
		await expect(
			checkVerifiedMatch(makeSupabase({ match: null }) as never, "missing-match", "user-a"),
		).resolves.toEqual({ ok: false, reason: "not_found" });
	});
});
