import { beforeEach, describe, expect, it, vi } from "vitest";
import { checkJudgeSimulatedAdmission, judgeSimulatedRpc } from "./judge-simulated-admission";
const A="11111111-1111-4111-8111-111111111111", B="22222222-2222-4222-8222-222222222222", R="33333333-3333-4333-8333-333333333333", M="44444444-4444-4444-8444-444444444444";
const access={actorId:A,counterpartId:B,accountKind:"judge" as const,expiresAtMs:Date.parse("2026-10-13T19:00:00Z")};
beforeEach(()=>{vi.useFakeTimers();vi.setSystemTime("2026-10-02T00:00:00Z");});
describe("judge simulated admission remains registry and scope bound",()=>{
 it("accepts only the strict private boolean and wraps the actor's action",async()=>{
  const rpc=vi.fn().mockResolvedValue({data:[{admitted:true}],error:null}); const a=await checkJudgeSimulatedAdmission({rpc},access,A,{roomId:R});
  expect(a).not.toBeNull(); await judgeSimulatedRpc({rpc},"apply_chat_meetup_action",{p_user_id:A,p_room_id:R},a!);
  expect(rpc.mock.calls[1]).toEqual(["judge_simulated_apply_chat_meetup_action",{p_judge_actor_id:A,p_user_id:A,p_room_id:R}]);
 });
 it.each([null,[],[{admitted:true},{admitted:true}],{admitted:false},{admitted:"true"},"admitted"])("rejects malformed admission %j",async data=>{
  const rpc=vi.fn().mockResolvedValue({data,error:null});expect(await checkJudgeSimulatedAdmission({rpc},access,A,{meetupId:M})).toBeNull();
 });
 it("rejects expiry crossing the database await",async()=>{
  const rpc=vi.fn(async()=>{vi.setSystemTime(access.expiresAtMs);return{data:{admitted:true},error:null};});expect(await checkJudgeSimulatedAdmission({rpc},access,A,{roomId:R})).toBeNull();
 });
 it("rejects missing scope and actor mismatch before any RPC",async()=>{
  const rpc=vi.fn(); for(const [user,scope] of [[B,{roomId:R}],[A,{}],[A,{roomId:"bad"}]] as const)expect(await checkJudgeSimulatedAdmission({rpc},access,user,scope)).toBeNull(); expect(rpc).not.toHaveBeenCalled();
 });
 it.each([["ordinary_operation",{p_user_id:A,p_room_id:R}],["apply_chat_meetup_action",{p_user_id:B,p_room_id:R}],["apply_chat_meetup_action",{p_user_id:A,p_room_id:M}],["get_meetup_reflection_state",{p_user_id:A,p_meetup_id:R}]])("refuses changed operation or action scope %s",async(name,args)=>{
  const rpc=vi.fn();expect((await judgeSimulatedRpc({rpc},name as string,args as Record<string,unknown>,{access,roomId:R,meetupId:M})).error).toBeTruthy();expect(rpc).not.toHaveBeenCalled();
 });
 it("drops a result when the trusted window expires during the wrapper",async()=>{
  const rpc=vi.fn(async()=>{vi.setSystemTime(access.expiresAtMs);return{data:{outcome:"ok"},error:null};});expect((await judgeSimulatedRpc({rpc},"get_meetup_reflection_state",{p_user_id:A,p_meetup_id:M},{access,meetupId:M})).error).toBeTruthy();
 });
});
