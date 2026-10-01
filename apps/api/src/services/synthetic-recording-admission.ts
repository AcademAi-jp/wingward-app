import {
  isRecordingRehearsalActive, RECORDING_REHEARSAL_GENERATION_PAIRS,
  type ValidatedRecordingRehearsalConfig,
} from "./recording-rehearsal";

export type SyntheticTestAdmissionProjection = Readonly<{
  kind: "fictional-demo";
  pair: "demo-maya-ren";
  identity_verified: false;
  expires_at: string;
}>;
export type SyntheticRecordingAdmission = Readonly<{
  config: ValidatedRecordingRehearsalConfig;
  matchId: string;
  roomId: string;
  meetupId: string | null;
  projection: SyntheticTestAdmissionProjection;
}>;
type RpcClient = { rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: unknown }> };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function syntheticRecordingConfigActive(config: ValidatedRecordingRehearsalConfig | undefined, nowMs = Date.now()): config is ValidatedRecordingRehearsalConfig & { syntheticTestAdmissionId: string } {
  const pair = RECORDING_REHEARSAL_GENERATION_PAIRS["demo-maya-ren"];
  return isRecordingRehearsalActive(config, nowMs) && !config.ownerPrepOnly
    && config.pair === "demo-maya-ren" && typeof config.syntheticTestAdmissionId === "string"
    && UUID.test(config.syntheticTestAdmissionId)
    && config.generationPair.length === 2 && config.generationPair.every((id, i) => id === pair[i])
    && config.profileIds.length === 2 && new Set(config.profileIds).size === 2 && config.profileIds.every(id => pair.includes(id as typeof pair[number]));
}

/** Trusted server config + private DB metadata only; request bodies cannot supply a permit. */
export async function checkSyntheticRecordingAdmission(
  client: RpcClient, config: ValidatedRecordingRehearsalConfig | undefined,
  userId: string, scope: { roomId?: string; meetupId?: string; matchId?: string }, now: () => number = Date.now,
): Promise<SyntheticRecordingAdmission | null> {
  if (!syntheticRecordingConfigActive(config, now()) || !config.generationPair.some(id => id === userId)
    || (!scope.roomId && !scope.meetupId) || (scope.roomId && !UUID.test(scope.roomId))
    || (scope.meetupId && !UUID.test(scope.meetupId))) return null;
  let result: { data: unknown; error: unknown };
  try {
    result = await client.rpc("check_synthetic_recording_admission", {
      p_admission_id: config.syntheticTestAdmissionId, p_user_id: userId,
      p_room_id: scope.roomId ?? null, p_meetup_id: scope.meetupId ?? null,
      p_issued_at: config.issuedAt, p_expires_at: config.expiresAt,
    });
  } catch { return null; }
  if (!syntheticRecordingConfigActive(config, now()) || result.error) return null;
  const value = Array.isArray(result.data) && result.data.length === 1 ? result.data[0] : result.data;
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  const pair = config.generationPair as readonly string[];
  if (row.outcome !== "admitted" || row.admission_id !== config.syntheticTestAdmissionId
    || typeof row.user_a_id !== "string" || typeof row.user_b_id !== "string" || row.user_a_id === row.user_b_id
    || !pair.includes(row.user_a_id) || !pair.includes(row.user_b_id)
    || typeof row.match_id !== "string" || !UUID.test(row.match_id) || (scope.matchId && row.match_id !== scope.matchId)
    || typeof row.room_id !== "string" || !UUID.test(row.room_id) || (scope.roomId && row.room_id !== scope.roomId)
    || (row.meetup_id !== null && (typeof row.meetup_id !== "string" || !UUID.test(row.meetup_id)))
    || (scope.meetupId && row.meetup_id !== scope.meetupId)
    || typeof row.issued_at !== "string" || Date.parse(row.issued_at) !== config.issuedAtMs
    || typeof row.expires_at !== "string" || Date.parse(row.expires_at) !== config.expiresAtMs) return null;
  return Object.freeze({ config, matchId: row.match_id, roomId: row.room_id, meetupId: row.meetup_id as string | null,
    projection: Object.freeze({ kind: "fictional-demo", pair: "demo-maya-ren", identity_verified: false, expires_at: config.expiresAt }) });
}

/** Dedicated SQL wrappers recheck and atomically bind the permit; ordinary RPCs stay strict. */
export async function recordingAdmissionRpc(client: RpcClient, name: string, args: Record<string, unknown>, admission: SyntheticRecordingAdmission | undefined): Promise<{ data: unknown; error: unknown }> {
  if (!admission) return client.rpc(name, args);
  if (!syntheticRecordingConfigActive(admission.config)) return { data: null, error: "Synthetic test admission unavailable" };
  return client.rpc(`demo_recording_${name}`, { ...args, p_admission_id: admission.config.syntheticTestAdmissionId,
    p_issued_at: admission.config.issuedAt, p_expires_at: admission.config.expiresAt });
}
