/** Daily match publication and post-publication status reporting. */
import { pruneMeetupPrivateInputs } from "./meetup-private-input-janitor";

import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { getSupabaseClient } from "../db/client";
import { DAILY_BATCH_TIME_ZONE, getBatchTimeZone, getTodayInTimeZone, toDateStringInTimeZone } from "../lib/date";
import { executeDailyMatching } from "./daily-matching";
import { sendDeferredNotifications } from "./notifications";
import { handleMeetupExpiryCron, MEETUP_EXPIRY_CRON } from "./meetup-expiry";
import type { DONamespace } from "../env";

export interface BatchResult {
	batchDate: string;
	batchId: string | null;
	status: "disabled" | "not_started" | "busy" | "resumable" | "completed";
	conversationStatus: "not_requested" | "pending" | "completed";
	conversationsPending: number;
	totalMatches: number;
	conversationsCompleted: number;
	conversationsFailed: number;
}

export interface RunDailyBatchOptions {
	/** Retained for callers; daily matching never bypasses the quota-gated request path. */
	foxConversationDO?: DONamespace;
	/** Required explicit rollout gate. Missing/disabled never uses the old matcher. */
	durableEnabled?: boolean;
	/** Resume an existing Tokyo date only; never creates a batch on a 15-minute tick. */
	resumeOnly?: boolean;
}

interface BatchConversationSummary {
	requested_count: number;
	pending_count: number;
	in_progress_count: number;
	completed_count: number;
	failed_count: number;
}

const conversationSummaryShape = (value: unknown): value is BatchConversationSummary => {
	if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
	const row = value as Record<string, unknown>;
	const keys = ["requested_count", "pending_count", "in_progress_count", "completed_count", "failed_count"];
	if (Object.keys(row).length !== keys.length || !keys.every((key) => Object.hasOwn(row, key))) return false;
	if (!keys.every((key) => Number.isSafeInteger(row[key]) && (row[key] as number) >= 0)) return false;
	const counts = row as unknown as BatchConversationSummary;
	return counts.requested_count === counts.pending_count + counts.in_progress_count
		+ counts.completed_count + counts.failed_count;
};

async function loadBatchConversationSummary(
	supabase: SupabaseClient<Database>,
	batchId: string,
): Promise<BatchConversationSummary> {
	const client = supabase as unknown as {
		rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }>;
	};
	const result = await client.rpc("get_durable_daily_matching_conversation_status", { p_batch_id: batchId });
	if (result.error || !conversationSummaryShape(result.data)) {
		throw new Error("Durable daily batch conversation status is unavailable");
	}
	return result.data;
}

/**
 * Runs only the daily match publication. Compatibility Fox conversations are
 * created and charged exclusively by `requestFoxConversation`; this function
 * never creates, restarts, or charges one. The summary distinguishes matches
 * published from any later, quota-backed compatibility conversation.
 */
export async function runDailyBatch(
	supabase: SupabaseClient<Database>,
	_mistralApiKey: string | undefined,
	batchTimeZone: string,
	batchDate?: string,
	options: RunDailyBatchOptions = {},
): Promise<BatchResult> {
	if (batchTimeZone !== DAILY_BATCH_TIME_ZONE) {
		throw new Error(`Daily matching timezone is fixed to ${DAILY_BATCH_TIME_ZONE}`);
	}
	const date = batchDate ?? getTodayInTimeZone(batchTimeZone);
	const empty = (status: BatchResult["status"], batchId: string | null = null): BatchResult => ({
		batchDate: date,
		batchId,
		status,
		conversationStatus: "not_requested",
		conversationsPending: 0,
		totalMatches: 0,
		conversationsCompleted: 0,
		conversationsFailed: 0,
	});
	if (options.durableEnabled !== true) return empty("disabled");

	const matchResult = await executeDailyMatching(supabase, date, 1, {
		durableEnabled: true,
		resumeOnly: options.resumeOnly === true,
	});
	if (matchResult.status !== "completed") return empty(matchResult.status, matchResult.batchId);
	if (!matchResult.batchId) throw new Error("Completed daily matching has no durable batch id");
	const conversationSummary = await loadBatchConversationSummary(supabase, matchResult.batchId);
	const conversationsPending = conversationSummary.pending_count
		+ conversationSummary.in_progress_count
		+ conversationSummary.failed_count;
	const conversationStatus: BatchResult["conversationStatus"] = conversationSummary.requested_count === 0
		? "not_requested"
		: conversationsPending === 0 ? "completed" : "pending";
	return {
		batchDate: date,
		batchId: matchResult.batchId,
		status: "completed",
		conversationStatus,
		conversationsPending,
		totalMatches: matchResult.totalMatches,
		conversationsCompleted: conversationSummary.completed_count,
		conversationsFailed: conversationSummary.failed_count,
	};
}
/**
 * The cron expression that runs the daily matching batch, and the one that
 * runs the deferred-notification executor.
 *
 * These strings must match `[triggers] crons` in `apps/api/wrangler.toml`
 * CHARACTER FOR CHARACTER — Cloudflare hands `scheduled` the raw expression it
 * was configured with, so a whitespace difference silently routes to no job at
 * all. `daily-batch-cron-wiring.test.ts` reads wrangler.toml and fails the
 * build if the two ever drift apart; do not change one without the other.
 *
 * This is source wiring only. It records the cron expressions the deployed
 * worker must use when the trigger is enabled; it does not establish that a
 * trigger was deployed, registered, or observed running. Deployment and
 * runtime status belong to the release gate, while this test only prevents the
 * source constants and wrangler.toml from drifting. See that file's
 * `[triggers]` comment before changing either.
 *
 * Why the two workloads are separated at all: they used to share one handler
 * with `event.cron` ignored, so BOTH ran on EVERY trigger. The deferred
 * executor needs to run every 15 minutes (a notification held for quiet hours
 * should go out promptly after 08:00 local, and users span many timezones),
 * while the daily batch must run exactly once a day. Sharing a trigger meant
 * choosing between a stale notification queue and 96 daily batches a day.
 */
export const DAILY_BATCH_CRON = "0 0 * * *"; // 00:00 UTC = 09:00 JST
export const DEFERRED_SEND_CRON = "*/15 * * * *";

/**
 * Cloudflare Cron Triggers の scheduled イベントハンドラ
 *
 * Routes on `event.cron`. An unrecognised expression runs NOTHING and logs:
 * the alternative — falling back to "run everything" — would turn a
 * wrangler.toml typo into the daily batch firing on the 15-minute schedule.
 * The wiring test exists so that this failure mode is caught at build time
 * rather than discovered from the logs.
 */
export async function handleScheduled(
	event: { cron: string; scheduledTime: number },
	env: {
		SUPABASE_URL: string;
		SUPABASE_SERVICE_ROLE_KEY: string;
		MISTRAL_API_KEY?: string;
		FOX_CONVERSATION?: DONamespace;
		BATCH_TIMEZONE?: string;
		DURABLE_DAILY_BATCH_ENABLED?: string;
		ONESIGNAL_APP_ID?: string;
		ONESIGNAL_API_KEY?: string;
		DEFERRED_SEND_LIMIT?: string;
	},
): Promise<void> {
	const supabase = getSupabaseClient(env as any);

	if (
		event.cron !== DAILY_BATCH_CRON &&
		event.cron !== DEFERRED_SEND_CRON &&
		event.cron !== MEETUP_EXPIRY_CRON
	) {
		console.error(
			`[handleScheduled] no job is wired to cron expression ${JSON.stringify(event.cron)} — nothing ran. wrangler.toml's [triggers] crons and the constants in services/daily-batch.ts have drifted apart.`,
		);
		return;
	}

	if (event.cron === DAILY_BATCH_CRON) {
		try {
			const batchTimeZone = getBatchTimeZone(env);
			const scheduledDate = toDateStringInTimeZone(new Date(event.scheduledTime), batchTimeZone);
			const result = await runDailyBatch(supabase, env.MISTRAL_API_KEY, batchTimeZone, scheduledDate, {
				durableEnabled: env.DURABLE_DAILY_BATCH_ENABLED === "enabled",
				foxConversationDO: env.FOX_CONVERSATION,
			});
			console.log(
				`[handleScheduled] Daily batch ${result.status}: ${result.totalMatches} matches, ${result.conversationsPending} conversations pending`,
			);
		} catch {
			console.error("[handleScheduled] Daily batch failed");
		}
	}

	// Deferred-send executor (step-04-notifications.md §3-1): sends held
	// notifications whose quiet-hours `scheduled_for` has passed. It has its
	// own, much more frequent trigger — a notification held until 08:00 local
	// should not wait for tomorrow's batch — and deliberately does NOT share an
	// invocation with the daily batch, both so their subrequest budgets stay
	// separate and so the batch cannot run 96 times a day.
	if (event.cron === DEFERRED_SEND_CRON) {
		// Privacy cleanup runs independently of notification delivery and flags.
		await pruneMeetupPrivateInputs(supabase as never);
		try {
			const deferredResult = await sendDeferredNotifications(supabase, env);
			if (deferredResult.processed > 0) {
				console.log(
					`[handleScheduled] Deferred notifications: ${deferredResult.processed} processed, ${deferredResult.sent} sent, ${deferredResult.suppressed} suppressed, ${deferredResult.failed} failed`,
				);
			}
		} catch {
			console.error("[handleScheduled] Deferred notification send failed");
		}
	}

	// Code-only Phase 2 branch. The expression is deliberately not added to
	// wrangler.toml here; enabling a new external schedule remains a separate,
	// explicitly approved integration action.
	if (event.cron === MEETUP_EXPIRY_CRON) {
		await handleMeetupExpiryCron(event, supabase as never, {
			now: new Date(event.scheduledTime),
		});
	}
}
