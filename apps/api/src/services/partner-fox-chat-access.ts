import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { MATCHING_ELIGIBILITY_COLUMNS, areMutuallyEligible } from "./matching-eligibility";

/** Match states in which an already-created partner-Fox chat remains usable. */
export const PARTNER_FOX_ALLOWED_MATCH_STATUSES = [
	"fox_conversation_completed",
	"partner_chat_started",
	"direct_chat_requested",
	"direct_chat_active",
	"meetup_intent",
	"meetup_confirmed",
] as const;

export type PartnerFoxMatchStatus = (typeof PARTNER_FOX_ALLOWED_MATCH_STATUSES)[number];

const PARTNER_FOX_ACTIVE_ROOM_STATUSES = new Set<string>([
	"direct_chat_active",
	"meetup_intent",
	"meetup_confirmed",
]);

const PARTNER_FOX_PROFILE_SELECT = `${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)`;

// Keep the current-state read in one PostgREST request. Explicit foreign-key
// hints prevent a schema change from silently selecting a different relation.
const CURRENT_PARTNER_FOX_ACCESS_SELECT = [
	"id,match_id,user_id,partner_user_id",
	`match:matches!partner_fox_chats_match_id_fkey!inner(id,user_a_id,user_b_id,status,profile_a:user_profiles!matches_user_a_id_fkey!inner(${PARTNER_FOX_PROFILE_SELECT}),profile_b:user_profiles!matches_user_b_id_fkey!inner(${PARTNER_FOX_PROFILE_SELECT}),fox_conversation:fox_conversations!fox_conversations_match_id_fkey!inner(id,match_id,purpose,status),direct_room:direct_chat_rooms!direct_chat_rooms_match_id_fkey(id,match_id,status))`,
].join(",");

const START_PARTNER_FOX_ACCESS_SELECT = [
	"id,user_a_id,user_b_id,status",
	`profile_a:user_profiles!matches_user_a_id_fkey!inner(${PARTNER_FOX_PROFILE_SELECT})`,
	`profile_b:user_profiles!matches_user_b_id_fkey!inner(${PARTNER_FOX_PROFILE_SELECT})`,
	"fox_conversation:fox_conversations!fox_conversations_match_id_fkey!inner(id,match_id,purpose,status)",
	"direct_room:direct_chat_rooms!direct_chat_rooms_match_id_fkey(id,match_id,status)",
].join(",");

const START_PARTNER_FOX_IDENTITY_SELECT = "id,user_a_id,user_b_id,status";

export type PartnerFoxChatAccessExpectation = {
	chatId: string;
	matchId: string;
	userId: string;
	partnerUserId: string;
};

export type PartnerFoxChatStartExpectation = {
	matchId: string;
	userId: string;
};

export type PartnerFoxChatAccessFailure = "not_found" | "forbidden" | "error";

export type PartnerFoxChatAccessResult =
	| { ok: true; matchStatus: PartnerFoxMatchStatus; partnerUserId: string }
	| { ok: false; reason: PartnerFoxChatAccessFailure };

export type PartnerFoxChatStartResult =
	| {
			ok: true;
			matchStatus: PartnerFoxMatchStatus;
			userAId: string;
			userBId: string;
			partnerUserId: string;
		}
	| { ok: false; reason: PartnerFoxChatAccessFailure | "not_ready" };

type QueryResult = { data: unknown; error: unknown };

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyId(value: unknown): value is string {
	return typeof value === "string" && value.trim().length > 0;
}

function isKnownContactStatus(value: unknown): value is (typeof PARTNER_FOX_ALLOWED_MATCH_STATUSES)[number] {
	return typeof value === "string" && (PARTNER_FOX_ALLOWED_MATCH_STATUSES as readonly string[]).includes(value);
}

function missingOrFailed(error: unknown): PartnerFoxChatAccessFailure {
	return isRecord(error) && error.code === "PGRST116" ? "not_found" : "error";
}

function validExpectation(expectation: PartnerFoxChatAccessExpectation): boolean {
	return (
		isNonEmptyId(expectation.chatId) &&
		isNonEmptyId(expectation.matchId) &&
		isNonEmptyId(expectation.userId) &&
		isNonEmptyId(expectation.partnerUserId) &&
		expectation.userId !== expectation.partnerUserId
	);
}

function validStartExpectation(expectation: PartnerFoxChatStartExpectation): boolean {
	return isNonEmptyId(expectation.matchId) && isNonEmptyId(expectation.userId);
}

async function readCurrentPartnerFoxRow(
	supabase: SupabaseClient<Database>,
	expectation: PartnerFoxChatAccessExpectation,
): Promise<QueryResult> {
	const [userAId, userBId] = [expectation.userId, expectation.partnerUserId].sort();
	try {
		return await supabase
			.from("partner_fox_chats")
			.select(CURRENT_PARTNER_FOX_ACCESS_SELECT)
			.eq("id", expectation.chatId)
			.eq("match_id", expectation.matchId)
			.eq("user_id", expectation.userId)
			.eq("partner_user_id", expectation.partnerUserId)
			.eq("match.fox_conversation.purpose", "compatibility")
			.eq("match.profile_a.blocks_sent.blocked_id", userBId)
			.eq("match.profile_b.blocks_sent.blocked_id", userAId)
			.single() as unknown as QueryResult;
	} catch {
		return { data: null, error: { accessLookupFailed: true } };
	}
}

async function readStartPartnerFoxRow(
	supabase: SupabaseClient<Database>,
	expectation: PartnerFoxChatStartExpectation,
	userAId: string,
	userBId: string,
): Promise<QueryResult> {
	try {
		return await supabase
			.from("matches")
			.select(START_PARTNER_FOX_ACCESS_SELECT)
			.eq("id", expectation.matchId)
			.eq("user_a_id", userAId)
			.eq("user_b_id", userBId)
			.eq("fox_conversation.purpose", "compatibility")
			.eq("profile_a.blocks_sent.blocked_id", userBId)
			.eq("profile_b.blocks_sent.blocked_id", userAId)
			.single() as unknown as QueryResult;
	} catch {
		return { data: null, error: { accessLookupFailed: true } };
	}
}

async function readStartPartnerFoxIdentity(
	supabase: SupabaseClient<Database>,
	expectation: PartnerFoxChatStartExpectation,
): Promise<QueryResult> {
	try {
		return await supabase
			.from("matches")
			.select(START_PARTNER_FOX_IDENTITY_SELECT)
			.eq("id", expectation.matchId)
			.single() as unknown as QueryResult;
	} catch {
		return { data: null, error: { accessLookupFailed: true } };
	}
}

function validateBlockRows(
	value: unknown,
	blockerId: string,
	blockedId: string,
): { ok: true; blocked: boolean } | { ok: false } {
	if (!Array.isArray(value)) return { ok: false };
	for (const row of value) {
		if (
			!isRecord(row) ||
			!isNonEmptyId(row.id) ||
			row.blocker_id !== blockerId ||
			row.blocked_id !== blockedId
		) {
			return { ok: false };
		}
	}
	return { ok: true, blocked: value.length > 0 };
}

function validateConversation(value: unknown, matchId: string): boolean {
	if (!Array.isArray(value) || value.length !== 1) return false;
	const conversation = value[0];
	return (
		isRecord(conversation) &&
		isNonEmptyId(conversation.id) &&
		conversation.match_id === matchId &&
		conversation.purpose === "compatibility" &&
		conversation.status === "completed"
	);
}

type ValidatedMatch = {
	row: Record<string, unknown>;
	status: PartnerFoxMatchStatus;
	userAId: string;
	userBId: string;
	profileA: Record<string, unknown>;
	profileB: Record<string, unknown>;
};

function validateMatch(
	value: unknown,
	expectation: { matchId: string; userId: string; partnerUserId: string },
): ValidatedMatch | PartnerFoxChatAccessFailure {
	if (!isRecord(value)) return "error";
	if (
		value.id !== expectation.matchId ||
		!isNonEmptyId(value.user_a_id) ||
		!isNonEmptyId(value.user_b_id) ||
		typeof value.status !== "string"
	) {
		return "forbidden";
	}
	if (value.user_a_id >= value.user_b_id) return "forbidden";
	const expectedUsers = [expectation.userId, expectation.partnerUserId].sort();
	if (value.user_a_id !== expectedUsers[0] || value.user_b_id !== expectedUsers[1]) return "forbidden";
	if (!isKnownContactStatus(value.status)) return "forbidden";
	if (!isRecord(value.profile_a) || !isRecord(value.profile_b)) return "error";
	if (value.profile_a.id !== value.user_a_id || value.profile_b.id !== value.user_b_id) return "forbidden";
	return {
		row: value,
		status: value.status,
		userAId: value.user_a_id,
		userBId: value.user_b_id,
		profileA: value.profile_a,
		profileB: value.profile_b,
	};
}

function validateRoom(value: unknown, matchId: string, matchStatus: string): PartnerFoxChatAccessFailure | null {
	if (value === null) {
		return PARTNER_FOX_ACTIVE_ROOM_STATUSES.has(matchStatus) ? "forbidden" : null;
	}
	if (!isRecord(value) || !isNonEmptyId(value.id) || value.match_id !== matchId || typeof value.status !== "string") {
		return "error";
	}
	if (value.status !== "active" && value.status !== "closed") return "error";
	if (value.status === "closed") return "forbidden";
	if (PARTNER_FOX_ACTIVE_ROOM_STATUSES.has(matchStatus) && value.status !== "active") return "forbidden";
	return null;
}

function verifyProfilesAndBlocks(
	match: ValidatedMatch,
	userId: string,
	partnerUserId: string,
): PartnerFoxChatAccessFailure | null {
	if (!isNonEmptyId(userId) || !isNonEmptyId(partnerUserId) || userId === partnerUserId) return "forbidden";
	if (
		(match.userAId !== userId && match.userBId !== userId) ||
		(match.userAId !== partnerUserId && match.userBId !== partnerUserId)
	) return "forbidden";
	const profileABlocks = validateBlockRows(match.profileA.blocks_sent, match.userAId, match.userBId);
	const profileBBlocks = validateBlockRows(match.profileB.blocks_sent, match.userBId, match.userAId);
	if (!profileABlocks.ok || !profileBBlocks.ok) return "error";
	if (profileABlocks.blocked || profileBBlocks.blocked) return "forbidden";
	// Reuse the same pure predicate as checkVerifiedPair against this snapshot;
	// a second await would create a stale gap between eligibility and block state.
	if (!areMutuallyEligible(match.profileA, match.profileB)) return "forbidden";
	return null;
}

/**
 * Revalidates one exact partner-Fox chat and its current contact state.
 * Every caller supplies immutable IDs captured from the route's first read;
 * a reassigned chat, match, owner, or partner therefore fails closed.
 */
export async function checkPartnerFoxChatAccess(
	supabase: SupabaseClient<Database>,
	expectation: PartnerFoxChatAccessExpectation,
): Promise<PartnerFoxChatAccessResult> {
	if (!validExpectation(expectation)) return { ok: false, reason: "forbidden" };
	const result = await readCurrentPartnerFoxRow(supabase, expectation);
	if (result.error) return { ok: false, reason: missingOrFailed(result.error) };
	if (!isRecord(result.data)) return { ok: false, reason: "error" };
	if (
		result.data.id !== expectation.chatId ||
		result.data.match_id !== expectation.matchId ||
		result.data.user_id !== expectation.userId ||
		result.data.partner_user_id !== expectation.partnerUserId
	) {
		return { ok: false, reason: "forbidden" };
	}

	const match = validateMatch(result.data.match, expectation);
	if (typeof match === "string") return { ok: false, reason: match };
	if (!validateConversation(match.row.fox_conversation, expectation.matchId)) return { ok: false, reason: "forbidden" };
	const roomFailure = validateRoom(match.row.direct_room, expectation.matchId, match.status);
	if (roomFailure) return { ok: false, reason: roomFailure };
	const pairFailure = verifyProfilesAndBlocks(match, expectation.userId, expectation.partnerUserId);
	if (pairFailure) return { ok: false, reason: pairFailure };

	return { ok: true, matchStatus: match.status, partnerUserId: expectation.partnerUserId };
}

/**
 * Validates the initial POST state before a partner chat row exists. A chat may
 * be started from any allowed contact state; only the completed Fox state is
 * eligible for the one-way match CAS performed by the route.
 */
export async function checkPartnerFoxChatStartAccess(
	supabase: SupabaseClient<Database>,
	expectation: PartnerFoxChatStartExpectation,
): Promise<PartnerFoxChatStartResult> {
	if (!validStartExpectation(expectation)) return { ok: false, reason: "forbidden" };
	const identityResult = await readStartPartnerFoxIdentity(supabase, expectation);
	if (identityResult.error) {
		const reason = missingOrFailed(identityResult.error);
		return { ok: false, reason: reason === "not_found" ? "not_ready" : reason };
	}
	if (!isRecord(identityResult.data)) return { ok: false, reason: "error" };
	if (
		identityResult.data.id !== expectation.matchId ||
		!isNonEmptyId(identityResult.data.user_a_id) ||
		!isNonEmptyId(identityResult.data.user_b_id) ||
		identityResult.data.user_a_id >= identityResult.data.user_b_id
	) return { ok: false, reason: "forbidden" };
	if (identityResult.data.user_a_id !== expectation.userId && identityResult.data.user_b_id !== expectation.userId) {
		return { ok: false, reason: "forbidden" };
	}
	const userAId = identityResult.data.user_a_id;
	const userBId = identityResult.data.user_b_id;
	const partnerUserId = userAId === expectation.userId ? userBId : userAId;

	const result = await readStartPartnerFoxRow(supabase, expectation, userAId, userBId);
	if (result.error) {
		const reason = missingOrFailed(result.error);
		return { ok: false, reason: reason === "not_found" ? "not_ready" : reason };
	}
	const match = validateMatch(result.data, {
		matchId: expectation.matchId,
		userId: expectation.userId,
		partnerUserId,
	});
	if (typeof match === "string") return { ok: false, reason: match === "error" ? "error" : "forbidden" };
	if (!isKnownContactStatus(match.status)) return { ok: false, reason: "forbidden" };
	if (match.status !== identityResult.data.status) return { ok: false, reason: "forbidden" };
	if (!validateConversation(match.row.fox_conversation, expectation.matchId)) return { ok: false, reason: "not_ready" };
	const roomFailure = validateRoom(match.row.direct_room, expectation.matchId, match.status);
	if (roomFailure) return { ok: false, reason: roomFailure };

	const pairFailure = verifyProfilesAndBlocks(match, expectation.userId, partnerUserId);
	if (pairFailure) return { ok: false, reason: pairFailure };

	return {
		ok: true,
		matchStatus: match.status,
		userAId: match.userAId,
		userBId: match.userBId,
		partnerUserId,
	};
}
