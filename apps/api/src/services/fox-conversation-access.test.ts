import { describe, expect, it, vi } from "vitest";
import {
	checkFoxConversationCurrentAccess,
	checkFoxConversationParticipant,
	readFoxConversationPublicAccess,
} from "./fox-conversation-access";
import { resolveFoxConversationRecordingWindow } from "./fox-conversation-recording-window";
import { RECORDING_REHEARSAL_GENERATION_PAIRS } from "./recording-rehearsal";

/**
 * Unit coverage for the shared conversation -> match -> participant check
 * (step-3 §4-C-3-1), used by both GET /api/fox-search/status/:conversationId
 * and the WebSocket edge handshake. The consuming routes' own tests mock
 * this module, so its own behavior needs direct coverage here.
 *
 * Note on what the error-path tests below actually prove: for supabase-js's
 * `.single()`, a query error and `data === null` happen to always coincide,
 * so `if (matchError || !match)` and `if (!match)` behave identically today
 * — this is NOT the same class of fail-open bug step-3a's Security Impact
 * Report found elsewhere (those involved code that kept going after a
 * discarded error, not a `.single()` null-data check). Checking `{ error }`
 * explicitly here is defensive/future-proofing per the "every `await
 * supabase...` checks its `{ error }`" rule, not a behavior change from the
 * pre-extraction code — the tests confirm denial, not a regression fix.
 */

interface FakeRow {
	table: string;
	data: unknown;
	error: unknown;
	trace?: QueryTrace;
	beforeResolve?: () => Promise<void>;
}

interface QueryTrace {
	table: string;
	selects: string[];
	filters: [string, unknown][];
	singleCalls: number;
}

function makeQuery(row: FakeRow) {
	return {
		select(columns: string) {
			row.trace?.selects.push(columns);
			return this;
		},
		eq(column: string, value: unknown) {
			row.trace?.filters.push([column, value]);
			return this;
		},
		in() {
			return Promise.resolve({ data: row.data, error: row.error });
		},
		or() {
			return this;
		},
		limit() {
			return this;
		},
		maybeSingle() {
			return Promise.resolve({ data: row.data, error: row.error });
		},
		async single() {
			if (row.trace) row.trace.singleCalls++;
			await row.beforeResolve?.();
			return { data: row.data, error: row.error };
		},
	};
}

function buildSupabaseFake(opts: {
	conv?: { data: unknown; error: unknown };
	match?: { data: unknown; error: unknown };
	profiles?: Array<Record<string, unknown>>;
	blocks?: { data: unknown; error: unknown };
	current?: { data: unknown; error: unknown; beforeResolve?: () => Promise<void> };
}) {
	const conv = opts.conv ?? { data: null, error: null };
	const match = opts.match ?? { data: null, error: null };
	const blocks = opts.blocks ?? { data: null, error: null };
	const traces: QueryTrace[] = [];
	function query(table: string, data: unknown, error: unknown, beforeResolve?: () => Promise<void>) {
		const trace: QueryTrace = { table, selects: [], filters: [], singleCalls: 0 };
		traces.push(trace);
		return makeQuery({ table, data, error, trace, beforeResolve });
	}
	return {
		from(table: string) {
			if (table === "fox_conversations") return query(
				table,
				opts.current?.data ?? conv.data,
				opts.current?.error ?? conv.error,
				opts.current?.beforeResolve,
			);
			if (table === "matches") return query(table, match.data, match.error);
			if (table === "blocks") return query(table, blocks.data, blocks.error);
			if (table === "user_profiles") {
				return query(table,
					opts.profiles ?? [
						{ id: USER_A, age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
						{ id: USER_B, age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
					],
					null,
				);
			}
			throw new Error(`unexpected table ${table}`);
		},
		traces,
	};
}

const USER_A = "user-a";
const USER_B = "user-b";
const OUTSIDER = "user-outsider";

function publicCurrentRows(overrides: {
	conversation?: Record<string, unknown>;
	match?: Record<string, unknown>;
	profileA?: unknown;
	profileB?: unknown;
	row?: Record<string, unknown>;
	currentError?: unknown;
} = {}) {
	const profileA = "profileA" in overrides
		? overrides.profileA
		: { id: USER_A, age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z", blocks_sent: [] };
	const profileB = "profileB" in overrides
		? overrides.profileB
		: { id: USER_B, age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z", blocks_sent: [] };
	const conversation = {
		id: "conv-1",
		match_id: "match-1",
		status: "in_progress",
		purpose: "compatibility",
		total_rounds: 10,
		current_round: 3,
		started_at: "2026-08-24T00:00:00Z",
		completed_at: null,
		...overrides.conversation,
	};
	const match = {
		id: "match-1",
		user_a_id: USER_A,
		user_b_id: USER_B,
		status: "fox_conversation_in_progress",
		profile_a: profileA,
		profile_b: profileB,
		...overrides.match,
	};
	return buildSupabaseFake({
		current: {
			data: { ...conversation, match, ...overrides.row },
			error: overrides.currentError ?? null,
		},
	});
}

describe("checkFoxConversationParticipant", () => {
	it("returns ok:true with matchId for a participant (user_a)", async () => {
		const supabase = buildSupabaseFake({
			conv: { data: { id: "conv-1", match_id: "match-1" }, error: null },
			match: { data: { user_a_id: USER_A, user_b_id: USER_B }, error: null },
		});

		const result = await checkFoxConversationParticipant(supabase as never, "conv-1", USER_A);

		expect(result).toEqual({ ok: true, matchId: "match-1" });
	});

	it("returns ok:true for the other participant (user_b)", async () => {
		const supabase = buildSupabaseFake({
			conv: { data: { id: "conv-1", match_id: "match-1" }, error: null },
			match: { data: { user_a_id: USER_A, user_b_id: USER_B }, error: null },
		});

		const result = await checkFoxConversationParticipant(supabase as never, "conv-1", USER_B);

		expect(result).toEqual({ ok: true, matchId: "match-1" });
	});

	it("returns forbidden for a valid conversation the user isn't part of", async () => {
		const supabase = buildSupabaseFake({
			conv: { data: { id: "conv-1", match_id: "match-1" }, error: null },
			match: { data: { user_a_id: USER_A, user_b_id: USER_B }, error: null },
		});

		const result = await checkFoxConversationParticipant(supabase as never, "conv-1", OUTSIDER);

		expect(result).toEqual({ ok: false, reason: "forbidden" });
	});

	it("returns not_found when the conversation row doesn't exist", async () => {
		const supabase = buildSupabaseFake({
			conv: { data: null, error: null },
		});

		const result = await checkFoxConversationParticipant(supabase as never, "conv-missing", USER_A);

		expect(result).toEqual({ ok: false, reason: "not_found" });
	});

	it("denies access (not_found) when the fox_conversations query errors", async () => {
		const supabase = buildSupabaseFake({
			conv: { data: null, error: { message: "simulated DB error" } },
		});

		const result = await checkFoxConversationParticipant(supabase as never, "conv-1", USER_A);

		expect(result).toEqual({ ok: false, reason: "not_found" });
	});

	it("denies access when the matches query errors (conversation resolved fine, match lookup failed)", async () => {
		const supabase = buildSupabaseFake({
			conv: { data: { id: "conv-1", match_id: "match-1" }, error: null },
			match: { data: null, error: { message: "simulated DB error" } },
		});

		const result = await checkFoxConversationParticipant(supabase as never, "conv-1", USER_A);

		expect(result.ok).toBe(false);
	});

	it("denies access when the counterpart is unverified", async () => {
		const supabase = buildSupabaseFake({
			conv: { data: { id: "conv-1", match_id: "match-1" }, error: null },
			match: { data: { user_a_id: USER_A, user_b_id: USER_B }, error: null },
			profiles: [
				{ id: USER_A, age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
				{ id: USER_B, age_verified_at: null, gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
			],
		});

		await expect(checkFoxConversationParticipant(supabase as never, "conv-1", USER_A)).resolves.toEqual({ ok: false, reason: "forbidden" });
	});
});

describe("checkFoxConversationCurrentAccess", () => {
	const expectation = {
		conversationId: "conv-1",
		matchId: "match-1",
		userA: USER_A,
		userB: USER_B,
	};

	function currentRows(overrides: {
		conversation?: Record<string, unknown>;
		match?: Record<string, unknown>;
		blocksA?: unknown;
		blocksB?: unknown;
		profiles?: Array<Record<string, unknown>>;
		profileA?: unknown;
		profileB?: unknown;
		row?: Record<string, unknown>;
		currentError?: unknown;
		beforeCurrentResolve?: () => Promise<void>;
		userA?: string;
		userB?: string;
	} = {}) {
		const userA = overrides.userA ?? USER_A;
		const userB = overrides.userB ?? USER_B;
		const profiles = overrides.profiles ?? [
			{ id: userA, age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
			{ id: userB, age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
		];
		const profileA = "profileA" in overrides
			? overrides.profileA
			: { ...(profiles[0] ?? {}), id: userA, blocks_sent: "blocksA" in overrides ? overrides.blocksA : [] };
		const profileB = "profileB" in overrides
			? overrides.profileB
			: { ...(profiles[1] ?? {}), id: userB, blocks_sent: "blocksB" in overrides ? overrides.blocksB : [] };
		const conversation = {
			id: "conv-1",
			match_id: "match-1",
			status: "in_progress",
			purpose: "compatibility",
			total_rounds: 10,
			current_round: 3,
			started_at: "2026-08-24T00:00:00Z",
			completed_at: null,
			...overrides.conversation,
		};
		const match = {
			id: "match-1",
			user_a_id: userA,
			user_b_id: userB,
			status: "fox_conversation_in_progress",
			...overrides.match,
		};
		return buildSupabaseFake({
			current: {
				data: { ...conversation, match: { ...match, profile_a: profileA, profile_b: profileB }, ...overrides.row },
				error: overrides.currentError ?? null,
				beforeResolve: overrides.beforeCurrentResolve,
			},
		});
	}

	it("allows an exact active pair only while both rows are active", async () => {
		const result = await checkFoxConversationCurrentAccess(currentRows() as never, expectation, "active");

		expect(result).toMatchObject({
			ok: true,
			conversationStatus: "in_progress",
			matchStatus: "fox_conversation_in_progress",
			matchId: "match-1",
		});
	});

	it("rechecks the active recording expiry after the awaited current-access query", async () => {
		const [recordingUserA, recordingUserB] = RECORDING_REHEARSAL_GENERATION_PAIRS["aoi-ren"];
		const now = Date.parse("2026-09-27T02:00:00.000Z");
		const expiresAt = new Date(now + 1_000);
		const generationWindow = resolveFoxConversationRecordingWindow({
			RECORDING_REHEARSAL_ENABLED: "enabled",
			RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 1_000).toISOString(),
			RECORDING_REHEARSAL_EXPIRES_AT: expiresAt.toISOString(),
			RECORDING_REHEARSAL_PAIR: "aoi-ren",
		}, recordingUserA, recordingUserB, now);
		vi.useFakeTimers();
		vi.setSystemTime(now);
		try {
			const delayedRows = currentRows({
				userA: recordingUserA,
				userB: recordingUserB,
				beforeCurrentResolve: async () => {
					await Promise.resolve();
					vi.setSystemTime(expiresAt);
				},
			});
			const result = await checkFoxConversationCurrentAccess(
				delayedRows as never,
				{ ...expectation, userA: recordingUserA, userB: recordingUserB, generationWindow },
				"active",
			);
			expect(result).toEqual({ ok: false, reason: "forbidden" });
		} finally {
			vi.useRealTimers();
		}
	});

	it("uses a distinct completed status pair for completed output", async () => {
		const supabase = currentRows({
			conversation: { status: "completed" },
			match: { status: "fox_conversation_completed" },
		});

		await expect(checkFoxConversationCurrentAccess(supabase as never, expectation, "completed")).resolves.toMatchObject({ ok: true });
		await expect(checkFoxConversationCurrentAccess(supabase as never, expectation, "active")).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it("rejects a conversation or match row whose exact identity/participants differ", async () => {
		await expect(
			checkFoxConversationCurrentAccess(
				currentRows({ conversation: { match_id: "other-match" } }) as never,
				expectation,
				"active",
			),
		).resolves.toEqual({ ok: false, reason: "forbidden" });

		await expect(
			checkFoxConversationCurrentAccess(
				currentRows({ match: { user_a_id: USER_B, user_b_id: USER_A } }) as never,
				expectation,
				"active",
			),
		).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it("uses one embedded read with exact relationship hints and opposite block filters", async () => {
		const supabase = currentRows();

		await expect(checkFoxConversationCurrentAccess(supabase as never, expectation, "active")).resolves.toMatchObject({ ok: true });

		const traces = (supabase as unknown as { traces: QueryTrace[] }).traces;
		expect(traces).toHaveLength(1);
		expect(traces[0].table).toBe("fox_conversations");
		expect(traces[0].singleCalls).toBe(1);
		const select = traces[0].selects[0].replace(/\s+/g, "");
		expect(select).toContain("match:matches!fox_conversations_match_id_fkey!inner(");
		expect(select).toContain("profile_a:user_profiles!matches_user_a_id_fkey!inner(");
		expect(select).toContain("profile_b:user_profiles!matches_user_b_id_fkey!inner(");
		expect(select).toContain("blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)");
		expect(select).not.toContain("blocks!blocks_blocker_id_fkey!inner");
		expect(traces[0].filters).toEqual([
			["id", "conv-1"],
			["match_id", "match-1"],
			["match.profile_a.blocks_sent.blocked_id", USER_B],
			["match.profile_b.blocks_sent.blocked_id", USER_A],
		]);
	});

	it("rejects a current block embedded from either direction", async () => {
		const blockAtoB = { id: "block-a-to-b", blocker_id: USER_A, blocked_id: USER_B };
		const blockBtoA = { id: "block-b-to-a", blocker_id: USER_B, blocked_id: USER_A };

		await expect(
			checkFoxConversationCurrentAccess(currentRows({ blocksA: [blockAtoB] }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(
			checkFoxConversationCurrentAccess(currentRows({ blocksB: [blockBtoA] }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it("fails closed for missing or malformed embedded relationships and IDs", async () => {
		await expect(
			checkFoxConversationCurrentAccess(currentRows({ row: { match: [] } }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "error" });
		await expect(
			checkFoxConversationCurrentAccess(currentRows({
				profileA: {
					id: "unexpected-profile",
					age_verified_at: "2026-08-24T00:00:00Z",
					gender_identity: "woman",
					preferred_genders: ["woman"],
					preference_mode: "selected",
					dating_market: "JP",
					onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
					blocks_sent: [],
				},
			}) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(
			checkFoxConversationCurrentAccess(currentRows({ blocksA: null }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "error" });
		await expect(
			checkFoxConversationCurrentAccess(currentRows({ blocksB: undefined }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "error" });
		await expect(
			checkFoxConversationCurrentAccess(currentRows({ blocksA: [{ id: "wrong-block", blocker_id: USER_B, blocked_id: USER_A }] }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "error" });
		await expect(
			checkFoxConversationCurrentAccess(currentRows({ profileA: null }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "error" });
		await expect(
			checkFoxConversationCurrentAccess(currentRows({ profileB: undefined }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "error" });
	});

	it("maps embedded query errors without exposing their details", async () => {
		await expect(
			checkFoxConversationCurrentAccess(currentRows({ currentError: { code: "PGRST116", message: "missing" } }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "not_found" });
		await expect(
			checkFoxConversationCurrentAccess(currentRows({ currentError: { message: "database unavailable" } }) as never, expectation, "active"),
		).resolves.toEqual({ ok: false, reason: "error" });
	});

	it.each([
		["preference", { preferred_genders: ["man"] }],
		["market", { dating_market: "US" }],
		["age verification", { age_verified_at: null }],
		["onboarding completion", { onboarding_settings_completed_at: null }],
	])("rejects current access after a counterpart %s change", async (_label, changedFields) => {
		const profiles = [
			{ id: USER_A, age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
			{ id: USER_B, age_verified_at: "2026-08-24T00:00:00Z", gender_identity: "woman", preferred_genders: ["woman"], preference_mode: "selected", dating_market: "JP", onboarding_settings_completed_at: "2026-08-24T00:00:00Z", ...changedFields },
		];

		await expect(checkFoxConversationCurrentAccess(currentRows({ profiles }) as never, expectation, "active")).resolves.toEqual({ ok: false, reason: "forbidden" });
	});
});

describe("checkFoxConversationCurrentAccess public_read", () => {
	const expectation = {
		conversationId: "conv-1",
		matchId: "match-1",
		userA: USER_A,
		userB: USER_B,
		viewerId: USER_A,
	};

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
	])("allows the exact public pair %s/%s", async (conversationStatus, matchStatus) => {
		await expect(
			checkFoxConversationCurrentAccess(
				publicCurrentRows({ conversation: { status: conversationStatus }, match: { status: matchStatus } }) as never,
				expectation,
				"public_read",
			),
		).resolves.toMatchObject({
			ok: true,
			conversationStatus,
			matchStatus,
			purpose: "compatibility",
			publicDetail: {
				id: "conv-1",
				match_id: "match-1",
				status: conversationStatus,
			},
		});
	});

	it.each([
		["completed", "meetup_intent"],
		["completed", "meetup_confirmed"],
		["completed", "fox_conversation_failed"],
		["completed", "fox_conversation_in_progress"],
		["failed", "fox_conversation_completed"],
		["pending", "fox_conversation_completed"],
	])("rejects a public status mismatch %s/%s", async (conversationStatus, matchStatus) => {
		await expect(
			checkFoxConversationCurrentAccess(
				publicCurrentRows({ conversation: { status: conversationStatus }, match: { status: matchStatus } }) as never,
				expectation,
				"public_read",
			),
		).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it("requires the compatibility purpose and an exact participant viewer", async () => {
		await expect(
			checkFoxConversationCurrentAccess(
				publicCurrentRows({ conversation: { purpose: "scheduling" } }) as never,
				expectation,
				"public_read",
			),
		).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(
			checkFoxConversationCurrentAccess(
				publicCurrentRows() as never,
				{ ...expectation, viewerId: OUTSIDER },
				"public_read",
			),
		).resolves.toEqual({ ok: false, reason: "forbidden" });
		const outsiderRead = publicCurrentRows();
		await expect(readFoxConversationPublicAccess(outsiderRead as never, "conv-1", OUTSIDER)).resolves.toEqual({ ok: false, reason: "forbidden" });
		expect((outsiderRead as unknown as { traces: QueryTrace[] }).traces).toHaveLength(1);
	});

	it("returns a closed public detail projection from the initial lookup", async () => {
		const supabase = publicCurrentRows();
		const result = await readFoxConversationPublicAccess(supabase as never, "conv-1", USER_B);
		expect(result).toMatchObject({
			ok: true,
			expectation: { conversationId: "conv-1", matchId: "match-1", userA: USER_A, userB: USER_B, viewerId: USER_B },
			publicDetail: {
				id: "conv-1",
				match_id: "match-1",
				status: "in_progress",
				total_rounds: 10,
				current_round: 3,
				started_at: "2026-08-24T00:00:00Z",
				completed_at: null,
			},
		});
		if (result.ok) expect(Object.keys(result.publicDetail).sort()).toEqual([
				"completed_at",
				"current_round",
				"id",
				"match_id",
				"started_at",
				"status",
				"total_rounds",
			]);
		const traces = (supabase as unknown as { traces: QueryTrace[] }).traces;
		expect(traces).toHaveLength(2);
		expect(traces[0]?.selects[0]).not.toContain("blocks_sent");
		expect(traces[0]?.selects[0]).not.toContain("profile_a:user_profiles");
		expect(traces[1]?.filters).toEqual([
			["id", "conv-1"],
			["match_id", "match-1"],
			["match.profile_a.blocks_sent.blocked_id", USER_B],
			["match.profile_b.blocks_sent.blocked_id", USER_A],
			["purpose", "compatibility"],
		]);
	});
});
