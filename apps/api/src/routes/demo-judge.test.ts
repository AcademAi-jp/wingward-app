import {Hono} from "hono";
import {afterEach,beforeEach,describe,expect,it,vi} from "vitest";
import type {Env} from "../env";
const mocks=vi.hoisted(()=>({matching:vi.fn(),snapshot:vi.fn(),db:vi.fn()}));
vi.mock("../middleware/auth",()=>({requireAuth:async(_c:unknown,next:()=>Promise<void>)=>next(),requireAgeVerified:async(_c:unknown,next:()=>Promise<void>)=>next()}));
vi.mock("../db/client",()=>({getSupabaseClient:mocks.db}));
vi.mock("../services/matching",()=>({executeMatching:mocks.matching}));
vi.mock("../services/matching-current-access",()=>({readMatchingCurrentSnapshot:mocks.snapshot}));
import route from "./demo-judge";
import {readDemoJudgeConfig} from "../services/demo-judge-window";
import {DEMO_20260930_PROFILE_IDS as IDS} from "../services/synthetic-matching-cohort";
const NOW=Date.parse("2026-09-30T10:00:00Z"),END=NOW+7200000;
const env={DEMO_JUDGE_ENABLED:"enabled",DEMO_JUDGE_COHORT:"demo-20260930",DEMO_JUDGE_ISSUED_AT:new Date(NOW).toISOString(),DEMO_JUDGE_EXPIRES_AT:new Date(END).toISOString()};
function app(configured=true){const app=new Hono<Env>();app.use("*",async(c,next)=>{const value=readDemoJudgeConfig(env);if(configured&&value.kind==="active")c.set("demo_judge",value.config);c.set("user_id",IDS[0]);await next();});app.route("/api/demo-judge",route);return app;}
function dbRows(rows:unknown[]){const q={select:()=>q,in:()=>q,or:()=>q,order:()=>q,limit:async()=>({data:rows,error:null})};mocks.db.mockReturnValue({from:()=>q});}
beforeEach(()=>{vi.useFakeTimers();vi.setSystemTime(NOW);vi.clearAllMocks();mocks.matching.mockResolvedValue(3);});afterEach(()=>vi.useRealTimers());
describe("independent ordinary-discovery route contract",()=>{
 it.each(["preview","start"])("returns honest %s count with server-only fixed scope",async mode=>{const response=await app().request(`/api/demo-judge/matching/${mode}`,{method:"POST",body:JSON.stringify({profileIds:["outsider"],mode:"start"})});expect(response.status).toBe(200);expect(await response.json()).toEqual({data:{source:"ordinary-discovery",outcome:mode==="preview"?"eligible":"started",count:3}});const scope=mocks.matching.mock.calls[0][3];expect(scope).toMatchObject({profileIds:IDS,actorId:IDS[0],mode});expect(scope.canWrite()).toBe(true);});
 it("requires a configured window before matching",async()=>{expect((await app(false).request("/api/demo-judge/matching/start",{method:"POST"})).status).toBe(503);expect(mocks.matching).not.toHaveBeenCalled();});
 it("checks expiry after normal matching awaits",async()=>{mocks.matching.mockImplementation(async()=>{vi.setSystemTime(END);return 3;});expect((await app().request("/api/demo-judge/matching/start",{method:"POST"})).status).toBe(503);});
 it("returns persisted matches with no daily ledger metadata",async()=>{dbRows([{id:"match-1",user_a_id:IDS[0],user_b_id:IDS[1]}]);mocks.snapshot.mockResolvedValue({ok:true,rows:new Map([["match-1",{id:"match-1",user_a_id:IDS[0],user_b_id:IDS[1],profile_b:{nickname:"Fictional partner"},status:"pending",profile_score:65,final_score:null,conversation_score:null,score_details:{},compatibilityConversation:null}]])});const response=await app().request("/api/demo-judge/matching/results");expect(response.status).toBe(200);const body=await response.json() as {data:Record<string,unknown>};expect(Object.keys(body.data).sort()).toEqual(["matches","source","total_matches"]);expect(body.data).toMatchObject({source:"ordinary-discovery",total_matches:1,matches:[{partner_id:IDS[1],status:"pending",profile_score:65,fox_conversation_id:null}]});});
 it("rejects an outside partner before current-access lookup",async()=>{dbRows([{id:"match-out",user_a_id:IDS[0],user_b_id:"9d836fee-7b93-41ce-b577-34a63006aaea"}]);expect((await app().request("/api/demo-judge/matching/results")).status).toBe(503);expect(mocks.snapshot).not.toHaveBeenCalled();});
 it("denies if current ordinary eligibility rejects a persisted match",async()=>{dbRows([{id:"match-1",user_a_id:IDS[0],user_b_id:IDS[1]}]);mocks.snapshot.mockResolvedValue({ok:false});expect((await app().request("/api/demo-judge/matching/results")).status).toBe(503);});
 it("checks expiry after current-access awaits",async()=>{dbRows([{id:"match-1",user_a_id:IDS[0],user_b_id:IDS[1]}]);mocks.snapshot.mockImplementation(async()=>{vi.setSystemTime(END);return{ok:true,rows:new Map()};});expect((await app().request("/api/demo-judge/matching/results")).status).toBe(503);});
});
