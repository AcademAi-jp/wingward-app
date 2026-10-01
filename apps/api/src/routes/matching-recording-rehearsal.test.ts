import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
import { readRecordingRehearsalConfig, type ValidatedRecordingRehearsalConfig } from "../services/recording-rehearsal";

const USER_A = "96b31c0a-b8c4-4536-ada2-f3537dadd146";
const USER_B = "9d836fee-7b93-41ce-b577-34a63006aaea";
const USER_C = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";
const MATCH_ID = "20000000-0000-4000-8000-000000000001";
const CONVERSATION_ID = "30000000-0000-4000-8000-000000000001";

const mocks = vi.hoisted(() => ({
  getSupabaseClient: vi.fn(),
  filterVerifiedMatches: vi.fn(),
  readMatchingCurrentSnapshot: vi.fn(),
  getProfilePhotoAdapter: vi.fn(),
  signPhoto: vi.fn(),
}));

vi.mock("../middleware/auth", () => ({
  requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
    c.set("user_id", c.req.header("x-test-user") ?? "96b31c0a-b8c4-4536-ada2-f3537dadd146");
    await next();
  },
  requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => next(),
}));
vi.mock("../db/client", () => ({ getSupabaseClient: (...args: unknown[]) => mocks.getSupabaseClient(...args) }));
vi.mock("../services/match-age-access", () => ({
  checkVerifiedPair: vi.fn(async () => ({ ok: true })),
  filterVerifiedMatches: (...args: unknown[]) => mocks.filterVerifiedMatches(...args),
}));
vi.mock("../services/matching-current-access", () => ({
  MAX_MATCHING_CURRENT_SNAPSHOT_EXPECTATIONS: 128,
  readMatchingCurrentSnapshot: (...args: unknown[]) => mocks.readMatchingCurrentSnapshot(...args),
}));
vi.mock("../services/onboarding-settings", () => ({
  getProfilePhotoAdapter: (...args: unknown[]) => mocks.getProfilePhotoAdapter(...args),
}));

import matching from "./matching";

const MATCH_ROW = {
  id: MATCH_ID,
  user_a_id: USER_A,
  user_b_id: USER_B,
  final_score: 91,
  profile_score: 88,
  conversation_score: 94,
  status: "fox_conversation_completed",
  score_details: { summary: "synthetic test result" },
};
const CURRENT_SNAPSHOT = {
  ...MATCH_ROW,
  layer_scores: {},
  created_at: "2026-09-01T00:00:00.000Z",
  profile_a: { id: USER_A, nickname: "Aoi", avatar_url: null, avatar_storage_path: null },
  profile_b: {
    id: USER_B,
    nickname: "Ren",
    avatar_url: null,
    avatar_storage_path: `profile-photos/${USER_B}/rehearsal.png`,
  },
  compatibilityConversation: {
    id: CONVERSATION_ID,
    match_id: MATCH_ID,
    purpose: "compatibility" as const,
    status: "completed",
  },
};

type Trace = { table: string; filters: Array<[string, unknown]>; select?: string };
type DbResult = { data: unknown; error: unknown };

function activeConfig(now = Date.now(), expiresAtMs = now + 30 * 60_000): ValidatedRecordingRehearsalConfig {
  const result = readRecordingRehearsalConfig({
    RECORDING_REHEARSAL_ENABLED: "enabled",
    RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 60_000).toISOString(),
    RECORDING_REHEARSAL_EXPIRES_AT: new Date(expiresAtMs).toISOString(),
    RECORDING_REHEARSAL_PAIR: "aoi-ren",
  }, now);
  if (result.kind !== "active") throw new Error("Expected active synthetic test rehearsal");
  return result.config;
}

function makeSupabase(matchRows: unknown[] = [MATCH_ROW]) {
  const traces: Trace[] = [];
  const from = (table: string) => {
    const trace: Trace = { table, filters: [] };
    traces.push(trace);
    const query: Record<string, unknown> = {};
    query.select = (columns: string) => { trace.select = columns; return query; };
    for (const method of ["eq", "or", "in", "order", "lt", "is"]) {
      query[method] = (column: string, value?: unknown) => {
        trace.filters.push([`${method}:${column}`, value]);
        return query;
      };
    }
    query.limit = (value: number) => {
      trace.filters.push(["limit", value]);
      return query;
    };
    query.then = (resolve: (value: DbResult) => unknown, reject?: (reason: unknown) => unknown) => {
      let data: unknown;
      if (table === "matches") data = matchRows;
      else if (table === "blocks" || table === "daily_match_pairs") data = [];
      else if (table === "user_profiles") data = [{ id: USER_B, nickname: "Ren", avatar_url: null }];
      else if (table === "personas") data = [{ user_id: USER_B, icon_url: "https://assets.invalid/ren.png" }];
      else if (table === "fox_conversations") data = [{ id: CONVERSATION_ID, match_id: MATCH_ID, purpose: "compatibility", status: "completed" }];
      else throw new Error(`Unexpected test table: ${table}`);
      return Promise.resolve({ data, error: null }).then(resolve, reject);
    };
    return query;
  };
  return { client: { from }, traces };
}

function buildApp(config?: ValidatedRecordingRehearsalConfig) {
  const app = new Hono<Env>();
  app.use("/api/matching/*", async (c, next) => {
    if (config) c.set("recording_rehearsal", config);
    await next();
  });
  app.route("/api/matching", matching);
  return app;
}

function requestEnv() {
  return { SUPABASE_URL: "https://synthetic.invalid", SUPABASE_SERVICE_ROLE_KEY: "synthetic-test-only", BATCH_TIMEZONE: "Asia/Tokyo" };
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.filterVerifiedMatches.mockImplementation(async (_client: unknown, rows: unknown[]) => ({ ok: true, rows }));
  mocks.readMatchingCurrentSnapshot.mockResolvedValue({ ok: true, rows: new Map([[MATCH_ID, CURRENT_SNAPSHOT]]) });
  mocks.signPhoto.mockResolvedValue("https://storage.invalid/signed/rehearsal.png");
  mocks.getProfilePhotoAdapter.mockReturnValue({ storage: { createOwnerReadUrl: mocks.signPhoto } });
  mocks.getSupabaseClient.mockReturnValue(makeSupabase().client);
});

describe("recording rehearsal matching daily results", () => {
  it("returns only the exact persisted pair without requiring a daily batch row", async () => {
    const { client, traces } = makeSupabase([MATCH_ROW]);
    mocks.getSupabaseClient.mockReturnValue(client);
    const response = await buildApp(activeConfig()).request(
      "/api/matching/daily-results?date=2001-01-01",
      {},
      requestEnv(),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("private");
    expect(response.headers.get("cache-control")).toContain("no-store");
    const body = await response.json() as { data: Record<string, unknown> };
    expect(body.data).toMatchObject({
      batch_status: "rehearsal",
      matches: [{ id: MATCH_ID, partner_id: USER_B }],
      is_new: false,
      total_matches: 1,
      conversations_completed: 1,
      conversations_failed: 0,
    });
    expect(body.data.batch_date).not.toBe("2001-01-01");
    expect(traces.map((trace) => trace.table)).not.toContain("daily_match_pairs");
    const pairRead = traces.find((trace) => trace.table === "matches");
    expect(pairRead?.filters).toContainEqual(["eq:user_a_id", USER_A]);
    expect(pairRead?.filters).toContainEqual(["eq:user_b_id", USER_B]);
    expect(pairRead?.filters).toContainEqual(["limit", 2]);
    expect(mocks.filterVerifiedMatches).toHaveBeenCalledTimes(1);
    expect(mocks.readMatchingCurrentSnapshot).toHaveBeenCalledWith(client, [{
      matchId: MATCH_ID,
      ownerId: USER_A,
      participantIds: [USER_A, USER_B],
    }]);
    expect(traces.find((trace) => trace.table === "blocks")?.filters).toContainEqual([
      "or:and(blocker_id.eq." + USER_A + ",blocked_id.eq." + USER_B + "),and(blocker_id.eq." + USER_B + ",blocked_id.eq." + USER_A + ")",
      undefined,
    ]);
    expect(mocks.signPhoto).toHaveBeenCalledWith(USER_B, `profile-photos/${USER_B}/rehearsal.png`, 300);
  });

  it("does not expose the configured match to a nonmember actor", async () => {
    const { client, traces } = makeSupabase([MATCH_ROW]);
    mocks.getSupabaseClient.mockReturnValue(client);
    const response = await buildApp(activeConfig()).request(
      "/api/matching/daily-results?date=2001-01-01",
      { headers: { "x-test-user": USER_C } },
      requestEnv(),
    );
    expect(response.status).toBe(200);
    const body = await response.json() as { data: { matches: unknown[]; batch_status: string } };
    expect(body.data).toMatchObject({ matches: [], batch_status: "rehearsal" });
    expect(traces).toHaveLength(0);
    expect(mocks.readMatchingCurrentSnapshot).not.toHaveBeenCalled();
  });

  it("keeps the absent-context daily result path unchanged", async () => {
    const { client, traces } = makeSupabase();
    mocks.getSupabaseClient.mockReturnValue(client);
    const response = await buildApp().request("/api/matching/daily-results?date=2001-01-01", {}, requestEnv());
    expect(response.status).toBe(200);
    const body = await response.json() as { data: { batch_date: string; batch_status: string; matches: unknown[] } };
    expect(body.data).toMatchObject({ batch_date: "2001-01-01", batch_status: "completed", matches: [] });
    expect(traces[0]?.table).toBe("daily_match_pairs");
    expect(mocks.readMatchingCurrentSnapshot).not.toHaveBeenCalled();
  });

  it("returns a generic no-store unavailable response if expiry crosses the snapshot await", async () => {
    const now = Date.now();
    const config = activeConfig(now, now + 30_000);
    const { client } = makeSupabase([MATCH_ROW]);
    mocks.getSupabaseClient.mockReturnValue(client);
    vi.useFakeTimers();
    vi.setSystemTime(now);
    mocks.readMatchingCurrentSnapshot.mockImplementationOnce(async () => {
      vi.setSystemTime(config.expiresAtMs);
      return { ok: true, rows: new Map([[MATCH_ID, CURRENT_SNAPSHOT]]) };
    });
    try {
      const response = await buildApp(config).request("/api/matching/daily-results", {}, requestEnv());
      expect(response.status).toBe(503);
      expect(response.headers.get("cache-control")).toContain("private");
      expect(response.headers.get("cache-control")).toContain("no-store");
      expect(mocks.signPhoto).not.toHaveBeenCalled();
    } finally {
      vi.useRealTimers();
    }
  });

  it("hides raw errors from awaited rehearsal reads", async () => {
    const { client } = makeSupabase([MATCH_ROW]);
    mocks.getSupabaseClient.mockReturnValue(client);
    mocks.readMatchingCurrentSnapshot.mockRejectedValueOnce(new Error("synthetic database detail"));
    const response = await buildApp(activeConfig()).request("/api/matching/daily-results", {}, requestEnv());
    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(await response.text()).not.toContain("synthetic database detail");
  });
});
