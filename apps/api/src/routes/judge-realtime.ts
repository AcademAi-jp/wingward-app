import { Hono, type Context } from "hono";
import { z } from "zod";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { readActiveSpeedDatingSession, readOwnedVirtualPersona, readSpeedDatingOwnerState, isCanonicalUuid } from "../lib/speed-dating-ai";
import { realtimeVoiceSchema } from "../lib/openai-realtime";
import { isJudgeAccessActive, type JudgeAccess, type JudgeRpcClient } from "../services/judge-access";
const inputSchema=z.object({sdp:z.string().min(4).max(65536).refine(value=>value.startsWith("v=0")&&!value.includes("\0")),voice:realtimeVoiceSchema}).strict();
export async function readJudgeVoiceBody(c:Context<Env>):Promise<z.infer<typeof inputSchema>|null>{
 const reader=c.req.raw.body?.getReader();if(!reader)return null;let size=0;const parts:Uint8Array[]=[];
 try{while(true){const part=await reader.read();if(part.done)break;size+=part.value.byteLength;if(size>70_000){await reader.cancel();return null;}parts.push(part.value);}
 const bytes=new Uint8Array(size);let offset=0;for(const p of parts){bytes.set(p,offset);offset+=p.byteLength;}const parsed=inputSchema.safeParse(JSON.parse(new TextDecoder().decode(bytes)));return parsed.success?parsed.data:null;
 }catch{return null;}
}
export async function settleJudgeVoiceReservation(client:JudgeRpcClient,actorId:string,reservationId:string):Promise<boolean>{
 try{
  const result=await client.rpc("settle_judge_voice_session",{p_user_id:actorId,p_reservation_id:reservationId});
  const row=Array.isArray(result.data)&&result.data.length===1?result.data[0]:result.data;
  return !result.error && !!row && typeof row==="object" && !Array.isArray(row)
   && ["settled","replayed"].includes(String((row as Record<string,unknown>).outcome));
 }catch{return false;}
}
export async function reserveJudgeVoice(client:JudgeRpcClient,access:JudgeAccess,id:string,kind:"interview"|"reflection"){
 if(!isJudgeAccessActive(access)||!isCanonicalUuid(id))return null;
 try{
 const r=await client.rpc(kind==="interview"?"reserve_judge_voice_session":"reserve_judge_reflection_voice_session",{
 p_user_id:access.actorId,...(kind==="interview"?{p_session_id:id}:{p_meetup_id:id}),p_idempotency_key:id});
 const row=Array.isArray(r.data)&&r.data.length===1?r.data[0]:r.data;
 if(r.error||!row||typeof row!=="object"||Array.isArray(row))return null;
 const v=row as Record<string,unknown>, expiry=typeof v.expires_at==="string"?Date.parse(v.expires_at):NaN;
 if(v.outcome!=="allowed"||!isCanonicalUuid(v.reservation_id))return null;
 if(!Number.isSafeInteger(v.max_units)||(v.max_units as number)<256||(v.max_units as number)>20000||!Number.isSafeInteger(v.max_seconds)||(v.max_seconds as number)<15||(v.max_seconds as number)>180
  ||!Number.isFinite(expiry)||expiry<=Date.now()+15000||expiry>access.expiresAtMs||!isJudgeAccessActive(access)){
  // A trusted newly allowed reservation exists, but no DO/provider was invoked.
  // Settle only that exact actor receipt; denied/replayed/ambiguous rows stay intact.
  await settleJudgeVoiceReservation(client,access.actorId,v.reservation_id);return null;
 }
 return {reservationId:v.reservation_id,maxUnits:v.max_units as number,maxSeconds:v.max_seconds as number,expiresAtMs:expiry};
 }catch{return null;}
}
export async function dispatchJudgeVoice(c:Context<Env>,id:string,kind:"interview"|"reflection",value:Record<string,unknown>,diagnosticDeadlineMs?:number){
 const access=c.get("judge_access"),namespace=c.env.JUDGE_REALTIME_CALLS;
 if(!isJudgeAccessActive(access)||!namespace)return jsonError(c,"FORBIDDEN","Voice interview is unavailable",403);
 const reservation=await reserveJudgeVoice(getSupabaseClient(c.env) as unknown as JudgeRpcClient,access,id,kind);
 if(!reservation)return jsonError(c,"FORBIDDEN","Voice allowance is exhausted or unavailable",403);
 const stub=namespace.get(namespace.idFromName(`${kind}:${id}`));
 const boundedExpiry = diagnosticDeadlineMs === undefined ? reservation.expiresAtMs : Math.min(reservation.expiresAtMs, diagnosticDeadlineMs);
 let response:Response;
 try{response=await stub.fetch(new Request("https://judge-realtime.internal/start",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({...value,kind,sessionId:id,ownerId:access.actorId,...reservation,expiresAtMs:boundedExpiry})}));}
 catch{return jsonError(c,"INTERNAL_ERROR","Voice interview is temporarily unavailable",503);}
 if(response.status!==201){
  // Only the trusted DO may attest that this attempt never reached a provider.
  // Unknown/transport failures retain the SQL lease and require reconciliation.
  const failed=await response.json().catch(()=>null) as {providerNotStarted?:unknown}|null;
  if(failed?.providerNotStarted===true)await settleJudgeVoiceReservation(getSupabaseClient(c.env) as unknown as JudgeRpcClient,access.actorId,reservation.reservationId);
  return jsonError(c,"INTERNAL_ERROR","Voice interview is temporarily unavailable",503);
 }
 const answer=await response.json() as {sdp?:unknown;max_duration_seconds?:unknown};
 const accessResult=await (getSupabaseClient(c.env) as unknown as JudgeRpcClient).rpc("check_judge_access",{p_user_id:access.actorId});
 const accessRow=Array.isArray(accessResult.data)&&accessResult.data.length===1?accessResult.data[0]:accessResult.data;
 const currentAccess=!!accessRow && typeof accessRow==="object" && !Array.isArray(accessRow)
  && (accessRow as Record<string,unknown>).outcome==="allowed" && (accessRow as Record<string,unknown>).actor_user_id===access.actorId
  && (accessRow as Record<string,unknown>).account_kind===access.accountKind;

 if(accessResult.error||!currentAccess||typeof answer.sdp!=="string"||!answer.sdp.startsWith("v=0")||answer.sdp.length>65536||!Number.isInteger(answer.max_duration_seconds)||(answer.max_duration_seconds as number)<1||(answer.max_duration_seconds as number)>180
   ||!isJudgeAccessActive(access)||Date.now()>=boundedExpiry){
  await stub.fetch(new Request("https://judge-realtime.internal/stop",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({ownerId:access.actorId,sessionId:id})})).catch(()=>{});
  return jsonError(c,"INTERNAL_ERROR","Voice interview is temporarily unavailable",503);
 }
 return jsonData(c,answer,201);
}
export async function stopJudgeVoice(c:Context<Env>,id:string,kind:"interview"|"reflection"){
 const access=c.get("judge_access"),namespace=c.env.JUDGE_REALTIME_CALLS;
 if(!access||access.actorId!==c.get("user_id")||!namespace||!isCanonicalUuid(id))return jsonError(c,"NOT_FOUND","Voice interview not found",404);
 const response=await namespace.get(namespace.idFromName(`${kind}:${id}`)).fetch(new Request("https://judge-realtime.internal/stop",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({ownerId:access.actorId,sessionId:id})}));
 if(!response.ok){await response.body?.cancel();return jsonError(c,"NOT_FOUND","Voice interview not found",404);}
 return jsonData(c,await response.json());
}
const judgeRealtime=new Hono<Env>();
judgeRealtime.post("/sessions/:id/realtime-call",requireAuth,async c=>{
 c.header("Cache-Control","no-store");try{
 const access=c.get("judge_access"),id=c.req.param("id");
 if(!isJudgeAccessActive(access)||access.actorId!==c.get("user_id")||c.env.OPENAI_REALTIME_ENABLED!=="enabled"||!c.env.JUDGE_REALTIME_CALLS)return jsonError(c,"FORBIDDEN","Voice interview is unavailable",403);
 if(!isCanonicalUuid(id))return jsonError(c,"NOT_FOUND","Voice interview not found",404);
 const input=await readJudgeVoiceBody(c);if(!input)return jsonError(c,"BAD_REQUEST","Invalid voice connection",400);
 const db=getSupabaseClient(c.env);
 const ownerResult=await db.from("user_profiles").select("conversation_language,age_verified_at,onboarding_settings_completed_at").eq("id",access.actorId).maybeSingle();
 const owner=readSpeedDatingOwnerState(ownerResult.data);if(ownerResult.error||!owner)return jsonError(c,"FORBIDDEN","Voice interview is unavailable",403);
 const result=await db.from("speed_dating_sessions").select("id,user_id,persona_id,status,personas(id,user_id,persona_type,name,compiled_document)").eq("id",id).eq("user_id",access.actorId).maybeSingle();
 const binding=readActiveSpeedDatingSession(result.data,access.actorId,id);if(result.error||!binding)return jsonError(c,"NOT_FOUND","Voice interview not found",404);
 const record=result.data as Record<string,unknown>,nested=Array.isArray(record.personas)?record.personas[0]:record.personas;
 const persona=readOwnedVirtualPersona(nested,access.actorId,binding.personaId);if(!persona)return jsonError(c,"NOT_FOUND","Voice interview not found",404);
 return dispatchJudgeVoice(c,id,"interview",{sdp:input.sdp,voice:input.voice,language:owner.conversationLanguage,personaDocument:persona.compiledDocument});
 }catch{return jsonError(c,"INTERNAL_ERROR","Voice interview is temporarily unavailable",503);}
});
judgeRealtime.post("/sessions/:id/realtime-stop",requireAuth,async c=>{try{return await stopJudgeVoice(c,c.req.param("id"),"interview");}catch{return jsonError(c,"INTERNAL_ERROR","Voice interview is temporarily unavailable",503);}});
export default judgeRealtime;
