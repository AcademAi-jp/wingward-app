import { unavailableCafeSearchProvider } from "../services/chat-meetup-providers";
import { Hono } from "hono";
import { z } from "zod";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAuth, requireAgeVerified } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { isJudgeAccessActive, judgeRpcClient, readJudgeAccess, readJudgeAccessConfig } from "../services/judge-access";
import { getChatMeetupState, refreshChatMeetupAvailableTimes } from "../services/chat-meetup";

const input = z.object({ match_id: z.string().uuid().transform(value => value.toLowerCase()), operation: z.enum(["accept", "intent", "availability", "time_approve", "simulate_completion"]),
  expected_revision: z.number().int().min(0).max(2_147_483_647), idempotency_key: z.string().uuid().transform(value => value.toLowerCase()) }).strict();
const output = z.object({ outcome: z.enum(["ok", "replayed"]), match_id: z.string().uuid(), room_id: z.string().uuid().nullable(),
  meetup_id: z.string().uuid().nullable(), status: z.string().min(1).max(64), revision: z.number().int().min(0).max(2_147_483_647) });
const route = new Hono<Env>();
route.post("/counterpart/advance", requireAuth, requireAgeVerified, async c => {
  c.header("Cache-Control", "private, no-store");
  const unavailable = () => jsonError(c, "INTERNAL_ERROR", "Review counterpart unavailable", 503);
  const access = c.get("judge_access"), scope = readJudgeAccessConfig(c.env), actor = c.get("user_id");
  if (!isJudgeAccessActive(access) || access.actorId !== actor || scope.kind !== "active") return jsonError(c, "FORBIDDEN", "Review counterpart unavailable");
  let parsed: ReturnType<typeof input.safeParse>;
  try {
    const reader = c.req.raw.body?.getReader(); if (!reader) return jsonError(c, "BAD_REQUEST", "Invalid review action");
    const chunks: Uint8Array[] = []; let size = 0;
    while (true) { const part = await reader.read(); if (part.done) break; size += part.value.byteLength;
      if (size > 2048) { await reader.cancel(); return jsonError(c, "BAD_REQUEST", "Invalid review action"); } chunks.push(part.value); }
    const bytes = new Uint8Array(size); let offset = 0; for (const part of chunks) { bytes.set(part, offset); offset += part.byteLength; }
    parsed = input.safeParse(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)));
  } catch { return jsonError(c, "BAD_REQUEST", "Invalid review action"); }
  if (!parsed.success || (c.req.header("Idempotency-Key") !== undefined && c.req.header("Idempotency-Key") !== parsed.data.idempotency_key)) return jsonError(c, "BAD_REQUEST", "Invalid review action");
  if (parsed.data.operation !== "accept" && c.env.CHAT_MEETUP_ENABLED !== "enabled") return unavailable();
  const db = getSupabaseClient(c.env), rpc = judgeRpcClient(db);
  const fresh = await readJudgeAccess(rpc, scope.config, actor);
  if (!fresh || fresh.counterpartId !== access.counterpartId || fresh.accountKind !== access.accountKind) return jsonError(c, "FORBIDDEN", "Review counterpart unavailable");
  try {
    const response = await rpc.rpc("advance_judge_counterpart", { p_user_id: actor, p_match_id: parsed.data.match_id,
      p_operation: parsed.data.operation, p_expected_revision: parsed.data.expected_revision, p_idempotency_key: parsed.data.idempotency_key });
    const row = Array.isArray(response.data) && response.data.length === 1 ? response.data[0] : response.data;
    if (response.error || !row || typeof row !== "object" || Array.isArray(row) || !isJudgeAccessActive(fresh)) return unavailable();
    const outcome = (row as Record<string, unknown>).outcome;
    if (["denied", "expired"].includes(outcome as string)) return jsonError(c, "FORBIDDEN", "Review counterpart unavailable");
    if (outcome === "not_found") return jsonError(c, "NOT_FOUND", "Review match not found");
    if (outcome === "invalid_input") return jsonError(c, "BAD_REQUEST", "Invalid review action");
    if (["invalid_state", "stale_revision", "idempotency_conflict", "identity_verification_required", "expired_candidate"].includes(outcome as string)) return jsonError(c, "CONFLICT", "Review state changed; refresh and try again");
    const result = output.safeParse(row);
    if (!result.success || result.data.match_id !== parsed.data.match_id || (parsed.data.operation === "accept" && !result.data.room_id)) return unavailable();
    if (parsed.data.operation === "availability" && result.data.room_id) {
      const failure = await refreshChatMeetupAvailableTimes(db, result.data.room_id, actor, fresh);
      if (failure === "quota_exhausted") return jsonError(c, "PAYMENT_REQUIRED", "Meetup arrangement is unavailable");
      if (failure) return unavailable();
      const state = await getChatMeetupState(db, result.data.room_id, actor, { enabled: c.env.CHAT_MEETUP_ENABLED === "enabled", providers: { cafe: unavailableCafeSearchProvider, judgeAccess: fresh } });
      if (!state.ok) return unavailable();
      result.data.status = state.state.status; result.data.revision = state.state.revision;
    }
    const after = await readJudgeAccess(rpc, scope.config, actor);
    if (!after || after.counterpartId !== fresh.counterpartId || after.accountKind !== fresh.accountKind || !isJudgeAccessActive(fresh)) return unavailable();
    return jsonData(c, result.data);
  } catch { return unavailable(); }
});
export default route;
