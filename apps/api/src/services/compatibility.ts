/**
 * Compatibility Feature Framework — US-8 Implementation
 *
 * 14 compatibility features organized into 3 layers:
 *   Layer 1 (20%): Meeting Affinity (#1-#4)
 *   Layer 2 (50%): Deep Psychological Sync (#5-#11)
 *   Layer 3 (30%): Future Compatibility (#12-#14)
 *
 * All feature scores are normalized to 0.0-1.0.
 */

import type { Database, Json } from "../db/types";
import type { SupabaseClient } from "@supabase/supabase-js";

type ProfileRow = Database["public"]["Tables"]["profiles"]["Row"];

// ─── Feature Definitions ───────────────────────────────────────────────

export interface FeatureDefinition {
	id: number;
	name: string;
	nameJa: string;
	layer: 1 | 2 | 3;
	sourcePhasePrimary: SourcePhase[];
	isDealbreaker: boolean;
}

export type SourcePhase = "quiz" | "speed_dating" | "fox_conversation" | "partner_fox_chat" | "direct_chat";

export const FEATURES: readonly FeatureDefinition[] = [
	// Layer 1: Meeting Affinity
	{ id: 1, name: "proximity", nameJa: "近接性", layer: 1, sourcePhasePrimary: ["quiz"], isDealbreaker: false },
	{ id: 2, name: "mere_exposure", nameJa: "単純接触効果", layer: 1, sourcePhasePrimary: ["speed_dating"], isDealbreaker: false },
	{ id: 3, name: "similarity_complementarity", nameJa: "類似性・相補性", layer: 1, sourcePhasePrimary: ["quiz", "speed_dating"], isDealbreaker: false },
	{ id: 4, name: "reciprocity", nameJa: "好意の返報性", layer: 1, sourcePhasePrimary: ["fox_conversation", "partner_fox_chat"], isDealbreaker: false },
	// Layer 2: Deep Psychological Sync
	{ id: 5, name: "attachment", nameJa: "アタッチメント", layer: 2, sourcePhasePrimary: ["speed_dating"], isDealbreaker: false },
	{ id: 6, name: "humor_sharing", nameJa: "ユーモア共有", layer: 2, sourcePhasePrimary: ["speed_dating", "fox_conversation"], isDealbreaker: false },
	{ id: 7, name: "self_disclosure", nameJa: "自己開示", layer: 2, sourcePhasePrimary: ["speed_dating", "fox_conversation"], isDealbreaker: true },
	{ id: 8, name: "synchrony", nameJa: "非言語同調", layer: 2, sourcePhasePrimary: ["speed_dating"], isDealbreaker: false },
	{ id: 9, name: "emotional_responsiveness", nameJa: "感情的応答性", layer: 2, sourcePhasePrimary: ["fox_conversation", "partner_fox_chat"], isDealbreaker: false },
	{ id: 10, name: "self_expansion", nameJa: "自己拡張", layer: 2, sourcePhasePrimary: ["speed_dating", "partner_fox_chat"], isDealbreaker: false },
	{ id: 11, name: "self_esteem", nameJa: "自己肯定感", layer: 2, sourcePhasePrimary: ["fox_conversation", "partner_fox_chat"], isDealbreaker: false },
	// Layer 3: Future Compatibility
	{ id: 12, name: "physiological", nameJa: "生理的適合性", layer: 3, sourcePhasePrimary: ["speed_dating"], isDealbreaker: false },
	{ id: 13, name: "economic_alignment", nameJa: "経済的行動特性", layer: 3, sourcePhasePrimary: ["quiz"], isDealbreaker: false },
	{ id: 14, name: "conflict_resolution", nameJa: "葛藤解決スタイル", layer: 3, sourcePhasePrimary: ["fox_conversation", "partner_fox_chat"], isDealbreaker: true },
] as const;

export const FEATURE_BY_ID = new Map(FEATURES.map((f) => [f.id, f]));

const LAYER_WEIGHTS = { 1: 0.2, 2: 0.5, 3: 0.3 } as const;

// ─── Feature Score Type ────────────────────────────────────────────────

export interface FeatureScore {
	featureId: number;
	featureName: string;
	rawScore: number; // 0.0-1.0
	normalizedScore: number; // 0.0-1.0
	confidence: number; // 0.0-1.0
	evidence: Record<string, unknown>;
	sourcePhase: SourcePhase;
}

export interface LayerScores {
	layer1: number; // 0.0-1.0
	layer2: number; // 0.0-1.0
	layer3: number; // 0.0-1.0
	finalScore: number; // 0-100
	featureScores: Record<number, number>; // featureId -> normalizedScore
}

export interface DealbreakerResult {
	triggered: boolean;
	features: { featureId: number; featureName: string; reason: string }[];
}

// ─── Layer Assignment (corrected per spec) ─────────────────────────────
// Layer 1: #1-#4, Layer 2: #5-#11, Layer 3: #12-#14

function getFeatureLayer(featureId: number): 1 | 2 | 3 {
	if (featureId >= 1 && featureId <= 4) return 1;
	if (featureId >= 5 && featureId <= 11) return 2;
	return 3;
}

// ─── Profile-based Feature Extraction (Quiz phase) ─────────────────────

/** #1 Proximity: location similarity from quiz data */
function computeProximity(profileA: ProfileRow, profileB: ProfileRow): number {
	const infoA = (profileA.basic_info as Record<string, string>) ?? {};
	const infoB = (profileB.basic_info as Record<string, string>) ?? {};
	const locA = (infoA.location ?? "").toLowerCase().trim();
	const locB = (infoB.location ?? "").toLowerCase().trim();
	if (!locA || !locB) return 0.5; // no data → neutral
	if (locA === locB) return 1.0;
	// Partial match: same prefecture prefix
	const prefA = locA.slice(0, 3);
	const prefB = locB.slice(0, 3);
	if (prefA === prefB) return 0.8;
	return 0.3;
}

/** #3 Similarity & Complementarity: personality + interests + values overlap */
function computeSimilarityComplementarity(profileA: ProfileRow, profileB: ProfileRow): number {
	// Personality similarity (axis distance)
	const pa = (profileA.personality_analysis as Record<string, number>) ?? {};
	const pb = (profileB.personality_analysis as Record<string, number>) ?? {};
	let axisSim = 0;
	let axisCount = 0;
	for (const key of ["introvert_extrovert", "planned_spontaneous", "logical_emotional"]) {
		const va = pa[key];
		const vb = pb[key];
		if (typeof va === "number" && typeof vb === "number") {
			axisSim += 1 - Math.abs(va - vb);
			axisCount++;
		}
	}
	const personalitySim = axisCount > 0 ? axisSim / axisCount : 0.5;

	// Personality tags overlap
	const tagsA = (profileA.personality_tags as string[]) ?? [];
	const tagsB = (profileB.personality_tags as string[]) ?? [];
	const tagOverlap =
		tagsA.length && tagsB.length ? tagsA.filter((t) => tagsB.includes(t)).length / Math.max(tagsA.length, tagsB.length) : 0.5;

	// Interests Jaccard
	const ia = (profileA.interests as { category: string; items: string[] }[]) ?? [];
	const ib = (profileB.interests as { category: string; items: string[] }[]) ?? [];
	const itemsA = new Set(ia.flatMap((x) => x.items ?? []));
	const itemsB = new Set(ib.flatMap((x) => x.items ?? []));
	const interestOverlap =
		itemsA.size || itemsB.size
			? [...itemsA].filter((x) => itemsB.has(x)).length / new Set([...itemsA, ...itemsB]).size
			: 0.5;

	// Values similarity
	const va2 = (profileA.values as Record<string, number>) ?? {};
	const vb2 = (profileB.values as Record<string, number>) ?? {};
	const vKeys = new Set([...Object.keys(va2), ...Object.keys(vb2)]);
	let valSum = 0;
	let valN = 0;
	for (const k of vKeys) {
		if (typeof va2[k] === "number" && typeof vb2[k] === "number") {
			valSum += 1 - Math.abs(va2[k] - vb2[k]);
			valN++;
		}
	}
	const valuesSim = valN > 0 ? valSum / valN : 0.5;

	return personalitySim * 0.3 + tagOverlap * 0.1 + interestOverlap * 0.3 + valuesSim * 0.3;
}

/** #13 Economic alignment: values / lifestyle similarity */
function computeEconomicAlignment(profileA: ProfileRow, profileB: ProfileRow): number {
	const va = (profileA.values as Record<string, number>) ?? {};
	const vb = (profileB.values as Record<string, number>) ?? {};
	// Focus on economic-relevant value keys
	const economicKeys = ["work_life_balance", "experience_vs_material"];
	let sum = 0;
	let n = 0;
	for (const k of economicKeys) {
		if (typeof va[k] === "number" && typeof vb[k] === "number") {
			sum += 1 - Math.abs(va[k] - vb[k]);
			n++;
		}
	}
	return n > 0 ? sum / n : 0.5;
}

// ─── Interaction Style Feature Extraction (Speed Dating phase) ─────────

type InteractionStyle = {
	warmup_speed?: number;
	humor_responsiveness?: number;
	self_disclosure_depth?: number;
	emotional_responsiveness?: number;
	conflict_style?: string;
	attachment_tendency?: string;
	rhythm_preference?: string;
	mirroring_tendency?: number;
};

function getInteractionStyle(profile: ProfileRow): InteractionStyle {
	return (profile.interaction_style as InteractionStyle) ?? {};
}

/** #2 Mere Exposure: warmup speed indicates how quickly comfort builds */
function computeMereExposure(profileA: ProfileRow, profileB: ProfileRow): number {
	const isA = getInteractionStyle(profileA);
	const isB = getInteractionStyle(profileB);
	const wA = isA.warmup_speed;
	const wB = isB.warmup_speed;
	if (typeof wA !== "number" || typeof wB !== "number") return 0.5;
	// Both warming up faster = higher mere exposure effect
	return (wA + wB) / 2;
}

/** #5 Attachment: compatibility of attachment tendencies */
function computeAttachment(profileA: ProfileRow, profileB: ProfileRow): number {
	const isA = getInteractionStyle(profileA);
	const isB = getInteractionStyle(profileB);
	const aA = isA.attachment_tendency;
	const aB = isB.attachment_tendency;
	if (!aA || !aB) return 0.5;
	// secure-secure is ideal, secure-anxious or secure-avoidant is workable, anxious-avoidant is challenging
	const ATTACHMENT_COMPAT: Record<string, Record<string, number>> = {
		secure: { secure: 1.0, anxious: 0.7, avoidant: 0.6 },
		anxious: { secure: 0.7, anxious: 0.4, avoidant: 0.2 },
		avoidant: { secure: 0.6, anxious: 0.2, avoidant: 0.3 },
	};
	return ATTACHMENT_COMPAT[aA]?.[aB] ?? 0.5;
}

/** #6 Humor sharing: both sides' humor responsiveness */
function computeHumorSharing(profileA: ProfileRow, profileB: ProfileRow): number {
	const isA = getInteractionStyle(profileA);
	const isB = getInteractionStyle(profileB);
	const hA = isA.humor_responsiveness;
	const hB = isB.humor_responsiveness;
	if (typeof hA !== "number" || typeof hB !== "number") return 0.5;
	// Similarity of humor responsiveness + average level
	const similarity = 1 - Math.abs(hA - hB);
	const level = (hA + hB) / 2;
	return similarity * 0.5 + level * 0.5;
}

/** #7 Self-disclosure: depth of personal sharing */
function computeSelfDisclosure(profileA: ProfileRow, profileB: ProfileRow): number {
	const isA = getInteractionStyle(profileA);
	const isB = getInteractionStyle(profileB);
	const dA = isA.self_disclosure_depth;
	const dB = isB.self_disclosure_depth;
	if (typeof dA !== "number" || typeof dB !== "number") return 0.5;
	// Both should be willing to share; balance matters too
	const similarity = 1 - Math.abs(dA - dB);
	const level = (dA + dB) / 2;
	return similarity * 0.4 + level * 0.6;
}

/** #8 Synchrony: mirroring tendency */
function computeSynchrony(profileA: ProfileRow, profileB: ProfileRow): number {
	const isA = getInteractionStyle(profileA);
	const isB = getInteractionStyle(profileB);
	const mA = isA.mirroring_tendency;
	const mB = isB.mirroring_tendency;
	if (typeof mA !== "number" || typeof mB !== "number") return 0.5;
	return (mA + mB) / 2;
}

/** #9 Emotional Responsiveness (A.R.E.) */
function computeEmotionalResponsiveness(profileA: ProfileRow, profileB: ProfileRow): number {
	const isA = getInteractionStyle(profileA);
	const isB = getInteractionStyle(profileB);
	const eA = isA.emotional_responsiveness;
	const eB = isB.emotional_responsiveness;
	if (typeof eA !== "number" || typeof eB !== "number") return 0.5;
	const similarity = 1 - Math.abs(eA - eB);
	const level = (eA + eB) / 2;
	return similarity * 0.3 + level * 0.7;
}

/** #12 Physiological compatibility: rhythm preference alignment */
function computePhysiological(profileA: ProfileRow, profileB: ProfileRow): number {
	const isA = getInteractionStyle(profileA);
	const isB = getInteractionStyle(profileB);
	const rA = isA.rhythm_preference;
	const rB = isB.rhythm_preference;
	if (!rA || !rB) return 0.5;
	if (rA === rB) return 1.0;
	const RHYTHM_DIST: Record<string, Record<string, number>> = {
		slow: { slow: 1.0, moderate: 0.7, fast: 0.3 },
		moderate: { slow: 0.7, moderate: 1.0, fast: 0.7 },
		fast: { slow: 0.3, moderate: 0.7, fast: 1.0 },
	};
	return RHYTHM_DIST[rA]?.[rB] ?? 0.5;
}

/** #14 Conflict resolution style compatibility */
function computeConflictResolution(profileA: ProfileRow, profileB: ProfileRow): number {
	const isA = getInteractionStyle(profileA);
	const isB = getInteractionStyle(profileB);
	const cA = isA.conflict_style;
	const cB = isB.conflict_style;
	if (!cA || !cB) return 0.5;
	// "dialogue" is healthiest; "avoids" or "yields" is lower; "maintains" can be problematic
	const CONFLICT_COMPAT: Record<string, Record<string, number>> = {
		dialogue: { dialogue: 1.0, yields: 0.7, maintains: 0.5, avoids: 0.4 },
		yields: { dialogue: 0.7, yields: 0.5, maintains: 0.3, avoids: 0.4 },
		maintains: { dialogue: 0.5, yields: 0.3, maintains: 0.2, avoids: 0.2 },
		avoids: { dialogue: 0.4, yields: 0.4, maintains: 0.2, avoids: 0.3 },
	};
	return CONFLICT_COMPAT[cA]?.[cB] ?? 0.5;
}

// ─── Compute All Profile-Based Features ────────────────────────────────

export function computeProfileFeatureScores(
	profileA: ProfileRow,
	profileB: ProfileRow,
): FeatureScore[] {
	const scores: FeatureScore[] = [];

	const add = (id: number, score: number, phase: SourcePhase, evidence: Record<string, unknown> = {}) => {
		const feat = FEATURE_BY_ID.get(id);
		if (!feat) return;
		const clamped = Math.max(0, Math.min(1, score));
		scores.push({
			featureId: id,
			featureName: feat.nameJa,
			rawScore: clamped,
			normalizedScore: clamped,
			confidence: 0.6,
			evidence,
			sourcePhase: phase,
		});
	};

	// Quiz-based features
	add(1, computeProximity(profileA, profileB), "quiz");
	add(3, computeSimilarityComplementarity(profileA, profileB), "quiz");
	add(13, computeEconomicAlignment(profileA, profileB), "quiz");

	// Speed dating / interaction_style-based features
	add(2, computeMereExposure(profileA, profileB), "speed_dating");
	add(5, computeAttachment(profileA, profileB), "speed_dating");
	add(6, computeHumorSharing(profileA, profileB), "speed_dating");
	add(7, computeSelfDisclosure(profileA, profileB), "speed_dating");
	add(8, computeSynchrony(profileA, profileB), "speed_dating");
	add(9, computeEmotionalResponsiveness(profileA, profileB), "speed_dating");
	add(12, computePhysiological(profileA, profileB), "speed_dating");
	add(14, computeConflictResolution(profileA, profileB), "speed_dating");

	// Features #4, #10, #11 require conversation data — set to neutral default
	add(4, 0.5, "quiz", { note: "placeholder_until_conversation" });
	add(10, 0.5, "quiz", { note: "placeholder_until_conversation" });
	add(11, 0.5, "quiz", { note: "placeholder_until_conversation" });

	return scores;
}

// ─── 3-Layer Score Calculation ─────────────────────────────────────────

export function calculateLayerScores(featureScores: Map<number, number>): LayerScores {
	const layerSums = { 1: 0, 2: 0, 3: 0 };
	const layerCounts = { 1: 0, 2: 0, 3: 0 };

	for (const [featureId, score] of featureScores) {
		const layer = getFeatureLayer(featureId);
		layerSums[layer] += score;
		layerCounts[layer]++;
	}

	const layer1 = layerCounts[1] > 0 ? layerSums[1] / layerCounts[1] : 0.5;
	const layer2 = layerCounts[2] > 0 ? layerSums[2] / layerCounts[2] : 0.5;
	const layer3 = layerCounts[3] > 0 ? layerSums[3] / layerCounts[3] : 0.5;

	const weighted = layer1 * LAYER_WEIGHTS[1] + layer2 * LAYER_WEIGHTS[2] + layer3 * LAYER_WEIGHTS[3];
	const finalScore = Math.round(weighted * 100);

	const featureScoresObj: Record<number, number> = {};
	for (const [id, score] of featureScores) {
		featureScoresObj[id] = Math.round(score * 1000) / 1000;
	}

	return {
		layer1: Math.round(layer1 * 1000) / 1000,
		layer2: Math.round(layer2 * 1000) / 1000,
		layer3: Math.round(layer3 * 1000) / 1000,
		finalScore: Math.min(100, finalScore),
		featureScores: featureScoresObj,
	};
}

// ─── Dealbreaker Detection ─────────────────────────────────────────────

const SELF_DISCLOSURE_REJECTION_THRESHOLD = 0.15;
const DESTRUCTIVE_CONFLICT_THRESHOLD = 0.2;

export function detectDealbreakers(featureScores: Map<number, number>): DealbreakerResult {
	const triggered: DealbreakerResult["features"] = [];

	// #7 Self-disclosure rejection
	const sdScore = featureScores.get(7);
	if (sdScore !== undefined && sdScore < SELF_DISCLOSURE_REJECTION_THRESHOLD) {
		triggered.push({
			featureId: 7,
			featureName: "自己開示",
			reason: `自己開示スコアが極端に低い (${sdScore.toFixed(3)})。脆弱性の受容に深刻な問題がある可能性`,
		});
	}

	// #14 Destructive conflict style
	const crScore = featureScores.get(14);
	if (crScore !== undefined && crScore < DESTRUCTIVE_CONFLICT_THRESHOLD) {
		triggered.push({
			featureId: 14,
			featureName: "葛藤解決スタイル",
			reason: `葛藤解決スコアが極端に低い (${crScore.toFixed(3)})。破壊的な対立パターンの可能性`,
		});
	}

	return { triggered: triggered.length > 0, features: triggered };
}

// ─── Save Feature Scores to DB ─────────────────────────────────────────

/**
 * Upserts every feature score for one match in a SINGLE subrequest.
 *
 * This used to issue one upsert per feature — up to 14 subrequests per match on
 * the daily-batch path (`FEATURES` has 14 entries; the step 3-D note's "17" is
 * the Durable Object path, which scores 6 conversation features plus 11 profile
 * ones). A Workers Free invocation may issue only 50 external subrequests, and
 * the `scheduled`
 * handler runs `executeDailyMatching` (which calls this once per match created)
 * before the deferred-notification executor in the same invocation, so the old
 * shape put the daily batch over the cap at two or three matches a day. See
 * step-04-notifications.md §4-b (the 4-C budget recount).
 *
 * `onConflict` behaviour is preserved exactly, including for duplicates: a
 * sequential loop applied same-key rows one after another, so the LAST one won.
 * A single multi-row upsert cannot do that — Postgres raises "ON CONFLICT DO
 * UPDATE command cannot affect row a second time" when one statement carries
 * two rows with the same conflict key — so duplicates are collapsed here,
 * keeping the last, which is what the loop produced.
 */
export async function saveFeatureScores(
	supabase: SupabaseClient<Database>,
	matchId: string,
	scores: FeatureScore[],
	options: Readonly<{ throwOnError?: boolean }> = {},
): Promise<void> {
	if (scores.length === 0) return;

	// Keyed by the upsert's conflict target, last write winning — see above.
	const byConflictKey = new Map<string, Record<string, unknown>>();
	for (const s of scores) {
		byConflictKey.set(`${s.featureId}\u0000${s.sourcePhase}`, {
			match_id: matchId,
			feature_id: s.featureId,
			feature_name: s.featureName,
			raw_score: s.rawScore,
			normalized_score: s.normalizedScore,
			confidence: s.confidence,
			evidence: s.evidence as Json,
			source_phase: s.sourcePhase,
		});
	}

	const { error } = await supabase
		.from("interaction_dna_scores")
		// biome-ignore lint/suspicious/noExplicitAny: the row shape is built dynamically above; the columns are checked against the table by the query itself
		.upsert([...byConflictKey.values()] as any, { onConflict: "match_id,feature_id,source_phase" });

	// The previous per-row loop discarded its result entirely. supabase-js
	// resolves with `{ error }` rather than rejecting on a PostgREST error, so
	// that was a silent fail-open. Logging rather than throwing is deliberate:
	// callers (the daily batch's per-match loop, the conversation engine's
	// scoring step) have no handling for a throw here, and turning a lost
	// scores write into an aborted batch would be a behaviour change beyond
	// this fix. The server-side log is the detection path.
	if (error) {
		console.error("[saveFeatureScores] failed to upsert feature scores");
		if (options.throwOnError) throw new Error("Failed to save feature scores");
	}
}

// ─── Load Feature Scores from DB ───────────────────────────────────────

export async function loadFeatureScores(
	supabase: SupabaseClient<Database>,
	matchId: string,
): Promise<Map<number, number>> {
	const { data, error } = await supabase
		.from("interaction_dna_scores")
		.select("feature_id, normalized_score, confidence, source_phase")
		.eq("match_id", matchId);
	if (error || !data) {
		console.error("[loadFeatureScores] failed to load feature scores");
		throw new Error("Failed to load feature scores");
	}

	// For each feature, take the highest-confidence score across phases
	const best = new Map<number, { score: number; confidence: number }>();
	for (const row of data ?? []) {
		const existing = best.get(row.feature_id);
		const score = Number(row.normalized_score);
		const conf = Number(row.confidence);
		if (!existing || conf > existing.confidence) {
			best.set(row.feature_id, { score, confidence: conf });
		}
	}

	const result = new Map<number, number>();
	for (const [featureId, { score }] of best) {
		result.set(featureId, score);
	}
	return result;
}

// ─── Full Compatibility Calculation ────────────────────────────────────

export async function calculateCompatibility(
	supabase: SupabaseClient<Database>,
	matchId: string,
	profileA: ProfileRow,
	profileB: ProfileRow,
): Promise<{
	layerScores: LayerScores;
	dealbreakers: DealbreakerResult;
	featureScores: FeatureScore[];
}> {
	// 1. Compute profile-based feature scores
	const featureScores = computeProfileFeatureScores(profileA, profileB);

	// 2. Save to DB
	await saveFeatureScores(supabase, matchId, featureScores);

	// 3. Load all scores (may include previously computed conversation scores)
	const allScores = await loadFeatureScores(supabase, matchId);

	// 4. Calculate 3-layer scores
	const layerScores = calculateLayerScores(allScores);

	// 5. Detect dealbreakers
	const dealbreakers = detectDealbreakers(allScores);

	// 6. Update match with layer scores
	const { error: matchUpdateError } = await supabase
		.from("matches")
		.update({
			profile_score: layerScores.finalScore,
			final_score: dealbreakers.triggered ? 0 : layerScores.finalScore,
			layer_scores: {
				layer1: layerScores.layer1,
				layer2: layerScores.layer2,
				layer3: layerScores.layer3,
				feature_scores: layerScores.featureScores,
				dealbreakers: dealbreakers.triggered ? dealbreakers.features : [],
			} as Json,
			score_details: {
				feature_scores: layerScores.featureScores,
				layer1: layerScores.layer1,
				layer2: layerScores.layer2,
				layer3: layerScores.layer3,
			} as Json,
			updated_at: new Date().toISOString(),
		})
		.eq("id", matchId);
	if (matchUpdateError) {
		console.error("[calculateCompatibility] failed to update match scores");
		throw new Error("Failed to update match scores");
	}

	return { layerScores, dealbreakers, featureScores };
}
