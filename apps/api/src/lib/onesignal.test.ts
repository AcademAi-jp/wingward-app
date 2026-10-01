import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sendOneSignalNotification, setOneSignalTags } from "./onesignal";

/**
 * Unit coverage for the OneSignal REST wrapper, with the HTTP layer mocked
 * (step-04-notifications.md §6: "A-1〜A-6 はすべて、OneSignal への実送信なしに検証
 * できるよう設計する"). No real API key is used anywhere in this file.
 *
 * URLs asserted below (https://api.onesignal.com/...) match OneSignal's
 * current official docs, confirmed 2026-08-19 — see lib/onesignal.ts's
 * module doc comment for the citations.
 */

function jsonResponse(status: number, body: unknown) {
	return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
	fetchMock = vi.fn();
	vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe("sendOneSignalNotification", () => {
	it("addresses via External ID alias + target_channel push, and sends only scenario_id/notification_id/deep_link in `data` (A-5)", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(200, { id: "onesignal-id-1", recipients: 1 }));

		await sendOneSignalNotification({
			appId: "test-app-id",
			apiKey: "test-key-not-real",
			externalUserId: "user-profile-uuid-1",
			heading: "Wingward",
			content: "There's something new for you to see.",
			data: { scenario_id: "N-01", notification_id: "notif-1", deep_link: "wingward://match/x/fox-result" },
		});

		expect(fetchMock).toHaveBeenCalledTimes(1);
		const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		expect(url).toBe("https://api.onesignal.com/notifications");
		const sentBody = JSON.parse(init.body as string);

		expect(sentBody.include_aliases).toEqual({ external_id: ["user-profile-uuid-1"] });
		expect(sentBody.target_channel).toBe("push");
		expect(Object.keys(sentBody.data).sort()).toEqual(["deep_link", "notification_id", "scenario_id"]);
		expect(sentBody.data).toEqual({
			scenario_id: "N-01",
			notification_id: "notif-1",
			deep_link: "wingward://match/x/fox-result",
		});

		// No PII anywhere in the assembled body: no name/message-body/location keys.
		const serialized = JSON.stringify(sentBody);
		expect(serialized).not.toMatch(/name|message|location|address/i);
	});

	it("sends idempotency_key = our own notification_id (finding #1: prevents duplicate sends on retry)", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(200, { id: "onesignal-id-idem", recipients: 1 }));

		await sendOneSignalNotification({
			appId: "app",
			apiKey: "key",
			externalUserId: "user-1",
			heading: "h",
			content: "c",
			data: { scenario_id: "N-01", notification_id: "notif-idem-1", deep_link: "wingward://availability" },
		});

		const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		const sentBody = JSON.parse(init.body as string);
		expect(sentBody.idempotency_key).toBe("notif-idem-1");
	});

	it("returns ok:true with recipients from a successful response", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(200, { id: "onesignal-id-2", recipients: 1 }));
		const result = await sendOneSignalNotification({
			appId: "app",
			apiKey: "key",
			externalUserId: "user-1",
			heading: "h",
			content: "c",
			data: { scenario_id: "N-01", notification_id: "n-1", deep_link: "wingward://availability" },
		});
		expect(result).toEqual({ ok: true, oneSignalId: "onesignal-id-2", recipients: 1 });
	});

	it("returns recipients:0 (not an error) when OneSignal reports no subscribed devices", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(200, { id: "onesignal-id-3", recipients: 0 }));
		const result = await sendOneSignalNotification({
			appId: "app",
			apiKey: "key",
			externalUserId: "user-1",
			heading: "h",
			content: "c",
			data: { scenario_id: "N-01", notification_id: "n-1", deep_link: "wingward://availability" },
		});
		expect(result).toEqual({ ok: true, oneSignalId: "onesignal-id-3", recipients: 0 });
	});

	it("treats a 200 with a missing `id` as ok:true/recipients:0, not an error — OneSignal's documented shape for 'no valid subscriptions'", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(200, { recipients: 0, errors: ["All included players are not subscribed"] }));
		const result = await sendOneSignalNotification({
			appId: "app",
			apiKey: "key",
			externalUserId: "user-1",
			heading: "h",
			content: "c",
			data: { scenario_id: "N-01", notification_id: "n-1", deep_link: "wingward://availability" },
		});
		expect(result).toEqual({ ok: true, oneSignalId: "", recipients: 0 });
	});

	it("A-6: on an API error, the response body never reaches the caller — only a generic ok:false", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		fetchMock.mockResolvedValueOnce(
			jsonResponse(400, { errors: ["PWNED-CANARY: invalid app_id abc123-internal-detail"] }),
		);

		const result = await sendOneSignalNotification({
			appId: "app",
			apiKey: "key",
			externalUserId: "user-1",
			heading: "h",
			content: "c",
			data: { scenario_id: "N-01", notification_id: "n-1", deep_link: "wingward://availability" },
		});

		expect(result).toEqual({ ok: false });
		expect(JSON.stringify(result)).not.toContain("PWNED-CANARY");
		// The detail is still available server-side (logged), just not returned.
		expect(consoleErrorSpy).toHaveBeenCalled();
		const loggedText = consoleErrorSpy.mock.calls.map((call) => call.join(" ")).join("\n");
		expect(loggedText).toContain("PWNED-CANARY");

		consoleErrorSpy.mockRestore();
	});

	it("returns ok:false on a network/transport failure without throwing", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		fetchMock.mockRejectedValueOnce(new Error("network unreachable"));

		const result = await sendOneSignalNotification({
			appId: "app",
			apiKey: "key",
			externalUserId: "user-1",
			heading: "h",
			content: "c",
			data: { scenario_id: "N-01", notification_id: "n-1", deep_link: "wingward://availability" },
		});

		expect(result).toEqual({ ok: false });
		consoleErrorSpy.mockRestore();
	});

	it("returns ok:false when the 2xx body is not valid JSON, without throwing", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		fetchMock.mockResolvedValueOnce(new Response("not json", { status: 200 }));

		const result = await sendOneSignalNotification({
			appId: "app",
			apiKey: "key",
			externalUserId: "user-1",
			heading: "h",
			content: "c",
			data: { scenario_id: "N-01", notification_id: "n-1", deep_link: "wingward://availability" },
		});

		expect(result).toEqual({ ok: false });
		consoleErrorSpy.mockRestore();
	});
});

describe("setOneSignalTags", () => {
	it("PATCHes the by/external_id endpoint with the given tags", async () => {
		fetchMock.mockResolvedValueOnce(new Response("{}", { status: 200 }));

		const result = await setOneSignalTags({
			appId: "app-1",
			apiKey: "key-1",
			externalUserId: "user-profile-uuid-1",
			tags: { billing_status: "free", has_meetup_experience: "false", timezone: "Asia/Tokyo" },
		});

		expect(result).toEqual({ ok: true });
		const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		expect(url).toBe("https://api.onesignal.com/apps/app-1/users/by/external_id/user-profile-uuid-1");
		expect(init.method).toBe("PATCH");
		expect(JSON.parse(init.body as string)).toEqual({
			properties: { tags: { billing_status: "free", has_meetup_experience: "false", timezone: "Asia/Tokyo" } },
		});
	});

	it("does not reflect an error body and returns ok:false", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		fetchMock.mockResolvedValueOnce(new Response("PWNED-CANARY-TAGS", { status: 500 }));

		const result = await setOneSignalTags({
			appId: "app-1",
			apiKey: "key-1",
			externalUserId: "user-1",
			tags: { billing_status: "free", has_meetup_experience: "false", timezone: "UTC" },
		});

		expect(result).toEqual({ ok: false });
		consoleErrorSpy.mockRestore();
	});
});
