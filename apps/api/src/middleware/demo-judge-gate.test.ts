import { Hono } from "hono";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
const state=vi.hoisted(()=>({auth:vi.fn(),db:vi.fn()}));
vi.mock("./auth",()=>({resolveAuthUser:state.auth}));vi.mock("../db/client",()=>({getSupabaseClient:state.db}));
import {productionE2EGate} from "./production-e2e-gate";
import {demoJudgeGate} from "./demo-judge-gate";
import {DEMO_20260930_PROFILE_IDS as IDS,SYNTHETIC_MATCHING_PROFILE_IDS as OLD} from "../services/synthetic-matching-cohort";
const NOW=Date.parse("2026-09-30T10:00:00Z"),END=NOW+7200000;
const ENV={DEMO_JUDGE_ENABLED:"enabled",DEMO_JUDGE_COHORT:"demo-20260930",DEMO_JUDGE_ISSUED_AT:new Date(NOW).toISOString(),DEMO_JUDGE_EXPIRES_AT:new Date(END).toISOString()};
function probe(actor:string=IDS[0]){vi.useFakeTimers();vi.setSystemTime(NOW);state.auth.mockReset().mockResolvedValue({authUserId:"test-auth",userId:actor});const app=new Hono<Env>();app.use("*",demoJudgeGate);app.all("*",c=>c.json({actor:c.get("user_id")}));return app;}
const headers={Authorization:"Bearer private-test"};afterEach(()=>vi.useRealTimers());
describe("judge gate",()=>{
 it.each(IDS)("admits exact Auth profile %s",async actor=>expect((await probe(actor).request("/api/demo-judge/matching/results",{headers},ENV)).status).toBe(200));
 it.each([...OLD,"11111111-1111-4111-8111-111111111111"])("rejects outsider %s",async actor=>expect((await probe(actor).request("/api/auth/me",{headers},ENV)).status).toBe(403));
 it.each(["/api/testing/synthetic-session","/api/profiles/generate","/api/recording-rehearsal/matching/start","/api/chat-requests"])("blocks other mutation %s",async path=>{const app=probe();expect((await app.request(path,{method:"POST",headers},ENV)).status).toBe(403);expect(state.auth).not.toHaveBeenCalled();});
 it("replaces finalized downstream response when permit expires during handler",async()=>{
  probe();const app=new Hono<Env>();app.use("*",demoJudgeGate);
  app.get("/api/auth/me",async c=>{await Promise.resolve();vi.setSystemTime(END);return c.json({privatePayload:"must-not-leave-after-expiry"});});
  const response=await app.request("/api/auth/me",{headers},ENV);
  expect(response.status).toBe(503);
  expect(await response.text()).not.toContain("must-not-leave-after-expiry");
 });
 it("closes after auth await expires",async()=>{const app=probe();state.auth.mockImplementation(async()=>{vi.setSystemTime(END);return{authUserId:"test-auth",userId:IDS[0]};});expect((await app.request("/api/auth/me",{headers},ENV)).status).toBe(503);});
 it("denies detail for same actor but legacy Ren partner",async()=>{const app=probe();state.db.mockReturnValue({from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>({data:{user_a_id:IDS[0],user_b_id:OLD[1]},error:null})})})})});expect((await app.request("/api/matching/results/11111111-1111-4111-8111-111111111111",{headers},ENV)).status).toBe(404);});
});

describe("production dispatch with judge tombstone",()=>{
 it("allows a new Maya recording prep only when prior judge is disabled complete expired",async()=>{
  probe("a88a89e2-5421-5ce9-a33b-76d512898c37");const app=new Hono<Env>();app.use("*",productionE2EGate);app.get("/api/auth/me",c=>c.json({ok:true}));
  const closed={...ENV,DEMO_JUDGE_ENABLED:"disabled",DEMO_JUDGE_ISSUED_AT:"2026-09-30T06:00:00Z",DEMO_JUDGE_EXPIRES_AT:"2026-09-30T08:00:00Z",RECORDING_REHEARSAL_ENABLED:"enabled",RECORDING_REHEARSAL_PAIR:"demo-maya-ren",RECORDING_REHEARSAL_ISSUED_AT:new Date(NOW).toISOString(),RECORDING_REHEARSAL_EXPIRES_AT:new Date(END).toISOString(),RECORDING_REHEARSAL_OWNER_PREP_ONLY:"enabled"};
  expect((await app.request("/api/auth/me",{headers},closed)).status).toBe(200);
  for(const override of [{DEMO_JUDGE_ENABLED:"enabled"},{DEMO_JUDGE_EXPIRES_AT:undefined},{DEMO_JUDGE_EXPIRES_AT:new Date(END).toISOString()}])expect((await app.request("/api/auth/me",{headers},{...closed,...override})).status).toBe(503);
 });
});
