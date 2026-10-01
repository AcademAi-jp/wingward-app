import { beforeEach, describe, expect, it, vi } from "vitest";

const executeDailyMatching = vi.fn();
vi.mock("./daily-matching", () => ({ executeDailyMatching: (...args: unknown[]) => executeDailyMatching(...args) }));

import { runDailyBatch } from "./daily-batch";

const BATCH_ID = "11111111-1111-4111-8111-111111111111";

function batchClient(summary: unknown = {
	requested_count: 0,
	pending_count: 0,
	in_progress_count: 0,
	completed_count: 0,
	failed_count: 0,
}) {
	const calls: { name: string; args: Record<string, unknown> }[] = [];
	return {
		calls,
		client: {
			rpc(name: string, args: Record<string, unknown>) {
				calls.push({ name, args });
				return Promise.resolve({ data: summary, error: null });
			},
		},
	};
}

beforeEach(() => {
	executeDailyMatching.mockReset().mockResolvedValue({
		status: "completed", batchId: BATCH_ID, totalUsers: 2, usersMatched: 2, totalMatches: 1,
	});
});

describe("runDailyBatch durable rollout and truthful status", () => {
	it("keeps matching disabled when the explicit durable flag is absent", async () => {
		const { client, calls } = batchClient();

		const result = await runDailyBatch(client as never, undefined, "Asia/Tokyo", "2026-09-26");

		expect(result).toMatchObject({ status: "disabled", batchDate: "2026-09-26", totalMatches: 0 });
		expect(executeDailyMatching).not.toHaveBeenCalled();
		expect(calls).toHaveLength(0);
	});

	it("returns resumable without claiming publication or conversations", async () => {
		executeDailyMatching.mockResolvedValueOnce({
			status: "resumable", batchId: BATCH_ID, totalUsers: 2, usersMatched: 0, totalMatches: 0,
		});
		const { client, calls } = batchClient();

		const result = await runDailyBatch(client as never, undefined, "Asia/Tokyo", "2026-09-26", {
			durableEnabled: true,
		});

		expect(result).toMatchObject({ status: "resumable", conversationStatus: "not_requested", totalMatches: 0 });
		expect(calls).toHaveLength(0);
		expect(executeDailyMatching).toHaveBeenCalledWith(client, "2026-09-26", 1, {
			durableEnabled: true,
			resumeOnly: false,
		});
	});

	it("counts pending, in-progress, and failed Ward conversations separately from published matches", async () => {
		const summary = {
			requested_count: 5,
			pending_count: 2,
			in_progress_count: 1,
			completed_count: 1,
			failed_count: 1,
		};
		const { client, calls } = batchClient(summary);

		const result = await runDailyBatch(client as never, undefined, "Asia/Tokyo", "2026-09-26", {
			durableEnabled: true,
		});

		expect(result).toMatchObject({
			status: "completed",
			batchId: BATCH_ID,
			totalMatches: 1,
			conversationStatus: "pending",
			conversationsPending: 4,
			conversationsCompleted: 1,
			conversationsFailed: 1,
		});
		expect(calls).toEqual([{
			name: "get_durable_daily_matching_conversation_status",
			args: { p_batch_id: BATCH_ID },
		}]);
	});

	it("rejects malformed or inconsistent conversation counts", async () => {
		for (const summary of [
			{ requested_count: 1, pending_count: 1, in_progress_count: 0, completed_count: 0, failed_count: 0, extra: 0 },
			{ requested_count: 1, pending_count: 2, in_progress_count: 0, completed_count: 0, failed_count: 0 },
			{ requested_count: Number.MAX_SAFE_INTEGER + 1, pending_count: 0, in_progress_count: 0, completed_count: 0, failed_count: 0 },
		]) {
			const client = { rpc: () => Promise.resolve({ data: summary, error: null }) };
			await expect(runDailyBatch(client as never, undefined, "Asia/Tokyo", "2026-09-26", {
				durableEnabled: true,
			})).rejects.toThrow(/conversation status is unavailable/);
		}
	});

	it("fails closed when the required durable status RPC is unavailable", async () => {
		const client = { rpc: () => Promise.resolve({ data: null, error: { message: "migration missing" } }) };

		await expect(runDailyBatch(client as never, undefined, "Asia/Tokyo", "2026-09-26", {
			durableEnabled: true,
		})).rejects.toThrow(/conversation status is unavailable/);
	});

	it("rejects any runtime timezone override away from Tokyo", async () => {
		await expect(runDailyBatch({} as never, undefined, "America/Los_Angeles", "2026-09-26", {
			durableEnabled: true,
		})).rejects.toThrow(/fixed to Asia\/Tokyo/);
		expect(executeDailyMatching).not.toHaveBeenCalled();
	});
});
