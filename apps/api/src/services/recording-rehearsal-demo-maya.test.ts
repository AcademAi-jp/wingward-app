import { describe, expect, it, vi } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { RECORDING_REHEARSAL_PROFILE_IDS, readRecordingRehearsalConfig, isRecordingRehearsalProfile, isRecordingRehearsalSoraInterviewActive, createRecordingRehearsalGoogleReservationGuard } from "./recording-rehearsal";
import { isRecordingRehearsalPairMember, runRecordingRehearsalMatching } from "./recording-rehearsal-matching";
import { resolveFoxConversationRecordingWindow, isFoxConversationGenerationAllowed } from "./fox-conversation-recording-window";
import { isRecordingRehearsalMeetupReady, reserveRecordingRehearsalReflectionAttempt } from "./meetup-reflection-recording-window";
const NOW = Date.parse("2026-09-30T02:25:00Z");
const MAYA = "a88a89e2-5421-5ce9-a33b-76d512898c37";
const REN = "9d836fee-7b93-41ce-b577-34a63006aaea";
const ENV = {
 RECORDING_REHEARSAL_ENABLED: "enabled", RECORDING_REHEARSAL_PAIR: "demo-maya-ren",
 RECORDING_REHEARSAL_ISSUED_AT: "2026-09-30T02:20:00Z", RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-30T04:20:00Z",
};
function config(prep = false) {
 const result = readRecordingRehearsalConfig({ ...ENV, RECORDING_REHEARSAL_OWNER_PREP_ONLY: prep ? "enabled" : "disabled" }, NOW);
 if (result.kind !== "active") throw new Error("Expected active synthetic window");
 return result.config;
}
describe("Maya/Ren local recording services", () => {
 it("admits exactly the selected pair and refuses a widened runtime allowlist", () => {
  const full = config();
  expect(full.profileIds).toEqual([MAYA, REN]);
  expect(RECORDING_REHEARSAL_PROFILE_IDS).toHaveLength(3);
  for (const id of [MAYA, REN]) expect(isRecordingRehearsalProfile(full, id, NOW)).toBe(true);
  for (const id of [RECORDING_REHEARSAL_PROFILE_IDS[0], RECORDING_REHEARSAL_PROFILE_IDS[2], "e7c595cb-ff44-5611-aff1-44fb0ca8bf58"]) expect(isRecordingRehearsalProfile(full, id, NOW)).toBe(false);
  expect(isRecordingRehearsalPairMember(full, MAYA, NOW)).toBe(true);
  expect(isRecordingRehearsalPairMember({ ...full, profileIds: [...full.profileIds, RECORDING_REHEARSAL_PROFILE_IDS[0]] }, MAYA, NOW)).toBe(false);
 });
 it("blocks owner-prep Start before any database work", async () => {
  const from = vi.fn();
  await expect(runRecordingRehearsalMatching({ from } as unknown as SupabaseClient<Database>, config(true), MAYA, "start", () => NOW)).resolves.toEqual({ outcome: "expired", count: 0 });
  expect(from).not.toHaveBeenCalled();
 });
 it("blocks owner-prep Google admission before reservation", async () => {
  const admission = vi.fn().mockResolvedValue(true);
  const guard = createRecordingRehearsalGoogleReservationGuard(config(true), admission, () => NOW);
  await expect(guard({ operation: "google_places_details", units: 1, idempotencyKey: "11111111-1111-4111-8111-111111111111" })).resolves.toBe(false);
  expect(admission).not.toHaveBeenCalled();
 });
 it("allows Fox generation only for the exact pair in full unexpired mode", () => {
  const full = resolveFoxConversationRecordingWindow(ENV, MAYA, REN, NOW);
  expect(isFoxConversationGenerationAllowed(full, REN, MAYA, NOW)).toBe(true);
  expect(isFoxConversationGenerationAllowed(full, RECORDING_REHEARSAL_PROFILE_IDS[0], REN, NOW)).toBe(false);
  expect(isFoxConversationGenerationAllowed(full, MAYA, REN, Date.parse(ENV.RECORDING_REHEARSAL_EXPIRES_AT))).toBe(false);
  const prep = resolveFoxConversationRecordingWindow({ ...ENV, RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enabled" }, MAYA, REN, NOW);
  expect(prep.kind).toBe("invalid");
  expect(isFoxConversationGenerationAllowed(prep, MAYA, REN, NOW)).toBe(false);
 });
 it("reflection needs actual end, own completion and full mode", () => {
  const full = config();
  const meetupId = "22222222-2222-4222-8222-222222222222";
  const session = { meetup_id: meetupId, match_id: "33333333-3333-4333-8333-333333333333", room_id: "44444444-4444-4444-8444-444444444444", user_a_id: MAYA, user_b_id: REN, status: "completed", confirmed_ends_at: new Date(NOW - 60_000).toISOString(), completed_a_at: new Date(NOW - 60_000).toISOString(), completed_b_at: null };
  expect(isRecordingRehearsalMeetupReady(full, meetupId, MAYA, session, NOW)).toBe(true);
  expect(isRecordingRehearsalMeetupReady(full, meetupId, REN, session, NOW)).toBe(false);
  expect(isRecordingRehearsalMeetupReady(full, meetupId, MAYA, { ...session, confirmed_ends_at: new Date(NOW + 60 * 60_000).toISOString() }, NOW)).toBe(false);
  expect(isRecordingRehearsalMeetupReady(full, meetupId, MAYA, { ...session, completed_a_at: null }, NOW)).toBe(false);
  expect(isRecordingRehearsalMeetupReady(config(true), meetupId, MAYA, session, NOW)).toBe(false);
  expect(reserveRecordingRehearsalReflectionAttempt(config(true), "voice", NOW)).toBe(false);
  expect(reserveRecordingRehearsalReflectionAttempt(config(true), "draft", NOW)).toBe(false);
 });
});


describe("Maya/Ren disabled Sora tombstone", () => {
 const tombstone = {
  RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled",
  RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: "2026-09-30T01:40:00Z",
  RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-30T02:10:00Z",
 };
 it("accepts absent or complete expired disabled keys with no Sora admission", async () => {
  for (const oldKeys of [{}, tombstone]) {
   const env = { ...ENV, ...oldKeys, RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enabled" };
   const result = readRecordingRehearsalConfig(env, NOW);
   if (result.kind !== "active") throw new Error("Expected bounded preparation");
   expect(result.config.profileIds).toEqual([MAYA, REN]);
   expect(result.config.soraInterviewAdmission).toBeUndefined();
   expect(isRecordingRehearsalSoraInterviewActive(result.config, NOW)).toBe(false);
   expect(isRecordingRehearsalProfile(result.config, RECORDING_REHEARSAL_PROFILE_IDS[2], NOW)).toBe(false);
   const admission = vi.fn();
   await expect(createRecordingRehearsalGoogleReservationGuard(result.config, admission, () => NOW)({ operation: "google_places_details", units: 1, idempotencyKey: "11111111-1111-4111-8111-111111111111" })).resolves.toBe(false);
   expect(admission).not.toHaveBeenCalled();
   expect(resolveFoxConversationRecordingWindow(env, MAYA, REN, NOW).kind).toBe("invalid");
  }
 });
 it.each([
  { RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "enabled" },
  { RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disable" },
  { RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: undefined },
  { RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: undefined },
  { RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: "2026-09-30T01:40:00+00:00" },
  { RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-30T02:10:00.001Z" },
  { RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-30T01:39:00Z" },
  { RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: "2026-09-30T02:20:00Z", RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-30T02:30:00Z" },
 ])("rejects active, partial, malformed, too long or unexpired Sora interval %#", (override) => {
  expect(readRecordingRehearsalConfig({ ...ENV, ...tombstone, ...override }, NOW)).toEqual({ kind: "invalid" });
 });
});
