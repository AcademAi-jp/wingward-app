import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { MATCHING_ELIGIBILITY_COLUMNS, areMutuallyEligible } from "./matching-eligibility";

/**
 * Internal, owner-readable context persisted with a notification.  These ids
 * are delivery bindings only; they are never copied into the provider data.
 */
export type NotificationDeliveryContext =
	| { conversation_id: string }
	| { request_id: string }
	| { proposal_id: string };

export type NotificationDeliveryExpectation = {
	notificationId: string;
	scenarioId: string;
	userId: string;
	matchId?: string | null;
	meetupId?: string | null;
	deepLink: string;
	deliveryContext?: NotificationDeliveryContext | null;
	/** The ordered participants read before this final snapshot. */
	participantIds?: readonly [string, string];
	/** The claim value, when a deferred row is being delivered. */
	fencingToken?: string;
	now: Date;
	/** Sampled only after the final embedded read resolves. */
	clock?: () => Date;
};

export type NotificationDeliveryAccessFailure = "not_found" | "forbidden" | "error";

export type NotificationDeliveryAccessResult =
	| { ok: true }
	| { ok: false; reason: NotificationDeliveryAccessFailure };

type QueryResult = { data: unknown; error: unknown };
type NotificationDeliveryContextKey = "conversation_id" | "request_id" | "proposal_id";

const PARTNER_FOX_MATCH_STATUSES = new Set([
	"fox_conversation_completed",
	"partner_chat_started",
	"direct_chat_requested",
	"direct_chat_active",
	"meetup_intent",
	"meetup_confirmed",
]);

const ACTIVE_ROOM_REQUIRED_STATUSES = new Set(["direct_chat_active", "meetup_intent", "meetup_confirmed"]);

const WIRED_SCENARIOS = new Set(["N-01", "N-03", "N-04", "N-05", "N-06", "N-07", "N-14", "N-13"]);

export function isWiredNotificationScenario(scenarioId: string): boolean {
	return WIRED_SCENARIOS.has(scenarioId);
}

const FINAL_NOTIFICATION_SELECT = [
	"id,scenario_id,user_id,match_id,meetup_id,payload,scheduled_for,sent_at,suppressed_reason,onesignal_notification_id",
	"scenario:notification_scenarios!notifications_scenario_id_fkey!inner(scenario_id,is_enabled)",
	`match:matches!notifications_match_id_fkey(id,user_a_id,user_b_id,status,profile_a:user_profiles!matches_user_a_id_fkey!inner(${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)),profile_b:user_profiles!matches_user_b_id_fkey!inner(${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)),compatibility_conversations:fox_conversations!fox_conversations_match_id_fkey(id,match_id,purpose,status),chat_requests:chat_requests!chat_requests_match_id_fkey(id,match_id,requester_id,responder_id,status,expires_at),direct_room:direct_chat_rooms!direct_chat_rooms_match_id_fkey(id,match_id,status))`,
	`meetup:meetups!notifications_meetup_id_fkey(id,match_id,initiator_id,status,proposal_expires_at,proposals:meetup_proposals!meetup_proposals_meetup_id_fkey(id,meetup_id,attempt_number,expires_at))`,
].join(",");

const MATCH_IDENTITY_SELECT = "id,user_a_id,user_b_id";

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyId(value: unknown): value is string {
	return typeof value === "string" && value.trim().length > 0;
}

function isExactContext(value: unknown, key: NotificationDeliveryContextKey): boolean {
	if (!isRecord(value)) return false;
	const keys = Object.keys(value);
	return keys.length === 1 && keys[0] === key && isNonEmptyId(value[key]);
}

export function parseNotificationDeliveryContext(value: unknown): NotificationDeliveryContext | null {
	if (isExactContext(value, "conversation_id")) return { conversation_id: (value as Record<string, string>).conversation_id };
	if (isExactContext(value, "request_id")) return { request_id: (value as Record<string, string>).request_id };
	if (isExactContext(value, "proposal_id")) return { proposal_id: (value as Record<string, string>).proposal_id };
	return null;
}

export function isNotificationDeliveryContextForScenario(
	scenarioId: string,
	matchId: string | null | undefined,
	meetupId: string | null | undefined,
	context: NotificationDeliveryContext | null | undefined,
): boolean {
	const hasMatch = isNonEmptyId(matchId);
	const hasMeetup = isNonEmptyId(meetupId);
	if (scenarioId === "N-13") return !hasMatch && !hasMeetup && context == null;
	if (scenarioId === "N-01" || scenarioId === "N-03") {
		if (!hasMatch || hasMeetup) return false;
		if (scenarioId === "N-01") return context != null && "conversation_id" in context;
		return context != null && "request_id" in context;
	}
	if (scenarioId === "N-04" || scenarioId === "N-05" || scenarioId === "N-06" || scenarioId === "N-07" || scenarioId === "N-14") {
		if (!hasMatch || !hasMeetup) return false;
		return scenarioId === "N-05" ? context != null && "proposal_id" in context : context == null;
	}
	return true;
}

function missingOrFailed(error: unknown): NotificationDeliveryAccessFailure {
	return isRecord(error) && error.code === "PGRST116" ? "not_found" : "error";
}

function asRows(value: unknown): Record<string, unknown>[] | null {
	if (!Array.isArray(value)) return null;
	return value.every(isRecord) ? value : null;
}

function exactlyOne(value: unknown): Record<string, unknown> | null {
	if (Array.isArray(value)) return value.length === 1 && isRecord(value[0]) ? value[0] : null;
	return isRecord(value) ? value : null;
}

function sameParticipants(value: unknown, participantIds: readonly [string, string]): boolean {
	return isNonEmptyId(value) && (value === participantIds[0] || value === participantIds[1]);
}

function validateBlockRows(value: unknown, expectedBlocker: string, expectedBlocked: string): boolean {
	const rows = asRows(value);
	if (!rows) return false;
	return rows.every((row) => isNonEmptyId(row.id) && row.blocker_id === expectedBlocker && row.blocked_id === expectedBlocked);
}

function validateProfile(value: unknown, expectedId: string): value is Record<string, unknown> {
	return isRecord(value) && value.id === expectedId;
}

function validateProfilesAndBlocks(match: Record<string, unknown>, participantIds: readonly [string, string]): boolean {
	if (!validateProfile(match.profile_a, match.user_a_id as string) || !validateProfile(match.profile_b, match.user_b_id as string)) return false;
	const profileA = match.profile_a as Record<string, unknown>;
	const profileB = match.profile_b as Record<string, unknown>;
	if (!validateBlockRows(profileA.blocks_sent, participantIds[0], participantIds[1])) return false;
	if (!validateBlockRows(profileB.blocks_sent, participantIds[1], participantIds[0])) return false;
	if ((profileA.blocks_sent as unknown[]).length > 0 || (profileB.blocks_sent as unknown[]).length > 0) return false;
	return areMutuallyEligible(profileA, profileB);
}

function validateRoom(value: unknown, matchId: string, matchStatus: string): boolean {
	if (value === null) return !ACTIVE_ROOM_REQUIRED_STATUSES.has(matchStatus);
	if (Array.isArray(value)) {
		if (value.length === 0) return !ACTIVE_ROOM_REQUIRED_STATUSES.has(matchStatus);
		if (value.length !== 1 || !isRecord(value[0])) return false;
		value = value[0];
	}
	if (!isRecord(value) || !isNonEmptyId(value.id) || value.match_id !== matchId) return false;
	if (value.status === "closed") return false;
	if (value.status !== "active") return false;
	return ACTIVE_ROOM_REQUIRED_STATUSES.has(matchStatus);
}

function isValidExpiry(value: unknown, nowMs: number): boolean {
	if (value == null) return true;
	if (typeof value !== "string") return false;
	const parsed = Date.parse(value);
	return Number.isFinite(parsed) && parsed > nowMs;
}

function validateCompatibilityConversation(value: unknown, matchId: string, context: NotificationDeliveryContext): boolean {
	if (!("conversation_id" in context)) return false;
	const rows = asRows(value);
	if (!rows || rows.length !== 1) return false;
	const conversation = rows[0];
	return conversation.id === context.conversation_id && conversation.match_id === matchId && conversation.purpose === "compatibility" && conversation.status === "completed";
}

function validateChatRequest(value: unknown, matchId: string, userId: string, participantIds: readonly [string, string], context: NotificationDeliveryContext, nowMs: number): boolean {
	if (!("request_id" in context)) return false;
	const request = exactlyOne(value);
	if (!request) return false;
	if (
		request.id !== context.request_id ||
		request.match_id !== matchId ||
		request.status !== "pending" ||
		request.responder_id !== userId ||
		!sameParticipants(request.requester_id, participantIds) ||
		request.requester_id === request.responder_id
	) {
		return false;
	}
	return request.requester_id !== userId && isValidExpiry(request.expires_at, nowMs) && Number.isFinite(Date.parse(String(request.expires_at)));
}

function validateMeetupProposal(value: unknown, meetupId: string, context: NotificationDeliveryContext, nowMs: number): boolean {
	if (!("proposal_id" in context)) return false;
	const proposals = asRows(value);
	if (!proposals || proposals.length === 0) return false;
	const latest = proposals[0];
	if (
		latest.id !== context.proposal_id ||
		latest.meetup_id !== meetupId ||
		!Number.isInteger(latest.attempt_number) ||
		(latest.attempt_number as number) < 1 ||
		!isValidExpiry(latest.expires_at, nowMs)
	) {
		return false;
	}
	return proposals.every(
		(proposal, index) =>
			Number.isInteger(proposal.attempt_number) &&
			(proposal.attempt_number as number) >= 1 &&
			(index === 0 || (proposal.attempt_number as number) <= (latest.attempt_number as number)),
	);
}

function validateScenarioRow(value: unknown, scenarioId: string): boolean {
	const scenario = exactlyOne(value);
	return !!scenario && scenario.scenario_id === scenarioId && scenario.is_enabled === true;
}

function validateMatchCommon(match: Record<string, unknown>, expectation: NotificationDeliveryExpectation, participantIds: readonly [string, string]): boolean {
	if (
		match.id !== expectation.matchId ||
		match.user_a_id !== participantIds[0] ||
		match.user_b_id !== participantIds[1] ||
		!isNonEmptyId(match.user_a_id) ||
		!isNonEmptyId(match.user_b_id) ||
		participantIds[0] >= participantIds[1]
	) {
		return false;
	}
	return validateProfilesAndBlocks(match, participantIds);
}

function validateMatchScenario(match: Record<string, unknown>, expectation: NotificationDeliveryExpectation, participantIds: readonly [string, string]): boolean {
	if (!validateMatchCommon(match, expectation, participantIds) || typeof match.status !== "string") return false;
	const status = match.status;
	if (expectation.scenarioId === "N-01") {
		if (!PARTNER_FOX_MATCH_STATUSES.has(status) || !validateCompatibilityConversation(match.compatibility_conversations, expectation.matchId as string, expectation.deliveryContext!)) return false;
		return validateRoom(match.direct_room, expectation.matchId as string, status);
	}
	if (expectation.scenarioId === "N-03") {
		return status === "direct_chat_requested" && validateChatRequest(match.chat_requests, expectation.matchId as string, expectation.userId, participantIds, expectation.deliveryContext!, expectation.now.getTime());
	}
	if (status !== "direct_chat_active") return false;
	return validateRoom(match.direct_room, expectation.matchId as string, status);
}

function validateMeetupScenario(
	meetupValue: unknown,
	expectation: NotificationDeliveryExpectation,
	participantIds: readonly [string, string],
	match: Record<string, unknown>,
): boolean {
	if (!validateMatchScenario(match, { ...expectation, scenarioId: "N-04" }, participantIds)) return false;
	const meetup = exactlyOne(meetupValue);
	if (!meetup || meetup.id !== expectation.meetupId || meetup.match_id !== expectation.matchId) return false;
	const expectedStatus =
		expectation.scenarioId === "N-05"
			? "proposed"
			: expectation.scenarioId === "N-06"
				? "confirmed"
				: expectation.scenarioId === "N-04" || expectation.scenarioId === "N-07"
					? "verifying"
					: "arrange_failed";
	if (meetup.status !== expectedStatus || !isValidExpiry(meetup.proposal_expires_at, expectation.now.getTime())) return false;
	if (expectation.scenarioId === "N-05") return validateMeetupProposal(meetup.proposals, expectation.meetupId as string, expectation.deliveryContext!, expectation.now.getTime());
	return true;
}

async function readFinalNotificationRow(
	supabase: SupabaseClient<Database>,
	expectation: NotificationDeliveryExpectation,
	participantIds?: readonly [string, string],
): Promise<QueryResult> {
	try {
		let query = supabase
			.from("notifications")
			.select(FINAL_NOTIFICATION_SELECT)
			.eq("id", expectation.notificationId)
			.eq("scenario_id", expectation.scenarioId)
			.eq("user_id", expectation.userId)
			.eq("payload->>deep_link", expectation.deepLink)
			.is("sent_at", null)
			.is("suppressed_reason", null)
			.is("onesignal_notification_id", null);
		query = expectation.matchId ? query.eq("match_id", expectation.matchId) : query.is("match_id", null);
		query = expectation.meetupId ? query.eq("meetup_id", expectation.meetupId) : query.is("meetup_id", null);
		query = expectation.fencingToken !== undefined ? query.eq("scheduled_for", expectation.fencingToken) : query.is("scheduled_for", null);
		if (participantIds) {
			query = query
				.eq("match.user_a_id", participantIds[0])
				.eq("match.user_b_id", participantIds[1])
				.eq("match.profile_a.blocks_sent.blocked_id", participantIds[1])
				.eq("match.profile_b.blocks_sent.blocked_id", participantIds[0]);
		}
		if (expectation.scenarioId === "N-01") query = query.eq("match.compatibility_conversations.purpose", "compatibility");
		const context = parseNotificationDeliveryContext(expectation.deliveryContext);
		if (context && "conversation_id" in context) query = query.eq("payload->delivery_context->>conversation_id", context.conversation_id);
		if (context && "request_id" in context) query = query.eq("payload->delivery_context->>request_id", context.request_id);
		if (context && "proposal_id" in context) query = query.eq("payload->delivery_context->>proposal_id", context.proposal_id);
		if (expectation.scenarioId === "N-05") query = query.order("attempt_number", { ascending: false, referencedTable: "meetup.proposals" });
		return await query.single() as unknown as QueryResult;
	} catch {
		return { data: null, error: { accessLookupFailed: true } };
	}
}

/** Read the ordered match identity before the final embedded snapshot. */
export async function readNotificationMatchParticipants(
	supabase: SupabaseClient<Database>,
	matchId: string,
	userId: string,
): Promise<{ ok: true; participantIds: readonly [string, string] } | { ok: false; reason: NotificationDeliveryAccessFailure }> {
	if (!isNonEmptyId(matchId) || !isNonEmptyId(userId)) return { ok: false, reason: "forbidden" };
	try {
		const result = await supabase.from("matches").select(MATCH_IDENTITY_SELECT).eq("id", matchId).single() as unknown as QueryResult;
		if (result.error) return { ok: false, reason: missingOrFailed(result.error) };
		if (!isRecord(result.data) || result.data.id !== matchId || !isNonEmptyId(result.data.user_a_id) || !isNonEmptyId(result.data.user_b_id)) return { ok: false, reason: "forbidden" };
		if (result.data.user_a_id >= result.data.user_b_id || (result.data.user_a_id !== userId && result.data.user_b_id !== userId)) return { ok: false, reason: "forbidden" };
		return { ok: true, participantIds: [result.data.user_a_id, result.data.user_b_id] };
	} catch {
		return { ok: false, reason: "error" };
	}
}

/**
 * Verify the row and every relationship used by a wired scenario in one
 * final embedded read. Callers must perform no database work between this
 * read and the OneSignal request.
 */
export async function checkNotificationDeliveryAccess(
	supabase: SupabaseClient<Database>,
	expectation: NotificationDeliveryExpectation,
): Promise<NotificationDeliveryAccessResult> {
	const context = parseNotificationDeliveryContext(expectation.deliveryContext);
	if (!WIRED_SCENARIOS.has(expectation.scenarioId) || !isNotificationDeliveryContextForScenario(expectation.scenarioId, expectation.matchId, expectation.meetupId, context)) {
		return { ok: false, reason: "forbidden" };
	}
	if (expectation.scenarioId !== "N-13" && (!expectation.participantIds || expectation.participantIds.length !== 2)) {
		return { ok: false, reason: "forbidden" };
	}
	const finalResult = await readFinalNotificationRow(supabase, expectation, expectation.participantIds);
	if (finalResult.error) return { ok: false, reason: missingOrFailed(finalResult.error) };
	if (!isRecord(finalResult.data)) return { ok: false, reason: "forbidden" };
	const finalNowMs = (expectation.clock?.() ?? expectation.now).getTime();
	const row = finalResult.data;
	if (
		row.id !== expectation.notificationId ||
		row.scenario_id !== expectation.scenarioId ||
		row.user_id !== expectation.userId ||
		row.match_id !== (expectation.matchId ?? null) ||
		row.meetup_id !== (expectation.meetupId ?? null) ||
		!isRecord(row.payload) ||
		(row.payload as Record<string, unknown>).deep_link !== expectation.deepLink
	) {
		return { ok: false, reason: "forbidden" };
	}
	const persistedContext = parseNotificationDeliveryContext((row.payload as Record<string, unknown>).delivery_context);
	const rawPersistedContext = (row.payload as Record<string, unknown>).delivery_context;
	if (rawPersistedContext !== undefined && rawPersistedContext !== null && persistedContext === null) return { ok: false, reason: "forbidden" };
	if (context === null ? persistedContext !== null : persistedContext === null) return { ok: false, reason: "forbidden" };
	if (context !== null && persistedContext !== null) {
		const contextKey = Object.keys(context)[0] as NotificationDeliveryContextKey;
		const persistedValue = (persistedContext as Record<string, string>)[contextKey];
		const expectedValue = (context as Record<string, string>)[contextKey];
		if (persistedValue !== expectedValue) return { ok: false, reason: "forbidden" };
	}
	if (!validateScenarioRow(row.scenario, expectation.scenarioId)) return { ok: false, reason: "forbidden" };
	if (expectation.scenarioId === "N-13") return { ok: true };
	const match = exactlyOne(row.match);
	if (!match || !validateMatchScenario(match, { ...expectation, now: new Date(finalNowMs) }, expectation.participantIds!)) return { ok: false, reason: "forbidden" };
	if (expectation.scenarioId === "N-03" && !validateChatRequest(match.chat_requests, expectation.matchId!, expectation.userId, expectation.participantIds!, context!, finalNowMs)) return { ok: false, reason: "forbidden" };
	if (expectation.scenarioId === "N-01" && !validateCompatibilityConversation(match.compatibility_conversations, expectation.matchId!, context!)) return { ok: false, reason: "forbidden" };
	if (expectation.scenarioId === "N-04" || expectation.scenarioId === "N-05" || expectation.scenarioId === "N-06" || expectation.scenarioId === "N-07" || expectation.scenarioId === "N-14") {
		if (!validateMeetupScenario(row.meetup, { ...expectation, now: new Date(finalNowMs) }, expectation.participantIds!, match)) return { ok: false, reason: "forbidden" };
	}
	return { ok: true };
}
