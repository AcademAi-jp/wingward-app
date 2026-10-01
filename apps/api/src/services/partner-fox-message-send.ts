import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { sha256Hex } from "./message-idempotency";

export type PartnerFoxMessageSendRow = {
	outcome: string;
	user_message_id: string | null;
	user_content: string | null;
	user_created_at: string | null;
	fox_message_id: string | null;
	fox_content: string | null;
	fox_created_at: string | null;
	claim_token: string | null;
};

export type PartnerFoxMessageRecoveryRow = {
	outcome: string;
	user_message_id: string | null;
	user_content: string | null;
	user_created_at: string | null;
	fox_message_id: string | null;
	fox_content: string | null;
	fox_created_at: string | null;
};

export type PartnerFoxGreetingClaimRow = {
	outcome: string;
	claim_token: string | null;
	message_id: string | null;
	message_role: "fox" | null;
	message_content: string | null;
	message_created_at: string | null;
	match_status: string | null;
	transitioned: boolean;
};

export type PartnerFoxGreetingRetryRow = { outcome: string; claim_token: null };

const PARTNER_SEND_OUTCOMES = new Set([
	"claimed",
	"replayed",
	"completed",
	"missing",
	"conflict",
	"not_found",
	"unknown",
	"processing",
	"stale",
	"busy",
	"ineligible",
	"invalid_input",
	"failed",
]);
const PARTNER_RECOVERY_OUTCOMES = new Set([
	"completed",
	"processing",
	"failed",
	"unknown",
	"missing",
	"conflict",
	"not_found",
	"ineligible",
	"invalid_input",
]);
const GREETING_CLAIM_OUTCOMES = new Set([
	"claimed", "busy", "completed", "unknown", "message_present", "not_found", "invalid_input", "missing",
]);
const GREETING_COMPLETE_OUTCOMES = new Set([
	"completed", "stale", "unknown", "message_present", "not_found", "invalid_input",
]);
const GREETING_MATCH_STATUSES = new Set([
	"fox_conversation_completed", "partner_chat_started", "direct_chat_requested", "direct_chat_active",
	"meetup_intent", "meetup_confirmed",
]);

const CANONICAL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const RFC3339_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

type RpcResult = {
	data: unknown;
	error: unknown;
};

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isValidTimestamp(value: unknown): value is string {
	return typeof value === "string" && RFC3339_TIMESTAMP.test(value) && Number.isFinite(Date.parse(value));
}

function isNullableUuid(value: unknown): value is string | null {
	return value === null || typeof value === "string" && CANONICAL_UUID.test(value);
}

function isNullableTimestamp(value: unknown): value is string | null {
	return value === null || isValidTimestamp(value);
}

function isGreetingRpcRow(value: unknown, allowedOutcomes: Set<string>, expectedContent?: string): value is PartnerFoxGreetingClaimRow {
	if (
		!isRecord(value) || typeof value.outcome !== "string" || !allowedOutcomes.has(value.outcome) ||
		!isNullableUuid(value.claim_token) || !isNullableUuid(value.message_id) ||
		(value.message_role !== null && value.message_role !== "fox") ||
		(value.message_content !== null && (typeof value.message_content !== "string" || value.message_content.length > 2000)) ||
		!isNullableTimestamp(value.message_created_at) ||
		(value.match_status !== null && (typeof value.match_status !== "string" || !GREETING_MATCH_STATUSES.has(value.match_status))) ||
		typeof value.transitioned !== "boolean"
	) return false;

	if (value.outcome === "claimed") {
		return value.claim_token !== null && value.message_id === null && value.message_role === null &&
			value.message_content === null && value.message_created_at === null &&
			typeof value.match_status === "string" && !value.transitioned;
	}
	if (value.outcome === "completed") {
		return value.claim_token === null && value.message_id !== null && value.message_role === "fox" &&
			typeof value.message_content === "string" && value.message_content.trim().length > 0 &&
			isValidTimestamp(value.message_created_at) && typeof value.match_status === "string" &&
			(!value.transitioned || value.match_status === "partner_chat_started") &&
			(expectedContent === undefined || value.message_content === expectedContent);
	}
	return value.claim_token === null && value.message_id === null && value.message_role === null &&
		value.message_content === null && value.message_created_at === null && !value.transitioned;
}

async function callGreetingRpc(
	supabase: SupabaseClient<Database>,
	functionName: "claim_partner_fox_greeting" | "complete_partner_fox_greeting",
	args: Record<string, unknown>,
	allowedOutcomes: Set<string>,
	expectedContent?: string,
): Promise<PartnerFoxGreetingClaimRow | null> {
	try {
		const response = await (supabase.rpc as unknown as (
			name: string,
			rpcArgs: Record<string, unknown>,
		) => Promise<RpcResult>)(functionName, args);
		if (response.error || !Array.isArray(response.data) || response.data.length !== 1 ||
			!isGreetingRpcRow(response.data[0], allowedOutcomes, expectedContent)) return null;
		return response.data[0];
	} catch {
		return null;
	}
}

export function claimPartnerFoxGreeting(
	supabase: SupabaseClient<Database>,
	args: { chatId: string; matchId: string; userId: string; partnerUserId: string },
): Promise<PartnerFoxGreetingClaimRow | null> {
	return callGreetingRpc(supabase, "claim_partner_fox_greeting", {
		p_chat_id: args.chatId,
		p_match_id: args.matchId,
		p_user_id: args.userId,
		p_partner_user_id: args.partnerUserId,
	}, GREETING_CLAIM_OUTCOMES);
}

export function completePartnerFoxGreeting(
	supabase: SupabaseClient<Database>,
	args: { chatId: string; claimToken: string; content: string },
): Promise<PartnerFoxGreetingClaimRow | null> {
	return callGreetingRpc(supabase, "complete_partner_fox_greeting", {
		p_chat_id: args.chatId,
		p_claim_token: args.claimToken,
		p_content: args.content,
	}, GREETING_COMPLETE_OUTCOMES, args.content);
}

export async function retryPartnerFoxGreetingBeforeProvider(
	supabase: SupabaseClient<Database>,
	args: { chatId: string; claimToken: string },
): Promise<PartnerFoxGreetingRetryRow | null> {
	try {
		const response = await (supabase.rpc as unknown as (
			name: string,
			rpcArgs: Record<string, unknown>,
		) => Promise<RpcResult>)("retry_partner_fox_greeting_before_provider", {
			p_chat_id: args.chatId,
			p_claim_token: args.claimToken,
		});
		if (response.error || !Array.isArray(response.data) || response.data.length !== 1) return null;
		const row: unknown = response.data[0];
		if (!isRecord(row) || !["retryable", "stale", "unknown", "not_found", "invalid_input"].includes(String(row.outcome)) || row.claim_token !== null) return null;
		return row as PartnerFoxGreetingRetryRow;
	} catch {
		return null;
	}
}

function isRecoveryRow(value: unknown): value is PartnerFoxMessageRecoveryRow {
	if (
		!isRecord(value) || typeof value.outcome !== "string" || !PARTNER_RECOVERY_OUTCOMES.has(value.outcome) ||
		!isNullableUuid(value.user_message_id) ||
		(value.user_content !== null && (typeof value.user_content !== "string" || value.user_content.length > 2000)) ||
		!isNullableTimestamp(value.user_created_at) ||
		!isNullableUuid(value.fox_message_id) ||
		(value.fox_content !== null && (typeof value.fox_content !== "string" || value.fox_content.length > 2000)) ||
		!isNullableTimestamp(value.fox_created_at)
	) return false;
	if (value.outcome === "completed") {
		return value.user_message_id !== null && typeof value.user_content === "string" && value.user_content.trim().length > 0 &&
			isValidTimestamp(value.user_created_at) && value.fox_message_id !== null &&
			typeof value.fox_content === "string" && value.fox_content.trim().length > 0 && isValidTimestamp(value.fox_created_at);
	}
	return value.user_message_id === null && value.user_content === null && value.user_created_at === null &&
		value.fox_message_id === null && value.fox_content === null && value.fox_created_at === null;
}

function isSendRow(value: unknown, expectedContent: string): value is PartnerFoxMessageSendRow {
	if (
		!isRecord(value) ||
		typeof value.outcome !== "string" || !PARTNER_SEND_OUTCOMES.has(value.outcome) ||
		!isNullableUuid(value.user_message_id) ||
		(value.user_content !== null && (typeof value.user_content !== "string" || value.user_content.length > 2000)) ||
		!isNullableTimestamp(value.user_created_at) ||
		!isNullableUuid(value.fox_message_id) ||
		(value.fox_content !== null && (typeof value.fox_content !== "string" || value.fox_content.length > 2000)) ||
		!isNullableTimestamp(value.fox_created_at) ||
		!isNullableUuid(value.claim_token)
	) return false;

	if (value.outcome === "claimed") {
		return isNullableUuid(value.user_message_id) && value.user_message_id !== null &&
			value.user_content === expectedContent && isValidTimestamp(value.user_created_at) &&
			value.fox_message_id === null && value.fox_content === null && value.fox_created_at === null &&
			value.claim_token !== null;
	}
	if (value.outcome === "completed" || value.outcome === "replayed") {
		return value.user_message_id !== null && value.user_content === expectedContent && isValidTimestamp(value.user_created_at) &&
			value.fox_message_id !== null && typeof value.fox_content === "string" && value.fox_content.trim().length > 0 &&
			isValidTimestamp(value.fox_created_at) && value.claim_token === null;
	}
	if (value.user_content !== null && value.user_content !== expectedContent) return false;
	if (value.fox_message_id !== null || value.fox_content !== null || value.fox_created_at !== null || value.claim_token !== null) return false;
	if (value.outcome === "processing" || value.outcome === "unknown") return true;
	return value.user_message_id === null && value.user_content === null && value.user_created_at === null;
}

async function callSendRpc(
	supabase: SupabaseClient<Database>,
	functionName: "claim_partner_fox_message_send" | "complete_partner_fox_message_send" | "finish_partner_fox_message_send",
	args: Record<string, unknown>,
	expectedContent: string,
): Promise<PartnerFoxMessageSendRow | null> {
	try {
		const response = await (supabase.rpc as unknown as (
			name: string,
			rpcArgs: Record<string, unknown>,
		) => Promise<RpcResult>)(functionName, args);
		if (response.error || !Array.isArray(response.data) || response.data.length !== 1 || !isSendRow(response.data[0], expectedContent)) return null;
		return response.data[0];
	} catch {
		return null;
	}
}

export function claimPartnerFoxMessageSend(
	supabase: SupabaseClient<Database>,
	args: { chatId: string; ownerId: string; idempotencyKey: string; content: string; contentSha256: string },
): Promise<PartnerFoxMessageSendRow | null> {
	return callSendRpc(supabase, "claim_partner_fox_message_send", {
		p_chat_id: args.chatId,
		p_owner_id: args.ownerId,
		p_idempotency_key: args.idempotencyKey,
		p_content: args.content,
		p_content_sha256: args.contentSha256,
	}, args.content);
}

export function completePartnerFoxMessageSend(
	supabase: SupabaseClient<Database>,
	args: { idempotencyKey: string; claimToken: string; foxContent: string; userContent: string },
): Promise<PartnerFoxMessageSendRow | null> {
	return callSendRpc(supabase, "complete_partner_fox_message_send", {
		p_idempotency_key: args.idempotencyKey,
		p_claim_token: args.claimToken,
		p_fox_content: args.foxContent,
	}, args.userContent);
}

export function finishPartnerFoxMessageSend(
	supabase: SupabaseClient<Database>,
	args: { idempotencyKey: string; claimToken: string; outcome: "failed" | "unknown"; userContent: string },
): Promise<PartnerFoxMessageSendRow | null> {
	return callSendRpc(supabase, "finish_partner_fox_message_send", {
		p_idempotency_key: args.idempotencyKey,
		p_claim_token: args.claimToken,
		p_outcome: args.outcome,
	}, args.userContent);
}

export async function recoverPartnerFoxMessageSend(
	supabase: SupabaseClient<Database>,
	args: { chatId: string; ownerId: string; idempotencyKey: string; contentSha256: string },
): Promise<PartnerFoxMessageRecoveryRow | null> {
	try {
		const response = await (supabase.rpc as unknown as (
			name: string,
			rpcArgs: Record<string, unknown>,
		) => Promise<RpcResult>)("recover_partner_fox_message_send", {
			p_chat_id: args.chatId,
			p_owner_id: args.ownerId,
			p_idempotency_key: args.idempotencyKey,
			p_content_sha256: args.contentSha256,
		});
		if (response.error || !Array.isArray(response.data) || response.data.length !== 1 || !isRecoveryRow(response.data[0])) return null;
		const row = response.data[0];
		if (row.outcome === "completed" && await sha256Hex(row.user_content ?? "") !== args.contentSha256) return null;
		return row;
	} catch {
		return null;
	}
}
