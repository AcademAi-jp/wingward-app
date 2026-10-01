import { Hono } from "hono";
import { describe, expect, it, vi, beforeEach } from "vitest";

/**
 * Round-2 fix (Codex PR #26 review): the fall-through branch in the /start
 * catch block used to return `jsonError(c, "INTERNAL_ERROR", msg)` where
 * `msg` is the raw `Error.message` of whatever `searchMatchCandidates`
 * threw (Supabase/PostgREST text, Mistral errors, internal ids). That
 * reflects internal exception text to an authenticated caller. The two
 * sentinel mappings (WINGFOX_PERSONA_NOT_FOUND, NO_CANDIDATES_FOUND) must
 * still produce their own friendly messages; everything else must collapse
 * to the generic constant.
 */

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "user-1");
		await next();
	},
	requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => {
		await next();
	},
}));
vi.mock("../services/fox-search", () => ({
	searchMatchCandidates: vi.fn(),
}));
vi.mock("../services/fox-conversation", () => ({
	runFoxConversation: vi.fn(),
}));
vi.mock("../services/fox-conversation-request", () => ({
	consumeFoxConversationQuota: vi.fn(),
	refundFoxConversationQuota: vi.fn(),
}));
vi.mock("../services/match-age-access", () => ({
	checkVerifiedPair: vi.fn(async () => ({ ok: true })),
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { searchMatchCandidates } from "../services/fox-search";
import { getSupabaseClient } from "../db/client";
import { consumeFoxConversationQuota, refundFoxConversationQuota } from "../services/fox-conversation-request";
import foxSearch from "./fox-search";

const mockedSearch = vi.mocked(searchMatchCandidates);
const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const mockedConsumeQuota = vi.mocked(consumeFoxConversationQuota);
const mockedRefundQuota = vi.mocked(refundFoxConversationQuota);

type QueryResponse = { data: unknown; error: unknown };
type QueryPlan = {
	or?: QueryResponse;
	single?: QueryResponse;
	limit?: QueryResponse;
	maybeSingle?: QueryResponse;
	mutation?: QueryResponse;
};

function makeQuery(plan: QueryPlan) {
	const query: {
		select: (_columns?: string) => typeof query;
		delete: () => typeof query;
		update: (_patch: Record<string, unknown>) => typeof query;
		eq: (_column: string, _value: string) => typeof query;
		in: (_column: string, _values: string[]) => typeof query;
		or: (_expression: string) => Promise<QueryResponse>;
		limit: (_value: number) => Promise<QueryResponse>;
		single: () => Promise<QueryResponse>;
		maybeSingle: () => Promise<QueryResponse>;
		then: Promise<QueryResponse>["then"];
	} = {
		select: () => query,
		delete: () => query,
		update: () => query,
		eq: () => query,
		in: () => query,
		or: async () => plan.or ?? { data: [], error: null },
		limit: async () => plan.limit ?? { data: [], error: null },
		single: async () => plan.single ?? { data: null, error: null },
		maybeSingle: async () => plan.maybeSingle ?? { data: null, error: null },
		then: (onfulfilled, onrejected) => Promise.resolve(plan.mutation ?? { data: null, error: null }).then(onfulfilled, onrejected),
	};
	return query;
}

interface RouteSupabasePlan {
	startMatchList?: QueryResponse;
	retryMatchLookup?: QueryResponse;
	retryMatchList?: QueryResponse;
	startActiveConversations?: QueryResponse;
	retryConversationLookup?: QueryResponse;
	retryActiveConversations?: QueryResponse;
	retryEntitlement?: QueryResponse;
	retryMessageDelete?: QueryResponse;
	retryConversationReset?: QueryResponse;
	retryMatchReset?: QueryResponse;
	retryCleanupConversation?: QueryResponse;
	retryCleanupMatch?: QueryResponse;
}

function makeRouteSupabase(plan: RouteSupabasePlan = {}) {
	const matchQueries = [
		makeQuery({ or: plan.startMatchList ?? { data: [], error: null }, single: plan.retryMatchLookup ?? { data: null, error: null } }),
		makeQuery({ or: plan.retryMatchList ?? { data: [], error: null } }),
		makeQuery({ mutation: plan.retryMatchReset }),
		makeQuery({ mutation: plan.retryCleanupMatch }),
	];
	const foxConversationQueries = [
		makeQuery({
			limit: plan.startActiveConversations ?? { data: [], error: null },
			single: plan.retryConversationLookup ?? { data: null, error: null },
		}),
		makeQuery({ limit: plan.retryActiveConversations ?? { data: [], error: null } }),
		makeQuery({ mutation: plan.retryConversationReset }),
		makeQuery({ mutation: plan.retryCleanupConversation }),
	];
	const entitlementQuery = makeQuery({ maybeSingle: plan.retryEntitlement ?? { data: null, error: null } });
	const messageQuery = makeQuery({ mutation: plan.retryMessageDelete });

	return {
		from(table: string) {
			if (table === "matches") return matchQueries.shift() ?? makeQuery({});
			if (table === "fox_conversations") return foxConversationQueries.shift() ?? makeQuery({});
			if (table === "entitlements") return entitlementQuery;
			if (table === "fox_conversation_messages") return messageQuery;
			return makeQuery({});
		},
	};
}

function buildApp() {
	const app = new Hono();
	app.route("/api/fox-search", foxSearch);
	return app;
}

beforeEach(() => {
	mockedSearch.mockReset();
	mockedGetSupabaseClient.mockReset();
	mockedGetSupabaseClient.mockReturnValue(makeRouteSupabase() as never);
	mockedConsumeQuota.mockReset();
	mockedConsumeQuota.mockResolvedValue({ consumed: true, ok: true, periodStart: "2026-08-01" });
	mockedRefundQuota.mockReset();
	mockedRefundQuota.mockResolvedValue(undefined);
});

describe("POST /api/fox-search/start", () => {
	it("fails closed when the active-match guard read errors, without searching", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeRouteSupabase({ startMatchList: { data: null, error: { message: "database unavailable" } } }) as never,
		);

		const app = buildApp();
		const res = await app.request("/api/fox-search/start", { method: "POST" });

		expect(res.status).toBe(500);
		expect(await res.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to verify active fox conversation" },
		});
		expect(mockedSearch).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("fails closed when the active-conversation guard read errors, without searching", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeRouteSupabase({
				startMatchList: { data: [{ id: "match-1" }], error: null },
				startActiveConversations: { data: null, error: { message: "database unavailable" } },
			}) as never,
		);

		const app = buildApp();
		const res = await app.request("/api/fox-search/start", { method: "POST" });

		expect(res.status).toBe(500);
		expect(await res.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to verify active fox conversation" },
		});
		expect(mockedSearch).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("does not reflect raw exception text for an unmapped error, and logs it server-side instead", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedSearch.mockRejectedValue(new Error('duplicate key value violates unique constraint "PWNED-CANARY-FOXSEARCH"'));

		const app = buildApp();
		const res = await app.request("/api/fox-search/start", { method: "POST" });
		const bodyText = await res.text();

		expect(res.status).toBe(500);
		expect(bodyText).not.toContain("PWNED-CANARY-FOXSEARCH");
		expect(JSON.parse(bodyText)).toEqual({
			error: { code: "INTERNAL_ERROR", message: "An unexpected error occurred" },
		});
		expect(consoleErrorSpy).toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("still maps WINGFOX_PERSONA_NOT_FOUND to its own friendly BAD_REQUEST message", async () => {
		mockedSearch.mockRejectedValue(new Error("WINGFOX_PERSONA_NOT_FOUND"));
		const app = buildApp();
		const res = await app.request("/api/fox-search/start", { method: "POST" });
		const body = (await res.json()) as { error: { code: string; message: string } };

		expect(res.status).toBe(400);
		expect(body.error).toEqual({ code: "BAD_REQUEST", message: "You need a wingfox persona first" });
	});

	it("still maps NO_CANDIDATES_FOUND to its own friendly NOT_FOUND message", async () => {
		mockedSearch.mockRejectedValue(new Error("NO_CANDIDATES_FOUND"));
		const app = buildApp();
		const res = await app.request("/api/fox-search/start", { method: "POST" });
		const body = (await res.json()) as { error: { code: string; message: string } };

		expect(res.status).toBe(404);
		expect(body.error).toEqual({ code: "NOT_FOUND", message: "No eligible partners found" });
	});
});

describe("POST /api/fox-search/retry/:matchId", () => {
	const completedMatch = {
		data: { id: "match-1", user_a_id: "user-1", user_b_id: "user-2", status: "fox_conversation_completed" },
		error: null,
	};
	const completedConversation = { data: { id: "conv-1", status: "completed" }, error: null };

	it.each([
		{
			name: "match",
			plan: { retryMatchLookup: { data: null, error: { message: "PWNED-CANARY-MATCH" } } },
			message: "Failed to verify match",
		},
		{
			name: "conversation",
			plan: {
				retryMatchLookup: completedMatch,
				retryConversationLookup: { data: null, error: { message: "PWNED-CANARY-CONVERSATION" } },
			},
			message: "Failed to verify fox conversation",
		},
	] as const)("fails closed when the retry $name lookup errors", async ({ plan, message }) => {
		mockedGetSupabaseClient.mockReturnValue(makeRouteSupabase(plan) as never);

		const res = await buildApp().request("/api/fox-search/retry/match-1", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });
		const body = await res.text();

		expect(res.status).toBe(500);
		expect(body).not.toMatch(/PWNED-CANARY/);
		expect(JSON.parse(body)).toEqual({ error: { code: "INTERNAL_ERROR", message } });
		expect(mockedConsumeQuota).not.toHaveBeenCalled();
	});

	it("fails closed on entitlement read errors before consuming retry quota", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeRouteSupabase({
				retryMatchLookup: completedMatch,
				retryConversationLookup: completedConversation,
				retryEntitlement: { data: null, error: { message: "database unavailable" } },
			}) as never,
		);

		const app = buildApp();
		const res = await app.request("/api/fox-search/retry/match-1", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });

		expect(res.status).toBe(500);
		expect(await res.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to verify fox conversation entitlement" },
		});
		expect(mockedConsumeQuota).not.toHaveBeenCalled();
		consoleErrorSpy.mockRestore();
	});

	it("fails closed on the retry active-match guard and refunds any quota already consumed", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeRouteSupabase({
				retryMatchLookup: completedMatch,
				retryConversationLookup: completedConversation,
				retryEntitlement: { data: { is_active: false }, error: null },
				retryMatchList: { data: null, error: { message: "database unavailable" } },
			}) as never,
		);

		const app = buildApp();
		const res = await app.request("/api/fox-search/retry/match-1", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });

		expect(res.status).toBe(500);
		expect(await res.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to verify active fox conversation" },
		});
		expect(mockedConsumeQuota).toHaveBeenCalledOnce();
		expect(mockedRefundQuota).toHaveBeenCalledOnce();
		consoleErrorSpy.mockRestore();
	});

	it("fails closed on the retry active-conversation guard and refunds any quota already consumed", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeRouteSupabase({
				retryMatchLookup: completedMatch,
				retryConversationLookup: completedConversation,
				retryEntitlement: { data: { is_active: false }, error: null },
				retryMatchList: { data: [{ id: "other-match" }], error: null },
				retryActiveConversations: { data: null, error: { message: "database unavailable" } },
			}) as never,
		);

		const app = buildApp();
		const res = await app.request("/api/fox-search/retry/match-1", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });

		expect(res.status).toBe(500);
		expect(await res.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to verify active fox conversation" },
		});
		expect(mockedConsumeQuota).toHaveBeenCalledOnce();
		expect(mockedRefundQuota).toHaveBeenCalledOnce();
		consoleErrorSpy.mockRestore();
	});

	it("fails closed and refunds quota when clearing old retry messages fails", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(
			makeRouteSupabase({
				retryMatchLookup: completedMatch,
				retryConversationLookup: completedConversation,
				retryEntitlement: { data: { is_active: false }, error: null },
				retryMatchList: { data: [{ id: "other-match" }], error: null },
				retryActiveConversations: { data: [], error: null },
				retryMessageDelete: { data: null, error: { message: "database unavailable" } },
			}) as never,
		);

		const app = buildApp();
		const res = await app.request("/api/fox-search/retry/match-1", { method: "POST" }, { MISTRAL_API_KEY: "test-key" });

		expect(res.status).toBe(500);
		expect(await res.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Failed to reset fox conversation" },
		});
		expect(mockedRefundQuota).toHaveBeenCalledOnce();
		consoleErrorSpy.mockRestore();
	});
});
