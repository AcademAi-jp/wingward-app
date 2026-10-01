import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { MATCHING_ELIGIBILITY_COLUMNS, areMutuallyEligible } from "./matching-eligibility";

export const MAX_MATCHING_CURRENT_SNAPSHOT_EXPECTATIONS = 128;

export type MatchingCurrentSnapshotExpectation = {
	matchId: string;
	ownerId: string;
	participantIds: readonly [string, string];
};

export type MatchingCurrentSnapshotProfile = Record<string, unknown> & {
	id: string;
};

export type MatchingCurrentSnapshotConversation = {
	id: string;
	match_id: string;
	purpose: "compatibility";
	status: string;
};

export type MatchingCurrentSnapshot = {
	id: string;
	user_a_id: string;
	user_b_id: string;
	status: string;
	final_score: unknown;
	profile_score: unknown;
	conversation_score: unknown;
	score_details: unknown;
	layer_scores?: unknown;
	created_at?: unknown;
	profile_a: MatchingCurrentSnapshotProfile;
	profile_b: MatchingCurrentSnapshotProfile;
	compatibilityConversation: MatchingCurrentSnapshotConversation | null;
};

export type MatchingCurrentSnapshotResult =
	| { ok: true; rows: Map<string, MatchingCurrentSnapshot> }
	| { ok: false; reason: "error" | "too_many_expectations" };

type QueryResult = { data: unknown; error: unknown };

const MATCHING_CURRENT_SNAPSHOT_SELECT = [
	"id,user_a_id,user_b_id,final_score,profile_score,conversation_score,status,score_details,layer_scores,created_at",
	`profile_a:user_profiles!matches_user_a_id_fkey!inner(nickname,avatar_url,avatar_storage_path,${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id))`,
	`profile_b:user_profiles!matches_user_b_id_fkey!inner(nickname,avatar_url,avatar_storage_path,${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id))`,
	"compatibility_conversations:fox_conversations!fox_conversations_match_id_fkey(id,match_id,purpose,status)",
].join(",");

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown): value is string {
	return typeof value === "string" && value.trim().length > 0;
}

function asRows(value: unknown): Record<string, unknown>[] | null {
	if (!Array.isArray(value) || !value.every(isRecord)) return null;
	return value;
}

function validateBlockRows(
	value: unknown,
	expectedBlocker: string,
	expectedBlocked: string,
): { ok: true; blocked: boolean } | { ok: false } {
	const rows = asRows(value);
	if (!rows) return { ok: false };

	let blocked = false;
	for (const row of rows) {
		if (!isNonEmptyString(row.id) || row.blocker_id !== expectedBlocker || !isNonEmptyString(row.blocked_id)) {
			return { ok: false };
		}
		if (row.blocked_id === expectedBlocked) blocked = true;
	}
	return { ok: true, blocked };
}

function parseCompatibilityConversation(
	value: unknown,
	matchId: string,
): { ok: true; value: MatchingCurrentSnapshotConversation | null } | { ok: false } {
	const rows = asRows(value);
	if (!rows) return { ok: false };

	const compatibilityRows: MatchingCurrentSnapshotConversation[] = [];
	for (const row of rows) {
		if (
			!isNonEmptyString(row.id) ||
			row.match_id !== matchId ||
			!isNonEmptyString(row.purpose) ||
			!isNonEmptyString(row.status)
		) {
			return { ok: false };
		}
		if (row.purpose === "compatibility") {
			compatibilityRows.push({
				id: row.id,
				match_id: row.match_id,
				purpose: "compatibility",
				status: row.status,
			});
		}
	}
	if (compatibilityRows.length > 1) return { ok: false };
	return { ok: true, value: compatibilityRows[0] ?? null };
}

function validateExpectation(
	value: MatchingCurrentSnapshotExpectation,
): value is MatchingCurrentSnapshotExpectation {
	return (
		isNonEmptyString(value.matchId) &&
		isNonEmptyString(value.ownerId) &&
		Array.isArray(value.participantIds) &&
		value.participantIds.length === 2 &&
		isNonEmptyString(value.participantIds[0]) &&
		isNonEmptyString(value.participantIds[1]) &&
		value.participantIds[0] !== value.participantIds[1] &&
		(value.ownerId === value.participantIds[0] || value.ownerId === value.participantIds[1])
	);
}

function validateSnapshotRow(
	value: unknown,
	expectation: MatchingCurrentSnapshotExpectation,
): MatchingCurrentSnapshot | null {
	if (!isRecord(value)) return null;
	if (
		value.id !== expectation.matchId ||
		value.user_a_id !== expectation.participantIds[0] ||
		value.user_b_id !== expectation.participantIds[1] ||
		!isNonEmptyString(value.status) ||
		!isRecord(value.profile_a) ||
		!isRecord(value.profile_b)
	) {
		return null;
	}

	const profileA = value.profile_a;
	const profileB = value.profile_b;
	const blocksSentA = profileA["blocks_sent"];
	const blocksSentB = profileB["blocks_sent"];
	if (
		profileA.id !== expectation.participantIds[0] ||
		profileB.id !== expectation.participantIds[1] ||
		!areMutuallyEligible(profileA, profileB)
	) {
		return null;
	}

	const blocksFromA = validateBlockRows(blocksSentA, profileA.id, profileB.id);
	const blocksFromB = validateBlockRows(blocksSentB, profileB.id, profileA.id);
	if (!blocksFromA.ok || !blocksFromB.ok || blocksFromA.blocked || blocksFromB.blocked) return null;

	const compatibility = parseCompatibilityConversation(value.compatibility_conversations, expectation.matchId);
	if (!compatibility.ok) return null;

	return {
		id: value.id,
		user_a_id: value.user_a_id,
		user_b_id: value.user_b_id,
		status: value.status,
		final_score: value.final_score,
		profile_score: value.profile_score,
		conversation_score: value.conversation_score,
		score_details: value.score_details,
		layer_scores: value.layer_scores,
		created_at: value.created_at,
		profile_a: profileA as MatchingCurrentSnapshotProfile,
		profile_b: profileB as MatchingCurrentSnapshotProfile,
		compatibilityConversation: compatibility.value,
	};
}

function validateExpectations(
	expectations: readonly MatchingCurrentSnapshotExpectation[],
): { ok: true; participantIds: string[] } | { ok: false; reason: "error" | "too_many_expectations" } {
	if (expectations.length > MAX_MATCHING_CURRENT_SNAPSHOT_EXPECTATIONS) {
		return { ok: false, reason: "too_many_expectations" };
	}

	const matchIds = new Set<string>();
	const participantIds = new Set<string>();
	for (const expectation of expectations) {
		if (!validateExpectation(expectation) || matchIds.has(expectation.matchId)) {
			return { ok: false, reason: "error" };
		}
		matchIds.add(expectation.matchId);
		participantIds.add(expectation.participantIds[0]);
		participantIds.add(expectation.participantIds[1]);
	}
	return { ok: true, participantIds: [...participantIds] };
}

/**
 * Reads the final current match/profile/block snapshot in one embedded request.
 * Individual revoked or malformed relationship rows are omitted; query-level
 * failures remain an explicit error so callers cannot return a partial list.
 */
export async function readMatchingCurrentSnapshot(
	supabase: SupabaseClient<Database>,
	expectations: readonly MatchingCurrentSnapshotExpectation[],
): Promise<MatchingCurrentSnapshotResult> {
	const validation = validateExpectations(expectations);
	if (validation.ok === false) return { ok: false, reason: validation.reason };
	if (expectations.length === 0) return { ok: true, rows: new Map() };

	let result: QueryResult;
	try {
		const query = supabase
			.from("matches")
			.select(MATCHING_CURRENT_SNAPSHOT_SELECT)
			.in("id", expectations.map((expectation) => expectation.matchId))
			.eq("compatibility_conversations.purpose", "compatibility")
			.in("profile_a.blocks_sent.blocked_id", validation.participantIds)
			.in("profile_b.blocks_sent.blocked_id", validation.participantIds);
		result = await query as unknown as QueryResult;
	} catch {
		return { ok: false, reason: "error" };
	}
	if (result.error || !Array.isArray(result.data)) return { ok: false, reason: "error" };

	const rowsById = new Map<string, unknown>();
	for (const row of result.data) {
		if (!isRecord(row) || !isNonEmptyString(row.id) || rowsById.has(row.id)) {
			return { ok: false, reason: "error" };
		}
		rowsById.set(row.id, row);
	}

	const rows = new Map<string, MatchingCurrentSnapshot>();
	for (const expectation of expectations) {
		const row = rowsById.get(expectation.matchId);
		if (!row) continue;
		const snapshot = validateSnapshotRow(row, expectation);
		if (snapshot) rows.set(expectation.matchId, snapshot);
	}
	return { ok: true, rows };
}

export { MATCHING_CURRENT_SNAPSHOT_SELECT };
