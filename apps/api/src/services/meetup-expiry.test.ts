import { describe, expect, it, vi } from "vitest";
import { expireMeetups, handleMeetupExpiryCron, MEETUP_EXPIRY_CRON } from "./meetup-expiry";

const MEETUP_ID = "30000000-0000-0000-0000-000000000001";
const MATCH_ID = "20000000-0000-0000-0000-000000000001";
const NOW = new Date("2026-09-04T00:00:00.000Z");

function expiryRow(previousStatus: "intent_pending" | "proposed" | "confirmed") {
	return {
		meetup_id: MEETUP_ID,
		match_id: MATCH_ID,
		previous_status: previousStatus,
		status: "expired",
		transitioned: true,
	};
}

describe("meetup expiry branch", () => {
	it("is a no-op for an unknown cron expression", async () => {
		const rpc = vi.fn();
		const result = await handleMeetupExpiryCron({ cron: "unknown-cron" }, { rpc } as never, { now: NOW });

		expect(result).toEqual({ ran: false, transitioned: [], notificationContexts: [] });
		expect(rpc).not.toHaveBeenCalled();
	});

	it.each(["intent_pending", "proposed", "confirmed"] as const)("forwards exact-boundary %s transitions only", async (previousStatus) => {
		const rpc = vi.fn().mockResolvedValue({ data: [expiryRow(previousStatus)], error: null });
		const notify = vi.fn().mockResolvedValue(undefined);
		const result = await expireMeetups({ rpc } as never, { now: NOW, notifier: { notify } });

		expect(rpc).toHaveBeenCalledWith("claim_expired_meetups", { p_now: NOW.toISOString() });
		expect(result.transitioned).toEqual([
			{ meetupId: MEETUP_ID, matchId: MATCH_ID, previousStatus, status: "expired" },
		]);
		expect(result.notificationContexts).toEqual(result.transitioned);
		expect(notify).toHaveBeenCalledTimes(1);
		expect(notify).toHaveBeenCalledWith(result.transitioned[0]);
	});

	it("does not notify malformed or already-claimed rows, and tolerates notifier failure", async () => {
		const rpc = vi.fn().mockResolvedValue({
			data: [
				expiryRow("proposed"),
				{ ...expiryRow("confirmed"), transitioned: false },
				{ ...expiryRow("intent_pending"), meetup_id: "not-a-uuid" },
			],
			error: null,
		});
		const notify = vi.fn().mockRejectedValue(new Error("delivery unavailable"));

		const result = await expireMeetups({ rpc } as never, { now: NOW, notifier: { notify } });

		expect(result.transitioned).toHaveLength(1);
		expect(notify).toHaveBeenCalledTimes(1);
	});
});
