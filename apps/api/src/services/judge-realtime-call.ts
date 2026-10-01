import { z } from "zod";
import { buildRealtimeSession, realtimeVoiceSchema } from "../lib/openai-realtime";
import { buildMeetupReflectionRealtimeSession, REFLECTION_TRAIT_VALUES } from "./meetup-reflection";
import { readBoundedResponseTextWithSignal } from "../lib/speed-dating-ai";

export const JUDGE_REALTIME_MAX_SECONDS = 180;
export const JUDGE_REALTIME_CALL_ENDPOINT = "https://api.openai.com/v1/realtime/calls";
const callIdPattern = /^rtc_[A-Za-z0-9_-]{1,160}$/;
const uuid = z.string().uuid();
export const judgeRealtimeStartSchema = z.object({
 ownerId: uuid, sessionId: uuid, reservationId: uuid, kind:z.enum(["interview","reflection"]),
 confirmedTraits:z.record(z.string()).default({}).refine(map=>Object.entries(map).every(([key,value])=>Object.hasOwn(REFLECTION_TRAIT_VALUES,key) && (REFLECTION_TRAIT_VALUES[key as keyof typeof REFLECTION_TRAIT_VALUES] as readonly string[]).includes(value))),
 personaDocument: z.string().min(1).max(30_000), language: z.enum(["ja", "en"]), voice: realtimeVoiceSchema,
 sdp: z.string().min(4).max(65_536).refine(value=>value.startsWith("v=0") && !value.includes("\0")),
 expiresAtMs: z.number().int().positive(), maxUnits:z.number().int().min(256).max(20000), maxSeconds: z.number().int().min(15).max(JUDGE_REALTIME_MAX_SECONDS),
}).strict();
export type JudgeRealtimeStart = z.infer<typeof judgeRealtimeStartSchema>;
export interface JudgeRealtimeSideband { accept():void; addEventListener(type:string, listener:(event:{data?:unknown})=>void):void; close(code?:number,reason?:string):void }
export const judgeRealtimeCloseReasons = ["owner_stop","deadline","sideband","session_configuration","invalid_event","invalid_usage","unit_limit","response_limit","user_item_limit","provider_create_rejected","provider_create_unknown","provider_not_started"] as const;
export type JudgeRealtimeCloseReason = typeof judgeRealtimeCloseReasons[number];
export type JudgeRealtimeLease = {ownerId:string;sessionId:string;reservationId:string;deadlineMs:number;maxUnits?:number;callId:string|null;status:"starting"|"active"|"closing"|"closed";responseCount?:number;userItemCount?:number;observedUnits?:number;settled?:boolean;runtimeTransportVersion?:1;closeReason?:JudgeRealtimeCloseReason;providerCreateState?:"not_started"|"rejected"|"unknown"|"created"};
export type JudgeRealtimeStorage = {
 get<T>(key:string):Promise<T|undefined>; put<T>(key:string,value:T):Promise<void>;
 setAlarm(when:number):Promise<void>; deleteAlarm():Promise<void>;
};
export interface JudgeRealtimeCallEnvironment { OPENAI_API_KEY?:string; OPENAI_REALTIME_ENABLED?:string }
/** No provider credential or call ID leaves this server-side durable lease. */
export class JudgeRealtimeCallController {
 private busy=false;
 private sideband:JudgeRealtimeSideband|null=null;
 private expectedInstructions:string|null=null;
 private expectedVoice:string|null=null;
 private expectedLanguage:string|null=null;
 private eventQueue:Promise<void>=Promise.resolve();
 constructor(private storage:JudgeRealtimeStorage,private env:JudgeRealtimeCallEnvironment,private fetcher:typeof fetch=fetch,private now:()=>number=Date.now,private settle:(ownerId:string,reservationId:string)=>Promise<boolean>=async()=>false) {}
 async start(value:unknown):Promise<Response> {
  const parsed=judgeRealtimeStartSchema.safeParse(value), key=this.env.OPENAI_API_KEY?.trim();
  if(!parsed.success || !key || this.env.OPENAI_REALTIME_ENABLED!=="enabled") return this.failed(503,true);
  const input=parsed.data, now=this.now(), deadlineMs=Math.min(input.expiresAtMs,now+input.maxSeconds*1000);
  if(this.busy)return this.failed(409);
  if(deadlineMs-now<15_000)return this.failed(409,true);
  this.busy=true;
  let callId:string|null=null;
  try {
   if(await this.storage.get("lease"))return this.failed(409);
   // Persist the deadline before a billable operation. A recreated object retains this alarm.
   await this.storage.put<JudgeRealtimeLease>("lease",{ownerId:input.ownerId,sessionId:input.sessionId,reservationId:input.reservationId,deadlineMs,maxUnits:input.maxUnits,callId:null,status:"starting",runtimeTransportVersion:1,providerCreateState:"not_started"});
   await this.storage.setAlarm(deadlineMs);
   const controller=new AbortController(), timeout=setTimeout(()=>controller.abort(),10_000);
   let response:Response, sdp:string|null;
   try {
    const config=input.kind==="reflection"?buildMeetupReflectionRealtimeSession(input.language,input.voice,input.personaDocument,input.confirmedTraits):buildRealtimeSession(input.personaDocument,input.language,input.voice);
    if(new TextEncoder().encode(config.instructions).byteLength>16000){
     const lease=await this.storage.get<JudgeRealtimeLease>("lease");if(lease){const closed={...lease,status:"closed" as const};await this.storage.put("lease",closed);await this.settleClosed(closed);}
     return this.failed(503);
    }
    this.expectedInstructions=config.instructions;this.expectedVoice=input.voice;this.expectedLanguage=input.language;
    const form=new FormData();form.set("sdp",input.sdp);form.set("session",JSON.stringify({...config,truncation:{type:"retention_ratio",retention_ratio:0.8,token_limits:{post_instructions:1000}}}));
    // Mark ambiguity durably before sending: timeouts cannot prove no call exists.
    const beforeCreate=await this.storage.get<JudgeRealtimeLease>("lease");
    if(!beforeCreate)return this.failed(503);
    await this.storage.put("lease",{...beforeCreate,providerCreateState:"unknown"});
    response=await this.fetcher.call(globalThis,JUDGE_REALTIME_CALL_ENDPOINT,{method:"POST",headers:{Authorization:`Bearer ${key}`},body:form,redirect:"manual",signal:controller.signal});
    const location=response.headers.get("Location");
    // Accept only the exact provider-relative path, never an arbitrary redirect/host.
    const match=location?.match(/^\/v1\/realtime\/calls\/(rtc_[A-Za-z0-9_-]{1,160})$/)
      ?? location?.match(/^https:\/\/api\.openai\.com\/v1\/realtime\/calls\/(rtc_[A-Za-z0-9_-]{1,160})$/);
    callId=match?.[1]??null;
    if(response.status!==201 || !callId){
     await response.body?.cancel();
     const failedLease=await this.storage.get<JudgeRealtimeLease>("lease");
     // Only explicit request rejection proves no provider call was created.
     if(failedLease && [400,401,403,404,413,422,429].includes(response.status))await this.storage.put("lease",{...failedLease,providerCreateState:"rejected"});
     await this.hangup(failedLease && [400,401,403,404,413,422,429].includes(response.status)?"provider_create_rejected":"provider_create_unknown");
     return this.failed(503);
    }
    // Store the provider ID before reading the answer or giving a client the means to connect.
    const lease=await this.storage.get<JudgeRealtimeLease>("lease");
    if(!lease)return this.failed(503);
    await this.storage.put("lease",{...lease,callId,providerCreateState:"created",status:lease.status==="starting"?"active":lease.status});
    sdp=await readBoundedResponseTextWithSignal(response,65_536,controller.signal);
   } finally {clearTimeout(timeout);}
   if(!callId || !await this.attachSideband(callId)){await this.hangup("sideband");return this.failed(503);}
   const lease=await this.storage.get<JudgeRealtimeLease>("lease");
   if(!sdp?.startsWith("v=0") || sdp.includes("\0") || !lease || lease.status!=="active" || this.now()>=deadlineMs){await this.hangup();return this.failed(503);}
   return Response.json({sdp,max_duration_seconds:Math.max(1,Math.floor((deadlineMs-this.now())/1000))},{status:201,headers:{"Cache-Control":"no-store"}});
  } catch {
   // If a provider ID was learned, preserve it and keep retrying cleanup; never disclose an answer on failure.
   if(callId){const lease=await this.storage.get<JudgeRealtimeLease>("lease").catch(()=>undefined);if(lease)await this.storage.put("lease",{...lease,callId}).catch(()=>{});await this.hangup().catch(()=>{});}
   if(!callId){const failedLease=await this.storage.get<JudgeRealtimeLease>("lease").catch(()=>undefined);if(failedLease)await this.hangup(failedLease.providerCreateState==="not_started"?"provider_not_started":"provider_create_unknown").catch(()=>{});}
   return this.failed(503);
  } finally {this.busy=false;}
 }
 async stop(ownerId:string,sessionId:string):Promise<Response>{
  const lease=await this.storage.get<JudgeRealtimeLease>("lease");
  if(!lease || lease.ownerId!==ownerId || lease.sessionId!==sessionId)return this.failed(404);
  // Exactly the failed synthetic diagnostic deployed with the verified illegal
  // global-fetch receiver. That implementation could never reach the provider.
  // Never apply this recovery to versioned attempts or any other owner/context.
  if(lease.ownerId==="56f96c3d-6040-5c57-b6ad-c59284ba4f3c" && lease.sessionId==="124ea7e7-1cd0-4965-8198-9162b6fb94b4"
   && lease.callId===null && lease.runtimeTransportVersion===undefined && this.now()>=lease.deadlineMs
   && ["starting","closing"].includes(lease.status)){
   const closed={...lease,status:"closed" as const};await this.storage.put("lease",closed);
   return Response.json({closed:await this.settleClosed(closed)},{headers:{"Cache-Control":"no-store"}});
  }
  return Response.json({closed:await this.hangup("owner_stop")},{headers:{"Cache-Control":"no-store"}});
 }
 async readStatus(ownerId:string,sessionId:string):Promise<Response>{
  const lease=await this.storage.get<JudgeRealtimeLease>("lease");
  if(lease && (lease.ownerId!==ownerId || lease.sessionId!==sessionId))return this.failed(404);
  return Response.json({leaseExists:!!lease,status:lease?.status??"missing",providerCreated:!!lease?.callId,settled:lease?.settled===true,closeReason:lease?.closeReason && judgeRealtimeCloseReasons.includes(lease.closeReason)?lease.closeReason:null},{headers:{"Cache-Control":"no-store"}});
 }
 async alarm():Promise<void>{
  const lease=await this.storage.get<JudgeRealtimeLease>("lease");
  if(!lease){await this.storage.deleteAlarm();return;}
  if(lease.status==="closed"){await this.settleClosed(lease);return;}
  if(lease.status==="closing"){await this.hangup();return;}
  if(this.now()<lease.deadlineMs){await this.storage.setAlarm(lease.deadlineMs);return;}
  await this.hangup("deadline");
 }
 private async attachSideband(callId:string):Promise<boolean>{
  const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),5000);
  try{
   const response=await this.fetcher.call(globalThis,`https://api.openai.com/v1/realtime?call_id=${callId}`,{headers:{Upgrade:"websocket",Authorization:`Bearer ${this.env.OPENAI_API_KEY?.trim()}`},redirect:"manual",signal:controller.signal});
   const socket=(response as Response & {webSocket?:JudgeRealtimeSideband}).webSocket;
   if(response.status!==101||!socket){await response.body?.cancel();return false;}
   socket.accept();this.sideband=socket;
   socket.addEventListener("message",event=>{this.eventQueue=this.eventQueue.then(()=>this.handleProviderEvent(event.data)).catch(()=>this.hangup("invalid_event")).then(()=>{});});
   for(const type of ["close","error"])socket.addEventListener(type,()=>{this.eventQueue=this.eventQueue.then(async()=>{const lease=await this.storage.get<JudgeRealtimeLease>("lease");if(lease?.status==="active")await this.hangup("sideband");}).catch(()=>{});});
   return true;
  }catch{return false;}finally{clearTimeout(timeout);}
 }
 private async handleProviderEvent(raw:unknown):Promise<void>{
  const lease=await this.storage.get<JudgeRealtimeLease>("lease");if(!lease||lease.status!=="active")return;
  if(this.now()>=lease.deadlineMs){await this.hangup("deadline");return;}
  if(typeof raw!=="string" || new TextEncoder().encode(raw).byteLength>131072){await this.hangup("invalid_event");return;}
  let event:Record<string,unknown>;try{event=JSON.parse(raw);}catch{await this.hangup("invalid_event");return;}
  if(!event||typeof event!=="object"||Array.isArray(event)){await this.hangup("invalid_event");return;}
  if(event.type==="session.updated"||event.type==="session.created"){
   const v=event.session as Record<string,unknown>|undefined;
   if(!v||typeof v.instructions!=="string"||new TextEncoder().encode(v.instructions).byteLength>16000||v.model!=="gpt-realtime-2.1-mini"||typeof v.max_output_tokens!=="number"||v.max_output_tokens>256||v.max_output_tokens<1
    ||!Array.isArray(v.tools)||v.tools.length!==0||!Array.isArray(v.output_modalities)||v.output_modalities.length!==1||v.output_modalities[0]!=="audio"
    ||this.expectedInstructions!==null && v.instructions!==this.expectedInstructions){await this.hangup("session_configuration");return;}
   const truncation=v.truncation as {type?:unknown;retention_ratio?:unknown;token_limits?:{post_instructions?:unknown}}|undefined;
   const audio=v.audio as {input?:{transcription?:{model?:unknown;language?:unknown}};output?:{voice?:unknown}}|undefined;
   if(!truncation||truncation.type!=="retention_ratio"||truncation.retention_ratio!==0.8||truncation.token_limits?.post_instructions!==1000
    ||audio?.input?.transcription?.model!=="gpt-4o-mini-transcribe"||audio.input.transcription.language!==this.expectedLanguage||audio.output?.voice!==this.expectedVoice){await this.hangup("session_configuration");return;}
  }
  if(event.type==="response.done"||event.type==="conversation.item.input_audio_transcription.completed"){
   const usage=(event.type==="response.done"?(event.response as Record<string,unknown>|undefined)?.usage:event.usage) as Record<string,unknown>|undefined;
   if(!usage||!Number.isSafeInteger(usage.total_tokens)||(usage.total_tokens as number)<0){await this.hangup("invalid_usage");return;}
   const observedUnits=(lease.observedUnits??0)+(usage.total_tokens as number);
   const input=usage.input_tokens,output=usage.output_tokens;
   if(!Number.isSafeInteger(input)||!Number.isSafeInteger(output)||(input as number)<0||(output as number)<0){await this.hangup("invalid_usage");return;}
   await this.storage.put("lease",{...lease,observedUnits});
   if(observedUnits>(lease.maxUnits??20000))await this.hangup("unit_limit");
  }
  if(event.type==="response.created"){
   // The server Response schema exposes these settings, but not the client's
   // per-response instructions/tools. Validate reported settings without
   // inventing mandatory fields absent from the provider's optional schema.
   const response=event.response as Record<string,unknown>|undefined;
   if(response){
    const modalities=response.output_modalities;
    if(response.max_output_tokens!==undefined && (!Number.isSafeInteger(response.max_output_tokens)||(response.max_output_tokens as number)<1||(response.max_output_tokens as number)>256)
     || modalities!==undefined && (!Array.isArray(modalities)||modalities.length!==1||modalities[0]!=="audio")){
     await this.hangup("session_configuration");return;
    }
   }
   const responseCount=(lease.responseCount??0)+1;await this.storage.put("lease",{...lease,responseCount});
   if(responseCount>20)await this.hangup("response_limit");
  }
  if(event.type==="conversation.item.added"||event.type==="conversation.item.created"){
   const item=event.item as {role?:unknown;content?:unknown;type?:unknown}|undefined;
   if(!item || !["user","assistant"].includes(String(item.role)) || item.type!==undefined && item.type!=="message"){
    await this.hangup("invalid_event");return;
   }
   if(item.role==="assistant"){
    // Provider-generated assistant items may begin with an empty content array.
    if(!Array.isArray(item.content)||item.content.some(value=>!value||typeof value!=="object"
      ||!["audio","text","output_audio","output_text"].includes(value.type)
      ||value.text!==undefined&&(typeof value.text!=="string"||value.text.length>2000)))await this.hangup("user_item_limit");
    return;
   }
   const userItemCount=(lease.userItemCount??0)+1;await this.storage.put("lease",{...lease,userItemCount});
   if(userItemCount>40||!Array.isArray(item.content)||item.content.some(value=>!value||typeof value!=="object"
     ||!["input_audio","input_text"].includes(value.type)||value.type==="input_text"&&(typeof value.text!=="string"||value.text.length>2000))){await this.hangup("user_item_limit");return;}
  }
 }
 private async hangup(reason?:JudgeRealtimeCloseReason):Promise<boolean>{
  let lease=await this.storage.get<JudgeRealtimeLease>("lease");if(!lease)return false;
  if(reason && !lease.closeReason){lease={...lease,closeReason:reason};await this.storage.put("lease",lease);}
  if(lease.status==="closed")return this.settleClosed(lease);
  await this.storage.put("lease",{...lease,status:"closing"});
  if(!lease.callId){
   if(lease.providerCreateState==="not_started"||lease.providerCreateState==="rejected"){
    const closed={...lease,status:"closed" as const};await this.storage.put("lease",closed);return this.settleClosed(closed);
   }
   if(lease.providerCreateState==="unknown"||lease.providerCreateState===undefined){
    // Keep SQL admission blocked for operator reconciliation. No blind retry or
    // settlement can guarantee that a timeout did not create an orphan call.
    await this.storage.deleteAlarm();return false;
   }
   await this.storage.setAlarm(this.now()+5000);return false;
  }
  if(!callIdPattern.test(lease.callId)){await this.storage.setAlarm(this.now()+5000);return false;}
  const key=this.env.OPENAI_API_KEY?.trim();
  if(!key){await this.storage.setAlarm(this.now()+5000);return false;}
  const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),5000);
  try{
   const result=await this.fetcher.call(globalThis,`${JUDGE_REALTIME_CALL_ENDPOINT}/${lease.callId}/hangup`,{method:"POST",headers:{Authorization:`Bearer ${key}`},redirect:"manual",signal:controller.signal});
   await result.body?.cancel();
   // Unknown/error responses retain the active lease and durable retry alarm.
   if(result.ok || result.status===404 || result.status===410){const closed={...lease,status:"closed" as const};await this.storage.put("lease",closed);this.sideband?.close(1000,"Complete");this.sideband=null;return this.settleClosed(closed);}
  }catch{}finally{clearTimeout(timeout);}
  await this.storage.setAlarm(this.now()+5000);return false;
 }
 private async settleClosed(lease:JudgeRealtimeLease):Promise<boolean>{
  if(lease.settled){await this.storage.deleteAlarm();return true;}
  let settled=false;try{settled=await this.settle(lease.ownerId,lease.reservationId);}catch{}
  if(settled){await this.storage.put("lease",{...lease,settled:true});await this.storage.deleteAlarm();return true;}
  await this.storage.setAlarm(this.now()+5000);return false;
 }
 private failed(status:number,providerNotStarted=false){return Response.json({error:"Voice interview unavailable",...(providerNotStarted?{providerNotStarted:true}:{})},{status,headers:{"Cache-Control":"no-store"}});}
}
