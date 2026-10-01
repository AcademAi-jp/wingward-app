import {Hono} from "hono";
import {describe,it,expect,vi,beforeEach,afterEach} from "vitest";
import type {Env} from "../env";
import type {JudgeAccess} from "../services/judge-access";
const owner="11111111-1111-4111-8111-111111111111",id="22222222-2222-4222-8222-222222222222",personaId="33333333-3333-4333-8333-333333333333",reservationId="44444444-4444-4444-8444-444444444444";
vi.mock("../middleware/auth",()=>({requireAuth:async(c:import("hono").Context,next:()=>Promise<void>)=>{c.set("user_id","11111111-1111-4111-8111-111111111111");await next();}}));
vi.mock("../db/client",()=>({getSupabaseClient:vi.fn()}));
import {getSupabaseClient} from "../db/client";
import judgeRealtime,{dispatchJudgeVoice,settleJudgeVoiceReservation} from "./judge-realtime";
import meetupReflections from "./meetup-reflections";
const now=Date.parse("2026-10-01T00:00:00Z");
function fixture(overrides:Record<string,unknown>={}){
 const access:JudgeAccess={actorId:owner,accountKind:"judge",counterpartId:personaId,expiresAtMs:now+3600000};
 let active=overrides.active!==false;
 const ownedPersona={id:personaId,user_id:owner,persona_type:"virtual_similar",name:"Synthetic",compiled_document:"A thoughtful synthetic persona"};
 const session={id,user_id:owner,persona_id:personaId,status:"active",personas:ownedPersona,...overrides.session as object};
 const own={conversation_language:"en",age_verified_at:"2026-09-01T00:00:00Z",onboarding_settings_completed_at:"2026-09-01T00:00:00Z",...overrides.owner as object};
 const rpc=vi.fn(async(name:string):Promise<{error:unknown;data:unknown}>=>name==="check_judge_access"?{error:null,data:{outcome:active?"allowed":"denied",actor_user_id:owner,account_kind:"judge"}}:name==="settle_judge_voice_session"?{error:overrides.settleError??null,data:{outcome:overrides.settleOutcome??"settled"}}:{error:overrides.reserveError??null,data:{outcome:overrides.reservationOutcome??"allowed",reservation_id:reservationId,max_units:20000,max_seconds:180,expires_at:new Date(now+180000).toISOString(),...overrides.reservationRow as object}});
 const from=vi.fn((table:string)=>{const q={select:vi.fn(()=>q),eq:vi.fn(()=>q),maybeSingle:vi.fn(async()=>({data:table==="user_profiles"?own:session,error:null}))};return q;});
 vi.mocked(getSupabaseClient).mockReturnValue({from,rpc} as never);
 const stub=vi.fn(async(req:Request)=>{if(new URL(req.url).pathname==="/stop")return Response.json({closed:true});if(overrides.disableAfterStart)active=false;return Response.json({sdp:"v=0\r\na=synthetic\r\n",max_duration_seconds:179},{status:201});});
 const namespace={idFromName:vi.fn((name:string)=>name),get:vi.fn(()=>({fetch:stub}))};
 const app=new Hono<Env>();app.use("*",async(c,next)=>{if(overrides.noAccess!==true)c.set("judge_access",{...access,...overrides.access as object});await next();});app.route("/api/speed-dating",judgeRealtime);app.route("/api/meetup-reflections",meetupReflections);
 app.post("/diagnostic",c=>dispatchJudgeVoice(c,id,"interview",{sdp:"v=0",voice:"marin",language:"en",personaDocument:"Synthetic"},Number(overrides.diagnosticDeadlineMs)));
 const env={SUPABASE_URL:"https://synthetic.invalid",SUPABASE_SERVICE_ROLE_KEY:"synthetic",OPENAI_REALTIME_ENABLED:"enabled",JUDGE_REALTIME_CALLS:namespace,...overrides.env as object};
 return {rpc,stub,namespace,stop:(kind:"interview"|"reflection"="interview",pathId=id)=>app.request(kind==="interview"?`/api/speed-dating/sessions/${pathId}/realtime-stop`:`/api/meetup-reflections/${pathId}/realtime-stop`,{method:"POST"},env),diagnostic:()=>app.request("/diagnostic",{method:"POST"},env),request:(body:unknown={sdp:"v=0\r\na=offer\r\n",voice:"cedar"},pathId=id)=>app.request(`/api/speed-dating/sessions/${pathId}/realtime-call`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)},env)};
}
beforeEach(()=>{vi.spyOn(Date,"now").mockReturnValue(now);});afterEach(()=>vi.restoreAllMocks());
describe("judge owner-authenticated SDP exchange",()=>{
 it("reserves once immediately before exact owner session call",async()=>{const f=fixture(),r=await f.request();expect(r.status).toBe(201);expect(((await r.json()) as {data:unknown}).data).toEqual({sdp:"v=0\r\na=synthetic\r\n",max_duration_seconds:179});expect(f.rpc.mock.calls[0]).toEqual(["reserve_judge_voice_session",{p_user_id:owner,p_session_id:id,p_idempotency_key:id}]);expect(f.namespace.idFromName).toHaveBeenCalledWith(`interview:${id}`);const sent=await f.stub.mock.calls[0][0].json() as Record<string,unknown>;expect(sent.ownerId).toBe(owner);expect(sent.reservationId).toBe(reservationId);expect(sent.maxSeconds).toBe(180);expect(sent.expiresAtMs).toBe(now+180000);expect(sent).not.toHaveProperty("api_key");});
 it("caps the actual DO start payload at the diagnostic deadline and never extends DB lease",async()=>{
  const shorter=fixture({diagnosticDeadlineMs:now+45000});expect((await shorter.diagnostic()).status).toBe(201);expect(((await shorter.stub.mock.calls[0][0].json()) as Record<string,unknown>).expiresAtMs).toBe(now+45000);
  const longer=fixture({diagnosticDeadlineMs:now+900000});expect((await longer.diagnostic()).status).toBe(201);expect(((await longer.stub.mock.calls[0][0].json()) as Record<string,unknown>).expiresAtMs).toBe(now+180000);
 });
 it.each([{noAccess:true},{access:{actorId:personaId}},{access:{expiresAtMs:now}},{env:{OPENAI_REALTIME_ENABLED:"disabled"}},{env:{JUDGE_REALTIME_CALLS:undefined}},{session:{user_id:personaId}},{session:{status:"completed"}},{session:{personas:{id:personaId,user_id:personaId,persona_type:"virtual_similar",name:"Synthetic",compiled_document:"Not owner"}}},{owner:{age_verified_at:null}},{owner:{conversation_language:"unsupported"}}])("invalid admission or owner/context invokes no namespace %j",async overrides=>{const f=fixture(overrides);expect((await f.request()).status).not.toBe(201);expect(f.stub).not.toHaveBeenCalled();});
 it.each([{sdp:"invalid",voice:"cedar"},{sdp:"v=0",voice:"unsupported"},{sdp:"v=0",voice:"cedar",ownerId:personaId},{sdp:"v=0"+"x".repeat(70000),voice:"cedar"}])("strict SDP body rejects unexpected inputs %j",async body=>{const f=fixture();expect((await f.request(body)).status).toBe(400);expect(f.rpc).not.toHaveBeenCalled();expect(f.stub).not.toHaveBeenCalled();});
 it("reservation replay or unavailable policy never creates another call",async()=>{const f=fixture({reservationOutcome:"replayed"});expect((await f.request()).status).toBe(403);expect(f.stub).not.toHaveBeenCalled();});
 it.each([{max_units:255},{max_units:20001},{max_seconds:14},{max_seconds:181},{expires_at:new Date(now+14000).toISOString()},{expires_at:"invalid"},{expires_at:new Date(now+3600001).toISOString()}])("settles an exact trusted reservation rejected before DO start %j",async reservationRow=>{const f=fixture({reservationRow});expect((await f.request()).status).toBe(403);expect(f.stub).not.toHaveBeenCalled();expect(f.rpc.mock.calls).toContainEqual(["settle_judge_voice_session",{p_user_id:owner,p_reservation_id:reservationId}]);});
 it.each([{reserveError:{message:"synthetic"}},{reservationOutcome:"replayed"},{reservationOutcome:"denied"},{reservationRow:{reservation_id:"invalid"}}])("never settles an untrusted or replayed reservation %j",async overrides=>{const f=fixture(overrides);expect((await f.request()).status).toBe(403);expect(f.stub).not.toHaveBeenCalled();expect(f.rpc.mock.calls.some(([name])=>name==="settle_judge_voice_session")).toBe(false);});
 it.each([{settleError:{message:"synthetic"}},{settleOutcome:"denied"},{settleOutcome:"unknown"}])("reports no settlement success for rejected RPC result %j",async overrides=>{const f=fixture(overrides);expect(await settleJudgeVoiceReservation({rpc:f.rpc},owner,reservationId)).toBe(false);});
 it("reports a settlement transport failure without leaking or starting a provider",async()=>{const f=fixture();f.rpc.mockRejectedValueOnce(new Error("synthetic"));expect(await settleJudgeVoiceReservation({rpc:f.rpc},owner,reservationId)).toBe(false);expect(f.stub).not.toHaveBeenCalled();});
 it("settles the exact SQL receipt only after trusted no-provider attestation",async()=>{const f=fixture();f.stub.mockImplementationOnce(async()=>Response.json({error:"unavailable",providerNotStarted:true},{status:503}));expect((await f.request()).status).toBe(503);expect(f.rpc.mock.calls).toContainEqual(["settle_judge_voice_session",{p_user_id:owner,p_reservation_id:reservationId}]);});
 it("awaits a real-shaped PostgREST settlement thenable without requiring catch",async()=>{
  const f=fixture(),original=f.rpc.getMockImplementation()!;let executed=0;
  f.rpc.mockImplementation(name=>name==="settle_judge_voice_session"?{then(resolve:(value:unknown)=>unknown){executed++;return Promise.resolve({error:null,data:{outcome:"settled"}}).then(resolve);}} as never:original(name));
  f.stub.mockImplementationOnce(async()=>Response.json({providerNotStarted:true},{status:503}));
  expect((await f.request()).status).toBe(503);expect(executed).toBe(1);expect(f.rpc.mock.calls).toContainEqual(["settle_judge_voice_session",{p_user_id:owner,p_reservation_id:reservationId}]);
 });
 it.each([{}, {providerNotStarted:false},{providerNotStarted:"true"}])("never settles ambiguous failed provider dispatch %j",async failed=>{const f=fixture();f.stub.mockImplementationOnce(async()=>Response.json(failed,{status:503}));expect((await f.request()).status).toBe(503);expect(f.rpc.mock.calls.some(([name])=>name==="settle_judge_voice_session")).toBe(false);});
 it("transport exception cannot attest no provider or settle SQL",async()=>{const f=fixture();f.stub.mockRejectedValueOnce(new Error("synthetic lost response"));expect((await f.request()).status).toBe(503);expect(f.rpc.mock.calls.some(([name])=>name==="settle_judge_voice_session")).toBe(false);});
 it("revoked admission after provider creation stops call before returning SDP",async()=>{const f=fixture({disableAfterStart:true});const r=await f.request();expect(r.status).toBe(503);expect(f.stub).toHaveBeenCalledTimes(2);expect(new URL(f.stub.mock.calls[1][0].url).pathname).toBe("/stop");expect(await r.text()).not.toContain("v=0");});
});


describe("owner-bound voice stop routes",()=>{
 it.each(["interview","reflection"] as const)("stops only the %s namespace with the authenticated owner",async kind=>{
  const f=fixture({access:{expiresAtMs:now-1}}),r=await f.stop(kind);
  expect(r.status).toBe(200);expect(await r.json()).toEqual({data:{closed:true}});
  expect(f.namespace.idFromName.mock.calls).toEqual([[`${kind}:${id}`]]);
  expect(new URL(f.stub.mock.calls[0][0].url).pathname).toBe("/stop");
  expect(await f.stub.mock.calls[0][0].json()).toEqual({ownerId:owner,sessionId:id});
  expect(f.rpc).not.toHaveBeenCalled();
 });
 it.each([{noAccess:true},{access:{actorId:personaId}},{env:{JUDGE_REALTIME_CALLS:undefined}}])("rejects invalid stop authority before any DO access %j",async overrides=>{
  for(const kind of ["interview","reflection"] as const){const f=fixture(overrides);expect((await f.stop(kind)).status).toBe(404);expect(f.stub).not.toHaveBeenCalled();expect(f.rpc).not.toHaveBeenCalled();}
 });
 it.each(["interview","reflection"] as const)("rejects invalid %s ID without creating a DO",async kind=>{const f=fixture();expect((await f.stop(kind,"invalid")).status).toBe(404);expect(f.namespace.idFromName).not.toHaveBeenCalled();});
 it.each(["interview","reflection"] as const)("does not leak failed %s DO response",async kind=>{const f=fixture();f.stub.mockImplementationOnce(async()=>new Response("PRIVATE_PROVIDER_DETAILS",{status:403}));const r=await f.stop(kind);expect(r.status).toBe(404);expect(await r.text()).not.toContain("PRIVATE_PROVIDER_DETAILS");expect(f.rpc).not.toHaveBeenCalled();});
});
