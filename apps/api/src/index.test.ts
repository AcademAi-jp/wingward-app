import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "./env";
const mocks = vi.hoisted(() => ({
  db: vi.fn(() => ({})), run: vi.fn().mockResolvedValue({}), handle: vi.fn().mockResolvedValue(undefined),
  prune: vi.fn().mockResolvedValue({pruned:0}), deliver: vi.fn().mockResolvedValue({}),
}));
vi.mock("./app", () => ({app:{fetch:vi.fn()}}));
vi.mock("./db/client", () => ({getSupabaseClient:mocks.db}));
vi.mock("./services/daily-batch", () => ({DEFERRED_SEND_CRON:"*/15 * * * *",handleScheduled:mocks.handle,runDailyBatch:mocks.run}));
vi.mock("./services/chat-meetup", () => ({expireChatMeetupPrivateInputs:mocks.prune}));
vi.mock("./services/daily-matching-notification-outbox", () => ({deliverDailyMatchingNotifications:mocks.deliver}));
vi.mock("./durable-objects/fox-conversation-do", () => ({FoxConversationDO:class {}}));
vi.mock("./durable-objects/judge-realtime-call-do", () => ({JudgeRealtimeCall:class {}}));
import worker, { runScheduledMaintenance } from "./index";
const env = (fields:Record<string,unknown>={}) => fields as Env["Bindings"];
const event = {cron:"*/15 * * * *",scheduledTime:Date.parse("2026-09-26T15:15:00Z")};
beforeEach(() => {vi.clearAllMocks();mocks.run.mockResolvedValue({});mocks.handle.mockResolvedValue(undefined);mocks.prune.mockResolvedValue({pruned:0});});
describe("private maintenance and durable batch continuation", () => {
  it.each([
    { RECORDING_REHEARSAL_ENABLED: "enabled" },
    { JUDGE_ACCESS_ENABLED: "enabled" },
    { JUDGE_ACCESS_UNKNOWN: "malformed" },
    { RECORDING_REHEARSAL_EXPIRES_AT: "malformed" },
    { RECORDING_REHEARSAL_ENABLED: "enabled", RECORDING_REHEARSAL_ISSUED_AT: "2026-09-20T00:00:00Z", RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-20T01:00:00Z", RECORDING_REHEARSAL_PAIR: "aoi-ren" },
  ])("closes scheduled handlers whenever any rehearsal binding is present", async (bindings) => {
    const waitUntil = vi.fn();
    await worker.scheduled(event, env({ ...bindings, CHAT_MEETUP_ENABLED: "enabled", DURABLE_DAILY_BATCH_ENABLED: "enabled" }), { waitUntil });
    await runScheduledMaintenance(event, env({ ...bindings, CHAT_MEETUP_ENABLED: "enabled", DURABLE_DAILY_BATCH_ENABLED: "enabled" }));
    expect(waitUntil).not.toHaveBeenCalled();
    expect(mocks.handle).not.toHaveBeenCalled();
    expect(mocks.db).not.toHaveBeenCalled();
    expect(mocks.run).not.toHaveBeenCalled();
    expect(mocks.prune).not.toHaveBeenCalled();
    expect(mocks.deliver).not.toHaveBeenCalled();
  });
  it("disabled or unrecognized triggers perform no database reads", async () => {
    await runScheduledMaintenance(event,env());
    await runScheduledMaintenance({...event,cron:"0 0 * * *"},env({DURABLE_DAILY_BATCH_ENABLED:"enabled"}));
    await runScheduledMaintenance(event,env({CHAT_MEETUP_ENABLED:"true",DURABLE_DAILY_BATCH_ENABLED:"true"}));
    expect(mocks.db).not.toHaveBeenCalled();
  });
  it("chat flag does not duplicate the cleanup owned by handleScheduled", async () => {
    await runScheduledMaintenance(event,env({CHAT_MEETUP_ENABLED:"enabled"}));
    expect(mocks.prune).not.toHaveBeenCalled();expect(mocks.run).not.toHaveBeenCalled();expect(mocks.deliver).not.toHaveBeenCalled();
  });
  it("uses the scheduled JST date and never creates a new batch from a continuation tick", async () => {
    const bindings=env({DURABLE_DAILY_BATCH_ENABLED:"enabled"});
    await runScheduledMaintenance(event,bindings);
    expect(mocks.run).toHaveBeenCalledWith(expect.anything(),"","Asia/Tokyo","2026-09-27",expect.objectContaining({durableEnabled:true,resumeOnly:true}));
    expect(mocks.deliver).toHaveBeenCalledWith(expect.anything(),bindings);
  });
  it("a failed resume keeps notification outbox recovery available", async () => {
    mocks.run.mockRejectedValueOnce(new Error("synthetic failure"));
    const log=vi.spyOn(console,"error").mockImplementation(() => {});
    await runScheduledMaintenance(event,env({DURABLE_DAILY_BATCH_ENABLED:"enabled"}));
    expect(mocks.deliver).toHaveBeenCalledOnce();log.mockRestore();
  });
});
