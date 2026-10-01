import { z } from "zod";
import type { MeetupExpiryRow } from "./meetups";

/**
 * Code-only cron branch.  The integration owner may add this expression to
 * its scheduler after review; this leaf does not alter cron configuration.
 */
/** Hourly at minute 7 UTC; intentionally offset from the quarter-hour job. */
export const MEETUP_EXPIRY_CRON = "7 * * * *";

export type MeetupExpiryNotificationContext = MeetupExpiryRow;

export interface MeetupExpiryNotifier {
	notify(context: MeetupExpiryNotificationContext): Promise<void>;
}

export const noopMeetupExpiryNotifier: MeetupExpiryNotifier = Object.freeze({
	async notify(): Promise<void> {
		// Notification delivery belongs to the integration branch.
	},
});

type ExpiryClient = {
	rpc(functionName: string, args: Record<string, unknown>): Promise<{ data: unknown; error: unknown }>;
};

const expiryRowSchema = z
	.object({
		meetup_id: z.string().uuid(),
		match_id: z.string().uuid(),
		previous_status: z.enum(["intent_pending", "proposed", "confirmed"]),
		status: z.literal("expired"),
		transitioned: z.literal(true),
	})
	.strict();

export type MeetupExpiryResult = {
	transitioned: MeetupExpiryRow[];
	notificationContexts: MeetupExpiryNotificationContext[];
};

/**
 * Claims intent (7d), proposal (48h), and confirmed-meeting-boundary expiry
 * in one server-side RPC.  The SQL function returns only rows it changed;
 * this function forwards notifications only for those rows.
 */
export async function expireMeetups(
	client: ExpiryClient,
	options: { now?: Date; notifier?: MeetupExpiryNotifier } = {},
): Promise<MeetupExpiryResult> {
	const now = options.now ?? new Date();
	if (!(now instanceof Date) || !Number.isFinite(now.getTime())) {
		return { transitioned: [], notificationContexts: [] };
	}

	let result: { data: unknown; error: unknown };
	try {
		result = (await client.rpc("claim_expired_meetups", {
			p_now: now.toISOString(),
		})) as unknown as { data: unknown; error: unknown };
	} catch {
		return { transitioned: [], notificationContexts: [] };
	}
	if (result.error || !Array.isArray(result.data)) return { transitioned: [], notificationContexts: [] };

	const transitioned: MeetupExpiryRow[] = [];
	for (const row of result.data) {
		const parsed = expiryRowSchema.safeParse(row);
		if (!parsed.success) continue;
		const context: MeetupExpiryRow = {
			meetupId: parsed.data.meetup_id,
			matchId: parsed.data.match_id,
			previousStatus: parsed.data.previous_status,
			status: "expired",
		};
		transitioned.push(context);
		try {
			await (options.notifier ?? noopMeetupExpiryNotifier).notify(context);
		} catch {
			// Expiry is already durable.  A notification failure must not make a
			// later cron run reinterpret the row as still active.
		}
	}

	return {
	transitioned,
	notificationContexts: transitioned,
	};
}

/**
 * Scheduler adapter.  An unknown expression is a deliberate no-op and does
 * not even call the database, protecting the daily batch from cron typos.
 */
export async function handleMeetupExpiryCron(
	event: { cron: string },
	client: ExpiryClient,
	options: { now?: Date; notifier?: MeetupExpiryNotifier } = {},
): Promise<MeetupExpiryResult & { ran: boolean }> {
	if (event.cron !== MEETUP_EXPIRY_CRON) {
		return { ran: false, transitioned: [], notificationContexts: [] };
	}
	return { ran: true, ...(await expireMeetups(client, options)) };
}

export const runMeetupExpiry = expireMeetups;
