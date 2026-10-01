import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { jsonData, jsonError } from "../lib/response";
import { isJudgeAccessActive, judgeRpcClient, readJudgeAccess, readJudgeAccessConfig, reserveJudgeProviderOperation } from "../services/judge-access";
import { JUDGE_20261001_PROFILE_IDS, JUDGE_SEVEN_OWNER_PROFILE_IDS } from "../services/synthetic-matching-cohort";
import { chatCompleteOnceBounded, MISTRAL_LARGE, MISTRAL_REQUEST_TOKEN_OVERHEAD } from "../services/mistral";

const members = new Set<string>([...JUDGE_20261001_PROFILE_IDS.slice(0, 5), ...JUDGE_SEVEN_OWNER_PROFILE_IDS]);
// Fixed transport-v2 receipts retain all earlier failed reservations and allow one repaired probe per account.
const transportV2Receipts = new Map([...members].map((actor, index) => [actor, [
 "c0167ddf-5573-408f-a684-d352fdb5a35b",
 "fba1644a-854f-4569-8317-7dac53e1f41c",
 "047a9050-0331-4f63-8f71-0c2817f561f8",
 "57e2097e-3b1f-43ce-ad6a-e0c9979424a5",
 "f3e6d886-24b5-49da-bf18-f0b6a8ddca24",
 "248426cb-b1c0-4a7d-9934-22d1ec6af656",
 "45e680f2-0786-43ca-9e16-79c81b684d97"
][index]]));
const route = new Hono<Env>();
/** Read-only vendor authentication check: no inference, reservation, or model output. */
route.get("/readiness/provider", async c => {
 c.header("Cache-Control", "private, no-store");
 const scope = readJudgeAccessConfig(c.env), access = c.get("judge_access"), actor = c.get("user_id");
 if (scope.kind !== "active" || scope.config.ownerAiExpiresAtMs === undefined
  || !isJudgeAccessActive(access) || access.actorId !== actor || !members.has(actor)
  || !["judge", "owner"].includes(access.accountKind)) return jsonError(c, "FORBIDDEN", "Review check unavailable");
 const deadline = Math.min(scope.config.expiresAtMs, scope.config.issuedAtMs + 30 * 60_000);
 if (Date.now() >= deadline) return c.json({ code: "closed" }, 410);
 const rpc = judgeRpcClient(getSupabaseClient(c.env));
 const fresh = await readJudgeAccess(rpc, scope.config, actor);
 if (!fresh || fresh.counterpartId !== access.counterpartId || fresh.accountKind !== access.accountKind || Date.now() >= deadline)
  return jsonError(c, "FORBIDDEN", "Review check unavailable");
 if (!c.env.MISTRAL_API_KEY?.trim()) return jsonData(c, { connected: false, reason: "key_unavailable" });
 let stage: "fetch" | "body" | "json" | "access" = "fetch";
 try {
  const response = await fetch(`https://api.mistral.ai/v1/models/${MISTRAL_LARGE}`, {
   method: "GET", headers: { Authorization: `Bearer ${c.env.MISTRAL_API_KEY}` },
   redirect: "manual", signal: AbortSignal.timeout(15_000),
  });
  const status = response.status;
  if (status >= 300 && status < 400) {
   const location = response.headers.get("Location");
   await response.body?.cancel();
   let target = "unrecognized";
   if (location) {
    const url = new URL(location, `https://api.mistral.ai/v1/models/${MISTRAL_LARGE}`);
    if (url.href === `https://api.mistral.ai/v1/models/${MISTRAL_LARGE}/`) target = "same_model_slash";
    else if (url.origin === "https://api.mistral.ai") target = "same_origin_other";
    else target = "other_origin";
   }
   return jsonData(c, { connected: false, providerStatus: status, redirectTarget: target });
  }
  if (!response.ok) { await response.body?.cancel(); return jsonData(c, { connected: false, providerStatus: status }); }
  stage = "body";
  const reader = response.body?.getReader();
  if (!reader) return jsonData(c, { connected: false, reason: "invalid_model_response" });
  const chunks: Uint8Array[] = []; let size = 0;
  try {
   while (true) {
    const { done, value } = await reader.read(); if (done) break;
    size += value.byteLength;
    if (size > 8192) { await reader.cancel(); return jsonData(c, { connected: false, reason: "invalid_model_response" }); }
    chunks.push(value);
   }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  stage = "json";
  const model: unknown = JSON.parse(new TextDecoder().decode(bytes));
  const valid = typeof model === "object" && model !== null && "id" in model && model.id === MISTRAL_LARGE;
  stage = "access";
  const after = await readJudgeAccess(rpc, scope.config, actor);
  if (!after || after.counterpartId !== fresh.counterpartId || after.accountKind !== fresh.accountKind || Date.now() >= deadline)
   return jsonError(c, "FORBIDDEN", "Review check unavailable");
  return jsonData(c, { connected: valid, providerStatus: status });
 } catch (error) {
  // Only fixed classifications leave the Worker; never expose exception text.
  const message = error instanceof Error ? error.message : "";
  const cause = error instanceof Error && ["AbortError", "TimeoutError"].includes(error.name) ? "timeout"
   : /redirect/i.test(message) ? "redirect_blocked"
   : /header/i.test(message) ? "invalid_header"
   : error instanceof TypeError ? "type_error" : "other_error";
  return jsonData(c, { connected: false, reason: "model_lookup_failed", stage, cause });
 }
});
/** One fixed synthetic text probe per new account, during the first 30 minutes only. */
route.post("/readiness", async c => {
 c.header("Cache-Control", "private, no-store");
 const scope = readJudgeAccessConfig(c.env), access = c.get("judge_access"), actor = c.get("user_id");
 if (scope.kind !== "active" || scope.config.ownerAiExpiresAtMs === undefined
  || !isJudgeAccessActive(access) || access.actorId !== actor || !members.has(actor)
  || !["judge", "owner"].includes(access.accountKind)) return jsonError(c, "FORBIDDEN", "Review check unavailable");
 const deadline = Math.min(scope.config.expiresAtMs, scope.config.issuedAtMs + 30 * 60_000);
 if (Date.now() >= deadline) return c.json({ code: "closed" }, 410);
 // The probe accepts no user content and never returns model output or credentials.
 if (c.req.raw.body !== null) {
  const reader = c.req.raw.body.getReader();
  try {
   const first = await reader.read();
   if (!first.done) { await reader.cancel(); return jsonError(c, "BAD_REQUEST", "Review check takes no input"); }
  } catch { return jsonError(c, "BAD_REQUEST", "Review check takes no input"); }
 }
 try {
  const rpc = judgeRpcClient(getSupabaseClient(c.env));
  const fresh = await readJudgeAccess(rpc, scope.config, actor);
  if (!fresh || fresh.counterpartId !== access.counterpartId || fresh.accountKind !== access.accountKind || Date.now() >= deadline)
   return jsonError(c, "FORBIDDEN", "Review check unavailable");
  // A new fixed receipt is used only for this reviewed transport repair; replays still cannot bill again.
  const reservation = await reserveJudgeProviderOperation(rpc, fresh, "personas_generate", transportV2Receipts.get(actor)!);
  if (!reservation || Date.now() >= deadline) return jsonError(c, "RATE_LIMITED", "Review check already used or unavailable");
  const maxRequestBytes = Math.min(32768, reservation.maxUnits - 8 - MISTRAL_REQUEST_TOKEN_OVERHEAD);
  if (maxRequestBytes < 1) return jsonError(c, "INTERNAL_ERROR", "Review check unavailable", 503);
  const result = await chatCompleteOnceBounded(c.env.MISTRAL_API_KEY, [{ role: "user", content: "Reply with exactly READY." }],
   { model: MISTRAL_LARGE, maxTokens: 8, temperature: 0, maxRequestBytes, maxResponseBytes: 4096, maxTotalTokenUnits: reservation.maxUnits });
  const after = await readJudgeAccess(rpc, scope.config, actor);
  if (!after || after.counterpartId !== fresh.counterpartId || after.accountKind !== fresh.accountKind
   || Date.now() >= deadline || result.content.trim() !== "READY") return jsonError(c, "INTERNAL_ERROR", "Review check unavailable", 503);
  return jsonData(c, { ready: true });
 } catch { return jsonError(c, "INTERNAL_ERROR", "Review check unavailable", 503); }
});
export default route;
