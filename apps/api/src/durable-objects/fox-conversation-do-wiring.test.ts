import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";

/**
 * Step-3d, acceptance condition 5 (the core of this PR): guards that the
 * PRODUCTION path — `FoxConversationDO.alarm()` — actually reaches the token
 * accounting inside services/fox-conversation-engine.ts and persists
 * input_tokens/output_tokens/cache_hit_tokens onto the `fox_conversations`
 * row.
 *
 * This is the exact regression PR #22 (step-3b) shipped without anyone
 * noticing: token accounting was added only to the service (local-dev
 * fallback) path, tests passed, real-API measurement passed, and the DO path
 * that actually runs in production wrote nothing. This test is what would
 * have caught that.
 *
 * Its negative control was verified by hand rather than encoded as a second
 * describe block (a test that edits source files on disk is worse than the
 * regression it guards against). Two breakages were applied to the working
 * tree and reverted, on 2026-08-13:
 *   1. removing `...tokenTotalsForUpdate()` from the engine's terminal
 *      `status: "completed"` update -> this test AND the three
 *      fox-conversation-token-retry.test.ts token tests fail (4 total).
 *   2. an early `return` in alarm() before the runConversationLoop call, so
 *      only the DO -> engine wiring is broken and the service path is intact
 *      -- the exact shape of the step-3b regression -> ONLY this test fails
 *      (1 of 118). Re-run that experiment if this file is ever refactored.
 *
 * `cloudflare:workers` is not resolvable under plain vitest (no
 * @cloudflare/vitest-pool-workers in this project), so it is mocked with a
 * minimal shim exposing exactly what FoxConversationDO extends — the
 * `DurableObject` base class contributes nothing to alarm()'s logic itself,
 * it only supplies `this.ctx` / `this.env` typing, so mocking it does not
 * change what is under test.
 */

vi.mock("cloudflare:workers", () => ({
	DurableObject: class {
		ctx: unknown;
		env: unknown;
		constructor(ctx: unknown, env: unknown) {
			this.ctx = ctx;
			this.env = env;
		}
	},
}));

vi.mock("../services/mistral", () => ({
	chatCompleteWithUsage: vi.fn(),
}));

import { chatCompleteWithUsage } from "../services/mistral";
import { runFoxConversation } from "../services/fox-conversation";
import { runConversationLoop } from "../services/fox-conversation-engine";
import { FoxConversationDO } from "./fox-conversation-do";

const CONVERSATION_ID = "conv-do-1";
const MATCH_ID = "match-do-1";
const USER_A = "user-do-a";
const USER_B = "user-do-b";

type CapturedUpdate = Record<string, unknown>;

interface FakeMessage {
	speaker_user_id: string;
	content: string;
	round_number: number;
}

interface FakeOptions {
	/** id returned by `user_profiles.select("id").eq("auth_user_id", ...).single()`, i.e. the WS caller's resolved profile id. Only consulted for that auth_user_id lookup path — the pre-existing `.in("id", ...)` path used by the engine is untouched. */
	authProfileId?: string;
	/** `fox_conversations.total_rounds`, as read by the catch-up query. Defaults to the pre-existing 1 used by the alarm()/engine tests. */
	totalRounds?: number;
	/** Rows returned by `fox_conversation_messages` for catch-up, already in `round_number` order (mirrors what `.order("round_number")` would produce). Defaults to the pre-existing empty array. */
	messages?: FakeMessage[];
	/**
	 * How many times the checkpoint token-only update (the shape produced by
	 * `tokenTotalsForUpdate()`: has `input_tokens` but no `status` key — this
	 * is what distinguishes it from the terminal `status: "completed"` update
	 * and from the per-round `current_round`-only update) resolves with
	 * `{ error }` before it starts succeeding. `0` (default) means it always
	 * succeeds; `Number.POSITIVE_INFINITY` means it always fails.
	 */
	checkpointUpdateFailures?: number;
	/**
	 * When true, every non-insert `fox_conversation_messages` query (the
	 * "existing messages for resume" select at the top of the loop, and the
	 * "all messages" select before scoring) resolves with `{ data: null,
	 * error }` instead of the fake's normal rows. Used by E-1/E-2 to verify
	 * `runConversationLoop` throws on that error rather than silently
	 * treating it as "no messages yet, start from round 1".
	 */
	messagesSelectError?: boolean;
	/** Deny the Nth strict current-access profile lookup onward (for catch-up races). */
	denyCurrentAccessAfter?: number;
	/** Revoke access immediately after the engine persists a round checkpoint. */
	revokeAccessOnCurrentRoundUpdate?: boolean;
	/** Revoke access immediately after terminal conversation persistence. */
	revokeAccessOnCompletionUpdate?: boolean;
	/** Move both rows to their terminal state during the access read itself. */
	terminalizeOnBlockLookup?: boolean;
}

/**
 * Mirrors fox-conversation-token-retry.test.ts's fake, scoped to what
 * alarm() -> runConversationLoop needs. `fox_conversation_messages` and the
 * mutable subset of the `fox_conversations` row (current_round, the token
 * columns) are held in closure state across queries — and across repeated
 * `alarm()` calls against the same fake, which the budget-limited-alarm
 * tests rely on to simulate a conversation resuming across multiple
 * invocations. The original two describe blocks below only ever insert 0 or
 * 1 message and call `alarm()` at most once, so this mutability is a
 * superset of what they exercised, not a behavior change for them.
 */
function buildSupabaseFake(options: FakeOptions = {}) {
	const {
		authProfileId,
		totalRounds = 1,
		messages: initialMessages = [],
		checkpointUpdateFailures = 0,
		messagesSelectError = false,
		denyCurrentAccessAfter,
		revokeAccessOnCurrentRoundUpdate = false,
		revokeAccessOnCompletionUpdate = false,
		terminalizeOnBlockLookup = false,
	} = options;
	const foxConversationUpdates: CapturedUpdate[] = [];
	const matchUpdates: CapturedUpdate[] = [];
	const messages: FakeMessage[] = [...initialMessages];
	const convMutable: Record<string, unknown> = {
		current_round: 0,
		input_tokens: null,
		output_tokens: null,
		cache_hit_tokens: null,
		status: "in_progress",
	};
	let checkpointUpdateCalls = 0;
	let matchStatus = "fox_conversation_in_progress";
	let currentAccessChecks = 0;
	let currentAccessRevoked = false;

	function makeCurrentAccessRow(denyAccess: boolean) {
		const profileRows = [
			{
				id: USER_A,
				age_verified_at: denyAccess ? null : "2026-08-24T00:00:00Z",
				gender_identity: "woman",
				preferred_genders: ["woman"],
				preference_mode: "selected",
				dating_market: "JP",
				onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
			},
			{
				id: USER_B,
				age_verified_at: denyAccess ? null : "2026-08-24T00:00:00Z",
				gender_identity: "woman",
				preferred_genders: ["woman"],
				preference_mode: "selected",
				dating_market: "JP",
				onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
			},
		];
		return {
			id: CONVERSATION_ID,
			match_id: MATCH_ID,
			status: convMutable.status,
			match: {
				id: MATCH_ID,
				user_a_id: USER_A,
				user_b_id: USER_B,
				status: matchStatus,
				profile_a: { ...profileRows[0], blocks_sent: currentAccessRevoked ? [{ id: "revoked-a-to-b", blocker_id: USER_A, blocked_id: USER_B }] : [] },
				profile_b: { ...profileRows[1], blocks_sent: [] },
			},
		};
	}

	interface QueryState {
		select?: string;
		eq?: [string, unknown][];
		in?: [string, unknown[]];
		update?: Record<string, unknown>;
		insert?: Record<string, unknown>;
		upsert?: Record<string, unknown>;
	}

	function makeQuery(resolve: (state: QueryState) => { data: unknown; error: unknown }) {
		const state: QueryState = {};
		const builder = {
			select(cols: string) {
				state.select = cols;
				return builder;
			},
			eq(col: string, val: unknown) {
				(state.eq ??= []).push([col, val]);
				return builder;
			},
			in(col: string, vals: unknown[]) {
				state.in = [col, vals];
				return builder;
			},
			order() {
				return builder;
			},
			update(obj: Record<string, unknown>) {
				state.update = obj;
				return builder;
			},
			insert(obj: Record<string, unknown>) {
				state.insert = obj;
				return builder;
			},
			upsert(obj: Record<string, unknown>) {
				state.upsert = obj;
				return builder;
			},
			or() {
				return builder;
			},
			limit() {
				return builder;
			},
			single() {
				return Promise.resolve().then(() => resolve(state));
			},
			maybeSingle() {
				return Promise.resolve().then(() => resolve(state));
			},
			then(onFulfilled: (v: unknown) => unknown, onRejected?: (e: unknown) => unknown) {
				return Promise.resolve()
					.then(() => resolve(state))
					.then(onFulfilled, onRejected);
			},
		};
		return builder;
	}

	function matchesEq(state: QueryState, column: string, expected: unknown): boolean {
		return !(state.eq ?? []).some(([name, value]) => name === column && value !== expected);
	}

	function matchesIn(state: QueryState, column: string, current: unknown): boolean {
		const filter = state.in;
		return !filter || filter[0] !== column || filter[1].includes(current);
	}

	const supabase = {
		from(table: string) {
			return makeQuery((state) => {
				switch (table) {
					case "fox_conversations": {
						if ((state.select ?? "").includes("match:matches!")) {
							currentAccessChecks++;
							const denyCurrentAccess = denyCurrentAccessAfter !== undefined && currentAccessChecks >= denyCurrentAccessAfter;
							const data = makeCurrentAccessRow(denyCurrentAccess || currentAccessRevoked);
							if (terminalizeOnBlockLookup) {
								// Return the pre-transition snapshot, then expose the terminal
								// state to the next logical access read.
								convMutable.status = "completed";
								matchStatus = "fox_conversation_completed";
							}
							return { data, error: null };
						}
						if (state.update) {
							const isCheckpointOnlyUpdate =
								Object.prototype.hasOwnProperty.call(state.update, "input_tokens") &&
								!Object.prototype.hasOwnProperty.call(state.update, "status");
							if (isCheckpointOnlyUpdate) {
								checkpointUpdateCalls++;
								if (checkpointUpdateCalls <= checkpointUpdateFailures) {
									return { data: null, error: { message: `simulated checkpoint failure #${checkpointUpdateCalls}` } };
								}
							}
							if (
								!matchesEq(state, "id", CONVERSATION_ID) ||
								!matchesEq(state, "match_id", MATCH_ID) ||
								!matchesIn(state, "status", convMutable.status)
							) {
								return { data: null, error: null };
							}
							foxConversationUpdates.push(state.update);
							Object.assign(convMutable, state.update);
							if (revokeAccessOnCurrentRoundUpdate && Object.prototype.hasOwnProperty.call(state.update, "current_round")) {
								currentAccessRevoked = true;
							}
							if (revokeAccessOnCompletionUpdate && state.update.status === "completed") {
								currentAccessRevoked = true;
							}
							return { data: null, error: null };
						}
						return {
							data: {
								id: CONVERSATION_ID,
								match_id: MATCH_ID,
								total_rounds: totalRounds,
								...convMutable,
							},
							error: null,
						};
					}
					case "fox_conversation_messages": {
						if (state.insert) {
							const row = state.insert as unknown as FakeMessage;
							messages.push({
								speaker_user_id: row.speaker_user_id,
								content: row.content,
								round_number: row.round_number,
							});
							return { data: null, error: null };
						}
						if (messagesSelectError) {
							return { data: null, error: { message: "simulated fox_conversation_messages select failure" } };
						}
						return { data: [...messages].sort((a, b) => a.round_number - b.round_number), error: null };
					}
					case "matches": {
						if (state.update) {
							if (
								!matchesEq(state, "id", MATCH_ID) ||
								!matchesEq(state, "user_a_id", USER_A) ||
								!matchesEq(state, "user_b_id", USER_B) ||
								!matchesEq(state, "status", matchStatus) ||
								!matchesIn(state, "status", matchStatus)
							) {
								return { data: null, error: null };
							}
							matchUpdates.push(state.update);
							if (typeof state.update.status === "string") matchStatus = state.update.status;
							return { data: { id: MATCH_ID }, error: null };
						}
						const cols = state.select ?? "";
						if (cols.includes("user_a_id")) {
							return { data: { id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: matchStatus }, error: null };
						}
						return { data: { profile_score: 50, score_details: {} }, error: null };
					}
					case "personas": {
						const userId = state.eq?.find(([col]) => col === "user_id")?.[1];
						return {
							data: {
								compiled_document: `persona document for ${userId}`,
								name: userId === USER_A ? "Alice" : "Bob",
							},
							error: null,
						};
					}
					case "user_profiles": {
						// Vestigial as of step-3c: this branch existed for the in-band
						// `auth` message's `.eq("auth_user_id", ...).single()` lookup,
						// which no longer exists (auth now happens at the edge, before
						// this DO is reached — see resolveWsAccess). No current test
						// configures `authProfileId`, so this branch is unreachable;
						// left in place only because the `.in("id", [...])` lookup below
						// it is still live and this fake is a single shared `from()`
						// dispatcher.
						const authUserIdLookup = state.eq?.find(([col]) => col === "auth_user_id");
						if (authUserIdLookup) {
							if (authProfileId === undefined) {
								throw new Error(
									"fox-conversation-do-wiring.test.ts fake: user_profiles auth_user_id lookup hit but no authProfileId configured",
								);
							}
							return { data: { id: authProfileId }, error: null };
						}
						const profileRows = [
								{
									id: USER_A,
									gender: "female",
									language: "ja",
									age_verified_at: "2026-08-24T00:00:00Z",
									gender_identity: "woman",
									preferred_genders: ["woman"],
									preference_mode: "selected",
									dating_market: "JP",
									onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
								},
								{
									id: USER_B,
									gender: "male",
									language: "ja",
									age_verified_at: "2026-08-24T00:00:00Z",
									gender_identity: "woman",
									preferred_genders: ["woman"],
									preference_mode: "selected",
									dating_market: "JP",
									onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
								},
							];
						return {
							data: profileRows,
							error: null,
						};
					}
					case "blocks": {
						return { data: currentAccessRevoked ? [{ id: "revoked" }] : null, error: null };
					}
					case "interaction_dna_scores": {
						if (state.upsert) {
							// Deliberately throws so the 3-layer scoring branch falls back
							// to simple scoring — this test isn't about that path.
							throw new Error("interaction_dna_scores unavailable (test double)");
						}
						return { data: [], error: null };
					}
					default:
						throw new Error(`fox-conversation-do-wiring.test.ts fake: unhandled table "${table}"`);
				}
			});
		},
	};

	return {
		supabase,
		foxConversationUpdates,
		matchUpdates,
		getMessages: () => [...messages],
		getCheckpointUpdateCalls: () => checkpointUpdateCalls,
		setCurrentState: (next: { conversationStatus?: string; matchStatus?: string }) => {
			if (next.conversationStatus) convMutable.status = next.conversationStatus;
			if (next.matchStatus) matchStatus = next.matchStatus;
		},
	};
}

function scorePayload() {
	return JSON.stringify({
		score: 80,
		excitement_level: 0.5,
		common_topics: [],
		mutual_interest: 0.5,
		topic_distribution: [],
		feature_scores: {
			reciprocity: 0.5,
			humor_sharing: 0.5,
			self_disclosure: 0.5,
			emotional_responsiveness: 0.5,
			self_esteem: 0.5,
			conflict_resolution: 0.5,
		},
	});
}

/** Minimal DurableObjectState stand-in: an in-memory `storage` map plus a no-op WebSocket list. */
function makeFakeCtx(initialState: unknown) {
	const store = new Map<string, unknown>();
	store.set("state", initialState);
	return {
		storage: {
			get: vi.fn(async (key: string) => store.get(key)),
			put: vi.fn(async (key: string, value: unknown) => {
				store.set(key, value);
			}),
			setAlarm: vi.fn(async () => undefined),
		},
		getWebSockets: () => [],
	};
}

function makeInProgressState() {
	return {
		conversationId: CONVERSATION_ID,
		matchId: MATCH_ID,
		userA: USER_A,
		userB: USER_B,
		status: "in_progress" as const,
	};
}

const mockedChatCompleteWithUsage = vi.mocked(chatCompleteWithUsage);

beforeEach(() => {
	mockedChatCompleteWithUsage.mockReset();
});

afterEach(() => {
	vi.restoreAllMocks();
});

describe("FoxConversationDO /init Supabase persistence", () => {
	it("returns 500 and does not schedule when the in-progress update fails", async () => {
		function query(result: unknown) {
			const builder: Record<string, unknown> = {};
			for (const method of ["select", "eq", "update", "single"]) builder[method] = () => builder;
			builder.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve(result).then(resolve, reject);
			return builder;
		}
		let conversationCalls = 0;
		const supabase = {
			from(table: string) {
				if (table === "matches") return query({ data: { user_a_id: USER_A, user_b_id: USER_B }, error: null });
				if (table === "personas") return query({ data: { compiled_document: "persona" }, error: null });
				if (table === "fox_conversations") {
					conversationCalls += 1;
					return query({ data: null, error: conversationCalls === 1 ? { message: "canary" } : null });
				}
				throw new Error(`unexpected table ${table}`);
			},
		};
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;
		const ctx = makeFakeCtx(undefined);
		const instance = new FoxConversationDO(ctx as never, { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" } as never);
		const response = await instance.fetch(new Request("https://do/init", {
			method: "POST",
			body: JSON.stringify({ conversationId: CONVERSATION_ID, matchId: MATCH_ID }),
		}));
		expect(response.status).toBe(500);
		expect(ctx.storage.setAlarm).not.toHaveBeenCalled();
	});
});

describe("FoxConversationDO.alarm() reaches the engine and persists token accounting", () => {
	it("writes input_tokens/output_tokens/cache_hit_tokens onto fox_conversations after a successful run", async () => {
		const { supabase, foxConversationUpdates } = buildSupabaseFake();
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({
				content: "Hi there!",
				usage: { inputTokens: 10, outputTokens: 5, cachedTokens: 2 },
			})
			.mockResolvedValueOnce({
				content: scorePayload(),
				usage: { inputTokens: 50, outputTokens: 20, cachedTokens: 3 },
			});

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		// This fake's total_rounds defaults to 1, so the first alarm() types
		// that single round and — per the Codex 3rd-review P1 fix (an
		// invocation that processed >=1 round never also scores) — returns
		// incomplete rather than completing in the same call. The second
		// alarm() processes 0 rounds and runs scoring. See the D-1/D-2
		// describe block below for the fix itself; this test only cares that
		// token accounting still reaches fox_conversations once the
		// conversation actually completes.
		await doInstance.alarm();
		expect(foxConversationUpdates.some((u) => u.status === "completed")).toBe(false);
		await doInstance.alarm();

		const terminalUpdate = foxConversationUpdates.at(-1);
		expect(terminalUpdate).toMatchObject({
			status: "completed",
			input_tokens: 10 + 50,
			output_tokens: 5 + 20,
			cache_hit_tokens: 2 + 3,
		});

		// The loop's own invocation now ends at `notifying`, not `completed`:
		// N-01 was given its own alarm invocation so it never shares this one's
		// subrequest budget (Codex P1 on PR #31). Every database write for the
		// conversation is already done here — only the push is left.
		const afterLoop = await ctx.storage.get("state");
		expect((afterLoop as { status: string }).status).toBe("notifying");

		await doInstance.alarm(); // the notify-only invocation
		const finalState = await ctx.storage.get("state");
		expect((finalState as { status: string }).status).toBe("completed");
	});
});

describe("FoxConversationDO.alarm(): current output and stale-cleanup races", () => {
	it("suppresses a round broadcast when access is revoked after round persistence", async () => {
		const { supabase, foxConversationUpdates } = buildSupabaseFake({ revokeAccessOnCurrentRoundUpdate: true });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;
		mockedChatCompleteWithUsage.mockResolvedValueOnce({
			content: "paid round",
			usage: { inputTokens: 11, outputTokens: 7, cachedTokens: 2 },
		});

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);
		const broadcastSpy = vi.spyOn(doInstance as unknown as { broadcast: (message: unknown) => void }, "broadcast");

		await doInstance.alarm();

		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1);
		expect(foxConversationUpdates).toContainEqual({ input_tokens: 11, output_tokens: 7, cache_hit_tokens: 2 });
		expect(foxConversationUpdates.some((update) => "current_round" in update)).toBe(true);
		expect(broadcastSpy.mock.calls.some(([message]) => (message as { type?: string }).type === "round_message")).toBe(false);
	});

	it("suppresses completed output after terminal persistence when access is revoked", async () => {
		const { supabase, foxConversationUpdates, matchUpdates } = buildSupabaseFake({ revokeAccessOnCompletionUpdate: true });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({ content: "round one", usage: { inputTokens: 3, outputTokens: 2, cachedTokens: null } })
			.mockResolvedValueOnce({ content: scorePayload(), usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null } });

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);
		const broadcastSpy = vi.spyOn(doInstance as unknown as { broadcast: (message: unknown) => void }, "broadcast");

		await doInstance.alarm();
		await doInstance.alarm();

		expect(foxConversationUpdates.some((update) => update.status === "completed")).toBe(true);
		expect(matchUpdates.some((update) => update.status === "fox_conversation_completed")).toBe(true);
		expect(foxConversationUpdates.some((update) => update.status === "failed")).toBe(false);
		expect(matchUpdates.some((update) => update.status === "fox_conversation_failed")).toBe(false);
		expect(broadcastSpy.mock.calls.some(([message]) => (message as { type?: string }).type === "completed")).toBe(false);
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("notifying");
	});

	it("preserves terminal rows when a stale failure cleanup races their closure", async () => {
		const { supabase, foxConversationUpdates, matchUpdates } = buildSupabaseFake({ terminalizeOnBlockLookup: true });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		await doInstance.alarm();

		expect(foxConversationUpdates.some((update) => update.status === "failed")).toBe(false);
		expect(matchUpdates.some((update) => update.status === "fox_conversation_failed")).toBe(false);
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("failed");
	});
});

/**
 * Step-3c, acceptance conditions 4/5/9: `resolveWsAccess` (called from
 * `handleWebSocketUpgrade`, which itself can't be unit-tested directly
 * because it constructs `WebSocketPair`, unavailable under plain vitest —
 * see the module doc comment above `handleWebSocketUpgrade`) is where G1's
 * fail-closed fix lives. Authentication itself now happens at the edge
 * (routes/fox-search-ws.ts, covered by fox-search-ws.test.ts); this DO
 * trusts the already-verified user id it's handed and only re-checks match
 * participation as defense in depth.
 *
 * C2 (step-3c review, Codex P2): `resolveWsAccess` no longer builds the
 * catch-up snapshot itself — it only decides authorization and returns
 * `state`. `handleWebSocketUpgrade` calls `buildCatchUpMessage(state)`
 * separately, AFTER `acceptWebSocket()`, so a round broadcast during those
 * Supabase reads reaches the (already-registered) socket instead of being
 * silently dropped. `buildCatchUpMessage` is tested directly below since
 * `resolveWsAccess` no longer wraps it.
 */
describe("FoxConversationDO.resolveWsAccess: handshake authorization", () => {
	function getResolveWsAccess(doInstance: FoxConversationDO) {
		return (
			doInstance as unknown as {
				resolveWsAccess: (
					verifiedUserId: string | null,
				) => Promise<{ authorized: false } | { authorized: true; userId: string; state: unknown }>;
			}
		).resolveWsAccess.bind(doInstance);
	}

	function getBuildCatchUpMessage(doInstance: FoxConversationDO) {
		return (
			doInstance as unknown as {
				buildCatchUpMessage: (state: unknown) => Promise<{ total_rounds: number; current_round: number; messages: unknown[] }>;
			}
		).buildCatchUpMessage.bind(doInstance);
	}

	it("condition 4/9: authorizes a participant, and buildCatchUpMessage (called after, as handleWebSocketUpgrade does) assembles the snapshot from fox_conversation_messages and fox_conversations.total_rounds", async () => {
		// Mixed A/B speakers, out of insertion order but already round_number-sorted
		// (as `.order("round_number")` would return), so the speaker-resolution
		// and ordering logic are both exercised.
		const messages = [
			{ speaker_user_id: USER_B, content: "hi from B", round_number: 1 },
			{ speaker_user_id: USER_A, content: "hi from A", round_number: 2 },
			{ speaker_user_id: USER_B, content: "second from B", round_number: 3 },
		];
		// Deliberately not 10 or 15 (the DO's historical/other hardcoded
		// defaults) so a hardcoded total_rounds would fail this assertion.
		const TOTAL_ROUNDS = 7;
		const { supabase } = buildSupabaseFake({ totalRounds: TOTAL_ROUNDS, messages });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		const access = await getResolveWsAccess(doInstance)(USER_A);

		expect(access.authorized).toBe(true);
		if (!access.authorized) throw new Error("unreachable");
		expect((access as { catchUp?: unknown }).catchUp).toBeUndefined(); // catch-up is no longer built here (C2)

		const catchUp = await getBuildCatchUpMessage(doInstance)(access.state);
		expect(catchUp.total_rounds).toBe(TOTAL_ROUNDS);
		expect(catchUp.current_round).toBe(messages.length);
		expect(catchUp.messages).toEqual([
			{ round_number: 1, speaker: "B", content: "hi from B" },
			{ round_number: 2, speaker: "A", content: "hi from A" },
			{ round_number: 3, speaker: "B", content: "second from B" },
		]);
	});

	it("condition 2/4: denies access when the verified user is neither userA nor userB", async () => {
		const OTHER_USER = "user-do-outsider";
		const { supabase } = buildSupabaseFake({ totalRounds: 7, messages: [] });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		const access = await getResolveWsAccess(doInstance)(OTHER_USER);

		expect(access.authorized).toBe(false);
	});

	/**
	 * Condition 5 / gap G1's negative control (step-3 §4-C-4-5, AGENTS.md
	 * Code Review Rules): a DO with no `state` at all (e.g. `/init` returned
	 * early on a missing persona, before ever calling `storage.put("state",
	 * ...)`) must be rejected, not treated as "no restriction". The old
	 * shape (`if (state && A && B)`) made the whole check vacuously false —
	 * and therefore authorized everyone — when `state` was undefined.
	 *
	 * This experiment was actually run and reverted on 2026-08-13: reverting
	 * `resolveWsAccess`'s `if (!state || ...)` back to the old
	 * `if (state && ...)` shape made this exact test fail (it started
	 * asserting `authorized: false` but got `true`); no other test in this
	 * file was affected by that single-line revert.
	 */
	it("condition 5 (G1 negative control): denies access when the DO has no state, even for a plausible-looking user id", async () => {
		const { supabase } = buildSupabaseFake({ totalRounds: 7, messages: [] });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		const ctx = makeFakeCtx(undefined); // no "state" key written at all
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		const access = await getResolveWsAccess(doInstance)(USER_A);

		expect(access.authorized).toBe(false);
	});

	it("denies access when no verified user id is provided at all", async () => {
		const { supabase } = buildSupabaseFake({ totalRounds: 7, messages: [] });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		const access = await getResolveWsAccess(doInstance)(null);

		expect(access.authorized).toBe(false);
	});
});

/**
 * Condition 6: the in-band `{type:"auth"}` message must no longer function
 * as an authentication path — it isn't even a recognized `ClientMessage`
 * shape anymore, so `webSocketMessage` should just fall through and do
 * nothing (no `pong`, no state change) rather than authenticate the socket.
 */
describe("FoxConversationDO.webSocketMessage: in-band auth message is inert", () => {
	function makeFakeWs(authenticated: boolean) {
		return {
			send: vi.fn(),
			close: vi.fn(),
			serializeAttachment: vi.fn(),
			deserializeAttachment: vi.fn(() => (authenticated ? { authenticated: true, userId: USER_A } : null)),
		};
	}

	it("an {type:'auth', token} message produces no response and no attachment change", async () => {
		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);
		const ws = makeFakeWs(false);

		await doInstance.webSocketMessage(ws as never, JSON.stringify({ type: "auth", token: "some-jwt" }));

		expect(ws.send).not.toHaveBeenCalled();
		expect(ws.serializeAttachment).not.toHaveBeenCalled();
		expect(ws.close).not.toHaveBeenCalled();
	});

	it("ping only gets a pong when the socket's attachment is already authenticated", async () => {
		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		const unauthedWs = makeFakeWs(false);
		await doInstance.webSocketMessage(unauthedWs as never, JSON.stringify({ type: "ping" }));
		expect(unauthedWs.send).not.toHaveBeenCalled();

		const authedWs = makeFakeWs(true);
		await doInstance.webSocketMessage(authedWs as never, JSON.stringify({ type: "ping" }));
		expect(authedWs.send).toHaveBeenCalledWith(JSON.stringify({ type: "pong" }));
	});
});

/**
 * C2 (step-3c review, Codex P2): `handleWebSocketUpgrade` used to build the
 * catch-up snapshot BEFORE `acceptWebSocket()`. `broadcast()` iterates
 * `ctx.getWebSockets()`, which only includes accepted sockets, so a round
 * broadcasting during that window was silently dropped for the connecting
 * client — permanently, since the snapshot read (already in flight) would
 * not pick it up either. The fix moves the catch-up read to AFTER accept.
 *
 * `handleWebSocketUpgrade` constructs `new WebSocketPair()` and a real
 * `Response` with `status: 101` — neither exists in plain Node/vitest (no
 * `@cloudflare/vitest-pool-workers` here, same constraint noted throughout
 * this file), so this test stubs both globals for its own scope only.
 * `Response(status: 101)` specifically throws under Node's real Response
 * (`RangeError: init["status"] must be in the range of 200 to 599`), which
 * is exactly what Task 0's earlier probe against real workerd already found
 * — that real behavior was verified separately with `wrangler dev`; this
 * test's job is only the message-ordering guarantee, not the wire protocol.
 */
describe("FoxConversationDO.handleWebSocketUpgrade: C2 accept-before-catchup ordering", () => {
	class FakeServerSocket {
		sentMessages: string[] = [];
		private attachment: unknown = null;
		serializeAttachment(a: unknown): void {
			this.attachment = a;
		}
		deserializeAttachment(): unknown {
			return this.attachment;
		}
		send(data: string): void {
			this.sentMessages.push(data);
		}
		close(): void {}
	}
	class FakeClientSocket {}
	class FakeWebSocketPairCtor {
		0: FakeClientSocket;
		1: FakeServerSocket;
		constructor() {
			this[0] = new FakeClientSocket();
			this[1] = new FakeServerSocket();
		}
	}
	class FakeResponseCtor {
		status: number;
		webSocket?: unknown;
		constructor(_body: unknown, init?: { status?: number; webSocket?: unknown; headers?: Record<string, string> }) {
			this.status = init?.status ?? 200;
			this.webSocket = init?.webSocket;
		}
	}

	afterEach(() => {
		vi.unstubAllGlobals();
	});

	it("C2: a broadcast arriving between acceptWebSocket() and the catch-up read still reaches the client", async () => {
		vi.stubGlobal("WebSocketPair", FakeWebSocketPairCtor);
		vi.stubGlobal("Response", FakeResponseCtor);

		// The catch-up read's messages query never resolves until the test
		// explicitly unblocks it, so we can deterministically pause
		// handleWebSocketUpgrade exactly inside buildCatchUpMessage's await —
		// strictly after acceptWebSocket() has already run, since that call is
		// synchronous and precedes this await in source order.
		let resolveMessagesQuery: (v: { data: unknown; error: unknown }) => void = () => {};
		const messagesQueryPromise = new Promise<{ data: unknown; error: unknown }>((resolve) => {
			resolveMessagesQuery = resolve;
		});

		const supabase = {
			from(table: string) {
				if (table === "fox_conversation_messages") {
					return {
						select() {
							return this;
						},
						eq() {
							return this;
						},
						order() {
							return this;
						},
						then(onFulfilled: (v: unknown) => unknown, onRejected?: (e: unknown) => unknown) {
							return messagesQueryPromise.then(onFulfilled, onRejected);
						},
					};
				}
				if (table === "fox_conversations") {
					let selectedColumns = "";
					return {
						select(columns: string) {
							selectedColumns = columns;
							return this;
						},
						eq() {
							return this;
						},
						single: async () => selectedColumns.includes("match:matches!")
							? {
									data: {
										id: CONVERSATION_ID,
										match_id: MATCH_ID,
										status: "in_progress",
										match: {
											id: MATCH_ID,
											user_a_id: USER_A,
											user_b_id: USER_B,
											status: "fox_conversation_in_progress",
											profile_a: {
												id: USER_A,
												age_verified_at: "2026-08-24T00:00:00Z",
												gender_identity: "woman",
												preferred_genders: ["woman"],
												preference_mode: "selected",
												dating_market: "JP",
												onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
												blocks_sent: [],
											},
											profile_b: {
												id: USER_B,
												age_verified_at: "2026-08-24T00:00:00Z",
												gender_identity: "woman",
												preferred_genders: ["woman"],
												preference_mode: "selected",
												dating_market: "JP",
												onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
												blocks_sent: [],
											},
										},
									},
									error: null,
								}
							: selectedColumns.includes("status")
								? { data: { id: CONVERSATION_ID, match_id: MATCH_ID, status: "in_progress" }, error: null }
								: { data: { total_rounds: 5 }, error: null },
					};
				}
				if (table === "matches") {
					return {
						select() {
							return this;
						},
						eq() {
							return this;
						},
						single: async () => ({
							data: { id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: "fox_conversation_in_progress" },
							error: null,
						}),
					};
				}
				if (table === "user_profiles") {
					return {
						select() {
							return this;
						},
						in() {
							return this;
						},
						then: async (onFulfilled: (value: unknown) => unknown) => onFulfilled({
							data: [
								{
									id: USER_A,
									age_verified_at: "2026-08-24T00:00:00Z",
									gender_identity: "woman",
									preferred_genders: ["woman"],
									preference_mode: "selected",
									dating_market: "JP",
									onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
								},
								{
									id: USER_B,
									age_verified_at: "2026-08-24T00:00:00Z",
									gender_identity: "woman",
									preferred_genders: ["woman"],
									preference_mode: "selected",
									dating_market: "JP",
									onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
								},
							],
							error: null,
						}),
					};
				}
				if (table === "blocks") {
					return {
						select() {
							return this;
						},
						or() {
							return this;
						},
						limit() {
							return this;
						},
						maybeSingle: async () => ({ data: null, error: null }),
					};
				}
				throw new Error(`unexpected table ${table}`);
			},
		};
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		const acceptedSockets: FakeServerSocket[] = [];
		const ctx = {
			storage: {
				get: vi.fn(async (key: string) => (key === "state" ? makeInProgressState() : undefined)),
				put: vi.fn(async () => undefined),
				setAlarm: vi.fn(async () => undefined),
			},
			acceptWebSocket: vi.fn((ws: FakeServerSocket) => {
				acceptedSockets.push(ws);
			}),
			getWebSockets: () => acceptedSockets,
		};
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		const request = new Request("https://do/ws", { headers: { "X-Verified-User-Id": USER_A } });
		const upgradePromise = (
			doInstance as unknown as { handleWebSocketUpgrade: (r: Request) => Promise<{ status: number }> }
		).handleWebSocketUpgrade(request);

		// Let resolveWsAccess + pair creation + acceptWebSocket run. Over-flushing
		// is safe here: nothing downstream can progress past buildCatchUpMessage's
		// await until the messages query is resolved below.
		for (let i = 0; i < 20; i++) await Promise.resolve();

		expect(ctx.acceptWebSocket).toHaveBeenCalledTimes(1);
		const serverSocket = acceptedSockets[0];
		expect(serverSocket).toBeDefined();

		// Simulate the race: a round broadcasts while the catch-up read is
		// still pending.
		(doInstance as unknown as { broadcast: (msg: unknown) => void }).broadcast({
			type: "round_message",
			round_number: 9,
			speaker: "A",
			content: "raced in",
		});

		// This is the assertion that fails under the old (pre-C2) ordering,
		// where the socket wasn't registered yet at this point and the
		// broadcast would have silently skipped it.
		expect(serverSocket.sentMessages).toHaveLength(1);
		expect(JSON.parse(serverSocket.sentMessages[0])).toMatchObject({ type: "round_message", round_number: 9 });

		resolveMessagesQuery({ data: [], error: null });
		const response = await upgradePromise;

		expect(response.status).toBe(101);
		expect(serverSocket.sentMessages).toHaveLength(2);
		expect(JSON.parse(serverSocket.sentMessages[1])).toMatchObject({ type: "state" });
	});

	it("suppresses catch-up output when current access changes after the DB snapshot", async () => {
		vi.stubGlobal("WebSocketPair", FakeWebSocketPairCtor);
		vi.stubGlobal("Response", FakeResponseCtor);

		const { supabase } = buildSupabaseFake({ denyCurrentAccessAfter: 3 });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		const acceptedSockets: FakeServerSocket[] = [];
		const ctx = {
			storage: {
				get: vi.fn(async (key: string) => (key === "state" ? makeInProgressState() : undefined)),
				put: vi.fn(async () => undefined),
				setAlarm: vi.fn(async () => undefined),
			},
			acceptWebSocket: vi.fn((ws: FakeServerSocket) => acceptedSockets.push(ws)),
			getWebSockets: () => acceptedSockets,
		};
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		const response = await (
			doInstance as unknown as { handleWebSocketUpgrade: (r: Request) => Promise<{ status: number }> }
		).handleWebSocketUpgrade(new Request("https://do/ws", { headers: { "X-Verified-User-Id": USER_A } }));

		expect(response.status).toBe(403);
		expect(acceptedSockets).toHaveLength(1);
		expect(acceptedSockets[0].sentMessages).toHaveLength(0);
	});
});

/**
 * Codex P1 fix: `alarm()` must not run an entire long conversation to
 * completion in a single invocation. `MAX_ROUNDS_PER_ALARM` bounds each
 * alarm to one round, then reschedules; the transport test measures the
 * resulting per-invocation Supabase dispatches with the production
 * existing-FK embedding query and keeps model attempts separate.
 */
describe("FoxConversationDO.alarm() budget: reschedules instead of completing a long conversation in one invocation", () => {
	function stubRoundUsage() {
		mockedChatCompleteWithUsage.mockResolvedValue({
			content: "hi",
			usage: { inputTokens: 10, outputTokens: 5, cachedTokens: null },
		});
	}

	it("B-1: with rounds remaining past the budget, reschedules the alarm and leaves the conversation in_progress (not completed)", async () => {
		const { supabase, foxConversationUpdates } = buildSupabaseFake({ totalRounds: 10 });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;
		stubRoundUsage();

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);
		const broadcastSpy = vi.spyOn(doInstance as unknown as { broadcast: (msg: unknown) => void }, "broadcast");

		await doInstance.alarm();

		// (a) setAlarm called for the reschedule
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(1);
		// (b) fox_conversations never got a status: "completed" write
		expect(foxConversationUpdates.some((u) => u.status === "completed")).toBe(false);
		// (c) DO state is still in_progress
		const finalState = await ctx.storage.get("state");
		expect((finalState as { status: string }).status).toBe("in_progress");
		// (d) no "completed" broadcast went out
		expect(broadcastSpy.mock.calls.some(([msg]) => (msg as { type: string }).type === "completed")).toBe(false);
	});

	it("B-2: persists the token spend accumulated so far even though the run stops mid-conversation (guards the same class of gap as 3-B)", async () => {
		const { supabase, foxConversationUpdates } = buildSupabaseFake({ totalRounds: 10 });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;
		mockedChatCompleteWithUsage.mockResolvedValue({
			content: "hi",
			usage: { inputTokens: 7, outputTokens: 3, cachedTokens: 1 },
		});

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		await doInstance.alarm();

		// MAX_ROUNDS_PER_ALARM (1) round ran before the budget-exhausted return.
		const lastUpdate = foxConversationUpdates.at(-1);
		expect(lastUpdate).toEqual({
			input_tokens: 7,
			output_tokens: 3,
			cache_hit_tokens: 1,
		});
	});

	it("D-3 (was B-3): repeated alarm() calls eventually complete the conversation, with token totals summed across every invocation", async () => {
		const TOTAL_ROUNDS = 10;
		const { supabase, foxConversationUpdates, getMessages } = buildSupabaseFake({ totalRounds: TOTAL_ROUNDS });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		let roundCalls = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			roundCalls++;
			if (roundCalls <= TOTAL_ROUNDS) {
				return { content: `round reply ${roundCalls}`, usage: { inputTokens: 2, outputTokens: 1, cachedTokens: null } };
			}
			// The 11th call is the scoring call.
			return { content: scorePayload(), usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null } };
		});

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		// Codex P1 (round-count-vs-retries) fix: an invocation that processed
		// any rounds always returns incomplete now, even the one that types the
		// conversation's final round — scoring only ever runs in an invocation
		// that processed zero rounds. With one round per alarm, 10 rounds need
		// 10 rounds-only invocations, then one scoring invocation that processes
		// zero rounds, followed by the notify-only invocation. Call alarm()
		// until the DO reports completed, with a hard cap so a bug that never
		// completes fails the test instead of hanging.
		let iterations = 0;
		let status = (await ctx.storage.get("state") as { status: string } | undefined)?.status;
		while (status !== "completed" && iterations < 20) {
			await doInstance.alarm();
			status = (await ctx.storage.get("state") as { status: string } | undefined)?.status;
			iterations++;
		}

		expect(status).toBe("completed");
		// Twelve: ten rounds-only invocations, one scoring invocation that ends
		// at `notifying`, and one notify-only invocation for N-01.
		// The extra one carries no conversation work — it exists so the send
		// never shares the scoring invocation's subrequest budget (Codex P1 on
		// PR #31). `roundCalls` below is unchanged, which is what proves the
		// split added an invocation and not a unit of work.
		expect(iterations).toBe(12);
		expect(roundCalls).toBe(TOTAL_ROUNDS + 1);
		const persistedRounds = getMessages().map((message) => message.round_number);
		expect(persistedRounds).toHaveLength(TOTAL_ROUNDS);
		expect(new Set(persistedRounds)).toEqual(new Set(Array.from({ length: TOTAL_ROUNDS }, (_, index) => index + 1)));

		const terminalUpdate = foxConversationUpdates.at(-1);
		expect(terminalUpdate).toMatchObject({
			status: "completed",
			input_tokens: TOTAL_ROUNDS * 2 + 5,
			output_tokens: TOTAL_ROUNDS * 1 + 4,
			cache_hit_tokens: null,
		});
		// 10 real rounds across 10 alarms plus a 2000ms pre-score sleep remain
		// intentionally bounded by this explicit timeout; sleep is not injectable
		// through alarm().
	}, 20000);
});

/**
 * Codex 3rd-round-of-review P1 fix (indictment A): `MAX_RETRIES` (round
 * generation) and `SCORE_MAX_RETRIES` (scoring) each allow up to 3 Mistral
 * calls, not 1 — so an invocation that both finished a budget's worth of
 * rounds AND went on to score in the same call could retry both, blowing
 * past the Workers Free plan's 50-subrequest cap. The fix: whenever
 * `maxRoundsPerRun` is set, an invocation that processed >=1 round always
 * returns `incomplete: true` without scoring, regardless of whether rounds
 * still remain — scoring only ever happens in an invocation that processed
 * zero rounds (i.e. `startRound > total_rounds` already, from a prior run).
 */
describe("Codex 3rd-review P1 fix (indictment A): scoring never shares an invocation with round generation", () => {
	it("D-1: an alarm that types the conversation's final round(s) returns incomplete and does not score", async () => {
		const TOTAL_ROUNDS = 1; // == MAX_ROUNDS_PER_ALARM, so one alarm exhausts total_rounds exactly
		const { supabase, foxConversationUpdates } = buildSupabaseFake({ totalRounds: TOTAL_ROUNDS });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		let roundCalls = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			roundCalls++;
			return { content: `round reply ${roundCalls}`, usage: { inputTokens: 2, outputTokens: 1, cachedTokens: null } };
		});

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		await doInstance.alarm();

		// No scoring call was made: only the one round-generation call happened.
		expect(roundCalls).toBe(TOTAL_ROUNDS);
		// Not scored: no terminal "completed" write, DO state still in_progress,
		// and it rescheduled (same observable shape as the budget-exhausted /
		// rounds-remaining case).
		expect(foxConversationUpdates.some((u) => u.status === "completed")).toBe(false);
		const finalState = await ctx.storage.get("state");
		expect((finalState as { status: string }).status).toBe("in_progress");
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(1);
	});

	it("D-2: the following alarm (0 rounds processed) runs scoring and completes; it does not return incomplete", async () => {
		const TOTAL_ROUNDS = 1;
		const { supabase, foxConversationUpdates } = buildSupabaseFake({ totalRounds: TOTAL_ROUNDS });
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		let roundCalls = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			roundCalls++;
			if (roundCalls <= TOTAL_ROUNDS) {
				return { content: `round reply ${roundCalls}`, usage: { inputTokens: 2, outputTokens: 1, cachedTokens: null } };
			}
			return { content: scorePayload(), usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null } };
		});

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		await doInstance.alarm(); // D-1's invocation: rounds only, incomplete
		await doInstance.alarm(); // D-2: 0 rounds this time, must score and finish the loop

		expect(roundCalls).toBe(TOTAL_ROUNDS + 1); // the +1 is the scoring call
		// The scoring invocation ends at `notifying` and hands N-01 its own
		// invocation (Codex P1 on PR #31); the conversation's own work — the
		// fox_conversations terminal update below — is already done here.
		expect(foxConversationUpdates.some((u) => u.status === "completed")).toBe(true);
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("notifying");

		await doInstance.alarm(); // the notify-only invocation
		const finalState = await ctx.storage.get("state");
		expect((finalState as { status: string }).status).toBe("completed");
		// Two reschedules: the first alarm's resume, and the scoring alarm
		// handing off to the notify invocation. Crucially the notify invocation
		// itself does NOT reschedule — a third would mean it loops.
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(2);
		expect(roundCalls).toBe(TOTAL_ROUNDS + 1); // the notify invocation ran no conversation work
	});
});

/**
 * Codex 3rd-review P1 fix (indictment B): the "existing messages" select at
 * the top of `runConversationLoop` (used to resume from
 * `fox_conversation_messages` and derive `startRound`) discarded supabase-js's
 * `{ error }` result. supabase-js resolves rather than rejects on a
 * PostgREST error, so a transient failure there silently produced
 * `existingMsgs = null` -> `startRound = 1`, restarting a conversation that
 * was already several rounds in. `fox_conversation_messages` has no UNIQUE
 * constraint on `(conversation_id, round_number)`, so this doesn't fail
 * loudly — it duplicates rows, re-bills already-paid-for Mistral rounds, and
 * corrupts both score computation and WebSocket catch-up.
 */
describe("Codex 3rd-review P1 fix (indictment B): a failed history select throws instead of resuming from round 1", () => {
	function stubRoundUsage() {
		mockedChatCompleteWithUsage.mockResolvedValue({
			content: "hi",
			usage: { inputTokens: 10, outputTokens: 5, cachedTokens: null },
		});
	}

	it("E-1: runConversationLoop throws and makes zero round-generation Mistral calls", async () => {
		const { supabase } = buildSupabaseFake({ totalRounds: 10, messagesSelectError: true });
		stubRoundUsage();

		await expect(
			runConversationLoop({
				// biome-ignore lint: test double, not a real Supabase client
				supabase: supabase as never,
				apiKey: "fake-key",
				conversationId: CONVERSATION_ID,
			}),
		).rejects.toThrow();

		expect(mockedChatCompleteWithUsage).not.toHaveBeenCalled();
	});

	it("E-2: FoxConversationDO.alarm() does not reschedule and fails the conversation/match instead of resuming from round 1", async () => {
		const { supabase, foxConversationUpdates, matchUpdates } = buildSupabaseFake({
			totalRounds: 10,
			messagesSelectError: true,
		});
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;
		stubRoundUsage();

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		await doInstance.alarm();

		expect(mockedChatCompleteWithUsage).not.toHaveBeenCalled();
		expect(ctx.storage.setAlarm).not.toHaveBeenCalled();
		expect(foxConversationUpdates.some((u) => u.status === "failed")).toBe(true);
		expect(matchUpdates.some((u) => u.status === "fox_conversation_failed")).toBe(true);

		const finalState = await ctx.storage.get("state");
		expect((finalState as { status: string }).status).toBe("failed");
	});
});

/**
 * B-4: the local-dev / no-DO-binding fallback (`runFoxConversation`, which
 * never passes `maxRoundsPerRun`) must be unaffected by the budget — it
 * still runs an arbitrarily long conversation to completion in one call.
 */
describe("runFoxConversation (no maxRoundsPerRun) always completes a conversation in a single call", () => {
	it("B-4: completes a conversation longer than MAX_ROUNDS_PER_ALARM without ever returning incomplete", async () => {
		const TOTAL_ROUNDS = 10; // > the DO's MAX_ROUNDS_PER_ALARM (1)
		const { supabase, foxConversationUpdates } = buildSupabaseFake({ totalRounds: TOTAL_ROUNDS });

		let roundCalls = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			roundCalls++;
			if (roundCalls <= TOTAL_ROUNDS) {
				return { content: `round reply ${roundCalls}`, usage: { inputTokens: 2, outputTokens: 1, cachedTokens: null } };
			}
			return { content: scorePayload(), usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null } };
		});

		await runFoxConversation(supabase as never, "fake-key", CONVERSATION_ID);

		expect(roundCalls).toBe(TOTAL_ROUNDS + 1);
		const terminalUpdate = foxConversationUpdates.at(-1);
		expect(terminalUpdate).toMatchObject({ status: "completed" });
		// 10 real rounds in one call (~9 inter-round sleeps of 500-1000ms plus a
		// 2000ms pre-score sleep) exceed vitest's 5000ms default test timeout;
		// sleep is not injectable through runFoxConversation's public signature.
	}, 20000);
});

/**
 * Codex external-review P1 fix: the budget-exhausted checkpoint write in
 * fox-conversation-engine.ts (`await supabase.from("fox_conversations")
 * .update(tokenTotalsForUpdate())...`) discarded the `{ error }` supabase-js
 * resolves with instead of rejecting. If that write silently failed, the
 * engine still returned `incomplete: true` — telling the caller "the
 * checkpoint is safe, reschedule" — while the next alarm reseeds its token
 * accumulators from the (unwritten) row, permanently losing this run's
 * already-billed Mistral spend. Same failure class as 3-B, worse because it
 * fires on the normal (non-error) path.
 *
 * The fix retries the checkpoint write a few times with a short backoff and,
 * if it still hasn't landed, throws instead of returning `incomplete` — a
 * loud failure (routed through `FoxConversationDO.alarm()`'s catch ->
 * `failConversation`) instead of a silently-lost checkpoint.
 *
 * `runConversationLoop`'s default `sleep` (no `sleep` dep injected, since
 * `alarm()` doesn't pass one) is a real `setTimeout`, so these tests incur a
 * few hundred ms of genuine backoff delay — same tradeoff the pre-existing
 * B-3/B-4 tests already accepted for their inter-round sleeps.
 */
describe("Codex P1 fix: a failed checkpoint token write throws instead of silently returning incomplete", () => {
	function stubRoundUsage() {
		mockedChatCompleteWithUsage.mockResolvedValue({
			content: "hi",
			usage: { inputTokens: 10, outputTokens: 5, cachedTokens: null },
		});
	}

	it("C-1: checkpoint update fails on every attempt -> runConversationLoop throws, never returns incomplete", async () => {
		const { supabase } = buildSupabaseFake({ totalRounds: 10, checkpointUpdateFailures: Number.POSITIVE_INFINITY });
		stubRoundUsage();

		await expect(
			runConversationLoop({
				// biome-ignore lint: test double, not a real Supabase client
				supabase: supabase as never,
				apiKey: "fake-key",
				conversationId: CONVERSATION_ID,
				maxRoundsPerRun: 4,
			}),
		).rejects.toThrow();
	}, 10000);

	it("C-2: FoxConversationDO.alarm() does not reschedule and fails the conversation/match instead", async () => {
		const { supabase, foxConversationUpdates, matchUpdates } = buildSupabaseFake({
			totalRounds: 10,
			checkpointUpdateFailures: Number.POSITIVE_INFINITY,
		});
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;
		stubRoundUsage();

		const ctx = makeFakeCtx(makeInProgressState());
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		await doInstance.alarm();

		// Must NOT be the budget-exhausted reschedule path: no setAlarm call.
		// (Not to be confused with /init's own setAlarm, which is never
		// exercised in this test — alarm() is called directly.)
		expect(ctx.storage.setAlarm).not.toHaveBeenCalled();

		expect(foxConversationUpdates.some((u) => u.status === "failed")).toBe(true);
		expect(matchUpdates.some((u) => u.status === "fox_conversation_failed")).toBe(true);

		const finalState = await ctx.storage.get("state");
		expect((finalState as { status: string }).status).toBe("failed");
	}, 10000);

	it("C-3: checkpoint update fails once then succeeds -> retry recovers, incomplete: true as normal", async () => {
		const { supabase, foxConversationUpdates, getCheckpointUpdateCalls } = buildSupabaseFake({
			totalRounds: 10,
			checkpointUpdateFailures: 1,
		});
		stubRoundUsage();

		const result = await runConversationLoop({
			// biome-ignore lint: test double, not a real Supabase client
			supabase: supabase as never,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			maxRoundsPerRun: 4,
		});

		expect(result.incomplete).toBe(true);
		expect(getCheckpointUpdateCalls()).toBe(2); // 1 failed attempt + 1 successful retry
		const lastUpdate = foxConversationUpdates.at(-1);
		expect(lastUpdate).toEqual({
			input_tokens: 10 * 4,
			output_tokens: 5 * 4,
			cache_hit_tokens: null,
		});
	}, 10000);
});


/**
 * Codex P1, PR #31 review round 2: a failure to SCHEDULE the N-01 notify
 * invocation must not reverse a conversation that already succeeded.
 *
 * By the time that setAlarm runs, fox_conversations is already persisted as
 * completed and the WebSocket clients have already been told so. Leaving that
 * await inside the loop's generic try meant a rejection would reach
 * failConversation, overwrite both database statuses to failed, and broadcast
 * an error contradicting a message the clients had already acted on.
 */
describe("a failed N-01 handoff loses the push, never the completion", () => {
	it("keeps fox_conversations completed and does not mark the match failed when setAlarm rejects", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const { supabase, foxConversationUpdates, matchUpdates } = buildSupabaseFake();
		// biome-ignore lint: test double, not a real Supabase client
		(FoxConversationDO.prototype as unknown as { getSupabase: () => unknown }).getSupabase = () => supabase;

		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({ content: "Hi there!", usage: { inputTokens: 10, outputTokens: 5, cachedTokens: 2 } })
			.mockResolvedValueOnce({ content: scorePayload(), usage: { inputTokens: 50, outputTokens: 20, cachedTokens: 3 } });

		const ctx = makeFakeCtx(makeInProgressState());
		// Only the N-01 handoff fails. The first setAlarm is the loop's own
		// resume reschedule, which must keep working — failing that one is a
		// genuine conversation failure and SHOULD reach failConversation, so
		// breaking both would not distinguish the fix from its absence.
		let setAlarmCalls = 0;
		ctx.storage.setAlarm = vi.fn(async () => {
			setAlarmCalls++;
			if (setAlarmCalls > 1) throw new Error("storage unavailable");
		});
		const env = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test", MISTRAL_API_KEY: "fake-key" };
		// biome-ignore lint: constructing with test doubles for ctx/env
		const doInstance = new FoxConversationDO(ctx as never, env as never);

		await doInstance.alarm(); // rounds, then reschedules (setAlarm #1, succeeds)
		await doInstance.alarm(); // scores, completes, then fails to hand off N-01

		// The conversation stands as completed — the whole point of the fix.
		expect(foxConversationUpdates.at(-1)).toMatchObject({ status: "completed" });
		expect(foxConversationUpdates.some((u) => u.status === "failed")).toBe(false);
		expect(matchUpdates.some((u) => u.status === "fox_conversation_failed")).toBe(false);

		// The push is what was lost: no notify invocation was ever scheduled,
		// so the DO stays parked in `notifying` rather than looping.
		const finalState = await ctx.storage.get("state");
		expect((finalState as { status: string }).status).toBe("notifying");

		consoleErrorSpy.mockRestore();
	});
});
