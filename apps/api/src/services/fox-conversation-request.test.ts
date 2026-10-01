import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import type { Env } from "../env";
import { RECORDING_REHEARSAL_GENERATION_PAIRS } from "./recording-rehearsal";
import { requestFoxConversation, FREE_FOX_CONVERSATION_LIMIT } from "./fox-conversation-request";

/**
 * Fake Supabase client + in-memory "DB" used by these tests.
 *
 * This is intentionally not a generic PostgREST mock: it only implements the
 * exact call shapes requestFoxConversation makes (see the grep of `supabase.`
 * calls in fox-conversation-request.ts), keyed by table name.
 *
 * Concurrency-safety design (the test that matters most, see
 * "consumeQuota concurrency" below): `rpc("consume_quota", ...)` is the ONLY
 * write path exposed for `usage_counters` — `.from("usage_counters")` is not
 * implemented at all and throws if ever called. That means a future
 * regression to a select-then-update implementation against usage_counters
 * cannot pass silently; it fails loudly instead. The rpc implementation
 * itself serializes concurrent calls for the same (user, quota_key,
 * period_start) key through a promise-chain lock, modeling the row-level
 * locking a real single SQL statement gets from Postgres — this is what lets
 * the concurrency test assert exactly `limit` successes.
 */

interface MatchRow {
	id: string;
	user_a_id: string;
	user_b_id: string;
	status: string;
	fox_conversation_requested_at?: string | null;
	fox_conversation_requested_by?: string | null;
}

interface FoxConvRow {
	id: string;
	match_id: string;
	status: string;
	purpose: string;
}

interface UserProfileRow {
	id: string;
	age_verified_at: string | null;
	gender_identity: "woman" | "man" | "nonbinary" | null;
	preferred_genders: string[];
	preference_mode: "selected" | "no_answer";
	dating_market: "JP" | "US";
	onboarding_settings_completed_at: string | null;
}

interface FakeDB {
	matches: Map<string, MatchRow>;
	userProfiles: Map<string, UserProfileRow>;
	blocks: Array<{ blocker_id: string; blocked_id: string }>;
	foxConversations: Map<string, FoxConvRow>;
	entitlements: Map<string, { is_active: boolean }>;
	usageCounters: Map<string, { used_count: number; period_start: string; period_end: string }>;
	nextConvId: number;
}

interface FakeSupabaseOptions {
	judgeActorId?: string;
	judgeCounterpartId?: string;
	failBlocksLookup?: boolean;
	failExistingConversationLookup?: boolean;
	failEntitlementLookup?: boolean;
	failMatchStatusUpdate?: boolean;
	afterQuotaConsumption?: () => void;
	afterFoxConversationInsert?: () => void;
	afterMatchStatusUpdate?: () => void;
}

function makeFakeDB(): FakeDB {
	return {
		matches: new Map(),
		userProfiles: new Map(),
		blocks: [],
		foxConversations: new Map(),
		entitlements: new Map(),
		usageCounters: new Map(),
		nextConvId: 1,
	};
}

const locks = new Map<string, Promise<unknown>>();
/** Promise-chain mutex per key — models Postgres row-level locking for a single UPDATE statement. */
function withLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
	const prev = locks.get(key) ?? Promise.resolve();
	const next = prev.then(fn, fn) as Promise<T>;
	locks.set(
		key,
		next.catch(() => undefined),
	);
	return next;
}

/**
 * Yields a microtask tick, simulating a network round trip inside the
 * (atomic) RPC call. Deliberately microtask-based (not a real timer) so this
 * still resolves correctly under `vi.useFakeTimers()` in the month-rollover
 * test below, without needing to advance a fake clock.
 */
function tick(): Promise<void> {
	return Promise.resolve();
}

class FakeQueryBuilder {
	private filters: Record<string, string> = {};
	private inValues: string[] | null = null;
	private orExpr: string | null = null;
	private mode: "select" | "insert" | "update" = "select";
	private payload: Record<string, unknown> = {};

	constructor(
		private db: FakeDB,
		private table: string,
		private opts: FakeSupabaseOptions = {},
	) {}

	select(_cols?: string) {
		return this;
	}
	eq(col: string, val: string) {
		this.filters[col] = val;
		return this;
	}
	in(col: string, values: string[]) {
		this.filters[col] = col;
		this.inValues = values;
		return this;
	}
	or(expr: string) {
		this.orExpr = expr;
		return this;
	}
	limit(_n: number) {
		return this;
	}
	insert(row: Record<string, unknown>) {
		this.mode = "insert";
		this.payload = row;
		return this;
	}
	update(patch: Record<string, unknown>) {
		this.mode = "update";
		this.payload = patch;
		return this;
	}
	maybeSingle() {
		return Promise.resolve(this.execute(false));
	}
	single() {
		return Promise.resolve(this.execute(true));
	}
	then<TResult1 = unknown, TResult2 = never>(
		onfulfilled?: ((value: { data: unknown; error: unknown }) => TResult1 | PromiseLike<TResult1>) | null,
		onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
	) {
		return Promise.resolve(this.execute(false)).then(onfulfilled, onrejected);
	}

	private execute(requireRow: boolean): { data: unknown; error: unknown } {
		if (this.table === "usage_counters") {
			// Deliberately unimplemented: usage_counters must only ever be
			// written through the consume_quota/refund_quota RPC. A regression
			// that reintroduces a direct select-then-update fails loudly here
			// instead of silently racing.
			throw new Error("usage_counters must only be accessed via the consume_quota/refund_quota RPC, not .from()");
		}

		if (this.mode === "insert") {
			if (this.table === "fox_conversations") {
				const id = `conv-${this.db.nextConvId++}`;
				const row: FoxConvRow = {
					id,
					match_id: String(this.payload.match_id),
					status: String(this.payload.status ?? "pending"),
					purpose: String(this.payload.purpose ?? "compatibility"),
				};
				this.db.foxConversations.set(id, row);
				this.opts.afterFoxConversationInsert?.();
				return { data: { id }, error: null };
			}
			throw new Error(`FakeQueryBuilder: insert not implemented for table ${this.table}`);
		}

		if (this.mode === "update") {
			if (this.table === "matches") {
				if (this.opts.failMatchStatusUpdate && this.payload.status === "fox_conversation_in_progress") {
					return { data: null, error: { message: "connection reset" } };
				}
				const row = this.db.matches.get(this.filters.id);
				if (row) Object.assign(row, this.payload);
				if (this.payload.status === "fox_conversation_in_progress") this.opts.afterMatchStatusUpdate?.();
				return { data: null, error: null };
			}
			if (this.table === "fox_conversations") {
				const row = [...this.db.foxConversations.values()].find(
					(r) => (this.filters.id ? r.id === this.filters.id : true) && (this.filters.match_id ? r.match_id === this.filters.match_id : true),
				);
				if (row) Object.assign(row, this.payload);
				return { data: null, error: null };
			}
			throw new Error(`FakeQueryBuilder: update not implemented for table ${this.table}`);
		}

		// select
		if (this.table === "matches") {
			const row = this.db.matches.get(this.filters.id);
			if (!row) return { data: null, error: requireRow ? { message: "not found" } : null };
			return { data: row, error: null };
		}
		if (this.table === "user_profiles") {
			const rows = [...this.db.userProfiles.values()].filter((row) =>
				this.inValues ? this.inValues.includes(row.id) : this.filters.id ? row.id === this.filters.id : true,
			);
			return { data: rows, error: null };
		}
		if (this.table === "blocks") {
			// Simulates a transient failure of the block lookup. The request must
			// stop here rather than read the error as "not blocked".
			if (this.opts.failBlocksLookup) return { data: null, error: { message: "connection reset" } };
			if (!this.orExpr) return { data: null, error: null };
			const ids = [...new Set([...this.orExpr.matchAll(/eq\.([^,)]+)/g)].map((m) => m[1]))];
			const hit = this.db.blocks.find(
				(b) => ids.includes(b.blocker_id) && ids.includes(b.blocked_id) && b.blocker_id !== b.blocked_id,
			);
			return { data: hit ?? null, error: null };
		}
		if (this.table === "fox_conversations") {
			if (this.opts.failExistingConversationLookup) return { data: null, error: { message: "connection reset" } };
			const rows = [...this.db.foxConversations.values()].filter((r) => {
				if (this.filters.match_id && r.match_id !== this.filters.match_id) return false;
				if (this.filters.purpose && r.purpose !== this.filters.purpose) return false;
				if (this.filters.id && r.id !== this.filters.id) return false;
				return true;
			});
			return { data: rows[0] ?? null, error: null };
		}
		if (this.table === "entitlements") {
			if (this.opts.failEntitlementLookup) return { data: null, error: { message: "connection reset" } };
			const row = this.db.entitlements.get(this.filters.user_id);
			return { data: row ?? null, error: null };
		}
		throw new Error(`FakeQueryBuilder: select not implemented for table ${this.table}`);
	}
}

function createFakeSupabase(db: FakeDB, opts: FakeSupabaseOptions = {}): SupabaseClient<Database> {
	const client = {
		from(table: string) {
			return new FakeQueryBuilder(db, table, opts);
		},
		rpc(name: string, args: Record<string, unknown>) {
			if (name === "check_judge_access") return Promise.resolve({ error: null, data: args.p_user_id === opts.judgeActorId
				? { outcome: "allowed", actor_user_id: opts.judgeActorId, counterpart_user_id: opts.judgeCounterpartId, account_kind: "judge", expires_at: "2026-10-13T19:00:00Z" } : null });
			if (name === "consume_quota") {
				const key = `${args.p_user_id}:${args.p_quota_key}:${args.p_period_start}`;
				return withLock(key, async () => {
					await tick(); // simulate a real round trip
					const existing = db.usageCounters.get(key);
					const limit = Number(args.p_limit);
					if (!existing) {
						db.usageCounters.set(key, {
							used_count: 1,
							period_start: String(args.p_period_start),
							period_end: String(args.p_period_end),
						});
						opts.afterQuotaConsumption?.();
						return { data: 1, error: null };
					}
					if (existing.used_count >= limit) {
						return { data: null, error: null };
					}
					existing.used_count += 1;
					opts.afterQuotaConsumption?.();
					return { data: existing.used_count, error: null };
				});
			}
			if (name === "refund_quota") {
				const key = `${args.p_user_id}:${args.p_quota_key}:${args.p_period_start}`;
				return withLock(key, async () => {
					const existing = db.usageCounters.get(key);
					if (existing) existing.used_count = Math.max(existing.used_count - 1, 0);
					return { data: null, error: null };
				});
			}
			throw new Error(`FakeSupabase: rpc not implemented for ${name}`);
		},
	};
	return client as unknown as SupabaseClient<Database>;
}

/**
 * A Durable Object binding whose /init returns `status`. Used instead of the
 * no-binding local-dev fallback so tests exercise the real Workers path, and
 * so a rejected init can be simulated.
 */
function fakeDOBinding(status = 200, calls?: { count: number }, afterFetch?: () => void) {
	return {
		idFromName: (name: string) => name,
		get: (_id: unknown) => ({
			fetch: async (_req: Request) => {
				if (calls) calls.count += 1;
				afterFetch?.();
				return new Response(null, { status });
			},
		}),
	};
}

/** Default env: the DO accepts /init, so the happy path actually starts. */
const fakeEnv: Env["Bindings"] = {
	SUPABASE_URL: "http://localhost",
	SUPABASE_SERVICE_ROLE_KEY: "test",
	FOX_CONVERSATION: fakeDOBinding(),
};

const [REHEARSAL_USER_A, REHEARSAL_USER_B] = RECORDING_REHEARSAL_GENERATION_PAIRS["aoi-ren"];
const REHEARSAL_NOW = Date.parse("2026-09-27T02:00:00.000Z");

function rehearsalEnv(expiresAt: Date, foxConversation = fakeDOBinding()): Env["Bindings"] {
	return {
		...fakeEnv,
		FOX_CONVERSATION: foxConversation,
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: new Date(REHEARSAL_NOW - 60_000).toISOString(),
		RECORDING_REHEARSAL_EXPIRES_AT: expiresAt.toISOString(),
		RECORDING_REHEARSAL_PAIR: "aoi-ren",
	};
}

/** Total consumed units across every quota period, so assertions do not depend on the key format. */
function totalUsed(db: FakeDB): number {
	return [...db.usageCounters.values()].reduce((sum, row) => sum + row.used_count, 0);
}

function addPendingMatch(db: FakeDB, id: string, userA: string, userB: string): void {
	db.matches.set(id, { id, user_a_id: userA, user_b_id: userB, status: "pending" });
	for (const userId of [userA, userB]) {
		if (!db.userProfiles.has(userId)) {
			db.userProfiles.set(userId, {
				id: userId,
				age_verified_at: "2026-08-24T00:00:00Z",
				gender_identity: "woman",
				preferred_genders: ["woman"],
				preference_mode: "selected",
				dating_market: "JP",
				onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
			});
		}
	}
}

describe("requestFoxConversation: participant authorization", () => {
	it("rejects a caller who is not a participant of the match", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		const supabase = createFakeSupabase(db);

		const result = await requestFoxConversation(supabase, fakeEnv, "user-c", "match-1");

		expect(result.ok).toBe(false);
		if (result.ok === false) expect(result.code).toBe("NOT_FOUND");
		// No fox_conversations row must have been created for a non-participant.
		expect(db.foxConversations.size).toBe(0);
	});

	it("allows either participant (user_a or user_b) of the match", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		const supabase = createFakeSupabase(db);

		const result = await requestFoxConversation(supabase, fakeEnv, "user-b", "match-1");
		expect(result.ok).toBe(true);
	});

	it("returns NOT_FOUND (not FORBIDDEN) for a non-existent match, matching the non-participant response", async () => {
		const db = makeFakeDB();
		const supabase = createFakeSupabase(db);
		const result = await requestFoxConversation(supabase, fakeEnv, "user-a", "no-such-match");
		expect(result.ok).toBe(false);
		if (result.ok === false) expect(result.code).toBe("NOT_FOUND");
	});
});

describe("requestFoxConversation: blocks", () => {
	it("rejects when the participants have blocked each other", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		db.blocks.push({ blocker_id: "user-b", blocked_id: "user-a" });
		const supabase = createFakeSupabase(db);

		const result = await requestFoxConversation(supabase, fakeEnv, "user-a", "match-1");
		expect(result.ok).toBe(false);
		if (result.ok === false) expect(result.code).toBe("NOT_FOUND");
	});
});

describe("requestFoxConversation: match status", () => {
	it("rejects a match that is not 'pending'", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		db.matches.get("match-1")!.status = "fox_conversation_completed";
		const supabase = createFakeSupabase(db);

		const result = await requestFoxConversation(supabase, fakeEnv, "user-a", "match-1");
		expect(result.ok).toBe(false);
		if (result.ok === false) expect(result.code).toBe("CONFLICT");
	});
});

describe("requestFoxConversation: free quota (3/month)", () => {
	it("allows exactly 3 conversations, then the 4th returns PAYMENT_REQUIRED (402-mapped)", async () => {
		const db = makeFakeDB();
		const supabase = createFakeSupabase(db);
		const userId = "user-a";

		const outcomes: boolean[] = [];
		for (let i = 0; i < 4; i++) {
			const matchId = `match-${i}`;
			addPendingMatch(db, matchId, userId, `partner-${i}`);
			const result = await requestFoxConversation(supabase, fakeEnv, userId, matchId);
			outcomes.push(result.ok);
			if (result.ok === false && i < FREE_FOX_CONVERSATION_LIMIT) {
				throw new Error(`Expected request ${i} to succeed, got ${result.code}: ${result.message}`);
			}
		}

		expect(outcomes).toEqual([true, true, true, false]);
	});
});

describe("requestFoxConversation: active entitlement bypasses quota", () => {
	it("never calls consume_quota (never touches usage_counters) when entitlements.is_active is true", async () => {
		const db = makeFakeDB();
		const userId = "user-a";
		db.entitlements.set(userId, { is_active: true });
		const supabase = createFakeSupabase(db);

		for (let i = 0; i < FREE_FOX_CONVERSATION_LIMIT + 2; i++) {
			const matchId = `match-${i}`;
			addPendingMatch(db, matchId, userId, `partner-${i}`);
			const result = await requestFoxConversation(supabase, fakeEnv, userId, matchId);
			expect(result.ok).toBe(true);
		}
		// An entitled user must consume zero quota units, ever.
		expect(db.usageCounters.size).toBe(0);
	});
});

describe("requestFoxConversation: concurrency consumes exactly one unit per request", () => {
	/**
	 * The test that matters most (per the implementation brief): fires more
	 * concurrent requests than the limit allows, for the SAME user, against
	 * DIFFERENT pending matches (so nothing but the quota check can reject
	 * them). A select-then-update implementation against usage_counters would
	 * let multiple concurrent requests read the same pre-increment count and
	 * all pass the `< limit` check before any of them writes — this fake
	 * client's `.from("usage_counters")` throws (see FakeQueryBuilder.execute),
	 * so that implementation shape fails immediately and loudly. This test
	 * instead exercises the actual atomic `rpc("consume_quota", ...)` path and
	 * asserts exactly `FREE_FOX_CONVERSATION_LIMIT` of the concurrent requests
	 * succeed, regardless of the artificial network delay in the mock RPC.
	 */
	it("exactly `limit` of N concurrent requests succeed, the rest get PAYMENT_REQUIRED", async () => {
		const db = makeFakeDB();
		const userId = "user-a";
		const supabase = createFakeSupabase(db);
		const N = 8;

		for (let i = 0; i < N; i++) {
			addPendingMatch(db, `match-${i}`, userId, `partner-${i}`);
		}

		const results = await Promise.all(
			Array.from({ length: N }, (_, i) => requestFoxConversation(supabase, fakeEnv, userId, `match-${i}`)),
		);

		const succeeded = results.filter((r) => r.ok).length;
		const exhausted = results.filter((r) => r.ok === false && r.code === "PAYMENT_REQUIRED").length;

		expect(succeeded).toBe(FREE_FOX_CONVERSATION_LIMIT);
		expect(exhausted).toBe(N - FREE_FOX_CONVERSATION_LIMIT);

		// The counter itself must land on exactly `limit`, not overshoot.
		const counterValues = [...db.usageCounters.values()];
		expect(counterValues).toHaveLength(1);
		expect(counterValues[0]!.used_count).toBe(FREE_FOX_CONVERSATION_LIMIT);
	});
});

describe("requestFoxConversation: 402 response carries no internal state", () => {
	it("the PAYMENT_REQUIRED message contains no digits (no used_count/limit/period leaked)", async () => {
		const db = makeFakeDB();
		const userId = "user-a";
		const supabase = createFakeSupabase(db);

		let lastResult: Awaited<ReturnType<typeof requestFoxConversation>> | undefined;
		for (let i = 0; i < FREE_FOX_CONVERSATION_LIMIT + 1; i++) {
			const matchId = `match-${i}`;
			addPendingMatch(db, matchId, userId, `partner-${i}`);
			lastResult = await requestFoxConversation(supabase, fakeEnv, userId, matchId);
		}

		expect(lastResult!.ok).toBe(false);
		if (lastResult!.ok === false) {
			expect(lastResult!.code).toBe("PAYMENT_REQUIRED");
			expect(lastResult!.message).not.toMatch(/\d/);
		}
	});
});

describe("requestFoxConversation: month rollover resets the quota", () => {
	beforeEach(() => {
		vi.useFakeTimers();
	});
	afterEach(() => {
		vi.useRealTimers();
	});

	it("a caller who exhausted their quota in one UTC month gets a fresh allowance the next", async () => {
		const db = makeFakeDB();
		const userId = "user-a";
		const supabase = createFakeSupabase(db);

		vi.setSystemTime(new Date("2026-01-20T12:00:00.000Z"));
		for (let i = 0; i < FREE_FOX_CONVERSATION_LIMIT; i++) {
			const matchId = `jan-match-${i}`;
			addPendingMatch(db, matchId, userId, `partner-jan-${i}`);
			const result = await requestFoxConversation(supabase, fakeEnv, userId, matchId);
			expect(result.ok).toBe(true);
		}
		addPendingMatch(db, "jan-match-extra", userId, "partner-jan-extra");
		const exhausted = await requestFoxConversation(supabase, fakeEnv, userId, "jan-match-extra");
		expect(exhausted.ok).toBe(false);

		// Roll into February (still UTC).
		vi.setSystemTime(new Date("2026-02-01T00:00:00.000Z"));
		addPendingMatch(db, "feb-match-1", userId, "partner-feb-1");
		const afterRollover = await requestFoxConversation(supabase, fakeEnv, userId, "feb-match-1");
		expect(afterRollover.ok).toBe(true);
	});
});

/**
 * Regressions for the four findings Codex raised on PR #19. Each one charged
 * the user for a conversation that never ran, or let a request through that
 * should have been stopped, so each gets a test rather than just a fix.
 */
describe("requestFoxConversation: rehearsal expiry is rechecked across awaits", () => {
	it("refunds quota and stops before insert when expiry crosses the quota RPC", async () => {
		vi.useFakeTimers();
		vi.setSystemTime(REHEARSAL_NOW);
		try {
			const db = makeFakeDB();
			addPendingMatch(db, "rehearsal-1", REHEARSAL_USER_A, REHEARSAL_USER_B);
			const doCalls = { count: 0 };
			const expiresAt = new Date(REHEARSAL_NOW + 1_000);
			const supabase = createFakeSupabase(db, {
				afterQuotaConsumption: () => vi.setSystemTime(expiresAt),
			});

			const result = await requestFoxConversation(
				supabase,
				rehearsalEnv(expiresAt, fakeDOBinding(200, doCalls)),
				REHEARSAL_USER_A,
				"rehearsal-1",
			);

			expect(result).toMatchObject({ ok: false, code: "CONFLICT" });
			expect(totalUsed(db)).toBe(0);
			expect(db.foxConversations.size).toBe(0);
			expect(doCalls.count).toBe(0);
		} finally {
			vi.useRealTimers();
		}
	});

	it("marks the partial insert failed and refunds quota when its response crosses expiry", async () => {
		vi.useFakeTimers();
		vi.setSystemTime(REHEARSAL_NOW);
		try {
			const db = makeFakeDB();
			addPendingMatch(db, "rehearsal-insert", REHEARSAL_USER_A, REHEARSAL_USER_B);
			const doCalls = { count: 0 };
			const expiresAt = new Date(REHEARSAL_NOW + 1_000);
			const supabase = createFakeSupabase(db, {
				afterFoxConversationInsert: () => vi.setSystemTime(expiresAt),
			});

			const result = await requestFoxConversation(
				supabase,
				rehearsalEnv(expiresAt, fakeDOBinding(200, doCalls)),
				REHEARSAL_USER_A,
				"rehearsal-insert",
			);

			expect(result).toMatchObject({ ok: false, code: "CONFLICT" });
			expect(totalUsed(db)).toBe(0);
			expect([...db.foxConversations.values()][0]?.status).toBe("failed");
			expect(db.matches.get("rehearsal-insert")?.status).toBe("fox_conversation_failed");
			expect(doCalls.count).toBe(0);
		} finally {
			vi.useRealTimers();
		}
	});

	it("compensates the inserted rows and quota if expiry crosses the match status write", async () => {
		vi.useFakeTimers();
		vi.setSystemTime(REHEARSAL_NOW);
		try {
			const db = makeFakeDB();
			addPendingMatch(db, "rehearsal-2", REHEARSAL_USER_A, REHEARSAL_USER_B);
			const doCalls = { count: 0 };
			const expiresAt = new Date(REHEARSAL_NOW + 1_000);
			const supabase = createFakeSupabase(db, {
				afterMatchStatusUpdate: () => vi.setSystemTime(expiresAt),
			});

			const result = await requestFoxConversation(
				supabase,
				rehearsalEnv(expiresAt, fakeDOBinding(200, doCalls)),
				REHEARSAL_USER_A,
				"rehearsal-2",
			);

			expect(result).toMatchObject({ ok: false, code: "CONFLICT" });
			expect(totalUsed(db)).toBe(0);
			expect([...db.foxConversations.values()][0]?.status).toBe("failed");
			expect(db.matches.get("rehearsal-2")?.status).toBe("fox_conversation_failed");
			expect(doCalls.count).toBe(0);
		} finally {
			vi.useRealTimers();
		}
	});

	it("refunds and marks the start failed if expiry crosses the DO init response", async () => {
		vi.useFakeTimers();
		vi.setSystemTime(REHEARSAL_NOW);
		try {
			const db = makeFakeDB();
			addPendingMatch(db, "rehearsal-3", REHEARSAL_USER_A, REHEARSAL_USER_B);
			const doCalls = { count: 0 };
			const expiresAt = new Date(REHEARSAL_NOW + 1_000);
			const env = rehearsalEnv(expiresAt, fakeDOBinding(200, doCalls, () => vi.setSystemTime(expiresAt)));

			const result = await requestFoxConversation(
				createFakeSupabase(db),
				env,
				REHEARSAL_USER_A,
				"rehearsal-3",
			);

			expect(result).toMatchObject({ ok: false, code: "CONFLICT" });
			expect(totalUsed(db)).toBe(0);
			expect([...db.foxConversations.values()][0]?.status).toBe("failed");
			expect(db.matches.get("rehearsal-3")?.status).toBe("fox_conversation_failed");
			expect(doCalls.count).toBe(1);
		} finally {
			vi.useRealTimers();
		}
	});
});

describe("requestFoxConversation: the user is never charged for a conversation that cannot run", () => {
	it("fails closed when the existing-conversation lookup errors, before quota/create/DO", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		const doCalls = { count: 0 };
		const supabase = createFakeSupabase(db, { failExistingConversationLookup: true });
		const env: Env["Bindings"] = { ...fakeEnv, FOX_CONVERSATION: fakeDOBinding(200, doCalls) };

		const result = await requestFoxConversation(supabase, env, "user-a", "match-1");

		expect(result).toMatchObject({ ok: false, code: "INTERNAL_ERROR" });
		expect(totalUsed(db)).toBe(0);
		expect(db.foxConversations.size).toBe(0);
		expect(doCalls.count).toBe(0);
	});

	it("fails closed when the entitlement lookup errors, before quota/create/DO", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		const doCalls = { count: 0 };
		const supabase = createFakeSupabase(db, { failEntitlementLookup: true });
		const env: Env["Bindings"] = { ...fakeEnv, FOX_CONVERSATION: fakeDOBinding(200, doCalls) };

		const result = await requestFoxConversation(supabase, env, "user-a", "match-1");

		expect(result).toMatchObject({ ok: false, code: "INTERNAL_ERROR" });
		expect(totalUsed(db)).toBe(0);
		expect(db.foxConversations.size).toBe(0);
		expect(doCalls.count).toBe(0);
	});

	it("refunds and marks the conversation failed when match status cannot be updated", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		const doCalls = { count: 0 };
		const supabase = createFakeSupabase(db, { failMatchStatusUpdate: true });
		const env: Env["Bindings"] = { ...fakeEnv, FOX_CONVERSATION: fakeDOBinding(200, doCalls) };

		const result = await requestFoxConversation(supabase, env, "user-a", "match-1");

		expect(result).toMatchObject({ ok: false, code: "INTERNAL_ERROR" });
		expect(totalUsed(db)).toBe(0);
		expect(db.foxConversations.size).toBe(1);
		expect([...db.foxConversations.values()][0]?.status).toBe("failed");
		expect(db.matches.get("match-1")?.status).toBe("fox_conversation_failed");
		expect(doCalls.count).toBe(0);
	});

	it("refunds the quota when the Durable Object rejects /init with a non-2xx status", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		const supabase = createFakeSupabase(db);
		const env: Env["Bindings"] = { ...fakeEnv, FOX_CONVERSATION: fakeDOBinding(500) };

		const result = await requestFoxConversation(supabase, env, "user-a", "match-1");

		expect(result.ok).toBe(false);
		// Charged then refunded: the counter is back where it started, so the
		// next request still has the full allowance.
		expect(totalUsed(db)).toBe(0);
	});

	it("fails, rather than silently succeeding, when nothing is configured to run the conversation", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		const supabase = createFakeSupabase(db);
		// No DO binding and no Mistral key: nothing can run it.
		const env: Env["Bindings"] = { SUPABASE_URL: "http://localhost", SUPABASE_SERVICE_ROLE_KEY: "test" };

		const result = await requestFoxConversation(supabase, env, "user-a", "match-1");

		expect(result.ok).toBe(false);
		expect(totalUsed(db)).toBe(0);
	});

	it("stops the request when the blocks lookup itself fails, instead of treating the error as 'not blocked'", async () => {
		const db = makeFakeDB();
		addPendingMatch(db, "match-1", "user-a", "user-b");
		const supabase = createFakeSupabase(db, { failBlocksLookup: true });

		const result = await requestFoxConversation(supabase, fakeEnv, "user-a", "match-1");

		expect(result.ok).toBe(false);
		if (result.ok === false) expect(result.code).toBe("INTERNAL_ERROR");
		// Nothing was charged, because the request never got past the check.
		expect(totalUsed(db)).toBe(0);
	});
});

// Judge discovery uses the ordinary atomic quota, with no permit or IDV exception.
describe("judge Ward quota and expiry", () => {
 it("retains the ordinary three free conversations and payment requirement", async () => {
  vi.useFakeTimers();const now=Date.parse("2026-09-30T10:00:00Z");vi.setSystemTime(now);
  try {
   const {DEMO_20260930_PROFILE_IDS:ids}=await import("./synthetic-matching-cohort");
   const db=makeFakeDB(),calls={count:0};const supabase=createFakeSupabase(db);
   const env={...fakeEnv,FOX_CONVERSATION:fakeDOBinding(200,calls),DEMO_JUDGE_ENABLED:"enabled",DEMO_JUDGE_COHORT:"demo-20260930",DEMO_JUDGE_ISSUED_AT:new Date(now).toISOString(),DEMO_JUDGE_EXPIRES_AT:new Date(now+7200000).toISOString()};
   const outcomes=[];
   for(let i=0;i<4;i++){addPendingMatch(db,`judge-${i}`,ids[0],ids[i+1]);const result=await requestFoxConversation(supabase,env,ids[0],`judge-${i}`);outcomes.push(result.ok);if(i===3)expect(result).toMatchObject({ok:false,code:"PAYMENT_REQUIRED"});}
   expect(outcomes).toEqual([true,true,true,false]);expect(totalUsed(db)).toBe(3);expect(calls.count).toBe(3);
  } finally {vi.useRealTimers();}
 });
 it("refunds consumed quota on expiry and never starts the provider",async()=>{
  vi.useFakeTimers();const now=Date.parse("2026-09-30T10:00:00Z");vi.setSystemTime(now);
  try {
   const {DEMO_20260930_PROFILE_IDS:ids}=await import("./synthetic-matching-cohort");
   const db=makeFakeDB(),calls={count:0};addPendingMatch(db,"judge-expiry",ids[0],ids[1]);
   const supabase=createFakeSupabase(db,{afterQuotaConsumption:()=>vi.setSystemTime(now+1000)});
   const env={...fakeEnv,FOX_CONVERSATION:fakeDOBinding(200,calls),DEMO_JUDGE_ENABLED:"enabled",DEMO_JUDGE_COHORT:"demo-20260930",DEMO_JUDGE_ISSUED_AT:new Date(now).toISOString(),DEMO_JUDGE_EXPIRES_AT:new Date(now+1000).toISOString()};
   expect(await requestFoxConversation(supabase,env,ids[0],"judge-expiry")).toMatchObject({ok:false,code:"CONFLICT"});expect(totalUsed(db)).toBe(0);expect(calls.count).toBe(0);expect(db.foxConversations.size).toBe(0);
  }finally{vi.useRealTimers();}
 });
});

describe("registered judge Ward quota and owned counterpart", () => {
 const actor = "11111111-1111-4111-8111-111111111111", counterpart = "22222222-2222-4222-8222-222222222222";
 const judgeEnv = { ...fakeEnv, JUDGE_ACCESS_ENABLED: "enabled", JUDGE_ACCESS_COHORT: ["shipaton", "20261001"].join("-"), JUDGE_ACCESS_ISSUED_AT: "2026-09-30T19:00:00Z", JUDGE_ACCESS_EXPIRES_AT: "2026-10-13T19:00:00Z", JUDGE_ACCESS_AI_EXPIRES_AT: "2026-10-01T00:00:00Z" };
 it.each([false, true])("keeps ordinary free quota and server premium policy (%s)", async premium => {
  vi.useFakeTimers(); vi.setSystemTime(Date.parse("2026-09-30T20:00:00Z"));
  try {
   const db = makeFakeDB(); const calls = { count: 0 };
   if (premium) db.entitlements.set(actor, { is_active: true });
   const supabase = createFakeSupabase(db, { judgeActorId: actor, judgeCounterpartId: counterpart });
   const outcomes = [];
   for (let i = 0; i < 4; i++) {
    addPendingMatch(db, `registered-${i}`, actor, counterpart);
    outcomes.push(await requestFoxConversation(supabase, { ...judgeEnv, FOX_CONVERSATION: fakeDOBinding(200, calls) }, actor, `registered-${i}`));
   }
   expect(outcomes.map(outcome => outcome.ok)).toEqual(premium ? [true,true,true,true] : [true,true,true,false]);
   if (!premium) expect(outcomes[3]).toMatchObject({ code: "PAYMENT_REQUIRED" });
   expect(totalUsed(db)).toBe(premium ? 0 : 3); expect(calls.count).toBe(premium ? 4 : 3);
  } finally { vi.useRealTimers(); }
 });
 it("cannot spend quota or start generation with another registered actor's counterpart", async () => {
  vi.useFakeTimers(); vi.setSystemTime(Date.parse("2026-09-30T20:00:00Z"));
  try {
   const db = makeFakeDB(); const calls = { count: 0 }; addPendingMatch(db, "wrong-peer", actor, "33333333-3333-4333-8333-333333333333");
   const supabase = createFakeSupabase(db, { judgeActorId: actor, judgeCounterpartId: counterpart });
   expect(await requestFoxConversation(supabase, { ...judgeEnv, FOX_CONVERSATION: fakeDOBinding(200, calls) }, actor, "wrong-peer")).toMatchObject({ ok: false, code: "CONFLICT" });
   expect(totalUsed(db)).toBe(0); expect(calls.count).toBe(0); expect(db.foxConversations.size).toBe(0);
  } finally { vi.useRealTimers(); }
 });
});
