/**
 * Shared "is this user a participant in this fox conversation" check.
 *
 * Single implementation of the conversation -> match -> participant chain,
 * used by both `GET /api/fox-search/status/:conversationId` and the
 * WebSocket edge handshake (`GET /api/fox-search/ws/:conversationId`). See
 * docs/spec/impl/step-03-lazy-generation.md §4-C-3(1): the two call sites
 * previously duplicated this logic (fox-search.ts:73-88), and the WS route
 * had no participant check at all (gap G2).
 *
 * Fail-closed: the current-access gate checks the single embedding query's
 * `{ error }` result explicitly and validates every nested relationship rather
 * than trusting the generated database types. The participant helper below
 * retains its separate lookup contract. Callers never see which internal
 * relationship failed, so error responses built from this result carry no
 * internal state (§5).
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { checkVerifiedPair } from "./match-age-access";
import { MATCHING_ELIGIBILITY_COLUMNS, areMutuallyEligible } from "./matching-eligibility";
import {
	isFoxConversationGenerationAllowed,
	type FoxConversationRecordingWindow,
} from "./fox-conversation-recording-window";

/**
 * A current conversation can be used for generation only while both sides
 * are still in the active state. Completed output has its own state pair so a
 * terminal row cannot be treated as an active work item after a preference,
 * age, block, or status change.
 */
export const FOX_ACTIVE_CONVERSATION_STATUSES = ["pending", "in_progress"] as const;
export const FOX_COMPLETED_CONVERSATION_STATUSES = ["completed"] as const;
export const FOX_ACTIVE_MATCH_STATUSES = ["fox_conversation_in_progress"] as const;
export const FOX_COMPLETED_MATCH_STATUSES = ["fox_conversation_completed"] as const;
export const FOX_PUBLIC_COMPLETED_MATCH_STATUSES = [
	"fox_conversation_completed",
	"partner_chat_started",
	"direct_chat_requested",
	"direct_chat_active",
	"chat_request_expired",
	"chat_request_declined",
] as const;

export type FoxConversationAccessMode = "active" | "completed" | "terminal" | "public_read";

export type FoxConversationAccessExpectation = {
	conversationId: string;
	matchId: string;
	userA: string;
	userB: string;
	/** Required only by the public-read mode; existing generation callers omit it. */
	viewerId?: string;
	/** Derived from server bindings and database participants; never client input or DO storage. */
	generationWindow?: FoxConversationRecordingWindow;
};

export type FoxConversationPublicAccessExpectation = FoxConversationAccessExpectation & {
	viewerId: string;
};

export type FoxConversationPublicDetail = {
	id: string;
	match_id: string;
	status: string;
	total_rounds: number;
	current_round: number;
	started_at: string | null;
	completed_at: string | null;
};

export type FoxConversationCurrentAccessResult =
	| {
			ok: true;
			conversationStatus: string;
			matchStatus: string;
			matchId: string;
			userA: string;
			userB: string;
			purpose?: string;
			publicDetail?: FoxConversationPublicDetail;
		}
	| { ok: false; reason: "not_found" | "forbidden" | "error" };

export type FoxConversationPublicAccessResult =
	| ({
			ok: true;
			expectation: FoxConversationPublicAccessExpectation;
			conversationStatus: string;
			matchStatus: string;
			matchId: string;
			userA: string;
			userB: string;
			purpose: "compatibility";
			publicDetail: FoxConversationPublicDetail;
		} & { viewerId: string })
	| { ok: false; reason: "not_found" | "forbidden" | "error" };

/** Generic internal error used when a current-output gate rejects a run. */
export class FoxConversationAccessError extends Error {
	constructor() {
		super("Current conversation access is no longer available");
		this.name = "FoxConversationAccessError";
	}
}

export function isFoxConversationAccessError(error: unknown): error is FoxConversationAccessError {
	return error instanceof FoxConversationAccessError;
}

function isAllowedStatus(mode: FoxConversationAccessMode, conversationStatus: unknown, matchStatus: unknown): boolean {
	if (mode === "active") {
		return (
			(typeof conversationStatus === "string" && (FOX_ACTIVE_CONVERSATION_STATUSES as readonly string[]).includes(conversationStatus)) &&
			(typeof matchStatus === "string" && (FOX_ACTIVE_MATCH_STATUSES as readonly string[]).includes(matchStatus))
		);
	}
	if (mode === "completed") {
		return (
			(typeof conversationStatus === "string" && (FOX_COMPLETED_CONVERSATION_STATUSES as readonly string[]).includes(conversationStatus)) &&
			(typeof matchStatus === "string" && (FOX_COMPLETED_MATCH_STATUSES as readonly string[]).includes(matchStatus))
		);
	}
	if (mode === "public_read") {
		if (typeof conversationStatus !== "string" || typeof matchStatus !== "string") return false;
		return (
			(FOX_ACTIVE_CONVERSATION_STATUSES as readonly string[]).includes(conversationStatus) && matchStatus === "fox_conversation_in_progress" ||
			conversationStatus === "failed" && matchStatus === "fox_conversation_failed" ||
			(FOX_COMPLETED_CONVERSATION_STATUSES as readonly string[]).includes(conversationStatus) &&
				(FOX_PUBLIC_COMPLETED_MATCH_STATUSES as readonly string[]).includes(matchStatus)
		);
	}
	if (mode !== "terminal") return false;
	// The engine writes the match terminal status first and the conversation
	// terminal status second. This narrow transition mode is not used for
	// public reads or new work; it only lets the second terminal write be
	// guarded without accepting terminal rows as active work.
	return (
		(typeof conversationStatus === "string" && ("in_progress" === conversationStatus || "completed" === conversationStatus)) &&
		(typeof matchStatus === "string" && (FOX_COMPLETED_MATCH_STATUSES as readonly string[]).includes(matchStatus))
	);
}

// PostgREST v14 resource embedding supports the explicit FK hints, aliases,
// and nested filters used here: https://docs.postgrest.org/en/v14/references/api/resource_embedding.html
const CURRENT_ACCESS_SELECT = [
	"id",
	"match_id",
	"status",
	`match:matches!fox_conversations_match_id_fkey!inner(id,user_a_id,user_b_id,status,profile_a:user_profiles!matches_user_a_id_fkey!inner(${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)),profile_b:user_profiles!matches_user_b_id_fkey!inner(${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)))`,
].join(",");

const PUBLIC_CURRENT_ACCESS_SELECT = [
	"id",
	"match_id",
	"status",
	"purpose",
	"total_rounds",
	"current_round",
	"started_at",
	"completed_at",
	`match:matches!fox_conversations_match_id_fkey!inner(id,user_a_id,user_b_id,status,profile_a:user_profiles!matches_user_a_id_fkey!inner(${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)),profile_b:user_profiles!matches_user_b_id_fkey!inner(${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)))`,
].join(",");

// The first public read discovers only the immutable tuple and the closed
// detail fields. Eligibility and block rows are read by the filtered current
// access gate below, so unrelated block rows cannot consume that query.
const PUBLIC_IDENTITY_SELECT = [
	"id",
	"match_id",
	"status",
	"purpose",
	"total_rounds",
	"current_round",
	"started_at",
	"completed_at",
	"match:matches!fox_conversations_match_id_fkey!inner(id,user_a_id,user_b_id,status)",
].join(",");

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isKnownAccessMode(value: unknown): value is FoxConversationAccessMode {
	return value === "active" || value === "completed" || value === "terminal" || value === "public_read";
}

function isNonEmptyString(value: unknown): value is string {
	return typeof value === "string" && value.trim().length > 0;
}

function isPublicTimestamp(value: unknown): value is string | null {
	return value === null || isNonEmptyString(value);
}

function parsePublicDetail(value: Record<string, unknown>): FoxConversationPublicDetail | null {
	const totalRounds = value.total_rounds;
	const currentRound = value.current_round;
	if (
		!isNonEmptyString(value.id) ||
		!isNonEmptyString(value.match_id) ||
		!isNonEmptyString(value.status) ||
		!Number.isInteger(totalRounds) ||
		(totalRounds as number) < 0 ||
		!Number.isInteger(currentRound) ||
		(currentRound as number) < 0 ||
		(Number.isInteger(totalRounds) && Number.isInteger(currentRound) && (currentRound as number) > (totalRounds as number)) ||
		!isPublicTimestamp(value.started_at) ||
		!isPublicTimestamp(value.completed_at)
	) {
		return null;
	}
	return {
		id: value.id,
		match_id: value.match_id,
		status: value.status,
		total_rounds: totalRounds as number,
		current_round: currentRound as number,
		started_at: value.started_at,
		completed_at: value.completed_at,
	};
}

function isValidExpectedAccess(expected: FoxConversationAccessExpectation, mode: FoxConversationAccessMode): boolean {
	if (
		!isNonEmptyString(expected.conversationId) ||
		!isNonEmptyString(expected.matchId) ||
		!isNonEmptyString(expected.userA) ||
		!isNonEmptyString(expected.userB) ||
		expected.userA === expected.userB
	) {
		return false;
	}
	if (mode === "public_read") {
		return isNonEmptyString(expected.viewerId) && (expected.viewerId === expected.userA || expected.viewerId === expected.userB);
	}
	return true;
}

function validateEmbeddedBlockArray(
	value: unknown,
	blockerId: string,
	blockedId: string,
): { ok: true; rows: Record<string, unknown>[] } | { ok: false } {
	if (!Array.isArray(value)) return { ok: false };
	const rows: Record<string, unknown>[] = [];
	for (const row of value) {
		if (
			!isRecord(row) ||
			typeof row.id !== "string" ||
			row.id.length === 0 ||
			row.blocker_id !== blockerId ||
			row.blocked_id !== blockedId
		) {
			return { ok: false };
		}
		rows.push(row);
	}
	return { ok: true, rows };
}

function validateCurrentAccessRow(
	value: unknown,
	expected: FoxConversationAccessExpectation,
	mode: FoxConversationAccessMode,
): FoxConversationCurrentAccessResult {
	if (!isValidExpectedAccess(expected, mode)) return { ok: false, reason: "forbidden" };
	if (!isRecord(value)) return { ok: false, reason: "error" };
	const conversation = value;
	if (
		conversation.id !== expected.conversationId ||
		conversation.match_id !== expected.matchId ||
		!isNonEmptyString(conversation.status)
	) {
		return { ok: false, reason: "forbidden" };
	}
	if (mode === "public_read" && conversation.purpose !== "compatibility") {
		return { ok: false, reason: "forbidden" };
	}
	if (!isRecord(conversation.match)) return { ok: false, reason: "error" };
	const match = conversation.match;
	if (
		match.id !== expected.matchId ||
		!isNonEmptyString(match.user_a_id) ||
		!isNonEmptyString(match.user_b_id) ||
		match.user_a_id !== expected.userA ||
		match.user_b_id !== expected.userB ||
		!isNonEmptyString(match.status)
	) {
		return { ok: false, reason: "forbidden" };
	}
	if (!isAllowedStatus(mode, conversation.status, match.status)) return { ok: false, reason: "forbidden" };

	if (!isRecord(match.profile_a) || !isRecord(match.profile_b)) return { ok: false, reason: "error" };
	const profileA = match.profile_a;
	const profileB = match.profile_b;
	if (profileA.id !== expected.userA || profileB.id !== expected.userB) return { ok: false, reason: "forbidden" };
	if (!areMutuallyEligible(profileA, profileB)) return { ok: false, reason: "forbidden" };
	const profileABlocks = validateEmbeddedBlockArray((profileA as Record<string, unknown>).blocks_sent, expected.userA, expected.userB);
	const profileBBlocks = validateEmbeddedBlockArray((profileB as Record<string, unknown>).blocks_sent, expected.userB, expected.userA);
	if (!profileABlocks.ok || !profileBBlocks.ok) return { ok: false, reason: "error" };
	if (profileABlocks.rows.length > 0 || profileBBlocks.rows.length > 0) return { ok: false, reason: "forbidden" };

	if (mode !== "public_read") {
		return {
			ok: true,
			conversationStatus: conversation.status,
			matchStatus: match.status,
			matchId: match.id,
			userA: match.user_a_id,
			userB: match.user_b_id,
		};
	}
	const publicDetail = parsePublicDetail(conversation);
	if (!publicDetail || publicDetail.id !== expected.conversationId || publicDetail.match_id !== expected.matchId) {
		return { ok: false, reason: "error" };
	}
	return {
		ok: true,
		conversationStatus: conversation.status,
		matchStatus: match.status,
		matchId: match.id,
		userA: match.user_a_id,
		userB: match.user_b_id,
		purpose: "compatibility",
		publicDetail,
	};
}

type PublicInitialIdentity = {
	ok: true;
	expectation: FoxConversationPublicAccessExpectation;
	conversationStatus: string;
	matchStatus: string;
	publicDetail: FoxConversationPublicDetail;
};

function mapInitialPublicIdentity(
	value: unknown,
	conversationId: string,
	viewerId: string,
): PublicInitialIdentity | { ok: false; reason: "forbidden" | "error" } {
	if (!isRecord(value)) return { ok: false, reason: "error" };
	if (value.id !== conversationId || !isNonEmptyString(value.match_id) || !isRecord(value.match)) {
		return { ok: false, reason: "forbidden" };
	}
	const publicDetail = parsePublicDetail(value);
	if (!publicDetail || publicDetail.id !== conversationId || publicDetail.match_id !== value.match_id) {
		return { ok: false, reason: "error" };
	}
	if (!isNonEmptyString(value.status)) return { ok: false, reason: "forbidden" };
	if (value.purpose !== "compatibility") return { ok: false, reason: "forbidden" };
	const match = value.match;
	if (
		match.id !== value.match_id ||
		!isNonEmptyString(match.user_a_id) ||
		!isNonEmptyString(match.user_b_id) ||
		match.user_a_id === match.user_b_id ||
		!isNonEmptyString(match.status)
	) {
		return { ok: false, reason: "forbidden" };
	}
	const expectation: FoxConversationPublicAccessExpectation = {
		conversationId,
		matchId: value.match_id,
		userA: match.user_a_id,
		userB: match.user_b_id,
		viewerId,
	};
	if (!isValidExpectedAccess(expectation, "public_read")) return { ok: false, reason: "forbidden" };
	if (!isAllowedStatus("public_read", value.status, match.status)) return { ok: false, reason: "forbidden" };
	return {
		ok: true,
		expectation,
		conversationStatus: value.status,
		matchStatus: match.status,
		publicDetail,
	};
}

/**
 * Performs the first public-read lookup and binds the result to the exact
 * ordered participant tuple and authenticated viewer. The later gate uses the
 * returned expectation so a route cannot rediscover participants after an
 * awaited payload query.
 */
export async function readFoxConversationPublicAccess(
	supabase: SupabaseClient<Database>,
	conversationId: string,
	viewerId: string,
): Promise<FoxConversationPublicAccessResult> {
	if (!isNonEmptyString(conversationId) || !isNonEmptyString(viewerId)) return { ok: false, reason: "forbidden" };
	let result: { data: unknown; error: unknown };
	try {
		result = await supabase
			.from("fox_conversations")
			.select(PUBLIC_IDENTITY_SELECT)
			.eq("id", conversationId)
			.single() as unknown as { data: unknown; error: unknown };
	} catch {
		return { ok: false, reason: "error" };
	}
	if (result.error) {
		if (isRecord(result.error) && result.error.code === "PGRST116") return { ok: false, reason: "not_found" };
		return { ok: false, reason: "error" };
	}
	if (result.data === null || result.data === undefined) return { ok: false, reason: "not_found" };
	const identity = mapInitialPublicIdentity(result.data, conversationId, viewerId);
	if (identity.ok === false) return { ok: false, reason: identity.reason };
	let gate: FoxConversationCurrentAccessResult;
	try {
		gate = await checkFoxConversationCurrentAccess(supabase, identity.expectation, "public_read");
	} catch {
		return { ok: false, reason: "error" };
	}
	if (gate.ok === false) return { ok: false, reason: gate.reason };
	if (
		gate.conversationStatus !== identity.conversationStatus ||
		gate.matchStatus !== identity.matchStatus ||
		gate.purpose !== "compatibility" ||
		gate.matchId !== identity.expectation.matchId ||
		gate.userA !== identity.expectation.userA ||
		gate.userB !== identity.expectation.userB
	) {
		return { ok: false, reason: "forbidden" };
	}
	return {
		ok: true,
		expectation: identity.expectation,
		conversationStatus: identity.conversationStatus,
		matchStatus: identity.matchStatus,
		matchId: identity.expectation.matchId,
		userA: identity.expectation.userA,
		userB: identity.expectation.userB,
		purpose: "compatibility",
		publicDetail: identity.publicDetail,
		viewerId,
	};
}

/**
 * Re-reads the conversation, match, current mutual eligibility, and both
 * block directions for one exact expected state. This is intentionally a
 * separate helper from the public participant check: active generation and
 * completed output have different valid status pairs, while the participant
 * helper's `{ ok, matchId }` contract remains stable for existing routes.
 */
export async function checkFoxConversationCurrentAccess(
	supabase: SupabaseClient<Database>,
	expected: FoxConversationAccessExpectation,
	mode: FoxConversationAccessMode,
): Promise<FoxConversationCurrentAccessResult> {
	if (!isKnownAccessMode(mode) || !isValidExpectedAccess(expected, mode)) return { ok: false, reason: "forbidden" };
	const recordingWindowMustBeActive = mode === "active"
		|| (mode === "terminal" && expected.generationWindow !== undefined && expected.generationWindow.kind !== "absent");
	if (recordingWindowMustBeActive
		&& !isFoxConversationGenerationAllowed(expected.generationWindow, expected.userA, expected.userB)) {
		return { ok: false, reason: "forbidden" };
	}

	let result: { data: unknown; error: unknown };
	try {
			let query = supabase
				.from("fox_conversations")
				.select(mode === "public_read" ? PUBLIC_CURRENT_ACCESS_SELECT : CURRENT_ACCESS_SELECT)
			.eq("id", expected.conversationId)
			.eq("match_id", expected.matchId)
			.eq("match.profile_a.blocks_sent.blocked_id", expected.userB)
			.eq("match.profile_b.blocks_sent.blocked_id", expected.userA);
		if (mode === "public_read") query = query.eq("purpose", "compatibility");
		result = await query.single() as unknown as { data: unknown; error: unknown };
	} catch {
		return { ok: false, reason: "error" };
	}
	if (result.error) {
		if (isRecord(result.error) && result.error.code === "PGRST116") return { ok: false, reason: "not_found" };
		return { ok: false, reason: "error" };
	}
	if (result.data === null || result.data === undefined) return { ok: false, reason: "not_found" };

	const access = validateCurrentAccessRow(result.data, expected, mode);
	if (!access.ok) return access;
	// The database read above is an await boundary. A recording rehearsal may
	// expire while it is in flight, so recheck the server-derived permit before
	// returning authorization to a caller that is about to spend or write.
	if (recordingWindowMustBeActive
		&& !isFoxConversationGenerationAllowed(expected.generationWindow, expected.userA, expected.userB)) {
		return { ok: false, reason: "forbidden" };
	}
	return access;
}

/** Alias kept for callers that phrase the gate as a current-access check. */
export const checkCurrentFoxConversationAccess = checkFoxConversationCurrentAccess;

export type ParticipantCheckResult =
	| { ok: true; matchId: string }
	| { ok: false; reason: "not_found" | "forbidden" };

export async function checkFoxConversationParticipant(
	supabase: SupabaseClient<Database>,
	conversationId: string,
	userId: string,
): Promise<ParticipantCheckResult> {
	const { data: conv, error: convError } = await supabase
		.from("fox_conversations")
		.select("id, match_id")
		.eq("id", conversationId)
		.single();
	if (convError || !conv) {
		return { ok: false, reason: "not_found" };
	}

	const { data: match, error: matchError } = await supabase
		.from("matches")
		.select("user_a_id, user_b_id")
		.eq("id", conv.match_id)
		.single();
	if (matchError || !match) {
		// The conversation row exists but its match can't be read (deleted,
		// transient DB error, ...). Fail closed: treat as not found rather
		// than granting access or leaking which query failed.
		return { ok: false, reason: "not_found" };
	}

	if (match.user_a_id !== userId && match.user_b_id !== userId) {
		return { ok: false, reason: "forbidden" };
	}

	const pair = await checkVerifiedPair(supabase, match.user_a_id, match.user_b_id);
	if (pair.ok === false) {
		// Do not disclose whether the counterpart is missing, unverified, or the
		// age lookup failed.  All are a stable denial for this contact path.
		return { ok: false, reason: "forbidden" };
	}

	return { ok: true, matchId: conv.match_id };
}
