import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../db/types";
import { saveFeatureScores } from "./compatibility";
import { evaluateMatchingPair, type MatchingProfileRow } from "./matching";
import { insertMatchesRejectingBlockedPairs } from "./insert-matches";
import {
	areMutuallyEligible,
	isMatchingProfileComplete,
	loadMatchingEligibilityProfiles,
	type MatchingEligibilityProfileMap,
} from "./matching-eligibility";
import {
	RECORDING_REHEARSAL_GENERATION_PAIRS,
	recordingRehearsalProfileIds,
	isRecordingRehearsalActive,
	type RecordingRehearsalPair,
	type ValidatedRecordingRehearsalConfig,
} from "./recording-rehearsal";

export type RecordingRehearsalMatchingMode = "preview" | "start";
export type RecordingRehearsalMatchingResult = {
	outcome:
		| "expired"
		| "not_selected_member"
		| "not_eligible"
		| "already_exists"
		| "eligible"
		| "started"
		| "started_partial";
	count: number;
};

type ProfileRow = Database["public"]["Tables"]["profiles"]["Row"];
type SelectedPair = readonly [string, string];
type MatchRow = {
	user_a_id: string;
	user_b_id: string;
	profile_score: number;
	final_score: number | null;
	score_details: Json;
	layer_scores: Json;
};

function validatedSelectedPair(config: ValidatedRecordingRehearsalConfig): SelectedPair | null {
	if (config.pair !== "aoi-ren" && config.pair !== "sora-ren" && config.pair !== "demo-maya-ren") return null;
	const expected = RECORDING_REHEARSAL_GENERATION_PAIRS[config.pair as RecordingRehearsalPair];
	const requested = config.generationPair as readonly string[];
	const profileIds = recordingRehearsalProfileIds(config.pair);
	const allowedProfiles = new Set<string>(profileIds);
	if (
		!Array.isArray(requested)
		|| requested.length !== 2
		|| requested[0] !== expected[0]
		|| requested[1] !== expected[1]
		|| !Array.isArray(config.profileIds)
		|| config.profileIds.length !== profileIds.length
		|| new Set(config.profileIds).size !== profileIds.length
		|| config.profileIds.some((id) => !allowedProfiles.has(id))
	) return null;
	return expected;
}

export function isRecordingRehearsalPairMember(
	config: ValidatedRecordingRehearsalConfig | undefined,
	userId: string,
	nowMs = Date.now(),
): boolean {
	if (!config || !isRecordingRehearsalActive(config, nowMs)) return false;
	const pair = validatedSelectedPair(config);
	return pair !== null && (pair as readonly string[]).includes(userId);
}

function closedResult(): RecordingRehearsalMatchingResult {
	return { outcome: "expired", count: 0 };
}

async function readExistingPair(
	supabase: SupabaseClient<Database>,
	pair: SelectedPair,
	config: ValidatedRecordingRehearsalConfig,
	now: () => number,
): Promise<boolean | null> {
	if (!isRecordingRehearsalActive(config, now())) return null;
	let response: { data: Array<{ user_a_id: string; user_b_id: string }> | null; error: unknown };
	try {
		response = await supabase
			.from("matches")
			.select("user_a_id, user_b_id")
			.in("user_a_id", [...pair])
			.in("user_b_id", [...pair]);
	} catch {
		if (!isRecordingRehearsalActive(config, now())) return null;
		throw new Error("Matching rehearsal state could not be read");
	}
	if (!isRecordingRehearsalActive(config, now())) return null;
	if (response.error || !Array.isArray(response.data)) {
		throw new Error("Matching rehearsal state could not be read");
	}
	const first = pair[0] < pair[1] ? pair[0] : pair[1];
	const second = pair[0] < pair[1] ? pair[1] : pair[0];
	for (const row of response.data) {
		if (row.user_a_id !== first || row.user_b_id !== second) {
			throw new Error("Matching rehearsal state was outside the selected pair");
		}
	}
	return response.data.length > 0;
}

/**
 * Preview and start share the exact live matcher inputs and scoring. Preview
 * returns before the first write; start can only create the one config-selected
 * pair and never changes an existing match.
 */
export async function runRecordingRehearsalMatching(
	supabase: SupabaseClient<Database>,
	config: ValidatedRecordingRehearsalConfig | undefined,
	actorId: string,
	mode: RecordingRehearsalMatchingMode,
	now: () => number = Date.now,
): Promise<RecordingRehearsalMatchingResult> {
	if (!config || !isRecordingRehearsalActive(config, now())
		|| (config.ownerPrepOnly && mode !== "preview")) return closedResult();
	const pair = validatedSelectedPair(config);
	if (!pair) return closedResult();
	if (!(pair as readonly string[]).includes(actorId)) {
		return { outcome: "not_selected_member", count: 0 };
	}
	const ensureActive = () => isRecordingRehearsalActive(config, now());
	const pairIds = [...pair];

	let profileResponse: { data: ProfileRow[] | null; error: unknown };
	try {
		profileResponse = await supabase
			.from("profiles")
			.select("*")
			.in("user_id", pairIds)
			.eq("status", "confirmed");
	} catch {
		if (!ensureActive()) return closedResult();
		throw new Error("Matching rehearsal profiles could not be read");
	}
	if (!ensureActive()) return closedResult();
	if (profileResponse.error || !Array.isArray(profileResponse.data)) {
		throw new Error("Matching rehearsal profiles could not be read");
	}
	const requestedIds = new Set(pairIds);
	const profilesByUserId = new Map<string, MatchingProfileRow>();
	for (const row of profileResponse.data) {
		if (!requestedIds.has(row.user_id) || profilesByUserId.has(row.user_id)) {
			throw new Error("Matching rehearsal profiles were outside the selected pair");
		}
		profilesByUserId.set(row.user_id, row);
	}
	if (profilesByUserId.size !== 2) return { outcome: "not_eligible", count: 0 };

	let eligibilityByUserId: MatchingEligibilityProfileMap;
	try {
		eligibilityByUserId = await loadMatchingEligibilityProfiles(supabase, pairIds);
	} catch {
		if (!ensureActive()) return closedResult();
		throw new Error("Matching rehearsal eligibility could not be read");
	}
	if (!ensureActive()) return closedResult();

	let blockResponse: { data: Array<{ blocker_id: string; blocked_id: string }> | null; error: unknown };
	try {
		blockResponse = await supabase
			.from("blocks")
			.select("blocker_id, blocked_id")
			.in("blocker_id", pairIds)
			.in("blocked_id", pairIds);
	} catch {
		if (!ensureActive()) return closedResult();
		throw new Error("Matching rehearsal safety data could not be read");
	}
	if (!ensureActive()) return closedResult();
	if (blockResponse.error || !Array.isArray(blockResponse.data)) {
		throw new Error("Matching rehearsal safety data could not be read");
	}
	for (const block of blockResponse.data) {
		if (!requestedIds.has(block.blocker_id) || !requestedIds.has(block.blocked_id)) {
			throw new Error("Matching rehearsal safety data was outside the selected pair");
		}
	}
	const blockSet = new Set(blockResponse.data.map((block) => block.blocker_id + ":" + block.blocked_id));

	const existing = await readExistingPair(supabase, pair, config, now);
	if (existing === null) return closedResult();
	if (existing) return { outcome: "already_exists", count: 0 };

	const profileA = profilesByUserId.get(pair[0]);
	const profileB = profilesByUserId.get(pair[1]);
	if (!profileA || !profileB) return { outcome: "not_eligible", count: 0 };
	if (
		!isMatchingProfileComplete(eligibilityByUserId.get(pair[0]))
		|| !isMatchingProfileComplete(eligibilityByUserId.get(pair[1]))
		|| !areMutuallyEligible(eligibilityByUserId.get(pair[0]), eligibilityByUserId.get(pair[1]))
	) return { outcome: "not_eligible", count: 0 };

	const result = evaluateMatchingPair(
		profileA,
		profileB,
		eligibilityByUserId,
		(a, b) => blockSet.has(a + ":" + b) || blockSet.has(b + ":" + a),
		() => false,
	);
	if (!result) return { outcome: "not_eligible", count: 0 };
	if (!ensureActive()) return closedResult();
	if (mode === "preview") return { outcome: "eligible", count: 1 };

	const first = pair[0] < pair[1] ? pair[0] : pair[1];
	const second = pair[0] < pair[1] ? pair[1] : pair[0];
	const row: MatchRow = {
		user_a_id: first,
		user_b_id: second,
		profile_score: result.score,
		final_score: null,
		score_details: result.details as Json,
		layer_scores: {
			layer1: result.layerScores.layer1,
			layer2: result.layerScores.layer2,
			layer3: result.layerScores.layer3,
			feature_scores: result.layerScores.featureScores,
		} as Json,
	};
	let insertion: Awaited<ReturnType<typeof insertMatchesRejectingBlockedPairs>>;
	try {
		insertion = await insertMatchesRejectingBlockedPairs(supabase, [row], "[recording-rehearsal-matching]", {
			scopeIds: pairIds,
			canWrite: ensureActive,
		});
	} catch {
		if (!ensureActive()) return closedResult();
		const concurrentExisting = await readExistingPair(supabase, pair, config, now);
		if (concurrentExisting === null) return closedResult();
		if (concurrentExisting) return { outcome: "already_exists", count: 0 };
		throw new Error("Matching rehearsal could not be started");
	}
	if (insertion.windowClosed || !ensureActive()) {
		return insertion.inserted.length
			? { outcome: "started_partial", count: insertion.inserted.length }
			: closedResult();
	}
	if (insertion.inserted.length === 0) return { outcome: "not_eligible", count: 0 };
	if (insertion.inserted.length !== 1) return { outcome: "started_partial", count: insertion.inserted.length };

	if (!ensureActive()) return { outcome: "started_partial", count: 1 };
	try {
		await saveFeatureScores(supabase, insertion.inserted[0].id, result.featureScores, { throwOnError: true });
	} catch {
		return { outcome: "started_partial", count: 1 };
	}
	// Do not remove a match if the window closes during persistence; report the
	// known inserted row without attempting any further write or retry.
	if (!ensureActive()) return { outcome: "started_partial", count: 1 };
	return { outcome: "started", count: 1 };
}
