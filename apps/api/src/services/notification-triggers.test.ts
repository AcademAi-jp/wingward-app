import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const sendNotification = vi.fn();
vi.mock("./notifications", () => ({
	sendNotification: (...args: unknown[]) => sendNotification(...args),
}));

const {
	notifyChatRequestCreated,
	notifyFoxConversationCompleted,
	notifyMeetupArrangement,
	notifyMeetupMutualIntent,
} = await import("./notification-triggers");

const ENV = { ONESIGNAL_APP_ID: "test-app-id", ONESIGNAL_API_KEY: "test-key-not-real" };
const MATCH_ID = "20000000-0000-0000-0000-000000000001";
const MEETUP_ID = "30000000-0000-0000-0000-000000000001";

function matchingProfile(id: string, ageVerifiedAt: string | null = "2026-08-24T00:00:00Z") {
	return {
		id,
		age_verified_at: ageVerifiedAt,
		gender_identity: "woman",
		preferred_genders: ["woman"],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
	};
}

/**
 * A chainable Supabase stand-in returning one queued result per `${table}:select`.
 */
function makeSupabase(responses: Record<string, { data: unknown; error: unknown }>) {
	return {
		from: (table: string) => {
			// biome-ignore lint/suspicious/noExplicitAny: minimal test double
			const chain: any = {};
			for (const method of ["select", "eq", "limit", "order", "or", "in"]) {
				chain[method] = () => chain;
			}
			chain.single = () => Promise.resolve(responses[`${table}:select`] ?? { data: null, error: { message: `no stub for ${table}` } });
			chain.maybeSingle = () => Promise.resolve(responses[`${table}:select`] ?? { data: null, error: { message: `no stub for ${table}` } });
			chain.then = (resolve: (value: unknown) => unknown, reject?: (error: unknown) => unknown) =>
				Promise.resolve(responses[`${table}:select`] ?? { data: null, error: { message: `no stub for ${table}` } }).then(resolve, reject);
			return chain;
		},
	};
}

beforeEach(() => {
	sendNotification.mockReset().mockResolvedValue({ ok: true, notificationId: "n-1", outcome: "sent" });
});

afterEach(() => {
	vi.restoreAllMocks();
});

describe("N-01: a completed compatibility fox conversation notifies both participants", () => {
	it("never sends completion notifications for the isolated synthetic cohort", async () => {
		const supabase = makeSupabase({
			"fox_conversations:select": { data: { purpose: "compatibility" }, error: null },
			"matches:select": { data: { user_a_id: "96b31c0a-b8c4-4536-ada2-f3537dadd146", user_b_id: "9d836fee-7b93-41ce-b577-34a63006aaea" }, error: null },
		});
		await notifyFoxConversationCompleted({ supabase: supabase as never, env: ENV }, { conversationId: "test-conversation", matchId: "test-match" });
		expect(sendNotification).not.toHaveBeenCalled();
	});
	const supabase = () =>
		makeSupabase({
			"fox_conversations:select": { data: { purpose: "compatibility" }, error: null },
			"matches:select": { data: { user_a_id: "user-a", user_b_id: "user-b" }, error: null },
		});

	it("sends N-01 to each participant with the match's fox-result deep link", async () => {
		await notifyFoxConversationCompleted(
			{ supabase: supabase() as never, env: ENV },
			{ conversationId: "conv-1", matchId: "match-1" },
		);

		expect(sendNotification).toHaveBeenCalledTimes(2);
		const recipients = sendNotification.mock.calls.map((call) => call[2].userId);
		expect(recipients.sort()).toEqual(["user-a", "user-b"]);
		for (const call of sendNotification.mock.calls) {
			expect(call[2]).toMatchObject({
				scenarioId: "N-01",
				matchId: "match-1",
				deepLink: "wingward://match/match-1/fox-result",
				deliveryContext: { conversation_id: "conv-1" },
			});
		}
	});

	it("sends nothing for a conversation whose purpose is not compatibility — the scenario's own trigger condition", async () => {
		const notCompatibility = makeSupabase({
			"fox_conversations:select": { data: { purpose: "fox_search" }, error: null },
			"matches:select": { data: { user_a_id: "user-a", user_b_id: "user-b" }, error: null },
		});

		await notifyFoxConversationCompleted(
			{ supabase: notCompatibility as never, env: ENV },
			{ conversationId: "conv-1", matchId: "match-1" },
		);

		expect(sendNotification).not.toHaveBeenCalled();
	});

	it("sends nothing when the conversation row cannot be read, and does not throw", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const broken = makeSupabase({ "fox_conversations:select": { data: null, error: { message: "boom" } } });

		await expect(
			notifyFoxConversationCompleted({ supabase: broken as never, env: ENV }, { conversationId: "conv-1", matchId: "match-1" }),
		).resolves.toBeUndefined();

		expect(sendNotification).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("sends nothing when the match row cannot be read, and does not throw", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const broken = makeSupabase({
			"fox_conversations:select": { data: { purpose: "compatibility" }, error: null },
			"matches:select": { data: null, error: { message: "boom" } },
		});

		await expect(
			notifyFoxConversationCompleted({ supabase: broken as never, env: ENV }, { conversationId: "conv-1", matchId: "match-1" }),
		).resolves.toBeUndefined();

		expect(sendNotification).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("a send that throws does not stop the other participant's send, and does not propagate", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		sendNotification.mockRejectedValueOnce(new Error("network down"));

		await expect(
			notifyFoxConversationCompleted({ supabase: supabase() as never, env: ENV }, { conversationId: "conv-1", matchId: "match-1" }),
		).resolves.toBeUndefined();

		// Both were attempted: the first one's failure must not cost the second
		// participant their notification.
		expect(sendNotification).toHaveBeenCalledTimes(2);
		consoleErrorSpy.mockRestore();
	});

	it("a refused send (duplicate, quiet hours, no subscription) is logged, not thrown", async () => {
		const consoleLogSpy = vi.spyOn(console, "log").mockImplementation(() => {});
		sendNotification.mockResolvedValue({ ok: false, reason: "duplicate" });

		await expect(
			notifyFoxConversationCompleted({ supabase: supabase() as never, env: ENV }, { conversationId: "conv-1", matchId: "match-1" }),
		).resolves.toBeUndefined();

		expect(consoleLogSpy).toHaveBeenCalledWith(expect.stringContaining("duplicate"));
		consoleLogSpy.mockRestore();
	});
});

describe("N-03: a created chat request notifies the responder only", () => {
	it("sends N-03 to the responder with the chat-request deep link", async () => {
		await notifyChatRequestCreated(
			{ supabase: makeSupabase({}) as never, env: ENV },
			{ chatRequestId: "req-1", matchId: "match-1", responderId: "user-b" },
		);

		expect(sendNotification).toHaveBeenCalledTimes(1);
		expect(sendNotification.mock.calls[0][2]).toEqual({
			scenarioId: "N-03",
			userId: "user-b",
			matchId: "match-1",
			deepLink: "wingward://chat-requests/req-1",
			deliveryContext: { request_id: "req-1" },
		});
	});

	it("does not notify the requester — they are looking at the result of their own action", async () => {
		await notifyChatRequestCreated(
			{ supabase: makeSupabase({}) as never, env: ENV },
			{ chatRequestId: "req-1", matchId: "match-1", responderId: "user-b" },
		);

		const recipients = sendNotification.mock.calls.map((call) => call[2].userId);
		expect(recipients).not.toContain("user-a");
	});

	it("does not throw when the send throws", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		sendNotification.mockRejectedValue(new Error("network down"));

		await expect(
			notifyChatRequestCreated(
				{ supabase: makeSupabase({}) as never, env: ENV },
				{ chatRequestId: "req-1", matchId: "match-1", responderId: "user-b" },
			),
		).resolves.toBeUndefined();

		consoleErrorSpy.mockRestore();
	});
});

describe("N-04/N-07: mutual meetup intent notification", () => {
	function supabase(overrides: Record<string, { data: unknown; error: unknown }> = {}) {
		return makeSupabase({
			"meetups:select": { data: { id: MEETUP_ID, match_id: MATCH_ID, status: "verifying" }, error: null },
			"matches:select": { data: { id: MATCH_ID, user_a_id: "user-a", user_b_id: "user-b" }, error: null },
			"user_profiles:select": {
				data: [
					matchingProfile("user-a"),
					matchingProfile("user-b"),
				],
				error: null,
			},
			"blocks:select": { data: null, error: null },
			...overrides,
		});
	}

	it("sends one N-04 and one N-07 to each verified participant", async () => {
		await notifyMeetupMutualIntent(
			{ supabase: supabase() as never, env: ENV },
			{ meetupId: MEETUP_ID, matchId: MATCH_ID },
		);

		expect(sendNotification).toHaveBeenCalledTimes(4);
		expect(sendNotification.mock.calls.map((call) => call[2].scenarioId)).toEqual(["N-04", "N-07", "N-04", "N-07"]);
		for (const call of sendNotification.mock.calls) {
			expect(call[2]).toMatchObject({ matchId: MATCH_ID, meetupId: MEETUP_ID });
			expect(["user-a", "user-b"]).toContain(call[2].userId);
		}
		expect(sendNotification.mock.calls[0][2].deepLink).toBe(`wingward://meetup/${MEETUP_ID}`);
		expect(sendNotification.mock.calls[1][2].deepLink).toBe(`wingward://meetup/${MEETUP_ID}/verify`);
	});

	it("continues all remaining sends when one notification fails", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		sendNotification.mockRejectedValueOnce(new Error("transport failure"));

		await expect(
			notifyMeetupMutualIntent(
				{ supabase: supabase() as never, env: ENV },
				{ meetupId: MEETUP_ID, matchId: MATCH_ID },
			),
		).resolves.toBeUndefined();

		expect(sendNotification).toHaveBeenCalledTimes(4);
		consoleErrorSpy.mockRestore();
	});

	it.each([
		["missing meetup", { "meetups:select": { data: null, error: null } }],
		["wrong status", { "meetups:select": { data: { id: MEETUP_ID, match_id: MATCH_ID, status: "intent_matched" }, error: null } }],
		["wrong match", { "meetups:select": { data: { id: MEETUP_ID, match_id: "20000000-0000-0000-0000-000000000099", status: "verifying" }, error: null } }],
	])("does not send when the meetup safety boundary fails (%s)", async (_name, overrides) => {
		await notifyMeetupMutualIntent(
			{ supabase: supabase(overrides) as never, env: ENV },
			{ meetupId: MEETUP_ID, matchId: MATCH_ID },
		);
		expect(sendNotification).not.toHaveBeenCalled();
	});

	it("does not send an age-unverified or blocked pair", async () => {
		await notifyMeetupMutualIntent(
			{
				supabase: supabase({
					"user_profiles:select": {
						data: [
							matchingProfile("user-a"),
							matchingProfile("user-b", null),
						],
						error: null,
					},
				}) as never,
				env: ENV,
			},
			{ meetupId: MEETUP_ID, matchId: MATCH_ID },
		);
		expect(sendNotification).not.toHaveBeenCalled();

		await notifyMeetupMutualIntent(
			{ supabase: supabase({ "blocks:select": { data: { id: "block-1" }, error: null } }) as never, env: ENV },
			{ meetupId: MEETUP_ID, matchId: MATCH_ID },
		);
		expect(sendNotification).not.toHaveBeenCalled();
	});
});

describe("N-05/N-06/N-14: meetup arrangement notifications", () => {
	const ARRANGE_MEETUP_ID = "30000000-0000-0000-0000-000000000002";
	const ARRANGE_MATCH_ID = "20000000-0000-0000-0000-000000000002";
	const ARRANGE_USER_A = "10000000-0000-0000-0000-000000000011";
	const ARRANGE_USER_B = "10000000-0000-0000-0000-000000000012";

	function supabase(status: string, overrides: Record<string, { data: unknown; error: unknown }> = {}) {
		return makeSupabase({
			"meetups:select": { data: { id: ARRANGE_MEETUP_ID, match_id: ARRANGE_MATCH_ID, status }, error: null },
			"matches:select": {
				data: { id: ARRANGE_MATCH_ID, user_a_id: ARRANGE_USER_A, user_b_id: ARRANGE_USER_B },
				error: null,
			},
			"user_profiles:select": {
				data: [
					matchingProfile(ARRANGE_USER_A, "2026-09-01T00:00:00Z"),
					matchingProfile(ARRANGE_USER_B, "2026-09-01T00:00:00Z"),
				],
				error: null,
			},
			"blocks:select": { data: null, error: null },
			"meetup_proposals:select": { data: { id: "50000000-0000-0000-0000-000000000001", meetup_id: ARRANGE_MEETUP_ID, attempt_number: 1 }, error: null },
			...overrides,
		});
	}

	it.each([
		["N-05", "proposed", { scenarioId: "N-05", proposalId: "50000000-0000-0000-0000-000000000001" }],
		["N-06", "confirmed", { scenarioId: "N-06" }],
		["N-14", "arrange_failed", { scenarioId: "N-14" }],
	] as const)("sends %s only to the two match participants with a neutral meetup link", async (_label, status, context) => {
		await notifyMeetupArrangement(
			{ supabase: supabase(status) as never, env: ENV },
			{
				...context,
				meetupId: ARRANGE_MEETUP_ID,
				matchId: ARRANGE_MATCH_ID,
				recipientIds: [ARRANGE_USER_A, ARRANGE_USER_B],
			},
		);

		expect(sendNotification).toHaveBeenCalledTimes(2);
		expect(sendNotification.mock.calls.map((call) => call[2].scenarioId)).toEqual([context.scenarioId, context.scenarioId]);
		for (const call of sendNotification.mock.calls) {
			expect(call[2]).toMatchObject({
				scenarioId: context.scenarioId,
				matchId: ARRANGE_MATCH_ID,
				meetupId: ARRANGE_MEETUP_ID,
				deepLink: `wingward://meetup/${ARRANGE_MEETUP_ID}`,
			});
			if (context.scenarioId === "N-05") {
				expect(call[2]).toMatchObject({ deliveryContext: { proposal_id: "50000000-0000-0000-0000-000000000001" } });
			} else {
				expect(call[2]).not.toHaveProperty("deliveryContext");
			}
			expect(call[2]).not.toHaveProperty("proposalId");
		}
	});

	it("does not reuse N-05 for a failed arrangement or expose stale states", async () => {
		await notifyMeetupArrangement(
			{ supabase: supabase("arrange_failed") as never, env: ENV },
			{
				scenarioId: "N-05",
				meetupId: ARRANGE_MEETUP_ID,
				matchId: ARRANGE_MATCH_ID,
				proposalId: "50000000-0000-0000-0000-000000000001",
				recipientIds: [ARRANGE_USER_A, ARRANGE_USER_B],
			},
		);
		await notifyMeetupArrangement(
			{ supabase: supabase("proposed") as never, env: ENV },
			{
				scenarioId: "N-14",
				meetupId: ARRANGE_MEETUP_ID,
				matchId: ARRANGE_MATCH_ID,
				recipientIds: [ARRANGE_USER_A, ARRANGE_USER_B],
			},
		);

		expect(sendNotification).not.toHaveBeenCalled();
	});

	it("rejects a forged recipient list before it reaches the notification pipeline", async () => {
		await notifyMeetupArrangement(
			{ supabase: supabase("confirmed") as never, env: ENV },
			{
				scenarioId: "N-06",
				meetupId: ARRANGE_MEETUP_ID,
				matchId: ARRANGE_MATCH_ID,
				recipientIds: [ARRANGE_USER_A, "10000000-0000-0000-0000-000000000099"],
			},
		);

		expect(sendNotification).not.toHaveBeenCalled();
	});

	it("fails closed when age verification is revoked or the pair is blocked", async () => {
		await notifyMeetupArrangement(
			{
				supabase: supabase("confirmed", {
					"user_profiles:select": {
						data: [
							matchingProfile(ARRANGE_USER_A, "2026-09-01T00:00:00Z"),
							matchingProfile(ARRANGE_USER_B, null),
						],
						error: null,
					},
				}) as never,
				env: ENV,
			},
			{
				scenarioId: "N-06",
				meetupId: ARRANGE_MEETUP_ID,
				matchId: ARRANGE_MATCH_ID,
				recipientIds: [ARRANGE_USER_A, ARRANGE_USER_B],
			},
		);
		expect(sendNotification).not.toHaveBeenCalled();

		await notifyMeetupArrangement(
			{
				supabase: supabase("confirmed", { "blocks:select": { data: { id: "block-1" }, error: null } }) as never,
				env: ENV,
			},
			{
				scenarioId: "N-06",
				meetupId: ARRANGE_MEETUP_ID,
				matchId: ARRANGE_MATCH_ID,
				recipientIds: [ARRANGE_USER_A, ARRANGE_USER_B],
			},
		);
		expect(sendNotification).not.toHaveBeenCalled();
	});

	it("rejects an N-05 context whose proposal is no longer current", async () => {
		await notifyMeetupArrangement(
			{
				supabase: supabase("proposed", {
					"meetup_proposals:select": {
						data: { id: "50000000-0000-0000-0000-000000000099", meetup_id: ARRANGE_MEETUP_ID, attempt_number: 1 },
						error: null,
					},
				}) as never,
				env: ENV,
			},
			{
				scenarioId: "N-05",
				meetupId: ARRANGE_MEETUP_ID,
				matchId: ARRANGE_MATCH_ID,
				proposalId: "50000000-0000-0000-0000-000000000001",
				recipientIds: [ARRANGE_USER_A, ARRANGE_USER_B],
			},
		);

		expect(sendNotification).not.toHaveBeenCalled();
	});
});
