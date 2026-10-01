import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
import { readRecordingRehearsalConfig, type RecordingRehearsalPair, type ValidatedRecordingRehearsalConfig } from "../services/recording-rehearsal";

const AOI_ID = "96b31c0a-b8c4-4536-ada2-f3537dadd146";
const REN_ID = "9d836fee-7b93-41ce-b577-34a63006aaea";
const SORA_ID = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";
const WINGFOX_ID = "40000000-0000-4000-8000-000000000001";
const WINGFOX_SECTIONS = ["core_identity", "communication_rules", "personality_profile", "interests", "values", "romance_style", "conversation_references", "constraints"];

const mocks = vi.hoisted(() => ({
  getSupabaseClient: vi.fn(),
  executeMatching: vi.fn(),
}));

vi.mock("../middleware/auth", () => ({
  requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
    c.set("user_id", c.req.header("x-test-user") ?? "d327a193-9eeb-42b1-bac4-fb5bea3ca21f");
    await next();
  },
}));
vi.mock("../db/client", () => ({ getSupabaseClient: (...args: unknown[]) => mocks.getSupabaseClient(...args) }));
vi.mock("../services/matching", () => ({ executeMatching: (...args: unknown[]) => mocks.executeMatching(...args) }));

import profiles from "./profiles";

type Update = { table: string; payload: Record<string, unknown>; filters: Array<[string, unknown]> };
type Trace = { table: string; operation: "read" | "update"; filters: Array<[string, unknown]> };
type QueryResult = { data: unknown; error: unknown };
type FakeOptions = {
  personaPresent?: boolean;
  preferenceMode?: string;
  completedPersonaCount?: number;
  draftPresent?: boolean;
  completeWingfoxSections?: boolean;
  afterAwait?: (table: string, operation: "read" | "update") => void;
};

function rehearsalConfig(pair: RecordingRehearsalPair, now = Date.now(), expiresAtMs = now + 30 * 60_000): ValidatedRecordingRehearsalConfig {
  const result = readRecordingRehearsalConfig({
    RECORDING_REHEARSAL_ENABLED: "enabled",
    RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 60_000).toISOString(),
    RECORDING_REHEARSAL_EXPIRES_AT: new Date(expiresAtMs).toISOString(),
    RECORDING_REHEARSAL_PAIR: pair,
  }, now);
  if (result.kind !== "active") throw new Error("Expected active test rehearsal configuration");
  return result.config;
}

function envFor(config?: ValidatedRecordingRehearsalConfig, overrides: Partial<Env["Bindings"]> = {}) {
  return {
    SUPABASE_URL: "https://synthetic.invalid",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-test-only",
    ...(config ? {
      RECORDING_REHEARSAL_ENABLED: "enabled",
      RECORDING_REHEARSAL_ISSUED_AT: config.issuedAt,
      RECORDING_REHEARSAL_EXPIRES_AT: config.expiresAt,
      RECORDING_REHEARSAL_PAIR: config.pair,
    } : {}),
    ...overrides,
  };
}

function makeConfirmSupabase(options: FakeOptions = {}) {
  const updates: Update[] = [];
  const traces: Trace[] = [];
  const client = {
    from(table: string) {
      const trace: Trace = { table, operation: "read", filters: [] };
      traces.push(trace);
      const query: Record<string, unknown> = {};
      query.select = () => query;
      query.eq = (column: string, value: unknown) => { trace.filters.push([column, value]); return query; };
      query.update = (payload: Record<string, unknown>) => {
        trace.operation = "update";
        updates.push({ table, payload, filters: trace.filters });
        return query;
      };
      query.maybeSingle = async (): Promise<QueryResult> => {
        options.afterAwait?.(table, trace.operation);
        if (table === "personas") {
          return options.personaPresent === false
            ? { data: null, error: null }
            : { data: { id: WINGFOX_ID, user_id: SORA_ID, persona_type: "wingfox" }, error: null };
        }
        if (table === "profiles") {
          return options.draftPresent === false
            ? { data: null, error: null }
            : { data: { id: "50000000-0000-4000-8000-000000000001", user_id: SORA_ID, status: "draft" }, error: null };
        }
        if (table === "user_profiles") return { data: { preference_mode: options.preferenceMode ?? "selected" }, error: null };
        return { data: null, error: null };
      };
      query.then = (resolve: (value: QueryResult) => unknown, reject?: (reason: unknown) => unknown) => {
        options.afterAwait?.(table, trace.operation);
        const result = table === "speed_dating_sessions"
          ? { data: Array.from({ length: options.completedPersonaCount ?? 3 }, (_, index) => ({
            id: `60000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
            user_id: SORA_ID,
            persona_id: `70000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
            status: "completed",
          })), error: null }
          : table === "persona_sections"
            ? { data: WINGFOX_SECTIONS
              .filter((section) => options.completeWingfoxSections !== false || section !== "constraints")
              .map((section_id) => ({ section_id, content: "synthetic-section" })), error: null }
            : { data: null, error: null };
        return Promise.resolve(result).then(resolve, reject);
      };
      return query;
    },
  };
  return { client, updates, traces };
}

function buildApp(config?: ValidatedRecordingRehearsalConfig) {
  const app = new Hono<Env>();
  app.use("*", async (c, next) => {
    if (config) {
      c.set("recording_rehearsal", config);
      c.set("production_e2e_active", true);
      c.set("production_e2e_synthetic", false);
    }
    await next();
  });
  app.route("/api/profiles", profiles);
  return app;
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.executeMatching.mockResolvedValue(0);
});

describe("POST /api/profiles/me/confirm recording rehearsal boundary", () => {
  it("confirms Sora's existing owner-reviewed draft after the third interview without starting matching", async () => {
    const config = rehearsalConfig("sora-ren");
    const supabase = makeConfirmSupabase({ preferenceMode: "selected" });
    mocks.getSupabaseClient.mockReturnValue(supabase.client as never);
    const response = await buildApp(config).request("/api/profiles/me/confirm", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ basic_info: { name: "must be ignored" }, admin_confirm: true }),
    }, envFor(config));

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("private");
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(supabase.traces.find((trace) => trace.table === "personas")?.filters).toEqual([
      ["user_id", SORA_ID],
      ["persona_type", "wingfox"],
    ]);
    expect(supabase.updates).toEqual([
      expect.objectContaining({ table: "profiles", payload: expect.objectContaining({ status: "confirmed" }), filters: [["user_id", SORA_ID]] }),
      expect.objectContaining({ table: "user_profiles", payload: expect.objectContaining({ onboarding_status: "confirmed" }), filters: [["id", SORA_ID]] }),
    ]);
    expect(supabase.updates[0]?.payload).not.toHaveProperty("basic_info");
    expect(supabase.updates[0]?.payload).not.toHaveProperty("admin_confirm");
    expect(supabase.traces.some((trace) => trace.table === "user_profiles" && trace.operation === "read")).toBe(false);
    expect(supabase.updates.map(({ payload }) => payload)).not.toContainEqual(expect.objectContaining({ preference_mode: expect.anything() }));
    expect(mocks.executeMatching).not.toHaveBeenCalled();
  });

  it("keeps Sora's draft unconfirmed while the third interview is incomplete", async () => {
    const config = rehearsalConfig("sora-ren");
    const supabase = makeConfirmSupabase({ completedPersonaCount: 2 });
    mocks.getSupabaseClient.mockReturnValue(supabase.client as never);
    const response = await buildApp(config).request("/api/profiles/me/confirm", { method: "POST" }, envFor(config));

    expect(response.status).toBe(409);
    expect(supabase.updates).toHaveLength(0);
    expect(mocks.executeMatching).not.toHaveBeenCalled();
  });

  it("keeps Sora's draft unconfirmed if the saved AI partner is incomplete", async () => {
    const config = rehearsalConfig("sora-ren");
    const supabase = makeConfirmSupabase({ completeWingfoxSections: false });
    mocks.getSupabaseClient.mockReturnValue(supabase.client as never);
    const response = await buildApp(config).request("/api/profiles/me/confirm", { method: "POST" }, envFor(config));

    expect(response.status).toBe(409);
    expect(supabase.updates).toHaveLength(0);
  });

  it("rejects a cohort actor outside the configured generation pair before reading or writing", async () => {
    const config = rehearsalConfig("aoi-ren");
    const supabase = makeConfirmSupabase();
    mocks.getSupabaseClient.mockReturnValue(supabase.client as never);
    const response = await buildApp(config).request("/api/profiles/me/confirm", {
      method: "POST",
      headers: { "x-test-user": SORA_ID },
    }, envFor(config));

    expect(response.status).toBe(403);
    expect(supabase.traces).toHaveLength(0);
    expect(supabase.updates).toHaveLength(0);
    expect(mocks.executeMatching).not.toHaveBeenCalled();
  });

  it("fails closed for invalid raw rehearsal bindings without trusted middleware context", async () => {
    const response = await buildApp().request("/api/profiles/me/confirm", { method: "POST" }, envFor(undefined, {
      RECORDING_REHEARSAL_ENABLED: "enabled",
    }));

    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.getSupabaseClient).not.toHaveBeenCalled();
    expect(mocks.executeMatching).not.toHaveBeenCalled();
  });

  it("fails closed when the trusted configuration is expired", async () => {
    const now = Date.now();
    const current = rehearsalConfig("sora-ren", now, now + 30_000);
    const expired = {
      ...current,
      expiresAt: new Date(now - 1).toISOString(),
      expiresAtMs: now - 1,
    } as ValidatedRecordingRehearsalConfig;
    const response = await buildApp(expired).request("/api/profiles/me/confirm", { method: "POST" }, envFor(expired));

    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.getSupabaseClient).not.toHaveBeenCalled();
    expect(mocks.executeMatching).not.toHaveBeenCalled();
  });

  it("stops before profile writes if the expiry crosses while checking the persona", async () => {
    const now = Date.now();
    const config = rehearsalConfig("sora-ren", now, now + 30_000);
    vi.useFakeTimers();
    vi.setSystemTime(now);
    const supabase = makeConfirmSupabase({
      afterAwait: (table, operation) => {
        if (table === "personas" && operation === "read") vi.setSystemTime(config.expiresAtMs);
      },
    });
    mocks.getSupabaseClient.mockReturnValue(supabase.client as never);
    try {
      const response = await buildApp(config).request("/api/profiles/me/confirm", { method: "POST" }, envFor(config));
      expect(response.status).toBe(503);
      expect(supabase.updates).toHaveLength(0);
      expect(mocks.executeMatching).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("stops before the next write if expiry crosses after profile confirmation", async () => {
    const now = Date.now();
    const config = rehearsalConfig("sora-ren", now, now + 30_000);
    vi.useFakeTimers();
    vi.setSystemTime(now);
    const supabase = makeConfirmSupabase({
      afterAwait: (table, operation) => {
        if (table === "profiles" && operation === "update") vi.setSystemTime(config.expiresAtMs);
      },
    });
    mocks.getSupabaseClient.mockReturnValue(supabase.client as never);
    try {
      const response = await buildApp(config).request("/api/profiles/me/confirm", { method: "POST" }, envFor(config));
      expect(response.status).toBe(503);
      expect(supabase.updates.map((update) => update.table)).toEqual(["profiles"]);
      expect(mocks.executeMatching).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("preserves the ordinary absent-recording behavior", async () => {
    const supabase = makeConfirmSupabase();
    mocks.getSupabaseClient.mockReturnValue(supabase.client as never);
    const response = await buildApp().request("/api/profiles/me/confirm", { method: "POST" }, envFor());

    expect(response.status).toBe(200);
    expect(supabase.updates.map((update) => update.table)).toEqual(["profiles", "user_profiles"]);
    expect(mocks.executeMatching).toHaveBeenCalledTimes(1);
  });
});


describe("judge exact pair profile confirmation", () => {
  it("starts matching only with registry actor and counterpart and an expiry write guard", async () => {
    const client = makeConfirmSupabase();
    mocks.getSupabaseClient.mockReturnValue(client.client);
    const access = { actorId: SORA_ID, counterpartId: REN_ID, accountKind: "judge" as const, expiresAtMs: Date.now() + 30_000 };
    const app = new Hono<Env>();
    app.use("*", async (c, next) => { c.set("judge_access", access); await next(); });
    app.route("/api/profiles", profiles);
    expect((await app.request("/api/profiles/me/confirm", { method: "POST" }, envFor())).status).toBe(200);
    expect(mocks.executeMatching).toHaveBeenCalledWith(client.client, 1, undefined, expect.objectContaining({ profileIds: [SORA_ID, REN_ID], actorId: SORA_ID, mode: "start" }));
    const scope = mocks.executeMatching.mock.calls[0]?.[3] as { canWrite: () => boolean };
    expect(scope.canWrite()).toBe(true);
    access.expiresAtMs = Date.now() - 1;
    expect(scope.canWrite()).toBe(false);
  });
  it("rejects a mismatched trusted judge actor before draft or persona writes", async () => {
    const client = makeConfirmSupabase();
    mocks.getSupabaseClient.mockReturnValue(client.client);
    const app = new Hono<Env>();
    app.use("*", async (c, next) => { c.set("judge_access", { actorId: AOI_ID, counterpartId: REN_ID, accountKind: "judge", expiresAtMs: Date.now() + 30_000 }); await next(); });
    app.route("/api/profiles", profiles);
    expect((await app.request("/api/profiles/me/confirm", { method: "POST" }, envFor())).status).toBe(403);
    expect(client.traces).toEqual([]);
    expect(mocks.executeMatching).not.toHaveBeenCalled();
  });
});
