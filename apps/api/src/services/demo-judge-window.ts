import { DEMO_20260930_PROFILE_IDS, SYNTHETIC_MATCHING_PROFILE_IDS } from "./synthetic-matching-cohort";
import { hasRecordingRehearsalConfig, type RecordingRehearsalBindings } from "./recording-rehearsal";
export type DemoJudgeBindings = Readonly<{
 DEMO_JUDGE_ENABLED?: string; DEMO_JUDGE_COHORT?: string; DEMO_JUDGE_ISSUED_AT?: string; DEMO_JUDGE_EXPIRES_AT?: string;
}>;
export type ValidatedDemoJudgeConfig = Readonly<{ kind: "demo-judge"; issuedAt: string; expiresAt: string; issuedAtMs: number; expiresAtMs: number; profileIds: readonly string[] }>;
const KEYS = ["DEMO_JUDGE_ENABLED", "DEMO_JUDGE_COHORT", "DEMO_JUDGE_ISSUED_AT", "DEMO_JUDGE_EXPIRES_AT"] as const;
export function hasDemoJudgeConfig(env: DemoJudgeBindings | undefined): boolean { return Object.keys(env ?? {}).some(key => key.startsWith("DEMO_JUDGE_") && (env as Record<string, unknown>)[key] !== undefined); }
function strictTime(value: unknown): number | null {
 if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value)) return null;
 const parsed = Date.parse(value); if (!Number.isFinite(parsed)) return null;
 return new Date(parsed).toISOString() === (value.includes(".") ? value : value.slice(0,-1)+".000Z") ? parsed : null;
}
export function isDemoJudgeActive(config: ValidatedDemoJudgeConfig | undefined, now = Date.now()): config is ValidatedDemoJudgeConfig {
 return !!config && config.kind === "demo-judge" && Number.isFinite(now) && now >= config.issuedAtMs && now < config.expiresAtMs;
}
export function isDemoJudgePair(config: ValidatedDemoJudgeConfig | undefined, first: string, second: string, now = Date.now()): boolean {
 return isDemoJudgeActive(config, now) && first !== second && config.profileIds.includes(first as typeof config.profileIds[number]) && config.profileIds.includes(second as typeof config.profileIds[number]);
}
/** Only explicit expired/disabled tombstones may coexist; no active legacy authority is inherited. */
function closedLegacyConfig(env: Record<string, unknown>, now: number): boolean {
 const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
 const disabled = (key: string) => env[key] === undefined || env[key] === "disabled";
 if (hasRecordingRehearsalConfig(env as RecordingRehearsalBindings)) {
  const issued = strictTime(env.RECORDING_REHEARSAL_ISSUED_AT), expires = strictTime(env.RECORDING_REHEARSAL_EXPIRES_AT);
  if (env.RECORDING_REHEARSAL_ENABLED !== "disabled" || issued === null || expires === null || expires > now || expires <= issued || expires-issued > 2*60*60_000
   || !["aoi-ren","sora-ren","demo-maya-ren"].includes(String(env.RECORDING_REHEARSAL_PAIR))
   || !disabled("RECORDING_REHEARSAL_OWNER_PREP_ONLY") || !disabled("RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED")
   || (env.RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID !== undefined && (env.RECORDING_REHEARSAL_PAIR !== "demo-maya-ren" || !uuid.test(String(env.RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID))))) return false;
  const interviewKeys=["RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED","RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT","RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT"];
  if (interviewKeys.some(key=>env[key]!==undefined)) {
   const i=strictTime(env[interviewKeys[1]]),e=strictTime(env[interviewKeys[2]]);
   if (env[interviewKeys[0]]!=="disabled" || i===null || e===null || e<=i || e>now || e-i>30*60_000) return false;
  }
 }
 const e2eKeys=Object.keys(env).filter(key=>key.startsWith("PRODUCTION_E2E_")&&env[key]!==undefined);
 if (e2eKeys.length) {
  const known=["PRODUCTION_E2E_PROFILE_IDS","PRODUCTION_E2E_EXPIRES_AT","PRODUCTION_E2E_READ_ONLY","PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS","PRODUCTION_E2E_RECORDING_WINDOW"];
  if (e2eKeys.some(key=>!known.includes(key))) return false;
  const expires=strictTime(env.PRODUCTION_E2E_EXPIRES_AT),recording=strictTime(env.PRODUCTION_E2E_RECORDING_WINDOW);
  if (env.PRODUCTION_E2E_RECORDING_WINDOW!==undefined && (recording===null || recording>now)) return false;
  const parseIds=(value:unknown) => typeof value==="string" && value.split(",").length<=3 && value.split(",").every(id=>uuid.test(id.trim())) && new Set(value.split(",").map(id=>id.trim())).size===value.split(",").length;
  if (env.PRODUCTION_E2E_PROFILE_IDS!==undefined || env.PRODUCTION_E2E_EXPIRES_AT!==undefined || env.PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS!==undefined) {
   if (expires===null || expires>now || !parseIds(env.PRODUCTION_E2E_PROFILE_IDS)) return false;
   if (env.PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS!==undefined && (!parseIds(env.PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS) || !SYNTHETIC_MATCHING_PROFILE_IDS.every(id => String(env.PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS).split(",").map(value=>value.trim()).includes(id)))) return false;
  } else if (recording===null) return false;
  if (env.PRODUCTION_E2E_READ_ONLY!==undefined && env.PRODUCTION_E2E_READ_ONLY!=="true" && env.PRODUCTION_E2E_READ_ONLY!=="false") return false;
 }
 return true;
}
export function readDemoJudgeConfig(env: (DemoJudgeBindings & RecordingRehearsalBindings & Record<string, unknown>) | undefined, now = Date.now()): {kind:"absent"}|{kind:"invalid"}|{kind:"active";config:ValidatedDemoJudgeConfig} {
 if (!hasDemoJudgeConfig(env)) return {kind:"absent"};
 if (Object.keys(env ?? {}).some(key => key.startsWith("DEMO_JUDGE_") && !(KEYS as readonly string[]).includes(key))) return {kind:"invalid"};
 const issued = strictTime(env?.DEMO_JUDGE_ISSUED_AT), expires = strictTime(env?.DEMO_JUDGE_EXPIRES_AT);
 if (env?.DEMO_JUDGE_ENABLED === "disabled") {
  return env.DEMO_JUDGE_COHORT === "demo-20260930" && issued !== null && expires !== null && expires <= now && expires > issued && expires-issued <= 2*60*60_000 && Number.isFinite(now) ? {kind:"absent"} : {kind:"invalid"};
 }
 if (!closedLegacyConfig(env ?? {},now)) return {kind:"invalid"};
 if (env?.DEMO_JUDGE_ENABLED !== "enabled" || env.DEMO_JUDGE_COHORT !== "demo-20260930" || issued === null || expires === null || issued > now || expires <= now || expires <= issued || expires-issued > 2*60*60_000 || !Number.isFinite(now)) return {kind:"invalid"};
 return {kind:"active",config:Object.freeze({kind:"demo-judge",issuedAt:env.DEMO_JUDGE_ISSUED_AT!,expiresAt:env.DEMO_JUDGE_EXPIRES_AT!,issuedAtMs:issued,expiresAtMs:expires,profileIds:DEMO_20260930_PROFILE_IDS})};
}
