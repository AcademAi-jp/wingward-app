import { Hono } from 'hono';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Env } from '../env';
const A='11111111-1111-4111-8111-111111111111',B='22222222-2222-4222-8222-222222222222',R='33333333-3333-4333-8333-333333333333',M='44444444-4444-4444-8444-444444444444';
const mocks=vi.hoisted(()=>({access:vi.fn(),get:vi.fn(),apply:vi.fn()}));
vi.mock('../db/client',()=>({getSupabaseClient:()=>({})}));
vi.mock('../middleware/auth',()=>({requireAuth:async(c:import('hono').Context,next:()=>Promise<void>)=>{c.set('user_id','11111111-1111-4111-8111-111111111111');await next();},requireAgeVerified:async(_c:unknown,next:()=>Promise<void>)=>next()}));
vi.mock('../services/chat-meetup',async()=>{const actual=await vi.importActual('../services/chat-meetup');return{...actual,checkChatMeetupRoomAccess:(...args:unknown[])=>mocks.access(...args),getChatMeetupState:(...args:unknown[])=>mocks.get(...args),applyChatMeetupAction:(...args:unknown[])=>mocks.apply(...args)};});
import routes from './chat-meetups';
const state={room_id:R,meetup_id:null,revision:0,status:'idle'};
function app(judge=true){const a=new Hono<Env>();a.use('*',async(c,next)=>{if(judge)c.set('judge_access',{actorId:A,counterpartId:B,accountKind:'judge',expiresAtMs:Date.parse('2026-10-13T19:00:00Z')});await next();});a.route('/api/chat-meetups',routes);return a;}
const post=()=>({method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({expected_revision:0,expected_own_revision:0,idempotency_key:M,action:{type:'intent',value:'yes'}})});
beforeEach(()=>{vi.clearAllMocks();mocks.access.mockResolvedValue({ok:true,context:{userA:A,userB:B,matchId:M}});mocks.get.mockResolvedValue({ok:true,state});mocks.apply.mockResolvedValue({ok:true,state});});
describe('trusted judge meetup metadata',()=>{
 it('marks only exactpair normal GET state with match ID',async()=>{const r=await app().request(`/api/chat-meetups/rooms/${R}`,{}, {CHAT_MEETUP_ENABLED:'enabled'});expect(r.status).toBe(200);expect(await r.json()).toEqual({data:{...state,simulated_counterpart:true,judge_match_id:M}});});
 it('marks successful ordinary action for exactpair',async()=>{const r=await app().request(`/api/chat-meetups/rooms/${R}/actions`,post(),{CHAT_MEETUP_ENABLED:'enabled'});expect(r.status).toBe(200);expect(await r.json()).toEqual({data:{...state,simulated_counterpart:true,judge_match_id:M}});expect(mocks.apply).toHaveBeenCalledTimes(1);});
 it('rejects another room peer before read or write',async()=>{mocks.access.mockResolvedValue({ok:true,context:{userA:A,userB:R,matchId:M}});for(const [path,init] of [[`/api/chat-meetups/rooms/${R}`,{}],[`/api/chat-meetups/rooms/${R}/actions`,post()]] as const){expect((await app().request(path,init,{CHAT_MEETUP_ENABLED:'enabled'})).status).toBe(404);}expect(mocks.get).not.toHaveBeenCalled();expect(mocks.apply).not.toHaveBeenCalled();});
 it('preserves normal blocked or deleted room denial',async()=>{mocks.access.mockResolvedValue({ok:false,reason:'not_found'});expect((await app().request(`/api/chat-meetups/rooms/${R}`,{}, {CHAT_MEETUP_ENABLED:'enabled'})).status).toBe(404);expect(mocks.get).not.toHaveBeenCalled();});
 it('omits simulation metadata for ordinary state',async()=>{const r=await app(false).request(`/api/chat-meetups/rooms/${R}`,{}, {CHAT_MEETUP_ENABLED:'enabled'});expect(await r.json()).toEqual({data:state});expect(mocks.access).not.toHaveBeenCalled();});
});
