import {Hono} from "hono";import {afterEach,beforeEach,describe,expect,it,vi} from "vitest";import type {Env} from "../env";
const state=vi.hoisted(()=>({resolve:vi.fn(),rpc:vi.fn()}));
vi.mock("./auth",()=>({resolveAuthUser:(...args:unknown[])=>state.resolve(...args)}));vi.mock("../db/client",()=>({getSupabaseClient:()=>({rpc:(...args:unknown[])=>state.rpc(...args)})}));
import {judgeAccessGate,matchesJudgeAccessRoute} from "./judge-access-gate";
const ACTOR="11111111-1111-4111-8111-111111111111",BOT="22222222-2222-4222-8222-222222222222",NOW=Date.parse("2026-09-30T19:00:00Z");
const ENV={JUDGE_ACCESS_ENABLED:"enabled",JUDGE_ACCESS_COHORT:["shipaton", "20261001"].join("-"),JUDGE_ACCESS_ISSUED_AT:"2026-09-30T18:00:00Z",JUDGE_ACCESS_EXPIRES_AT:"2026-10-13T19:00:00Z",JUDGE_ACCESS_AI_EXPIRES_AT:"2026-10-01T00:00:00Z"};
function app(){const a=new Hono<Env>();a.use("*",judgeAccessGate);a.all("*",c=>c.json({actor:c.get("user_id"),judge:c.get("judge_access"),readOnly:c.get("production_e2e_read_only"),vendor:c.get("judge_vendor_active")}));return a;}
const request=(path:string,method="GET",env:unknown=ENV)=>app().request(path,{method,headers:{Authorization:"Bearer fixture"}},env as Env["Bindings"]);
beforeEach(()=>{vi.useFakeTimers();vi.setSystemTime(NOW);vi.clearAllMocks();state.resolve.mockResolvedValue({userId:ACTOR,authUserId:"auth-fixture"});state.rpc.mockImplementation(async name=>({data:name==="check_judge_access"?[{outcome:"allowed",actor_user_id:ACTOR,account_kind:"judge",counterpart_user_id:BOT,expires_at:ENV.JUDGE_ACCESS_EXPIRES_AT}]:[{outcome:"allowed"}],error:null}));});afterEach(()=>vi.useRealTimers());
describe("registered judge HTTP boundary",()=>{
 it("permits only exact GET vendor diagnostics after authentication, admission and request quota",async()=>{
  expect((await request('/api/judge/readiness/provider')).status).toBe(200);
  expect(state.rpc.mock.calls.map(x=>x[0])).toEqual(['check_judge_access','consume_judge_request']);
  expect(matchesJudgeAccessRoute('POST','/api/judge/readiness/provider')).toBe(false);
  expect(matchesJudgeAccessRoute('GET','/api/judge/readiness/provider/')).toBe(false);
  state.resolve.mockResolvedValue(null);expect((await request('/api/judge/readiness/provider')).status).toBe(401);
 });
 it("admits only exact POST synthetic voice start/stop after authentication and quota",async()=>{
  for(const path of ['/api/judge/readiness/voice','/api/judge/readiness/voice/stop']){
   expect((await request(path,'POST')).status).toBe(200);expect(matchesJudgeAccessRoute('GET',path)).toBe(path==='/api/judge/readiness/voice');expect(matchesJudgeAccessRoute('POST',path+'/')).toBe(false);
  }
  state.resolve.mockResolvedValue(null);expect((await request('/api/judge/readiness/voice','POST')).status).toBe(401);
 });
 it("admits only exact POST repair start and stop routes",async()=>{
  for(const path of ["/api/judge/readiness/voice-recheck","/api/judge/readiness/voice-recheck/stop"]){expect((await request(path,"POST")).status).toBe(200);expect(matchesJudgeAccessRoute("GET",path)).toBe(false);expect(matchesJudgeAccessRoute("POST",path+"/")).toBe(false);}
 });
 it("leaves unconfigured behavior unchanged",async()=>{expect((await request("/api/hello","GET",{})).status).toBe(200);expect(state.resolve).not.toHaveBeenCalled();});
 it("authenticates registered owner before read-only profile projection",async()=>{const r=await request("/api/profiles/me");expect(r.status).toBe(200);const body=await r.json() as {readOnly:boolean;actor:string};expect(body.readOnly).toBe(true);expect(body.actor).toBe(ACTOR);expect(state.rpc.mock.calls.map(x=>x[0])).toEqual(["check_judge_access","consume_judge_request"]);});
 it("permits owner profile draft edits through request cap",async()=>expect((await request("/api/profiles/me","PUT")).status).toBe(200));
 it.each(["/api/auth/me","/api/auth/me/age-verification"])("permits fresh account onboarding %s only after admission and quota",async path=>{
  expect((await request(path,"PUT")).status).toBe(200);
  expect(state.rpc.mock.calls.map(x=>x[0])).toEqual(["check_judge_access","consume_judge_request"]);
  state.rpc.mockResolvedValue({data:[{outcome:"denied"}],error:null});
  expect((await request(path,"PUT")).status).toBe(403);
  expect(matchesJudgeAccessRoute("POST",path)).toBe(false);
  expect(matchesJudgeAccessRoute("PUT",path+"/")).toBe(false);
 });
 it.each([["GET","/api/internal/status"],["POST","/api/auth/register"],["GET","/api/speed-dating/sessions/22222222-2222-4222-8222-222222222222/native-bootstrap"],["POST","/api/profiles/me/confirm/"],["GET","/api/profiles/other"]])("closes exact %s %s before authentication",async(method,path)=>{expect((await request(path,method)).status).toBe(403);expect(state.resolve).not.toHaveBeenCalled();});
 it("rejects unauthenticated and outside registered actors",async()=>{state.resolve.mockResolvedValue(null);expect((await request("/api/auth/me")).status).toBe(401);state.resolve.mockResolvedValue({userId:ACTOR,authUserId:"auth"});state.rpc.mockResolvedValue({data:[{outcome:"denied"}],error:null});expect((await request("/api/auth/me")).status).toBe(403);});
 it("delegates bounded text handler after membership and request quota",async()=>{expect((await request("/api/profiles/generate","POST")).status).toBe(200);expect(state.rpc.mock.calls.some(x=>x[0]==="reserve_judge_provider_operation")).toBe(false);});
 it("does not charge provider budget for SDP bootstrap readiness",async()=>expect((await request("/api/speed-dating/sessions/22222222-2222-4222-8222-222222222222/realtime-bootstrap","POST")).status).toBe(200));
 it("delegates vendor webhook without trusting a user token",async()=>{const r=await request("/api/webhooks/revenuecat","POST");expect(r.status).toBe(200);expect(state.resolve).not.toHaveBeenCalled();expect(state.rpc).not.toHaveBeenCalled();});
 it("fails closed on request quota denial",async()=>{state.rpc.mockImplementation(async name=>({data:[name==="check_judge_access"?{outcome:"allowed",actor_user_id:ACTOR,account_kind:"judge",counterpart_user_id:BOT,expires_at:ENV.JUDGE_ACCESS_EXPIRES_AT}:{outcome:"denied"}],error:null}));expect((await request("/api/auth/me")).status).toBe(429);});
 it("rejects unknown config instead of bypassing allowlist",async()=>{expect((await request("/api/auth/me","GET",{...ENV,JUDGE_ACCESS_UNKNOWN:"enabled"})).status).toBe(503);expect(state.resolve).not.toHaveBeenCalled();});
 it("checks expiry again after downstream work",async()=>{const a=new Hono<Env>();a.use("*",judgeAccessGate);a.get("/api/auth/me",c=>{vi.setSystemTime(Date.parse(ENV.JUDGE_ACCESS_EXPIRES_AT));return c.json({ok:true});});expect((await a.request("/api/auth/me",{headers:{Authorization:"Bearer fixture"}},ENV)).status).toBe(503);});
 it("permits normal owner chat request response PUT under auth and quota",async()=>{expect((await request(`/api/chat-requests/${BOT}`,"PUT")).status).toBe(200);expect(matchesJudgeAccessRoute("PUT","/api/chat-requests/invalid")).toBe(false);expect(state.rpc.mock.calls.map(x=>x[0])).toEqual(["check_judge_access","consume_judge_request"]);});
 it("recognizes only server-bounded voice paths and closed UUID input",()=>{expect(matchesJudgeAccessRoute("POST","/api/speed-dating/sessions/22222222-2222-4222-8222-222222222222/realtime-call")).toBe(true);expect(matchesJudgeAccessRoute("POST","/api/speed-dating/sessions/invalid/realtime-call")).toBe(false);});
});
