import {beforeEach,describe,expect,it,vi} from "vitest";
import type {Env} from "../env";
import {JUDGE_EXPIRES_AT,OWNER_QA_AI_EXPIRES_AT,readJudgeAccessConfig,readJudgeAccess,readJudgeWebhookAccess,reserveJudgeProviderOperation,consumeJudgeRequest,hasJudgeAccessConfig,type JudgeRpcClient} from "./judge-access";
import {JUDGE_SEVEN_OWNER_PROFILE_IDS} from "./synthetic-matching-cohort";
const NOW=Date.parse("2026-09-30T19:00:00Z"),ACTOR="11111111-1111-4111-8111-111111111111",BOT="22222222-2222-4222-8222-222222222222",KEY="33333333-3333-4333-8333-333333333333";
const ENV={JUDGE_ACCESS_ENABLED:"enabled",JUDGE_ACCESS_COHORT:["shipaton", "20261001"].join("-"),JUDGE_ACCESS_ISSUED_AT:"2026-09-30T18:00:00Z",JUDGE_ACCESS_EXPIRES_AT:JUDGE_EXPIRES_AT,JUDGE_ACCESS_AI_EXPIRES_AT:OWNER_QA_AI_EXPIRES_AT} as Env["Bindings"];
const CONFIG={issuedAtMs:Date.parse(ENV.JUDGE_ACCESS_ISSUED_AT!),expiresAtMs:Date.parse(JUDGE_EXPIRES_AT),aiExpiresAtMs:Date.parse(OWNER_QA_AI_EXPIRES_AT)};
const ROW={outcome:"allowed",actor_user_id:ACTOR,account_kind:"judge",counterpart_user_id:BOT,expires_at:"2026-10-13T19:00:00+00:00"};
const ACCESS={actorId:ACTOR,accountKind:"judge" as const,counterpartId:BOT,expiresAtMs:CONFIG.expiresAtMs};
beforeEach(()=>vi.clearAllMocks());
function client(data:unknown,error:unknown=null){const rpc=vi.fn(async()=>({data,error}));return {rpc};}
describe("judge fixed window",()=>{
 it("is absent only when all bindings are absent",()=>{expect(readJudgeAccessConfig(undefined,NOW)).toEqual({kind:"absent"});expect(hasJudgeAccessConfig({JUDGE_ACCESS_UNKNOWN:"enabled"} as unknown as Env["Bindings"])).toBe(true);});
 it("allows fixed judging deadline and owner QA 09:00 cutoff",()=>{expect(readJudgeAccessConfig(ENV,NOW)).toEqual({kind:"active",config:CONFIG});});
 it.each([{JUDGE_ACCESS_ENABLED:"disabled"},{JUDGE_ACCESS_ENABLED:"true"},{JUDGE_ACCESS_COHORT:"other"},{JUDGE_ACCESS_ISSUED_AT:"2026-02-30T00:00:00Z"},{JUDGE_ACCESS_ISSUED_AT:"2026-10-01T00:00:00Z"},{JUDGE_ACCESS_EXPIRES_AT:"2026-10-14T19:00:00Z"},{JUDGE_ACCESS_AI_EXPIRES_AT:"2026-10-01T01:00:00Z"},{JUDGE_ACCESS_UNKNOWN:"enabled"}])("fails closed for invalid configuration %#",overrides=>expect(readJudgeAccessConfig({...ENV,...overrides},NOW)).toEqual({kind:"invalid"}));
 it("closes exactly at final deadline",()=>expect(readJudgeAccessConfig(ENV,CONFIG.expiresAtMs)).toEqual({kind:"invalid"}));
});
describe("service-only own judge enrollment",()=>{
 it("reads only trusted actor and accepts singleton DB table rows",async()=>{const c=client([ROW]);expect(await readJudgeAccess(c,CONFIG,ACTOR,()=>NOW)).toEqual(ACCESS);expect(c.rpc).toHaveBeenCalledWith("check_judge_access",{p_user_id:ACTOR});});
 it.each(["owner","qa"])("bounds %s to 09:00 even when registry reports longer expiry",async kind=>{const c=client([{...ROW,account_kind:kind}]);expect((await readJudgeAccess(c,CONFIG,ACTOR,()=>NOW))?.expiresAtMs).toBe(CONFIG.aiExpiresAtMs);expect(await readJudgeAccess(c,CONFIG,ACTOR,()=>CONFIG.aiExpiresAtMs)).toBeNull();});
 it.each([null,[],[ROW,ROW],{...ROW,actor_user_id:BOT},{...ROW,account_kind:"customer"},{...ROW,counterpart_user_id:ACTOR},{...ROW,counterpart_user_id:"PRIVATE-CANARY"},{...ROW,expires_at:"2026-02-30T19:00:00Z"},{...ROW,expires_at:"2026-10-13T19:00:00"},{...ROW,expires_at:"2026-10-14T19:00:00Z"},{...ROW,outcome:"disabled"}])("rejects malformed, disabled or other-owner enrollment %#",async row=>expect(await readJudgeAccess(client(row),CONFIG,ACTOR,()=>NOW)).toBeNull());
 it("rejects expiry crossed while DB lookup awaits",async()=>{let now=NOW;const c={rpc:vi.fn(async()=>{now=CONFIG.expiresAtMs;return{data:[ROW],error:null};})};expect(await readJudgeAccess(c,CONFIG,ACTOR,()=>now)).toBeNull();});
});
describe("durable provider and request admission",()=>{
 const RESERVED={outcome:"allowed",reservation_id:KEY,max_units:20000,max_seconds:0};
 it("reserves only actor/closed operation/key without caller prices or quotas",async()=>{const c=client([RESERVED]);expect(await reserveJudgeProviderOperation(c,ACCESS,"profile_generate",KEY,()=>NOW)).toEqual({reservationId:KEY,maxUnits:20000,maxSeconds:0});expect(c.rpc).toHaveBeenCalledWith("reserve_judge_provider_operation",{p_user_id:ACTOR,p_operation:"profile_generate",p_idempotency_key:KEY});});
 it.each(["unknown","denied","expired","replayed"])("never mints or invokes a provider for %s reservation",async outcome=>expect(await reserveJudgeProviderOperation(client([{...RESERVED,outcome}]),ACCESS,"voice_session",KEY,()=>NOW)).toBeNull());
 it.each([{max_units:0},{max_units:100001},{max_units:1.5},{max_seconds:241},{max_seconds:-1},{reservation_id:"PRIVATE-CANARY"}])("rejects unbounded reservation %#",async overrides=>expect(await reserveJudgeProviderOperation(client([{...RESERVED,...overrides}]),ACCESS,"ward_chat",KEY,()=>NOW)).toBeNull());
 it("closes invalid operation and key without any RPC",async()=>{const c=client([RESERVED]);expect(await reserveJudgeProviderOperation(c,ACCESS,"google" as never,KEY,()=>NOW)).toBeNull();expect(await reserveJudgeProviderOperation(c,ACCESS,"ward_chat","invalid",()=>NOW)).toBeNull();expect(c.rpc).not.toHaveBeenCalled();});
 it("handles DB errors without unsafe retries",async()=>{expect(await reserveJudgeProviderOperation(client(RESERVED,{message:"PRIVATE-CANARY"}),ACCESS,"ward_chat",KEY,()=>NOW)).toBeNull();const c:JudgeRpcClient={rpc:async()=>{throw Error("PRIVATE-CANARY");}};expect(await consumeJudgeRequest(c,ACCESS,KEY,()=>NOW)).toBe(false);});
 it("uses durable per-actor request count independently of premium",async()=>{const c=client([{outcome:"allowed"}]);expect(await consumeJudgeRequest(c,ACCESS,KEY,()=>NOW)).toBe(true);expect(c.rpc).toHaveBeenCalledWith("consume_judge_request",{p_user_id:ACTOR,p_idempotency_key:KEY});expect(await consumeJudgeRequest(client([{outcome:"denied"}]),ACCESS,KEY,()=>NOW)).toBe(false);});
});
describe("fresh seven-account owners",()=>{
 const now=Date.parse("2026-10-01T11:00:00Z");
 const env={...ENV,JUDGE_ACCESS_ISSUED_AT:"2026-10-01T10:00:00Z",JUDGE_ACCESS_OWNER_AI_EXPIRES_AT:JUDGE_EXPIRES_AT};
 const config={...CONFIG,issuedAtMs:Date.parse(env.JUDGE_ACCESS_ISSUED_AT),ownerAiExpiresAtMs:CONFIG.expiresAtMs};
 it("allows a new issued window only with the fixed fresh-owner deadline",()=>{
  expect(readJudgeAccessConfig(env,now)).toEqual({kind:"active",config});
  expect(readJudgeAccessConfig({...env,JUDGE_ACCESS_OWNER_AI_EXPIRES_AT:undefined},now)).toEqual({kind:"invalid"});
  for(const value of ["", "2026-10-14T19:00:00Z", "2026-10-13T20:00:00Z"])
   expect(readJudgeAccessConfig({...env,JUDGE_ACCESS_OWNER_AI_EXPIRES_AT:value},now)).toEqual({kind:"invalid"});
 });
 it.each(JUDGE_SEVEN_OWNER_PROFILE_IDS)("allows fresh owner %s until judging ends in requests and webhooks",async actor=>{
  const row={...ROW,actor_user_id:actor,account_kind:"owner"};
  expect((await readJudgeAccess(client(row),config,actor,()=>now))?.expiresAtMs).toBe(CONFIG.expiresAtMs);
  expect(await readJudgeWebhookAccess(client({...row,auth_user_id:ACTOR}),config,ACTOR,()=>now)).toBe(true);
  expect(await readJudgeAccess(client(row),config,actor,()=>CONFIG.expiresAtMs)).toBeNull();
  expect(await readJudgeWebhookAccess(client({...row,auth_user_id:ACTOR}),config,ACTOR,()=>CONFIG.expiresAtMs)).toBe(false);
 });
 it.each([['qa','0ed47fef-1266-5fa9-8852-0a2c6b9dc741'],['owner','6d527260-24a9-57f6-8051-1c79eea0028f'],['owner',ACTOR],['qa',JUDGE_SEVEN_OWNER_PROFILE_IDS[0]]])("does not revive previous or other %s %s",async(kind,actor)=>{
  const row={...ROW,actor_user_id:actor,account_kind:kind};
  expect(await readJudgeAccess(client(row),config,actor,()=>now)).toBeNull();
  expect(await readJudgeWebhookAccess(client({...row,auth_user_id:ACTOR}),config,ACTOR,()=>now)).toBe(false);
 });
 it("retains the old cutoff for fresh owner IDs when new binding is absent",async()=>{
  const actor=JUDGE_SEVEN_OWNER_PROFILE_IDS[0];
  expect(await readJudgeAccess(client({...ROW,actor_user_id:actor,account_kind:"owner"}),CONFIG,actor,()=>now)).toBeNull();
 });
});
