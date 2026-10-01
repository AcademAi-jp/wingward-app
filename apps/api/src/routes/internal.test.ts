import { Hono } from "hono";
import { describe, expect, it, vi, beforeEach } from "vitest";

/**
 * Round-2 fix (Codex PR #26 review): the daily-batch execute catch block had
 * the same fall-through shape as fox-search.ts's /start route — raw
 * `Error.message` from `runDailyBatch` returned verbatim via
 * `jsonError(c, "INTERNAL_ERROR", msg)`. This route sits behind
 * `requireInternalAuth`, but the class of bug should be closed uniformly.
 */

vi.mock("../services/daily-batch", () => ({
	runDailyBatch: vi.fn(),
}));
vi.mock("../db/client", () => ({
	getSupabaseClient: vi.fn(),
}));

import { runDailyBatch } from "../services/daily-batch";
import { getSupabaseClient } from "../db/client";
import internal from "./internal";

const mockedRunDailyBatch = vi.mocked(runDailyBatch);
const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

function buildApp() {
	const app = new Hono();
	app.route("/api/internal", internal);
	return app;
}

beforeEach(() => {
	mockedRunDailyBatch.mockReset();
	mockedGetSupabaseClient.mockReset().mockReturnValue({} as never);
});

describe("POST /api/internal/fox-conversations/execute", () => {
	it("fails instead of reporting an empty batch when the pending read errors", async () => {
		const query: Record<string, unknown> = {};
		for (const method of ["select", "in", "limit"]) query[method] = () => query;
		query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) =>
			Promise.resolve({ data: null, error: { message: "PWNED-CANARY-INTERNAL-READ" } }).then(resolve, reject);
		mockedGetSupabaseClient.mockReturnValue({ from: () => query } as never);

		const response = await buildApp().request(
			"/api/internal/fox-conversations/execute",
			{ method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" },
			{ MISTRAL_API_KEY: "test-key" },
		);
		const body = await response.text();
		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-INTERNAL-READ");
	});
});

describe("POST /api/internal/daily-batch/execute", () => {
	it("does not reflect or log raw exception text from runDailyBatch", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedRunDailyBatch.mockRejectedValue(new Error('relation "PWNED-CANARY-INTERNAL" does not exist'));

		const app = buildApp();
		const res = await app.request(
			"/api/internal/daily-batch/execute",
			{ method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" },
			{ MISTRAL_API_KEY: "test-key", DURABLE_DAILY_BATCH_ENABLED: "enabled" },
		);
		const bodyText = await res.text();

		expect(res.status).toBe(500);
		expect(bodyText).not.toContain("PWNED-CANARY-INTERNAL");
		expect(JSON.parse(bodyText)).toEqual({
			error: { code: "INTERNAL_ERROR", message: "An unexpected error occurred" },
		});
		expect(consoleErrorSpy).toHaveBeenCalled();
		expect(JSON.stringify(consoleErrorSpy.mock.calls)).not.toContain("PWNED-CANARY-INTERNAL");
		consoleErrorSpy.mockRestore();
	});
});

describe("durable daily batch integration boundaries", () => {
	it.each([undefined, "true", "enabled ", "disabled"])("does no work when gate is %s", async (gate) => {
		const response = await buildApp().request("/api/internal/daily-batch/execute",
			{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"},
			{DURABLE_DAILY_BATCH_ENABLED:gate});
		expect(response.status).toBe(503);
		expect(mockedRunDailyBatch).not.toHaveBeenCalled();
		expect(mockedGetSupabaseClient).not.toHaveBeenCalled();
	});
	it.each(["{", "[]", '{"batch_date":"2026-02-30"}', '{"batch_date":"2026-9-26"}', '{"unknown":"value"}'])("rejects invalid body %s without work", async (body) => {
		const response = await buildApp().request("/api/internal/daily-batch/execute",
			{method:"POST",headers:{"Content-Type":"application/json"},body},
			{DURABLE_DAILY_BATCH_ENABLED:"enabled"});
		expect(response.status).toBe(400);
		expect(mockedRunDailyBatch).not.toHaveBeenCalled();
	});
	it("resumes through the same runner with no provider key and no destructive turn reset", async () => {
		mockedRunDailyBatch.mockResolvedValue({batchDate:"2026-09-26",batchId:"fixture",status:"completed",conversationStatus:"pending",conversationsPending:1,totalMatches:1,conversationsCompleted:0,conversationsFailed:0} as never);
		const response = await buildApp().request("/api/internal/daily-batch/retry",
			{method:"POST",headers:{"Content-Type":"application/json"},body:'{"batch_date":"2026-09-26"}'},
			{DURABLE_DAILY_BATCH_ENABLED:"enabled"});
		expect(response.status).toBe(200);
		expect(mockedRunDailyBatch).toHaveBeenCalledWith({}, "", "Asia/Tokyo", "2026-09-26", {durableEnabled:true,foxConversationDO:undefined});
	});
	it.each([null,{batch_date:"2026-09-26",status:"matching",total_matches:0,conversations_completed:0,conversations_failed:0,completed_at:null}])("does not invent completion from absent pairs", async (row) => {
		const query:Record<string,unknown>={};
		query.select=()=>query;query.eq=()=>query;
		query.maybeSingle=async()=>({data:row,error:null});
		mockedGetSupabaseClient.mockReturnValue({from:()=>query} as never);
		const response=await buildApp().request("/api/internal/daily-batch/status?date=2026-09-26",{},{});
		expect(response.status).toBe(200);
		expect(((await response.json()) as {data:{status:string}}).data.status).toBe(row ? "matching" : "not_started");
	});
	it("does not accept a completed status without an authoritative completion timestamp",async()=>{
		const query:Record<string,unknown>={};query.select=()=>query;query.eq=()=>query;
		query.maybeSingle=async()=>({data:{status:"completed",total_matches:0,conversations_completed:0,conversations_failed:0,completed_at:null},error:null});
		mockedGetSupabaseClient.mockReturnValue({from:()=>query} as never);
		const response=await buildApp().request("/api/internal/daily-batch/status?date=2026-09-26",{},{});
		expect(response.status).toBe(500);
	});
});
