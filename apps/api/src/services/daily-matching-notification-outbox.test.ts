import {describe,it,expect,vi} from "vitest";
import {deliverDailyMatchingNotifications,type DailyNotificationOutboxStore} from "./daily-matching-notification-outbox";
const uuid=(tail:string)=>`00000000-0000-4000-8000-${tail.padStart(12,"0")}`;
const row={batch_id:uuid("1"),match_id:uuid("2"),user_id:uuid("3"),conversation_id:uuid("4"),claim_token:uuid("5"),claim_generation:1};
const env={DURABLE_DAILY_BATCH_ENABLED:"enabled",ONESIGNAL_APP_ID:"synthetic-app",ONESIGNAL_API_KEY:"synthetic-key"};
function store():DailyNotificationOutboxStore {return {claim:vi.fn().mockResolvedValue([row]),complete:vi.fn().mockResolvedValue(true),release:vi.fn().mockResolvedValue(true),findDurableNotification:vi.fn().mockResolvedValue(null)};}
describe("published daily matching notification outbox",()=>{
 it.each([undefined,"true","disabled"])("does no claim/send when gate is %s",async(gate)=>{
  const s=store(),send=vi.fn();const result=await deliverDailyMatchingNotifications({} as never,{...env,DURABLE_DAILY_BATCH_ENABLED:gate},{store:s,send});
  expect(result.claimed).toBe(0);expect(s.claim).not.toHaveBeenCalled();expect(send).not.toHaveBeenCalled();
 });
 it("does not claim if provider is unavailable",async()=>{
  const s=store();await deliverDailyMatchingNotifications({} as never,{...env,ONESIGNAL_API_KEY:undefined},{store:s});expect(s.claim).not.toHaveBeenCalled();
 });
 it("rejects malformed or duplicate claims before any send",async()=>{
  for(const rows of [[{...row,private_location:"CANARY"}],[row,row],[{...row,claim_generation:0}]]) {
   const s=store();vi.mocked(s.claim).mockResolvedValue(rows);const send=vi.fn();
   const result=await deliverDailyMatchingNotifications({} as never,env,{store:s,send});
   expect(result.invalidResponse).toBe(true);expect(send).not.toHaveBeenCalled();expect(s.complete).not.toHaveBeenCalled();
  }
 });
 it.each(["sent","deferred","suppressed_no_subscription"])("acks only durable delivery %s using its exact fence",async(outcome)=>{
  const s=store(),send=vi.fn().mockResolvedValue({ok:true,notificationId:uuid("6"),outcome});
  const result=await deliverDailyMatchingNotifications({} as never,env,{store:s,send});
  expect(result).toEqual({claimed:1,completed:1,pending:0,invalidResponse:false});
  expect(s.complete).toHaveBeenCalledWith(row,uuid("6"));expect(s.release).not.toHaveBeenCalled();
  expect(send).toHaveBeenCalledWith({scenarioId:"N-01",userId:row.user_id,matchId:row.match_id,deepLink:`wingward://match/${row.match_id}/fox-result`,deliveryContext:{conversation_id:row.conversation_id}});
 });
 it("release retries provider failure without marking complete",async()=>{
  const s=store(),send=vi.fn().mockRejectedValue(new Error("PRIVATE CANARY"));
  const result=await deliverDailyMatchingNotifications({} as never,env,{store:s,send});
  expect(result.pending).toBe(1);expect(JSON.stringify(result)).not.toContain("CANARY");expect(s.complete).not.toHaveBeenCalled();expect(s.release).toHaveBeenCalledWith(row);
 });
 it("unproven duplicate remains pending; durable existing duplicate can ack",async()=>{
  const s=store(),send=vi.fn().mockResolvedValue({ok:false,reason:"duplicate"});
  expect((await deliverDailyMatchingNotifications({} as never,env,{store:s,send})).pending).toBe(1);
  vi.mocked(s.findDurableNotification).mockResolvedValue(uuid("6"));
  expect((await deliverDailyMatchingNotifications({} as never,env,{store:s,send})).completed).toBe(1);
 });
 it("lost ack or fence is pending and retryable",async()=>{
  const s=store();vi.mocked(s.complete).mockResolvedValue(false);
  const send=vi.fn().mockResolvedValue({ok:true,notificationId:uuid("6"),outcome:"sent"});
  expect((await deliverDailyMatchingNotifications({} as never,env,{store:s,send})).pending).toBe(1);expect(s.release).toHaveBeenCalledWith(row);
 });
 it("rejects unbounded worker limit before claim",async()=>{
  const s=store();expect((await deliverDailyMatchingNotifications({} as never,env,{store:s,limit:3})).invalidResponse).toBe(true);expect(s.claim).not.toHaveBeenCalled();
 });
});
