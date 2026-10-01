import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
import type { ChatMeetupProviders } from "../services/chat-meetup";
import { isGoogleCafeReferenceProvider } from "../services/chat-meetup-providers";
import { readRecordingRehearsalConfig, type ValidatedRecordingRehearsalConfig } from "../services/recording-rehearsal";

const USER_ID = "96b31c0a-b8c4-4536-ada2-f3537dadd146";
const ROOM_ID = "40000000-0000-4000-8000-000000000001";

vi.mock("../middleware/auth", () => ({
  requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => { c.set("user_id", c.req.header("x-test-user") ?? USER_ID); await next(); },
  requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => next(),
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn(() => ({})) }));
const getState = vi.fn();
const applyAction = vi.fn();
const getWardHistory = vi.fn();
vi.mock("../services/chat-meetup", async (importOriginal) => {
  const original = await importOriginal<typeof import("../services/chat-meetup")>();
  return {
    ...original,
    getChatMeetupState: (...args: unknown[]) => getState(...args),
    applyChatMeetupAction: (...args: unknown[]) => applyAction(...args),
    getChatWardConversation: (...args: unknown[]) => getWardHistory(...args),
  };
});

import chatMeetups from "./chat-meetups";

function makeApp(config?: ValidatedRecordingRehearsalConfig) {
  const app = new Hono<Env>();
  app.use("/api/chat-meetups/*", async (c, next) => {
    if (config) c.set("recording_rehearsal", config);
    await next();
  });
  app.route("/api/chat-meetups", chatMeetups);
  return app;
}
function requestEnv(flag?: string, googleEnabled?: string, googleKey?: string) {
  return {
    CHAT_MEETUP_ENABLED: flag,
    GOOGLE_CAFE_SEARCH_ENABLED: googleEnabled,
    GOOGLE_MAPS_PLATFORM_API_KEY: googleKey,
    SUPABASE_URL: "https://example.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-test-only",
  };
}
function activeRehearsalConfig(): ValidatedRecordingRehearsalConfig {
  const now = Date.now();
  const result = readRecordingRehearsalConfig({
    RECORDING_REHEARSAL_ENABLED: "enabled",
    RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 60_000).toISOString(),
    RECORDING_REHEARSAL_EXPIRES_AT: new Date(now + 60 * 60_000).toISOString(),
    RECORDING_REHEARSAL_PAIR: "aoi-ren",
  }, now);
  if (result.kind !== "active") throw new Error("Expected active test rehearsal");
  return result.config;
}
const TEST_STATE = {
  room_id: ROOM_ID, meetup_id: null, revision: 0, status: "idle", events: [], time_candidates: [],
  own_permissions: {}, own_decisions: { intent_value: "yes", time_candidate_id: null,  completed: false, private_revision: 1 },
   expires_at: null,
};
function mockState() { getState.mockResolvedValue({ ok: true, state: TEST_STATE }); }
function requestedProviders(): ChatMeetupProviders | undefined {
  const calls = getState.mock.calls;
  return (calls[calls.length - 1]?.[3] as { providers?: ChatMeetupProviders } | undefined)?.providers;
}
beforeEach(() => { vi.clearAllMocks(); });

describe("Chat meetup routes", () => {
  it.each(["true", "enabled ", undefined])("keeps the route closed unless the exact rollout value is enabled (%s)", async (flag) => {
    const response = await makeApp().request("/api/chat-meetups/rooms/" + ROOM_ID, {}, requestEnv(flag));
    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(getState).not.toHaveBeenCalled();
  });

  it("keeps cafe operations closed even with opt-in, key, and trusted context", async () => {
    mockState();
    const response = await makeApp(activeRehearsalConfig()).request(
      "/api/chat-meetups/rooms/" + ROOM_ID,
      {},
      requestEnv("enabled", "enabled", "synthetic-google-key"),
    );
    expect(response.status).toBe(200);
    const providers = requestedProviders();
    expect(providers?.recordingRehearsalConfig?.pair).toBe("aoi-ren");
    expect(providers?.cafe.availability).toBe("unavailable");
    if (providers) expect(isGoogleCafeReferenceProvider(providers.cafe)).toBe(false);

    const postState = { ...TEST_STATE, status: "awaiting_availability" };
    applyAction.mockResolvedValue({ ok: true, state: postState });
    const action = await makeApp(activeRehearsalConfig()).request(
      "/api/chat-meetups/rooms/" + ROOM_ID + "/actions",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ idempotency_key: "70000000-0000-4000-8000-000000000011", expected_revision: 1, expected_own_revision: 1, action: { type: "intent", value: "yes" } }),
      },
      requestEnv("enabled", "enabled", "synthetic-google-key"),
    );
    expect(action.status).toBe(200);
    const actionOptions = applyAction.mock.calls[0]?.[4] as { providers?: ChatMeetupProviders } | undefined;
    expect(actionOptions?.providers?.cafe.availability).toBe("unavailable");

    mockState();
    const absentContext = await makeApp().request(
      "/api/chat-meetups/rooms/" + ROOM_ID,
      {},
      requestEnv("enabled", "enabled", "synthetic-google-key"),
    );
    expect(absentContext.status).toBe(200);
    expect(requestedProviders()).toBeUndefined();
  });

  it.each([
    ["exact opt-in missing", undefined, "synthetic-google-key", USER_ID],
    ["opt-in is not exact", "true", "synthetic-google-key", USER_ID],
    ["server key missing", "enabled", undefined, USER_ID],
    ["user outside fixed cohort", "enabled", "synthetic-google-key", "22222222-2222-4222-8222-222222222222"],
  ])("keeps all cafe operations closed when %s", async (_label, googleEnabled, googleKey, userId) => {
    mockState();
    const response = await makeApp(activeRehearsalConfig()).request(
      "/api/chat-meetups/rooms/" + ROOM_ID,
      { headers: { "x-test-user": userId as string } },
      requestEnv("enabled", googleEnabled as string | undefined, googleKey as string | undefined),
    );
    expect(response.status).toBe(200);
    const provider = requestedProviders()?.cafe;
    expect(provider?.availability).toBe("unavailable");
    expect(provider ? isGoogleCafeReferenceProvider(provider) : false).toBe(false);
  });

  it("does not construct a paid provider from an expired trusted context", async () => {
    mockState();
    const active = activeRehearsalConfig();
    const expired = {
      ...active,
      expiresAt: new Date(Date.now() - 1).toISOString(),
      expiresAtMs: Date.now() - 1,
    } as ValidatedRecordingRehearsalConfig;
    const response = await makeApp(expired).request(
      "/api/chat-meetups/rooms/" + ROOM_ID,
      {},
      requestEnv("enabled", "enabled", "synthetic-google-key"),
    );
    expect(response.status).toBe(200);
    expect(requestedProviders()?.cafe.availability).toBe("unavailable");
  });

  it.each(["location.submit", "location.clear", "cafe.approve", "cafe.decline"])("rejects retired %s action before service entry", async (type) => {
    const response = await makeApp(activeRehearsalConfig()).request("/api/chat-meetups/rooms/" + ROOM_ID + "/actions", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 0, expected_own_revision: 0, action: { type, candidate_id: "retired" } }),
    }, requestEnv("enabled", "enabled", "synthetic-google-key"));
    expect(response.status).toBe(400);
    expect(applyAction).not.toHaveBeenCalled();
  });

  it("rejects a mismatched idempotency header before calling the service", async () => {
    const response = await makeApp().request("/api/chat-meetups/rooms/" + ROOM_ID + "/actions", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Idempotency-Key": "70000000-0000-4000-8000-000000000002" },
      body: JSON.stringify({ idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 0, expected_own_revision: 0, action: { type: "intent", value: "yes" } }),
    }, requestEnv("enabled"));
    expect(response.status).toBe(400);
    expect(applyAction).not.toHaveBeenCalled();
  });

  it("stops oversized request bodies while reading and never calls the write service", async () => {
    const response = await makeApp().request("/api/chat-meetups/rooms/" + ROOM_ID + "/actions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 0, expected_own_revision: 0, action: { type: "intent", value: "yes" }, filler: "x".repeat(40_000) }),
    }, requestEnv("enabled"));
    expect(response.status).toBe(400);
    expect(applyAction).not.toHaveBeenCalled();
  });

  it("returns the same state envelope for a successful POST and marks private responses no-store", async () => {
    const state = { room_id: ROOM_ID, meetup_id: null, revision: 0, status: "idle", events: [], time_candidates: [],  own_permissions: {}, own_decisions: { intent_value: "yes", time_candidate_id: null,  completed: false, private_revision: 1 },  expires_at: null };
    applyAction.mockResolvedValue({ ok: true, state });
    const response = await makeApp().request("/api/chat-meetups/rooms/" + ROOM_ID + "/actions", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 0, expected_own_revision: 0, action: { type: "intent", value: "yes" } }),
    }, requestEnv("enabled"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(await response.json()).toEqual({ data: state });
    expect(applyAction).toHaveBeenCalledOnce();
  });

  it("keeps Ward history behind the exact feature gate and disables caching", async () => {
    getWardHistory.mockResolvedValue({ ok: true, data: { room_id: ROOM_ID, events: [], next_cursor: null, has_more: false } });
    const response = await makeApp().request("/api/chat-meetups/rooms/" + ROOM_ID + "/ward-conversation", {}, requestEnv("enabled"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(getWardHistory).toHaveBeenCalledOnce();
  });
});
