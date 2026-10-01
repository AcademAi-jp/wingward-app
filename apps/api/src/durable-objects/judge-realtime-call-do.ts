import { getSupabaseClient } from "../db/client";
import { judgeRpcClient } from "../services/judge-access";
import type { Env } from "../env";
import { DurableObject } from "cloudflare:workers";
import { JudgeRealtimeCallController } from "../services/judge-realtime-call";
/** Reachable only through the owner-checked Worker namespace binding, never a public DO URL. */
export class JudgeRealtimeCall extends DurableObject<Env["Bindings"]> {
 private controller:JudgeRealtimeCallController;
 constructor(ctx:DurableObjectState,env:Env["Bindings"]){super(ctx,env);this.controller=new JudgeRealtimeCallController(ctx.storage,env,fetch,Date.now,async(ownerId,reservationId)=>{
 const result=await judgeRpcClient(getSupabaseClient(env)).rpc("settle_judge_voice_session",{p_user_id:ownerId,p_reservation_id:reservationId});
 const row=Array.isArray(result.data)&&result.data.length===1?result.data[0]:result.data;
 return !result.error && !!row && typeof row==="object" && "outcome" in row && ["settled","replayed"].includes(String(row.outcome));
 });}
 async fetch(request:Request):Promise<Response>{
  try{
   if(request.method!=="POST")return new Response(null,{status:405});
   const path=new URL(request.url).pathname;
   const body=await request.json();
   if(path==="/start")return this.controller.start(body);
   if((path==="/stop" || path==="/status") && body && typeof body==="object" && "ownerId" in body && "sessionId" in body
    && typeof body.ownerId==="string" && typeof body.sessionId==="string")return path==="/stop"?this.controller.stop(body.ownerId,body.sessionId):this.controller.readStatus(body.ownerId,body.sessionId);
  }catch{}
  return new Response(null,{status:400});
 }
 async alarm():Promise<void>{await this.controller.alarm();}
}
