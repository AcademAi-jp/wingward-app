import { Hono, type Context } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { getChatMeetupState, applyChatMeetupAction, getChatWardConversation, checkChatMeetupRoomAccess, chatMeetupActionRequestSchema, type ChatMeetupProviders } from "../services/chat-meetup";
import { isJudgeAccessActive } from "../services/judge-access";
import { unavailableCafeSearchProvider } from "../services/chat-meetup-providers";

const chatMeetups = new Hono<Env>();
const ROOM_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
/** Keep trusted admission context; cafe settings cannot enable this future feature. */
function providersForRequest(c: Context<Env>): ChatMeetupProviders | undefined {
  const judgeAccess = c.get("judge_access");
  if (judgeAccess) return { cafe: unavailableCafeSearchProvider, judgeAccess };
  const config = c.get("recording_rehearsal");
  return config ? { cafe: unavailableCafeSearchProvider, recordingRehearsalConfig: config } : undefined;
}
function failure(c: Parameters<typeof jsonError>[0], reason: string) {
  if (reason === "not_found") return jsonError(c, "NOT_FOUND", "Chat meetup not found");
  if (reason === "bad_request") return jsonError(c, "BAD_REQUEST", "Invalid meetup action");
  if (reason === "invalid_state") return jsonError(c, "CONFLICT", "Meetup cannot be updated");
  if (reason === "stale_revision") return jsonError(c, "CONFLICT", "Meetup state changed; refresh and try again");
  if (reason === "idempotency_conflict") return jsonError(c, "CONFLICT", "Idempotency key was already used for another action");
  if (reason === "identity_verification_required") return jsonError(c, "CONFLICT", "Identity verification required");
  if (reason === "quota_exhausted") return c.json({ error: { code: "PAYMENT_REQUIRED", message: "Meetup arrangement is unavailable", source: "meetup_arrange" } }, 402);
  if (reason === "provider_unavailable") return jsonError(c, "INTERNAL_ERROR", "Meetup provider is unavailable", 503);
  return jsonError(c, "INTERNAL_ERROR", "Unable to process meetup");
}
const MAX_ACTION_BODY_BYTES = 32 * 1024;
async function readJson(c: Parameters<typeof jsonError>[0]): Promise<unknown> {
  const reader = c.req.raw.body?.getReader();
  if (!reader) return null;
  try {
    let size = 0;
    const chunks: Uint8Array[] = [];
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      size += part.value.byteLength;
      if (size > MAX_ACTION_BODY_BYTES) { await reader.cancel(); return null; }
      chunks.push(part.value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return JSON.parse(new TextDecoder().decode(bytes)) as unknown;
  } catch { return null; }
}
function disabled(c: Parameters<typeof jsonError>[0]) {
  return jsonError(c, "INTERNAL_ERROR", "Chat meetup is unavailable", 503);
}
async function judgeMetadata(c: Context<Env>, roomId: string): Promise<{ simulated_counterpart: true; judge_match_id: string } | null | false> {
  const judge = c.get("judge_access");
  if (!judge) return null;
  if (!isJudgeAccessActive(judge) || judge.actorId !== c.get("user_id")) return false;
  const access = await checkChatMeetupRoomAccess(getSupabaseClient(c.env), roomId, judge.actorId, undefined, judge);
  if (!access.ok || !isJudgeAccessActive(judge)) return false;
  const peer = access.context.userA === judge.actorId ? access.context.userB : access.context.userA;
  return peer === judge.counterpartId ? { simulated_counterpart: true, judge_match_id: access.context.matchId } : false;
}

/** GET /api/chat-meetups/rooms/:roomId */
chatMeetups.get("/rooms/:roomId", requireAuth, requireAgeVerified, async (c) => {
  c.header("Cache-Control", "private, no-store");
  if (c.env.CHAT_MEETUP_ENABLED !== "enabled") return disabled(c);
  const roomId = c.req.param("roomId");
  if (!ROOM_ID.test(roomId)) return failure(c, "not_found");
  const judge = await judgeMetadata(c, roomId);
  if (judge === false) return failure(c, "not_found");
  const providers = providersForRequest(c);
  const result = await getChatMeetupState(getSupabaseClient(c.env), roomId, c.get("user_id"), {
    enabled: c.env.CHAT_MEETUP_ENABLED === "enabled",
    ...(providers ? { providers } : {}),
  });
  if (!result.ok) return failure(c, result.reason);
  return jsonData(c, { ...result.state, ...judge });
});

/** POST /api/chat-meetups/rooms/:roomId/actions */
chatMeetups.post("/rooms/:roomId/actions", requireAuth, requireAgeVerified, async (c) => {
  c.header("Cache-Control", "private, no-store");
  if (c.env.CHAT_MEETUP_ENABLED !== "enabled") return disabled(c);
  const roomId = c.req.param("roomId");
  if (!ROOM_ID.test(roomId)) return failure(c, "not_found");
  const judge = await judgeMetadata(c, roomId);
  if (judge === false) return failure(c, "not_found");
  const body = await readJson(c);
  const parsed = chatMeetupActionRequestSchema.safeParse(body);
  if (!parsed.success) return failure(c, "bad_request");
  const headerKey = c.req.header("Idempotency-Key");
  if (headerKey !== undefined && headerKey !== parsed.data.idempotency_key) return failure(c, "bad_request");
  const providers = providersForRequest(c);
  const result = await applyChatMeetupAction(getSupabaseClient(c.env), roomId, c.get("user_id"), parsed.data, {
    enabled: c.env.CHAT_MEETUP_ENABLED === "enabled",
    ...(providers ? { providers } : {}),
  });
  if (!result.ok) return failure(c, result.reason);
  return jsonData(c, { ...result.state, ...judge });
});

/** GET /api/chat-meetups/rooms/:roomId/ward-conversation */
chatMeetups.get("/rooms/:roomId/ward-conversation", requireAuth, requireAgeVerified, async (c) => {
  c.header("Cache-Control", "private, no-store");
  if (c.env.CHAT_MEETUP_ENABLED !== "enabled") return disabled(c);
  const roomId = c.req.param("roomId");
  if (!ROOM_ID.test(roomId)) return failure(c, "not_found");
  const result = await getChatWardConversation(getSupabaseClient(c.env), roomId, c.get("user_id"));
  if (!result.ok) return failure(c, result.reason);
  return jsonData(c, result.data);
});

export default chatMeetups;
