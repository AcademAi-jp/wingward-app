import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

let viewerId = "user-a";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", viewerId);
		await next();
	},
	requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => {
		await next();
	},
}));

vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import foxConversations from "./fox-conversations";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

const USER_A = "user-a";
const USER_B = "user-b";
const USER_C = "user-c";
const OUTSIDER = "user-outsider";
const MATCH_ID = "match-1";
const CONVERSATION_ID = "conversation-1";

type Call = { table: string; method: string; args: unknown[] };

type Scenario = {
	foxRows: Array<{ data: unknown; error: unknown }>;
	history: unknown[] | null;
	historyError: unknown;
	throwHistory: boolean;
	historyCompleted: boolean;
	events: string[];
	calls: Call[];
	historyReads: number;
	foxReads: number;
};

function profile(id: string, blocksSent: unknown[] = []) {
	return {
		id,
		age_verified_at: "2026-08-24T00:00:00Z",
		gender_identity: "woman",
		preferred_genders: ["woman"],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
		blocks_sent: blocksSent,
	};
}

function conversationRow(options: {
	conversationStatus?: string;
	matchStatus?: string;
	purpose?: string;
	userA?: string;
	userB?: string;
	profileA?: unknown;
	profileB?: unknown;
} = {}) {
	const conversationStatus = options.conversationStatus ?? "completed";
	const userA = options.userA ?? USER_A;
	const userB = options.userB ?? USER_B;
	return {
		id: CONVERSATION_ID,
		match_id: MATCH_ID,
		status: conversationStatus,
		purpose: options.purpose ?? "compatibility",
		total_rounds: 10,
		current_round: conversationStatus === "completed" ? 10 : 3,
		started_at: "2026-08-24T00:00:00Z",
		completed_at: conversationStatus === "completed" ? "2026-08-24T00:10:00Z" : null,
		conversation_analysis: { internal: "must-not-leak" },
		input_tokens: 101,
		output_tokens: 202,
		cache_hit_tokens: 303,
		match: {
			id: MATCH_ID,
			user_a_id: userA,
			user_b_id: userB,
			status: options.matchStatus ?? "fox_conversation_completed",
			profile_a: options.profileA ?? profile(userA),
			profile_b: options.profileB ?? profile(userB),
		},
	};
}

function clone<T>(value: T): T {
	return JSON.parse(JSON.stringify(value)) as T;
}

function makeSupabase(state: Scenario) {
	const from = (table: string) => {
		const query: Record<string, unknown> = {};
		const record = (method: string, args: unknown[]) => state.calls.push({ table, method, args });

		query.select = (...args: unknown[]) => {
			record("select", args);
			return query;
		};
		for (const method of ["eq", "order", "lt", "limit"]) {
			query[method] = (...args: unknown[]) => {
				record(method, args);
				return query;
			};
		}
		query.single = async () => {
			record("single", []);
			if (table !== "fox_conversations") return { data: null, error: null };
			const readIndex = state.foxReads++;
			state.events.push(`fox:${readIndex}`);
			if (readIndex >= 2 && !state.historyCompleted) return state.foxRows[1] ?? { data: null, error: null };
			return state.foxRows[Math.min(readIndex, state.foxRows.length - 1)] ?? { data: null, error: null };
		};
		query.then = (
			resolve: (value: { data: unknown; error: unknown }) => unknown,
			reject?: (reason: unknown) => unknown,
		) => {
			if (table !== "fox_conversation_messages") return Promise.resolve({ data: null, error: null }).then(resolve, reject);
			state.historyReads += 1;
			state.historyCompleted = true;
			state.events.push("history:resolved");
			if (state.throwHistory) return Promise.reject(new Error("history read failed")).then(resolve, reject);
			return Promise.resolve({ data: state.history, error: state.historyError }).then(resolve, reject);
		};
		return query;
	};
	return { from };
}

function scenario(options: {
	initial?: ReturnType<typeof conversationRow>;
	final?: ReturnType<typeof conversationRow>;
	history?: unknown[] | null;
	historyError?: unknown;
	throwHistory?: boolean;
} = {}): Scenario {
	const initial = options.initial ?? conversationRow();
	return {
		foxRows: [
			{ data: initial, error: null },
			{ data: initial, error: null },
			{ data: options.final ?? initial, error: null },
		],
		history: options.history ?? [],
		historyError: options.historyError ?? null,
		throwHistory: options.throwHistory ?? false,
		historyCompleted: false,
		events: [],
		calls: [],
		historyReads: 0,
		foxReads: 0,
	};
}

function buildApp() {
	const app = new Hono();
	app.route("/api/fox-conversations", foxConversations);
	return app;
}

function gateCalls(state: Scenario) {
	return state.calls.filter(
		(call) => call.table === "fox_conversations" &&
			call.method === "select" &&
			typeof call.args[0] === "string" &&
			(call.args[0] as string).includes("profile_a:user_profiles"),
	);
}

function gateFilterGroups(state: Scenario) {
	const starts = state.calls
		.map((call, index) => ({ call, index }))
		.filter(({ call }) => call.table === "fox_conversations" && call.method === "select" &&
			typeof call.args[0] === "string" && (call.args[0] as string).includes("profile_a:user_profiles"))
		.map(({ index }) => index);
	return starts.map((start, position) => {
		const nextGate = starts[position + 1] ?? state.calls.length;
		return state.calls.slice(start + 1, nextGate).filter((call) => call.table === "fox_conversations" && call.method === "eq");
	});
}

beforeEach(() => {
	viewerId = USER_A;
	vi.clearAllMocks();
});

describe("fox conversation public read status contract", () => {
	it.each([
		["pending", "fox_conversation_in_progress"],
		["in_progress", "fox_conversation_in_progress"],
		["failed", "fox_conversation_failed"],
		["completed", "fox_conversation_completed"],
		["completed", "partner_chat_started"],
		["completed", "direct_chat_requested"],
		["completed", "direct_chat_active"],
		["completed", "chat_request_expired"],
		["completed", "chat_request_declined"],
	])("returns only the closed detail for %s/%s", async (conversationStatus, matchStatus) => {
		const state = scenario({ initial: conversationRow({ conversationStatus, matchStatus }) });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}`);
		expect(response.status).toBe(200);
		const body = (await response.json()) as { data: Record<string, unknown> };
		expect(Object.keys(body.data).sort()).toEqual([
			"completed_at",
			"current_round",
			"id",
			"match_id",
			"started_at",
			"status",
			"total_rounds",
		]);
		expect(body.data.status).toBe(conversationStatus);
		expect(JSON.stringify(body)).not.toContain("must-not-leak");
		expect(JSON.stringify(body)).not.toContain("input_tokens");
		expect(gateCalls(state)).toHaveLength(2);
	});

	it.each([
		["completed", "meetup_intent"],
		["completed", "meetup_confirmed"],
		["completed", "fox_conversation_in_progress"],
		["completed", "fox_conversation_failed"],
		["failed", "fox_conversation_completed"],
		["pending", "fox_conversation_completed"],
	])("rejects a mismatched public pair %s/%s", async (conversationStatus, matchStatus) => {
		const state = scenario({ initial: conversationRow({ conversationStatus, matchStatus }) });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}`);
		expect(response.status).toBe(403);
	});

	it("rejects an outsider before reading history", async () => {
		viewerId = OUTSIDER;
		const state = scenario({ history: [{ id: "m1", speaker_user_id: USER_A, content: "secret", round_number: 1, created_at: "2026-08-24T00:01:00Z" }] });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);
		expect(response.status).toBe(403);
		expect(state.historyReads).toBe(0);
	});

	it("rejects scheduling purpose before reading history", async () => {
		const state = scenario({ initial: conversationRow({ purpose: "scheduling" }), history: [] });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);
		expect(response.status).toBe(403);
		expect(state.historyReads).toBe(0);
	});
});

describe("fox conversation public history final gate", () => {
	const history = [
		{ id: "m1", speaker_user_id: USER_A, content: "first", round_number: 1, created_at: "2026-08-24T00:01:00Z" },
		{ id: "m2", speaker_user_id: USER_B, content: "second", round_number: 2, created_at: "2026-08-24T00:02:00Z" },
		{ id: "m3", speaker_user_id: USER_A, content: "third", round_number: 3, created_at: "2026-08-24T00:03:00Z" },
	];

	it("preserves the history projection, order, cursor, limit and envelope", async () => {
		const state = scenario({ history });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(
			`/api/fox-conversations/${CONVERSATION_ID}/messages?limit=2&cursor=2026-08-24T00:04:00Z`,
		);
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: [
				{ id: "m1", speaker: "my_fox", content: "first", round_number: 1, created_at: "2026-08-24T00:01:00Z" },
				{ id: "m2", speaker: "partner_fox", content: "second", round_number: 2, created_at: "2026-08-24T00:02:00Z" },
			],
			next_cursor: "2026-08-24T00:02:00Z",
			has_more: true,
		});
		const historySelect = state.calls.find((call) => call.table === "fox_conversation_messages" && call.method === "select");
		expect(historySelect?.args).toEqual(["id, speaker_user_id, content, round_number, created_at"]);
		expect(state.calls).toContainEqual({ table: "fox_conversation_messages", method: "order", args: ["round_number"] });
		expect(state.calls).toContainEqual({ table: "fox_conversation_messages", method: "lt", args: ["created_at", "2026-08-24T00:04:00Z"] });
		expect(state.calls).toContainEqual({ table: "fox_conversation_messages", method: "limit", args: [3] });
		expect(gateCalls(state)).toHaveLength(2);
	});

	it("fails closed when a message speaker is outside the pinned pair", async () => {
		const state = scenario({
			history: [{ id: "m1", speaker_user_id: OUTSIDER, content: "secret", round_number: 1, created_at: "2026-08-24T00:01:00Z" }],
		});
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);
		expect(response.status).toBe(500);
		expect(await response.text()).not.toContain("secret");
	});

	it.each([
		{ name: "returns a query error", options: { historyError: { message: "history failed" } } },
		{ name: "handles a rejected history promise", options: { throwHistory: true } },
	])("fails closed when the history read $name", async ({ options }) => {
		const state = scenario(options);
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);
		expect(response.status).toBe(500);
		expect(await response.text()).not.toContain("history failed");
	});

	it.each([
		{
			name: "a profile_a block revocation",
			mutate(final: ReturnType<typeof conversationRow>) {
				(final.match.profile_a as Record<string, unknown>).blocks_sent = [{ id: "block-a", blocker_id: USER_A, blocked_id: USER_B }];
			},
		},
		{
			name: "a reverse profile_b block revocation",
			mutate(final: ReturnType<typeof conversationRow>) {
				(final.match.profile_b as Record<string, unknown>).blocks_sent = [{ id: "block-b", blocker_id: USER_B, blocked_id: USER_A }];
			},
		},
		{
			name: "a mutual eligibility revocation",
			mutate(final: ReturnType<typeof conversationRow>) {
				(final.match.profile_a as Record<string, unknown>).preferred_genders = ["man"];
			},
		},
	])("suppresses $name after the history await", async ({ mutate }) => {
		const final = clone(conversationRow());
		mutate(final);
		const state = scenario({ final, history });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);
		expect(response.status).toBe(403);
		expect(state.historyCompleted).toBe(true);
		expect(state.events.indexOf("history:resolved")).toBeLessThan(state.events.indexOf("fox:2"));
		expect(gateCalls(state)).toHaveLength(2);
		for (const gateFilters of gateFilterGroups(state)) {
			expect(gateFilters).toEqual(expect.arrayContaining([
				expect.objectContaining({ args: ["match.profile_a.blocks_sent.blocked_id", USER_B] }),
				expect.objectContaining({ args: ["match.profile_b.blocks_sent.blocked_id", USER_A] }),
			]));
		}
	});

	it.each([
		{ name: "a status transition", final: conversationRow({ matchStatus: "direct_chat_active" }) },
		{ name: "a participant reassignment", final: conversationRow({ userB: USER_C, profileB: profile(USER_C) }) },
		{ name: "a purpose transition", final: conversationRow({ purpose: "scheduling" }) },
		{ name: "a stale detail status", final: conversationRow({ conversationStatus: "failed", matchStatus: "fox_conversation_failed" }) },
	])("suppresses $name after the history await", async ({ final }) => {
		const state = scenario({ final, history });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);
		expect(response.status).toBe(403);
	});

	it("returns an internal error when the final gate query fails", async () => {
		const state = scenario({ history });
		state.foxRows[2] = { data: null, error: { message: "final access failed" } };
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);
		expect(response.status).toBe(500);
		expect(await response.text()).not.toContain("final access failed");
	});
});
