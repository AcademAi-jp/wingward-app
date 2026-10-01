import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "10000000-0000-0000-0000-000000000001");
		await next();
	},
	requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => {
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));
vi.mock("../services/match-age-access", () => ({
	checkVerifiedPair: vi.fn(async () => ({ ok: true })),
	filterVerifiedMatches: vi.fn(async (_supabase: unknown, rows: unknown[]) => ({ ok: true, rows })),
}));

import { getSupabaseClient } from "../db/client";
import matching from "./matching";
import { getProfilePhotoAdapter } from "../services/onboarding-settings";
vi.mock("../services/onboarding-settings", () => ({ getProfilePhotoAdapter: vi.fn(() => null) }));
const photoSign = vi.fn().mockResolvedValue("https://storage.invalid/fresh");

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

const USER_A = "10000000-0000-0000-0000-000000000001";
const USER_B = "10000000-0000-0000-0000-000000000002";
const USER_C = "10000000-0000-0000-0000-000000000003";
const MATCH_A = "20000000-0000-0000-0000-000000000001";
const MATCH_B = "20000000-0000-0000-0000-000000000002";
const CONVERSATION_A = "30000000-0000-0000-0000-000000000001";
const CONVERSATION_B = "30000000-0000-0000-0000-000000000002";

type Mutation = "revoke" | "tuple" | "none";
type State = {
	endpoint: "list" | "detail" | "daily";
	mutation: Mutation;
	finalMutation: Mutation;
	mutateAfter: "persona" | "contact" | null;
	failFinal: boolean;
	pendingConversationNoop: boolean;
	initialMatches: Record<string, unknown>[];
	finalMatches?: Record<string, unknown>[];
	updates: Array<{ table: string; filters: Array<[string, unknown]> }>;
	traces: Array<{ table: string; filters: Array<[string, unknown]> }>;
};

function profile(id: string, gender: "woman" | "man", preferred: "woman" | "man", blocks_sent: unknown[] = []) {
	return {
		id,
		nickname: id,
		avatar_url: null,
 avatar_storage_path: `profile-photos/${id}/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png`,
		age_verified_at: "2026-09-01T00:00:00.000Z",
		gender_identity: gender,
		preferred_genders: [preferred],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-09-01T00:00:00.000Z",
		blocks_sent,
	};
}

function snapshot(matchId: string, conversationId: string, status = "fox_conversation_completed") {
	return {
		id: matchId,
		user_a_id: USER_A,
		user_b_id: USER_B,
		final_score: matchId === MATCH_A ? 0.9 : 0.8,
		profile_score: 0.8,
		conversation_score: 0.7,
		status,
		score_details: { summary: "current" },
		layer_scores: {},
		created_at: matchId === MATCH_A ? "2026-09-01T00:00:00.000Z" : "2026-09-01T00:01:00.000Z",
		profile_a: profile(USER_A, "woman", "man"),
		profile_b: profile(USER_B, "man", "woman"),
		compatibility_conversations: [
			{ id: conversationId, match_id: matchId, purpose: "compatibility", status: "completed" },
		],
	};
}

function initialMatch(matchId: string, score: number) {
	return {
		id: matchId,
		user_a_id: USER_A,
		user_b_id: USER_B,
		final_score: score,
		profile_score: score,
		conversation_score: score,
		status: "fox_conversation_completed",
		score_details: { summary: "initial" },
		created_at: matchId === MATCH_A ? "2026-09-01T00:00:00.000Z" : "2026-09-01T00:01:00.000Z",
	};
}

function buildState(overrides: Partial<State> = {}): State {
	return {
		endpoint: "list",
		mutation: "none",
		finalMutation: "none",
		mutateAfter: null,
		failFinal: false,
		pendingConversationNoop: false,
		initialMatches: [initialMatch(MATCH_A, 0.9), initialMatch(MATCH_B, 0.8)],
		updates: [],
		traces: [],
		...overrides,
	};
}

function resultFor(state: State, table: string, single: boolean): { data: unknown; error: unknown } {
	if (table === "matches") {
		const profileSelect = state.traces[state.traces.length - 1]?.filters.some(([key]) => key === "final_snapshot");
		if (!single && profileSelect) {
			if (state.failFinal) return { data: null, error: { message: "final snapshot failed" } };
			let rows = state.finalMatches ?? [snapshot(MATCH_A, CONVERSATION_A), snapshot(MATCH_B, CONVERSATION_B)];
			rows = rows.map((value) => ({ ...value }));
			if (state.mutation === "revoke") {
				rows = rows.map((value) =>
					value.id === MATCH_A
						? { ...value, profile_a: profile(USER_A, "woman", "man", [{ id: "block-a", blocker_id: USER_A, blocked_id: USER_B }]) }
						: value,
				);
			}
			if (state.mutation === "tuple") {
				rows = rows.map((value) =>
					value.id === MATCH_A
						? { ...value, user_b_id: USER_C, profile_b: profile(USER_C, "man", "woman") }
						: value,
				);
			}
			return { data: rows, error: null };
		}
		if (state.endpoint === "daily" && !single) {
			return {
				data: state.initialMatches.map((match) =>
					match.id === MATCH_B ? { ...match, user_b_id: USER_C } : match,
				),
				error: null,
			};
		}
		return { data: single ? state.initialMatches[0] : state.initialMatches, error: null };
	}
	if (table === "daily_match_pairs") return { data: [{ match_id: MATCH_A }, { match_id: MATCH_B }], error: null };
	if (table === "blocks") return { data: [], error: null };
	if (table === "personas") {
		if (state.endpoint === "list" && state.mutation !== "none") {
			return { data: [{ user_id: USER_B, icon_url: "icon" }], error: null };
		}
		return { data: [{ user_id: USER_B, icon_url: "icon" }], error: null };
	}
	if (table === "user_profiles") {
		if (state.endpoint === "daily") {
			return { data: [profile(USER_B, "man", "woman"), profile(USER_C, "man", "woman")], error: null };
		}
		return { data: [profile(USER_B, "man", "woman")], error: null };
	}
	if (table === "fox_conversations") {
		return { data: [{ id: CONVERSATION_A, match_id: MATCH_A, purpose: "compatibility", status: state.pendingConversationNoop ? "pending" : "completed" }], error: null };
	}
	if (table === "partner_fox_chats" || table === "chat_requests" || table === "direct_chat_rooms") {
		return { data: null, error: null };
	}
	throw new Error("unexpected table " + table);
}

function makeSupabase(state: State) {
	const from = (table: string) => {
		const trace = { table, filters: [] as Array<[string, unknown]> };
		state.traces.push(trace);
		const query: Record<string, unknown> = {};
		let isFinalSnapshot = false;
		let isUpdate = false;
		query.select = (columns: string) => {
			if (table === "matches" && columns.includes("profile_a:user_profiles")) isFinalSnapshot = true;
			return query;
		};
		for (const method of ["eq", "or", "in", "order", "lt", "limit", "is"]) {
			query[method] = (column: string, value: unknown) => {
				if (typeof column === "string") trace.filters.push([method + ":" + column, value]);
				return query;
			};
		}
		query.update = () => {
			isUpdate = true;
			return query;
		};
		query.single = async () => resultFor(state, table, true);
		query.maybeSingle = async () => {
			if (table === "blocks") return { data: null, error: null };
			if (state.mutateAfter === "contact" && table === "partner_fox_chats") state.mutation = state.finalMutation;
			return resultFor(state, table, true);
		};
		query.then = (resolve: (value: { data: unknown; error: unknown }) => unknown, reject?: (reason: unknown) => unknown) => {
			if (isUpdate && table === "fox_conversations") {
				const result = state.pendingConversationNoop
					? { data: [], error: null }
					: { data: [{ id: CONVERSATION_A }], error: null };
				return Promise.resolve(result).then(resolve, reject);
			}
			if (isUpdate) {
				state.updates.push({ table, filters: trace.filters });
				return Promise.resolve({ data: null, error: null }).then(resolve, reject);
			}
			if (table === "matches" && isFinalSnapshot) trace.filters.push(["final_snapshot", true]);
			if (state.mutateAfter === "persona" && table === "personas") state.mutation = state.finalMutation;
			const result = resultFor(state, table, false);
			return Promise.resolve(result).then(resolve, reject);
		};
		return query;
	};
	return { from };
}

function app() {
	const app = new Hono();
	app.route("/api/matching", matching);
	return app;
}

function finalSnapshotTraceIndex(state: State): number {
	return state.traces.findIndex((trace) => trace.table === "matches" && trace.filters.some(([key]) => key === "final_snapshot"));
}

beforeEach(() => {
	vi.clearAllMocks();
 vi.mocked(getProfilePhotoAdapter).mockReturnValue({ storage: { createOwnerReadUrl: photoSign } } as never);
});

describe("matching route final current snapshot", () => {
	it("suppresses revocation during persona await while preserving the filtered pagination envelope", async () => {
		const state = buildState({ finalMutation: "revoke", mutateAfter: "persona" });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);
		const response = await app().request("/api/matching/results?limit=1");
		expect(response.status).toBe(200);
		const body = (await response.json()) as { data: unknown[]; next_cursor: string | null; has_more: boolean };
		expect(body.data).toEqual([]);
 expect(photoSign).not.toHaveBeenCalled();
		expect(body.next_cursor).toBe("2026-09-01T00:00:00.000Z");
		expect(body.has_more).toBe(true);
		const finalIndex = finalSnapshotTraceIndex(state);
		const personaIndex = state.traces.findIndex((trace) => trace.table === "personas");
		expect(finalIndex).toBeGreaterThan(personaIndex);
		expect(finalIndex).toBe(state.traces.length - 1);
	});

	it("suppresses participant reassignment during contact awaits in detail", async () => {
		const state = buildState({ endpoint: "detail", finalMutation: "tuple", mutateAfter: "contact", initialMatches: [initialMatch(MATCH_A, 0.9)] });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);
		const response = await app().request("/api/matching/results/" + MATCH_A);
		expect(response.status).toBe(404);
 expect(photoSign).not.toHaveBeenCalled();
		const body = (await response.json()) as { error: { message: string } };
		expect(body.error.message).toBe("Match not found");
		const blockTrace = state.traces.find((trace) => trace.table === "blocks");
		expect(blockTrace?.filters).toContainEqual(["or:and(blocker_id.eq.10000000-0000-0000-0000-000000000001,blocked_id.eq.10000000-0000-0000-0000-000000000002),and(blocker_id.eq.10000000-0000-0000-0000-000000000002,blocked_id.eq.10000000-0000-0000-0000-000000000001)", undefined]);
		const finalIndex = finalSnapshotTraceIndex(state);
		const contactIndex = state.traces.findIndex((trace) => trace.table === "partner_fox_chats");
		expect(finalIndex).toBeGreaterThan(contactIndex);
		expect(finalIndex).toBe(state.traces.length - 1);
	});

	it("returns an internal error when the final embedded query fails", async () => {
		const state = buildState({ endpoint: "detail", failFinal: true, initialMatches: [initialMatch(MATCH_A, 0.9)] });
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);
		const response = await app().request("/api/matching/results/" + MATCH_A);
		expect(response.status).toBe(500);
		expect(finalSnapshotTraceIndex(state)).toBe(state.traces.length - 1);
	});

	it("computes daily counts only from final visible rows", async () => {
		const state = buildState({
			endpoint: "daily",
			finalMatches: [
				snapshot(MATCH_A, CONVERSATION_A, "fox_conversation_completed"),
				{
					...snapshot(MATCH_B, CONVERSATION_B, "fox_conversation_failed"),
					user_b_id: USER_C,
					profile_b: profile(USER_C, "man", "woman", [{ id: "block-b", blocker_id: USER_C, blocked_id: USER_A }]),
				},
			],
		});
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);
		const response = await app().request("/api/matching/daily-results?date=2026-09-01");
		expect(response.status).toBe(200);
		const body = (await response.json()) as { data: { matches: unknown[]; total_matches: number; conversations_completed: number; conversations_failed: number; is_new: boolean } };
		expect(body.data.matches).toHaveLength(1);
 expect(photoSign).toHaveBeenCalledTimes(1);
 expect(JSON.stringify(body)).not.toContain("avatar_storage_path");
		expect(body.data.total_matches).toBe(1);
		expect(body.data.conversations_completed).toBe(1);
		expect(body.data.conversations_failed).toBe(0);
		expect(body.data.is_new).toBe(true);
		expect(body.data.matches[0]).toMatchObject({
			id: MATCH_A,
			partner_id: USER_B,
			partner: { nickname: USER_B, avatar_url: "https://storage.invalid/fresh", persona_icon_url: "icon" },
		});
		expect(JSON.stringify(body.data.matches[0])).not.toContain("preferred_genders");
		expect(JSON.stringify(body.data.matches[0])).not.toContain("blocks_sent");
		const finalIndex = finalSnapshotTraceIndex(state);
		const profileIndex = state.traces.findIndex((trace) => trace.table === "user_profiles");
		expect(finalIndex).toBeGreaterThan(profileIndex);
		expect(finalIndex).toBe(state.traces.length - 1);
	});

	it("leaves the match unchanged when a pending conversation CAS loses a race", async () => {
		const pendingMatch = {
			...initialMatch(MATCH_A, 0.9),
			status: "fox_conversation_in_progress",
			created_at: "2020-01-01T00:00:00.000Z",
		};
		const state = buildState({
			pendingConversationNoop: true,
			initialMatches: [pendingMatch],
		});
		mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);
		const response = await app().request("/api/matching/results?limit=1");
		expect(response.status).toBe(200);
		expect(state.updates.some((update) => update.table === "matches")).toBe(false);
		const conversationUpdateIndex = state.traces.findIndex((trace) => trace.table === "fox_conversations" && trace.filters.some(([filterKey, value]) => filterKey === "eq:status" && value === "pending"));
		expect(conversationUpdateIndex).toBeGreaterThanOrEqual(0);
		const finalIndex = finalSnapshotTraceIndex(state);
		expect(finalIndex).toBeGreaterThan(conversationUpdateIndex);
		expect(finalIndex).toBe(state.traces.length - 1);
	});
});

 it.each(["list", "detail"] as const)("renews authorized %s photos without exposing paths", async (endpoint) => {
  const state = buildState({ endpoint, initialMatches: [initialMatch(MATCH_A, 0.9)] });
  mockedGetSupabaseClient.mockReturnValue(makeSupabase(state) as never);
  const response = await app().request("/api/matching/results" + (endpoint === "detail" ? "/" + MATCH_A : ""));
  expect(response.status).toBe(200);
  const body = await response.text();
  expect(body).toContain("https://storage.invalid/fresh");
  expect(body).not.toContain("avatar_storage_path");
  expect(photoSign).toHaveBeenCalledWith(USER_B, `profile-photos/${USER_B}/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png`, 300);
 });
