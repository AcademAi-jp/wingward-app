import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "user-a");
		await next();
	},
	requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => {
		await next();
	},
}));

vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import { errorHandler } from "../middleware/error";
import foxConversations from "./fox-conversations";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

const MATCH_ID = "22222222-2222-4222-8222-222222222222";
const CONVERSATION_ID = "conversation-existing";
const MESSAGE_ERROR = { message: "PWNED-CANARY-MESSAGE-READ" };

type Call = { table: string; method: string; args: unknown[] };

/**
 * This fake behaves like a service-role client and returns the embedded
 * participant rows even when the current eligibility gate must deny access.
 * That keeps these tests focused on the route's derived-content boundary.
 */
function makeServiceRoleLikeSupabase(opts: {
	conversationError?: { message: string } | null;
	matchError?: { message: string } | null;
	messageError?: { message: string } | null;
	counterpartyVerified?: boolean;
} = {}) {
	const calls: Call[] = [];
	const conversation = {
		id: CONVERSATION_ID,
		match_id: MATCH_ID,
		status: "completed",
		purpose: "compatibility",
		total_rounds: 10,
		current_round: 10,
		started_at: "2026-08-24T00:00:00Z",
		completed_at: "2026-08-24T00:10:00Z",
		conversation_analysis: "conversation-derived-secret",
		match: {
			id: MATCH_ID,
			user_a_id: "user-a",
			user_b_id: "user-b",
			status: "fox_conversation_completed",
			profile_a: {
				id: "user-a",
				age_verified_at: "2026-08-24T00:00:00Z",
				gender_identity: "woman",
				preferred_genders: ["woman"],
				preference_mode: "selected",
				dating_market: "JP",
				onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
				blocks_sent: [],
			},
			profile_b: {
				id: "user-b",
				age_verified_at: opts.counterpartyVerified === false ? null : "2026-08-24T00:00:00Z",
				gender_identity: "woman",
				preferred_genders: ["woman"],
				preference_mode: "selected",
				dating_market: "JP",
				onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
				blocks_sent: [],
			},
		},
	};
	const message = {
		id: "conversation-message-secret",
		speaker_user_id: "user-b",
		content: "message-derived-secret",
		round_number: 1,
		created_at: "2026-08-24T00:00:00Z",
	};
	let foxReadCount = 0;

	const from = (table: string) => {
		const query: Record<string, unknown> = {};
		const record = (method: string, args: unknown[]) => calls.push({ table, method, args });

		for (const method of ["select", "eq", "order", "lt", "limit"]) {
			query[method] = (...args: unknown[]) => {
				record(method, args);
				return query;
			};
		}
		query.single = async () => {
			record("single", []);
			if (table === "fox_conversations") {
				const error = foxReadCount++ === 0 ? opts.conversationError ?? null : opts.matchError ?? null;
				return { data: conversation, error };
			}
			return { data: null, error: null };
		};
		query.then = (
			resolve: (value: { data: unknown; error: unknown }) => unknown,
			reject?: (reason: unknown) => unknown,
		) => {
			const result = table === "fox_conversation_messages"
				? { data: opts.messageError ? null : [message], error: opts.messageError }
				: { data: null, error: null };
			return Promise.resolve(result).then(resolve, reject);
		};
		return query;
	};

	return { from, calls };
}

function buildApp() {
	const app = new Hono();
	app.onError(errorHandler);
	app.route("/api/fox-conversations", foxConversations);
	return app;
}

beforeEach(() => {
	mockedGetSupabaseClient.mockReset();
});

describe("fox-conversations blocks derived content for an unverified counterparty", () => {
	it("GET detail returns FORBIDDEN before returning the conversation row", async () => {
		const supabase = makeServiceRoleLikeSupabase({ counterpartyVerified: false });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}`);

		expect(response.status).toBe(403);
		expect(await response.text()).not.toContain("derived-secret");
		expect(supabase.calls).not.toEqual(expect.arrayContaining([
			expect.objectContaining({ table: "fox_conversation_messages" }),
	]));
	});

	it("GET messages returns FORBIDDEN before reading conversation messages", async () => {
		const supabase = makeServiceRoleLikeSupabase({ counterpartyVerified: false });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);

		expect(response.status).toBe(403);
		expect(await response.text()).not.toContain("derived-secret");
		expect(supabase.calls).not.toEqual(expect.arrayContaining([
			expect.objectContaining({ table: "fox_conversation_messages" }),
		]));
	});

	it("GET messages returns an error instead of an empty transcript when the message read fails", async () => {
		const supabase = makeServiceRoleLikeSupabase({ messageError: MESSAGE_ERROR });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-MESSAGE-READ");
	});

	it.each([
		{ name: "conversation", options: { conversationError: { message: "PWNED-CANARY-CONVERSATION" } } },
		{ name: "match", options: { matchError: { message: "PWNED-CANARY-MATCH" } } },
	] as const)("GET messages fails closed when the $name access read fails", async ({ options }) => {
		const supabase = makeServiceRoleLikeSupabase(options);
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request(`/api/fox-conversations/${CONVERSATION_ID}/messages`);
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toMatch(/PWNED-CANARY/);
	});
});
