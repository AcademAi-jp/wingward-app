import { Hono, type Context } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
const OWNER="11111111-1111-4111-8111-111111111111", PEER="22222222-2222-4222-8222-222222222222";
const PROFILE={id:"33333333-3333-4333-8333-333333333333",user_id:OWNER,personality_tags:["Thoughtful"],interaction_style:{overall_signature:"Original saved analysis"},values:{original:0.4},confirmed_preferences:{rhythm_preference:"slow"},merged_persona_version:1,version:2,status:"confirmed"};
const latest={user_id:OWNER,version:1,traits:{rhythm_preference:"slow",priority_value:"community",communication_preference:"balanced"},confirmed_at:"2026-09-30T16:06:37+00:00"};
const getClient=vi.fn();
vi.mock("../db/client",()=>({getSupabaseClient:(...args:unknown[])=>getClient(...args)}));
vi.mock("../middleware/auth",()=>({requireAuth:async(c:Context,next:()=>Promise<void>)=>{if(c.req.header("x-test-auth")!=="owner")return c.json({error:{code:"UNAUTHORIZED"}},401);c.set("user_id",OWNER);await next();}}));
import profiles from "./profiles";
function setup(data:unknown=latest,error:unknown=null,throws=false,previous:unknown=latest,previousError:unknown=null,previousThrows=false){
 const calls:Array<{table:string;method:string;args:unknown[]}> = [];
 let reads=0;
 const client={from(table:string){const query:Record<string,unknown>={};for(const method of ["select","eq","order","limit"]){query[method]=(...args:unknown[])=>{calls.push({table,method,args});return query;};}query.maybeSingle=async()=>{if(table==='profiles')return{data:PROFILE,error:null};if(reads++===0){if(throws)throw Error('PRIVATE-CANARY');return{data,error};}if(previousThrows)throw Error('PRIVATE-CANARY');return{data:previous,error:previousError};};return query;}};
 getClient.mockReturnValue(client);const app=new Hono<Env>();app.route('/api/profiles',profiles);return{app,calls};
}
beforeEach(()=>vi.clearAllMocks());
describe('own profile latest confirmed persona',()=>{
 it('preserves existing profile attributes and returns only latest owner-confirmed enum traits',async()=>{
  const{app,calls}=setup({...latest,private_transcript:'PRIVATE-CANARY',source_meetup_id:'PRIVATE-SOURCE'});
  const response=await app.request('/api/profiles/me',{headers:{'x-test-auth':'owner'}});const body=await response.json();
  expect(response.status).toBe(200);expect(response.headers.get('cache-control')).toBe('private, no-store');
  expect(body).toEqual({data:{...PROFILE,latest_confirmed_persona:{version:1,traits:latest.traits,confirmed_at:'2026-09-30T16:06:37.000Z',changes:{compared_to_version:null,added_keys:['communication_preference','priority_value','rhythm_preference'],changed_keys:[]}}}});
  expect(calls.filter(c=>c.table==='user_persona_versions')).toEqual([
   {table:'user_persona_versions',method:'select',args:['user_id,version,traits,confirmed_at']},
   {table:'user_persona_versions',method:'eq',args:['user_id',OWNER]},
   {table:'user_persona_versions',method:'order',args:['version',{ascending:false}]},
   {table:'user_persona_versions',method:'limit',args:[1]},
  ]);
 });
 it('keeps a no-revision profile readable with a null optional projection',async()=>{
  const{app}=setup(null);const r=await app.request('/api/profiles/me',{headers:{'x-test-auth':'owner'}});
  expect(await r.json()).toEqual({data:{...PROFILE,latest_confirmed_persona:null}});
 });
 it.each([
  {label:'other owner',data:{...latest,user_id:PEER}},
  {label:'unknown trait',data:{...latest,traits:{private_note:'PRIVATE-CANARY'}}},
  {label:'invalid enum',data:{...latest,traits:{rhythm_preference:'PRIVATE-CANARY'}}},
  {label:'unconfirmed version',data:{...latest,version:0}},
  {label:'empty traits',data:{...latest,traits:{}}},
  {label:'future confirmation',data:{...latest,confirmed_at:'2999-01-01T00:00:00Z'}},
  {label:'unbounded version',data:{...latest,version:3_000_000_000}},
  {label:'missing timezone',data:{...latest,confirmed_at:'2026-09-30T16:06:37'}},
 ])('marks $label unavailable without leaking revision content',async({data})=>{
  const{app}=setup(data);const r=await app.request('/api/profiles/me',{headers:{'x-test-auth':'owner'}});
  expect(r.status).toBe(200);expect(await r.json()).toEqual({data:{...PROFILE,latest_confirmed_persona:null,latest_confirmed_persona_unavailable:true}});
 });
 it.each([false,true])('keeps revision query failure safe (throws=%s)',async(throws)=>{
  const{app}=setup(null,{message:'PRIVATE-CANARY'},throws);const r=await app.request('/api/profiles/me',{headers:{'x-test-auth':'owner'}});
  expect(await r.json()).toEqual({data:{...PROFILE,latest_confirmed_persona:null,latest_confirmed_persona_unavailable:true}});
 });
 it('requires authentication before any profile or revision read',async()=>{
  const{app,calls}=setup();const r=await app.request('/api/profiles/me');expect(r.status).toBe(401);expect(calls).toEqual([]);expect(getClient).not.toHaveBeenCalled();
 });
});


describe('own confirmed persona changes',()=>{
 const v2={...latest,version:2,traits:{...latest.traits,rhythm_preference:'moderate',social_energy:'introverted'},confirmed_at:'2026-09-30T16:07:37+00:00'};
 const current={version:2,traits:v2.traits,confirmed_at:'2026-09-30T16:07:37.000Z'};
 async function body(app:Hono<Env>){return(await (await app.request('/api/profiles/me',{headers:{'x-test-auth':'owner'}})).json()) as {data:{latest_confirmed_persona:{changes:unknown}}};}
 it('reports only newly added keys and changed values, preserving the original profile',async()=>{
  const{app,calls}=setup(v2);expect(await body(app)).toEqual({data:{...PROFILE,latest_confirmed_persona:{...current,changes:{compared_to_version:1,added_keys:['social_energy'],changed_keys:['rhythm_preference']}}}});
  expect(calls.filter(c=>c.table==='user_persona_versions').slice(4)).toEqual([{table:'user_persona_versions',method:'select',args:['user_id,version,traits,confirmed_at']},{table:'user_persona_versions',method:'eq',args:['user_id',OWNER]},{table:'user_persona_versions',method:'eq',args:['version',1]}]);
 });
 it('does not mark unchanged cumulative preferences as updated in later snapshots',async()=>{
  const{app}=setup({...v2,traits:latest.traits});expect(await body(app)).toEqual({data:{...PROFILE,latest_confirmed_persona:{...current,traits:latest.traits,changes:{compared_to_version:1,added_keys:[],changed_keys:[]}}}});
 });
 it('compares v3 to v2 instead of treating the entire cumulative snapshot as the latest update',async()=>{
  const traits={...v2.traits,priority_value:'learning',favorite_activity:'reading'};
  const{app,calls}=setup({...v2,version:3,traits,confirmed_at:'2026-09-30T16:08:37Z'},null,false,v2);
  const r=await body(app);expect(r.data.latest_confirmed_persona.changes).toEqual({compared_to_version:2,added_keys:['favorite_activity'],changed_keys:['priority_value']});expect(calls.some(c=>c.method==='eq'&&c.args[0]==='version'&&c.args[1]===2)).toBe(true);
 });
 it.each([
  {label:'missing previous snapshot',previous:null},
  {label:'other owner',previous:{...latest,user_id:PEER}},
  {label:'noncontinuous version',previous:{...latest,version:7}},
  {label:'unconfirmed version',previous:{...latest,version:0}},
  {label:'unknown key',previous:{...latest,traits:{private_note:'PRIVATE-CANARY'}}},
  {label:'invalid enum',previous:{...latest,traits:{rhythm_preference:'PRIVATE-CANARY'}}},
  {label:'empty traits',previous:{...latest,traits:{}}},
  {label:'invalid timestamp',previous:{...latest,confirmed_at:'invalid'}},
  {label:'future timestamp',previous:{...latest,confirmed_at:'2999-01-01T00:00:00Z'}},
  {label:'time reversal',previous:{...latest,confirmed_at:'2026-09-30T16:07:38Z'}},
  {label:'removed cumulative key',previous:{...latest,traits:{...latest.traits,favorite_activity:'reading'}}},
 ])('keeps latest and original readable when $label makes comparison unavailable',async({previous})=>{
  const{app}=setup(v2,null,false,previous);expect(await body(app)).toEqual({data:{...PROFILE,latest_confirmed_persona:{...current,changes:null,changes_unavailable:true}}});
 });
 it.each([false,true])('keeps latest preferences when previous query fails (throws=%s)',async throws=>{const{app}=setup(v2,null,false,null,{message:'PRIVATE-CANARY'},throws);expect(await body(app)).toEqual({data:{...PROFILE,latest_confirmed_persona:{...current,changes:null,changes_unavailable:true}}});});
 it('supports the same instant and normalizes previous timezone offsets for comparison',async()=>{const{app}=setup(v2,null,false,{...latest,confirmed_at:'2026-10-01T01:07:37+09:00'});expect((await body(app)).data.latest_confirmed_persona.changes).toEqual({compared_to_version:1,added_keys:['social_energy'],changed_keys:['rhythm_preference']});});
});
