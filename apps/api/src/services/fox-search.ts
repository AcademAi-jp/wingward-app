import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { getProfileScoreDetailsForUsers } from "./matching";
import {
	areMutuallyEligible,
	isMatchingProfileComplete,
	loadMatchingEligibilityProfiles,
	type MatchingEligibilityProfileMap,
} from "./matching-eligibility";
import { insertMatchesRejectingBlockedPairs } from "./insert-matches";

const MAX_MULTIPLE_MATCHES = 1;

/**
 * Finds and creates match *candidates* only. Does NOT create a
 * fox_conversations row and does NOT start the Durable Object — that only
 * happens via `POST /api/matches/:id/fox-conversation`
 * (services/fox-conversation-request.ts), which is the sole quota- and
 * entitlement-gated path to a fox conversation. This function used to also
 * create the fox_conversations row and kick off the DO/inline run; removed
 * as part of lazy generation (see step-3a security impact report §1, site C).
 */
export async function searchMatchCandidates(
	supabase: SupabaseClient<Database>,
	userId: string,
): Promise<Array<{ match_id: string; partner_user_id: string }>> {
	// 1. Verify current user has a wingfox persona
	const { data: myPersona, error: myPersonaError } = await supabase
		.from("personas")
		.select("id")
		.eq("user_id", userId)
		.eq("persona_type", "wingfox")
		.single();
	if (myPersonaError) {
		console.error("[searchMatchCandidates] own persona lookup failed");
		throw new Error("WINGFOX_PERSONA_LOOKUP_FAILED");
	}
	if (!myPersona) {
		throw new Error("WINGFOX_PERSONA_NOT_FOUND");
	}

	// 2. Get existing matched user IDs to exclude
	const { data: existingMatches, error: existingMatchesError } = await supabase
		.from("matches")
		.select("user_a_id, user_b_id")
		.or(`user_a_id.eq.${userId},user_b_id.eq.${userId}`);
	if (existingMatchesError || !existingMatches) {
		console.error("[searchMatchCandidates] existing matches lookup failed");
		throw new Error("EXISTING_MATCH_LOOKUP_FAILED");
	}
	const matchedUserIds = new Set(
		existingMatches.map((m) =>
			m.user_a_id === userId ? m.user_b_id : m.user_a_id,
		),
	);

	// 3. Get blocked user IDs (both directions)
	const [{ data: blockedByMe, error: blockedByMeError }, { data: blockedMe, error: blockedMeError }] = await Promise.all([
		supabase.from("blocks").select("blocked_id").eq("blocker_id", userId),
		supabase.from("blocks").select("blocker_id").eq("blocked_id", userId),
	]);
	if (blockedByMeError || blockedMeError || !blockedByMe || !blockedMe) {
		console.error("[searchMatchCandidates] block lookup failed");
		throw new Error("BLOCK_LOOKUP_FAILED");
	}
	const blockedIds = new Set([
		...blockedByMe.map((b) => b.blocked_id),
		...blockedMe.map((b) => b.blocker_id),
	]);

	// 4. Find other users with wingfox personas
	const { data: candidates, error: candidatesError } = await supabase
		.from("personas")
		.select("user_id")
		.eq("persona_type", "wingfox")
		.neq("user_id", userId);

	if (candidatesError || !candidates) {
		console.error("[searchMatchCandidates] candidate persona lookup failed");
		throw new Error("CANDIDATE_PERSONA_LOOKUP_FAILED");
	}

	// Read the current user's eligibility separately so the existing stable
	// error distinction remains intact. The helper uses the same closed
	// selection for both reads and rejects duplicate/unexpected rows.
	let myEligibilityById: MatchingEligibilityProfileMap;
	try {
		myEligibilityById = await loadMatchingEligibilityProfiles(supabase, [userId]);
	} catch {
		console.error("[searchMatchCandidates] own verified profile lookup failed");
		throw new Error("MY_PROFILE_LOOKUP_FAILED");
	}
	const myEligibility = myEligibilityById.get(userId);
	if (!myEligibility || !isMatchingProfileComplete(myEligibility)) {
		console.error("[searchMatchCandidates] own verified profile lookup failed");
		throw new Error("MY_PROFILE_LOOKUP_FAILED");
	}

	const candidateIds = [...new Set(candidates.map((c) => c.user_id))];
	let candidateEligibilityById: MatchingEligibilityProfileMap;
	try {
		candidateEligibilityById = await loadMatchingEligibilityProfiles(supabase, candidateIds);
	} catch {
		console.error("[searchMatchCandidates] candidate user_profiles lookup failed");
		throw new Error("CANDIDATE_PROFILE_LOOKUP_FAILED");
	}

	const eligible = candidates.filter(
		(c) =>
			!matchedUserIds.has(c.user_id) &&
			!blockedIds.has(c.user_id) &&
			areMutuallyEligible(myEligibility, candidateEligibilityById.get(c.user_id)),
	);
	if (eligible.length === 0) {
		throw new Error("NO_CANDIDATES_FOUND");
	}

	// 5. Fisher-Yates shuffle and pick up to MAX_MULTIPLE_MATCHES
	for (let i = eligible.length - 1; i > 0; i--) {
		const j = Math.floor(Math.random() * (i + 1));
		[eligible[i], eligible[j]] = [eligible[j], eligible[i]];
	}
	const picks = eligible.slice(0, MAX_MULTIPLE_MATCHES);

	// 6. Create match candidate for each pick (individual failures are skipped).
	// Status stays 'pending' — no fox_conversations row here; the user starts
	// the conversation explicitly via POST /api/matches/:id/fox-conversation.
	const results: Array<{ match_id: string; partner_user_id: string }> = [];

	for (const pick of picks) {
		try {
			const partnerUserId = pick.user_id;
			const [userA, userB] =
				userId < partnerUserId ? [userId, partnerUserId] : [partnerUserId, userId];

			const scoreDetails = await getProfileScoreDetailsForUsers(supabase, userA, userB);
			const matchPayload: {
				user_a_id: string;
				user_b_id: string;
				profile_score?: number;
				final_score?: number;
				score_details?: Record<string, number>;
			} = {
				user_a_id: userA,
				user_b_id: userB,
			};
			if (scoreDetails) {
				matchPayload.profile_score = scoreDetails.profile_score;
				matchPayload.final_score = scoreDetails.final_score;
				matchPayload.score_details = scoreDetails.score_details;
			}

			const { inserted } = await insertMatchesRejectingBlockedPairs(
				supabase,
				[matchPayload],
				"[searchMatchCandidates]",
			);
			const match = inserted[0];
			if (!match) continue;

			results.push({
				match_id: match.id,
				partner_user_id: partnerUserId,
			});
		} catch {
			// Skip individual failures
		}
	}

	if (results.length === 0) {
		throw new Error("ALL_MATCHES_FAILED");
	}

	return results;
}
