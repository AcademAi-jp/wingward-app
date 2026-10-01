import { hasJudgeAccessConfig } from './services/judge-access'
import { hasDemoJudgeConfig } from './services/demo-judge-window'
import { app } from './app'
import { handleScheduled, DEFERRED_SEND_CRON, runDailyBatch } from './services/daily-batch'
import { getSupabaseClient } from './db/client'
import { getBatchTimeZone, toDateStringInTimeZone } from './lib/date'
import { deliverDailyMatchingNotifications } from './services/daily-matching-notification-outbox'
import type { Env } from './env'
import { hasRecordingRehearsalConfig } from './services/recording-rehearsal'

export { FoxConversationDO } from './durable-objects/fox-conversation-do'
export { JudgeRealtimeCall } from './durable-objects/judge-realtime-call-do'

type ScheduledEvent = { cron: string; scheduledTime: number };

/** Existing deferred tick resumes only an already-started batch while handleScheduled owns private-input cleanup. */
export async function runScheduledMaintenance(event: ScheduledEvent, env: Env["Bindings"]): Promise<void> {
    if (hasJudgeAccessConfig(env) || hasRecordingRehearsalConfig(env) || hasDemoJudgeConfig(env)) return;
    if (event.cron !== DEFERRED_SEND_CRON) return;
    if (env.CHAT_MEETUP_ENABLED !== "enabled" && env.DURABLE_DAILY_BATCH_ENABLED !== "enabled") return;
    const supabase = getSupabaseClient(env);
    if (env.DURABLE_DAILY_BATCH_ENABLED === "enabled") {
        try {
            const zone = getBatchTimeZone(env);
            const date = toDateStringInTimeZone(new Date(event.scheduledTime), zone);
            await runDailyBatch(supabase, env.MISTRAL_API_KEY ?? "", zone, date, {
                durableEnabled: true, resumeOnly: true, foxConversationDO: env.FOX_CONVERSATION,
            });
        } catch { console.error("[scheduled] Daily batch continuation unavailable"); }
        try { await deliverDailyMatchingNotifications(supabase, env); }
        catch { console.error("[scheduled] Daily notification delivery unavailable"); }
    }
}

export default {
    fetch: app.fetch,
    scheduled: async (event: ScheduledEvent, env: Env["Bindings"], ctx: { waitUntil: (p: Promise<void>) => void }) => {
        if (hasJudgeAccessConfig(env) || hasRecordingRehearsalConfig(env) || hasDemoJudgeConfig(env)) return;
        ctx.waitUntil((async () => {
            await handleScheduled(event, env);
            await runScheduledMaintenance(event, env);
        })());
    },
}
