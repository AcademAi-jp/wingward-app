import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
import { SYNTHETIC_MATCHING_PROFILE_IDS as ids, SYNTHETIC_MATCHING_EXPIRES_AT } from "../services/synthetic-matching-cohort";
const state = vi.hoisted(() => ({ signIn: vi.fn() }));
vi.mock("../db/client", () => ({ getSupabaseAuthClient: () => ({ auth: { signInWithPassword: state.signIn } }) }));
import route from "./synthetic-session";
const app = new Hono<Env>().route("/api/testing", route);
const env = { PRODUCTION_E2E_PROFILE_IDS: "11111111-1111-4111-8111-111111111111", PRODUCTION_E2E_EXPIRES_AT: SYNTHETIC_MATCHING_EXPIRES_AT, PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS: ids.join(",") };
const password = "synthetic-test-password-only";
const request = (body: unknown, bindings: Record<string, string> = env) => app.request("/api/testing/synthetic-session", { method: "POST", body: JSON.stringify(body) }, bindings);
beforeEach(() => { state.signIn.mockReset(); vi.useFakeTimers(); vi.setSystemTime(new Date("2026-09-22T09:00:00Z")); });
afterEach(() => { vi.useRealTimers(); });
describe("temporary synthetic password session", () => {
  it("requires opt-in even when mounted without the application gate", async () => {
    expect((await request({ profile_id: ids[0], password }, {})).status).toBe(403);
    expect(state.signIn).not.toHaveBeenCalled();
  });
  it("cannot log in ordinary profiles or accept an email override", async () => {
    expect((await request({ profile_id: env.PRODUCTION_E2E_PROFILE_IDS, password })).status).toBe(400);
    expect((await request({ profile_id: ids[0], password, email: "other@example.invalid" })).status).toBe(400);
    expect(state.signIn).not.toHaveBeenCalled();
  });
  it("rejects provider failure and mismatched identity without leaking credentials", async () => {
    state.signIn.mockResolvedValue({ data: { user: { id: ids[1] }, session: { access_token: "must-not-return" } }, error: null });
    const response = await request({ profile_id: ids[0], password });
    expect(response.status).toBe(401);
    expect(await response.text()).not.toContain("must-not-return");
  });
  it("returns only the authenticated synthetic access token, with no-store", async () => {
    state.signIn.mockResolvedValue({ data: { user: { id: ids[0] }, session: { access_token: "synthetic-test-token", refresh_token: "never-return" } }, error: null });
    const response = await request({ profile_id: ids[0], password });
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.json()).toEqual({ data: { access_token: "synthetic-test-token" } });
  });
  it("closes while awaiting authentication across the deadline", async () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date(Date.parse(SYNTHETIC_MATCHING_EXPIRES_AT) - 1000));
    state.signIn.mockImplementation(async () => {
      vi.setSystemTime(new Date(SYNTHETIC_MATCHING_EXPIRES_AT));
      return { data: { user: { id: ids[0] }, session: { access_token: "must-not-return" } }, error: null };
    });
    try { expect((await request({ profile_id: ids[0], password })).status).toBe(401); }
    finally { vi.useRealTimers(); }
  });
});
