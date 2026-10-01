import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
	DEFAULT_DEFERRED_SEND_LIMIT,
	MAX_DEFERRED_SEND_ATTEMPTS,
	refreshNotificationTags,
	sendDeferredNotifications,
	sendNotification,
} from "./notifications";
import { parseNotificationDeliveryContext } from "./notification-delivery-access";

/**
 * Coverage for the send pipeline's three pre-send checks (quiet hours, 24h
 * dedup, lost-permission) and the deferred-send executor
 * (step-04-notifications.md §6, A-1/A-2/A-3/A-5/A-6). The OneSignal HTTP
 * layer is mocked throughout — no real send, no real key.
 */

type StubResult = { data: unknown; error: unknown };
interface CallRecord {
	method: string;
	args: unknown[];
}

type StubOptions = {
	/** Override the embedded final snapshot for a dynamic-state test. */
	finalSnapshot?: (filters: Array<[string, unknown]>) => StubResult;
};

/**
 * A minimal chainable Supabase-query stand-in, keyed by `${table}:${op}`
 * where `op` is "select" (default) / "insert" / "update" — whichever of
 * `.insert()` / `.update()` is called first on a chain, if any. Responses
 * are consumed FIFO per key, so a test queues one entry per call it expects
 * against that table+operation, in call order. Also records every method
 * call (with args) per table so a test can assert on the exact filter a
 * code path applied (e.g. `.is("match_id", null)` vs `.eq("match_id", x)`).
 */
function makeSupabaseStub(responses: Partial<Record<string, StubResult[]>>, options: StubOptions = {}) {
	const counters = new Map<string, number>();
	const calls: CallRecord[] = [];

	function nextResult(key: string, fallback?: StubResult): StubResult {
		const idx = counters.get(key) ?? 0;
		counters.set(key, idx + 1);
		const arr = responses[key];
		if (!arr || idx >= arr.length) {
			if (fallback) return fallback;
			// Match-age rechecks are deliberately additional reads beyond the
			// notification/block assertions below. Keep the old fixtures focused on
			// their scenario while defaulting only these read-only lookups to a
			// verified pair; dedicated age-gate tests override them explicitly.
			if (key === "matches:select") {
				return { data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null };
			}
			if (key === "user_profiles:select" && idx > 0) {
				return {
					data: [matchingProfile("user-1"), matchingProfile("user-2")],
					error: null,
				};
			}
			return { data: null, error: { message: `no stub queued for ${key}[${idx}]` } };
		}
		const result = arr[idx];
		// Conditional UPDATEs in production use `.select("id")` and therefore
		// return the affected row.  Older fixtures used `data: null` for a
		// successful write because the code did not inspect the count.  Normalize
		// that shorthand here so the fixtures continue to model a successful
		// fenced update after the INSERT discoverability change.
		if (key === "notifications:update" && result.error === null && result.data === null) {
			return { ...result, data: [{ id: "stub-update" }] };
		}
		return result;
	}

	function makeChain(table: string) {
		let op: "select" | "insert" | "update" = "select";
		let selectedColumns: unknown;
		const eqFilters: Array<[string, unknown]> = [];
		const record = (method: string, args: unknown[]) => calls.push({ method: `${table}.${method}`, args });
		// biome-ignore lint/suspicious/noExplicitAny: minimal test double, not worth typing precisely
		const chain: any = {};
		for (const method of ["is", "gte", "lte", "not", "order", "limit", "or", "in"]) {
			chain[method] = (...args: unknown[]) => {
				record(method, args);
				return chain;
			};
		}
		chain.select = (...args: unknown[]) => {
			selectedColumns = args[0];
			record("select", args);
			return chain;
		};
		chain.eq = (...args: unknown[]) => {
			eqFilters.push([args[0] as string, args[1]]);
			record("eq", args);
			return chain;
		};
		chain.insert = (...args: unknown[]) => {
			op = "insert";
			record("insert", args);
			return chain;
		};
		chain.update = (...args: unknown[]) => {
			op = "update";
			record("update", args);
			return chain;
		};
		const fallback = () =>
			table === "notifications" &&
			typeof selectedColumns === "string" &&
			selectedColumns.includes("scenario:notification_scenarios")
				? options.finalSnapshot?.(eqFilters) ?? { data: makeFinalSnapshot(eqFilters), error: null }
				: undefined;
		chain.single = () => Promise.resolve(nextResult(`${table}:${op}`, fallback()));
		chain.maybeSingle = () => Promise.resolve(nextResult(`${table}:${op}`, fallback()));
		chain.then = (resolve: (v: unknown) => unknown, reject?: (e: unknown) => unknown) =>
			Promise.resolve(nextResult(`${table}:${op}`, fallback())).then(resolve, reject);
		return chain;
	}

	return { from: (table: string) => makeChain(table), calls };
}

function makeFinalSnapshot(filters: Array<[string, unknown]>): Record<string, unknown> {
	const value = (key: string): unknown => filters.find(([column]) => column === key)?.[1];
	const scenarioId = String(value("scenario_id") ?? "N-13");
	const userId = String(value("user_id") ?? "user-1");
	const matchFilter = value("match_id");
	const meetupFilter = value("meetup_id");
	const matchId = typeof matchFilter === "string" ? matchFilter : null;
	const meetupId = typeof meetupFilter === "string" ? meetupFilter : null;
	const deepLink = String(value("payload->>deep_link") ?? "wingward://availability");
	const scheduledFor = value("scheduled_for") ?? null;
	const contextFilter = filters.find(([column]) => column.startsWith("payload->delivery_context->>"));
	const contextKey = contextFilter?.[0].split(">>").at(-1);
	const contextValue = contextFilter?.[1];
	const deliveryContext = contextKey && typeof contextValue === "string" ? { [contextKey]: contextValue } : undefined;
	const base: Record<string, unknown> = {
		id: String(value("id") ?? "notif-final"),
		scenario_id: scenarioId,
		user_id: userId,
		match_id: matchId,
		meetup_id: meetupId,
		payload: { deep_link: deepLink, ...(deliveryContext ? { delivery_context: deliveryContext } : {}) },
		scheduled_for: scheduledFor,
		sent_at: null,
		suppressed_reason: null,
		onesignal_notification_id: null,
		scenario: { scenario_id: scenarioId, is_enabled: true },
	};
	if (!matchId) return base;
	const userAId = "user-1";
	const userBId = "user-2";
	const profileA = { ...matchingProfile(userAId), blocks_sent: [] };
	const profileB = { ...matchingProfile(userBId), blocks_sent: [] };
	const match: Record<string, unknown> = {
		id: matchId,
		user_a_id: userAId,
		user_b_id: userBId,
		status: scenarioId === "N-03" ? "direct_chat_requested" : scenarioId === "N-01" ? "fox_conversation_completed" : "direct_chat_active",
		profile_a: profileA,
		profile_b: profileB,
		compatibility_conversations: scenarioId === "N-01" ? [{ id: (deliveryContext as { conversation_id?: string } | undefined)?.conversation_id ?? "conversation-1", match_id: matchId, purpose: "compatibility", status: "completed" }] : [],
		chat_requests:
			scenarioId === "N-03"
				? [{ id: (deliveryContext as { request_id?: string } | undefined)?.request_id ?? "request-1", match_id: matchId, requester_id: userBId, responder_id: userId, status: "pending", expires_at: "2099-01-01T00:00:00.000Z" }]
				: [],
		direct_room: scenarioId === "N-01" ? [] : [{ id: "room-1", match_id: matchId, status: "active" }],
	};
	base.match = match;
	if (meetupId) {
		base.meetup = {
			id: meetupId,
			match_id: matchId,
			initiator_id: userAId,
			status: scenarioId === "N-05" ? "proposed" : scenarioId === "N-06" ? "confirmed" : scenarioId === "N-04" || scenarioId === "N-07" ? "verifying" : "arrange_failed",
			proposal_expires_at: null,
			proposals:
				scenarioId === "N-05"
					? [{ id: (deliveryContext as { proposal_id?: string } | undefined)?.proposal_id ?? "proposal-1", meetup_id: meetupId, attempt_number: 1, expires_at: "2099-01-01T00:00:00.000Z" }]
					: [],
		};
	}
	return base;
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
	fetchMock = vi.fn().mockImplementation(async (url: string) => {
		if (url.includes("/notifications")) {
			return new Response(JSON.stringify({ id: "onesignal-send-id", recipients: 1 }), { status: 200 });
		}
		// tag PATCH calls, best-effort — always succeed unless a test overrides
		return new Response("{}", { status: 200 });
	});
	vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

const ENV = { ONESIGNAL_APP_ID: "test-app-id", ONESIGNAL_API_KEY: "test-key-not-real" };

function matchingProfile(id: string, ageVerifiedAt: string | null = "2026-08-24T00:00:00Z") {
	return {
		id,
		age_verified_at: ageVerifiedAt,
		gender_identity: "woman",
		preferred_genders: ["woman"],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-08-23T00:00:00Z",
	};
}

const FINAL_BINDING_CASES = [
	{
		scenarioId: "N-01",
		matchId: "20000000-0000-0000-0000-000000000001",
		deepLink: "wingward://match/20000000-0000-0000-0000-000000000001/fox-result",
		deliveryContext: { conversation_id: "40000000-0000-0000-0000-000000000001" },
	},
	{
		scenarioId: "N-03",
		matchId: "20000000-0000-0000-0000-000000000002",
		deepLink: "wingward://chat-requests/50000000-0000-0000-0000-000000000001",
		deliveryContext: { request_id: "50000000-0000-0000-0000-000000000001" },
	},
	{
		scenarioId: "N-04",
		matchId: "20000000-0000-0000-0000-000000000003",
		meetupId: "30000000-0000-0000-0000-000000000003",
		deepLink: "wingward://meetup/30000000-0000-0000-0000-000000000003",
	},
	{
		scenarioId: "N-05",
		matchId: "20000000-0000-0000-0000-000000000004",
		meetupId: "30000000-0000-0000-0000-000000000004",
		deepLink: "wingward://meetup/30000000-0000-0000-0000-000000000004",
		deliveryContext: { proposal_id: "60000000-0000-0000-0000-000000000001" },
	},
	{
		scenarioId: "N-06",
		matchId: "20000000-0000-0000-0000-000000000005",
		meetupId: "30000000-0000-0000-0000-000000000005",
		deepLink: "wingward://meetup/30000000-0000-0000-0000-000000000005",
	},
	{
		scenarioId: "N-07",
		matchId: "20000000-0000-0000-0000-000000000006",
		meetupId: "30000000-0000-0000-0000-000000000006",
		deepLink: "wingward://meetup/30000000-0000-0000-0000-000000000006",
	},
	{
		scenarioId: "N-14",
		matchId: "20000000-0000-0000-0000-000000000007",
		meetupId: "30000000-0000-0000-0000-000000000007",
		deepLink: "wingward://meetup/30000000-0000-0000-0000-000000000007",
	},
	{
		scenarioId: "N-13",
		deepLink: "wingward://availability",
	},
] as const;

describe("final delivery binding positive fixtures", () => {
	it.each(FINAL_BINDING_CASES)("sends a healthy $scenarioId snapshot", async (testCase) => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [
				{ data: { timezone: "UTC" }, error: null },
				{ data: [matchingProfile("user-1"), matchingProfile("user-2")], error: null },
			],
			"notifications:select": [{ data: [], error: null }],
			"matches:select": [{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null }],
			"blocks:select": [{ data: null, error: null }],
			"notifications:insert": [{ data: { id: `positive-${testCase.scenarioId}` }, error: null }],
			"notifications:update": [
				{ data: null, error: null },
				{ data: null, error: null },
			],
			"notification_events:insert": [{ data: null, error: null }],
		});
		const params = {
			scenarioId: testCase.scenarioId,
			userId: "user-1",
			...("matchId" in testCase ? { matchId: testCase.matchId } : {}),
			...("meetupId" in testCase ? { meetupId: testCase.meetupId } : {}),
			deepLink: testCase.deepLink,
			...("deliveryContext" in testCase ? { deliveryContext: testCase.deliveryContext } : {}),
		};

		const result = await sendNotification(supabase as never, ENV, params);

		expect(result).toEqual({ ok: true, notificationId: `positive-${testCase.scenarioId}`, outcome: "sent" });
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});
});

describe("sendNotification — quiet hours (A-1)", () => {
	it("Asia/Tokyo 23:00 local: not sent immediately, scheduled_for becomes next 08:00 JST", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: false, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "Asia/Tokyo" }, error: null }],
			"notifications:select": [{ data: [], error: null }], // dedup: no prior send
			"notifications:insert": [{ data: { id: "notif-tokyo-1" }, error: null }],
		});

		const now = new Date("2026-06-15T14:00:00.000Z"); // 23:00 JST
		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now,
		});

		expect(result).toEqual({
			ok: true,
			notificationId: "notif-tokyo-1",
			outcome: "deferred",
			scheduledFor: "2026-06-15T23:00:00.000Z", // 2026-06-16 08:00 JST
		});
		expect(fetchMock).not.toHaveBeenCalled(); // no OneSignal call for a held notification
	});

	it("America/Los_Angeles 23:00 local: not sent immediately, scheduled_for becomes next 08:00 PDT", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: false, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "America/Los_Angeles" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-la-1" }, error: null }],
		});

		const now = new Date("2026-06-16T06:00:00.000Z"); // 2026-06-15 23:00 PDT
		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now,
		});

		expect(result).toEqual({
			ok: true,
			notificationId: "notif-la-1",
			outcome: "deferred",
			scheduledFor: "2026-06-16T15:00:00.000Z", // 2026-06-16 08:00 PDT
		});
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("a quiet_hours_exempt scenario (N-08 shape) sends immediately even at 23:00 local", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "Asia/Tokyo" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-exempt-1" }, error: null }],
			// Two separate UPDATE calls (finding #1 review round 2): one for
			// onesignal_notification_id, one for sent_at.
			"notifications:update": [
				{ data: null, error: null },
				{ data: null, error: null },
			],
			// Existence check before inserting the sent event (finding #3
			// review round 3) — no prior event, so it proceeds to insert.
			"notification_events:select": [{ data: [], error: null }],
			"notification_events:insert": [{ data: null, error: null }],
		});

		const now = new Date("2026-06-15T14:00:00.000Z"); // 23:00 JST
		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now,
		});

		expect(result).toEqual({ ok: true, notificationId: "notif-exempt-1", outcome: "sent" });
		// Exactly one fetch: the OneSignal send itself. Tag refresh is no
		// longer part of the send path (P1-a) — see refreshNotificationTags
		// below, which is its own function and is not called from here.
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});
});

describe("sendNotification — invalid stored timezone (finding #4, review round 2)", () => {
	it("returns a clean typed failure instead of throwing when user_profiles.timezone is not a valid IANA name", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: false, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "not/a/real/zone" }, error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-01",
			userId: "user-1",
			deepLink: "wingward://availability",
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toEqual({ ok: false, reason: "invalid_timezone" });
		expect(fetchMock).not.toHaveBeenCalled();
		// Never reaches the dedup query or an insert — fails before either.
		expect(supabase.calls.find((c) => c.method === "notifications.insert")).toBeUndefined();
	});

	it("does the same for a quiet_hours_exempt scenario (the invalid-timezone check runs before the exemption is consulted)", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "<script>" }, error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
		});

		expect(result).toEqual({ ok: false, reason: "invalid_timezone" });
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

describe("sendNotification — 24h dedup (A-3)", () => {
	it("suppresses a second send for the same scenario+user+match within 24h", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			// dedup pre-check finds an existing row within the window.
			"notifications:select": [{ data: [{ id: "existing-notif" }], error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-03",
			userId: "user-1",
			matchId: "match-1",
			deepLink: "wingward://chat-requests/11111111-1111-4111-8111-111111111111",
			deliveryContext: { request_id: "request-1" },
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toEqual({ ok: false, reason: "duplicate" });
		expect(fetchMock).not.toHaveBeenCalled();
		// Confirms the non-NULL match_id branch filtered on match_id.
		const dedupEqMatchId = supabase.calls.find(
			(c) => c.method === "notifications.eq" && c.args[0] === "match_id" && c.args[1] === "match-1",
		);
		expect(dedupEqMatchId).toBeDefined();
	});

	it("suppresses a second send for the same scenario+user when match_id is NULL — the case the UNIQUE constraint cannot cover", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [{ id: "existing-notif-null-match" }], error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13", // a scenario with no match_id (availability expiry)
			userId: "user-1",
			deepLink: "wingward://availability",
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toEqual({ ok: false, reason: "duplicate" });
		expect(fetchMock).not.toHaveBeenCalled();
		// Confirms the dedup query used `.is("match_id", null)`, not `.eq`, when
		// no match_id is given — this is the branch that closes the gap the
		// UNIQUE(scenario_id, user_id, match_id, dedup_window_start) constraint
		// leaves open for NULL match_id (Postgres NULL never equals NULL).
		const dedupIsMatchIdNull = supabase.calls.find(
			(c) => c.method === "notifications.is" && c.args[0] === "match_id" && c.args[1] === null,
		);
		expect(dedupIsMatchIdNull).toBeDefined();
		const wrongEqCall = supabase.calls.find((c) => c.method === "notifications.eq" && c.args[0] === "match_id");
		expect(wrongEqCall).toBeUndefined();
	});

	it("allows a send when no prior notification exists in the dedup window", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-fresh" }, error: null }],
			"notifications:update": [
				{ data: null, error: null },
				{ data: null, error: null },
			],
			"notification_events:select": [{ data: [], error: null }],
			"notification_events:insert": [{ data: null, error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toEqual({ ok: true, notificationId: "notif-fresh", outcome: "sent" });
	});
});

describe("sendNotification — deep link allow-list (A-5)", () => {
	it("rejects a deep link outside the allow-list before creating any notifications row", async () => {
		const supabase = makeSupabaseStub({});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-01",
			userId: "user-1",
			deepLink: "https://evil.example.com/phish",
		});

		expect(result).toEqual({ ok: false, reason: "invalid_deep_link" });
		expect(fetchMock).not.toHaveBeenCalled();
		expect(supabase.calls.find((c) => c.method === "notifications.insert")).toBeUndefined();
	});
});

describe("sendNotification — lost permission is not a send failure", () => {
	it("records suppressed_reason='no_subscription' when OneSignal reports zero recipients, without treating it as a failure", async () => {
		fetchMock.mockImplementation(async (url: string) => {
			if (url.includes("/notifications")) {
				return new Response(JSON.stringify({ id: "onesignal-id-zero", recipients: 0 }), { status: 200 });
			}
			return new Response("{}", { status: 200 });
		});

		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-no-sub" }, error: null }],
			"notifications:update": [{ data: null, error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
		});

		expect(result).toEqual({ ok: true, notificationId: "notif-no-sub", outcome: "suppressed_no_subscription" });
		const updateCall = supabase.calls.find((c) => c.method === "notifications.update");
		expect(updateCall?.args[0]).toMatchObject({ suppressed_reason: "no_subscription" });
	});
});

describe("sendNotification — A-6: OneSignal error body never reaches the caller", () => {
	it("returns a generic send_failed reason, not the OneSignal error body", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		fetchMock.mockImplementation(async (url: string) => {
			if (url.includes("/notifications")) {
				return new Response(JSON.stringify({ errors: ["PWNED-CANARY-SEND: internal detail"] }), { status: 400 });
			}
			return new Response("{}", { status: 200 });
		});

		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-err-1" }, error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
		});

		expect(result).toEqual({ ok: false, notificationId: "notif-err-1", reason: "send_failed" });
		expect(JSON.stringify(result)).not.toContain("PWNED-CANARY-SEND");
		consoleErrorSpy.mockRestore();
	});
});

describe("sendDeferredNotifications (A-2)", () => {
	it("sends only rows whose scheduled_for has passed, setting sent_at and a sent event; not-due rows aren't touched", async () => {
		const supabase = makeSupabaseStub({
			// Query returns only the due row — the query itself filters by
			// scheduled_for <= now, so a not-yet-due row never appears here.
			"notifications:select": [
				{
					data: [
						{
							id: "due-notif-1",
							scenario_id: "N-13",
							user_id: "user-1",
							payload: { deep_link: "wingward://availability" },
							onesignal_notification_id: null,
							scheduled_for: "2020-01-01T00:00:00.000Z",
						},
					],
					error: null,
				},
				// The pre-send fenced re-read added in round 8: the row is
				// still unsuppressed and unsent, so the send proceeds.
				{ data: [{ id: "due-notif-1" }], error: null },
			],
			// Four UPDATE calls (round 3 finding #4 added the claim ahead of
			// round 2 finding #1's onesignal_notification_id/sent_at split;
			// round 5 finding #1 fences the pre-insert ownership check AND
			// the sent_at write itself, both individually, rather than
			// round 4's single entry-only renew): the claim, the
			// onesignal_notification_id write, the fenced pre-insert
			// ownership check, and the fenced sent_at write. ALL FOUR are
			// conditional writes that check affected-row count, not just
			// `error` — round 5 finding #2's audit — so every one of them
			// must return a non-empty array here, including the last
			// (sent_at is fenced now too, unlike in round 4).
			"notifications:update": [
				{ data: [{ id: "due-notif-1" }], error: null },
				{ data: [{ id: "due-notif-1" }], error: null },
				{ data: [{ id: "due-notif-1" }], error: null },
				{ data: [{ id: "due-notif-1" }], error: null },
			],
			// Existence check before inserting the sent event (finding #3) — no
			// prior event, so it proceeds to insert.
			"notification_events:select": [{ data: [], error: null }],
			"notification_events:insert": [{ data: null, error: null }],
		});

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		const idUpdateCall = supabase.calls.find(
			(c) => c.method === "notifications.update" && (c.args[0] as Record<string, unknown>).onesignal_notification_id !== undefined,
		);
		expect(idUpdateCall?.args[0]).toMatchObject({ onesignal_notification_id: "onesignal-send-id" });
		const lteCall = supabase.calls.find((c) => c.method === "notifications.lte" && c.args[0] === "scheduled_for");
		expect(lteCall).toBeDefined();
	});

	it("processes nothing when no rows are due (query itself returns empty)", async () => {
		const supabase = makeSupabaseStub({
			"notifications:select": [{ data: [], error: null }],
		});

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 0, sent: 0, suppressed: 0, failed: 0 });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("respects a caller-supplied limit override, distinct from the default", async () => {
		const supabase = makeSupabaseStub({ "notifications:select": [{ data: [], error: null }] });
		await sendDeferredNotifications(supabase as never, ENV, 3);
		const limitCall = supabase.calls.find((c) => c.method === "notifications.limit");
		expect(limitCall?.args[0]).toBe(3);
		expect(3).not.toBe(DEFAULT_DEFERRED_SEND_LIMIT);
	});

	it("does nothing when OneSignal is not configured (fails closed, not open)", async () => {
		const supabase = makeSupabaseStub({});
		const result = await sendDeferredNotifications(supabase as never, {});
		expect(result).toEqual({ processed: 0, sent: 0, suppressed: 0, failed: 0 });
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

describe("refreshNotificationTags (P1-a decoupling)", () => {
	it("computes tags from the user's own tables and PATCHes them to OneSignal", async () => {
		const supabase = makeSupabaseStub({
			"user_profiles:select": [{ data: { timezone: "Asia/Tokyo" }, error: null }],
			"entitlements:select": [{ data: { is_active: true }, error: null }],
			"matches:select": [{ data: [], error: null }],
		});

		const result = await refreshNotificationTags(supabase as never, ENV, "user-1");

		expect(result).toEqual({ ok: true });
		expect(fetchMock).toHaveBeenCalledTimes(1);
		const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		expect(url).toBe("https://api.onesignal.com/apps/test-app-id/users/by/external_id/user-1");
		expect(JSON.parse(init.body as string)).toEqual({
			properties: { tags: { billing_status: "active", has_meetup_experience: "false", timezone: "Asia/Tokyo" } },
		});
	});

	it("is not called as a side effect of sendNotification or sendDeferredNotifications (only the OneSignal send fetch happens)", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-no-tag-refresh" }, error: null }],
			"notifications:update": [
				{ data: null, error: null },
				{ data: null, error: null },
			],
			"notification_events:select": [{ data: [], error: null }],
			"notification_events:insert": [{ data: null, error: null }],
		});

		await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
		});

		const tagCalls = fetchMock.mock.calls.filter((call: unknown[]) => (call[0] as string).includes("/users/by/external_id/"));
		expect(tagCalls).toHaveLength(0);
	});

	it("returns ok:false without throwing when OneSignal is not configured", async () => {
		const supabase = makeSupabaseStub({});
		const result = await refreshNotificationTags(supabase as never, {}, "user-1");
		expect(result).toEqual({ ok: false });
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

/**
 * Stateful in-memory notifications table for the poison-row test below —
 * the generic FIFO-queued-response `makeSupabaseStub` above can't express
 * "a later query sees the effect of an earlier query's UPDATE", which is
 * exactly the behavior under test (orchestrator review P1-b).
 */
interface StatefulNotifRow {
	id: string;
	scenario_id: string;
	user_id: string;
	payload: Record<string, unknown> | null;
	sent_at: string | null;
	suppressed_reason: string | null;
	scheduled_for: string | null;
	onesignal_notification_id: string | null;
	/** Present only for the deferred block-revalidation tests. */
	match_id?: string | null;
	meetup_id?: string | null;
}

interface StatefulSentEvent {
	id: string;
	notification_id: string;
	event_type: string;
}

interface StatefulSupabaseOptions {
	/**
	 * Match ids for which the `blocks` lookup finds a row, i.e. the two people
	 * have blocked each other. Only consulted when a notification row carries
	 * a `match_id`. Used by the deferred block-revalidation tests.
	 */
	blockedMatchIds?: Set<string>;
	/** When true, every `blocks` lookup resolves with an error instead. */
	blocksLookupFails?: boolean;
	/**
	 * One-shot: the NEXT `notifications` UPDATE whose patch matches this
	 * predicate returns a DB error instead of applying, then the predicate
	 * is cleared. Models a single transient write failure for finding #1's
	 * (review round 2) regression test (a real UPDATE failing after
	 * OneSignal already accepted the send).
	 */
	failNextUpdateWhere?: (patch: Record<string, unknown>) => boolean;
	/**
	 * Like `failNextUpdateWhere` but NOT one-shot: every matching UPDATE
	 * fails, indefinitely. Used by round 4 finding #1's regression test to
	 * drive a row through many consecutive repair failures and confirm it
	 * never reaches `deferred_send_exhausted`. Also receives the `id` the
	 * update's `.eq("id", ...)` filter targets (if any), so a test can
	 * target specific rows instead of every row in the fake.
	 */
	alwaysFailUpdateWhere?: (patch: Record<string, unknown>, targetId: string | undefined) => boolean;
	/**
	 * One-shot: the NEXT `notifications` UPDATE whose patch matches this
	 * predicate awaits `barrier` before applying (against the row's state
	 * AT THAT LATER TIME, not a snapshot from before the wait — the whole
	 * point). Used by round 4 finding #3's fencing regression test to
	 * simulate a slow invocation that is paused mid-write while a second
	 * invocation runs to completion, then resumes and must find its own
	 * write fenced out.
	 */
	blockUpdateOnce?: { predicate: (patch: Record<string, unknown>) => boolean; barrier: Promise<void> } | null;
	/**
	 * If set, every `notifications` due-query (`.limit()`) awaits this
	 * promise before resolving. Used by the overlap test (round 3 finding
	 * #4) to force two concurrent `sendDeferredNotifications` calls to both
	 * complete their due-query — both seeing the SAME pre-claim
	 * `scheduled_for` — before either proceeds to claim, deterministically
	 * reproducing the race instead of hoping incidental microtask
	 * scheduling happens to overlap.
	 */
	dueQueryBarrier?: Promise<void>;
	/**
	 * One-shot: the NEXT `notification_events` INSERT awaits `barrier`
	 * before applying. Used by round 5 finding #1's regression test to
	 * pause an invocation exactly between its (successful) fenced
	 * pre-insert ownership check and the event insert itself — the
	 * specific gap round 4's entry-only fencing left open.
	 */
	blockNextEventInsert?: Promise<void>;
	/** Age rows returned by the deferred match revalidation lookup. */
	ageProfileRows?: Array<Record<string, unknown>>;
}

function statefulColumn(row: StatefulNotifRow, column: string): unknown {
	if (column === "payload->>deep_link") return row.payload?.deep_link;
	if (column === "match_id") return row.match_id ?? null;
	if (column === "meetup_id") return row.meetup_id ?? null;
	if (column.startsWith("payload->delivery_context->>")) {
		const key = column.split(">>").at(-1) as string;
		const context = parseNotificationDeliveryContext(row.payload?.delivery_context);
		return context && key in context ? (context as Record<string, unknown>)[key] : undefined;
	}
	return (row as never as Record<string, unknown>)[column];
}

function embeddedColumnValues(row: StatefulNotifRow, column: string, options?: StatefulSupabaseOptions): unknown[] {
	if (!column.includes(".")) return [];
	let values: unknown[] = [makeStatefulFinalSnapshot(row, options)];
	for (const part of column.split(".")) {
		values = values.flatMap((value) => {
			const candidates = Array.isArray(value) ? value : [value];
			return candidates.flatMap((candidate) =>
				candidate && typeof candidate === "object" && part in candidate ? [(candidate as Record<string, unknown>)[part]] : [],
			);
		});
	}
	return values.flatMap((value) => (Array.isArray(value) ? value : [value]));
}

function embeddedFilterMatches(row: StatefulNotifRow, column: string, expected: unknown, options?: StatefulSupabaseOptions): boolean {
	const values = embeddedColumnValues(row, column, options);
	if (values.some((value) => value === expected)) return true;
	// A non-inner embedded child can be empty while the parent remains in the
	// result. The final validator still sees that empty relationship and makes
	// the delivery decision; this only models PostgREST's row selection.
	return values.length === 0 && column.includes("blocks_sent");
}

function makeStatefulFinalSnapshot(row: StatefulNotifRow, options?: StatefulSupabaseOptions): Record<string, unknown> {
	const matchId = row.match_id ?? null;
	const meetupId = row.meetup_id ?? null;
	const context = parseNotificationDeliveryContext(row.payload?.delivery_context);
	const base: Record<string, unknown> = {
		id: row.id,
		scenario_id: row.scenario_id,
		user_id: row.user_id,
		match_id: matchId,
		meetup_id: meetupId,
		payload: row.payload,
		scheduled_for: row.scheduled_for,
		sent_at: row.sent_at,
		suppressed_reason: row.suppressed_reason,
		onesignal_notification_id: row.onesignal_notification_id,
		scenario: { scenario_id: row.scenario_id, is_enabled: true },
	};
	if (!matchId) return base;
	const profileRows = options?.ageProfileRows ?? [matchingProfile("user-1"), matchingProfile("user-2")];
	const profileA = { ...(profileRows.find((profile) => profile.id === "user-1") ?? matchingProfile("user-1")), blocks_sent: [] as unknown[] };
	const profileB = { ...(profileRows.find((profile) => profile.id === "user-2") ?? matchingProfile("user-2")), blocks_sent: [] as unknown[] };
	if (options?.blockedMatchIds?.has(matchId)) profileA.blocks_sent.push({ id: "block-1", blocker_id: "user-1", blocked_id: "user-2" });
	const match: Record<string, unknown> = {
		id: matchId,
		user_a_id: "user-1",
		user_b_id: "user-2",
		status: row.scenario_id === "N-03" ? "direct_chat_requested" : row.scenario_id === "N-01" ? "fox_conversation_completed" : "direct_chat_active",
		profile_a: profileA,
		profile_b: profileB,
		compatibility_conversations:
			row.scenario_id === "N-01"
				? [{ id: context && "conversation_id" in context ? context.conversation_id : "conversation-1", match_id: matchId, purpose: "compatibility", status: "completed" }]
				: [],
		chat_requests:
			row.scenario_id === "N-03"
				? [{ id: context && "request_id" in context ? context.request_id : "request-1", match_id: matchId, requester_id: "user-2", responder_id: row.user_id, status: "pending", expires_at: "2099-01-01T00:00:00.000Z" }]
				: [],
		direct_room: row.scenario_id === "N-01" ? [] : [{ id: "room-1", match_id: matchId, status: "active" }],
	};
	base.match = match;
	if (meetupId) {
		base.meetup = {
			id: meetupId,
			match_id: matchId,
			initiator_id: "user-1",
			status: row.scenario_id === "N-05" ? "proposed" : row.scenario_id === "N-06" ? "confirmed" : row.scenario_id === "N-07" ? "verifying" : row.scenario_id === "N-14" ? "arrange_failed" : "verifying",
			proposal_expires_at: null,
			proposals:
				row.scenario_id === "N-05"
					? [{ id: context && "proposal_id" in context ? context.proposal_id : "proposal-1", meetup_id: meetupId, attempt_number: 1, expires_at: "2099-01-01T00:00:00.000Z" }]
					: [],
		};
	}
	return base;
}

/**
 * Stateful in-memory `notifications` + `notification_events` tables. The
 * generic FIFO-queued-response `makeSupabaseStub` above can't express "a
 * later query sees the effect of an earlier query's UPDATE/INSERT", which
 * several review-round regression tests need: P1-b's poison-row backoff,
 * finding #1's bookkeeping-repair retry, finding #3's exactly-once event
 * write, and finding #4's claim race.
 *
 * `update()` supports both call shapes this codebase actually uses:
 * `.update(patch).eq(col, val)` (awaited directly — the backoff/exhaustion/
 * suppressed/sent_at writes) and `.update(patch).eq(col, val).eq(col2, val2).select("id")`
 * (the atomic claim in `claimDueNotification` — an update guarded on TWO
 * columns, returning the affected row so the caller can tell whether it
 * won the race). Both resolve against the SAME row state synchronously
 * (JS's single-threaded execution model), which is what makes the claim
 * guard's WHERE-clause semantics faithfully reproducible in these tests:
 * a second claim attempt whose `.eq("scheduled_for", ...)` filter targets
 * a value the first claim has already changed simply won't match.
 */
function makeStatefulNotificationsSupabase(rows: StatefulNotifRow[], options?: StatefulSupabaseOptions) {
	let failNextUpdateWhere = options?.failNextUpdateWhere ?? null;
	const alwaysFailUpdateWhere = options?.alwaysFailUpdateWhere ?? null;
	let blockUpdateOnce = options?.blockUpdateOnce ?? null;
	const blockedMatchIds = options?.blockedMatchIds ?? new Set<string>();
	const blocksLookupFails = options?.blocksLookupFails ?? false;
	const events: StatefulSentEvent[] = [];
	const updates: Array<{ patch: Record<string, unknown>; filters: Array<[string, unknown]> }> = [];
	let eventIdCounter = 0;
	// The fake has no way to see which notification the executor is currently
	// working on from inside the `blocks` chain, so the deferred tests set at
	// most one blocked match and this simply reports whether any row in the
	// fixture carries it.
	const blockedForCurrentRow = () => rows.some((r) => r.match_id != null && blockedMatchIds.has(r.match_id));

	function notificationsSelectChain(predicates: Array<(r: StatefulNotifRow) => boolean>, selectedColumns = "") {
		// biome-ignore lint/suspicious/noExplicitAny: minimal test double
		const chain: any = {
			select: (columns: string) => notificationsSelectChain(predicates, columns),
			is: (col: string, val: unknown) =>
				notificationsSelectChain(
					[...predicates, (r) => (col.includes(".") ? embeddedFilterMatches(r, col, val, options) : statefulColumn(r, col) === val)],
					selectedColumns,
				),
			// Added for the pre-send fenced re-read (round 8): it filters by
			// `id` and `scheduled_for` as well as the two `is` checks.
			eq: (col: string, val: unknown) =>
				notificationsSelectChain(
					[...predicates, (r) => (col.includes(".") ? embeddedFilterMatches(r, col, val, options) : statefulColumn(r, col) === val)],
					selectedColumns,
				),
			not: (col: string, _op: string, val: unknown) =>
				notificationsSelectChain([...predicates, (r) => statefulColumn(r, col) !== val], selectedColumns),
			lte: (col: string, val: string) =>
				notificationsSelectChain([
					...predicates,
					(r) => {
						const fieldValue = statefulColumn(r, col);
						return typeof fieldValue === "string" && fieldValue <= val;
					},
				]),
			order: () => chain,
			limit: async (n: number) => {
				if (options?.dueQueryBarrier) await options.dueQueryBarrier;
				const matched = rows.filter((r) => predicates.every((p) => p(r)));
				matched.sort((a, b) => (a.scheduled_for ?? "").localeCompare(b.scheduled_for ?? ""));
				const data = matched.slice(0, n).map((r) => ({
					id: r.id,
					scenario_id: r.scenario_id,
					user_id: r.user_id,
					match_id: r.match_id ?? null,
					meetup_id: r.meetup_id ?? null,
					payload: r.payload,
					onesignal_notification_id: r.onesignal_notification_id,
					scheduled_for: r.scheduled_for,
				}));
				return { data, error: null };
				},
			};
			chain.single = async () => {
				const row = rows.find((candidate) => predicates.every((predicate) => predicate(candidate)));
				if (!row) return { data: null, error: { code: "PGRST116", message: "row not found" } };
				if (!selectedColumns.includes("scenario:notification_scenarios")) return { data: row, error: null };
				return { data: makeStatefulFinalSnapshot(row, options), error: null };
			};
		return chain;
	}

	function notificationsUpdateChain(patch: Partial<StatefulNotifRow>) {
		const eqFilters: Array<[string, unknown]> = [];
		const targetId = () => eqFilters.find(([col]) => col === "id")?.[1] as string | undefined;
		const resolveUpdate = async (): Promise<{ data: unknown; error: unknown }> => {
			const patchRecord = patch as Record<string, unknown>;
			updates.push({ patch: { ...patchRecord }, filters: [...eqFilters] });
			if (blockUpdateOnce?.predicate(patchRecord)) {
				const barrier = blockUpdateOnce.barrier;
				blockUpdateOnce = null; // one-shot
				await barrier; // re-evaluate the WHERE match AFTER this, against current row state
			}
			if (failNextUpdateWhere?.(patchRecord)) {
				failNextUpdateWhere = null; // one-shot
				return { data: null, error: { message: "simulated transient update failure" } };
			}
			if (alwaysFailUpdateWhere?.(patchRecord, targetId())) {
				return { data: null, error: { message: "simulated persistent update failure" } };
			}
			const row = rows.find((r) => eqFilters.every(([col, val]) => statefulColumn(r, col) === val));
			if (!row) return { data: [], error: null }; // WHERE matched nothing — 0 rows affected (a lost claim race)
			Object.assign(row, patch);
			return { data: [{ id: row.id }], error: null };
		};
		// biome-ignore lint/suspicious/noExplicitAny: minimal test double
		const chain: any = {
			eq: (col: string, val: unknown) => {
				eqFilters.push([col, val]);
				return chain;
			},
			is: (col: string, val: unknown) => {
				eqFilters.push([col, val]);
				return chain;
			},
			select: (_cols: string) => resolveUpdate(),
			then: (resolve: (v: unknown) => unknown, reject?: (e: unknown) => unknown) => resolveUpdate().then(resolve, reject),
		};
		return chain;
	}

	function eventsSelectChain(predicates: Array<(e: StatefulSentEvent) => boolean>) {
		// biome-ignore lint/suspicious/noExplicitAny: minimal test double
		const chain: any = {
			eq: (col: string, val: unknown) => eventsSelectChain([...predicates, (e) => (e as never as Record<string, unknown>)[col] === val]),
			limit: (n: number) => {
				const matched = events.filter((e) => predicates.every((p) => p(e)));
				return Promise.resolve({ data: matched.slice(0, n).map((e) => ({ id: e.id })), error: null });
			},
		};
		return chain;
	}

	let blockNextEventInsert = options?.blockNextEventInsert ?? null;

	return {
		from: (table: string) => {
			if (table === "notification_events") {
				return {
					insert: async (row: { id?: string; notification_id: string; event_type: string }) => {
						if (blockNextEventInsert) {
							const barrier = blockNextEventInsert;
							blockNextEventInsert = null; // one-shot
							await barrier;
						}
						// notification_events.id is PRIMARY KEY — round 5 finding #1
						// deliberately relies on this for real, DB-level uniqueness
						// (see finalizeAlreadySentNotification's doc comment), so the
						// fake must enforce it the same way a real Postgres would.
						eventIdCounter++;
						const id = row.id ?? `evt-${eventIdCounter}`;
						if (events.some((e) => e.id === id)) {
							return {
								data: null,
								error: { code: "23505", message: `duplicate key value violates unique constraint "notification_events_pkey"` },
							};
						}
						events.push({ id, notification_id: row.notification_id, event_type: row.event_type });
						return { data: null, error: null };
					},
					select: () => eventsSelectChain([]),
				};
			}
			if (table === "matches") {
				// checkNotificationBlocked resolves the counterpart from the
				// match before looking at `blocks`; the ids themselves do not
				// matter to these tests, only that the lookup succeeds.
				// biome-ignore lint/suspicious/noExplicitAny: minimal test double
				const chain: any = {};
				let requestedMatchId: string | undefined;
				chain.select = () => chain;
				chain.eq = (_column: string, value: unknown) => {
					if (typeof value === "string") requestedMatchId = value;
					return chain;
				};
				chain.single = async () => ({ data: { id: requestedMatchId ?? rows.find((row) => row.match_id)?.match_id ?? "match-1", user_a_id: "user-1", user_b_id: "user-2" }, error: null });
				return chain;
			}
			if (table === "blocks") {
				// biome-ignore lint/suspicious/noExplicitAny: minimal test double
				const chain: any = {};
				let matchIdFromFilter: string | null = null;
				chain.select = () => chain;
				chain.or = () => chain;
				chain.limit = () => chain;
				chain.maybeSingle = async () =>
					blocksLookupFails
						? { data: null, error: { message: "simulated blocks lookup failure" } }
						: { data: blockedForCurrentRow() ? { id: "block-1" } : null, error: null };
				void matchIdFromFilter;
				return chain;
			}
			if (table === "user_profiles") {
				return {
					select: () => ({
						in: async () => ({
							data: options?.ageProfileRows ?? [matchingProfile("user-1"), matchingProfile("user-2")],
							error: null,
						}),
					}),
				};
			}
			if (table !== "notifications") throw new Error(`unexpected table in poison-row test fake: ${table}`);
			return {
				select: (columns: string) => notificationsSelectChain([], columns),
				update: (patch: Partial<StatefulNotifRow>) => notificationsUpdateChain(patch),
			};
		},
		rows,
		events,
		updates,
	};
}

describe("sendDeferredNotifications — poison-row backoff (P1-b)", () => {
	it("a permanently-failing row backs off out of the due window instead of blocking a later due row, and is eventually marked terminal", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-06-15T12:00:00.000Z"));

		const poison: StatefulNotifRow = {
			id: "poison-1",
			scenario_id: "N-13",
			user_id: "user-poison",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2026-06-15T10:00:00.000Z", // earliest — would sort first forever without backoff
			onesignal_notification_id: null,
		};
		const legit: StatefulNotifRow = {
			id: "legit-1",
			scenario_id: "N-13",
			user_id: "user-legit",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2026-06-15T11:00:00.000Z", // due, later than poison
			onesignal_notification_id: null,
		};
		const supabase = makeStatefulNotificationsSupabase([poison, legit]);

		fetchMock.mockImplementation(async (url: string, init: RequestInit) => {
			if (url.includes("/notifications")) {
				const body = JSON.parse(init.body as string) as { data: { notification_id: string } };
				if (body.data.notification_id === "poison-1") {
					return new Response(JSON.stringify({ errors: ["boom"] }), { status: 500 });
				}
				return new Response(JSON.stringify({ id: "onesignal-legit", recipients: 1 }), { status: 200 });
			}
			return new Response("{}", { status: 200 });
		});

		// Invocation 1 (limit 1): poison sorts first (earlier scheduled_for)
		// and is selected instead of the legit row.
		const first = await sendDeferredNotifications(supabase as never, ENV, 1);
		expect(first).toEqual({ processed: 1, sent: 0, suppressed: 0, failed: 1 });
		expect(poison.suppressed_reason).toBeNull(); // not yet exhausted
		expect(poison.payload?.deferred_attempts).toBe(1);
		expect(poison.scheduled_for).not.toBe("2026-06-15T10:00:00.000Z"); // pushed forward by backoff
		expect(legit.sent_at).toBeNull(); // legit was NOT starved... yet — proven on the next call

		// Invocation 2, same instant: poison's backed-off scheduled_for is now
		// in the future, so it's no longer due — the legit row gets through.
		const second = await sendDeferredNotifications(supabase as never, ENV, 1);
		expect(second).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(legit.sent_at).not.toBeNull();

		// Drive poison through its remaining bounded retries by advancing
		// fake time past each backoff window, confirming it eventually
		// terminates instead of retrying forever.
		for (let attempt = 2; attempt <= MAX_DEFERRED_SEND_ATTEMPTS; attempt++) {
			vi.setSystemTime(new Date(poison.scheduled_for as string));
			await sendDeferredNotifications(supabase as never, ENV, 1);
		}
		expect(poison.suppressed_reason).toBe("deferred_send_exhausted");
		expect(poison.payload?.deferred_attempts).toBe(MAX_DEFERRED_SEND_ATTEMPTS);

		// One more invocation after exhaustion: poison is excluded by
		// suppressed_reason and is never selected (and never re-attempted) again.
		fetchMock.mockClear();
		vi.setSystemTime(new Date(Date.now() + 365 * 24 * 60 * 60 * 1000)); // far in the future
		const afterExhausted = await sendDeferredNotifications(supabase as never, ENV, 5);
		expect(afterExhausted).toEqual({ processed: 0, sent: 0, suppressed: 0, failed: 0 });
		expect(fetchMock).not.toHaveBeenCalled();
		expect(poison.payload?.deferred_attempts).toBe(MAX_DEFERRED_SEND_ATTEMPTS); // unchanged — no further attempts

		vi.useRealTimers();
		consoleErrorSpy.mockRestore();
	});

	it("marks a row with a structurally invalid deep_link terminal on first sight, without spending any retry budget", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		const badPayload: StatefulNotifRow = {
			id: "bad-payload-1",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "https://evil.example.com/not-allowed" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z",
			onesignal_notification_id: null,
		};
		const supabase = makeStatefulNotificationsSupabase([badPayload]);

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 1, sent: 0, suppressed: 0, failed: 1 });
		expect(fetchMock).not.toHaveBeenCalled(); // never even attempted a send
		expect(badPayload.suppressed_reason).toBe("invalid_deep_link");
		expect(badPayload.payload?.deferred_attempts).toBeUndefined(); // no retry bookkeeping spent

		consoleErrorSpy.mockRestore();
	});

	it("finding #1 (review round 2): a bookkeeping-update failure AFTER OneSignal accepts the push, followed by a retry, sends via OneSignal exactly ONCE", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-06-15T12:00:00.000Z"));

		const row: StatefulNotifRow = {
			id: "flaky-1",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2026-06-15T10:00:00.000Z",
			onesignal_notification_id: null,
		};

		// Fail exactly the write that sets sent_at — i.e. the write that
		// happens AFTER onesignal_notification_id has already been persisted
		// (deliverNow's two-write split, per this finding's fix).
		const supabase = makeStatefulNotificationsSupabase([row], {
			failNextUpdateWhere: (patch) => "sent_at" in patch,
		});

		const first = await sendDeferredNotifications(supabase as never, ENV, 1);

		expect(first).toEqual({ processed: 1, sent: 0, suppressed: 0, failed: 1 });
		expect(fetchMock).toHaveBeenCalledTimes(1); // OneSignal called exactly once
		expect(row.onesignal_notification_id).toBe("onesignal-send-id"); // persisted despite the later failure
		expect(row.sent_at).toBeNull(); // this write is the one that failed
		expect(row.scheduled_for).not.toBe("2026-06-15T10:00:00.000Z"); // backed off, per the P1-b policy

		// Advance to the backed-off retry time and invoke again. Because
		// onesignal_notification_id is already set, this must repair local
		// bookkeeping WITHOUT calling OneSignal a second time.
		vi.setSystemTime(new Date(row.scheduled_for as string));
		const second = await sendDeferredNotifications(supabase as never, ENV, 1);

		expect(second).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(fetchMock).toHaveBeenCalledTimes(1); // STILL exactly once — no duplicate send
		expect(row.sent_at).not.toBeNull();

		vi.useRealTimers();
		consoleErrorSpy.mockRestore();
	});
});

describe("finding #2 (review round 3): an immediate send whose ID write fails becomes repairable without re-sending to OneSignal", () => {
	it("marks the row due with a pending_onesignal_id fallback marker, then a LATER deferred-executor run repairs it without a second OneSignal call", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		// --- Phase 1: the immediate send. OneSignal accepts the push, but
		// the write that would persist onesignal_notification_id fails.
		const phase1Supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }], // dedup: no prior send
			"notifications:insert": [{ data: { id: "notif-immediate-fail-1" }, error: null }],
			"notifications:update": [
				// 1st update: deliverNow's onesignal_notification_id write — fails.
				{ data: null, error: { message: "simulated transient DB error" } },
				// 2nd update: sendNotification's own "mark due for retry" write — succeeds.
				{ data: null, error: null },
			],
		});

		const phase1Result = await sendNotification(phase1Supabase as never, ENV, {
			scenarioId: "N-13", // fixture marks this unscoped scenario quiet_hours_exempt
			userId: "user-1",
			deepLink: "wingward://availability",
		});

		expect(phase1Result).toEqual({
			ok: false,
			notificationId: "notif-immediate-fail-1",
			reason: "send_accepted_but_unrecorded",
			oneSignalId: "onesignal-send-id",
		});
		expect(fetchMock).toHaveBeenCalledTimes(1); // exactly one OneSignal call so far

		const markDueCall = phase1Supabase.calls.filter((c) => c.method === "notifications.update").at(-1);
		// repair_attempts, not deferred_attempts (round 4 finding #1): this
		// is a repair of an already-answered push, not an unsent-delivery
		// retry, so it must never be able to reach deferred_send_exhausted.
		expect(markDueCall?.args[0]).toMatchObject({
			payload: {
				deep_link: "wingward://availability",
				repair_attempts: 1,
				pending_onesignal_id: "onesignal-send-id",
			},
		});

		// --- Phase 2: a LATER deferred-executor invocation. It must find the
		// row via the pending_onesignal_id fallback marker (the column is
		// still null — that write is what failed) and finish bookkeeping
		// WITHOUT calling OneSignal again.
		const row: StatefulNotifRow = {
			id: "notif-immediate-fail-1",
			scenario_id: "N-08",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability", deferred_attempts: 1, pending_onesignal_id: "onesignal-send-id" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z", // due
			onesignal_notification_id: null, // the column write never succeeded
		};
		const phase2Supabase = makeStatefulNotificationsSupabase([row]);

		const phase2Result = await sendDeferredNotifications(phase2Supabase as never, ENV);

		expect(phase2Result).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(fetchMock).toHaveBeenCalledTimes(1); // STILL exactly once — no re-send to OneSignal
		expect(row.onesignal_notification_id).toBe("onesignal-send-id"); // column repaired from the pending marker
		expect(row.sent_at).not.toBeNull();
		expect(phase2Supabase.events).toHaveLength(1);
		expect(phase2Supabase.events[0]).toMatchObject({ notification_id: "notif-immediate-fail-1", event_type: "sent" });

		consoleErrorSpy.mockRestore();
	});

	it("rediscovers an accepted row after both local fallback writes fail and retries with the same OneSignal idempotency key", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		const phase1Supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-double-write-fail-1" }, error: null }],
			"notifications:update": [
				{ data: null, error: { message: "id write failed" } },
				{ data: null, error: { message: "recovery marker write failed" } },
			],
		});

		const phase1Result = await sendNotification(phase1Supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
		});
		expect(phase1Result).toMatchObject({ reason: "send_accepted_but_unrecorded", oneSignalId: "onesignal-send-id" });
		expect(fetchMock).toHaveBeenCalledTimes(1);

		// The INSERT reservation is the only durable discovery marker left after
		// both local writes fail.  Once it is due, the executor is allowed to ask
		// OneSignal again; the provider idempotency key makes that retry the same
		// logical push rather than a second push.
		const inserted = phase1Supabase.calls.find((call) => call.method === "notifications.insert");
		expect((inserted?.args[0] as Record<string, unknown>).scheduled_for).toEqual(expect.any(String));

		const row: StatefulNotifRow = {
			id: "notif-double-write-fail-1",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: new Date(Date.now() - 60_000).toISOString(),
			onesignal_notification_id: null,
		};
		const phase2Result = await sendDeferredNotifications(makeStatefulNotificationsSupabase([row]) as never, ENV, 1);

		expect(phase2Result).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(fetchMock).toHaveBeenCalledTimes(2);
		const [, retryInit] = fetchMock.mock.calls[1] as [string, RequestInit];
		const retryBody = JSON.parse(retryInit.body as string) as Record<string, unknown>;
		expect(retryBody.idempotency_key).toBe("notif-double-write-fail-1");
		expect((retryBody.data as Record<string, unknown>).notification_id).toBe("notif-double-write-fail-1");

		consoleErrorSpy.mockRestore();
	});
});

describe("finding #3 (review round 3): a delivery can never end up with sent_at set and no sent event", () => {
	it("a sent-event insert that succeeds followed by a sent_at-write failure is not re-inserted on retry — exactly one event, eventually sent_at set", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		const row: StatefulNotifRow = {
			id: "notif-event-first-1",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z",
			onesignal_notification_id: "onesignal-already-accepted-1", // already accepted -> repair path
		};
		const supabase = makeStatefulNotificationsSupabase([row], {
			// Fail exactly the sent_at write, once — the event insert (a
			// different table/op) is untouched by this predicate.
			failNextUpdateWhere: (patch) => "sent_at" in patch,
		});

		const first = await sendDeferredNotifications(supabase as never, ENV);
		expect(first).toEqual({ processed: 1, sent: 0, suppressed: 0, failed: 1 });
		expect(row.sent_at).toBeNull(); // the failed write
		expect(supabase.events).toHaveLength(1); // but the event WAS recorded, before the failing write
		expect(supabase.events[0]).toMatchObject({ notification_id: "notif-event-first-1", event_type: "sent" });

		// Retry: the event already exists, so this must not insert a second
		// one — only the sent_at write is retried.
		vi.useFakeTimers();
		vi.setSystemTime(new Date(row.scheduled_for as string));
		const second = await sendDeferredNotifications(supabase as never, ENV);
		vi.useRealTimers();

		expect(second).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(row.sent_at).not.toBeNull();
		expect(supabase.events).toHaveLength(1); // still exactly one — no duplicate

		consoleErrorSpy.mockRestore();
	});
});

describe("finding #4 (review round 3): overlapping executor invocations don't double-process the same row", () => {
	it("two concurrent sendDeferredNotifications calls over the same due row produce exactly one OneSignal call and exactly one sent event", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		const row: StatefulNotifRow = {
			id: "notif-overlap-1",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z",
			onesignal_notification_id: null,
		};

		// Both concurrent invocations must complete their due-query (and so
		// both read the SAME pre-claim scheduled_for) before either is
		// allowed to proceed to claim — this is what makes the overlap
		// deterministic instead of hoping incidental microtask scheduling
		// happens to interleave.
		let releaseBarrier: () => void = () => {};
		const barrier = new Promise<void>((resolve) => {
			releaseBarrier = resolve;
		});
		const supabase = makeStatefulNotificationsSupabase([row], { dueQueryBarrier: barrier });

		const call1 = sendDeferredNotifications(supabase as never, ENV, 1);
		const call2 = sendDeferredNotifications(supabase as never, ENV, 1);
		// Both calls are now blocked at their due-query. Release them together.
		releaseBarrier();
		const [result1, result2] = await Promise.all([call1, call2]);

		const combined = {
			processed: result1.processed + result2.processed,
			sent: result1.sent + result2.sent,
			suppressed: result1.suppressed + result2.suppressed,
			failed: result1.failed + result2.failed,
		};
		// Exactly one of the two invocations actually claimed and processed
		// the row; the other lost the claim race and did nothing.
		expect(combined).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(fetchMock).toHaveBeenCalledTimes(1); // exactly one OneSignal call across BOTH invocations
		expect(supabase.events).toHaveLength(1); // exactly one sent event, not two
		expect(row.sent_at).not.toBeNull();

		consoleErrorSpy.mockRestore();
	});
});

describe("round 4, finding #1: a repair failure never reaches deferred_send_exhausted", () => {
	it("a row whose bookkeeping keeps failing after OneSignal already accepted the push never gets suppressed_reason set, no matter how many attempts", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-06-15T12:00:00.000Z"));

		const row: StatefulNotifRow = {
			id: "never-exhausts-1",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2026-06-15T10:00:00.000Z",
			onesignal_notification_id: "onesignal-already-accepted-1", // already accepted -> repair path
		};
		// The sent_at write ALWAYS fails — a persistent (not transient)
		// bookkeeping problem, to prove this never terminates as exhausted.
		const supabase = makeStatefulNotificationsSupabase([row], {
			alwaysFailUpdateWhere: (patch) => "sent_at" in patch,
		});

		// Drive it through more attempts than MAX_DEFERRED_SEND_ATTEMPTS (the
		// UNSENT-delivery budget) to prove the repair path is governed by a
		// different, non-exhausting policy.
		const attemptCount = MAX_DEFERRED_SEND_ATTEMPTS + 3;
		for (let i = 0; i < attemptCount; i++) {
			vi.setSystemTime(new Date(row.scheduled_for as string));
			const result = await sendDeferredNotifications(supabase as never, ENV, 1);
			expect(result).toEqual({ processed: 1, sent: 0, suppressed: 0, failed: 1 });
			// The property under test, checked on every single iteration, not
			// just at the end:
			expect(row.suppressed_reason).toBeNull();
			expect(row.sent_at).toBeNull();
		}

		expect(row.payload?.repair_attempts).toBe(attemptCount);
		expect(row.payload?.deferred_attempts).toBeUndefined(); // never touches the OTHER counter
		expect(supabase.events).toHaveLength(1); // inserted once (first attempt), never duplicated on retries
		expect(fetchMock).not.toHaveBeenCalled(); // repair never calls OneSignal

		vi.useRealTimers();
		consoleErrorSpy.mockRestore();
	});
});

describe("round 4, finding #2: a failed suppression write is reported as a failure, not success", () => {
	it("deliverNow returns suppression_unrecorded (not a false suppressed_no_subscription) when the write fails, and a later retry repairs it correctly", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-06-15T12:00:00.000Z"));

		fetchMock.mockImplementation(async (url: string) => {
			if (url.includes("/notifications")) {
				return new Response(JSON.stringify({ id: "onesignal-no-sub-1", recipients: 0 }), { status: 200 });
			}
			return new Response("{}", { status: 200 });
		});

		const row: StatefulNotifRow = {
			id: "suppression-write-fails-1",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2026-06-15T10:00:00.000Z",
			onesignal_notification_id: null,
		};
		// Fail exactly the suppression write, once.
		const supabase = makeStatefulNotificationsSupabase([row], {
			failNextUpdateWhere: (patch) => "suppressed_reason" in patch,
		});

		const first = await sendDeferredNotifications(supabase as never, ENV, 1);
		// Not reported as suppressed (the round-4 bug this fixes: reporting
		// success when the write actually failed) — reported as a failure,
		// classified as a REPAIR failure (round 4 finding #1's interaction
		// note), not an unsent-delivery one.
		expect(first).toEqual({ processed: 1, sent: 0, suppressed: 0, failed: 1 });
		expect(row.suppressed_reason).toBeNull(); // the failed write's effect
		expect(row.payload?.repair_attempts).toBe(1);
		expect(row.payload?.deferred_attempts).toBeUndefined();
		expect(row.payload?.pending_suppression_id).toBe("onesignal-no-sub-1");
		expect(fetchMock).toHaveBeenCalledTimes(1); // OneSignal asked once so far

		// Retry: must repair WITHOUT asking OneSignal again.
		vi.setSystemTime(new Date(row.scheduled_for as string));
		const second = await sendDeferredNotifications(supabase as never, ENV, 1);
		expect(second).toEqual({ processed: 1, sent: 0, suppressed: 1, failed: 0 });
		expect(row.suppressed_reason).toBe("no_subscription");
		expect(row.onesignal_notification_id).toBe("onesignal-no-sub-1");
		expect(fetchMock).toHaveBeenCalledTimes(1); // STILL once — no re-send to OneSignal

		vi.useRealTimers();
		consoleErrorSpy.mockRestore();
	});
});

describe("round 5, findings #1 and #3: fencing holds through the ENTIRE finalization, not just entry, and the event insert itself cannot be duplicated", () => {
	it("a slow invocation paused exactly at its own event-insert, resumed AFTER a second invocation fully finishes the row, produces no second OneSignal call and no duplicate sent event", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-06-15T12:00:00.000Z"));

		const row: StatefulNotifRow = {
			id: "fencing-race-1",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2026-06-15T10:00:00.000Z",
			onesignal_notification_id: null,
		};

		// Invocation "A" is paused exactly at the notification_events INSERT
		// — i.e. AFTER it has already claimed the row, called OneSignal, and
		// persisted onesignal_notification_id, but WHILE attempting to
		// record the sent event. This is the specific window round 4's
		// entry-only fencing left open (Codex, round 5 finding #1): the
		// danger isn't "before bookkeeping starts", it's "during it".
		let releaseA: () => void = () => {};
		const aBarrier = new Promise<void>((resolve) => {
			releaseA = resolve;
		});
		const supabase = makeStatefulNotificationsSupabase([row], {
			blockNextEventInsert: aBarrier,
		});

		const aPromise = sendDeferredNotifications(supabase as never, ENV, 1);
		// Let A run up to (and pause inside) its event insert — several
		// `await`s deep (due-query, claim, the mocked fetch, the id-persist
		// write) before it gets there, so flush generously rather than
		// guessing an exact microtask-tick count.
		for (let i = 0; i < 50; i++) {
			await Promise.resolve();
		}

		expect(row.onesignal_notification_id).toBe("onesignal-send-id"); // A got this far before pausing
		expect(fetchMock).toHaveBeenCalledTimes(1); // A's one (and, it turns out, only) OneSignal call
		expect(supabase.events).toHaveLength(0); // A's own insert hasn't landed yet — it's paused mid-call

		// A's claim window elapses while it's still paused inside the
		// insert, and a second invocation ("B") now sees the row as due
		// again and fully finishes it — including inserting the sent event
		// itself, since from B's perspective none exists yet.
		vi.setSystemTime(new Date(Date.now() + 3 * 60_000)); // past CLAIM_WINDOW_MS (2 min)
		const bResult = await sendDeferredNotifications(supabase as never, ENV, 1);
		expect(bResult).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(row.sent_at).not.toBeNull();
		expect(supabase.events).toHaveLength(1); // B's insert landed

		// Now release A. Its OWN insert attempt (paused this whole time)
		// finally executes — with the SAME deterministic id B already used
		// (both derive it from the same notification_id) — so it collides
		// on the primary key and is correctly treated as "already
		// recorded", not an error. A then reaches its fenced sent_at write,
		// guarded on its OWN (now-stale) token, which no longer matches the
		// row's CURRENT scheduled_for (B changed it) — so A is fenced out
		// there too: no corruption of what B already recorded.
		releaseA();
		const aResult = await aPromise;
		expect(aResult).toEqual({ processed: 1, sent: 0, suppressed: 0, failed: 0 }); // A's row didn't count as failed — it just lost ownership

		expect(fetchMock).toHaveBeenCalledTimes(1); // still exactly one, total
		expect(supabase.events).toHaveLength(1); // still exactly one, total — NOT duplicated
		expect(row.sent_at).not.toBeNull();

		vi.useRealTimers();
		consoleErrorSpy.mockRestore();
	});
});

describe("round 5, finding #2: repair backoff escalates correctly and cannot starve other due rows", () => {
	it("N persistently-failing repair rows back off out of the due window and stop occupying every slot, letting a legitimately-due row through on the next run", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-06-15T12:00:00.000Z"));

		// Five rows whose bookkeeping (sent_at) always fails after OneSignal
		// already accepted them — the exact "repair failure" shape — sorted
		// EARLIEST, so a due-query with the default limit (5) would pick all
		// five of them ahead of the legitimately-due row below, UNLESS their
		// backoff writes actually take effect and push them out of the due
		// window on the very next invocation.
		const failingRows: StatefulNotifRow[] = Array.from({ length: DEFAULT_DEFERRED_SEND_LIMIT }, (_, i) => ({
			id: `starver-${i}`,
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: new Date(Date.parse("2026-06-15T10:00:00.000Z") + i * 1000).toISOString(),
			onesignal_notification_id: `onesignal-already-accepted-${i}`,
		}));
		const legitRow: StatefulNotifRow = {
			id: "legit-row",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			// Later than all five failing rows, so it sorts LAST and would
			// never be reached if the failing rows kept monopolising every
			// slot of every run.
			scheduled_for: new Date(Date.parse("2026-06-15T10:00:00.000Z") + DEFAULT_DEFERRED_SEND_LIMIT * 1000).toISOString(),
			onesignal_notification_id: null,
		};

		const failingIds = new Set(failingRows.map((r) => r.id));
		const supabase = makeStatefulNotificationsSupabase([...failingRows, legitRow], {
			alwaysFailUpdateWhere: (patch, targetId) => "sent_at" in patch && targetId !== undefined && failingIds.has(targetId),
		});

		// Invocation 1 (default limit): the five failing rows sort first and
		// fill every slot; the legit row is due too but doesn't fit.
		const first = await sendDeferredNotifications(supabase as never, ENV);
		expect(first).toEqual({ processed: DEFAULT_DEFERRED_SEND_LIMIT, sent: 0, suppressed: 0, failed: DEFAULT_DEFERRED_SEND_LIMIT });
		expect(legitRow.sent_at).toBeNull(); // not reached this run

		for (const row of failingRows) {
			expect(row.payload?.repair_attempts).toBe(1); // backoff bookkeeping actually applied
			expect(row.suppressed_reason).toBeNull(); // never exhausted (round 4 finding #1)
			// The backoff write actually took effect — scheduled_for moved
			// out of the due window instead of silently staying put (this
			// round's finding #2: a fenced write whose WHERE clause doesn't
			// match must be DETECTED, not assumed to have applied).
			expect(Date.parse(row.scheduled_for as string)).toBeGreaterThan(Date.now());
		}

		// Invocation 2, same instant: none of the five failing rows are due
		// anymore (their backoff pushed them into the future) — the
		// due-query now surfaces ONLY the legit row, and it gets processed.
		const second = await sendDeferredNotifications(supabase as never, ENV);
		expect(second).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(legitRow.sent_at).not.toBeNull();
		expect(fetchMock).toHaveBeenCalledTimes(1); // only the legit row ever reached OneSignal

		vi.useRealTimers();
		consoleErrorSpy.mockRestore();
	});
});

describe("round 6: a forged notification_events.id collision must not be accepted as proof of a real sent event", () => {
	it("a foreign row occupying the notification's deterministic id (e.g. inserted directly by the notification's own owner, RLS does not constrain id) does not suppress the real sent event or block sent_at", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		const row: StatefulNotifRow = {
			id: "forged-collision-1",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z",
			onesignal_notification_id: "onesignal-already-accepted-1", // repair path — no OneSignal call needed
		};
		const supabase = makeStatefulNotificationsSupabase([row]);
		// Simulate a client that reached Supabase directly (the path
		// notification_events_insert's RLS policy exists for — see
		// finalizeAlreadySentNotification's doc comment) and inserted an
		// `opened` event with id forged to equal the notification's own id,
		// pre-occupying the exact primary key our deterministic sent-event
		// insert would use. RLS constrains user_id/notification_id, not id,
		// so this is a legal insert under that policy.
		supabase.events.push({ id: row.id, notification_id: row.id, event_type: "opened" });

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		// sent_at DID get set — the forged row did not block the real funnel
		// record from being recorded (falling back to a generated id).
		expect(row.sent_at).not.toBeNull();

		// Both the forged row and a genuine sent event now exist, under
		// DIFFERENT ids (the fallback path never reuses the occupied id).
		expect(supabase.events).toHaveLength(2);
		const forged = supabase.events.find((e) => e.event_type === "opened");
		const sent = supabase.events.find((e) => e.event_type === "sent");
		expect(forged).toMatchObject({ id: row.id, notification_id: row.id });
		expect(sent).toBeDefined();
		expect(sent?.id).not.toBe(row.id); // proves the fallback id was used, not the forged/occupied one
		expect(sent?.notification_id).toBe(row.id);

		consoleErrorSpy.mockRestore();
	});

	it("a retry after a forged-collision fallback does not insert a second sent event", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-06-15T12:00:00.000Z"));

		const row: StatefulNotifRow = {
			id: "forged-collision-2",
			scenario_id: "N-13",
			user_id: "user-1",
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2026-06-15T10:00:00.000Z",
			onesignal_notification_id: "onesignal-already-accepted-2",
		};
		// Same forged row, but this time the fenced sent_at write ALSO fails
		// once, forcing a retry through the whole repair path again.
		const supabase = makeStatefulNotificationsSupabase([row], {
			failNextUpdateWhere: (patch) => "sent_at" in patch,
		});
		supabase.events.push({ id: row.id, notification_id: row.id, event_type: "opened" });

		const first = await sendDeferredNotifications(supabase as never, ENV, 1);
		expect(first).toEqual({ processed: 1, sent: 0, suppressed: 0, failed: 1 });
		expect(row.sent_at).toBeNull(); // the sent_at write is what failed
		expect(supabase.events).toHaveLength(2); // forged row + our fallback sent event, already recorded

		vi.setSystemTime(new Date(row.scheduled_for as string));
		const second = await sendDeferredNotifications(supabase as never, ENV, 1);
		expect(second).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(row.sent_at).not.toBeNull();
		expect(supabase.events).toHaveLength(2); // still exactly two — the identity check found the fallback event and did not insert again

		vi.useRealTimers();
		consoleErrorSpy.mockRestore();
	});
});

/**
 * Migration 20260820100000 moved three invariants from application code into
 * the database. These cover the application's half of that move: a constraint
 * violation the database now raises must land as an outcome the caller already
 * understood, not as a new failure mode.
 */
describe("migration 20260820100000: the dedup exclusion constraint reads as a duplicate, not a failure", () => {
	it("maps SQLSTATE 23P01 from the notifications INSERT to reason 'duplicate' and never calls OneSignal", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			// The pre-send dedup query finds nothing: this test IS the race —
			// the other caller inserted its row after this SELECT ran.
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [
				{
					data: null,
					error: { code: "23P01", message: 'conflicting key value violates exclusion constraint "notifications_dedup_window_excl"' },
				},
			],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toEqual({ ok: false, reason: "duplicate" });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("still maps SQLSTATE 23505 to 'duplicate' — the older UNIQUE constraint can win the tie on an exact-timestamp collision", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			// This case carries a matchId, so the block revalidation runs.
			"matches:select": [{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null }],
			"blocks:select": [{ data: null, error: null }],
			"notifications:insert": [{ data: null, error: { code: "23505", message: "duplicate key value violates unique constraint" } }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-03",
			userId: "user-1",
			matchId: "match-1",
			deepLink: "wingward://chat-requests/11111111-1111-4111-8111-111111111111",
			deliveryContext: { request_id: "request-1" },
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toEqual({ ok: false, reason: "duplicate" });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("negative control: an unrelated INSERT error is still a failure, not a silent duplicate", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: null, error: { code: "08006", message: "connection failure" } }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toEqual({ ok: false, reason: "insert_failed" });
		expect(fetchMock).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});
});

describe("migration 20260820100000: the one-sent-event-per-notification index resolving a race is a success, not a send failure", () => {
	it("a fallback sent-event insert rejected by the unique index is treated as already recorded, and the send completes", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-race" }, error: null }],
			"notifications:update": [
				{ data: null, error: null }, // onesignal_notification_id
				{ data: null, error: null }, // sent_at
			],
			"notification_events:insert": [
				// Deterministic-id insert collides with a foreign row.
				{ data: null, error: { code: "23505", message: "duplicate key value violates unique constraint" } },
				// Fallback insert: a concurrent claimant recorded the genuine
				// sent event between the identity check and this write, so the
				// partial unique index rejects it. Exactly one sent row exists,
				// which is the invariant — so this must not read as a failure.
				{
					data: null,
					error: { code: "23505", message: 'duplicate key value violates unique constraint "notification_events_one_sent_per_notification"' },
				},
			],
			// Identity check after the first collision: no genuine sent event
			// visible yet, so the code proceeds to the fallback.
			"notification_events:select": [{ data: [], error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toEqual({ ok: true, notificationId: "notif-race", outcome: "sent" });
		consoleErrorSpy.mockRestore();
	});

	it("negative control: a fallback insert failing for any other reason is still not a successful send", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-race-2" }, error: null }],
			"notifications:update": [{ data: null, error: null }],
			"notification_events:insert": [
				{ data: null, error: { code: "23505", message: "duplicate key value violates unique constraint" } },
				{ data: null, error: { code: "08006", message: "connection failure" } },
			],
			"notification_events:select": [{ data: [], error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toMatchObject({ ok: false });
		consoleErrorSpy.mockRestore();
	});
});

/**
 * Codex P0, PR #31 review round 3. The block check at the chat-request route
 * only covers the instant a notification is CREATED. A quiet-hours hold can
 * sit for up to ten hours before delivery, and the recipient may block the
 * other person in that window — so the relationship is revalidated inside the
 * pipeline, both at creation and again in the deferred executor. Putting it
 * there rather than at the trigger sites is what makes it impossible for a
 * future scenario to be wired without it.
 */
describe("blocks are revalidated inside the send pipeline, not only at the trigger", () => {
	function blockAwareStub(blockRow: unknown, blockError: unknown = null) {
		return makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"matches:select": [{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null }],
			"blocks:select": [{ data: blockRow, error: blockError }],
			"notifications:insert": [{ data: { id: "notif-blocked" }, error: null }],
		});
	}

	const params = {
		scenarioId: "N-03",
		userId: "user-1",
		matchId: "match-1",
		deepLink: "wingward://chat-requests/11111111-1111-4111-8111-111111111111",
		deliveryContext: { request_id: "request-1" },
		now: new Date("2026-06-15T12:00:00.000Z"),
	};

	it("refuses to create or send when either party has blocked the other", async () => {
		const supabase = blockAwareStub({ id: "block-1" });

		const result = await sendNotification(supabase as never, ENV, params);

		expect(result).toEqual({ ok: false, reason: "blocked" });
		expect(fetchMock).not.toHaveBeenCalled();
		// The check runs BEFORE the row is created — a notification that never
		// exists cannot later be delivered by the deferred executor.
		const insert = supabase.calls.find((c) => c.method === "notifications.insert");
		expect(insert).toBeUndefined();
	});

	it("fails closed when the blocks lookup itself errors — unreadable is not unblocked", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const supabase = blockAwareStub(null, { message: "connection reset" });

		const result = await sendNotification(supabase as never, ENV, params);

		expect(result).toEqual({ ok: false, reason: "block_check_failed" });
		expect(fetchMock).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("negative control: an unblocked pair still sends", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			// Two of each: the pre-send check, then the late re-check added in
			// round 10 immediately before the outbound call.
			"matches:select": [
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
			],
			"blocks:select": [
				{ data: null, error: null },
				{ data: null, error: null },
			],
			"notifications:insert": [{ data: { id: "notif-clear" }, error: null }],
			"notifications:update": [
				{ data: null, error: null },
				{ data: null, error: null },
			],
			"notification_events:select": [{ data: [], error: null }],
			"notification_events:insert": [{ data: null, error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, params);

		expect(result).toEqual({ ok: true, notificationId: "notif-clear", outcome: "sent" });
	});

	it("a notification with no match_id has no relationship to check and is unaffected", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-no-match" }, error: null }],
			"notifications:update": [
				{ data: null, error: null },
				{ data: null, error: null },
			],
			"notification_events:select": [{ data: [], error: null }],
			"notification_events:insert": [{ data: null, error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now: new Date("2026-06-15T12:00:00.000Z"),
		});

		expect(result).toEqual({ ok: true, notificationId: "notif-no-match", outcome: "sent" });
		// No matches/blocks query was issued at all — nothing to check.
		expect(supabase.calls.some((c) => c.method.startsWith("blocks."))).toBe(false);
	});
});

describe("the deferred executor revalidates the block before delivering a held notification", () => {
	function heldRow(matchId: string | null): StatefulNotifRow {
		return {
			id: "notif-held",
			scenario_id: "N-03",
			user_id: "user-1",
			match_id: matchId,
			payload: {
				deep_link: "wingward://chat-requests/11111111-1111-4111-8111-111111111111",
				delivery_context: { request_id: "request-1" },
			},
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z",
			onesignal_notification_id: null,
		};
	}

	it("suppresses a held notification when the recipient blocked the other person during the hold", async () => {
		const row = heldRow("match-1");
		const supabase = makeStatefulNotificationsSupabase([row], { blockedMatchIds: new Set(["match-1"]) });

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 1, sent: 0, suppressed: 1, failed: 0 });
		expect(row.suppressed_reason).toBe("blocked");
		expect(row.sent_at).toBeNull();
		// The push is what must not happen: this is the whole point.
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("leaves the row for a later invocation when the block lookup fails — it is not terminal", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const row = heldRow("match-1");
		const supabase = makeStatefulNotificationsSupabase([row], { blocksLookupFails: true });

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 1, sent: 0, suppressed: 0, failed: 1 });
		expect(row.suppressed_reason).toBeNull(); // not marked terminal
		expect(row.sent_at).toBeNull();
		expect(fetchMock).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("negative control: an unblocked held notification is still delivered", async () => {
		const row = heldRow("match-1");
		const supabase = makeStatefulNotificationsSupabase([row]);

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(row.sent_at).not.toBeNull();
	});

	it("repairs a row OneSignal already accepted even when a block now exists — the push cannot be unsent, and its record must not be destroyed", async () => {
		// Codex P1, review round 4. This row is queued only so `sent_at` and
		// the sent event can be repaired; the push was delivered before the
		// block existed. Suppressing it protects nobody and would erase the
		// delivery record of a notification the recipient actually received.
		const row: StatefulNotifRow = {
			id: "notif-already-accepted",
			scenario_id: "N-03",
			user_id: "user-1",
			match_id: "match-1",
			payload: {
				deep_link: "wingward://chat-requests/11111111-1111-4111-8111-111111111111",
				delivery_context: { request_id: "request-1" },
			},
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z",
			onesignal_notification_id: "onesignal-already-accepted",
		};
		const supabase = makeStatefulNotificationsSupabase([row], { blockedMatchIds: new Set(["match-1"]) });

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(row.sent_at).not.toBeNull();
		expect(row.suppressed_reason).toBeNull();
		// And no second push: this is the repair path, not a resend.
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

describe("a suppression that lands after the claim still stops the send (Codex P2, round 8)", () => {
	it("does not call OneSignal for a row suppressed between the claim and the outbound call", async () => {
		const row: StatefulNotifRow = {
			id: "notif-cancelled-mid-flight",
			scenario_id: "N-13",
			user_id: "user-1",
			match_id: null,
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z",
			onesignal_notification_id: null,
		};
		// Simulates any concurrent suppression winning the race immediately
		// after this invocation's claim — the row is marked while we are still
		// holding it. The specific writer does not matter; what is under test
		// is that the executor re-reads before calling OneSignal.
		const supabase = makeStatefulNotificationsSupabase([row], {
			blockUpdateOnce: null,
		});
		const originalFrom = supabase.from.bind(supabase);
		let claimed = false;
		// biome-ignore lint/suspicious/noExplicitAny: minimal test double
		(supabase as any).from = (table: string) => {
			if (table === "notifications" && claimed && row.suppressed_reason === null) {
				row.suppressed_reason = "blocked";
			}
			if (table === "notifications") claimed = true;
			return originalFrom(table);
		};

		const result = await sendDeferredNotifications(supabase as never, ENV);

		// No push: the row was no longer sendable by the time we re-checked.
		expect(fetchMock).not.toHaveBeenCalled();
		expect(row.sent_at).toBeNull();
		expect(result.sent).toBe(0);
	});

	it("negative control: without a concurrent suppression the same row is sent", async () => {
		const row: StatefulNotifRow = {
			id: "notif-not-cancelled",
			scenario_id: "N-13",
			user_id: "user-1",
			match_id: null,
			payload: { deep_link: "wingward://availability" },
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z",
			onesignal_notification_id: null,
		};
		const supabase = makeStatefulNotificationsSupabase([row]);

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 1, sent: 1, suppressed: 0, failed: 0 });
		expect(row.sent_at).not.toBeNull();
	});
});

describe("match notifications revalidate both participants' age state", () => {
	it("does not create or send a match notification when the counterpart is unverified", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [
				{ data: { timezone: "UTC" }, error: null },
				{ data: [matchingProfile("user-1"), matchingProfile("user-2", null)], error: null },
			],
			"matches:select": [{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null }],
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-03",
			userId: "user-1",
			matchId: "match-1",
			deepLink: "wingward://chat-requests/11111111-1111-4111-8111-111111111111",
			deliveryContext: { request_id: "request-1" },
		});

		expect(result).toEqual({ ok: false, reason: "age_unverified" });
		expect(fetchMock).not.toHaveBeenCalled();
		expect(supabase.calls.some((call) => call.method === "notifications.insert")).toBe(false);
	});

	it("counts deferred age suppression without failure or retry backoff", async () => {
		const row: StatefulNotifRow = {
			id: "notif-deferred-age",
			scenario_id: "N-03",
			user_id: "user-1",
			match_id: "match-1",
			payload: {
				deep_link: "wingward://chat-requests/11111111-1111-4111-8111-111111111111",
				delivery_context: { request_id: "request-1" },
			},
			sent_at: null,
			suppressed_reason: null,
			scheduled_for: "2020-01-01T00:00:00.000Z",
			onesignal_notification_id: null,
		};
		const supabase = makeStatefulNotificationsSupabase([row], {
			ageProfileRows: [
				matchingProfile("user-1"),
				matchingProfile("user-2", null),
			],
		});

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 1, sent: 0, suppressed: 1, failed: 0 });
		expect(row.suppressed_reason).toBe("delivery_precondition_failed");
		expect(row.payload?.deferred_attempts).toBeUndefined();
		expect(fetchMock).not.toHaveBeenCalled();
		// One scheduled_for update is the claim itself; no retry/backoff update
		// is allowed after deliverNow terminally suppresses the row.
		expect(supabase.updates.filter(({ patch }) => "scheduled_for" in patch)).toHaveLength(1);
		expect(supabase.updates.filter(({ patch }) => "deferred_attempts" in patch)).toHaveLength(0);
	});

	it("rechecks the pair in the common delivery sink after the notification row exists", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [
				{ data: { timezone: "UTC" }, error: null },
				{ data: [matchingProfile("user-1"), matchingProfile("user-2")], error: null },
				{ data: [matchingProfile("user-1"), matchingProfile("user-2", null)], error: null },
			],
			"matches:select": [
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
			],
			"notifications:select": [{ data: [], error: null }],
			"blocks:select": [{ data: null, error: null }, { data: null, error: null }],
			"notifications:insert": [{ data: { id: "notif-late-age" }, error: null }],
			"notifications:update": [{ data: [{ id: "notif-late-age" }], error: null }],
		}, {
			finalSnapshot: (filters) => {
				const snapshot = makeFinalSnapshot(filters);
				const match = snapshot.match as Record<string, unknown>;
				const profileB = match.profile_b as Record<string, unknown>;
				profileB.age_verified_at = null;
				return { data: snapshot, error: null };
			},
		});

		const result = await sendNotification(supabase as never, ENV, {
			scenarioId: "N-03",
			userId: "user-1",
			matchId: "match-1",
			deepLink: "wingward://chat-requests/11111111-1111-4111-8111-111111111111",
			deliveryContext: { request_id: "request-1" },
		});

		expect(result).toEqual({ ok: false, notificationId: "notif-late-age", reason: "delivery_precondition_failed" });
		expect(fetchMock).not.toHaveBeenCalled();
		expect(supabase.calls.some((call) => call.method === "notifications.insert")).toBe(true);
		const suppressionUpdate = supabase.calls.find((call) => call.method === "notifications.update");
		expect(suppressionUpdate?.args[0]).toEqual({ suppressed_reason: "delivery_precondition_failed" });
		expect(supabase.calls.some((call) => call.method === "notification_events.insert")).toBe(false);
	});
});

describe("the immediate path revalidates the block right before the outbound call (Codex P0, round 10)", () => {
	const params = {
		scenarioId: "N-03",
		userId: "user-1",
		matchId: "match-1",
		deepLink: "wingward://chat-requests/11111111-1111-4111-8111-111111111111",
		deliveryContext: { request_id: "request-1" },
		now: new Date("2026-06-15T12:00:00.000Z"),
	};

	it("does not call OneSignal when the block appears between the pre-send check and the send", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"matches:select": [
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
			],
			// Clear at the pre-send check; blocked by the time we re-check.
			"blocks:select": [
				{ data: null, error: null },
				{ data: { id: "block-1" }, error: null },
			],
			"notifications:insert": [{ data: { id: "notif-late-block" }, error: null }],
			"notifications:update": [{ data: [{ id: "notif-late-block" }], error: null }],
		}, {
			finalSnapshot: (filters) => {
				const snapshot = makeFinalSnapshot(filters);
				const match = snapshot.match as Record<string, unknown>;
				const profileA = match.profile_a as Record<string, unknown>;
				profileA.blocks_sent = [{ id: "block-1", blocker_id: "user-1", blocked_id: "user-2" }];
				return { data: snapshot, error: null };
			},
		});

		const result = await sendNotification(supabase as never, ENV, params);

		expect(result).toEqual({ ok: false, notificationId: "notif-late-block", reason: "delivery_precondition_failed" });
		expect(fetchMock).not.toHaveBeenCalled();
		// The row exists but is marked terminal, so nothing picks it up later.
		const update = supabase.calls.find((c) => c.method === "notifications.update");
		expect(update?.args[0]).toEqual({ suppressed_reason: "delivery_precondition_failed" });
	});

	it("fails closed when the late re-check itself errors", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"matches:select": [
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
				{ data: { user_a_id: "user-1", user_b_id: "user-2" }, error: null },
			],
			"blocks:select": [
				{ data: null, error: null },
				{ data: null, error: { message: "connection reset" } },
			],
			"notifications:insert": [{ data: { id: "notif-late-error" }, error: null }],
			"notifications:update": [{ data: null, error: null }],
		}, {
			finalSnapshot: () => ({ data: null, error: { message: "embedded snapshot unavailable" } }),
		});

		const result = await sendNotification(supabase as never, ENV, params);

		expect(result).toEqual({ ok: false, notificationId: "notif-late-error", reason: "delivery_check_failed" });
		expect(fetchMock).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});
});


describe("recording rehearsal notification suppression", () => {
	it("keeps external OneSignal delivery closed while any rehearsal binding is present", async () => {
		const supabase = makeSupabaseStub({
			"notification_scenarios:select": [{ data: { quiet_hours_exempt: true, is_enabled: true }, error: null }],
			"user_profiles:select": [{ data: { timezone: "UTC" }, error: null }],
			"notifications:select": [{ data: [], error: null }],
			"notifications:insert": [{ data: { id: "notif-rehearsal" }, error: null }],
		});
		const rehearsalEnv = {
			...ENV,
			RECORDING_REHEARSAL_ENABLED: "enabled",
			RECORDING_REHEARSAL_ISSUED_AT: "2026-09-26T19:30:00.000Z",
			RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T21:30:00.000Z",
			RECORDING_REHEARSAL_PAIR: "aoi-ren",
		};
		const result = await sendNotification(supabase as never, rehearsalEnv, {
			scenarioId: "N-13",
			userId: "user-1",
			deepLink: "wingward://availability",
			now: new Date("2026-09-26T20:00:00.000Z"),
		});
		expect(result).toEqual({ ok: false, notificationId: "notif-rehearsal", reason: "delivery_precondition_failed" });
		expect(fetchMock).not.toHaveBeenCalled();
	});
});
