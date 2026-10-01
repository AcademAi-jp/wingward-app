import { describe, expect, it } from "vitest";
import { readDemoJudgeConfig, isDemoJudgePair, hasDemoJudgeConfig } from "./demo-judge-window";
import { resolveFoxConversationRecordingWindow, isFoxConversationGenerationAllowed } from "./fox-conversation-recording-window";
import { DEMO_20260930_PROFILE_IDS, SYNTHETIC_MATCHING_PROFILE_IDS } from "./synthetic-matching-cohort";
const NOW=Date.parse("2026-09-30T10:00:00Z");
const ENV={DEMO_JUDGE_ENABLED:"enabled",DEMO_JUDGE_COHORT:"demo-20260930",DEMO_JUDGE_ISSUED_AT:"2026-09-30T10:00:00Z",DEMO_JUDGE_EXPIRES_AT:"2026-09-30T12:00:00Z"};
const CLOSED={RECORDING_REHEARSAL_ENABLED:"disabled",RECORDING_REHEARSAL_PAIR:"sora-ren",RECORDING_REHEARSAL_ISSUED_AT:"2026-09-30T02:20:00Z",RECORDING_REHEARSAL_EXPIRES_AT:"2026-09-30T02:50:00Z",RECORDING_REHEARSAL_OWNER_PREP_ONLY:"disabled",RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED:"disabled",RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED:"disabled",RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT:"2026-09-30T01:40:00Z",RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT:"2026-09-30T02:10:00Z",PRODUCTION_E2E_PROFILE_IDS:SYNTHETIC_MATCHING_PROFILE_IDS[0],PRODUCTION_E2E_EXPIRES_AT:"2026-09-22T11:30:00Z",PRODUCTION_E2E_READ_ONLY:"false"};
describe("fixed twenty judge window",()=>{
 it("is absent by default and admits only distinct fixed20 pairs in the canonical bounded window",()=>{
  expect(hasDemoJudgeConfig(undefined)).toBe(false);expect(readDemoJudgeConfig(undefined,NOW)).toEqual({kind:"absent"});
  const r=readDemoJudgeConfig(ENV,NOW);if(r.kind!=="active")throw Error("Expected judge window");
  expect(r.config.profileIds).toHaveLength(20);expect(isDemoJudgePair(r.config,DEMO_20260930_PROFILE_IDS[0],DEMO_20260930_PROFILE_IDS[1],NOW)).toBe(true);
  for(const outsider of [...SYNTHETIC_MATCHING_PROFILE_IDS,"11111111-1111-4111-8111-111111111111"])expect(isDemoJudgePair(r.config,DEMO_20260930_PROFILE_IDS[0],outsider,NOW)).toBe(false);
  expect(isDemoJudgePair(r.config,DEMO_20260930_PROFILE_IDS[0],DEMO_20260930_PROFILE_IDS[0],NOW)).toBe(false);
 });
 it.each([{DEMO_JUDGE_ENABLED:"disabled"},{DEMO_JUDGE_COHORT:"all"},{DEMO_JUDGE_EXPIRES_AT:undefined},{DEMO_JUDGE_EXPIRES_AT:"2026-09-30T12:00:00.001Z"},{DEMO_JUDGE_ISSUED_AT:"2026-09-30T10:00:01Z"},{DEMO_JUDGE_ISSUED_AT:"2026-09-30T10:00:00+00:00"},{DEMO_JUDGE_EXPIRES_AT:"2026-02-30T12:00:00Z"},{RECORDING_REHEARSAL_ENABLED:"enabled"},{PRODUCTION_E2E_EXPIRES_AT:"2099-01-01T00:00:00Z"}])("rejects malformed/expired/conflicting configuration %#",override=>expect(readDemoJudgeConfig({...ENV,...override},NOW)).toEqual({kind:"invalid"}));
 it("accepts only explicit complete disabled expired legacy tombstones",()=>{
  expect(readDemoJudgeConfig({...ENV,...CLOSED},NOW).kind).toBe("active");
  for(const override of [{RECORDING_REHEARSAL_ENABLED:"enabled"},{RECORDING_REHEARSAL_OWNER_PREP_ONLY:"enabled"},{RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED:"enabled"},{RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT:undefined},{RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT:"2026-09-30T02:10:00.001Z"},{PRODUCTION_E2E_EXPIRES_AT:"2099-01-01T00:00:00Z"},{PRODUCTION_E2E_READ_ONLY:"yes"}])expect(readDemoJudgeConfig({...ENV,...CLOSED,...override},NOW)).toEqual({kind:"invalid"});
 });
 it("provider window permits ordinary scoped pairs only and closes expired admission without legacy fallback",()=>{
  const [a,b]=DEMO_20260930_PROFILE_IDS;
  const w=resolveFoxConversationRecordingWindow(ENV,a,b,NOW);expect(w.kind).toBe("judge");expect(isFoxConversationGenerationAllowed(w,a,b,NOW)).toBe(true);
  expect(isFoxConversationGenerationAllowed(w,a,SYNTHETIC_MATCHING_PROFILE_IDS[1],NOW)).toBe(false);
  expect(isFoxConversationGenerationAllowed(w,a,b,NOW+2*60*60_000)).toBe(false);
 });
});

describe("strict bidirectional closed-mode transitions",()=>{
 const disabled={...ENV,DEMO_JUDGE_ENABLED:"disabled",DEMO_JUDGE_ISSUED_AT:"2026-09-30T06:00:00Z",DEMO_JUDGE_EXPIRES_AT:"2026-09-30T08:00:00Z"};
 const recording={RECORDING_REHEARSAL_ENABLED:"enabled",RECORDING_REHEARSAL_PAIR:"demo-maya-ren",RECORDING_REHEARSAL_ISSUED_AT:ENV.DEMO_JUDGE_ISSUED_AT,RECORDING_REHEARSAL_EXPIRES_AT:ENV.DEMO_JUDGE_EXPIRES_AT};
 it("accepts expired disabled Maya recording admission UUID as inert metadata",()=>{
  const old={...CLOSED,RECORDING_REHEARSAL_PAIR:"demo-maya-ren",RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID:"11111111-1111-4111-8111-111111111111"};
  expect(readDemoJudgeConfig({...ENV,...old},NOW).kind).toBe("active");
  for(const bad of ["", "not-a-uuid"])expect(readDemoJudgeConfig({...ENV,...old,RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID:bad},NOW).kind).toBe("invalid");
  expect(readDemoJudgeConfig({...ENV,...old,RECORDING_REHEARSAL_PAIR:"sora-ren"},NOW).kind).toBe("invalid");
 });
 it("expired disabled judge is inert and permits a new active recording window",()=>{
  expect(hasDemoJudgeConfig(disabled)).toBe(true);expect(readDemoJudgeConfig({...disabled,...recording},NOW).kind).toBe("absent");
  expect(resolveFoxConversationRecordingWindow({...disabled,...recording},"a88a89e2-5421-5ce9-a33b-76d512898c37","9d836fee-7b93-41ce-b577-34a63006aaea",NOW).kind).toBe("active");
 });
 it.each([{DEMO_JUDGE_EXPIRES_AT:undefined},{DEMO_JUDGE_EXPIRES_AT:"2026-09-30T12:00:00Z"},{DEMO_JUDGE_COHORT:"other"},{DEMO_JUDGE_ISSUED_AT:"2026-09-30T08:00:00Z"},{DEMO_JUDGE_UNKNOWN:"x"}])("malformed or unexpired disabled judge stays closed %#",override=>expect(readDemoJudgeConfig({...disabled,...recording,...override},NOW).kind).toBe("invalid"));
});
