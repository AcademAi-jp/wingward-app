import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { pruneMeetupPrivateInputs } from "./meetup-private-input-janitor";

const mocks = vi.hoisted(() => ({ rpc: vi.fn(), notify: vi.fn(), batch: vi.fn(), expiry: vi.fn() }));
vi.mock("../db/client", () => ({ getSupabaseClient: () => ({ rpc: mocks.rpc }) }));
vi.mock("./daily-matching", () => ({ executeDailyMatching: mocks.batch }));
vi.mock("./notifications", () => ({ sendDeferredNotifications: mocks.notify }));
vi.mock("./fox-conversation", () => ({ runFoxConversation: vi.fn() }));
vi.mock("./meetup-expiry", () => ({ MEETUP_EXPIRY_CRON: "7 * * * *", handleMeetupExpiryCron: mocks.expiry }));
vi.mock("./daily-matching-notification-outbox", () => ({ deliverDailyMatchingNotifications: vi.fn() }));
vi.mock("../app", () => ({ app: { fetch: vi.fn() } }));
vi.mock("../durable-objects/fox-conversation-do", () => ({ FoxConversationDO: class {} }));
vi.mock("../durable-objects/judge-realtime-call-do", () => ({ JudgeRealtimeCall: class {} }));
const { default: worker } = await import("../index");
const dailyBatch = await import("./daily-batch");
const { DEFERRED_SEND_CRON, DAILY_BATCH_CRON, handleScheduled } = dailyBatch;
const env = { SUPABASE_URL: "https://example.invalid", SUPABASE_SERVICE_ROLE_KEY: "synthetic-key" };
const event = (cron: string) => ({ cron, scheduledTime: Date.parse("2026-10-01T00:15:00Z") });
const fixedFailure = "[meetup-private-input-janitor] Private input cleanup unavailable";

beforeEach(() => {
	mocks.rpc.mockReset().mockResolvedValue({ data: [{ pruned: 0 }], error: null });
	mocks.notify.mockReset().mockResolvedValue({ processed: 0, sent: 0, suppressed: 0, failed: 0 });
	mocks.batch.mockReset(); mocks.expiry.mockReset();
	vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => { vi.restoreAllMocks(); });

describe("private input janitor RPC boundary", () => {
	it.each([0, 1, 500])("accepts only the bounded count %i", async (pruned) => {
		mocks.rpc.mockResolvedValue({ data: [{ pruned }], error: null });
		expect(await pruneMeetupPrivateInputs({ rpc: mocks.rpc })).toBe(pruned);
		expect(mocks.rpc).toHaveBeenCalledWith("prune_chat_meetup_private_inputs", {});
		expect(console.error).not.toHaveBeenCalled();
	});
	it.each([null, [], [{ pruned: -1 }], [{ pruned: 501 }], [{ pruned: 1.5 }], [{ pruned: "2" }],
		[{ pruned: 2, origin: "synthetic-private-location" }], [{ pruned: 1 }, { pruned: 2 }]].map((data) => ({ data })))(
		"rejects malformed or excess output without echoing it", async ({ data }) => {
			mocks.rpc.mockResolvedValue({ data, error: null });
			expect(await pruneMeetupPrivateInputs({ rpc: mocks.rpc })).toBe(0);
			expect(console.error).toHaveBeenCalledExactlyOnceWith(fixedFailure);
		});
	it.each(["returned error", "throw"])("identifies %s only with the fixed failure log", async (kind) => {
		if (kind === "throw") mocks.rpc.mockRejectedValue(new Error("synthetic-private-location"));
		else mocks.rpc.mockResolvedValue({ data: null, error: { message: "synthetic-private-location" } });
		expect(await pruneMeetupPrivateInputs({ rpc: mocks.rpc })).toBe(0);
		expect(console.error).toHaveBeenCalledExactlyOnceWith(fixedFailure);
	});
});

describe("existing scheduled maintenance path", () => {
	it("the already-registered 15-minute tick calls the real janitor with feature flags absent", async () => {
		const config = readFileSync(new URL("../../wrangler.toml", import.meta.url), "utf8");
		expect(config).toMatch(/crons\s*=\s*\[[^\]]*"\*\/15 \* \* \* \*"/);
		await handleScheduled(event(DEFERRED_SEND_CRON), env);
		expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("prune_chat_meetup_private_inputs", {});
		expect(mocks.notify).toHaveBeenCalledOnce();
		expect(mocks.batch).not.toHaveBeenCalled();
	});
	it("a returned cleanup failure cannot suppress deferred notifications", async () => {
		mocks.rpc.mockResolvedValue({ data: null, error: { message: "synthetic-private-location" } });
		await handleScheduled(event(DEFERRED_SEND_CRON), env);
		expect(mocks.notify).toHaveBeenCalledOnce();
		expect(console.error).toHaveBeenCalledExactlyOnceWith(fixedFailure);
	});
	it("a thrown cleanup failure cannot suppress deferred notifications", async () => {
		mocks.rpc.mockRejectedValue(new Error("synthetic-private-location"));
		await handleScheduled(event(DEFERRED_SEND_CRON), env);
		expect(mocks.notify).toHaveBeenCalledOnce();
		expect(console.error).toHaveBeenCalledExactlyOnceWith(fixedFailure);
	});
	it("a notification failure cannot prevent private cleanup", async () => {
		mocks.notify.mockRejectedValue(new Error("synthetic-notification-failure"));
		await handleScheduled(event(DEFERRED_SEND_CRON), env);
		expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("prune_chat_meetup_private_inputs", {});
		expect(console.error).toHaveBeenCalledWith("[handleScheduled] Deferred notification send failed");
	});
	it.each([DAILY_BATCH_CRON, "7 * * * *", "0 * * * *"])("does not clean on unrelated cron %s", async (cron) => {
		await handleScheduled(event(cron), env);
		expect(mocks.rpc).not.toHaveBeenCalled();
	});
});


describe("Worker scheduled entry owns one cleanup pass", () => {
	it("cleans once while durable continuation fails independently", async () => {
		vi.spyOn(dailyBatch, "runDailyBatch").mockRejectedValue(new Error("synthetic-continuation-failure"));
		let pending: Promise<void> | undefined;
		await worker.scheduled(event(DEFERRED_SEND_CRON), { ...env, CHAT_MEETUP_ENABLED: "enabled", DURABLE_DAILY_BATCH_ENABLED: "enabled" }, {
			waitUntil: (job) => { pending = job; },
		});
		await pending;
		expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("prune_chat_meetup_private_inputs", {});
		expect(console.error).toHaveBeenCalledWith("[scheduled] Daily batch continuation unavailable");
	});
	it.each([{}, { CHAT_MEETUP_ENABLED: "enabled" }])("cleans once with bindings %j", async (bindings) => {
		let pending: Promise<void> | undefined;
		await worker.scheduled(event(DEFERRED_SEND_CRON), { ...env, ...bindings }, {
			waitUntil: (job) => { pending = job; },
		});
		await pending;
		expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("prune_chat_meetup_private_inputs", {});
		expect(mocks.notify).toHaveBeenCalledOnce();
	});
	it.each([
		{ JUDGE_ACCESS_ENABLED: "enabled" }, { DEMO_JUDGE_ENABLED: "enabled" },
		{ RECORDING_REHEARSAL_ENABLED: "enabled" },
	])("keeps scheduled privacy gates for %j", async (bindings) => {
		const waitUntil = vi.fn();
		await worker.scheduled(event(DEFERRED_SEND_CRON), { ...env, ...bindings }, { waitUntil });
		expect(waitUntil).not.toHaveBeenCalled();
		expect(mocks.rpc).not.toHaveBeenCalled();
	});
});
