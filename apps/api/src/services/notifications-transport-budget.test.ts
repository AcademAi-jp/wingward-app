import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { DEFAULT_DEFERRED_SEND_LIMIT, sendDeferredNotifications } from "./notifications";
import { MATCHING_ELIGIBILITY_COLUMNS } from "./matching-eligibility";

/**
 * This is a Node transport measurement, not a Cloudflare Worker limit test.
 * The production Supabase JS client is real; only fetch is synthetic and
 * stateful. Database dispatches and intercepted OneSignal dispatches are
 * counted separately for each invocation. The explicit `limit` override can
 * exceed the Worker budget; these tests intentionally measure the default 4
 * row limit without changing production policy.
 */

const SUPABASE_URL = "https://synthetic.supabase.invalid";
const SUPABASE_SERVICE_ROLE_KEY = "synthetic-service-role-key";
const ONESIGNAL_API_ORIGIN = "https://api.onesignal.com";
const SYNTHETIC_ONESIGNAL_APP_ID = "synthetic-onesignal-app";
const SYNTHETIC_ONESIGNAL_API_KEY = "synthetic-onesignal-key";
const MATCH_ID = "22222222-2222-4222-8222-222222222222";
const USER_A = "33333333-3333-4333-8333-333333333333";
const USER_B = "44444444-4444-4444-8444-444444444444";
const CONVERSATION_ID = "11111111-1111-4111-8111-111111111111";
const FOREIGN_NOTIFICATION_ID = "66666666-6666-4666-8666-666666666666";
const NOW = "2026-09-06T12:00:00.000Z";
const DEEP_LINK = `wingward://match/${MATCH_ID}/fox-result`;

const NOTIFICATION_IDS = [
	"55555555-5555-4555-8555-555555555551",
	"55555555-5555-4555-8555-555555555552",
	"55555555-5555-4555-8555-555555555553",
	"55555555-5555-4555-8555-555555555554",
] as const;

type NotificationRow = {
	id: string;
	scenario_id: string;
	user_id: string;
	match_id: string | null;
	payload: { deep_link: string; delivery_context?: { conversation_id: string } };
	onesignal_notification_id: string | null;
	/** Distinct stale windows make these four saved rows a possible DB state;
	 * the deferred executor does not select this column. */
	dedup_window_start: string;
	scheduled_for: string | null;
	sent_at: string | null;
	suppressed_reason: string | null;
};

type EventRow = {
	id: string;
	notification_id: string;
	user_id: string;
	event_type: string;
	occurred_at: string;
};

type InvocationLedger = {
	databaseRequests: number;
	providerRequests: number;
	byTable: Record<string, number>;
};

type AdapterOptions = {
	rows: NotificationRow[];
	events?: EventRow[];
};

type SupabaseFetchAdapter = {
	fetch: typeof globalThis.fetch;
	beginInvocation: () => void;
	invocations: InvocationLedger[];
	errors: string[];
	rows: NotificationRow[];
	events: EventRow[];
	oneSignalRequests: Array<{ body: Record<string, unknown>; status: number }>;
	notificationUpdates: Array<{ id: string; patch: Record<string, unknown> }>;
};

const DUE_SELECT = "id, scenario_id, user_id, match_id, meetup_id, payload, onesignal_notification_id, scheduled_for";
const STILL_LIVE_SELECT = "id";
const MATCH_BLOCK_SELECT = "user_a_id, user_b_id";
const MATCH_AGE_SELECT = "id, user_a_id, user_b_id";

function jsonResponse(data: unknown, status = 200): Response {
	return new Response(JSON.stringify(data), {
		status,
		headers: { "content-type": "application/json" },
	});
}

function emptyResponse(status = 201): Response {
	return new Response(null, { status });
}

function adapterError(errors: string[], message: string): Error {
	errors.push(message);
	return new Error(message);
}

function eqFilter(url: URL, column: string): string | null {
	const value = url.searchParams.get(column);
	return value?.startsWith("eq.") ? value.slice(3) : null;
}

function inFilter(url: URL, column: string): string[] | null {
	const value = url.searchParams.get(column);
	if (!value?.startsWith("in.(") || !value.endsWith(")")) return null;
	return value.slice(4, -1).split(",").map((entry) => entry.replace(/^"|"$/g, ""));
}

function isObjectResponse(request: Request): boolean {
	return request.headers.get("accept")?.includes("application/vnd.pgrst.object+json") === true;
}

function normalizeSelect(value: string): string {
	return value.replace(/\s+/g, "");
}

function sameQuery(url: URL, expected: Record<string, string | readonly string[]>): boolean {
	const actualKeys = [...new Set([...url.searchParams.keys()])].sort();
	const expectedKeys = Object.keys(expected).sort();
	return (
		actualKeys.length === expectedKeys.length &&
		actualKeys.every((key, index) => key === expectedKeys[index]) &&
		Object.entries(expected).every(([key, expectedValue]) => {
			const actualValues = url.searchParams.getAll(key);
			const expectedValues = Array.isArray(expectedValue) ? expectedValue : [expectedValue];
			return (
				actualValues.length === expectedValues.length &&
				actualValues.every((value, index) => key === "select" ? normalizeSelect(value) === normalizeSelect(expectedValues[index]) : value === expectedValues[index])
			);
		})
	);
}

function matchingProfiles(): Array<Record<string, unknown>> {
	return [
		{
			id: USER_A,
			age_verified_at: "2026-09-05T00:00:00.000Z",
			gender_identity: "woman",
			preferred_genders: ["man"],
			preference_mode: "selected",
			dating_market: "JP",
			onboarding_settings_completed_at: "2026-09-05T00:00:00.000Z",
		},
		{
			id: USER_B,
			age_verified_at: "2026-09-05T00:00:00.000Z",
			gender_identity: "man",
			preferred_genders: ["woman"],
			preference_mode: "selected",
			dating_market: "JP",
			onboarding_settings_completed_at: "2026-09-05T00:00:00.000Z",
		},
	];
}

function makeRows(options?: { onesignalIds?: boolean }): NotificationRow[] {
	return NOTIFICATION_IDS.map((id, index) => ({
		id,
		scenario_id: "N-01",
		user_id: USER_A,
		match_id: MATCH_ID,
		payload: { deep_link: DEEP_LINK, delivery_context: { conversation_id: CONVERSATION_ID } },
		onesignal_notification_id: options?.onesignalIds ? `onesignal-existing-${index + 1}` : null,
		// The executor's due SELECT intentionally omits dedup_window_start.
		// Keep each persisted fixture row in a distinct old 24h window so the
		// four rows represent a state the notifications constraints can store.
		dedup_window_start: `2026-09-0${index + 1}T10:00:00.000Z`,
		scheduled_for: "2026-09-06T10:00:00.000Z",
		sent_at: null,
		suppressed_reason: null,
	}));
}

function makeForeignEvents(rows: NotificationRow[]): EventRow[] {
	return rows.map((row) => ({
		id: row.id,
		notification_id: FOREIGN_NOTIFICATION_ID,
		user_id: USER_B,
		event_type: "opened",
		occurred_at: "2026-09-06T11:00:00.000Z",
	}));
}

function makeExistingSentEvents(rows: NotificationRow[]): EventRow[] {
	return rows.map((row, index) => ({
		id: `77777777-7777-4777-8777-77777777777${index + 1}`,
		notification_id: row.id,
		user_id: row.user_id,
		event_type: "sent",
		occurred_at: "2026-09-06T11:30:00.000Z",
	}));
}

function makeSupabaseFetchAdapter(options: AdapterOptions): SupabaseFetchAdapter {
	const rows = options.rows.map((row) => ({ ...row, payload: { ...row.payload } }));
	const events = options.events?.map((event) => ({ ...event })) ?? [];
	const invocations: InvocationLedger[] = [];
	const errors: string[] = [];
	const oneSignalRequests: Array<{ body: Record<string, unknown>; status: number }> = [];
	const notificationUpdates: Array<{ id: string; patch: Record<string, unknown> }> = [];
	let currentInvocation = -1;
	let fallbackEventNumber = 0;

	function recordDatabaseRequest(table: string, request: Request, url: URL): void {
		if (currentInvocation < 0) throw adapterError(errors, "synthetic fetch used before beginInvocation()");
		const invocation = invocations[currentInvocation];
		invocation.databaseRequests++;
		invocation.byTable[table] = (invocation.byTable[table] ?? 0) + 1;
		if (!["GET", "PATCH", "POST"].includes(request.method)) {
			throw adapterError(errors, `unsupported Supabase method ${request.method} ${url.pathname}`);
		}
		if (
			request.headers.get("apikey") !== SUPABASE_SERVICE_ROLE_KEY ||
			request.headers.get("authorization") !== `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`
		) {
			throw adapterError(errors, `Supabase auth header mismatch ${request.method} ${url.search}`);
		}
	}

	async function readBody(request: Request): Promise<unknown> {
		const raw = await request.text();
		if (!raw) return null;
		try {
			return JSON.parse(raw);
		} catch {
			throw adapterError(errors, `malformed JSON body ${request.url}`);
		}
	}

	function responseForNotificationUpdate(url: URL, body: unknown): Response {
		if (typeof body !== "object" || body === null || Array.isArray(body)) {
			throw adapterError(errors, `notifications PATCH body mismatch ${url.search}`);
		}
		if (
			!sameQuery(url, {
				select: STILL_LIVE_SELECT,
				id: url.searchParams.get("id") ?? "",
				scheduled_for: url.searchParams.get("scheduled_for") ?? "",
			}) ||
			url.searchParams.get("id")?.startsWith("eq.") !== true ||
			url.searchParams.get("scheduled_for")?.startsWith("eq.") !== true
		) {
			throw adapterError(errors, `notifications PATCH select/id mismatch ${url.search}`);
		}
		const id = eqFilter(url, "id");
		const fencingToken = eqFilter(url, "scheduled_for");
		if (!id || !fencingToken) throw adapterError(errors, `notifications PATCH fencing mismatch ${url.search}`);
		const row = rows.find((candidate) => candidate.id === id && candidate.scheduled_for === fencingToken);
		if (!row) return jsonResponse([]);
		const patch = body as Record<string, unknown>;
		const patchKeys = Object.keys(patch).sort();
		if (
			patchKeys.length !== 1 ||
			!patchKeys.every((key) => ["scheduled_for", "onesignal_notification_id", "sent_at"].includes(key)) ||
			typeof patch[patchKeys[0]] !== "string"
		) {
			throw adapterError(errors, `notifications PATCH fields mismatch ${url.search}`);
		}
		Object.assign(row, patch);
		notificationUpdates.push({ id, patch: { ...patch } });
		return jsonResponse([{ id }]);
	}

	const fetch: typeof globalThis.fetch = async (input, init) => {
		const request = new Request(input, init);
		const url = new URL(request.url);
		const body = request.method === "GET" ? null : await readBody(request);

		if (url.origin === ONESIGNAL_API_ORIGIN) {
			if (
				request.method !== "POST" ||
				url.pathname !== "/notifications" ||
				url.search !== "" ||
				(request.headers.get("authorization") ?? "") !== `Key ${SYNTHETIC_ONESIGNAL_API_KEY}` ||
				(request.headers.get("content-type") ?? "").toLowerCase() !== "application/json" ||
				typeof body !== "object" ||
				body === null ||
				Array.isArray(body)
			) {
				throw adapterError(errors, `OneSignal request mismatch ${request.method} ${url}`);
			}
			const oneSignalBody = body as Record<string, unknown>;
			const aliases = oneSignalBody.include_aliases;
			const data = oneSignalBody.data;
			const externalIds =
				typeof aliases === "object" && aliases !== null && Array.isArray((aliases as Record<string, unknown>).external_id)
					? ((aliases as Record<string, unknown>).external_id as unknown[])
					: null;
			if (
				oneSignalBody.app_id !== SYNTHETIC_ONESIGNAL_APP_ID ||
				typeof oneSignalBody.idempotency_key !== "string" ||
				oneSignalBody.target_channel !== "push" ||
				!externalIds ||
				externalIds.length !== 1 ||
				externalIds[0] !== USER_A ||
				typeof oneSignalBody.headings !== "object" ||
				typeof oneSignalBody.contents !== "object" ||
				typeof data !== "object" ||
				data === null ||
				(data as Record<string, unknown>).scenario_id !== "N-01" ||
				(data as Record<string, unknown>).notification_id !== oneSignalBody.idempotency_key ||
				(data as Record<string, unknown>).deep_link !== DEEP_LINK
			) {
				throw adapterError(errors, "OneSignal body mismatch");
			}
			currentInvocation >= 0 && invocations[currentInvocation].providerRequests++;
			const response = { id: `synthetic-onesignal-${oneSignalBody.idempotency_key}`, recipients: 1 };
			oneSignalRequests.push({ body: { ...oneSignalBody }, status: 200 });
			return jsonResponse(response);
		}

		if (url.origin !== SUPABASE_URL) throw adapterError(errors, `unexpected origin ${url.origin}`);
		const pathMatch = url.pathname.match(/^\/rest\/v1\/([^/]+)$/);
		if (!pathMatch) throw adapterError(errors, `unknown Supabase path ${url.pathname}`);
		const table = decodeURIComponent(pathMatch[1]);
		recordDatabaseRequest(table, request, url);

		if (table === "notifications" && request.method === "GET") {
			const select = url.searchParams.get("select");
			if (select?.includes("scenario:notification_scenarios")) {
				const notificationId = eqFilter(url, "id");
				const fencingToken = eqFilter(url, "scheduled_for");
				if (
					!notificationId ||
					!fencingToken ||
					!sameQuery(url, {
						select: select ?? "",
						id: `eq.${notificationId}`,
						scenario_id: "eq.N-01",
						user_id: `eq.${USER_A}`,
						"payload->>deep_link": `eq.${DEEP_LINK}`,
						sent_at: "is.null",
						suppressed_reason: "is.null",
						onesignal_notification_id: "is.null",
						match_id: `eq.${MATCH_ID}`,
						meetup_id: "is.null",
						scheduled_for: `eq.${fencingToken}`,
						"match.user_a_id": `eq.${USER_A}`,
						"match.user_b_id": `eq.${USER_B}`,
						"match.profile_a.blocks_sent.blocked_id": `eq.${USER_B}`,
						"match.profile_b.blocks_sent.blocked_id": `eq.${USER_A}`,
						"match.compatibility_conversations.purpose": "eq.compatibility",
						"payload->delivery_context->>conversation_id": `eq.${CONVERSATION_ID}`,
					})
				) {
					throw adapterError(errors, `notifications final snapshot query mismatch ${url.search}`);
				}
				const row = rows.find((candidate) => candidate.id === notificationId && candidate.scheduled_for === fencingToken && candidate.sent_at === null && candidate.suppressed_reason === null && candidate.onesignal_notification_id === null);
				if (!row) return new Response(JSON.stringify({ code: "PGRST116", message: "row not found" }), { status: 406, headers: { "content-type": "application/json" } });
				const [profileA, profileB] = matchingProfiles();
				return jsonResponse({
					id: row.id,
					scenario_id: row.scenario_id,
					user_id: row.user_id,
					match_id: row.match_id,
					meetup_id: null,
					payload: row.payload,
					scheduled_for: row.scheduled_for,
					sent_at: row.sent_at,
					suppressed_reason: row.suppressed_reason,
					onesignal_notification_id: row.onesignal_notification_id,
					scenario: { scenario_id: "N-01", is_enabled: true },
					match: {
						id: MATCH_ID,
						user_a_id: USER_A,
						user_b_id: USER_B,
						status: "direct_chat_requested",
						profile_a: { ...profileA, blocks_sent: [] },
						profile_b: { ...profileB, blocks_sent: [] },
						compatibility_conversations: [{ id: CONVERSATION_ID, match_id: MATCH_ID, purpose: "compatibility", status: "completed" }],
						chat_requests: [],
						direct_room: [],
					},
					meetup: null,
				});
			}
			if (select !== null && normalizeSelect(select) === normalizeSelect(DUE_SELECT)) {
				const scheduledFilters = url.searchParams.getAll("scheduled_for");
				const lteValue = scheduledFilters.find((value) => value.startsWith("lte."));
				if (
					!sameQuery(url, {
						select: DUE_SELECT,
						sent_at: "is.null",
						suppressed_reason: "is.null",
						scheduled_for: ["not.is.null", lteValue ?? ""],
						order: "scheduled_for.asc",
						limit: String(DEFAULT_DEFERRED_SEND_LIMIT),
					}) ||
					scheduledFilters.length !== 2 ||
					!scheduledFilters.includes("not.is.null") ||
					!lteValue
				) {
					throw adapterError(errors, `notifications due query mismatch ${url.search}`);
				}
				const now = lteValue.slice(4);
				const dueRows = rows
					.filter(
						(row) =>
							row.sent_at === null &&
							row.suppressed_reason === null &&
							row.scheduled_for !== null &&
							row.scheduled_for <= now,
					)
					.sort((a, b) => (a.scheduled_for ?? "").localeCompare(b.scheduled_for ?? ""))
					.slice(0, DEFAULT_DEFERRED_SEND_LIMIT)
					.map((row) => ({
						id: row.id,
						scenario_id: row.scenario_id,
						user_id: row.user_id,
						match_id: row.match_id,
						meetup_id: null,
						payload: row.payload,
						onesignal_notification_id: row.onesignal_notification_id,
						scheduled_for: row.scheduled_for,
					}));
				return jsonResponse(dueRows);
			}
			if (
				normalizeSelect(select ?? "") !== normalizeSelect(STILL_LIVE_SELECT) ||
				!sameQuery(url, {
					select: STILL_LIVE_SELECT,
					id: url.searchParams.get("id") ?? "",
					scheduled_for: url.searchParams.get("scheduled_for") ?? "",
					suppressed_reason: "is.null",
					sent_at: "is.null",
					limit: "1",
				}) ||
				!eqFilter(url, "id") ||
				!eqFilter(url, "scheduled_for")
			) {
				throw adapterError(errors, `notifications re-read mismatch ${url.search}`);
			}
			const row = rows.find(
				(candidate) =>
					candidate.id === eqFilter(url, "id") &&
					candidate.scheduled_for === eqFilter(url, "scheduled_for") &&
					candidate.suppressed_reason === null &&
					candidate.sent_at === null,
			);
			return jsonResponse(row ? [{ id: row.id }] : []);
		}

		if (table === "notifications" && request.method === "PATCH") {
			if (normalizeSelect(url.searchParams.get("select") ?? "") !== normalizeSelect(STILL_LIVE_SELECT)) {
				throw adapterError(errors, `notifications PATCH must select id ${url.search}`);
			}
			return responseForNotificationUpdate(url, body);
		}

		if (table === "matches" && request.method === "GET") {
			const select = url.searchParams.get("select");
			if (
				!sameQuery(url, { select: select ?? "", id: url.searchParams.get("id") ?? "" }) ||
				!isObjectResponse(request) ||
				eqFilter(url, "id") !== MATCH_ID
			) {
				throw adapterError(errors, `matches query identity mismatch ${url.search}`);
			}
			if (select !== null && normalizeSelect(select) === normalizeSelect(MATCH_BLOCK_SELECT)) {
				return jsonResponse({ user_a_id: USER_A, user_b_id: USER_B });
			}
			if (select !== null && normalizeSelect(select) === normalizeSelect(MATCH_AGE_SELECT)) {
				return jsonResponse({ id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B });
			}
			throw adapterError(errors, `matches select mismatch ${url.search}`);
		}

		if (table === "blocks" && request.method === "GET") {
			const expectedOr = `(and(blocker_id.eq.${USER_A},blocked_id.eq.${USER_B}),and(blocker_id.eq.${USER_B},blocked_id.eq.${USER_A}))`;
			if (
				!sameQuery(url, { select: "id", or: expectedOr, limit: "1" })
			) {
				throw adapterError(errors, `blocks query mismatch ${url.search}`);
			}
			return jsonResponse([]);
		}

		if (table === "user_profiles" && request.method === "GET") {
			if (
				!sameQuery(url, { select: MATCHING_ELIGIBILITY_COLUMNS, id: url.searchParams.get("id") ?? "" }) ||
				normalizeSelect(url.searchParams.get("select") ?? "") !== normalizeSelect(MATCHING_ELIGIBILITY_COLUMNS) ||
				JSON.stringify(inFilter(url, "id")) !== JSON.stringify([USER_A, USER_B])
			) {
				throw adapterError(errors, `profile query mismatch ${url.search}`);
			}
			return jsonResponse(matchingProfiles());
		}

		if (table === "notification_events" && request.method === "GET") {
			if (
				!sameQuery(url, {
					select: "id",
					notification_id: url.searchParams.get("notification_id") ?? "",
					event_type: "eq.sent",
					limit: "1",
				}) ||
				!eqFilter(url, "notification_id")
			) {
				throw adapterError(errors, `sent-event identity query mismatch ${url.search}`);
			}
			const notificationId = eqFilter(url, "notification_id");
			return jsonResponse(events.filter((event) => event.notification_id === notificationId && event.event_type === "sent").slice(0, 1).map((event) => ({ id: event.id })));
		}

		if (table === "notification_events" && request.method === "POST") {
			if (!sameQuery(url, {}) || typeof body !== "object" || body === null || Array.isArray(body)) {
				throw adapterError(errors, `sent-event insert body mismatch ${url.search}`);
			}
			const event = body as Record<string, unknown>;
			const notificationId = event.notification_id;
			const notification = rows.find((row) => row.id === notificationId);
			if (
				typeof notificationId !== "string" ||
				!notification ||
				event.user_id !== notification.user_id ||
				event.event_type !== "sent" ||
				typeof event.occurred_at !== "string"
			) {
				throw adapterError(errors, "sent-event insert identity mismatch");
			}
			const suppliedId = event.id;
			if (typeof suppliedId === "string") {
				if (events.some((candidate) => candidate.id === suppliedId) || events.some((candidate) => candidate.notification_id === notificationId && candidate.event_type === "sent")) {
					return jsonResponse({ code: "23505", message: "duplicate key value violates unique constraint" }, 409);
				}
				events.push({
					id: suppliedId,
					notification_id: notificationId,
					user_id: notification.user_id,
					event_type: "sent",
					occurred_at: event.occurred_at,
				});
				return emptyResponse();
			}
			fallbackEventNumber++;
			if (events.some((candidate) => candidate.notification_id === notificationId && candidate.event_type === "sent")) {
				return jsonResponse({ code: "23505", message: "duplicate key value violates unique constraint" }, 409);
			}
			const fallbackId = `88888888-8888-4888-8888-${String(fallbackEventNumber).padStart(12, "0")}`;
			events.push({
				id: fallbackId,
				notification_id: notificationId,
				user_id: notification.user_id,
				event_type: "sent",
				occurred_at: event.occurred_at,
			});
			return emptyResponse();
		}

		throw adapterError(errors, `unknown Supabase table/method ${request.method} ${table} ${url.search}`);
	};

	return {
		fetch,
		beginInvocation() {
			currentInvocation++;
			invocations.push({ databaseRequests: 0, providerRequests: 0, byTable: {} });
		},
		invocations,
		errors,
		rows,
		events,
		oneSignalRequests,
		notificationUpdates,
	};
}

function installSyntheticTransport(adapter: SupabaseFetchAdapter): void {
	vi.stubGlobal("fetch", adapter.fetch);
}

function makeSupabase() {
	return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
		auth: { persistSession: false },
	});
}

const ENV = {
	ONESIGNAL_APP_ID: SYNTHETIC_ONESIGNAL_APP_ID,
	ONESIGNAL_API_KEY: SYNTHETIC_ONESIGNAL_API_KEY,
};

beforeEach(() => {
	vi.useFakeTimers();
	vi.setSystemTime(new Date(NOW));
});

afterEach(() => {
	vi.useRealTimers();
	vi.unstubAllGlobals();
});

describe("sendDeferredNotifications transport budget", () => {
	it("measures the default four-row successful path with real Supabase JS and intercepted OneSignal", async () => {
		const adapter = makeSupabaseFetchAdapter({ rows: makeRows() });
		installSyntheticTransport(adapter);
		const supabase = makeSupabase();
		adapter.beginInvocation();

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 4, sent: 4, suppressed: 0, failed: 0 });
		expect(adapter.invocations).toHaveLength(1);
		expect(adapter.invocations[0]).toEqual({
			databaseRequests: 37,
			providerRequests: 4,
			byTable: {
				notifications: 21,
				matches: 8,
				blocks: 4,
				notification_events: 4,
			},
		});
		expect(adapter.invocations[0].databaseRequests + adapter.invocations[0].providerRequests).toBe(41);
		expect(adapter.oneSignalRequests).toHaveLength(4);
		expect(adapter.oneSignalRequests.every((request) => request.status === 200)).toBe(true);
		expect(adapter.rows.every((row) => row.sent_at !== null && row.onesignal_notification_id?.startsWith("synthetic-onesignal-"))).toBe(true);
		expect(adapter.events).toHaveLength(4);
		expect(adapter.events.every((event) => event.event_type === "sent" && event.notification_id === event.id)).toBe(true);
		expect(adapter.notificationUpdates).toHaveLength(12);
		expect(adapter.errors).toEqual([]);
	});

	it("measures four foreign sent-event ID collisions through identity checks and fallback inserts", async () => {
		const rows = makeRows();
		const adapter = makeSupabaseFetchAdapter({ rows, events: makeForeignEvents(rows) });
		installSyntheticTransport(adapter);
		const supabase = makeSupabase();
		adapter.beginInvocation();

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 4, sent: 4, suppressed: 0, failed: 0 });
		expect(adapter.invocations[0]).toEqual({
			databaseRequests: 45,
			providerRequests: 4,
			byTable: {
				notifications: 21,
				matches: 8,
				blocks: 4,
				notification_events: 12,
			},
		});
		expect(adapter.invocations[0].databaseRequests + adapter.invocations[0].providerRequests).toBe(49);
		expect(adapter.oneSignalRequests).toHaveLength(4);
		expect(adapter.events).toHaveLength(8);
		for (const row of adapter.rows) {
			const foreign = adapter.events.find((event) => event.id === row.id);
			const sent = adapter.events.find((event) => event.notification_id === row.id && event.event_type === "sent");
			expect(foreign).toMatchObject({ notification_id: FOREIGN_NOTIFICATION_ID, event_type: "opened" });
			expect(sent).toBeDefined();
			expect(sent?.id).not.toBe(row.id);
			expect(row.sent_at).not.toBeNull();
		}
		expect(adapter.notificationUpdates).toHaveLength(12);
		expect(adapter.errors).toEqual([]);
	});

	it("repairs four already-accepted rows without another OneSignal request", async () => {
		const rows = makeRows({ onesignalIds: true });
		const adapter = makeSupabaseFetchAdapter({ rows, events: makeExistingSentEvents(rows) });
		installSyntheticTransport(adapter);
		const supabase = makeSupabase();
		adapter.beginInvocation();

		const result = await sendDeferredNotifications(supabase as never, ENV);

		expect(result).toEqual({ processed: 4, sent: 4, suppressed: 0, failed: 0 });
		expect(adapter.invocations[0]).toEqual({
			databaseRequests: 17,
			providerRequests: 0,
			byTable: {
				notifications: 9,
				notification_events: 8,
			},
		});
		expect(adapter.oneSignalRequests).toHaveLength(0);
		expect(adapter.events).toHaveLength(4);
		expect(adapter.events.every((event) => event.event_type === "sent")).toBe(true);
		expect(adapter.rows.every((row) => row.sent_at !== null && row.onesignal_notification_id !== null)).toBe(true);
		expect(adapter.notificationUpdates).toHaveLength(8);
		expect(adapter.errors).toEqual([]);
	});
});
