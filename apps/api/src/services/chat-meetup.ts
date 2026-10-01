import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Database } from "../db/types";
import {
  unavailableCafeSearchProvider,
  type CafeSearchProvider,
  intersectMeetupAvailability,
  type MeetupAvailabilityInput,
} from "./chat-meetup-providers";
import { type ValidatedRecordingRehearsalConfig } from "./recording-rehearsal";
import { areMutuallyEligible, loadMatchingEligibilityProfiles } from "./matching-eligibility";
import { checkSyntheticRecordingAdmission, recordingAdmissionRpc, type SyntheticRecordingAdmission, type SyntheticTestAdmissionProjection } from "./synthetic-recording-admission";
import { sha256Hex } from "./message-idempotency";

type DbResult = { data: unknown; error: unknown };
type Query = {
  select(columns?: string): Query;
  eq(column: string, value: unknown): Query;
  in(column: string, values: unknown[]): Query;
  or(filters: string): Query;
  order(column: string, options?: { ascending?: boolean }): Query;
  limit(count: number): Query;
  maybeSingle(): Promise<DbResult>;
  single(): Promise<DbResult>;
  then<TResult1 = DbResult, TResult2 = never>(onfulfilled?: ((value: DbResult) => TResult1 | PromiseLike<TResult1>) | null, onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null): Promise<TResult1 | TResult2>;
};
type ChatDb = {
  from(table: string): Query;
  rpc(name: string, args: Record<string, unknown>): Promise<DbResult>;
};
function db(client: SupabaseClient<Database>): ChatDb { return client as unknown as ChatDb; }

const uuid = z.string().uuid();
const timestamp = z.string().datetime({ offset: false });
const persistedTimestamp = z.string().datetime({ offset: true });
const interval = z.object({ starts_at: timestamp, ends_at: timestamp }).strict().refine((v) => Date.parse(v.starts_at) < Date.parse(v.ends_at));
const max128Intervals = z.array(interval).max(128);
function validateAvailability(window: { starts_at: string; ends_at: string }, entries: Array<{ starts_at: string; ends_at: string }>, ctx: z.RefinementCtx, key: string): void {
  const now = Date.now(); const start = Date.parse(window.starts_at); const end = Date.parse(window.ends_at);
  if (start <= now || end > now + 21 * 24 * 60 * 60_000) ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["window"], message: "Availability window must be upcoming and no longer than 21 days." });
  for (const [index, entry] of entries.entries()) if (Date.parse(entry.starts_at) < start || Date.parse(entry.ends_at) > end) ctx.addIssue({ code: z.ZodIssueCode.custom, path: [key, index], message: "Availability must stay inside its window." });
}
const calendarAvailabilityAction = z.object({ type: z.literal("availability.submit"), source: z.literal("calendar"), window: interval, busy: max128Intervals }).strict().superRefine((value, ctx) => validateAvailability(value.window, value.busy, ctx, "busy"));
const manualAvailabilityAction = z.object({ type: z.literal("availability.submit"), source: z.literal("manual"), window: interval, available: max128Intervals }).strict().superRefine((value, ctx) => validateAvailability(value.window, value.available, ctx, "available"));
export const chatMeetupActionSchema = z.union([
  z.object({ type: z.literal("intent"), value: z.enum(["yes", "withdraw"]) }).strict(),
  calendarAvailabilityAction,
  manualAvailabilityAction,
  z.object({ type: z.literal("availability.clear") }).strict(),
  z.object({ type: z.literal("time.approve"), candidate_id: uuid }).strict(),
  z.object({ type: z.literal("replan") }).strict(),
  z.object({ type: z.literal("cancel") }).strict(),
  z.object({ type: z.literal("meeting.complete") }).strict(),
]);
export type ChatMeetupAction = z.infer<typeof chatMeetupActionSchema>;

export const chatMeetupActionRequestSchema = z.object({
  idempotency_key: uuid,
  expected_revision: z.number().int().nonnegative().max(2_147_483_647),
  expected_own_revision: z.number().int().nonnegative().max(2_147_483_647),
  action: chatMeetupActionSchema,
}).strict();
export type ChatMeetupActionRequest = z.infer<typeof chatMeetupActionRequestSchema>;

export const CHAT_MEETUP_STATUSES = ["idle", "awaiting_availability", "time_proposed", "awaiting_location", "cafe_proposed", "confirmed", "completed", "cancelled", "expired", "unavailable"] as const;
export type ChatMeetupStatus = (typeof CHAT_MEETUP_STATUSES)[number];
export type ChatMeetupState = {
  synthetic_test_admission?: SyntheticTestAdmissionProjection;
  room_id: string;
  meetup_id: string | null;
  revision: number;
  status: ChatMeetupStatus;
  events: Array<{ id: string; revision: number; kind: "system" | "human"; text: string; created_at: string }>;
  time_candidates: Array<{ id: string; starts_at: string; ends_at: string }>;
  confirmed_plan?: { starts_at: string; ends_at: string };
  own_permissions: {
    can_intent: boolean; can_schedule: boolean; can_replan: boolean; can_cancel: boolean; can_complete: boolean;
    calendar_connected: boolean;
    reason?: "feature_disabled" | "provider_unavailable" | "identity_verification_required" | "quota_exhausted" | "terminal_state";
  };
  own_decisions: { intent_value: "yes" | null; time_candidate_id: string | null; completed: boolean; private_revision: number };
  expires_at: string | null;
  unavailable_reason?: "calendar_unavailable" | "no_shared_time";
};

export type ChatMeetupServiceFailure = "not_found" | "internal" | "bad_request" | "invalid_state" | "stale_revision" | "quota_exhausted" | "identity_verification_required" | "idempotency_conflict" | "provider_unavailable";
export type ChatMeetupServiceResult = { ok: true; state: ChatMeetupState } | { ok: false; reason: ChatMeetupServiceFailure };

export type ChatMeetupProviders = {
  cafe: CafeSearchProvider;
  recordingRehearsalConfig?: ValidatedRecordingRehearsalConfig;
};
export const defaultChatMeetupProviders: ChatMeetupProviders = { cafe: unavailableCafeSearchProvider };

/** Time-only release: injected providers cannot enable cafe operations. */
function cafeProviderForRoom(_providers: ChatMeetupProviders, _context: ChatMeetupRoomContext): CafeSearchProvider {
  return unavailableCafeSearchProvider;
}

function isRecord(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
function queryRows(value: unknown): Record<string, unknown>[] | null { return Array.isArray(value) && value.every(isRecord) ? value : null; }
function rpcRow(value: unknown): Record<string, unknown> | null { return Array.isArray(value) && value.length === 1 && isRecord(value[0]) ? value[0] : isRecord(value) ? value : null; }
function stringOrNull(value: unknown): string | null { return typeof value === "string" ? value : null; }
function normalizePersistedTimestamp(value: unknown): string | null {
  const parsed = persistedTimestamp.safeParse(value);
  if (!parsed.success) return null;
  const milliseconds = Date.parse(parsed.data);
  return Number.isFinite(milliseconds) ? new Date(milliseconds).toISOString() : null;
}
function enumStatus(value: unknown): ChatMeetupStatus | null { return typeof value === "string" && (CHAT_MEETUP_STATUSES as readonly string[]).includes(value) ? value as ChatMeetupStatus : null; }
function safeUnavailableReason(value: unknown): ChatMeetupState["unavailable_reason"] | undefined {
  return value === "calendar_unavailable" || value === "no_shared_time" ? value : undefined;
}
export type ChatMeetupRoomContext = { roomId: string; matchId: string; userA: string; userB: string; callerId: string; partnerId: string; identityVerified: boolean; syntheticTestAdmission?: SyntheticRecordingAdmission };
export type ChatMeetupAccessResult = { ok: true; context: ChatMeetupRoomContext } | { ok: false; reason: "not_found" | "internal" };

/** Rechecks active room membership, current mutual matching eligibility, age verification and both block directions. */
export async function checkChatMeetupRoomAccess(client: SupabaseClient<Database>, roomId: string, callerId: string, recordingConfig?: ValidatedRecordingRehearsalConfig): Promise<ChatMeetupAccessResult> {
  if (!uuid.safeParse(roomId).success || !uuid.safeParse(callerId).success) return { ok: false, reason: "not_found" };
  const q = db(client);
  let roomResult: DbResult;
  try { roomResult = await q.from("direct_chat_rooms").select("id,match_id,status").eq("id", roomId).maybeSingle(); }
  catch { return { ok: false, reason: "internal" }; }
  if (roomResult.error) return { ok: false, reason: "internal" };
  if (!isRecord(roomResult.data) || roomResult.data.id !== roomId || roomResult.data.status !== "active" || typeof roomResult.data.match_id !== "string") return { ok: false, reason: "not_found" };
  let matchResult: DbResult;
  try { matchResult = await q.from("matches").select("id,user_a_id,user_b_id,status").eq("id", roomResult.data.match_id).maybeSingle(); }
  catch { return { ok: false, reason: "internal" }; }
  if (matchResult.error) return { ok: false, reason: "internal" };
  const match = matchResult.data;
  if (!isRecord(match) || match.id !== roomResult.data.match_id || match.status !== "direct_chat_active" || typeof match.user_a_id !== "string" || typeof match.user_b_id !== "string" || !uuid.safeParse(match.user_a_id).success || !uuid.safeParse(match.user_b_id).success || match.user_a_id === match.user_b_id || (callerId !== match.user_a_id && callerId !== match.user_b_id)) return { ok: false, reason: "not_found" };
  let profiles;
  try { profiles = await loadMatchingEligibilityProfiles(client, [match.user_a_id, match.user_b_id]); }
  catch { return { ok: false, reason: "internal" }; }
  if (!areMutuallyEligible(profiles.get(match.user_a_id), profiles.get(match.user_b_id))) return { ok: false, reason: "not_found" };
  let blockResult: DbResult;
  let identityResult: DbResult;
  try {
    [blockResult, identityResult] = await Promise.all([
      q.from("blocks").select("id,blocker_id,blocked_id").or(`and(blocker_id.eq.${match.user_a_id},blocked_id.eq.${match.user_b_id}),and(blocker_id.eq.${match.user_b_id},blocked_id.eq.${match.user_a_id})`).limit(2),
      q.from("user_profiles").select("id,identity_verification_status,identity_verified_at").in("id", [match.user_a_id, match.user_b_id]),
    ]);
  } catch { return { ok: false, reason: "internal" }; }
  if (blockResult.error || identityResult.error) return { ok: false, reason: "internal" };
  if (!Array.isArray(blockResult.data) || blockResult.data.length > 2) return { ok: false, reason: "internal" };
  if (blockResult.data.length !== 0) return { ok: false, reason: "not_found" };
  const identityRows = queryRows(identityResult.data);
  const identityVerified = !!identityRows && identityRows.length === 2 && new Set(identityRows.map(p => p.id)).size === 2
    && identityRows.every(p => (p.id === match.user_a_id || p.id === match.user_b_id) && p.identity_verification_status === "verified"
      && typeof p.identity_verified_at === "string" && Number.isFinite(Date.parse(p.identity_verified_at)) && Date.parse(p.identity_verified_at) <= Date.now());
  let syntheticTestAdmission: SyntheticRecordingAdmission | undefined;
  if (recordingConfig?.syntheticTestAdmissionId) {
    if (!identityRows || identityRows.length !== 2 || new Set(identityRows.map(p => p.id)).size !== 2
      || identityRows.some(p => p.id !== match.user_a_id && p.id !== match.user_b_id)) return { ok: false, reason: "not_found" };
    const admission = await checkSyntheticRecordingAdmission(q, recordingConfig, callerId, { roomId, matchId: match.id });
    if (!admission) return { ok: false, reason: "not_found" };
    syntheticTestAdmission = admission;
  }
  return { ok: true, context: { roomId, matchId: match.id, userA: match.user_a_id, userB: match.user_b_id, callerId,
    partnerId: callerId === match.user_a_id ? match.user_b_id : match.user_a_id, identityVerified,
    ...(syntheticTestAdmission ? { syntheticTestAdmission } : {}) } };
}

function projectTimeCandidates(value: unknown): ChatMeetupState["time_candidates"] | null {
  if (!Array.isArray(value) || value.length > 3 || !value.every(isRecord)) return null;
  const ids = new Set<string>(); const projected: ChatMeetupState["time_candidates"] = [];
  for (const r of value) {
    if (typeof r.id !== "string" || !uuid.safeParse(r.id).success || ids.has(r.id) || typeof r.starts_at !== "string" || !timestamp.safeParse(r.starts_at).success || typeof r.ends_at !== "string" || !timestamp.safeParse(r.ends_at).success || Date.parse(r.ends_at) <= Date.parse(r.starts_at)) return null;
    ids.add(r.id); projected.push({ id: r.id, starts_at: r.starts_at, ends_at: r.ends_at });
  }
  return projected;
}
async function readStateAfterAccess(client: SupabaseClient<Database>, context: ChatMeetupRoomContext, enabled: boolean, _cafeProvider: CafeSearchProvider): Promise<ChatMeetupServiceResult> {
  const q = db(client);
  const sessionColumns = "meetup_id,match_id,room_id,user_a_id,user_b_id,status,revision,time_candidates,selected_time_candidate_id,confirmed_starts_at,confirmed_ends_at,completed_a_at,completed_b_at,expires_at,unavailable_reason,created_at";
  let sessionResult: DbResult;
  let decisionResult: DbResult;
  try {
    [sessionResult, decisionResult] = await Promise.all([
      q.from("chat_meetup_sessions").select(sessionColumns).eq("room_id", context.roomId).order("created_at", { ascending: false }).limit(1),
      q.from("chat_meetup_private_decisions").select("intent_value,private_revision,time_choice_id,completed_at").eq("match_id", context.matchId).eq("user_id", context.callerId).maybeSingle(),
    ]);
  } catch { return { ok: false, reason: "internal" }; }
  if (sessionResult.error || decisionResult.error) return { ok: false, reason: "internal" };
  const sessions = queryRows(sessionResult.data);
  if (sessionResult.error || !sessions) return { ok: false, reason: "internal" };
  const session = sessions[0] ?? null;
  if (context.syntheticTestAdmission?.meetupId && session && session.meetup_id !== context.syntheticTestAdmission.meetupId) return { ok: false, reason: "not_found" };
  const decision = isRecord(decisionResult.data) ? decisionResult.data : null;
  if (!decision && decisionResult.data !== null) return { ok: false, reason: "internal" };
  if (decision && (typeof decision.private_revision !== "number" || !Number.isInteger(decision.private_revision) || decision.private_revision < 0 || decision.private_revision > 2_147_483_647 || (decision.intent_value !== null && typeof decision.intent_value !== "boolean") || (decision.time_choice_id !== null && typeof decision.time_choice_id !== "string") || (decision.completed_at !== null && (typeof decision.completed_at !== "string" || !Number.isFinite(Date.parse(decision.completed_at)) || Date.parse(decision.completed_at) > Date.now())))) return { ok: false, reason: "internal" };
  let status: ChatMeetupStatus = "idle";
  let meetupId: string | null = null;
  let revision = 0;
  let ownRevision = typeof decision?.private_revision === "number" && Number.isInteger(decision.private_revision) && decision.private_revision >= 0 ? decision.private_revision : 0;
  let times: ChatMeetupState["time_candidates"] = [];
  let events: ChatMeetupState["events"] = [];
  let expiresAt: string | null = null;
  let unavailableReason: ChatMeetupState["unavailable_reason"];
  let confirmedPlan: ChatMeetupState["confirmed_plan"];
  let completed = false;
  if (session) {
    if (session.expires_at !== null && (typeof session.expires_at !== "string" || !Number.isFinite(Date.parse(session.expires_at)))) return { ok: false, reason: "internal" };
    if (session.status !== "completed" && session.status !== "cancelled" && session.status !== "expired" && typeof session.expires_at === "string" && Date.parse(session.expires_at) <= Date.now()) {
      let expiryResult: DbResult;
      try { expiryResult = await q.rpc("expire_chat_meetup_session", { p_room_id: context.roomId, p_user_id: context.callerId }); }
      catch { return { ok: false, reason: "internal" }; }
      const expiry = parsePublishOutcome(expiryResult.data);
      if (expiryResult.error || !expiry || (expiry.outcome !== "ok" && expiry.outcome !== "expired")) return { ok: false, reason: expiry?.outcome === "not_found" ? "not_found" : "internal" };
      if (expiry.outcome === "expired") return readStateAfterAccess(client, context, enabled, _cafeProvider);
    }
    if (session.room_id !== context.roomId || session.match_id !== context.matchId || session.user_a_id !== context.userA || session.user_b_id !== context.userB || !uuid.safeParse(session.meetup_id).success || !enumStatus(session.status) || typeof session.revision !== "number" || !Number.isInteger(session.revision) || session.revision < 0 || session.revision > 2_147_483_647) return { ok: false, reason: "internal" };
    status = session.status === "awaiting_location" || session.status === "cafe_proposed" ? "unavailable" : enumStatus(session.status) ?? "idle"; meetupId = session.meetup_id as string; revision = session.revision;
    expiresAt = stringOrNull(session.expires_at);
    unavailableReason = safeUnavailableReason(session.unavailable_reason);
    for (const markerKey of ["completed_a_at", "completed_b_at"] as const) {
      if (!Object.prototype.hasOwnProperty.call(session, markerKey)) return { ok: false, reason: "internal" };
      const marker = session[markerKey];
      if (marker !== null && (typeof marker !== "string" || normalizePersistedTimestamp(marker) === null || Date.parse(marker) > Date.now())) return { ok: false, reason: "internal" };
    }
    const startsAt = session.confirmed_starts_at; const endsAt = session.confirmed_ends_at;
    if ((startsAt === null) !== (endsAt === null) || (startsAt !== null && (typeof startsAt !== "string" || !Number.isFinite(Date.parse(startsAt)) || typeof endsAt !== "string" || !Number.isFinite(Date.parse(endsAt)) || Date.parse(endsAt) <= Date.parse(startsAt)))) return { ok: false, reason: "internal" };
    if ((status === "confirmed" || status === "completed") && (typeof startsAt !== "string" || typeof endsAt !== "string")) return { ok: false, reason: "internal" };
    const projectedTimes = projectTimeCandidates(session.time_candidates);
    if (!projectedTimes) return { ok: false, reason: "internal" };
    times = projectedTimes;
    if (status === "confirmed" || status === "completed") {
      const confirmedStarts = normalizePersistedTimestamp(startsAt);
      const confirmedEnds = normalizePersistedTimestamp(endsAt);
      if (!confirmedStarts || !confirmedEnds) return { ok: false, reason: "internal" };
      confirmedPlan = { starts_at: confirmedStarts, ends_at: confirmedEnds };
    }
    completed = context.callerId === context.userA ? session.completed_a_at !== null : session.completed_b_at !== null;
    let eventResult: DbResult;
    try { eventResult = await q.from("chat_meetup_events").select("id,revision,kind,text,created_at").eq("meetup_id", meetupId).order("created_at", { ascending: true }).limit(100); }
    catch { return { ok: false, reason: "internal" }; }
    const eventRows = queryRows(eventResult.data);
    if (eventResult.error || !eventRows || eventRows.some((row) => !uuid.safeParse(row.id).success || typeof row.revision !== "number" || !Number.isInteger(row.revision) || (row.kind !== "system" && row.kind !== "human") || typeof row.text !== "string" || typeof row.created_at !== "string")) return { ok: false, reason: "internal" };
    events = eventRows.filter((row) => row.kind !== "system" || !/\bcafe\b|starting area/iu.test(row.text as string)).map((row) => ({ id: row.id as string, revision: row.revision as number, kind: row.kind as "system" | "human", text: row.text as string, created_at: row.created_at as string }));
  }
  const terminal = status === "cancelled" || status === "expired" || status === "completed";
  const identityReason = !context.identityVerified && !context.syntheticTestAdmission ? "identity_verification_required" as const : undefined;
  const unavailableReasonForPermissions = !enabled ? "feature_disabled" as const : identityReason;
  const canIntent = !meetupId || terminal;
  const canSchedule = enabled && (context.identityVerified || !!context.syntheticTestAdmission) && ["awaiting_availability", "time_proposed"].includes(status);
  const confirmedEnd = session && typeof session.confirmed_ends_at === "string" ? Date.parse(session.confirmed_ends_at) : NaN;
  const canComplete = status === "confirmed" && !completed && Number.isFinite(confirmedEnd) && confirmedEnd <= Date.now();
  const canReplan = status === "confirmed" ? Number.isFinite(confirmedEnd) && confirmedEnd > Date.now() : ["time_proposed", "unavailable", "expired"].includes(status);
  const canCancel = !!meetupId && !terminal;
  const state: ChatMeetupState = {
    ...(context.syntheticTestAdmission ? { synthetic_test_admission: context.syntheticTestAdmission.projection } : {}),
    room_id: context.roomId, meetup_id: meetupId, revision, status, events,
    time_candidates: times,
    ...(confirmedPlan ? { confirmed_plan: confirmedPlan } : {}),
    own_permissions: { can_intent: canIntent, can_schedule: canSchedule, can_replan: canReplan, can_cancel: canCancel, can_complete: canComplete, calendar_connected: false, ...(unavailableReasonForPermissions ? { reason: unavailableReasonForPermissions } : {}) },
    own_decisions: { intent_value: decision?.intent_value === true ? "yes" : null, time_candidate_id: stringOrNull(decision?.time_choice_id), completed, private_revision: ownRevision },
    expires_at: expiresAt,
    ...(unavailableReason ? { unavailable_reason: unavailableReason } : {}),
  };
  const latestAccess = await checkChatMeetupRoomAccess(client, context.roomId, context.callerId, context.syntheticTestAdmission?.config);
  if (!latestAccess.ok) return { ok: false, reason: latestAccess.reason };
  if (latestAccess.context.matchId !== context.matchId || latestAccess.context.userA !== context.userA || latestAccess.context.userB !== context.userB) return { ok: false, reason: "not_found" };
  return { ok: true, state };
}

export async function getChatMeetupState(client: SupabaseClient<Database>, roomId: string, callerId: string, options: { enabled?: boolean; providers?: ChatMeetupProviders } = {}): Promise<ChatMeetupServiceResult> {
  const access = await checkChatMeetupRoomAccess(client, roomId, callerId, options.providers?.recordingRehearsalConfig);
  if (!access.ok) return { ok: false, reason: access.reason };
  const providers = options.providers ?? defaultChatMeetupProviders;
  return readStateAfterAccess(client, access.context, options.enabled === true, cafeProviderForRoom(providers, access.context));
}

function actionToRpcJson(action: ChatMeetupAction): Record<string, unknown> { return { ...action } as Record<string, unknown>; }
function parsePublishOutcome(value: unknown): { outcome: string; meetup_id: string | null; status: string | null; revision: number } | null {
  const row = rpcRow(value);
  if (!row || typeof row.outcome !== "string" || (row.meetup_id !== null && typeof row.meetup_id !== "string") || (row.status !== null && typeof row.status !== "string") || typeof row.revision !== "number") return null;
  return { outcome: row.outcome, meetup_id: row.meetup_id as string | null, status: row.status as string | null, revision: row.revision };
}

function parseRpcOutcome(value: unknown): { outcome: string; meetup_id: string | null; status: string | null; revision: number; own_revision: number } | null {
  const row = rpcRow(value);
  if (!row || typeof row.outcome !== "string" || (row.meetup_id !== null && typeof row.meetup_id !== "string") || (row.status !== null && typeof row.status !== "string") || typeof row.revision !== "number" || typeof row.own_revision !== "number") return null;
  return { outcome: row.outcome, meetup_id: row.meetup_id as string | null, status: row.status as string | null, revision: row.revision, own_revision: row.own_revision };
}

async function publishAvailableTimes(client: SupabaseClient<Database>, context: ChatMeetupRoomContext, callerId: string): Promise<ChatMeetupServiceFailure | null> {
  const q = db(client);
  let sessionResult: DbResult;
  try { sessionResult = await q.from("chat_meetup_sessions").select("meetup_id,revision,status,quota_claim_owner_id,quota_operation_key").eq("room_id", context.roomId).order("created_at", { ascending: false }).limit(1); }
  catch { return "internal"; }
  const sessions = queryRows(sessionResult.data); const session = sessions?.[0];
  if (sessionResult.error || !session || session.status !== "awaiting_availability" || typeof session.meetup_id !== "string") return null;
  let rowsResult: DbResult; let revisionsResult: DbResult;
  try {
    [rowsResult, revisionsResult] = await Promise.all([
      q.from("chat_meetup_availability").select("user_id,source,window_starts_at,window_ends_at,intervals,expires_at").eq("meetup_id", session.meetup_id),
      q.from("chat_meetup_private_decisions").select("user_id,private_revision").eq("match_id", context.matchId).in("user_id", [context.userA, context.userB]),
    ]);
  } catch { return "internal"; }
  const availabilityRows = queryRows(rowsResult.data); const revisionRows = queryRows(revisionsResult.data);
  if (rowsResult.error || revisionsResult.error || !availabilityRows || !revisionRows) return "internal";
  const now = Date.now();
  if (availabilityRows.length !== 2 || availabilityRows.some((r) => typeof r.expires_at !== "string" || Date.parse(r.expires_at) <= now)) return null;
  const byUser = new Map(availabilityRows.map((r) => [r.user_id, r]));
  const a = byUser.get(context.userA); const b = byUser.get(context.userB);
  if (!a || !b) return null;
  const revByUser = new Map(revisionRows.map((r) => [r.user_id, r.private_revision]));
  if (!Number.isInteger(revByUser.get(context.userA)) || !Number.isInteger(revByUser.get(context.userB))) return "internal";
  const claimOwner = typeof session.quota_claim_owner_id === "string" ? session.quota_claim_owner_id : callerId;
  const operationKey = typeof session.quota_operation_key === "string" ? session.quota_operation_key : `chat-meetup:${session.meetup_id}`;
  if (typeof session.quota_claim_owner_id !== "string") return "internal";
  let claimResult: DbResult;
  try { claimResult = await recordingAdmissionRpc(q, "claim_meetup_arrangement", { p_meetup_id: session.meetup_id, p_user_id: claimOwner, p_is_retry: false, p_operation_key: operationKey }, context.syntheticTestAdmission); }
  catch { return "internal"; }
  const claim = rpcRow(claimResult.data);
  if (claimResult.error || !claim || typeof claim.outcome !== "string") return "internal";
  if (claim.outcome === "quota_exhausted") return "quota_exhausted";
  if (claim.outcome === "identity_verification_required") return "identity_verification_required";
  if (!["claimed", "already_claimed", "already_arranging"].includes(claim.outcome)) return "invalid_state";
  const convert = (row: Record<string, unknown>): MeetupAvailabilityInput | null => {
    const startsAt = normalizePersistedTimestamp(row.window_starts_at);
    const endsAt = normalizePersistedTimestamp(row.window_ends_at);
    if (!startsAt || !endsAt || !Array.isArray(row.intervals) || !row.intervals.every((item) => isRecord(item) && typeof item.starts_at === "string" && typeof item.ends_at === "string")) return null;
    const window = { starts_at: startsAt, ends_at: endsAt };
    const intervals = row.intervals as Array<{ starts_at: string; ends_at: string }>;
    if (row.source === "calendar") return { source: "calendar", calendar: { window, busy: intervals } };
    if (row.source === "manual") return { source: "manual", window, available: intervals };
    return null;
  };
  const inputA = convert(a); const inputB = convert(b); if (!inputA || !inputB) return "internal";
  let candidates: Array<{ id: string; starts_at: string; ends_at: string }> = [];
  try {
    candidates = intersectMeetupAvailability(inputA, inputB, 60, new Date(now))
      .map((v) => ({ id: crypto.randomUUID(), starts_at: v.starts_at, ends_at: v.ends_at }));
  } catch { return "bad_request"; }
  let publish: DbResult;
  try {
    publish = await recordingAdmissionRpc(q, "publish_chat_meetup_times", {
      p_room_id: context.roomId, p_user_id: callerId, p_expected_revision: session.revision,
      p_first_private_revision: revByUser.get(context.userA), p_second_private_revision: revByUser.get(context.userB),
      p_candidates: candidates, p_unavailable_reason: candidates.length ? null : "no_shared_time",
    }, context.syntheticTestAdmission);
  } catch { return "internal"; }
  const published = parsePublishOutcome(publish.data);
  if (publish.error || !published) return "internal";
  if (published.outcome === "stale_private_input") return "stale_revision";
  if (published.outcome !== "ok") return published.outcome === "identity_verification_required" ? "identity_verification_required" : "invalid_state";
  return null;
}

/** Resume the ordinary availability orchestration after a registry counterpart action. */
export async function refreshChatMeetupAvailableTimes(client: SupabaseClient<Database>, roomId: string, callerId: string): Promise<ChatMeetupServiceFailure | null> {
  const access = await checkChatMeetupRoomAccess(client, roomId, callerId);
  if (!access.ok) return access.reason;
  return publishAvailableTimes(client, access.context, callerId);
}

export async function applyChatMeetupAction(client: SupabaseClient<Database>, roomId: string, callerId: string, request: ChatMeetupActionRequest, options: { enabled?: boolean; providers?: ChatMeetupProviders } = {}): Promise<ChatMeetupServiceResult> {
  const parsed = chatMeetupActionRequestSchema.safeParse(request);
  if (!parsed.success) return { ok: false, reason: "bad_request" };
  const access = await checkChatMeetupRoomAccess(client, roomId, callerId, options.providers?.recordingRehearsalConfig);
  if (!access.ok) return { ok: false, reason: access.reason };
  if (options.enabled !== true) return { ok: false, reason: "invalid_state" };
  const action = parsed.data.action;
  if (new Set<string>(["availability.submit", "time.approve", "replan"]).has(action.type) && !access.context.identityVerified && !access.context.syntheticTestAdmission) return { ok: false, reason: "identity_verification_required" };
  const digest = await sha256Hex(JSON.stringify({ expected_revision: parsed.data.expected_revision, expected_own_revision: parsed.data.expected_own_revision, action }));
  const providers = options.providers ?? defaultChatMeetupProviders;
  const cafeProvider = cafeProviderForRoom(providers, access.context);
  let result: DbResult;
  try {
    result = await recordingAdmissionRpc(db(client), "apply_chat_meetup_action", {
      p_room_id: roomId, p_user_id: callerId, p_expected_revision: parsed.data.expected_revision,
      p_expected_own_revision: parsed.data.expected_own_revision, p_idempotency_key: parsed.data.idempotency_key,
      p_request_digest: digest, p_action: actionToRpcJson(action),
    }, access.context.syntheticTestAdmission);
  } catch { return { ok: false, reason: "internal" }; }
  const row = parseRpcOutcome(result.data);
  if (result.error || !row) return { ok: false, reason: "internal" };
  if (row.outcome === "not_found") return { ok: false, reason: "not_found" };
  if (row.outcome === "invalid_input") return { ok: false, reason: "bad_request" };
  if (row.outcome === "invalid_state" || row.outcome === "expired_candidate") return { ok: false, reason: "invalid_state" };
  if (row.outcome === "stale_revision") return { ok: false, reason: "stale_revision" };
  if (row.outcome === "idempotency_conflict") return { ok: false, reason: "idempotency_conflict" };
  if (row.outcome === "identity_verification_required") return { ok: false, reason: "identity_verification_required" };
  if (row.outcome !== "ok" && row.outcome !== "replayed") return { ok: false, reason: "internal" };
  let secondaryFailure: ChatMeetupServiceFailure | null = null;
  if (action.type === "availability.submit") secondaryFailure = await publishAvailableTimes(client, access.context, callerId);
  if (secondaryFailure) return { ok: false, reason: secondaryFailure };
  return readStateAfterAccess(client, access.context, true, cafeProvider);
}

export type WardConversationHistory = { room_id: string; events: Array<{ id: string; kind: "ward"; speaker: "my_ward" | "partner_ward"; text: string; round: number; created_at: string }>; next_cursor: null; has_more: boolean };
export type WardConversationResult = { ok: true; data: WardConversationHistory } | { ok: false; reason: "not_found" | "internal" };

/** Latest bounded compatibility-only Ward projection; private PartnerWard conversations are excluded. */
export async function getChatWardConversation(client: SupabaseClient<Database>, roomId: string, callerId: string): Promise<WardConversationResult> {
  const access = await checkChatMeetupRoomAccess(client, roomId, callerId);
  if (!access.ok) return { ok: false, reason: access.reason };
  const q = db(client);
  let conversationResult: DbResult;
  try { conversationResult = await q.from("fox_conversations").select("id,match_id,status,purpose").eq("match_id", access.context.matchId).eq("purpose", "compatibility").eq("status", "completed").order("created_at", { ascending: false }).limit(1).maybeSingle(); }
  catch { return { ok: false, reason: "internal" }; }
  if (conversationResult.error) return { ok: false, reason: "internal" };
  const conversation = isRecord(conversationResult.data) ? conversationResult.data : null;
  let events: WardConversationHistory["events"] = [];
  if (conversation) {
    if (typeof conversation.id !== "string" || conversation.match_id !== access.context.matchId || conversation.purpose !== "compatibility" || conversation.status !== "completed") return { ok: false, reason: "internal" };
    let messageResult: DbResult;
    try { messageResult = await q.from("fox_conversation_messages").select("id,speaker_user_id,content,round_number,created_at").eq("conversation_id", conversation.id).order("created_at", { ascending: false }).limit(100); }
    catch { return { ok: false, reason: "internal" }; }
    const rows = queryRows(messageResult.data);
    if (messageResult.error || !rows || rows.length > 100 || rows.some((r) => !uuid.safeParse(r.id).success || (r.speaker_user_id !== access.context.userA && r.speaker_user_id !== access.context.userB) || typeof r.content !== "string" || !Number.isInteger(r.round_number) || typeof r.created_at !== "string")) return { ok: false, reason: "internal" };
    const hasMore = false;
    events = rows.reverse().map((r) => ({ id: r.id as string, kind: "ward", speaker: r.speaker_user_id === callerId ? "my_ward" : "partner_ward", text: r.content as string, round: r.round_number as number, created_at: r.created_at as string }));
    const latest = await checkChatMeetupRoomAccess(client, roomId, callerId);
    if (!latest.ok || latest.context.matchId !== access.context.matchId || latest.context.userA !== access.context.userA || latest.context.userB !== access.context.userB) return { ok: false, reason: latest.ok ? "not_found" : latest.reason };
    return { ok: true, data: { room_id: roomId, events, next_cursor: null, has_more: hasMore } };
  }
  const latest = await checkChatMeetupRoomAccess(client, roomId, callerId);
  if (!latest.ok) return { ok: false, reason: latest.reason };
  if (latest.context.matchId !== access.context.matchId || latest.context.userA !== access.context.userA || latest.context.userB !== access.context.userB) return { ok: false, reason: "not_found" };
  return { ok: true, data: { room_id: roomId, events, next_cursor: null, has_more: false } };
}

/** Bounded service-role janitor hook; RPC returns only a count and never private input values. */
export async function expireChatMeetupPrivateInputs(client: SupabaseClient<Database>): Promise<number> {
  try {
    const result = await db(client).rpc("prune_chat_meetup_private_inputs", {});
    const row = rpcRow(result.data);
    if (result.error || !row || typeof row.pruned !== "number" || !Number.isInteger(row.pruned) || row.pruned < 0 || row.pruned > 500) return 0;
    return row.pruned;
  } catch { return 0; }
}
