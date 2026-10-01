import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createRevenueCatWebhookRoute } from "./revenuecat-webhook";
import { readJudgeWebhookAccess } from "../services/judge-access";
const NOW = Date.parse("2026-09-30T20:00:00Z"), AUTH_ID = "11111111-1111-4111-8111-111111111111", ACTOR = "22222222-2222-4222-8222-222222222222";
const registry = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock("../db/client", () => ({ getSupabaseClient: () => registry }));
const config = { issuedAtMs: NOW - 1000, expiresAtMs: Date.parse("2026-10-13T19:00:00Z"), aiExpiresAtMs: Date.parse("2026-10-01T00:00:00Z") };
const member = { outcome: "allowed", auth_user_id: AUTH_ID, actor_user_id: ACTOR, account_kind: "judge", expires_at: "2026-10-13T19:00:00+00:00" };
const env = { REVENUECAT_WEBHOOK_SECRET: "test-hmac", REVENUECAT_WEBHOOK_AUTHORIZATION: "Bearer test-only", JUDGE_ACCESS_ENABLED: "enabled", JUDGE_ACCESS_COHORT: ["shipaton", "20261001"].join("-"), JUDGE_ACCESS_ISSUED_AT: "2026-09-30T18:00:00Z", JUDGE_ACCESS_EXPIRES_AT: "2026-10-13T19:00:00Z", JUDGE_ACCESS_AI_EXPIRES_AT: "2026-10-01T00:00:00Z" };
const body = (change: Record<string, unknown> = {}) => JSON.stringify({ event: { id: "judge-test", type: "INITIAL_PURCHASE", app_user_id: AUTH_ID, product_id: "wingward_premium_monthly", entitlement_ids: ["premium"], environment: "SANDBOX", store: "TEST_STORE", event_timestamp_ms: NOW, expiration_at_ms: NOW + 10000, ...change } });
async function signature(raw: string) { const t = NOW / 1000; const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.REVENUECAT_WEBHOOK_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]); const bytes = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${raw}`))); return `t=${t},v1=${[...bytes].map(b => b.toString(16).padStart(2,"0")).join("")}`; }
function app() { const billing = { rpc: vi.fn(async () => ({ data: [{ result_status: "processed", resolved_user_id: ACTOR, entitlement_was_applied: true, credit_was_granted: false }], error: null })) }; const router = new Hono(); router.route("/hook", createRevenueCatWebhookRoute({ nowMs: () => NOW, database: billing })); return { router, billing }; }
async function post(raw = body(), headers = {}, bindings = env) { const a = app(); const response = await a.router.request("/hook", { method: "POST", headers: { Authorization: env.REVENUECAT_WEBHOOK_AUTHORIZATION, "X-RevenueCat-Webhook-Signature": await signature(raw), ...headers }, body: raw }, bindings); return { ...a, response }; }
beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(NOW); registry.rpc.mockReset().mockResolvedValue({ data: [member], error: null }); });
afterEach(() => vi.useRealTimers());
describe("judge Test Store webhook", () => {
 it("requires valid exact Authorization and HMAC before registry or billing", async () => { for (const headers of [{ Authorization: "Bearer wrong" }, { "X-RevenueCat-Webhook-Signature": "t=1,v1=bad" }]) { const r = await post(body(), headers); expect(r.response.status).toBe(401); expect(registry.rpc).not.toHaveBeenCalled(); expect(r.billing.rpc).not.toHaveBeenCalled(); } });
 it.each([{ environment: "PRODUCTION" }, { store: "APP_STORE" }, { store: "PLAY_STORE" }, { app_user_id: "anonymous" }])("rejects out-of-scope purchase %j", async change => { const r = await post(body(change)); expect(r.response.status).toBe(403); expect(r.billing.rpc).not.toHaveBeenCalled(); });
 it("maps only exact auth identity through private registry then normal billing RPC", async () => { const r = await post(); expect(r.response.status).toBe(200); expect(registry.rpc).toHaveBeenCalledWith("check_judge_webhook_access", { p_auth_user_id: AUTH_ID }); expect(r.billing.rpc).toHaveBeenCalledTimes(1); });
 it.each([{ ...member, auth_user_id: ACTOR }, { ...member, outcome: "denied" }, { ...member, expires_at: "2026-09-30T19:00:00Z" }])("never bills a revoked or mismapped registry identity", async row => { registry.rpc.mockResolvedValue({ data: [row], error: null }); const r = await post(); expect(r.response.status).toBe(403); expect(r.billing.rpc).not.toHaveBeenCalled(); });
 it("diagnostic SANDBOX TEST acknowledges without registry or billing mutation", async () => { const r = await post(body({ type: "TEST" })); expect(r.response.status).toBe(200); expect(registry.rpc).not.toHaveBeenCalled(); expect(r.billing.rpc).not.toHaveBeenCalled(); });
 it("closes malformed judge configuration before billing", async () => { const r = await post(body(), {}, { ...env, JUDGE_ACCESS_COHORT: "other" }); expect(r.response.status).toBe(403); expect(r.billing.rpc).not.toHaveBeenCalled(); });
});
describe("judge webhook registry helper", () => {
 it.each([null, [], [member, member], { ...member, actor_user_id: "canary" }, { ...member, account_kind: "customer" }, { ...member, expires_at: "2026-10-14T19:00:00Z" }])("fails closed on malformed data", async data => { registry.rpc.mockResolvedValue({ data, error: null }); expect(await readJudgeWebhookAccess(registry, config, AUTH_ID, () => NOW)).toBe(false); });
 it.each(["qa", "owner"])("applies owner QA deadline to %s billing identity", async account_kind => { registry.rpc.mockResolvedValue({ data: [{ ...member, account_kind }], error: null }); expect(await readJudgeWebhookAccess(registry, config, AUTH_ID, () => config.aiExpiresAtMs)).toBe(false); });
 it("fails closed on DB exceptions without unsafe detail", async () => { registry.rpc.mockRejectedValue(new Error("PRIVATE-CANARY")); expect(await readJudgeWebhookAccess(registry, config, AUTH_ID, () => NOW)).toBe(false); });
});
