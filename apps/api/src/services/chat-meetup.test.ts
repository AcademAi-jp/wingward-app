import { describe, expect, it, vi } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { applyChatMeetupAction, chatMeetupActionRequestSchema, getChatMeetupState, checkChatMeetupRoomAccess } from "./chat-meetup";
import type { GoogleCafeReferenceProvider } from "./chat-meetup-providers";
import { searchFairCafeCandidates, isGoogleCafeReferenceProvider, unavailableGoogleCafeReferenceProvider, unavailableCafeSearchProvider } from "./chat-meetup-providers";
import { readRecordingRehearsalConfig, type RecordingRehearsalPair } from "./recording-rehearsal";

const USER_A = "96b31c0a-b8c4-4536-ada2-f3537dadd146";
const USER_B = "9d836fee-7b93-41ce-b577-34a63006aaea";
const MATCH_ID = "20000000-0000-4000-8000-000000000001";
const ROOM_ID = "40000000-0000-4000-8000-000000000001";
const MEETUP_ID = "30000000-0000-4000-8000-000000000001";
const TIME_ID = "50000000-0000-4000-8000-000000000001";
const EVENT_ID = "60000000-0000-4000-8000-000000000001";

const eligibilityProfiles = [
  { id: USER_A, age_verified_at: "2026-09-01T00:00:00Z", gender_identity: "woman", preferred_genders: ["man"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-09-01T00:00:00Z" },
  { id: USER_B, age_verified_at: "2026-09-01T00:00:00Z", gender_identity: "man", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-09-01T00:00:00Z" },
];
const identityProfiles = [
  { id: USER_A, identity_verification_status: "verified", identity_verified_at: "2026-09-01T00:00:00Z" },
  { id: USER_B, identity_verification_status: "verified", identity_verified_at: "2026-09-01T00:00:00Z" },
];

type FixtureOptions = {
  decisionA?: Record<string, unknown> | null;
  decisionB?: Record<string, unknown> | null;
  session?: Record<string, unknown> | null;
  availability?: Record<string, unknown>[];
  locations?: Record<string, unknown>[];
  events?: Record<string, unknown>[];
  identityVerified?: boolean;
  identityNone?: boolean;
  rpc?: (name: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;
};

function rehearsalConfig(pair: RecordingRehearsalPair = "aoi-ren") {
  const now = Date.now();
  const result = readRecordingRehearsalConfig({
    RECORDING_REHEARSAL_ENABLED: "enabled",
    RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 60_000).toISOString(),
    RECORDING_REHEARSAL_EXPIRES_AT: new Date(now + 60 * 60_000).toISOString(),
    RECORDING_REHEARSAL_PAIR: pair,
  }, now);
  if (result.kind !== "active") throw new Error("Expected active test rehearsal");
  return result.config;
}

function fixture(options: FixtureOptions = {}, pair: readonly [string, string] = [USER_A, USER_B]) {
  const [userA, userB] = pair;
  const fixtureEligibilityProfiles = eligibilityProfiles.map(row => ({ ...row, id: row.id === USER_A ? userA : userB }));
  const fixtureIdentityProfiles = identityProfiles.map(row => ({ ...row, id: row.id === USER_A ? userA : userB, ...(options.identityNone ? { identity_verification_status: "none", identity_verified_at: null } : {}) }));
  const now = Date.now();
  const tables: Record<string, Record<string, unknown>[]> = {
    direct_chat_rooms: [{ id: ROOM_ID, match_id: MATCH_ID, status: "active" }],
    matches: [{ id: MATCH_ID, user_a_id: userA, user_b_id: userB, status: "direct_chat_active" }],
    user_profiles: [...fixtureEligibilityProfiles, ...(options.identityVerified === false ? fixtureIdentityProfiles.map((row) => ({ ...row, identity_verification_status: "pending" })) : fixtureIdentityProfiles)],
    blocks: [],
    chat_meetup_sessions: options.session ? [options.session] : [],
    chat_meetup_private_decisions: [],
    chat_meetup_availability: options.availability ?? [],
    chat_meetup_events: options.events ?? [],
    chat_meetup_locations: options.locations ?? [],
  };
  const decisions = [
    ...(options.decisionA ? [{ match_id: MATCH_ID, room_id: ROOM_ID, user_id: userA, intent_value: null, private_revision: 1, time_choice_id: null, cafe_choice_id: null, completed_at: null, ...options.decisionA }] : []),
    ...(options.decisionB ? [{ match_id: MATCH_ID, room_id: ROOM_ID, user_id: userB, intent_value: null, private_revision: 1, time_choice_id: null, cafe_choice_id: null, completed_at: null, ...options.decisionB }] : []),
  ];
  tables.chat_meetup_private_decisions = decisions;
  if (options.session) tables.chat_meetup_sessions = [options.session];
  const client = {
    from(table: string) {
      const filters: Array<[string, unknown]> = [];
      const inFilters: Array<[string, unknown[]]> = [];
      let selection = "";
      let orFilter: string | null = null;
      let limit = Number.POSITIVE_INFINITY;
      const query: Record<string, unknown> = {};
      query.select = (value = "") => { selection = value; return query; };
      query.eq = (column: string, value: unknown) => { filters.push([column, value]); return query; };
      query.in = (column: string, values: unknown[]) => { inFilters.push([column, values]); return query; };
      query.or = (value: string) => { orFilter = value; return query; };
      query.order = () => query;
      query.limit = (value: number) => { limit = value; return query; };
      const rowsForQuery = () => {
        if (table === "user_profiles" && selection.includes("age_verified_at")) {
          return fixtureEligibilityProfiles.filter((row) => inFilters.some(([column, values]) => column === "id" && values.includes(row.id)));
        }
        if (table === "user_profiles" && selection.includes("identity_verification_status")) {
          const identities = options.identityVerified === false ? fixtureIdentityProfiles.map((row) => ({ ...row, identity_verification_status: "pending" })) : fixtureIdentityProfiles;
          return identities.filter((row) => inFilters.some(([column, values]) => column === "id" && values.includes(row.id)));
        }
        if (table === "blocks" && orFilter) return [];
        return (tables[table] ?? []).filter((row) =>
          filters.every(([column, value]) => row[column] === value) &&
          inFilters.every(([column, values]) => values.includes(row[column])),
        ).slice(0, limit);
      };
      const getResult = (single: boolean) => {
        const rows = rowsForQuery();
        return { data: single ? rows[0] ?? null : rows, error: null };
      };
      query.maybeSingle = async () => getResult(true);
      query.single = async () => getResult(true);
      query.then = (resolve: (value: { data: unknown; error: unknown }) => unknown, reject: (reason: unknown) => unknown) => Promise.resolve(getResult(false)).then(resolve, reject);
      return query;
    },
    async rpc(name: string, args: Record<string, unknown>) {
      if (options.rpc) return options.rpc(name, args);
      return { data: null, error: null };
    },
  };
  const stateSession = options.session ?? {
    meetup_id: MEETUP_ID, match_id: MATCH_ID, room_id: ROOM_ID, user_a_id: userA, user_b_id: userB,
    status: "cafe_proposed", revision: 5,
    time_candidates: [{ id: TIME_ID, starts_at: new Date(now + 60 * 60_000).toISOString(), ends_at: new Date(now + 2 * 60 * 60_000).toISOString() }],
    selected_time_candidate_id: TIME_ID,
    cafe_candidates: [{ id: "verified-cafe-1", name: "Cafe", address: "Chiyoda, Tokyo", area: "Tokyo/Chiyoda", starts_at: new Date(now - 2 * 60 * 60_000).toISOString(), ends_at: new Date(now + 10 * 60 * 60_000).toISOString(), travel_minutes_first: 24.4, travel_minutes_second: 28.6, verified_at: new Date(now).toISOString() }],
    confirmed_starts_at: null, confirmed_ends_at: null, completed_a_at: null, completed_b_at: null,
    expires_at: new Date(now + 6 * 60 * 60_000).toISOString(), unavailable_reason: null, created_at: new Date(now).toISOString(),
  };
  tables.chat_meetup_sessions = options.session === undefined ? [stateSession] : options.session ? [options.session] : [];
  return { client: client as unknown as SupabaseClient<Database>, session: stateSession };
}

describe("Chat meetup DTO and private projection", () => {
  it("validates future bounded manual availability and rejects cafe and location DTOs", () => {
    const future = new Date(Date.now() + 60 * 60_000).toISOString();
    const later = new Date(Date.now() + 2 * 60 * 60_000).toISOString();
    const key = "70000000-0000-4000-8000-000000000001";
    const valid = { idempotency_key: key, expected_revision: 1, expected_own_revision: 1, action: { type: "availability.submit", source: "manual", window: { starts_at: future, ends_at: later }, available: [{ starts_at: future, ends_at: later }] } };
    expect(chatMeetupActionRequestSchema.safeParse(valid).success).toBe(true);
    expect(chatMeetupActionRequestSchema.safeParse({ ...valid, action: { ...valid.action, available: [{ starts_at: new Date(Date.now() - 60_000).toISOString(), ends_at: later }] } }).success).toBe(false);
    expect(chatMeetupActionRequestSchema.safeParse({ idempotency_key: key, expected_revision: 1, expected_own_revision: 1, action: { type: "cafe.decline", candidate_id: "provider:cafe-1" } }).success).toBe(false);
  });

  it.each(["confirmed", "completed"])("projects %s time-only plans and never calls an injected Google provider", async (status) => {
    const { session } = fixture();
    const starts = new Date(Date.now() + (status === "confirmed" ? 1 : -3) * 60 * 60_000).toISOString();
    const ends = new Date(Date.parse(starts) + 60 * 60_000).toISOString();
    const provider: GoogleCafeReferenceProvider = {
      availability: "configured", source: "google", search: vi.fn(async () => []),
      hydrateReference: vi.fn(async () => null), verifyReference: vi.fn(async () => true),
    };
    const event = { id: EVENT_ID, meetup_id: MEETUP_ID, revision: 4, kind: "system", text: "Meetup time confirmed.", created_at: new Date().toISOString() };
    const { client } = fixture({
      session: { ...session, status, confirmed_starts_at: starts, confirmed_ends_at: ends, expires_at: null,
        cafe_candidates: { malformed: true }, google_cafe_references: [{ place_id: "old-private-ref" }] },
      decisionA: { cafe_choice_id: "old-private-choice" }, events: [event],
    });
    const result = await getChatMeetupState(client, ROOM_ID, USER_A, { enabled: true, providers: { cafe: provider, recordingRehearsalConfig: rehearsalConfig() } });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.state.confirmed_plan).toEqual({ starts_at: starts, ends_at: ends });
    const { meetup_id: _id, ...projectedEvent } = event;
    expect(result.state.events).toEqual([projectedEvent]);
    expect(result.state).not.toHaveProperty("cafe_candidates");
    expect(result.state).not.toHaveProperty("cafe_details_unavailable");
    expect(result.state).not.toHaveProperty("needs_location");
    expect(result.state.own_permissions).not.toHaveProperty("cafe_connected");
    expect(result.state.own_decisions).not.toHaveProperty("cafe_candidate_id");
    expect(provider.search).not.toHaveBeenCalled();
    expect(provider.hydrateReference).not.toHaveBeenCalled();
    expect(provider.verifyReference).not.toHaveBeenCalled();
  });

  it.each(["Z", "+00:00", "+09:00"])("accepts persisted completion markers with %s offset", async (offset) => {
    const past = Date.now() - 60_000;
    const marker = offset === "Z" ? new Date(past).toISOString()
      : offset === "+00:00" ? new Date(past).toISOString().replace("Z", "+00:00")
      : new Date(past + 9 * 60 * 60_000).toISOString().replace("Z", "+09:00");
    const { session } = fixture();
    const { client } = fixture({ session: { ...session, status: "completed", expires_at: null,
      confirmed_starts_at: new Date(past - 2 * 60 * 60_000).toISOString().replace("Z", "+00:00"),
      confirmed_ends_at: new Date(past - 60 * 60_000).toISOString().replace("Z", "+00:00"),
      completed_a_at: marker, completed_b_at: marker }, decisionA: { completed_at: marker } });
    const result = await getChatMeetupState(client, ROOM_ID, USER_A, { enabled: true });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.state.status).toBe("completed");
      expect(result.state.own_decisions.completed).toBe(true);
      expect(result.state.own_permissions.can_complete).toBe(false);
    }
  });

  it.each(["not-a-timestamp", "2026-09-30T15:00:00", "2999-01-01T00:00:00+00:00"])("rejects invalid or future persisted completion marker %s", async (marker) => {
    const { session } = fixture();
    const { client } = fixture({ session: { ...session, completed_a_at: marker } });
    expect(await getChatMeetupState(client, ROOM_ID, USER_A, { enabled: true })).toEqual({ ok: false, reason: "internal" });
  });

  it("suppresses retired cafe prompts while retaining human Chat text", async () => {
    const makeEvent = (text: string, kind: string, id: string) => ({ id, meetup_id: MEETUP_ID, revision: 4, kind, text, created_at: new Date().toISOString() });
    const system = makeEvent("Cafe options are ready. Choose the same cafe to confirm.", "system", EVENT_ID);
    const human = makeEvent("Let's meet at a cafe.", "human", "60000000-0000-4000-8000-000000000002");
    const { client } = fixture({ events: [system, human] });
    const result = await getChatMeetupState(client, ROOM_ID, USER_A, { enabled: true });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.state.events.map(event => event.text)).toEqual([human.text]);
  });

  it.each(["ok", "replayed"])("returns authoritative confirmed time after time.approve %s and keeps RPC concurrency keys", async (outcome) => {
    const { session } = fixture();
    const time = (session.time_candidates as Array<{ starts_at: string; ends_at: string }>)[0];
    const rpc = vi.fn(async () => ({ data: { outcome, meetup_id: MEETUP_ID, status: "confirmed", revision: 6, own_revision: 4 }, error: null }));
    const { client } = fixture({ session: { ...session, status: "confirmed", confirmed_starts_at: time.starts_at, confirmed_ends_at: time.ends_at, expires_at: null }, rpc });
    const request = { idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 5, expected_own_revision: 3, action: { type: "time.approve" as const, candidate_id: TIME_ID } };
    const result = await applyChatMeetupAction(client, ROOM_ID, USER_A, request, { enabled: true });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.state.confirmed_plan).toEqual({ starts_at: time.starts_at, ends_at: time.ends_at });
    expect(rpc).toHaveBeenCalledExactlyOnceWith("apply_chat_meetup_action", expect.objectContaining({
      p_room_id: ROOM_ID, p_user_id: USER_A, p_expected_revision: 5, p_expected_own_revision: 3,
      p_idempotency_key: request.idempotency_key, p_request_digest: expect.stringMatching(/^[0-9a-f]{64}$/u), p_action: request.action,
    }));
  });

  it.each([
    ["expired_candidate", "invalid_state"], ["invalid_state", "invalid_state"], ["not_found", "not_found"],
    ["stale_revision", "stale_revision"], ["idempotency_conflict", "idempotency_conflict"],
    ["identity_verification_required", "identity_verification_required"],
  ])("preserves atomic RPC rejection %s", async (outcome, reason) => {
    const rpc = vi.fn(async () => ({ data: { outcome, meetup_id: MEETUP_ID, status: "time_proposed", revision: 5, own_revision: 3 }, error: null }));
    const { client } = fixture({ rpc });
    const result = await applyChatMeetupAction(client, ROOM_ID, USER_A, { idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 5, expected_own_revision: 3, action: { type: "time.approve", candidate_id: TIME_ID } }, { enabled: true });
    expect(result).toEqual({ ok: false, reason });
  });

  it("returns caller-private decisions only and keeps the peer public projection identical", async () => {
    const privateA = { intent_value: true, private_revision: 3, time_choice_id: TIME_ID, cafe_choice_id: "verified-cafe-1", completed_at: null };
    const privateB = { intent_value: true, private_revision: 2, time_choice_id: null, cafe_choice_id: null, completed_at: null };
    const shared = fixture({ decisionA: privateA, decisionB: privateB });
    const left = await getChatMeetupState(shared.client, ROOM_ID, USER_A, { enabled: true });
    const right = await getChatMeetupState(shared.client, ROOM_ID, USER_B, { enabled: true });
    expect(left.ok && right.ok).toBe(true);
    if (!left.ok || !right.ok) return;
    expect(left.state.own_decisions.time_candidate_id).toBe(TIME_ID);
    expect(right.state.own_decisions.time_candidate_id).toBeNull();
    const publicProjection = (state: typeof left.state) => {
      const { own_decisions: _own, ...visible } = state;
      return visible;
    };
    expect(publicProjection(left.state)).toEqual(publicProjection(right.state));
  });

  it("fails closed on duplicate shared candidate ids", async () => {
    const { session } = fixture();
    const time = (session.time_candidates as Array<Record<string, unknown>>)[0];
    const badSession = { ...session, time_candidates: [time, { ...time }] };
    const result = await getChatMeetupState(fixture({ session: badSession }).client, ROOM_ID, USER_A, { enabled: true });
    expect(result).toEqual({ ok: false, reason: "internal" });
  });

  it("fails closed when a durable owner attendance marker is missing", async () => {
    const { session } = fixture();
    const malformed = { ...session };
    delete malformed.completed_a_at;
    const result = await getChatMeetupState(fixture({ session: malformed }).client, ROOM_ID, USER_A, { enabled: true });
    expect(result).toEqual({ ok: false, reason: "internal" });
  });

  it("normalizes a rejected durable publish RPC without exposing raw provider/database detail", async () => {
    const now = Date.now();
    const session = {
      meetup_id: MEETUP_ID, match_id: MATCH_ID, room_id: ROOM_ID, user_a_id: USER_A, user_b_id: USER_B,
      status: "awaiting_availability", revision: 2, time_candidates: [], cafe_candidates: [],
      selected_time_candidate_id: null, confirmed_starts_at: null, confirmed_ends_at: null,
      completed_a_at: null, completed_b_at: null, expires_at: new Date(now + 3600_000).toISOString(),
      created_at: new Date(now).toISOString(), quota_claim_owner_id: USER_B, quota_operation_key: "chat-meetup:" + MEETUP_ID,
    };
    const queryRows = [
      { meetup_id: MEETUP_ID, user_id: USER_A, source: "manual", window_starts_at: new Date(now + 3600_000).toISOString(), window_ends_at: new Date(now + 4 * 3600_000).toISOString(), intervals: [{ starts_at: new Date(now + 3600_000).toISOString(), ends_at: new Date(now + 4 * 3600_000).toISOString() }], expires_at: new Date(now + 20 * 60_000).toISOString() },
      { meetup_id: MEETUP_ID, user_id: USER_B, source: "manual", window_starts_at: new Date(now + 3600_000).toISOString(), window_ends_at: new Date(now + 4 * 3600_000).toISOString(), intervals: [{ starts_at: new Date(now + 3600_000).toISOString(), ends_at: new Date(now + 4 * 3600_000).toISOString() }], expires_at: new Date(now + 20 * 60_000).toISOString() },
    ];
    const base = fixture({
      session,
      rpc: async (name) => {
        if (name === "apply_chat_meetup_action") return { data: [{ outcome: "ok", meetup_id: MEETUP_ID, status: "awaiting_availability", revision: 2, own_revision: 4 }], error: null };
        if (name === "claim_meetup_arrangement") return { data: [{ outcome: "claimed" }], error: null };
        if (name === "publish_chat_meetup_times") throw new Error("must not escape");
        return { data: null, error: null };
      },
    });
    const client = base.client as unknown as { from: (table: string) => Record<string, unknown> };
    const originalFrom = client.from.bind(base.client as never);
    vi.spyOn(client, "from").mockImplementation((table: string) => {
      if (table === "chat_meetup_availability") {
        const query: Record<string, unknown> = {};
        query.select = () => query; query.eq = () => query;
        query.then = (resolve: (value: { data: unknown; error: unknown }) => unknown) => Promise.resolve({ data: queryRows, error: null }).then(resolve);
        return query;
      }
      if (table === "chat_meetup_private_decisions") {
        const query: Record<string, unknown> = {};
        query.select = () => query; query.eq = () => query; query.in = () => query;
        query.then = (resolve: (value: { data: unknown; error: unknown }) => unknown) => Promise.resolve({ data: [{ user_id: USER_A, private_revision: 4 }, { user_id: USER_B, private_revision: 4 }], error: null }).then(resolve);
        query.maybeSingle = async () => ({ data: { private_revision: 4, intent_value: true, time_choice_id: null, cafe_choice_id: null, completed_at: null }, error: null });
        return query;
      }
      return originalFrom(table);
    });
    const request = {
      idempotency_key: "70000000-0000-4000-8000-000000000004", expected_revision: 2, expected_own_revision: 4,
      action: { type: "availability.submit", source: "manual", window: { starts_at: new Date(now + 3600_000).toISOString(), ends_at: new Date(now + 4 * 3600_000).toISOString() }, available: [{ starts_at: new Date(now + 3600_000).toISOString(), ends_at: new Date(now + 4 * 3600_000).toISOString() }] },
    };
    const result = await applyChatMeetupAction(base.client, ROOM_ID, USER_A, request as never, { enabled: true });
    expect(result).toEqual({ ok: false, reason: "internal" });
    expect(JSON.stringify(result)).not.toContain("must not escape");
  });

  it("normalizes persisted +00:00 windows and publishes mixed calendar/manual availability", async () => {
    const now = Date.now();
    const start = new Date(now + 10 * 60_000).toISOString();
    const end = new Date(now + 5 * 60 * 60_000).toISOString();
    const asOffset = (value: string) => value.replace(/Z$/, "+00:00");
    const session = {
      meetup_id: MEETUP_ID, match_id: MATCH_ID, room_id: ROOM_ID, user_a_id: USER_A, user_b_id: USER_B,
      status: "awaiting_availability", revision: 2, time_candidates: [], cafe_candidates: [],
      selected_time_candidate_id: null, confirmed_starts_at: null, confirmed_ends_at: null,
      completed_a_at: null, completed_b_at: null, expires_at: new Date(now + 7 * 24 * 60 * 60_000).toISOString(),
      created_at: new Date(now).toISOString(), quota_claim_owner_id: USER_B, quota_operation_key: "chat-meetup:" + MEETUP_ID,
    };
    const publication: { args?: Record<string, unknown> } = {};
    const { client } = fixture({
      session,
      decisionA: { intent_value: true, private_revision: 5 },
      decisionB: { intent_value: true, private_revision: 5 },
      availability: [
        { meetup_id: MEETUP_ID, user_id: USER_A, source: "calendar", window_starts_at: asOffset(start), window_ends_at: asOffset(end), intervals: [], expires_at: new Date(now + 20 * 60_000).toISOString() },
        { meetup_id: MEETUP_ID, user_id: USER_B, source: "manual", window_starts_at: asOffset(start), window_ends_at: asOffset(end), intervals: [{ starts_at: start, ends_at: end }], expires_at: new Date(now + 20 * 60_000).toISOString() },
      ],
      rpc: async (name, args) => {
        if (name === "apply_chat_meetup_action") return { data: [{ outcome: "ok", meetup_id: MEETUP_ID, status: "awaiting_availability", revision: 2, own_revision: 5 }], error: null };
        if (name === "claim_meetup_arrangement") return { data: [{ outcome: "claimed" }], error: null };
        if (name === "publish_chat_meetup_times") {
          publication.args = args;
          return { data: [{ outcome: "ok", meetup_id: MEETUP_ID, status: "time_proposed", revision: 3 }], error: null };
        }
        return { data: null, error: null };
      },
    });
    const request = {
      idempotency_key: "70000000-0000-4000-8000-000000000005", expected_revision: 2, expected_own_revision: 4,
      action: { type: "availability.submit", source: "calendar", window: { starts_at: start, ends_at: end }, busy: [] },
    };

    const result = await applyChatMeetupAction(client, ROOM_ID, USER_A, request as never, { enabled: true });

    expect(result.ok).toBe(true);
    expect(publication.args).toBeDefined();
    const candidates = publication.args?.p_candidates;
    expect(Array.isArray(candidates)).toBe(true);
    expect((candidates as Array<{ starts_at: string; ends_at: string }>).length).toBeGreaterThan(0);
    expect((candidates as Array<{ starts_at: string; ends_at: string }>).every((candidate) => Date.parse(candidate.ends_at) - Date.parse(candidate.starts_at) === 60 * 60_000)).toBe(true);
  });
});


describe("explicit synthetic Chat admission", () => {
  const maya = "a88a89e2-5421-5ce9-a33b-76d512898c37";
  const admissionId = "70000000-0000-4000-8000-000000000009";
  function config() { return { ...rehearsalConfig("demo-maya-ren"), syntheticTestAdmissionId: admissionId }; }
  function admitted(config: ReturnType<typeof rehearsalConfig>) {
    return { outcome: "admitted", admission_id: admissionId, user_a_id: USER_B, user_b_id: maya, match_id: MATCH_ID, room_id: ROOM_ID, meetup_id: MEETUP_ID, issued_at: config.issuedAt, expires_at: config.expiresAt };
  }
  it("keeps identityVerified false and emits only an explicit fictional projection after DB confirmation", async () => {
    const c = config();
    const rpc = vi.fn(async () => ({ data: admitted(c), error: null }));
    const { client } = fixture({ identityNone: true, rpc }, [maya, USER_B]);
    const access = await checkChatMeetupRoomAccess(client, ROOM_ID, maya, c);
    expect(access.ok).toBe(true);
    if (access.ok) { expect(access.context.identityVerified).toBe(false); expect(access.context.syntheticTestAdmission?.projection.identity_verified).toBe(false); }
    const state = await getChatMeetupState(client, ROOM_ID, maya, { enabled: true, providers: { cafe: unavailableCafeSearchProvider, recordingRehearsalConfig: c } });
    expect(state.ok).toBe(true);
    if (state.ok) expect(state.state.synthetic_test_admission).toEqual({ kind: "fictional-demo", pair: "demo-maya-ren", identity_verified: false, expires_at: c.expiresAt });
  });
  it.each([USER_B, maya])("allows caller %s to load private intent while the bound meetup has no mutual session yet", async (caller) => {
    const c = config();
    const { client } = fixture({
      identityNone: true, session: null, decisionB: { intent_value: true },
      rpc: async () => ({ data: admitted(c), error: null }),
    }, [USER_B, maya]);
    const result = await getChatMeetupState(client, ROOM_ID, caller, {
      enabled: true, providers: { cafe: unavailableCafeSearchProvider, recordingRehearsalConfig: c },
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.state.status).toBe("idle");
    expect(result.state.meetup_id).toBeNull();
    expect(result.state.own_permissions.can_intent).toBe(true);
    expect(result.state.own_permissions.can_schedule).toBe(false);
    expect(result.state.own_decisions.intent_value).toBe(caller === maya ? "yes" : null);
    expect(result.state.own_decisions.private_revision).toBe(caller === maya ? 1 : 0);
    expect(result.state.time_candidates).toEqual([]);
    expect(result.state.events).toEqual([]);
    expect(result.state.synthetic_test_admission?.identity_verified).toBe(false);
  });
  it("still rejects an existing session that differs from the bound synthetic meetup", async () => {
    const c = config();
    const existing = fixture({}, [USER_B, maya]).session;
    const { client } = fixture({
      identityNone: true,
      session: { ...existing, meetup_id: "30000000-0000-4000-8000-000000000099" },
      rpc: async () => ({ data: admitted(c), error: null }),
    }, [USER_B, maya]);
    expect(await getChatMeetupState(client, ROOM_ID, USER_B, {
      enabled: true, providers: { cafe: unavailableCafeSearchProvider, recordingRehearsalConfig: c },
    })).toEqual({ ok: false, reason: "not_found" });
  });
  it.each(["awaiting_availability", "time_proposed"])("keeps the server scheduling permission usable in normal phase %s", async (status) => {
    const c = config();
    const existing = fixture({}, [USER_B, maya]).session;
    const { client } = fixture({ identityNone: true, session: { ...existing, status },
      rpc: async () => ({ data: admitted(c), error: null }) }, [USER_B, maya]);
    for (const caller of [USER_B, maya]) {
      const result = await getChatMeetupState(client, ROOM_ID, caller, {
        enabled: true, providers: { cafe: unavailableCafeSearchProvider, recordingRehearsalConfig: c },
      });
      expect(result.ok).toBe(true);
      if (result.ok) expect(result.state.own_permissions.can_schedule).toBe(true);
    }
  });
  it.each(["awaiting_availability", "time_proposed", "awaiting_location", "cafe_proposed"])("does not grant scheduling to disabled or ordinary unverified phase %s", async (status) => {
    const c = config();
    const existing = fixture({}, [USER_B, maya]).session;
    const { client } = fixture({ identityNone: true, session: { ...existing, status },
      rpc: async () => ({ data: admitted(c), error: null }) }, [USER_B, maya]);
    const disabled = await getChatMeetupState(client, ROOM_ID, maya, {
      enabled: false, providers: { cafe: unavailableCafeSearchProvider, recordingRehearsalConfig: c },
    });
    expect(disabled.ok).toBe(true);
    if (disabled.ok) expect(disabled.state.own_permissions.can_schedule).toBe(false);
    const ordinary = await getChatMeetupState(client, ROOM_ID, maya, { enabled: true });
    expect(ordinary.ok).toBe(true);
    if (ordinary.ok) expect(ordinary.state.own_permissions.can_schedule).toBe(false);
  });
  it.each(["cancelled", "expired"])("does not grant scheduling to terminal phase %s", async (status) => {
    const c = config();
    const existing = fixture({}, [USER_B, maya]).session;
    const { client } = fixture({ identityNone: true, session: { ...existing, status },
      rpc: async () => ({ data: admitted(c), error: null }) }, [USER_B, maya]);
    const result = await getChatMeetupState(client, ROOM_ID, maya, {
      enabled: true, providers: { cafe: unavailableCafeSearchProvider, recordingRehearsalConfig: c },
    });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.state.own_permissions.can_schedule).toBe(false);
  });
  it("does not fallback to ordinary access when private DB admission is missing", async () => {
    const c = config();
    const { client } = fixture({ identityNone: true, rpc: async () => ({ data: { outcome: "not_found" }, error: null }) }, [maya, USER_B]);
    expect(await checkChatMeetupRoomAccess(client, ROOM_ID, maya, c)).toEqual({ ok: false, reason: "not_found" });
  });
  it("ordinary unverified users cannot schedule and cannot inject an admission in request data", async () => {
    const { client } = fixture({ identityNone: true }, [maya, USER_B]);
    const request = { idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 1, expected_own_revision: 1, action: { type: "time.approve" as const, candidate_id: TIME_ID } };
    expect(await applyChatMeetupAction(client, ROOM_ID, maya, request, { enabled: true })).toEqual({ ok: false, reason: "identity_verification_required" });
    expect(chatMeetupActionRequestSchema.safeParse({ ...request, synthetic_test_admission: admitted(config()) }).success).toBe(false);
  });
  it("uses only the explicit service wrapper with server admission args", async () => {
    const c = config();
    const rpc = vi.fn(async (name: string) => name === "check_synthetic_recording_admission"
      ? { data: admitted(c), error: null }
      : { data: { outcome: "ok", meetup_id: MEETUP_ID, status: "awaiting_location", revision: 2, own_revision: 2 }, error: null });
    const { client } = fixture({ identityNone: true, rpc }, [maya, USER_B]);
    await applyChatMeetupAction(client, ROOM_ID, maya, { idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 1, expected_own_revision: 1, action: { type: "time.approve", candidate_id: TIME_ID } }, { enabled: true, providers: { cafe: unavailableCafeSearchProvider, recordingRehearsalConfig: c } });
    expect(rpc).toHaveBeenCalledWith("demo_recording_apply_chat_meetup_action", expect.objectContaining({ p_admission_id: admissionId, p_issued_at: c.issuedAt, p_expires_at: c.expiresAt, p_user_id: maya }));
    expect(rpc.mock.calls.some(([name]) => name === "apply_chat_meetup_action")).toBe(false);
  });
});


it("synthetic arrangement preserves ordinary quota claim and stops on exhaustion before times/provider publication", async () => {
  const maya = "a88a89e2-5421-5ce9-a33b-76d512898c37";
  const id = "70000000-0000-4000-8000-000000000009";
  const c = { ...rehearsalConfig("demo-maya-ren"), syntheticTestAdmissionId: id };
  const now = Date.now(); const start = new Date(now + 10 * 60_000).toISOString(); const end = new Date(now + 70 * 60_000).toISOString();
  const rpc = vi.fn(async (name: string) => {
    if (name === "check_synthetic_recording_admission") return { data: { outcome: "admitted", admission_id: id, user_a_id: USER_B, user_b_id: maya, match_id: MATCH_ID, room_id: ROOM_ID, meetup_id: MEETUP_ID, issued_at: c.issuedAt, expires_at: c.expiresAt }, error: null };
    if (name === "demo_recording_apply_chat_meetup_action") return { data: { outcome: "ok", meetup_id: MEETUP_ID, status: "awaiting_availability", revision: 2, own_revision: 1 }, error: null };
    if (name === "demo_recording_claim_meetup_arrangement") return { data: { outcome: "quota_exhausted" }, error: null };
    throw new Error("Unexpected publish after quota exhaustion");
  });
  const session = { meetup_id: MEETUP_ID, match_id: MATCH_ID, room_id: ROOM_ID, user_a_id: maya, user_b_id: USER_B, status: "awaiting_availability", revision: 2, quota_claim_owner_id: USER_B, quota_operation_key: "chat-meetup:" + MEETUP_ID };
  const available = (user_id: string) => ({ meetup_id: MEETUP_ID, user_id, source: "manual", window_starts_at: start, window_ends_at: end, intervals: [{ starts_at: start, ends_at: end }], expires_at: new Date(now + 20 * 60_000).toISOString() });
  const { client } = fixture({ identityNone: true, rpc, session, availability: [available(maya), available(USER_B)], decisionA: { private_revision: 1 }, decisionB: { private_revision: 1 } }, [maya, USER_B]);
  const result = await applyChatMeetupAction(client, ROOM_ID, maya, { idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 1, expected_own_revision: 1, action: { type: "availability.submit", source: "manual", window: { starts_at: start, ends_at: end }, available: [{ starts_at: start, ends_at: end }] } }, { enabled: true, providers: { cafe: unavailableCafeSearchProvider, recordingRehearsalConfig: c } });
  expect(result).toEqual({ ok: false, reason: "quota_exhausted" });
  expect(rpc).toHaveBeenCalledWith("demo_recording_claim_meetup_arrangement", expect.objectContaining({ p_user_id: USER_B, p_is_retry: false, p_operation_key: "chat-meetup:" + MEETUP_ID, p_admission_id: id }));
  expect(rpc.mock.calls.some(([name]) => name.includes("publish"))).toBe(false);
});


describe("Retired location and cafe actions", () => {
  it.each([
    { type: "location.submit", location: { kind: "station", station_name: "Synthetic station" } },
    { type: "location.clear" }, { type: "cafe.approve", candidate_id: "google:retired" },
    { type: "cafe.decline", candidate_id: "retired" },
  ])("rejects $type before DB mutation or provider call", async (action) => {
    const rpc = vi.fn(async () => ({ data: null, error: null }));
    const provider: GoogleCafeReferenceProvider = {
      availability: "configured", source: "google", search: vi.fn(async () => []),
      hydrateReference: vi.fn(async () => null), verifyReference: vi.fn(async () => true),
    };
    const { client } = fixture({ rpc });
    const result = await applyChatMeetupAction(client, ROOM_ID, USER_A, {
      idempotency_key: "70000000-0000-4000-8000-000000000001", expected_revision: 5, expected_own_revision: 3, action,
    } as unknown as import("./chat-meetup").ChatMeetupActionRequest, { enabled: true, providers: { cafe: provider } });
    expect(result).toEqual({ ok: false, reason: "bad_request" });
    expect(rpc).not.toHaveBeenCalled();
    expect(provider.search).not.toHaveBeenCalled();
    expect(provider.hydrateReference).not.toHaveBeenCalled();
    expect(provider.verifyReference).not.toHaveBeenCalled();
  });
  it.each(["awaiting_location", "cafe_proposed"])("hides retired %s phases while allowing replan", async (status) => {
    const { session } = fixture();
    const { client } = fixture({ session: { ...session, status, unavailable_reason: "cafe_unavailable" } });
    const result = await getChatMeetupState(client, ROOM_ID, USER_A, { enabled: true });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.state.status).toBe("unavailable");
      expect(result.state.own_permissions.can_schedule).toBe(false);
      expect(result.state.own_permissions.can_replan).toBe(true);
      expect(result.state).not.toHaveProperty("unavailable_reason");
    }
  });
});

it("rejects an extra candidate id before any provider call", async () => {
  const search = vi.fn(async () => []);
  const location = { kind: "station" as const, station_name: "Ginza Station, Tokyo", nearby_station_names: [] };
  await expect(searchFairCafeCandidates({ availability: "configured", search }, { first_participant: { consented: true, location }, second_participant: { consented: true, location }, time_options: [{ id: TIME_ID, starts_at: new Date(Date.now()+3600000).toISOString(), ends_at: new Date(Date.now()+7200000).toISOString() } as unknown as import("./chat-meetup-providers").TimeInterval], duration_minutes: 60 })).rejects.toThrow("Invalid cafe search request.");
  expect(search).not.toHaveBeenCalled();
});
