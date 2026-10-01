import { Hono } from 'hono';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Env } from '../env';
const OWNER='11111111-1111-4111-8111-111111111111', OTHER='22222222-2222-4222-8222-222222222222', ID='33333333-3333-4333-8333-333333333333';
const mocks=vi.hoisted(()=>({getClient:vi.fn(),matching:vi.fn()}));
vi.mock('../db/client',()=>({getSupabaseClient:()=>mocks.getClient()}));
vi.mock('../services/matching',()=>({executeMatching:(...args:unknown[])=>mocks.matching(...args)}));
vi.mock('../middleware/auth',()=>({requireAuth:async(c:import('hono').Context,next:()=>Promise<void>)=>{if(c.req.header('Authorization')!=='Bearer owner')return c.json({},401);c.set('user_id','11111111-1111-4111-8111-111111111111');await next();}}));
import profiles from './profiles';
const existing={id:ID,user_id:OWNER,status:'draft',basic_info:{age_range:'20s',location:'Tokyo',occupation:'Teacher'},values:{privacy:'saved'}};
function setup(row:unknown=existing,changed=false){const writes:Array<{filters:unknown[];payload:Record<string,unknown>}>=[];const reads:unknown[]=[];const client={from(table:string){const filters:unknown[]=[];let payload:Record<string,unknown>|undefined;const q:Record<string,unknown>={};q.select=()=>q;q.eq=(k:string,v:unknown)=>{filters.push([k,v]);return q;};q.update=(v:Record<string,unknown>)=>{payload=v;writes.push({filters,payload:v});return q;};q.maybeSingle=async()=>{reads.push({table,filters});return {data:payload?(changed?null:{...existing,...payload}):row,error:null};};return q;}};mocks.getClient.mockReturnValue(client);const a=new Hono<Env>();a.route('/api/profiles',profiles);return{app:a,writes,reads};}
const edit=(app:Hono<Env>,body:unknown,auth='Bearer owner')=>app.request('/api/profiles/me',{method:'PUT',headers:{Authorization:auth,'Content-Type':'application/json'},body:JSON.stringify(body)});
beforeEach(()=>{vi.clearAllMocks();mocks.matching.mockResolvedValue(0);});
describe('owner draft tags and biography edit',()=>{
 it('preserves generated fields and atomically binds owner,id,draft state',async()=>{const s=setup();const r=await edit(s.app,{personality_tags:[' Kind ','Curious','Thoughtful'],basic_info:{bio:'I like learning.'}});expect(r.status).toBe(200);expect(s.writes).toEqual([{payload:{updated_at:expect.any(String),personality_tags:['Kind','Curious','Thoughtful'],basic_info:{...existing.basic_info,bio:'I like learning.'}},filters:[['id',ID],['user_id',OWNER],['status','draft']]}]);expect(s.writes[0]?.payload).not.toHaveProperty('values');});
 it.each([{personality_tags:['one','two']},{personality_tags:['a','b','c','d','e','f']},{personality_tags:['','b','c']},{personality_tags:['x'.repeat(101),'b','c']},{basic_info:{bio:'x'.repeat(1001)}},{basic_info:{bio:'hello',location:'new'}},{values:{priority:'override'}},{confirmed_preferences:{rhythm_preference:'fast'}},{status:'draft'},{}, {extra:'x'.repeat(9000)}])('rejects unbounded or canonical input before DB',async body=>{const s=setup();expect((await edit(s.app,body)).status).toBe(400);expect(mocks.getClient).not.toHaveBeenCalled();expect(s.writes).toEqual([]);});
 it('rejects unauthenticated edit before DB',async()=>{const s=setup();expect((await edit(s.app,{personality_tags:['a','b','c']},'')).status).toBe(401);expect(mocks.getClient).not.toHaveBeenCalled();});
 it('rejects confirmed and unexpected states without writes',async()=>{for(const status of ['confirmed','unknown']){const s=setup({...existing,status});expect((await edit(s.app,{personality_tags:['a','b','c']})).status).toBe(409);expect(s.writes).toEqual([]);}});
 it('rejects other-owner read data without writes',async()=>{const s=setup({...existing,user_id:OTHER});expect((await edit(s.app,{personality_tags:['a','b','c']})).status).toBe(500);expect(s.writes).toEqual([]);});
 it('reports conflict when confirmation races the draft update',async()=>{const s=setup(existing,true);expect((await edit(s.app,{personality_tags:['a','b','c']})).status).toBe(409);expect(s.writes[0]?.filters).toContainEqual(['status','draft']);});
});
