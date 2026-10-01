import { afterEach, describe, expect, it, vi } from "vitest";
import { readRecordingRehearsalConfig } from "./recording-rehearsal";
import { checkSyntheticRecordingAdmission, recordingAdmissionRpc } from "./synthetic-recording-admission";
const NOW = Date.parse("2026-09-30T06:00:00Z");
const ID = "70000000-0000-4000-8000-000000000009";
const MAYA = "a88a89e2-5421-5ce9-a33b-76d512898c37";
const REN = "9d836fee-7b93-41ce-b577-34a63006aaea";
const ROOM = "40000000-0000-4000-8000-000000000001";
const MATCH = "20000000-0000-4000-8000-000000000001";
const MEETUP = "30000000-0000-4000-8000-000000000001";
const ENV = { RECORDING_REHEARSAL_ENABLED: "enabled", RECORDING_REHEARSAL_PAIR: "demo-maya-ren", RECORDING_REHEARSAL_ISSUED_AT: "2026-09-30T05:59:00Z", RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-30T07:59:00Z", RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID: ID };
function config() { const r = readRecordingRehearsalConfig(ENV, NOW); if (r.kind !== "active") throw new Error("Expected synthetic config"); return r.config; }
function metadata() { return { outcome: "admitted", admission_id: ID, user_a_id: REN, user_b_id: MAYA, room_id: ROOM, match_id: MATCH, meetup_id: MEETUP, issued_at: ENV.RECORDING_REHEARSAL_ISSUED_AT, expires_at: ENV.RECORDING_REHEARSAL_EXPIRES_AT }; }
afterEach(() => vi.useRealTimers());
describe("private synthetic recording admission", () => {
 it("checks DB-backed exact scope and window without exposing permit ID in projection", async () => {
  const rpc = vi.fn(async () => ({ data: [metadata()], error: null }));
  const a = await checkSyntheticRecordingAdmission({ rpc }, config(), MAYA, { roomId: ROOM, matchId: MATCH }, () => NOW);
  expect(a?.projection).toEqual({ kind: "fictional-demo", pair: "demo-maya-ren", identity_verified: false, expires_at: ENV.RECORDING_REHEARSAL_EXPIRES_AT });
  expect(rpc).toHaveBeenCalledWith("check_synthetic_recording_admission", { p_admission_id: ID, p_user_id: MAYA, p_room_id: ROOM, p_meetup_id: null, p_issued_at: ENV.RECORDING_REHEARSAL_ISSUED_AT, p_expires_at: ENV.RECORDING_REHEARSAL_EXPIRES_AT });
 });
 it.each([
  { outcome: "not_found" }, { admission_id: ROOM }, { user_a_id: MAYA },
  { user_b_id: "e7c595cb-ff44-5611-aff1-44fb0ca8bf58" }, { room_id: ID }, { match_id: ID }, { meetup_id: ID },
  { issued_at: "2026-09-30T05:58:00Z" }, { expires_at: "2026-09-30T08:00:00Z" },
 ])("refuses metadata mismatch %# without wrapper fallback", async (override) => {
  const rpc = vi.fn(async () => ({ data: { ...metadata(), ...override }, error: null }));
  expect(await checkSyntheticRecordingAdmission({ rpc }, config(), MAYA, { roomId: ROOM, matchId: MATCH, meetupId: MEETUP }, () => NOW)).toBeNull();
  expect(rpc).toHaveBeenCalledOnce();
 });
 it("rejects other actor, prep, absent permit, expired permit before DB", async () => {
  const rpc = vi.fn();
  for (const c of [undefined, { ...config(), ownerPrepOnly: true }, { ...config(), syntheticTestAdmissionId: undefined }, { ...config(), expiresAtMs: NOW }]) expect(await checkSyntheticRecordingAdmission({ rpc }, c, MAYA, { roomId: ROOM }, () => NOW)).toBeNull();
  expect(await checkSyntheticRecordingAdmission({ rpc }, config(), "e7c595cb-ff44-5611-aff1-44fb0ca8bf58", { roomId: ROOM }, () => NOW)).toBeNull();
  expect(rpc).not.toHaveBeenCalled();
 });
 it("rechecks expiry after DB await", async () => {
  let clock = NOW;
  const rpc = vi.fn(async () => { clock = config().expiresAtMs; return { data: metadata(), error: null }; });
  expect(await checkSyntheticRecordingAdmission({ rpc }, config(), MAYA, { roomId: ROOM }, () => clock)).toBeNull();
 });
 it("uses named explicit wrapper arguments and closes after expiry", async () => {
  vi.useFakeTimers(); vi.setSystemTime(NOW);
  const rpc = vi.fn(async () => ({ data: metadata(), error: null }));
  const admission = await checkSyntheticRecordingAdmission({ rpc }, config(), MAYA, { roomId: ROOM });
  if (!admission) throw new Error("Expected admission"); rpc.mockClear();
  await recordingAdmissionRpc({ rpc }, "claim_meetup_arrangement", { p_meetup_id: MEETUP, p_user_id: MAYA, p_is_retry: false, p_operation_key: "ordinary-key" }, admission);
  expect(rpc).toHaveBeenCalledWith("demo_recording_claim_meetup_arrangement", expect.objectContaining({ p_admission_id: ID, p_operation_key: "ordinary-key", p_is_retry: false }));
  rpc.mockClear(); vi.setSystemTime(config().expiresAtMs);
  expect((await recordingAdmissionRpc({ rpc }, "claim_meetup_arrangement", {}, admission)).error).toBeTruthy();
  expect(rpc).not.toHaveBeenCalled();
 });
 it("binding is fail closed outside the full exact pair", () => {
  for (const override of [{ RECORDING_REHEARSAL_PAIR: "sora-ren" }, { RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enabled" }, { RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID: "bad" }]) expect(readRecordingRehearsalConfig({ ...ENV, ...override }, NOW)).toEqual({ kind: "invalid" });
 });
});
