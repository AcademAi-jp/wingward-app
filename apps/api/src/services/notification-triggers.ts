import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Database } from "../db/types";
import { type NotificationsEnv, sendNotification } from "./notifications";
import { checkVerifiedPair } from "./match-age-access";
import { isSyntheticMatchingProfile } from "./synthetic-matching-cohort";
import type {
	MeetupArrangementNotificationContext,
	MeetupArrangementNotifier,
} from "./meetups";

/**
 * The per-scenario trigger sites: the production callers of `sendNotification`.
 *
 * Until this file existed the send pipeline had none, so nothing built in step
 * 4-A ran in production. Every function here follows the same three rules.
 *
 * 1. **A notification never fails the action that caused it.** Each function
 *    returns void and swallows its own errors after logging them. A user who
 *    successfully sent a chat request has sent a chat request, whether or not
 *    the push went out. The callers pair this with `waitUntil` where they have
 *    an execution context, so the notification does not delay the response
 *    either.
 * 2. **The scenario's own trigger condition is checked here, not at the call
 *    site.** N-01 fires for `purpose = 'compatibility'` conversations only, and
 *    that check lives in this file so the DO does not have to know it. The
 *    call sites stay one line.
 * 3. **No PII crosses into the notification.** The visible copy comes from
 *    `notification-copy.ts`, a fixed server-side constant; the only per-user
 *    values passed from here are ids, which is what the deep-link allow-list
 *    in `lib/deep-links.ts` is built to accept.
 *
 * Quiet hours, the 24h dedup and lost-permission handling are all owned by
 * `sendNotification` itself (step-04-notifications.md §3-1), so no caller has
 * to think about them and no caller can get them wrong.
 *
 * N-04 and N-07 are dispatched together when the server-owned meetup state
 * reaches `verifying`. The validation below deliberately remains in this
 * trigger rather than trusting the route result: retries can be scheduled
 * after the original transition, and no caller should be able to turn an
 * arbitrary meetup id into a push.
 */

interface TriggerContext {
	supabase: SupabaseClient<Database>;
	env: NotificationsEnv;
}

/**
 * Runs a send and reports its outcome to the log without ever throwing.
 * `sendNotification` already returns a result rather than throwing for the
 * outcomes it knows about; this also contains the ones it does not (a network
 * failure inside supabase-js, say), because these run inside `waitUntil` where
 * a rejection is an unhandled promise rejection in the Worker.
 */
async function dispatch(
	{ supabase, env }: TriggerContext,
	label: string,
	params: Parameters<typeof sendNotification>[2],
): Promise<void> {
	try {
		const result = await sendNotification(supabase, env, params);
		if (result.ok === false) {
			// Not all of these are problems: "duplicate" and
			// "suppressed_no_subscription" are the pipeline working. Logged at
			// one level so the trigger's behaviour is observable either way.
			console.log(`[notification-trigger/${label}] notification not sent: ${result.reason}`);
		}
	} catch {
		// Keep transport/database exception details out of logs. The trigger is
		// deliberately best-effort, and the stable label is enough to locate the
		// failing path without retaining an identifier or raw error payload.
		console.error(`[notification-trigger/${label}] notification dispatch failed`);
	}
}

/**
 * N-01 — "Your Fox found something": a compatibility fox conversation finished
 * for a match. Both participants own the match and both are sent to; each gets
 * their own `notifications` row, so the 24h dedup and quiet-hours handling are
 * per-person, which is what a shared row could not express.
 *
 * Called from the Durable Object's alarm on the success path, which is the one
 * place that knows a conversation reached a terminal `completed` state.
 */
export async function notifyFoxConversationCompleted(
	ctx: TriggerContext,
	args: { conversationId: string; matchId: string },
): Promise<void> {
	const { data: conversation, error: conversationError } = await ctx.supabase
		.from("fox_conversations")
		.select("purpose")
		.eq("id", args.conversationId)
		.single();
	if (conversationError || !conversation) {
		console.error(`[notification-trigger/N-01] could not read conversation ${args.conversationId}:`, conversationError?.message);
		return;
	}
	// The scenario is defined for compatibility conversations only. Other
	// purposes (fox-search and friends) complete through the same DO and must
	// not push.
	if (conversation.purpose !== "compatibility") return;

	const { data: match, error: matchError } = await ctx.supabase
		.from("matches")
		.select("user_a_id, user_b_id")
		.eq("id", args.matchId)
		.single();
	if (matchError || !match) {
		console.error(`[notification-trigger/N-01] could not read match ${args.matchId}:`, matchError?.message);
		return;
	}

	const deepLink = `wingward://match/${args.matchId}/fox-result`;
	if (isSyntheticMatchingProfile(match.user_a_id) || isSyntheticMatchingProfile(match.user_b_id)) return;
	for (const userId of [match.user_a_id, match.user_b_id]) {
		await dispatch(ctx, "N-01", {
			scenarioId: "N-01",
			userId,
			matchId: args.matchId,
			deepLink,
			deliveryContext: { conversation_id: args.conversationId },
		});
	}
}

/**
 * N-03 — "Chat request received": a `chat_requests` row was created. Only the
 * responder is notified; the requester is the one who just performed the
 * action and is looking at its result.
 */
export async function notifyChatRequestCreated(
	ctx: TriggerContext,
	args: { chatRequestId: string; matchId: string; responderId: string },
): Promise<void> {
	await dispatch(ctx, "N-03", {
		scenarioId: "N-03",
		userId: args.responderId,
		matchId: args.matchId,
		deepLink: `wingward://chat-requests/${args.chatRequestId}`,
		deliveryContext: { request_id: args.chatRequestId },
	});
}

/**
 * N-04/N-07 — mutual meetup intent reached the identity-verification gate.
 *
 * The service-role client bypasses RLS, so this trigger repeats the
 * authorization and safety checks that a user-facing read would otherwise
 * receive from the database: the supplied meetup must still belong to the
 * supplied match, the meetup must be in `verifying`, both participants must
 * be age verified, and neither direction may be blocked. A failed lookup is
 * a fail-closed no-op. The four sends are independent so one failed delivery
 * cannot prevent the other participant from receiving the remaining scenario.
 */
export async function notifyMeetupMutualIntent(
	ctx: TriggerContext,
	args: { meetupId: string; matchId: string },
): Promise<void> {
	let meetupResult: {
		data: { id: string; match_id: string; status: string } | null;
		error: unknown;
	};
	try {
		meetupResult = await ctx.supabase
			.from("meetups")
			.select("id, match_id, status")
			.eq("id", args.meetupId)
			.maybeSingle();
	} catch {
		console.error("[notification-trigger/meetup] meetup lookup failed");
		return;
	}
	if (meetupResult.error || !meetupResult.data) {
		console.error("[notification-trigger/meetup] meetup is unavailable");
		return;
	}
	const meetup = meetupResult.data;
	if (meetup.id !== args.meetupId || meetup.match_id !== args.matchId || meetup.status !== "verifying") return;

	let matchResult: {
		data: { id: string; user_a_id: string; user_b_id: string } | null;
		error: unknown;
	};
	try {
		matchResult = await ctx.supabase
			.from("matches")
			.select("id, user_a_id, user_b_id")
			.eq("id", args.matchId)
			.maybeSingle();
	} catch {
		console.error("[notification-trigger/meetup] match lookup failed");
		return;
	}
	if (matchResult.error || !matchResult.data) {
		console.error("[notification-trigger/meetup] match is unavailable");
		return;
	}
	const match = matchResult.data;
	if (match.id !== args.matchId || !match.user_a_id || !match.user_b_id || match.user_a_id === match.user_b_id) return;

	let ageState: Awaited<ReturnType<typeof checkVerifiedPair>>;
	try {
		ageState = await checkVerifiedPair(ctx.supabase, match.user_a_id, match.user_b_id);
	} catch {
		console.error("[notification-trigger/meetup] age verification lookup failed");
		return;
	}
	if (ageState.ok === false) return;

	let blockResult: {
		data: { id: string } | null;
		error: unknown;
	};
	try {
		blockResult = await ctx.supabase
			.from("blocks")
			.select("id")
			.or(`and(blocker_id.eq.${match.user_a_id},blocked_id.eq.${match.user_b_id}),and(blocker_id.eq.${match.user_b_id},blocked_id.eq.${match.user_a_id})`)
			.limit(1)
			.maybeSingle();
	} catch {
		console.error("[notification-trigger/meetup] block lookup failed");
		return;
	}
	if (blockResult.error || blockResult.data) return;

	for (const userId of [match.user_a_id, match.user_b_id]) {
		await dispatch(ctx, "N-04", {
			scenarioId: "N-04",
			userId,
			matchId: args.matchId,
			meetupId: args.meetupId,
			deepLink: `wingward://meetup/${args.meetupId}`,
		});
		await dispatch(ctx, "N-07", {
			scenarioId: "N-07",
			userId,
			matchId: args.matchId,
			meetupId: args.meetupId,
			deepLink: `wingward://meetup/${args.meetupId}/verify`,
		});
	}
}

const meetupArrangementContextSchema = z
	.object({
		scenarioId: z.enum(["N-05", "N-06", "N-14"]),
		meetupId: z.string().uuid(),
		matchId: z.string().uuid(),
		proposalId: z.string().uuid().optional(),
		recipientIds: z.tuple([z.string().uuid(), z.string().uuid()]),
	})
	.strict();

type ArrangementTriggerContext = {
	scenarioId: "N-05" | "N-06" | "N-14";
	meetupId: string;
	matchId: string;
	proposalId?: string;
	recipientIds: [string, string];
};

function isArrangementContextForScenario(context: ArrangementTriggerContext): boolean {
	if (context.recipientIds[0] === context.recipientIds[1]) return false;
	if (context.scenarioId === "N-05") return context.proposalId !== undefined;
	return context.proposalId === undefined;
}

function hasSameParticipants(first: [string, string], second: [string, string]): boolean {
	return new Set(first).size === 2 && first.every((id) => second.includes(id));
}

/**
 * N-05/N-06/N-14 — arrangement side effects.
 *
 * The service creates these contexts only after an atomic state transition, but
 * this trigger still re-checks the relationship and expected state because a
 * background task can run after a later transition. Only fixed scenario copy,
 * participant IDs, and an allowlisted meetup deep link reach sendNotification;
 * proposal details, dates, areas, rationale, names, and messages never do.
 */
export async function notifyMeetupArrangement(
	ctx: TriggerContext,
	input: MeetupArrangementNotificationContext,
): Promise<void> {
	let context: ArrangementTriggerContext;
	try {
		const parsed = meetupArrangementContextSchema.safeParse(input);
		if (!parsed.success) return;
		const normalized: ArrangementTriggerContext = {
			scenarioId: parsed.data.scenarioId!,
			meetupId: parsed.data.meetupId!,
			matchId: parsed.data.matchId!,
			...(parsed.data.proposalId ? { proposalId: parsed.data.proposalId } : {}),
			recipientIds: [parsed.data.recipientIds![0]!, parsed.data.recipientIds![1]!],
		};
		if (!isArrangementContextForScenario(normalized)) return;
		context = normalized;
	} catch {
		return;
	}

	const expectedStatus =
		context.scenarioId === "N-05" ? "proposed" : context.scenarioId === "N-06" ? "confirmed" : "arrange_failed";

	let meetupResult: {
		data: { id: string; match_id: string; status: string } | null;
		error: unknown;
	};
	try {
		meetupResult = await ctx.supabase
			.from("meetups")
			.select("id, match_id, status")
			.eq("id", context.meetupId)
			.maybeSingle();
	} catch {
		console.error(`[notification-trigger/${context.scenarioId}] meetup lookup failed`);
		return;
	}
	if (
		meetupResult.error ||
		!meetupResult.data ||
		meetupResult.data.id !== context.meetupId ||
		meetupResult.data.match_id !== context.matchId ||
		meetupResult.data.status !== expectedStatus
	) {
		return;
	}

	let matchResult: {
		data: { id: string; user_a_id: string; user_b_id: string } | null;
		error: unknown;
	};
	try {
		matchResult = await ctx.supabase
			.from("matches")
			.select("id, user_a_id, user_b_id")
			.eq("id", context.matchId)
			.maybeSingle();
	} catch {
		console.error(`[notification-trigger/${context.scenarioId}] match lookup failed`);
		return;
	}
	if (matchResult.error || !matchResult.data || matchResult.data.id !== context.matchId) return;

	const participants: [string, string] = [matchResult.data.user_a_id, matchResult.data.user_b_id];
	if (!hasSameParticipants(context.recipientIds, participants)) return;

	let ageState: Awaited<ReturnType<typeof checkVerifiedPair>>;
	try {
		ageState = await checkVerifiedPair(ctx.supabase, participants[0], participants[1]);
	} catch {
		console.error(`[notification-trigger/${context.scenarioId}] age verification lookup failed`);
		return;
	}
	if (ageState.ok === false) return;

	let blockResult: {
		data: { id: string } | null;
		error: unknown;
	};
	try {
		blockResult = await ctx.supabase
			.from("blocks")
			.select("id")
			.or(`and(blocker_id.eq.${participants[0]},blocked_id.eq.${participants[1]}),and(blocker_id.eq.${participants[1]},blocked_id.eq.${participants[0]})`)
			.limit(1)
			.maybeSingle();
	} catch {
		console.error(`[notification-trigger/${context.scenarioId}] block lookup failed`);
		return;
	}
	if (blockResult.error || blockResult.data) return;

	if (context.scenarioId === "N-05") {
		const proposalId = context.proposalId;
		if (!proposalId) return;
		let proposalResult: {
			data: { id: string; meetup_id: string; attempt_number: number } | null;
			error: unknown;
		};
		try {
			proposalResult = await ctx.supabase
				.from("meetup_proposals")
				.select("id, meetup_id, attempt_number")
				.eq("meetup_id", context.meetupId)
				.order("attempt_number", { ascending: false })
				.limit(1)
				.maybeSingle();
		} catch {
			console.error(`[notification-trigger/${context.scenarioId}] proposal lookup failed`);
			return;
		}
		if (
			proposalResult.error ||
			!proposalResult.data ||
			proposalResult.data.id !== proposalId ||
			proposalResult.data.meetup_id !== context.meetupId ||
			!Number.isInteger(proposalResult.data.attempt_number) ||
			proposalResult.data.attempt_number < 1
		) {
			return;
		}
	}

	for (const userId of context.recipientIds) {
		await dispatch(ctx, context.scenarioId, {
			scenarioId: context.scenarioId,
			userId,
			matchId: context.matchId,
			meetupId: context.meetupId,
			deepLink: `wingward://meetup/${context.meetupId}`,
			...(context.scenarioId === "N-05" ? { deliveryContext: { proposal_id: context.proposalId! } } : {}),
		});
	}
}

/** Adapter form for scheduler/route callers that prefer a notifier object. */
export function createMeetupArrangementNotifier(ctx: TriggerContext): MeetupArrangementNotifier {
	return {
		notify: (context) => notifyMeetupArrangement(ctx, context),
	};
}

/** Backwards-compatible descriptive alias for focused callers/tests. */
export const notifyMeetupArrangementContext = notifyMeetupArrangement;

/**
 * N-02 — "Your question was answered" — DELIBERATELY NOT WIRED.
 *
 * The scenario's trigger is "the partner's Fox answered a question you asked
 * it", and its target action is "read the answer". But `POST
 * /api/partner-fox-chats/:id/messages` generates that answer synchronously and
 * returns it in the same HTTP response, so the only person the scenario would
 * notify is the person already reading it. Firing here would be a push to a
 * user looking at the screen it links to.
 *
 * This is not a gap to fill by picking a different recipient — notifying the
 * partner that someone asked their Fox a question is a different scenario with
 * different copy and a different consent story, and inventing it here would
 * put a scenario in production that no spec describes. N-02 becomes real if
 * the answer ever becomes asynchronous (a queued or long-running generation),
 * and should be revisited then.
 */
export const N_02_NOT_WIRED_SEE_DOC_COMMENT = true;
