import { z } from "zod";
import type { Env } from "../env";
import { JUDGE_SEVEN_OWNER_PROFILE_IDS } from "./synthetic-matching-cohort";

export const JUDGE_COHORT = "shipaton-20261001" as const;
export const JUDGE_EXPIRES_AT = "2026-10-13T19:00:00Z";
export const OWNER_QA_AI_EXPIRES_AT = "2026-10-01T00:00:00Z";
const KEYS = ["JUDGE_ACCESS_ENABLED", "JUDGE_ACCESS_COHORT", "JUDGE_ACCESS_ISSUED_AT", "JUDGE_ACCESS_EXPIRES_AT", "JUDGE_ACCESS_AI_EXPIRES_AT", "JUDGE_ACCESS_OWNER_AI_EXPIRES_AT"] as const;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export type JudgeAccessConfig = Readonly<{ issuedAtMs: number; expiresAtMs: number; aiExpiresAtMs: number; ownerAiExpiresAtMs?: number }>;
export type JudgeAccess = Readonly<{ actorId: string; accountKind: "judge" | "owner" | "qa"; counterpartId: string; expiresAtMs: number }>;
export const JUDGE_PROVIDER_OPERATIONS = ["personas_generate", "profile_generate", "ward_generate", "ward_conversation", "ward_greeting", "ward_chat", "reflection_draft", "voice_session", "reflection_voice"] as const;
export type JudgeProviderOperation = typeof JUDGE_PROVIDER_OPERATIONS[number];
export type JudgeRpcClient = { rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: unknown }> };
/** Keep the generated whole-client type outside the narrow service-only RPC surface. */
export function judgeRpcClient(value: unknown): JudgeRpcClient {
 const client=value as {rpc(name:string,args:Record<string,unknown>):PromiseLike<{data:unknown;error:unknown}>};
 return {rpc:async(name,args)=>await client.rpc(name,args)};
}
export function strictJudgeTime(value: unknown): number | null {
 if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value)) return null;
 const ms=Date.parse(value);return Number.isFinite(ms) && new Date(ms).toISOString()===(value.includes(".")?value:value.slice(0,-1)+".000Z")?ms:null;
}
export function hasJudgeAccessConfig(env: Env["Bindings"] | undefined): boolean {
 return Object.keys(env??{}).some(key=>key.startsWith("JUDGE_ACCESS_") && (env as Record<string,unknown>)[key]!==undefined);
}
export function readJudgeAccessConfig(env: Env["Bindings"] | undefined, now=Date.now()): {kind:"absent"}|{kind:"invalid"}|{kind:"active";config:JudgeAccessConfig} {
 if (!hasJudgeAccessConfig(env)) return {kind:"absent"};
 if (!Number.isFinite(now) || Object.keys(env??{}).some(key=>key.startsWith("JUDGE_ACCESS_") && !(KEYS as readonly string[]).includes(key))) return {kind:"invalid"};
 const issued=strictJudgeTime(env?.JUDGE_ACCESS_ISSUED_AT),expires=strictJudgeTime(env?.JUDGE_ACCESS_EXPIRES_AT),aiExpires=strictJudgeTime(env?.JUDGE_ACCESS_AI_EXPIRES_AT);
 const ownerBinding=env?.JUDGE_ACCESS_OWNER_AI_EXPIRES_AT;
 const ownerExpires=ownerBinding===undefined?undefined:strictJudgeTime(ownerBinding);
 if(env?.JUDGE_ACCESS_ENABLED!=="enabled" || env.JUDGE_ACCESS_COHORT!==JUDGE_COHORT || issued===null || expires===null || aiExpires===null
  || env.JUDGE_ACCESS_EXPIRES_AT!==JUDGE_EXPIRES_AT || env.JUDGE_ACCESS_AI_EXPIRES_AT!==OWNER_QA_AI_EXPIRES_AT
  || ownerExpires===null || (ownerBinding!==undefined && ownerBinding!==JUDGE_EXPIRES_AT)
  || issued<Date.parse("2026-09-30T00:00:00Z") || issued>now || expires<=now || expires<=issued
  || (ownerExpires===undefined && aiExpires<=issued)) return {kind:"invalid"};
 return {kind:"active",config:Object.freeze({issuedAtMs:issued,expiresAtMs:expires,aiExpiresAtMs:aiExpires,...(ownerExpires===undefined?{}:{ownerAiExpiresAtMs:ownerExpires})})};
}
function accountAiDeadline(config:JudgeAccessConfig,kind:unknown,actorId:string):number {
 if(kind==="judge")return config.expiresAtMs;
 if(kind==="owner" && (JUDGE_SEVEN_OWNER_PROFILE_IDS as readonly string[]).includes(actorId))
  return config.ownerAiExpiresAtMs??config.aiExpiresAtMs;
 return config.aiExpiresAtMs;
}
export function isJudgeAccessActive(access: JudgeAccess | undefined,now=Date.now()): access is JudgeAccess {
 return !!access && Number.isFinite(now) && now<access.expiresAtMs;
}
function row(value: unknown): Record<string,unknown> | null {
 const item=Array.isArray(value)&&value.length===1?value[0]:value;
 return typeof item==="object" && item!==null && !Array.isArray(item)?item as Record<string,unknown>:null;
}
export async function readJudgeAccess(client:JudgeRpcClient,config:JudgeAccessConfig,actorId:string,now:()=>number=Date.now):Promise<JudgeAccess|null>{
 if(!UUID.test(actorId) || now()>=config.expiresAtMs) return null;
 try {
  const result=await client.rpc("check_judge_access",{p_user_id:actorId});const record=row(result.data);
  if(result.error || !record || record.outcome!=="allowed" || record.actor_user_id!==actorId
   || !["judge","owner","qa"].includes(record.account_kind as string) || typeof record.counterpart_user_id!=="string" || !UUID.test(record.counterpart_user_id) || record.counterpart_user_id===actorId) return null;
  // Postgres timestamptz uses offsets; only canonical dates and explicit timezones are admitted.
  const expires=z.string().datetime({offset:true}).safeParse(record.expires_at).success?Date.parse(record.expires_at as string):NaN;
  if(!Number.isFinite(expires) || !/(?:Z|[+-]\d{2}:\d{2})$/.test(record.expires_at as string) || expires>config.expiresAtMs) return null;
  const boundedExpiry=Math.min(expires,accountAiDeadline(config,record.account_kind,actorId));
  if(now()>=boundedExpiry) return null;
  return Object.freeze({actorId,accountKind:record.account_kind as JudgeAccess["accountKind"],counterpartId:record.counterpart_user_id,expiresAtMs:boundedExpiry});
 }catch{return null;}
}
export async function consumeJudgeRequest(client:JudgeRpcClient,access:JudgeAccess,key:string,now:()=>number=Date.now):Promise<boolean>{
 if(!isJudgeAccessActive(access,now()) || !UUID.test(key))return false;
 try{const r=await client.rpc("consume_judge_request",{p_user_id:access.actorId,p_idempotency_key:key});const v=row(r.data);return !r.error && v?.outcome==="allowed" && isJudgeAccessActive(access,now());}catch{return false;}
}
export type JudgeProviderReservation={reservationId:string;maxUnits:number;maxSeconds:number};
/** Monetary policies live in the service-only DB; callers cannot supply price or usage ceilings. */
export async function reserveJudgeProviderOperation(client:JudgeRpcClient,access:JudgeAccess,operation:JudgeProviderOperation,key:string,now:()=>number=Date.now):Promise<JudgeProviderReservation|null>{
 if(!isJudgeAccessActive(access,now()) || !(JUDGE_PROVIDER_OPERATIONS as readonly string[]).includes(operation) || !UUID.test(key))return null;
 try{
  const r=await client.rpc("reserve_judge_provider_operation",{p_user_id:access.actorId,p_operation:operation,p_idempotency_key:key});const v=row(r.data);
  // A replay never creates another billable fetch or token. Failed fetches retain their reservation.
  if(r.error || !v || v.outcome!=="allowed" || typeof v.reservation_id!=="string" || !UUID.test(v.reservation_id)
   || !Number.isSafeInteger(v.max_units) || (v.max_units as number)<1 || (v.max_units as number)>100_000
   || !Number.isSafeInteger(v.max_seconds) || (v.max_seconds as number)<0 || (v.max_seconds as number)>240 || !isJudgeAccessActive(access,now()))return null;
  return {reservationId:v.reservation_id,maxUnits:v.max_units as number,maxSeconds:v.max_seconds as number};
 }catch{return null;}
}

/** Authenticated vendor events may resolve only a current private registry identity. */
export async function readJudgeWebhookAccess(client: JudgeRpcClient, config: JudgeAccessConfig, authId: string, now:()=>number=Date.now):Promise<boolean>{
 if(!UUID.test(authId) || now()>=config.expiresAtMs)return false;
 try {
  const r=await client.rpc("check_judge_webhook_access",{p_auth_user_id:authId});const v=row(r.data);
  if(r.error || !v || v.outcome!=="allowed" || v.auth_user_id!==authId || typeof v.actor_user_id!=="string" || !UUID.test(v.actor_user_id)
   || !["judge","owner","qa"].includes(v.account_kind as string) || !z.string().datetime({offset:true}).safeParse(v.expires_at).success)return false;
  const end=Date.parse(v.expires_at as string);
  return Number.isFinite(end) && end<=config.expiresAtMs && now()<Math.min(end,accountAiDeadline(config,v.account_kind,v.actor_user_id));
 }catch{return false;}
}
