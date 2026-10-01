import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const executeDailyMatching = vi.fn();
const sendDeferredNotifications = vi.fn();
const handleMeetupExpiryCron = vi.fn();
const rpc = vi.fn();

vi.mock("../db/client", () => ({ getSupabaseClient: () => ({ rpc }) as never }));
vi.mock("./daily-matching", () => ({ executeDailyMatching: (...args: unknown[]) => executeDailyMatching(...args) }));
vi.mock("./notifications", () => ({ sendDeferredNotifications: (...args: unknown[]) => sendDeferredNotifications(...args) }));
vi.mock("./meetup-expiry", () => ({
	MEETUP_EXPIRY_CRON: "7 * * * *",
	handleMeetupExpiryCron: (...args: unknown[]) => handleMeetupExpiryCron(...args),
}));

const { DAILY_BATCH_CRON, DEFERRED_SEND_CRON, handleScheduled } = await import("./daily-batch");
const { MEETUP_EXPIRY_CRON } = await import("./meetup-expiry");

const ENV = {
	SUPABASE_URL: "https://example.invalid",
	SUPABASE_SERVICE_ROLE_KEY: "not-a-real-key",
	DURABLE_DAILY_BATCH_ENABLED: "enabled",
};

function event(cron: string) {
	return { cron, scheduledTime: Date.parse("2026-06-15T00:00:00.000Z") };
}

beforeEach(() => {
	executeDailyMatching.mockReset().mockResolvedValue({
		status: "completed", batchId: "11111111-1111-4111-8111-111111111111", totalUsers: 0, usersMatched: 0, totalMatches: 0,
	});
	rpc.mockReset().mockResolvedValue({
		data: { requested_count: 0, pending_count: 0, in_progress_count: 0, completed_count: 0, failed_count: 0 },
		error: null,
	});
	sendDeferredNotifications.mockReset().mockResolvedValue({ processed: 0, sent: 0, suppressed: 0, failed: 0 });
	handleMeetupExpiryCron.mockReset().mockResolvedValue({ ran: true, transitioned: [], notificationContexts: [] });
});

afterEach(() => vi.restoreAllMocks());

describe("handleScheduled cron routing and daily schedule", () => {
	it("runs the enabled durable batch for the scheduled Tokyo date only", async () => {
		await handleScheduled(event(DAILY_BATCH_CRON), ENV);

		expect(executeDailyMatching).toHaveBeenCalledTimes(1);
		expect(executeDailyMatching).toHaveBeenCalledWith(
			expect.anything(),
			"2026-06-15",
			1,
			{ durableEnabled: true, resumeOnly: false },
		);
		expect(rpc).toHaveBeenCalledWith("get_durable_daily_matching_conversation_status", {
			p_batch_id: "11111111-1111-4111-8111-111111111111",
		});
		expect(sendDeferredNotifications).not.toHaveBeenCalled();
		expect(handleMeetupExpiryCron).not.toHaveBeenCalled();
	});

	it("keeps the durable matcher closed if the rollout gate is absent", async () => {
		const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

		await handleScheduled(event(DAILY_BATCH_CRON), { ...ENV, DURABLE_DAILY_BATCH_ENABLED: undefined });

		expect(executeDailyMatching).not.toHaveBeenCalled();
		expect(rpc).not.toHaveBeenCalled();
		consoleSpy.mockRestore();
	});

	it("the frequent cron runs deferred notifications and does NOT create a daily batch", async () => {
		await handleScheduled(event(DEFERRED_SEND_CRON), ENV);

		expect(sendDeferredNotifications).toHaveBeenCalledTimes(1);
		expect(executeDailyMatching).not.toHaveBeenCalled();
		expect(handleMeetupExpiryCron).not.toHaveBeenCalled();
	});

	it("the code-only meetup expiry cron runs only its expiry branch", async () => {
		const expiryEvent = event(MEETUP_EXPIRY_CRON);
		await handleScheduled(expiryEvent, ENV);

		expect(handleMeetupExpiryCron).toHaveBeenCalledWith(expiryEvent, expect.anything(), {
			now: new Date(expiryEvent.scheduledTime),
		});
		expect(executeDailyMatching).not.toHaveBeenCalled();
		expect(sendDeferredNotifications).not.toHaveBeenCalled();
	});

	it("an unrecognised cron runs nothing and logs the source wiring mismatch", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		await handleScheduled(event("0 * * * *"), ENV);

		expect(executeDailyMatching).not.toHaveBeenCalled();
		expect(sendDeferredNotifications).not.toHaveBeenCalled();
		expect(handleMeetupExpiryCron).not.toHaveBeenCalled();
		expect(consoleErrorSpy).toHaveBeenCalledWith(expect.stringContaining("no job is wired to cron expression"));
	});
});
