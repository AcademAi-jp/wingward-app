import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Database } from "../db/types";
import { sendNotification, type NotificationsEnv, type SendNotificationParams, type SendNotificationResult } from "./notifications";

const rowSchema = z.object({
  batch_id: z.string().uuid(), match_id: z.string().uuid(), user_id: z.string().uuid(),
  conversation_id: z.string().uuid(), claim_token: z.string().uuid(),
  claim_generation: z.number().int().positive(),
}).strict();
export type DailyNotificationClaim = z.infer<typeof rowSchema>;
export interface DailyNotificationOutboxStore {
  claim(limit: number): Promise<unknown>;
  complete(row: DailyNotificationClaim, notificationId: string): Promise<boolean>;
  release(row: DailyNotificationClaim): Promise<boolean>;
  findDurableNotification(row: DailyNotificationClaim): Promise<string | null>;
}
export interface DailyNotificationOutboxResult { claimed: number; completed: number; pending: number; invalidResponse: boolean }
type RpcClient = {rpc(name: string, args: Record<string, unknown>): PromiseLike<{data: unknown;error: unknown}>};
function claimArgs(row: DailyNotificationClaim) {
  return {p_batch_id:row.batch_id,p_match_id:row.match_id,p_user_id:row.user_id,
    p_claim_token:row.claim_token,p_claim_generation:row.claim_generation};
}
export function createDailyNotificationOutboxStore(supabase: SupabaseClient<Database>): DailyNotificationOutboxStore {
  const client = supabase as unknown as RpcClient;
  return {
    async claim(limit) {
      const result=await client.rpc("claim_daily_matching_notification_outbox",{p_limit:limit,p_lease_seconds:120});
      if(result.error) throw new Error("Daily notifications unavailable");
      return result.data;
    },
    async complete(row,notificationId) {
      const result=await client.rpc("complete_daily_matching_notification_outbox",{...claimArgs(row),p_notification_id:notificationId});
      return !result.error && result.data === true;
    },
    async release(row) {
      const result=await client.rpc("release_daily_matching_notification_outbox",claimArgs(row));
      return !result.error && result.data === true;
    },
    async findDurableNotification(row) {
      const result=await supabase.from("notifications").select("id,payload,sent_at,scheduled_for,suppressed_reason")
        .eq("scenario_id","N-01").eq("user_id",row.user_id).eq("match_id",row.match_id)
        .order("created_at",{ascending:false}).limit(1).maybeSingle();
      if(result.error || !result.data) return null;
      const notification=result.data;
      const payload=notification.payload;
      if(!payload || typeof payload !== "object" || Array.isArray(payload)) return null;
      const context=payload.delivery_context;
      if(!context || typeof context !== "object" || Array.isArray(context) || context.conversation_id !== row.conversation_id) return null;
      if(!notification.sent_at && !notification.scheduled_for && notification.suppressed_reason !== "no_subscription") return null;
      return z.string().uuid().safeParse(notification.id).success ? notification.id : null;
    },
  };
}

/** No match announcement is sent until the DB claim has rechecked publication and completed Ward conversation. */
export async function deliverDailyMatchingNotifications(
  supabase: SupabaseClient<Database>,
  env: NotificationsEnv & {DURABLE_DAILY_BATCH_ENABLED?:string},
  options: {store?:DailyNotificationOutboxStore;send?:(params:SendNotificationParams)=>Promise<SendNotificationResult>;limit?:number}={},
): Promise<DailyNotificationOutboxResult> {
  const empty={claimed:0,completed:0,pending:0,invalidResponse:false};
  if(env.DURABLE_DAILY_BATCH_ENABLED !== "enabled" || !env.ONESIGNAL_APP_ID || !env.ONESIGNAL_API_KEY) return empty;
  const limit=options.limit ?? 2;
  if(!Number.isInteger(limit) || limit < 1 || limit > 2) return {...empty,invalidResponse:true};
  const store=options.store ?? createDailyNotificationOutboxStore(supabase);
  let raw:unknown;
  try {raw=await store.claim(limit);} catch {return {...empty,invalidResponse:true};}
  const parsed=z.array(rowSchema).max(limit).safeParse(raw);
  if(!parsed.success) return {...empty,invalidResponse:true};
  const keys=new Set<string>();
  for(const row of parsed.data) {
    const key=`${row.batch_id}/${row.match_id}/${row.user_id}`;
    if(keys.has(key)) return {...empty,invalidResponse:true};
    keys.add(key);
  }
  const result={...empty,claimed:parsed.data.length};
  const send=options.send ?? ((params:SendNotificationParams)=>sendNotification(supabase,env,params));
  for(const row of parsed.data) {
    let notificationId:string|null=null;
    try {
      const delivered=await send({scenarioId:"N-01",userId:row.user_id,matchId:row.match_id,
        deepLink:`wingward://match/${row.match_id}/fox-result`,deliveryContext:{conversation_id:row.conversation_id}});
      if(delivered.ok) notificationId=delivered.notificationId;
      else if(delivered.reason === "duplicate") notificationId=await store.findDurableNotification(row);
      if(notificationId && z.string().uuid().safeParse(notificationId).success && await store.complete(row,notificationId)) {
        result.completed++;continue;
      }
    } catch { /* Keep retry ownership and error content private. */ }
    result.pending++;
    try {await store.release(row);} catch { /* Lease expiry makes an ambiguous release recoverable. */ }
  }
  return result;
}
