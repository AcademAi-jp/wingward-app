import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import {
	areMutuallyEligible,
	loadMatchingEligibilityProfiles,
	type MatchingEligibilityProfileMap,
} from "./matching-eligibility";

export type MatchParticipants = { id?: string; user_a_id: string; user_b_id: string };

export type VerifiedPairResult =
	| { ok: true }
	| { ok: false; reason: "unverified" | "error" };

export type VerifiedMatchResult =
	| { ok: true; match: MatchParticipants; partnerId: string }
	| { ok: false; reason: "not_found" | "error" };

/** Keep the success branch narrowed at call sites that also handle errors. */
export function isVerifiedMatch(
	result: VerifiedMatchResult,
): result is Extract<VerifiedMatchResult, { ok: true }> {
	return result.ok === true;
}

/**
 * Current matching eligibility for a pair is deliberately read in one common
 * helper. The API uses service_role (and therefore cannot rely on RLS) so
 * every contact path must explicitly confirm both rows before it reads or
 * writes pair data. Missing rows are treated as unverified; lookup errors are
 * never treated as an empty result.
 */
export async function checkVerifiedPair(
	supabase: SupabaseClient<Database>,
	firstUserId: string,
	secondUserId: string,
): Promise<VerifiedPairResult> {
	if (!firstUserId || !secondUserId || firstUserId === secondUserId) {
		return { ok: false, reason: "unverified" };
	}

	let profiles: MatchingEligibilityProfileMap;
	try {
		profiles = await loadMatchingEligibilityProfiles(supabase, [firstUserId, secondUserId]);
	} catch {
		console.error("[match-age-access] failed to read pair age state");
		return { ok: false, reason: "error" };
	}

	if (!areMutuallyEligible(profiles.get(firstUserId), profiles.get(secondUserId))) {
		return { ok: false, reason: "unverified" };
	}
	return { ok: true };
}

/**
 * Loads a match, proves the caller belongs to it, then proves both
 * participants are currently eligible. `not_found` is intentionally shared by
 * a missing match, a non-member, and an ineligible counterpart so callers do
 * not disclose relationship state.
 */
export async function checkVerifiedMatch(
	supabase: SupabaseClient<Database>,
	matchId: string,
	callerId: string,
): Promise<VerifiedMatchResult> {
	let match: { id: string; user_a_id: string; user_b_id: string } | null = null;
	try {
		const result = await supabase
			.from("matches")
			.select("id, user_a_id, user_b_id")
			.eq("id", matchId)
			.single();
		if (result.error) {
			// PostgREST's `.single()` uses PGRST116 for a missing row.  Treat
			// that as the same non-disclosing not_found branch as a null result;
			// all other lookup failures remain an explicit fail-closed error.
			if ((result.error as { code?: string }).code === "PGRST116") {
				return { ok: false, reason: "not_found" };
			}
			console.error("[match-age-access] failed to read match");
			return { ok: false, reason: "error" };
		}
		match = result.data;
	} catch {
		console.error("[match-age-access] failed to read match");
		return { ok: false, reason: "error" };
	}
	if (!match || (match.user_a_id !== callerId && match.user_b_id !== callerId)) {
		return { ok: false, reason: "not_found" };
	}

	const pair = await checkVerifiedPair(supabase, match.user_a_id, match.user_b_id);
	if (pair.ok === false) {
		return pair.reason === "error"
			? { ok: false, reason: "error" }
			: { ok: false, reason: "not_found" };
	}

	return {
		ok: true,
		match,
		partnerId: match.user_a_id === callerId ? match.user_b_id : match.user_a_id,
	};
}

/**
 * Filters a list endpoint's match rows without ever returning an ineligible
 * counterpart. A failed profile lookup rejects the list rather than silently
 * presenting a partial relationship view.
 */
export async function filterVerifiedMatches<T extends MatchParticipants>(
	supabase: SupabaseClient<Database>,
	rows: T[],
): Promise<{ ok: true; rows: T[] } | { ok: false; reason: "error" }> {
	const userIds = [...new Set(rows.flatMap((row) => [row.user_a_id, row.user_b_id]))];
	if (userIds.length === 0) return { ok: true, rows: [] };

	let profiles: MatchingEligibilityProfileMap;
	try {
		profiles = await loadMatchingEligibilityProfiles(supabase, userIds);
	} catch {
		console.error("[match-age-access] failed to read match list age state");
		return { ok: false, reason: "error" };
	}

	return {
		ok: true,
		rows: rows.filter((row) => areMutuallyEligible(profiles.get(row.user_a_id), profiles.get(row.user_b_id))),
	};
}
