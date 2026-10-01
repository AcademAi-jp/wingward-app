import { Hono } from "hono";
import { describe, expect, it, vi, beforeEach } from "vitest";

/**
 * Route-level coverage for POST /api/notification-events (A-4's API-layer
 * half; the DB/RLS half is supabase/tests/07_notification_events_insert_isolation.sql).
 * step-04-notifications.md §5's "test where the regression actually
 * happens" — this exercises the route handler, not just a unit under it.
 */

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "user-caller");
		await next();
	},
}));

interface FakeNotificationRow {
	id: string;
	user_id: string;
}

function makeFakeSupabase(opts: { notification: FakeNotificationRow | null; insertError?: { message: string } | null }) {
	return {
		from: (table: string) => {
			if (table === "notifications") {
				return {
					select: () => ({
						eq: () => ({
							single: async () => ({ data: opts.notification, error: opts.notification ? null : { message: "not found" } }),
						}),
					}),
				};
			}
			if (table === "notification_events") {
				return {
					insert: () => ({
						select: () => ({
							single: async () =>
								opts.insertError
									? { data: null, error: opts.insertError }
									: { data: { id: "event-1" }, error: null },
						}),
					}),
				};
			}
			throw new Error(`unexpected table in test fake: ${table}`);
		},
	};
}

vi.mock("../db/client", () => ({
	getSupabaseClient: vi.fn(),
}));

import { getSupabaseClient } from "../db/client";
import { errorHandler } from "../middleware/error";
import notificationEvents from "./notification-events";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

function buildApp() {
	const app = new Hono();
	app.onError(errorHandler); // mirrors app.ts's global wiring, so ZodError -> 400 behaves the same as production
	app.route("/api/notification-events", notificationEvents);
	return app;
}

function post(body: unknown) {
	const app = buildApp();
	return app.request("/api/notification-events", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(body),
	});
}

const NOTIF_ID = "11111111-1111-1111-1111-111111111111";

beforeEach(() => {
	mockedGetSupabaseClient.mockReset();
});

describe("POST /api/notification-events", () => {
	it("A-4: rejects an event reported against someone else's notification_id with the SAME response as a nonexistent notification_id (P2-a: no existence oracle)", async () => {
		const consoleWarnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "someone-else" } }) as never,
		);

		const res = await post({ notification_id: NOTIF_ID, event_type: "opened" });
		const body = (await res.json()) as { error: { code: string; message: string } };

		expect(res.status).toBe(404);
		expect(body.error.code).toBe("NOT_FOUND");
		expect(body).toEqual({ error: { code: "NOT_FOUND", message: "Notification not found" } });
		// The distinction (exists-but-not-mine vs. never-existed) is only logged server-side.
		expect(consoleWarnSpy).toHaveBeenCalled();
		consoleWarnSpy.mockRestore();
	});

	it("a nonexistent notification_id produces byte-for-byte the same response body as someone else's notification_id", async () => {
		vi.spyOn(console, "warn").mockImplementation(() => {});

		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "someone-else" } }) as never,
		);
		const forbiddenShaped = await post({ notification_id: NOTIF_ID, event_type: "opened" });
		const forbiddenBody = await forbiddenShaped.text();

		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ notification: null }) as never);
		const missing = await post({ notification_id: NOTIF_ID, event_type: "opened" });
		const missingBody = await missing.text();

		expect(forbiddenShaped.status).toBe(missing.status);
		expect(forbiddenBody).toBe(missingBody);

		vi.restoreAllMocks();
	});

	it("accepts an event reported against the caller's own notification_id", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "user-caller" } }) as never,
		);

		const res = await post({ notification_id: NOTIF_ID, event_type: "opened" });
		const body = (await res.json()) as { data: { id: string } };

		expect(res.status).toBe(201);
		expect(body.data).toEqual({ id: "event-1" });
	});

	it("returns NOT_FOUND for a notification_id that doesn't exist", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeFakeSupabase({ notification: null }) as never);

		const res = await post({ notification_id: NOTIF_ID, event_type: "opened" });
		expect(res.status).toBe(404);
	});

	it("rejects an event_type outside the CHECK constraint's client-reportable set", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "user-caller" } }) as never,
		);

		const res = await post({ notification_id: NOTIF_ID, event_type: "not_a_real_event_type" });
		expect(res.status).toBe(400);
	});

	it("rejects event_type 'sent' from a client — that value is written only by the send pipeline itself", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "user-caller" } }) as never,
		);

		const res = await post({ notification_id: NOTIF_ID, event_type: "sent" });
		expect(res.status).toBe(400);
	});

	it("does not reflect a raw DB error message when the event insert fails (PR #26 lesson)", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({
				notification: { id: NOTIF_ID, user_id: "user-caller" },
				insertError: { message: "duplicate key value violates unique constraint PWNED-CANARY-EVENTS" },
			}) as never,
		);

		const res = await post({ notification_id: NOTIF_ID, event_type: "opened" });
		const bodyText = await res.text();

		expect(res.status).toBe(500);
		expect(bodyText).not.toContain("PWNED-CANARY-EVENTS");
		expect(JSON.parse(bodyText)).toEqual({ error: { code: "INTERNAL_ERROR", message: "Failed to record event" } });
		consoleErrorSpy.mockRestore();
	});

	it("rejects a notification_id that isn't a UUID", async () => {
		const res = await post({ notification_id: "not-a-uuid", event_type: "opened" });
		expect(res.status).toBe(400);
	});

	it("returns BAD_REQUEST (not a 500) for a malformed JSON body, without throwing (P2-b)", async () => {
		const app = buildApp();
		const res = await app.request("/api/notification-events", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: "{not valid json",
		});

		expect(res.status).toBe(400);
		const body = (await res.json()) as { error: { code: string } };
		expect(body.error.code).toBe("BAD_REQUEST");
	});

	it("rejects metadata with too many keys (P2-c/finding #3)", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "user-caller" } }) as never,
		);

		const tooManyKeys: Record<string, string> = {};
		for (let i = 0; i < 25; i++) tooManyKeys[`key_${i}`] = "v";

		const res = await post({ notification_id: NOTIF_ID, event_type: "opened", metadata: tooManyKeys });
		expect(res.status).toBe(400);
	});

	it("rejects metadata with an oversized value (finding #3)", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "user-caller" } }) as never,
		);

		const res = await post({
			notification_id: NOTIF_ID,
			event_type: "opened",
			metadata: { note: "x".repeat(600) }, // over METADATA_MAX_VALUE_STRING_LENGTH (500)
		});
		expect(res.status).toBe(400);
	});

	it("rejects metadata whose total serialized size is over the byte cap even with few keys", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "user-caller" } }) as never,
		);

		// 10 keys x 500-char values = comfortably under the key cap (20) but
		// well over the 4000-byte serialized cap.
		const bigButFewKeys: Record<string, string> = {};
		for (let i = 0; i < 10; i++) bigButFewKeys[`k${i}`] = "x".repeat(500);

		const res = await post({ notification_id: NOTIF_ID, event_type: "opened", metadata: bigButFewKeys });
		expect(res.status).toBe(400);
	});

	it("rejects metadata with a nested object value (flat primitives only)", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "user-caller" } }) as never,
		);

		const res = await post({
			notification_id: NOTIF_ID,
			event_type: "opened",
			metadata: { nested: { a: 1 } },
		});
		expect(res.status).toBe(400);
	});

	it("accepts metadata within all bounds", async () => {
		mockedGetSupabaseClient.mockReturnValue(
			makeFakeSupabase({ notification: { id: NOTIF_ID, user_id: "user-caller" } }) as never,
		);

		const res = await post({
			notification_id: NOTIF_ID,
			event_type: "opened",
			metadata: { source: "push", count: 3, ok: true, note: null },
		});
		expect(res.status).toBe(201);
	});
});
