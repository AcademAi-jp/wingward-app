import {Hono} from "hono";
import {beforeEach,describe,expect,it,vi} from "vitest";
import type {Env} from "../env";
const owner="11111111-1111-4111-8111-111111111111",id="22222222-2222-4222-8222-222222222222";
const s=vi.hoisted(()=>({rows:[] as Record<string,unknown>[],writes:[] as Record<string,unknown>[],generate:vi.fn()}));
vi.mock("../middleware/auth",()=>({requireAuth:async(c:any,next:any)=>{c.set("user_id",owner);c.set("judge_access",{actorId:owner,accountKind:"owner",counterpartId:id,expiresAtMs:Date.now()+60000});await next();}}));
vi.mock("../services/judge-chat-complete",()=>({judgeChatComplete:s.generate}));
vi.mock("../lib/fox-icons",()=>({getRandomIconUrlForGender:()=>"/fixture.png"}));
vi.mock("../db/client",()=>({getSupabaseClient:()=>({from:(table:string)=>{
 let write:Record<string,unknown>|undefined;const q:any={};for(const m of ["select","eq","in","single","maybeSingle"])q[m]=()=>q;
 q.upsert=(v:Record<string,unknown>)=>{write=v;if(table==="personas")s.writes.push(v);return q;};
 q.then=(yes:any,no:any)=>Promise.resolve({data:table==="user_profiles"?{conversation_language:"en",age_verified_at:"2026-09-01T00:00:00Z",onboarding_settings_completed_at:"2026-09-01T00:00:00Z"}:table==="quiz_answers"?[]:table==="personas"?(write?{id:write.persona_type==="virtual_similar"?"33333333-3333-4333-8333-333333333333":"44444444-4444-4444-8444-444444444444"}:s.rows):null,error:null}).then(yes,no);return q;
}})}));
import route from "./speed-dating";
const saved={id,user_id:owner,persona_type:"virtual_discovery",name:"Saved",compiled_document:"Saved interview persona"};
const request=()=>{const app=new Hono<Env>();app.route("/api/speed-dating",route);return app.request("/api/speed-dating/personas",{method:"POST"},{MISTRAL_API_KEY:"synthetic"});};
beforeEach(()=>{s.rows=[saved];s.writes=[];s.generate.mockReset().mockResolvedValue("name: Fixture\n## Core Identity\nSynthetic.");});
describe("judging partial catalog recovery",()=>{
 it("generates missing styles and preserves the saved persona",async()=>{const r=await request();expect(r.status).toBe(200);const body=await r.json() as any;expect(s.generate).toHaveBeenCalledTimes(2);expect(s.writes.map(x=>x.persona_type)).toEqual(["virtual_similar","virtual_complementary"]);expect(body.data).toHaveLength(3);expect(body.data[0]).toMatchObject({id,compiled_document:saved.compiled_document});});
 it("uses no provider or writes for a complete catalog",async()=>{s.rows=[saved,{...saved,id:"33333333-3333-4333-8333-333333333333",persona_type:"virtual_similar"},{...saved,id:"44444444-4444-4444-8444-444444444444",persona_type:"virtual_complementary"}];expect((await request()).status).toBe(200);expect(s.generate).not.toHaveBeenCalled();expect(s.writes).toEqual([]);});
 it.each(["other_owner","duplicate"])("rejects %s before provider or writes",async kind=>{s.rows=kind==="other_owner"?[{...saved,user_id:id}]:[saved,saved];expect((await request()).status).toBe(500);expect(s.generate).not.toHaveBeenCalled();expect(s.writes).toEqual([]);});
});
