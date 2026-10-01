import {Hono} from "hono";
import {afterEach,beforeEach,describe,expect,it,vi} from "vitest";
import type {Env} from "../env";
import type {JudgeAccess} from "../services/judge-access";
const state=vi.hoisted(()=>({rpc:vi.fn(),provider:vi.fn()}));
vi.mock("../db/client",()=>({getSupabaseClient:()=>({rpc:state.rpc})}));
vi.mock("../services/mistral",()=>({chatCompleteOnceBounded:state.provider,MISTRAL_LARGE:"mistral-large-2512",MISTRAL_REQUEST_TOKEN_OVERHEAD:1024}));
import route from "./judge-readiness";
import {JUDGE_20261001_PROFILE_IDS,JUDGE_SEVEN_OWNER_PROFILE_IDS} from "../services/synthetic-matching-cohort";
const actors=[...JUDGE_20261001_PROFILE_IDS.slice(0,5),...JUDGE_SEVEN_OWNER_PROFILE_IDS];
const issued=Date.parse("2026-10-01T11:35:00Z"),end="2026-10-13T19:00:00Z",peer="22222222-2222-4222-8222-222222222222";
const env={JUDGE_ACCESS_ENABLED:"enabled",JUDGE_ACCESS_COHORT:["shipaton","20261001"].join("-"),JUDGE_ACCESS_ISSUED_AT:"2026-10-01T11:35:00Z",JUDGE_ACCESS_EXPIRES_AT:end,JUDGE_ACCESS_AI_EXPIRES_AT:"2026-10-01T00:00:00Z",JUDGE_ACCESS_OWNER_AI_EXPIRES_AT:end,MISTRAL_API_KEY:"synthetic-key"};
let current:JudgeAccess|undefined;
const probe=(body?:string|ReadableStream<Uint8Array>,bindings:unknown=env,modelLookup=false)=>{
 const app=new Hono<Env>();app.use('*',async(c,next)=>{if(current){c.set('user_id',current.actorId);c.set('judge_access',current);}await next();});app.route('/api/judge',route);
 const init:RequestInit&{duplex?:"half"}={method:modelLookup?'GET':'POST',...(body===undefined?{}:{body}),...(body instanceof ReadableStream?{duplex:'half' as const}:{})};
 return app.request(new Request('http://localhost/api/judge/readiness'+(modelLookup?'/provider':''),init),undefined,bindings as Env['Bindings']);
};
beforeEach(()=>{
 vi.useFakeTimers();vi.setSystemTime(issued+60000);vi.clearAllMocks();
 current={actorId:actors[0],accountKind:'judge',counterpartId:peer,expiresAtMs:Date.parse(end)};
 state.rpc.mockImplementation(async name=>({data:[name==='check_judge_access'?{outcome:'allowed',actor_user_id:current?.actorId,account_kind:current?.accountKind,counterpart_user_id:peer,expires_at:end}:{outcome:'allowed',reservation_id:peer,max_units:20000,max_seconds:180}],error:null}));
 state.provider.mockResolvedValue({content:'READY'});
});
afterEach(()=>{vi.useRealTimers();vi.unstubAllGlobals();});
describe('read-only vendor model diagnostics',()=>{
 it('does not follow vendor redirects and reports only fixed destination classifications',async()=>{
  const fetcher=vi.fn().mockResolvedValueOnce(new Response(null,{status:307,headers:{Location:'https://api.mistral.ai/v1/models/mistral-large-2512/'}})).mockResolvedValueOnce(new Response(null,{status:302,headers:{Location:'https://untrusted.invalid/private-key-in-path?secret=canary'}}));vi.stubGlobal('fetch',fetcher);
  expect(await (await probe(undefined,env,true)).json()).toEqual({data:{connected:false,providerStatus:307,redirectTarget:'same_model_slash'}});
  expect(await (await probe(undefined,env,true)).json()).toEqual({data:{connected:false,providerStatus:302,redirectTarget:'other_origin'}});
  expect(fetcher).toHaveBeenCalledTimes(2);
 });
 it('classifies vendor failures without returning exception text',async()=>{
  vi.stubGlobal('fetch',vi.fn().mockRejectedValue(new TypeError('Cannot follow redirect: synthetic-secret-value')));
  const response=await probe(undefined,env,true);
  expect(await response.json()).toEqual({data:{connected:false,reason:'model_lookup_failed',stage:'fetch',cause:'redirect_blocked'}});
 });
 it('classifies malformed successful vendor JSON without leaking it',async()=>{
  vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response('private-invalid-json')));
  expect(await (await probe(undefined,env,true)).json()).toEqual({data:{connected:false,reason:'model_lookup_failed',stage:'json',cause:'other_error'}});
 });
 it('checks only the fixed model and returns no credential or raw vendor response',async()=>{
  const fetcher=vi.fn().mockResolvedValue(new Response(JSON.stringify({id:'mistral-large-2512',private:'private-vendor-value'})));
  vi.stubGlobal('fetch',fetcher);
  const response=await probe(undefined,env,true);
  expect(await response.json()).toEqual({data:{connected:true,providerStatus:200}});
  expect(fetcher).toHaveBeenCalledOnce();expect(fetcher.mock.calls[0][0]).toBe('https://api.mistral.ai/v1/models/mistral-large-2512');
  expect(fetcher.mock.calls[0][1]).toMatchObject({method:'GET',redirect:'manual'});
  expect(state.provider).not.toHaveBeenCalled();expect(state.rpc.mock.calls.map(c=>c[0])).toEqual(['check_judge_access','check_judge_access']);
 });
 it('reports only HTTP status on rejected vendor authentication',async()=>{
  vi.stubGlobal('fetch',vi.fn().mockResolvedValue(new Response('synthetic-key and private-output',{status:401})));
  const response=await probe(undefined,env,true);expect(await response.json()).toEqual({data:{connected:false,providerStatus:401}});expect(state.provider).not.toHaveBeenCalled();
 });
 it('never connects when key is absent',async()=>{
  const fetcher=vi.fn();vi.stubGlobal('fetch',fetcher);
  expect(await (await probe(undefined,{...env,MISTRAL_API_KEY:undefined},true)).json()).toEqual({data:{connected:false,reason:'key_unavailable'}});expect(fetcher).not.toHaveBeenCalled();
 });
 it('refuses oversized response and wrong model without exposing content',async()=>{
  const fetcher=vi.fn().mockResolvedValueOnce(new Response('x'.repeat(8193))).mockResolvedValueOnce(new Response(JSON.stringify({id:'other-model',private:'private-output'})));vi.stubGlobal('fetch',fetcher);
  expect(await (await probe(undefined,env,true)).json()).toEqual({data:{connected:false,reason:'invalid_model_response'}});
  expect(await (await probe(undefined,env,true)).json()).toEqual({data:{connected:false,providerStatus:200}});
 });
 it('closes before vendor access for missing actor and deadline',async()=>{
  const fetcher=vi.fn();vi.stubGlobal('fetch',fetcher);current=undefined;expect((await probe(undefined,env,true)).status).toBe(403);
  current={actorId:actors[0],accountKind:'judge',counterpartId:peer,expiresAtMs:Date.parse(end)};
  vi.setSystemTime(issued+30*60000);expect((await probe(undefined,env,true)).status).toBe(410);expect(fetcher).not.toHaveBeenCalled();expect(state.rpc).not.toHaveBeenCalled();
 });
 it('drops vendor success if access expires during model lookup',async()=>{
  vi.stubGlobal('fetch',vi.fn().mockImplementation(async()=>{vi.setSystemTime(issued+30*60000);return new Response(JSON.stringify({id:'mistral-large-2512'}));}));
  expect((await probe(undefined,env,true)).status).toBe(403);
 });
});
describe('bounded seven-account provider readiness',()=>{
 it.each(actors)('uses a fixed paid receipt and returns only boolean for %s',async actor=>{
  current={...current!,actorId:actor,accountKind:actors.indexOf(actor)<5?'judge':'owner'};
  const response=await probe();expect(response.status).toBe(200);expect(await response.json()).toEqual({data:{ready:true}});
  expect(state.rpc.mock.calls[1]).toEqual(['reserve_judge_provider_operation',{p_user_id:actor,p_operation:'personas_generate',p_idempotency_key:expect.stringMatching(/^[0-9a-f-]{36}$/)}]);
  expect(state.rpc.mock.calls[1][1].p_idempotency_key).not.toBe(actor);
  expect(state.provider).toHaveBeenCalledOnce();expect(state.provider.mock.calls[0][2]).toMatchObject({model:'mistral-large-2512',maxTokens:8,maxTotalTokenUnits:20000,maxRequestBytes:18968,maxResponseBytes:4096});
 });
 it('keeps one distinct transport repair receipt per member across repeated requests',async()=>{
  const keys=[];
  for(const actor of actors){current={...current!,actorId:actor,accountKind:actors.indexOf(actor)<5?'judge':'owner'};await probe();const key=state.rpc.mock.calls.at(-2)![1].p_idempotency_key;await probe();expect(state.rpc.mock.calls.at(-2)![1].p_idempotency_key).toBe(key);keys.push(key);}
  expect(new Set(keys).size).toBe(7);expect(keys.some(key=>actors.includes(key))).toBe(false);
 });
 it('closes at the exact thirty-minute boundary before any RPC or provider',async()=>{
  vi.setSystemTime(issued+30*60000);const response=await probe();expect(response.status).toBe(410);expect(await response.json()).toEqual({code:'closed'});expect(state.rpc).not.toHaveBeenCalled();expect(state.provider).not.toHaveBeenCalled();
 });
 it('rejects user content without reserving or forwarding it',async()=>{
  expect((await probe('synthetic-private-input')).status).toBe(400);expect(state.rpc).not.toHaveBeenCalled();expect(state.provider).not.toHaveBeenCalled();
 });
 it('accepts a genuinely empty POST stream without treating it as user input',async()=>{
  const empty=new ReadableStream<Uint8Array>({start(controller){controller.close();}});
  expect((await probe(empty)).status).toBe(200);expect(state.provider).toHaveBeenCalledOnce();
 });
 it('rejects absent, arbitrary and legacy QA contexts',async()=>{
  current=undefined;expect((await probe()).status).toBe(403);
  current={actorId:JUDGE_20261001_PROFILE_IDS[6],accountKind:'qa',counterpartId:peer,expiresAtMs:Date.parse(end)};expect((await probe()).status).toBe(403);
  current={...current,actorId:peer,accountKind:'owner'};expect((await probe()).status).toBe(403);expect(state.provider).not.toHaveBeenCalled();
 });
 it.each(['unknown','denied','replayed','expired'])('never calls provider on %s reservation',async outcome=>{
  const original=state.rpc.getMockImplementation()!;state.rpc.mockImplementation(async(name,...args)=>name==='reserve_judge_provider_operation'?{data:[{outcome}],error:null}:original(name,...args));
  expect((await probe()).status).toBe(429);expect(state.provider).not.toHaveBeenCalled();
 });
 it('does not expose provider errors or retry failed paid fetch',async()=>{
  state.provider.mockRejectedValue(new Error('synthetic-key and provider-private-output'));
  const response=await probe();expect(response.status).toBe(503);expect(await response.text()).not.toContain('synthetic-key');expect(state.provider).toHaveBeenCalledOnce();expect(state.rpc.mock.calls).toHaveLength(2);
 });
 it('drops successful output when deadline expires during fetch',async()=>{
  state.provider.mockImplementation(async()=>{vi.setSystemTime(issued+30*60000);return {content:'READY'};});expect((await probe()).status).toBe(503);
 });
 it('rejects non-READY model output without exposing it',async()=>{
  state.provider.mockResolvedValue({content:'synthetic-private-output'});const response=await probe();expect(response.status).toBe(503);expect(await response.text()).not.toContain('synthetic-private-output');
 });
});
