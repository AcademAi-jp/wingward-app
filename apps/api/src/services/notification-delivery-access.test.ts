import { describe, expect, it, vi } from "vitest";
import {
	checkNotificationDeliveryAccess,
	parseNotificationDeliveryContext,
} from "./notification-delivery-access";
import type { NotificationDeliveryExpectation } from "./notification-delivery-access";

const USER_A = "10000000-0000-0000-0000-000000000001";
const USER_B = "10000000-0000-0000-0000-000000000002";
const MATCH_ID = "20000000-0000-0000-0000-000000000001";
const MEETUP_ID = "30000000-0000-0000-0000-000000000001";
const REQUEST_ID = "40000000-0000-0000-0000-000000000001";
const PROPOSAL_ID = "50000000-0000-0000-0000-000000000001";
const NOTIFICATION_ID = "60000000-0000-0000-0000-000000000001";
const BEFORE = new Date("2026-09-06T00:00:00.000Z");
const MID = new Date("2026-09-06T00:30:00.000Z");
const AFTER = new Date("2026-09-06T01:00:00.000Z");

type QueryResult = { data: unknown; error: unknown };

type QueryTrace = {
	table: string;
	select?: string;
	filters: Array<[string, unknown]>;
	ordered: boolean;
};

/** A deliberately controlled async Supabase stand-in; it never calls a network. */
function makeSupabase(result: QueryResult, onFinalRead?: () => Promise<void> | void) {
	const traces: QueryTrace[] = [];
	const from = (table: string) => {
		const trace: QueryTrace = { table, filters: [], ordered: false };
		traces.push(trace);
		const query: Record<string, unknown> = {};
		query.select = (columns: string) => {
			trace.select = columns;
			return query;
		};
		query.eq = (column: string, value: unknown) => {
			trace.filters.push([column, value]);
			return query;
		};
		query.is = (column: string, value: unknown) => {
			trace.filters.push([`${column}:is`, value]);
			return query;
		};
		query.order = () => {
			trace.ordered = true;
			return query;
		};
		query.single = async () => {
			await onFinalRead?.();
			return result;
		};
		return query;
	};
	return { from, traces };
}

function matchingProfile(id: string, gender: "woman" | "man", preferredGender: "woman" | "man") {
	return {
		id,
		age_verified_at: "2026-09-05T00:00:00.000Z",
		gender_identity: gender,
		preferred_genders: [preferredGender],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-09-05T00:00:00.000Z",
		blocks_sent: [],
	};
}

function makeExpectation(scenarioId: "N-03" | "N-05", now = BEFORE): NotificationDeliveryExpectation {
	if (scenarioId === "N-03") {
		return {
			notificationId: NOTIFICATION_ID,
			scenarioId,
			userId: USER_B,
			matchId: MATCH_ID,
			meetupId: null,
			deepLink: `wingward://chat-requests/${REQUEST_ID}`,
			deliveryContext: { request_id: REQUEST_ID },
			participantIds: [USER_A, USER_B],
			now,
		};
	}
	return {
		notificationId: NOTIFICATION_ID,
		scenarioId,
		userId: USER_A,
		matchId: MATCH_ID,
		meetupId: MEETUP_ID,
		deepLink: `wingward://meetup/${MEETUP_ID}`,
		deliveryContext: { proposal_id: PROPOSAL_ID },
		participantIds: [USER_A, USER_B],
		now,
	};
}

function makeFinalRow(scenarioId: "N-03" | "N-05", expiresAt = AFTER.toISOString()) {
	const isRequest = scenarioId === "N-03";
	const expectation = makeExpectation(scenarioId);
	const match = {
		id: MATCH_ID,
		user_a_id: USER_A,
		user_b_id: USER_B,
		status: isRequest ? "direct_chat_requested" : "direct_chat_active",
		profile_a: matchingProfile(USER_A, "woman", "man"),
		profile_b: matchingProfile(USER_B, "man", "woman"),
		compatibility_conversations: [],
		chat_requests: isRequest
			? [{ id: REQUEST_ID, match_id: MATCH_ID, requester_id: USER_A, responder_id: USER_B, status: "pending", expires_at: expiresAt }]
			: [],
		direct_room: isRequest ? null : { id: "70000000-0000-0000-0000-000000000001", match_id: MATCH_ID, status: "active" },
	};
	return {
		id: NOTIFICATION_ID,
		scenario_id: scenarioId,
		user_id: expectation.userId,
		match_id: expectation.matchId,
		meetup_id: expectation.meetupId,
		payload: { deep_link: expectation.deepLink, delivery_context: expectation.deliveryContext },
		scheduled_for: null,
		sent_at: null,
		suppressed_reason: null,
		onesignal_notification_id: null,
		scenario: { scenario_id: scenarioId, is_enabled: true },
		match,
		meetup: isRequest
			? null
			: {
				id: MEETUP_ID,
				match_id: MATCH_ID,
				initiator_id: USER_A,
				status: "proposed",
				proposal_expires_at: expiresAt,
				proposals: [{ id: PROPOSAL_ID, meetup_id: MEETUP_ID, attempt_number: 1, expires_at: expiresAt }],
			},
	};
}

describe("checkNotificationDeliveryAccess final snapshot", () => {
	it.each(["N-03", "N-05"] as const)("allows %s while the final snapshot is still before expiry", async (scenarioId) => {
		const row = makeFinalRow(scenarioId, AFTER.toISOString());
		const supabase = makeSupabase({ data: row, error: null });

		await expect(checkNotificationDeliveryAccess(supabase as never, makeExpectation(scenarioId))).resolves.toEqual({ ok: true });
		expect(supabase.traces).toHaveLength(1);
		expect(supabase.traces[0].table).toBe("notifications");
		expect(supabase.traces[0].filters).toContainEqual(["user_id", scenarioId === "N-03" ? USER_B : USER_A]);
	});

	it.each(["N-03", "N-05"] as const)("denies %s when the clock advances past expiry during the awaited final read", async (scenarioId) => {
		let clockNow = BEFORE;
		const finalRead = vi.fn(async () => {
			// This await is the race: a helper that samples only expectation.now
			// would incorrectly return ok:true below.
			await Promise.resolve();
			clockNow = AFTER;
		});
		const supabase = makeSupabase({ data: makeFinalRow(scenarioId, MID.toISOString()), error: null }, finalRead);
		const expectation = { ...makeExpectation(scenarioId), clock: () => clockNow };

		await expect(checkNotificationDeliveryAccess(supabase as never, expectation)).resolves.toEqual({ ok: false, reason: "forbidden" });
		expect(finalRead).toHaveBeenCalledOnce();
		expect(clockNow).toBe(AFTER);
	});

	it("denies a disabled scenario, mismatched parent context, or recipient mismatch", async () => {
		const disabled = makeFinalRow("N-03");
		disabled.scenario = { scenario_id: "N-03", is_enabled: false };
		await expect(checkNotificationDeliveryAccess(makeSupabase({ data: disabled, error: null }) as never, makeExpectation("N-03"))).resolves.toEqual({ ok: false, reason: "forbidden" });

		const mismatchedContext = makeFinalRow("N-03");
		mismatchedContext.payload = {
			deep_link: `wingward://chat-requests/${REQUEST_ID}`,
			delivery_context: { request_id: "40000000-0000-0000-0000-000000000099" },
		};
		await expect(checkNotificationDeliveryAccess(makeSupabase({ data: mismatchedContext, error: null }) as never, makeExpectation("N-03"))).resolves.toEqual({ ok: false, reason: "forbidden" });

		const recipientMismatch = makeFinalRow("N-03");
		recipientMismatch.user_id = USER_A;
		await expect(checkNotificationDeliveryAccess(makeSupabase({ data: recipientMismatch, error: null }) as never, makeExpectation("N-03"))).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it("denies null match linkage before reading a final row", async () => {
		const supabase = makeSupabase({ data: makeFinalRow("N-03"), error: null });
		const expectation = { ...makeExpectation("N-03"), matchId: null };

		await expect(checkNotificationDeliveryAccess(supabase as never, expectation)).resolves.toEqual({ ok: false, reason: "forbidden" });
		expect(supabase.traces).toHaveLength(0);
	});

	it("fails closed for malformed block relationship arrays", async () => {
		const row = makeFinalRow("N-03");
		(row.match.profile_a as Record<string, unknown>).blocks_sent = [[{ id: "80000000-0000-0000-0000-000000000001", blocker_id: USER_A, blocked_id: USER_B }]];

		await expect(checkNotificationDeliveryAccess(makeSupabase({ data: row, error: null }) as never, makeExpectation("N-03"))).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it("keeps the parent context parser closed to arrays and extra keys", () => {
		expect(parseNotificationDeliveryContext([{ request_id: REQUEST_ID }])).toBeNull();
		expect(parseNotificationDeliveryContext({ request_id: REQUEST_ID, extra: "unexpected" })).toBeNull();
	});
});
