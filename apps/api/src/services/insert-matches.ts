import { DEMO_20260930_PROFILE_IDS } from "./synthetic-matching-cohort";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import {
	areMutuallyEligible,
	loadMatchingEligibilityProfiles,
	type MatchingEligibilityProfileMap,
} from "./matching-eligibility";

/**
 * Insert rows into `matches`, rejecting blocked or no-longer-mutual pairs
 * without discarding the rest of the batch.
 *
 * The block trigger is existing; mutual-preference enforcement additionally
 * requires the B2-B SQL backstop (not implemented or runtime-tested by B2-A).
 * This wrapper alone does not make a stale first insert safe. In either case,
 * Postgres aborts a multi-row INSERT statement entirely if any one row
 * violates a trigger's RAISE — it does not apply the other rows and skip the
 * bad one. The caller's reads may be stale by the time this runs; if a block
 * or preference changed since then, the trigger rejects that one pair with
 * 23514, and naively surfacing that error (or silently returning zero) would
 * discard every other valid pair in the batch along with it. So: on 23514,
 * re-read both blocks and current matching eligibility, drop invalid rows, and
 * retry once. The returned `keptIndices` are into
 * `rows` in the SAME positions as the returned `inserted` array — the caller
 * must filter its own parallel arrays (allocated pairs, feature scores, ...)
 * by the same indices before zipping them against `inserted`.
 *
 * Shared by both matching entry points (`daily-matching.ts` and
 * `matching.ts`) precisely because having this logic in one file only was
 * the round-4 finding: the identical unhandled site existed in both places.
 */
export type InsertMatchAdmissionOptions = Readonly<{
	scopeIds?: readonly string[];
	judgeScope?: Readonly<{ profileIds: readonly string[]; actorId: string }>;
	canWrite?: () => boolean;
}>;

type InsertMatchesResult = {
	inserted: { id: string }[];
	keptIndices: number[];
	windowClosed?: boolean;
};

export async function insertMatchesRejectingBlockedPairs<
	T extends { user_a_id: string; user_b_id: string },
>(
	supabase: SupabaseClient<Database>,
	rows: T[],
	logPrefix: string,
	admission?: InsertMatchAdmissionOptions,
): Promise<InsertMatchesResult> {
	const judge = admission?.judgeScope;
	if (judge && (admission?.scopeIds !== undefined || judge.profileIds.length !== DEMO_20260930_PROFILE_IDS.length || new Set(judge.profileIds).size !== DEMO_20260930_PROFILE_IDS.length || !DEMO_20260930_PROFILE_IDS.every(id=>judge.profileIds.includes(id)) || !judge.profileIds.includes(judge.actorId) || rows.some(row=>!judge.profileIds.includes(row.user_a_id) || !judge.profileIds.includes(row.user_b_id) || (row.user_a_id !== judge.actorId && row.user_b_id !== judge.actorId)))) throw new Error("Matching aborted: invalid judge insertion scope");
	const scopeIds = admission?.scopeIds;
	const readScopeIds = judge?.profileIds ?? scopeIds;
	if (
		scopeIds !== undefined &&
		(scopeIds.length !== 2 || new Set(scopeIds).size !== 2 || rows.some(
			(row) => !scopeIds.includes(row.user_a_id) || !scopeIds.includes(row.user_b_id),
		))
	) {
		throw new Error("Matching aborted: invalid selected-pair insertion scope");
	}
	const isAdmitted = () => {
		if (!admission?.canWrite) return true;
		try {
			return admission.canWrite() === true;
		} catch {
			return false;
		}
	};
	const result = (inserted: { id: string }[], keptIndices: number[], windowClosed = false): InsertMatchesResult =>
		admission ? { inserted, keptIndices, windowClosed } : { inserted, keptIndices };

	if (!isAdmitted()) return result([], [], true);
	const { data: inserted, error: insertError } = await supabase
		.from("matches")
		.insert(rows)
		.select("id");
	const admittedAfterInitialWrite = isAdmitted();

	if (!insertError && inserted) {
		return result(inserted, rows.map((_, i) => i), !admittedAfterInitialWrite);
	}
	if (!insertError) {
		console.error(`${logPrefix} matches insert returned no data`);
		throw new Error("Matching aborted: matches insert returned no data");
	}

	if (insertError.code !== "23514") {
		console.error(`${logPrefix} matches insert failed`);
		throw new Error("Matching aborted: matches insert failed");
	}

	if (!admittedAfterInitialWrite) return result([], [], true);
	// A 23514 can now come from either the bidirectional block invariant or
	// the mutual-preference invariant. Refresh both inputs before deciding
	// which rows can survive; neither stale discovery data nor legacy gender
	// values are sufficient here.
	if (!isAdmitted()) return result([], [], true);
	const [freshBlocksResult, eligibilityResult] = await Promise.all([
		(async () => {
			try {
				let blocksQuery = supabase.from("blocks").select("blocker_id, blocked_id");
				if (readScopeIds) {
					blocksQuery = blocksQuery.in("blocker_id", [...readScopeIds]).in("blocked_id", [...readScopeIds]);
				}
				return await blocksQuery;
			} catch {
				return null;
			}
		})(),
		(async () => {
			try {
				return await loadMatchingEligibilityProfiles(
					supabase,
					[...new Set(rows.flatMap((row) => [row.user_a_id, row.user_b_id]))],
				);
			} catch {
				return null;
			}
		})(),
	]);
	if (!freshBlocksResult || freshBlocksResult.error || !freshBlocksResult.data) {
		console.error(`${logPrefix} re-read of blocks after a blocked-pair rejection failed`);
		throw new Error("Matching aborted: the block list could not be re-read after a blocked-pair rejection");
	}
	if (!eligibilityResult) {
		console.error(`${logPrefix} re-read of matching eligibility after a constraint rejection failed`);
		throw new Error("Matching aborted: matching eligibility could not be re-read after a constraint rejection");
	}
	if (!isAdmitted()) return result([], [], true);
	const freshBlocks = freshBlocksResult.data;
	if (judge && freshBlocks.some(row=>!judge.profileIds.includes(row.blocker_id) || !judge.profileIds.includes(row.blocked_id))) throw new Error("Matching aborted: invalid judge block scope");
	const eligibilityByUserId: MatchingEligibilityProfileMap = eligibilityResult;
	const freshBlockSet = new Set(
		(freshBlocks ?? []).map((b) => `${b.blocker_id}:${b.blocked_id}`),
	);
	const isNowBlocked = (a: string, b: string) =>
		freshBlockSet.has(`${a}:${b}`) || freshBlockSet.has(`${b}:${a}`);

	const keptIndices: number[] = [];
	rows.forEach((row, i) => {
		if (
			!isNowBlocked(row.user_a_id, row.user_b_id) &&
			areMutuallyEligible(eligibilityByUserId.get(row.user_a_id), eligibilityByUserId.get(row.user_b_id))
		) {
			keptIndices.push(i);
		}
	});
	const droppedCount = rows.length - keptIndices.length;
	console.warn(
		`${logPrefix} dropped ${droppedCount} pair(s) rejected by a matching invariant after the first read; retrying the insert with the remaining ${keptIndices.length} pair(s)`,
	);

	if (keptIndices.length === 0) {
		// Every pair in this batch got blocked out from under it — a genuine
		// zero, not a swallowed failure.
		return result([], [], !isAdmitted());
	}
	if (!isAdmitted()) return result([], [], true);

	const retryRows = keptIndices.map((i) => rows[i]);
	const retry = await supabase.from("matches").insert(retryRows).select("id");
	const admittedAfterRetry = isAdmitted();
	if (retry.error) {
		console.error(`${logPrefix} matches insert retry after filtering blocked pairs failed`);
		throw new Error("Matching aborted: matches insert failed even after filtering blocked pairs");
	}
	if (!retry.data) {
		console.error(`${logPrefix} matches insert retry returned no data`);
		throw new Error("Matching aborted: matches insert retry returned no data");
	}

	return result(retry.data, keptIndices, !admittedAfterRetry);
}
