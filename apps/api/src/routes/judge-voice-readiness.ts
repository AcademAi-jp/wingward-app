import { Hono, type Handler } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { jsonData, jsonError } from "../lib/response";
import { isJudgeAccessActive, judgeRpcClient, readJudgeAccess, readJudgeAccessConfig } from "../services/judge-access";
import { JUDGE_SEVEN_OWNER_PROFILE_IDS } from "../services/synthetic-matching-cohort";
import { judgeRealtimeCloseReasons } from "../services/judge-realtime-call";
import { dispatchJudgeVoice, readJudgeVoiceBody, stopJudgeVoice } from "./judge-realtime";

// One synthetic fixture, owned solely by the newly enrolled owner01. This test
// does not attest age, change onboarding, or accept real interview content.
export const VOICE_READINESS_SESSION = "124ea7e7-1cd0-4965-8198-9162b6fb94b4";
export const VOICE_READINESS_RECHECK_SESSION = "6801c6a0-6d1b-42c3-a0a7-c29a67e29b81";
export const VOICE_READINESS_DOCUMENT = "Synthetic voice connection check. No personal data. Ask one brief question about a favorite food.";
const route = new Hono<Env>();

route.get("/readiness/voice", async c => {
 try {
 c.header("Cache-Control", "private, no-store");
 const scope=readJudgeAccessConfig(c.env),access=c.get("judge_access"),actor=c.get("user_id"),namespace=c.env.JUDGE_REALTIME_CALLS;
 if(scope.kind!=="active"||scope.config.ownerAiExpiresAtMs===undefined||!isJudgeAccessActive(access)||access.actorId!==actor||actor!==JUDGE_SEVEN_OWNER_PROFILE_IDS[0]||access.accountKind!=="owner"||!namespace)
  return jsonError(c,"FORBIDDEN","Voice check unavailable");
 const deadline=Math.min(scope.config.expiresAtMs,scope.config.issuedAtMs+30*60000);
 if(Date.now()>=deadline)return c.json({code:"closed"},410);
 const rpc=judgeRpcClient(getSupabaseClient(c.env)),fresh=await readJudgeAccess(rpc,scope.config,actor);
 if(!fresh||fresh.accountKind!==access.accountKind||fresh.counterpartId!==access.counterpartId||Date.now()>=deadline)return jsonError(c,"FORBIDDEN","Voice check unavailable");
 const response=await namespace.get(namespace.idFromName(`interview:${VOICE_READINESS_SESSION}`)).fetch(new Request("https://judge-realtime.internal/status",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({ownerId:actor,sessionId:VOICE_READINESS_SESSION})}));
 if(!response.ok)return jsonError(c,"INTERNAL_ERROR","Voice check unavailable",503);
 const raw=await response.json() as Record<string,unknown>;
 const lease={leaseExists:raw.leaseExists===true,status:["missing","starting","active","closing","closed"].includes(String(raw.status))?raw.status:"unknown",providerCreated:raw.providerCreated===true,settled:raw.settled===true,closeReason:judgeRealtimeCloseReasons.includes(raw.closeReason as typeof judgeRealtimeCloseReasons[number])?raw.closeReason:null};
 let model:{connected:boolean;providerStatus?:number;reason?:string}={connected:false,reason:"key_unavailable"};
 if(c.env.OPENAI_API_KEY?.trim()){
  try{
   const r=await fetch("https://api.openai.com/v1/models/gpt-realtime-2.1-mini",{headers:{Authorization:`Bearer ${c.env.OPENAI_API_KEY.trim()}`},redirect:"manual",signal:AbortSignal.timeout(10000)});
   model={connected:false,providerStatus:r.status};
   if(!r.ok){await r.body?.cancel();}else{
    const reader=r.body?.getReader();if(reader){const parts:Uint8Array[]=[];let size=0;
     try{while(true){const v=await reader.read();if(v.done)break;size+=v.value.byteLength;if(size>8192){await reader.cancel();throw Error("bounded response");}parts.push(v.value);}}finally{reader.releaseLock();}
     const bytes=new Uint8Array(size);let offset=0;for(const p of parts){bytes.set(p,offset);offset+=p.byteLength;}const value:unknown=JSON.parse(new TextDecoder().decode(bytes));
     model.connected=!!value&&typeof value==="object"&&"id" in value&&value.id==="gpt-realtime-2.1-mini";
    }
   }
  }catch{model={connected:false,reason:"lookup_failed"};}
 }
 const after=await readJudgeAccess(rpc,scope.config,actor);
 if(!after||after.accountKind!==fresh.accountKind||after.counterpartId!==fresh.counterpartId||Date.now()>=deadline)return jsonError(c,"FORBIDDEN","Voice check unavailable");
 return jsonData(c,{lease,model});
 } catch { return jsonError(c,"INTERNAL_ERROR","Voice check unavailable",503); }
});

const startVoiceCheck:Handler<Env> = async c => {
 c.header("Cache-Control", "private, no-store");
 const scope = readJudgeAccessConfig(c.env), access = c.get("judge_access"), actor = c.get("user_id");
 if (scope.kind !== "active" || scope.config.ownerAiExpiresAtMs === undefined
  || !isJudgeAccessActive(access) || access.actorId !== actor || actor !== JUDGE_SEVEN_OWNER_PROFILE_IDS[c.req.path.endsWith("/voice-recheck") ? 1 : 0]
  || access.accountKind !== "owner" || c.env.OPENAI_REALTIME_ENABLED !== "enabled" || !c.env.JUDGE_REALTIME_CALLS)
  return jsonError(c, "FORBIDDEN", "Voice check unavailable");
 const deadline = Math.min(scope.config.expiresAtMs, scope.config.issuedAtMs + 30 * 60_000);
 if (Date.now() + 60_000 >= deadline) return c.json({ code: "closed" }, 410);
 const input = await readJudgeVoiceBody(c);
 if (!input || input.voice !== "marin") return jsonError(c, "BAD_REQUEST", "Invalid voice check");
 const fresh = await readJudgeAccess(judgeRpcClient(getSupabaseClient(c.env)), scope.config, actor);
 if (!fresh || fresh.accountKind !== access.accountKind || fresh.counterpartId !== access.counterpartId || Date.now() + 60_000 >= deadline)
  return jsonError(c, "FORBIDDEN", "Voice check unavailable");
 // Same DB voice lease, permanent idempotent reservation, durable alarm/sideband/hangup
 // as app interviews. The smaller diagnostic expiry also bounds its runtime.
 const session = c.req.path.endsWith("/voice-recheck") ? VOICE_READINESS_RECHECK_SESSION : VOICE_READINESS_SESSION;
 return dispatchJudgeVoice(c, session, "interview", {
  sdp: input.sdp, voice: "marin", language: "en", personaDocument: VOICE_READINESS_DOCUMENT,
 }, Math.min(deadline, Date.now() + 45_000));
};

const stopVoiceCheck:Handler<Env> = async c => {
 c.header("Cache-Control", "private, no-store");
 const access = c.get("judge_access");
 if (!access || access.actorId !== c.get("user_id") || access.actorId !== JUDGE_SEVEN_OWNER_PROFILE_IDS[c.req.path.endsWith("/voice-recheck/stop") ? 1 : 0] || access.accountKind !== "owner")
  return jsonError(c, "FORBIDDEN", "Voice check unavailable");
 // Cleanup remains available after the diagnostic start window closes.
 const session = c.req.path.endsWith("/voice-recheck/stop") ? VOICE_READINESS_RECHECK_SESSION : VOICE_READINESS_SESSION;
 return stopJudgeVoice(c, session, "interview");
};
route.post("/readiness/voice",startVoiceCheck);
route.post("/readiness/voice-recheck",startVoiceCheck);
route.post("/readiness/voice/stop",stopVoiceCheck);
route.post("/readiness/voice-recheck/stop",stopVoiceCheck);
export default route;
