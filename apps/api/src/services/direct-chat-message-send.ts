import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { sha256Hex } from "./message-idempotency";

export type DirectChatMessageSendRow = {
	outcome: string;
	message_id: string | null;
	message_content: string | null;
	message_created_at: string | null;
};

const DIRECT_SEND_OUTCOMES = new Set([
	"inserted",
	"replayed",
	"conflict",
	"missing",
	"not_found",
	"ineligible",
	"invalid_input",
]);
const DIRECT_RECOVERY_OUTCOMES = new Set([
	"found",
	"not_found",
	"ineligible",
	"conflict",
	"missing",
	"invalid_input",
]);

const CANONICAL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const RFC3339_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRow(value: unknown): value is DirectChatMessageSendRow {
	return isRecord(value)
		&& typeof value.outcome === "string"
		&& DIRECT_SEND_OUTCOMES.has(value.outcome)
		&& (value.message_id === null || typeof value.message_id === "string" && CANONICAL_UUID.test(value.message_id))
		&& (value.message_content === null || typeof value.message_content === "string" && value.message_content.length <= 2000)
		&& (value.message_created_at === null || isValidTimestamp(value.message_created_at));
}

function isValidTimestamp(value: unknown): value is string {
	return typeof value === "string" && RFC3339_TIMESTAMP.test(value) && Number.isFinite(Date.parse(value));
}

function isValidSendResult(row: DirectChatMessageSendRow, expectedContent: string): boolean {
	if (row.outcome === "inserted" || row.outcome === "replayed") {
		return CANONICAL_UUID.test(row.message_id ?? "")
			&& row.message_content === expectedContent
			&& isValidTimestamp(row.message_created_at);
	}
	return row.message_id === null && row.message_content === null && row.message_created_at === null;
}

export async function persistDirectChatMessage(
	supabase: SupabaseClient<Database>,
	args: {
		roomId: string;
		senderId: string;
		idempotencyKey: string;
		content: string;
		contentSha256: string;
	},
): Promise<DirectChatMessageSendRow | null> {
	try {
		const { data, error } = await supabase.rpc("persist_direct_chat_message", {
			p_room_id: args.roomId,
			p_sender_id: args.senderId,
			p_idempotency_key: args.idempotencyKey,
			p_content: args.content,
			p_content_sha256: args.contentSha256,
		});
		if (error || !Array.isArray(data) || data.length !== 1 || !isRow(data[0])) return null;
		return isValidSendResult(data[0], args.content) ? data[0] : null;
	} catch {
		return null;
	}
}

export async function recoverDirectChatMessageSend(
	supabase: SupabaseClient<Database>,
	args: { roomId: string; senderId: string; idempotencyKey: string; contentSha256: string },
): Promise<DirectChatMessageSendRow | null> {
	try {
		const { data, error } = await supabase.rpc("recover_direct_chat_message_send", {
			p_room_id: args.roomId,
			p_sender_id: args.senderId,
			p_idempotency_key: args.idempotencyKey,
			p_content_sha256: args.contentSha256,
		});
		if (error || !Array.isArray(data) || data.length !== 1) return null;
		const value: unknown = data[0];
		if (
			!isRecord(value) || typeof value.outcome !== "string" || !DIRECT_RECOVERY_OUTCOMES.has(value.outcome) ||
			!(value.message_id === null || typeof value.message_id === "string" && CANONICAL_UUID.test(value.message_id)) ||
			!(value.message_content === null || typeof value.message_content === "string" && value.message_content.length <= 2000) ||
			!(value.message_created_at === null || isValidTimestamp(value.message_created_at))
		) return null;
		const row = value as DirectChatMessageSendRow;
		if (row.outcome === "found") {
			if (!CANONICAL_UUID.test(row.message_id ?? "") || !isNonEmptyBoundedContent(row.message_content) || !isValidTimestamp(row.message_created_at)) return null;
			return await sha256Hex(row.message_content) === args.contentSha256 ? row : null;
		}
		return row.message_id === null && row.message_content === null && row.message_created_at === null ? row : null;
	} catch {
		return null;
	}
}

function isNonEmptyBoundedContent(value: string | null): value is string {
	return typeof value === "string" && value.trim().length > 0 && value.length <= 2000;
}
