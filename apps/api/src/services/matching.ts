import type { Database, Json } from "../db/types";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
	computeProfileFeatureScores,
	calculateLayerScores,
	detectDealbreakers,
	saveFeatureScores,
	type FeatureScore,
	type LayerScores,
	type DealbreakerResult,
} from "./compatibility";
import { insertMatchesRejectingBlockedPairs } from "./insert-matches";
import { SYNTHETIC_MATCHING_PROFILE_IDS } from "./synthetic-matching-cohort";
import {
	areMutuallyEligible,
	isMatchingProfileComplete,
	loadMatchingEligibilityProfiles,
	type MatchingEligibilityProfileMap,
} from "./matching-eligibility";

export type MatchingProfileRow = Database["public"]["Tables"]["profiles"]["Row"];
type ProfileRow = MatchingProfileRow;

type ConfirmedPersonaTraits = Partial<Record<
	| "social_energy"
	| "planning_style"
	| "decision_style"
	| "attachment_tendency"
	| "conflict_style"
	| "rhythm_preference"
	| "communication_preference"
	| "priority_value"
	| "favorite_activity",
	string
>>;

const REFLECTION_ENUMS: Record<keyof ConfirmedPersonaTraits, readonly string[]> = {
	social_energy: ["introverted", "ambiverted", "extroverted"],
	planning_style: ["planned", "mixed", "spontaneous"],
	decision_style: ["analytical", "balanced", "emotional"],
	attachment_tendency: ["secure", "anxious", "avoidant"],
	conflict_style: ["dialogue", "yields", "maintains", "avoids"],
	rhythm_preference: ["slow", "moderate", "fast"],
	communication_preference: ["concise", "balanced", "detailed"],
	priority_value: ["family", "friendship", "independence", "creativity", "learning", "stability", "community"],
	favorite_activity: ["arts", "music", "reading", "outdoors", "food", "technology", "sports"],
};

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validatedConfirmedPersonaTraits(value: unknown): ConfirmedPersonaTraits {
	if (!isRecord(value)) return {};
	const traits: ConfirmedPersonaTraits = {};
	for (const key of Object.keys(REFLECTION_ENUMS) as (keyof ConfirmedPersonaTraits)[]) {
		const item = value[key];
		if (typeof item === "string" && REFLECTION_ENUMS[key].includes(item)) traits[key] = item;
	}
	return traits;
}

const AXIS_VALUE: Record<string, number> = {
	introverted: 0.2, planned: 0.2, analytical: 0.2,
	ambiverted: 0.5, mixed: 0.5, balanced: 0.5,
	extroverted: 0.8, spontaneous: 0.8, emotional: 0.8,
};

/**
 * Applies only owner-confirmed, closed-enum self-reflection traits to the
 * existing scoring fields. It never copies free text into scoring evidence.
 * Missing or malformed values leave the legacy profile input unchanged.
 */
export function applyConfirmedPersonaTraits<T extends ProfileRow>(profile: T, rawTraits: unknown): T {
	const traits = validatedConfirmedPersonaTraits(rawTraits);
	if (Object.keys(traits).length === 0) return profile;

	const next = { ...profile } as T;
	const personality = isRecord(profile.personality_analysis) ? { ...profile.personality_analysis } : {};
	const axisKeys = {
		social_energy: "introvert_extrovert",
		planning_style: "planned_spontaneous",
		decision_style: "logical_emotional",
	} as const;
	for (const traitKey of Object.keys(axisKeys) as (keyof typeof axisKeys)[]) {
		const value = traits[traitKey];
		if (value) personality[axisKeys[traitKey]] = AXIS_VALUE[value];
	}
	if (Object.keys(personality).length) next.personality_analysis = personality as T["personality_analysis"];

	const interaction = isRecord(profile.interaction_style) ? { ...profile.interaction_style } : {};
	for (const key of ["attachment_tendency", "conflict_style", "rhythm_preference"] as const) {
		const value = traits[key];
		if (value) interaction[key] = value;
	}
	if (Object.keys(interaction).length) next.interaction_style = interaction as T["interaction_style"];

	const communicationPreference = traits.communication_preference;
	if (communicationPreference) {
		const communication = isRecord(profile.communication_style) ? { ...profile.communication_style } : {};
		communication.message_length = communicationPreference;
		next.communication_style = communication as T["communication_style"];
	}

	const priorityValue = traits.priority_value;
	if (priorityValue) {
		const values = isRecord(profile.values) ? { ...profile.values } : {};
		values[`confirmed_priority:${priorityValue}`] = 1;
		next.values = values as T["values"];
	}

	const favoriteActivity = traits.favorite_activity;
	if (favoriteActivity) {
		const interests = Array.isArray(profile.interests)
			? profile.interests.map((entry) => isRecord(entry) ? { ...entry } : entry)
			: [];
		const item = `confirmed_activity:${favoriteActivity}`;
		const category = interests.find((entry) => isRecord(entry) && entry.category === "self_reflection");
		if (isRecord(category)) {
			const items = Array.isArray(category.items) ? category.items.filter((v): v is string => typeof v === "string") : [];
			category.items = [...new Set([...items, item])];
		} else {
			interests.push({ category: "self_reflection", items: [item] });
		}
		next.interests = interests as T["interests"];
	}
	return next;
}

// ─── Legacy 5-axis scoring (kept for backward compat in score_details) ──

function getPersonalityScore(a: ProfileRow, b: ProfileRow): number {
	const pa = (a.personality_analysis as Record<string, number>) ?? {};
	const pb = (b.personality_analysis as Record<string, number>) ?? {};
	let sum = 0;
	let n = 0;
	for (const key of ["introvert_extrovert", "planned_spontaneous", "logical_emotional"]) {
		const va = pa[key];
		const vb = pb[key];
		if (typeof va === "number" && typeof vb === "number") {
			sum += 1 - Math.abs(va - vb);
			n++;
		}
	}
	const tagsA = (a.personality_tags as string[]) ?? [];
	const tagsB = (b.personality_tags as string[]) ?? [];
	const tagOverlap = tagsA.length && tagsB.length ? tagsA.filter((t) => tagsB.includes(t)).length / Math.max(tagsA.length, tagsB.length) : 0.5;
	return n ? (sum / n) * 0.7 + tagOverlap * 0.3 : 0.5;
}

function getInterestsScore(a: ProfileRow, b: ProfileRow): number {
	const ia = (a.interests as { category: string; items: string[] }[]) ?? [];
	const ib = (b.interests as { category: string; items: string[] }[]) ?? [];
	const allItemsA = new Set(ia.flatMap((x) => x.items ?? []));
	const allItemsB = new Set(ib.flatMap((x) => x.items ?? []));
	if (allItemsA.size === 0 && allItemsB.size === 0) return 0.5;
	const overlap = [...allItemsA].filter((x) => allItemsB.has(x)).length;
	const union = new Set([...allItemsA, ...allItemsB]).size;
	return union ? overlap / union : 0.5;
}

function getValuesScore(a: ProfileRow, b: ProfileRow): number {
	const va = (a.values as Record<string, number>) ?? {};
	const vb = (b.values as Record<string, number>) ?? {};
	const keys = new Set([...Object.keys(va), ...Object.keys(vb)]);
	if (keys.size === 0) return 0.5;
	let sum = 0;
	for (const k of keys) {
		const aVal = va[k];
		const bVal = vb[k];
		if (typeof aVal === "number" && typeof bVal === "number") {
			sum += 1 - Math.abs(aVal - bVal);
		}
	}
	return keys.size ? sum / keys.size : 0.5;
}

function getCommunicationScore(a: ProfileRow, b: ProfileRow): number {
	const ca = (a.communication_style as Record<string, unknown>) ?? {};
	const cb = (b.communication_style as Record<string, unknown>) ?? {};
	const lenA = ca.message_length;
	const lenB = cb.message_length;
	if (lenA === lenB) return 1;
	return 0.7;
}

// ─── 14-feature based matching ─────────────────────────────────────────

export interface MatchResult {
	score: number; // 0-100
	details: Record<string, number>; // legacy 5-axis + layer scores (0-100 each)
	layerScores: LayerScores;
	featureScores: FeatureScore[];
	dealbreakers: DealbreakerResult;
}

export function computeMatchScore(
	profileA: ProfileRow,
	profileB: ProfileRow,
): MatchResult {
	// 1. Compute 14 feature scores from profiles
	const featureScores = computeProfileFeatureScores(profileA, profileB);

	// 2. Build feature map for layer calculation
	const featureMap = new Map<number, number>();
	for (const fs of featureScores) {
		featureMap.set(fs.featureId, fs.normalizedScore);
	}

	// 3. Calculate 3-layer scores (20% / 50% / 30%)
	const layerScores = calculateLayerScores(featureMap);

	// 4. Detect dealbreakers
	const dealbreakers = detectDealbreakers(featureMap);

	// 5. Legacy 5-axis scores for backward compatibility
	const personality = getPersonalityScore(profileA, profileB);
	const interests = getInterestsScore(profileA, profileB);
	const values = getValuesScore(profileA, profileB);
	const communication = getCommunicationScore(profileA, profileB);

	const details: Record<string, number> = {
		personality: Math.round(personality * 100),
		interests: Math.round(interests * 100),
		values: Math.round(values * 100),
		communication: Math.round(communication * 100),
		layer1: Math.round(layerScores.layer1 * 100),
		layer2: Math.round(layerScores.layer2 * 100),
		layer3: Math.round(layerScores.layer3 * 100),
	};

	return {
		score: dealbreakers.triggered ? 0 : layerScores.finalScore,
		details,
		layerScores,
		featureScores,
		dealbreakers,
	};
}


/** Applies the shared live matcher gates and normal scoring to one candidate pair. */
export function evaluateMatchingPair(
	profileA: MatchingProfileRow,
	profileB: MatchingProfileRow,
	eligibilityByUserId: MatchingEligibilityProfileMap,
	isBlocked: (userA: string, userB: string) => boolean,
	hasExistingMatch: (userA: string, userB: string) => boolean,
): MatchResult | null {
	const userA = profileA.user_id;
	const userB = profileB.user_id;
	if (userA === userB || isBlocked(userA, userB)) return null;
	if (!areMutuallyEligible(eligibilityByUserId.get(userA), eligibilityByUserId.get(userB))) return null;
	if (hasExistingMatch(userA, userB)) return null;
	const result = computeMatchScore(profileA, profileB);
	return result.dealbreakers.triggered ? null : result;
}

export type MatchingExecutionScope = Readonly<{ profileIds: readonly string[]; actorId: string; mode: "preview" | "start"; canWrite: () => boolean }>;
export async function executeMatching(supabase: SupabaseClient<Database>, topN: number = 10, cohort?: "synthetic", scope?: MatchingExecutionScope): Promise<number> {
	const admitted = () => scope === undefined || scope.canWrite() === true;
	if (!admitted()) return 0;
	if (scope && (!scope.profileIds.includes(scope.actorId) || new Set(scope.profileIds).size !== scope.profileIds.length)) throw new Error("Matching scope invalid");
	let profileQuery = supabase.from("profiles").select("*").eq("status", "confirmed");
	if (scope) profileQuery = profileQuery.in("user_id", [...scope.profileIds]);
	if (cohort === "synthetic") profileQuery = profileQuery.in("user_id", [...SYNTHETIC_MATCHING_PROFILE_IDS.slice(0, 2)]);
	const { data: profiles, error: profilesError } = await profileQuery;
	if (!admitted()) return 0;
	if (scope && profiles && (new Set(profiles.map(p => p.user_id)).size !== profiles.length || profiles.some(p => !scope.profileIds.includes(p.user_id)))) throw new Error("Matching scope invalid");
	if (profilesError || !profiles) {
		console.error("[executeMatching] confirmed profiles lookup failed; aborting");
		throw new Error("Matching aborted: confirmed profiles could not be read");
	}
	if (!profiles?.length) return 0;

	// Read only the closed, owner-private eligibility columns. The legacy
	// `gender` field is intentionally not consulted for matching.
	const userIds = [...new Set(profiles.map((p) => p.user_id))];
	let eligibilityByUserId: MatchingEligibilityProfileMap;
	try {
		eligibilityByUserId = await loadMatchingEligibilityProfiles(supabase, userIds);
	} catch {
		console.error("[executeMatching] verified user_profiles lookup failed; aborting");
		throw new Error("Matching aborted: verified profile data could not be read");
	}
	if (!admitted()) return 0;
	const verifiedUserIds = new Set(
		userIds.filter((id) => isMatchingProfileComplete(eligibilityByUserId.get(id))),
	);
	const eligibleProfiles = profiles.filter((profile) => verifiedUserIds.has(profile.user_id));
	if (eligibleProfiles.length < 2) return 0;

	let blocksQuery = supabase.from("blocks").select("blocker_id, blocked_id");
	if (scope) blocksQuery = blocksQuery.in("blocker_id", userIds).in("blocked_id", userIds);
	if (cohort === "synthetic") blocksQuery = blocksQuery.in("blocker_id", userIds).in("blocked_id", userIds);
	const { data: blocks, error: blocksError } = await blocksQuery;
	if (!admitted()) return 0;
	if (scope && blocks?.some(b => !scope.profileIds.includes(b.blocker_id) || !scope.profileIds.includes(b.blocked_id))) throw new Error("Matching scope invalid");
	if (blocksError || !blocks) {
		console.error("[executeMatching] blocks lookup failed; aborting");
		throw new Error("Matching aborted: the block list could not be read");
	}
	const blockSet = new Set(blocks.map((b) => `${b.blocker_id}:${b.blocked_id}`));
	const isBlocked = (a: string, b: string) => blockSet.has(`${a}:${b}`) || blockSet.has(`${b}:${a}`);
	let existingQuery = supabase.from("matches").select("user_a_id, user_b_id");
	if (scope) existingQuery = existingQuery.in("user_a_id", userIds).in("user_b_id", userIds);
	if (cohort === "synthetic") existingQuery = existingQuery.in("user_a_id", userIds).in("user_b_id", userIds);
	const { data: existing, error: existingError } = await existingQuery;
	if (!admitted()) return 0;
	if (scope && existing?.some(m => !scope.profileIds.includes(m.user_a_id) || !scope.profileIds.includes(m.user_b_id))) throw new Error("Matching scope invalid");
	if (existingError || !existing) {
		console.error("[executeMatching] existing matches lookup failed; aborting");
		throw new Error("Matching aborted: existing matches could not be read");
	}
	const existingSet = new Set(
		existing.map((m) => (m.user_a_id < m.user_b_id ? `${m.user_a_id}:${m.user_b_id}` : `${m.user_b_id}:${m.user_a_id}`)),
	);

	const scored: { userA: string; userB: string; result: MatchResult }[] = [];
	for (let i = 0; i < eligibleProfiles.length; i++) {
		for (let j = i + 1; j < eligibleProfiles.length; j++) {
			const idA = eligibleProfiles[i].user_id;
			const idB = eligibleProfiles[j].user_id;
			if (scope && idA !== scope.actorId && idB !== scope.actorId) continue;
			// Keep discovery and rehearsal evaluation on the same eligibility,
			// block, existing-match, score, and dealbreaker checks.
			const result = evaluateMatchingPair(
				eligibleProfiles[i],
				eligibleProfiles[j],
				eligibilityByUserId,
				isBlocked,
				(a, b) => existingSet.has(a < b ? a + ":" + b : b + ":" + a),
			);
			if (!result) continue;
			scored.push({ userA: idA, userB: idB, result });
		}
	}
	scored.sort((a, b) => b.result.score - a.result.score);

	const perUser = new Map<string, number>();
	const toInsert: {
		user_a_id: string;
		user_b_id: string;
		profile_score: number;
		final_score: number | null;
		score_details: Json;
		layer_scores: Json;
	}[] = [];
	const matchFeatureScores: FeatureScore[][] = [];

	for (const s of scored) {
		const countA = perUser.get(s.userA) ?? 0;
		const countB = perUser.get(s.userB) ?? 0;
		if (countA >= topN || countB >= topN) continue;
		const aId = s.userA < s.userB ? s.userA : s.userB;
		const bId = s.userA < s.userB ? s.userB : s.userA;
		toInsert.push({
			user_a_id: aId,
			user_b_id: bId,
			profile_score: s.result.score,
			final_score: null,
			score_details: s.result.details as Json,
			layer_scores: {
				layer1: s.result.layerScores.layer1,
				layer2: s.result.layerScores.layer2,
				layer3: s.result.layerScores.layer3,
				feature_scores: s.result.layerScores.featureScores,
			} as Json,
		});
		matchFeatureScores.push(s.result.featureScores);
		perUser.set(s.userA, countA + 1);
		perUser.set(s.userB, countB + 1);
	}
	if (!admitted() || toInsert.length === 0) return 0;
	if (scope?.mode === "preview") return toInsert.length;

	// The trigger described in insert-matches.ts can abort this whole bulk
	// INSERT over a single blocked pair; the shared helper re-reads blocks,
	// drops the now-blocked row(s), and retries so the rest of the batch
	// survives. `matchFeatureScores` must be filtered by the same
	// `keptIndices` as `toInsert` to stay aligned with `inserted`.
	const { inserted, keptIndices } = await insertMatchesRejectingBlockedPairs(
		supabase,
		toInsert,
		"[executeMatching]",
		scope ? { canWrite: admitted, judgeScope: { profileIds: scope.profileIds, actorId: scope.actorId } } : undefined,
	);
	if (!inserted.length) return 0;
	const keptFeatureScores = keptIndices.map((i) => matchFeatureScores[i]);

	// fox_conversations はもう自動作成しない（lazy generation）:
	// see services/fox-conversation-request.ts / POST /api/matches/:id/fox-conversation
	for (let i = 0; i < inserted.length; i++) {
		if (!admitted()) break;
		const matchId = inserted[i].id;
		await saveFeatureScores(supabase, matchId, keptFeatureScores[i]);
	}

	return inserted.length;
}

const TRAIT_KEYS = ["personality", "interests", "values", "communication"] as const;

/** score_details に特性軸が含まれているか */
export function hasTraitScores(details: Record<string, unknown>): boolean {
	return TRAIT_KEYS.every((k) => typeof details[k] === "number");
}

/** score_details に14特徴量のレイヤースコアが含まれているか */
export function hasLayerScores(details: Record<string, unknown>): boolean {
	return typeof details.layer1 === "number" && typeof details.layer2 === "number" && typeof details.layer3 === "number";
}

/** 2ユーザーの profiles から互換性スコアを計算。どちらかが無い場合は null */
export async function getProfileScoreDetailsForUsers(
	supabase: SupabaseClient<Database>,
	userA: string,
	userB: string,
): Promise<{ profile_score: number; final_score: number; score_details: Record<string, number>; layerScores: LayerScores; featureScores: FeatureScore[] } | null> {
	const { data: profiles, error: profilesError } = await supabase
		.from("profiles")
		.select("*")
		.in("user_id", [userA, userB])
		.eq("status", "confirmed");
	if (profilesError) {
		console.error("[getProfileScoreDetailsForUsers] profile lookup failed");
		throw new Error("Failed to load profile score inputs");
	}
	if (!profiles || profiles.length !== 2) return null;
	const byUserId = new Map(profiles.map((p) => [p.user_id, p as ProfileRow]));
	const profileA = byUserId.get(userA);
	const profileB = byUserId.get(userB);
	if (!profileA || !profileB) return null;
	const result = computeMatchScore(profileA, profileB);
	return {
		profile_score: result.score,
		final_score: result.score,
		score_details: result.details,
		layerScores: result.layerScores,
		featureScores: result.featureScores,
	};
}
