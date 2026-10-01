/** Durable daily matching coordinator. Matches are not visible until one SQL publication transaction commits. */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../db/types";
type ProfileRow = Database["public"]["Tables"]["profiles"]["Row"];
import { computeMatchScore, applyConfirmedPersonaTraits } from "./matching";
import type { FeatureScore } from "./compatibility";
import {
	areMutuallyEligible,
	isMatchingProfileComplete,
} from "./matching-eligibility";
import {
	executeDurableDailyBatch,
	type DurableDailyBatchOptions,
	type DurableDailyCandidate,
	type DurableDailyPairSnapshot,
	type DurableBatchState,
} from "./durable-daily-batch";

/** Closed scoring projection persisted by the private batch snapshot RPC. */
export const DAILY_MATCHING_PROFILE_COLUMNS =
	"user_id, basic_info, personality_tags, personality_analysis, interaction_style, interests, values, communication_style" as const;
/** The SQL snapshot and pair RPCs page by this fixed bound. */
export const DAILY_MATCHING_WRITE_CHUNK_SIZE = 100;

export interface DailyMatchingResult {
	status: DurableBatchState;
	batchId: string | null;
	totalUsers: number;
	usersMatched: number;
	totalMatches: number;
}

export interface ExecuteDailyMatchingOptions extends DurableDailyBatchOptions {
	durableEnabled?: boolean;
}

function toDailyCandidate(pair: DurableDailyPairSnapshot): DurableDailyCandidate | null {
	if (
		!isMatchingProfileComplete(pair.eligibility_a) ||
		!isMatchingProfileComplete(pair.eligibility_b) ||
		!areMutuallyEligible(pair.eligibility_a, pair.eligibility_b)
	) return null;

	const profileA = applyConfirmedPersonaTraits(pair.profile_a as unknown as ProfileRow, pair.persona_traits_a);
	const profileB = applyConfirmedPersonaTraits(pair.profile_b as unknown as ProfileRow, pair.persona_traits_b);
	const result = computeMatchScore(profileA, profileB);
	if (result.dealbreakers.triggered) return null;

	const featureScores = result.featureScores.map((score: FeatureScore) => ({
		featureId: score.featureId,
		featureName: score.featureName,
		rawScore: score.rawScore,
		normalizedScore: score.normalizedScore,
		confidence: score.confidence,
		evidence: score.evidence,
		sourcePhase: score.sourcePhase,
	})) as unknown as Json;
	return {
		user_a_id: pair.user_a_id,
		user_b_id: pair.user_b_id,
		score: result.score,
		score_details: result.details,
		layer_scores: {
			layer1: result.layerScores.layer1,
			layer2: result.layerScores.layer2,
			layer3: result.layerScores.layer3,
			feature_scores: result.layerScores.featureScores,
		} as Json,
		feature_scores: featureScores,
	};
}

/**
 * Run one bounded slice of the durable daily batch. `durableEnabled` is an
 * explicit rollout gate; a missing migration/RPC never falls back to the old
 * in-memory writer.
 */
export async function executeDailyMatching(
	supabase: SupabaseClient<Database>,
	matchDate: string,
	maxPerUser = 1,
	options: ExecuteDailyMatchingOptions = {},
): Promise<DailyMatchingResult> {
	if (options.durableEnabled !== true) {
		return { status: "disabled", batchId: null, totalUsers: 0, usersMatched: 0, totalMatches: 0 };
	}
	if (maxPerUser !== 1) throw new Error("Daily matching currently publishes at most one match per user");
	const result = await executeDurableDailyBatch(supabase, matchDate, toDailyCandidate, options as DurableDailyBatchOptions);
	return {
		status: result.state,
		batchId: result.batchId,
		totalUsers: result.totalUsers,
		usersMatched: result.usersMatched,
		totalMatches: result.totalMatches,
	};
}
