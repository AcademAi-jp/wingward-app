import { createClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { checkVerifiedPair } from "./match-age-access";
import {
	arrangeMeetup,
	recordMeetupProposalResponse,
	validateGeneratedCandidates,
	type ProposalGeneratorInput,
} from "./meetups";

vi.mock("./match-age-access", () => ({ checkVerifiedPair: vi.fn() }));

const USER_A = "10000000-0000-0000-0000-000000000001";
const USER_B = "10000000-0000-0000-0000-000000000002";
const USER_C = "10000000-0000-0000-0000-000000000003";
const MATCH_ID = "20000000-0000-0000-0000-000000000001";
const OTHER_MATCH_ID = "20000000-0000-0000-0000-000000000002";
const MEETUP_ID = "30000000-0000-0000-0000-000000000001";
const ROOM_ID = "40000000-0000-0000-0000-000000000001";
const PROPOSAL_ID = "50000000-0000-0000-0000-000000000001";
const NOW = new Date("2026-09-04T00:00:00.000Z");

type QueryResult = { data: unknown; error: unknown };
type ArrangeClient = Parameters<typeof arrangeMeetup>[0];

type FakeClientOptions = {
	queues?: Record<string, QueryResult[]>;
	rpc: (name: string, args: Record<string, unknown>) => QueryResult;
};

type FakeClient = {
	client: ArrangeClient;
	fromCalls: string[];
	rpcCalls: Array<[string, Record<string, unknown>]>;
};

function makeBuilder(result: QueryResult): Record<string, unknown> {
	const builder: Record<string, unknown> = {};
	for (const method of ["select", "eq", "in", "or", "limit", "order"]) {
		builder[method] = vi.fn(() => builder);
	}
	builder.maybeSingle = vi.fn(async () => result);
	builder.update = vi.fn(() => {
		throw new Error("arrangement reads must not perform direct state writes");
	});
	builder.upsert = vi.fn(() => {
		throw new Error("arrangement must persist through the RPC");
	});
	return builder;
}

function makeClient(options: FakeClientOptions): FakeClient {
	const fromCalls: string[] = [];
	const rpcCalls: Array<[string, Record<string, unknown>]> = [];
	const queues = options.queues ?? {};
	const client = {
		from(table: string): Record<string, unknown> {
			fromCalls.push(table);
			return makeBuilder(queues[table]?.shift() ?? { data: null, error: null });
		},
		rpc(name: string, args: Record<string, unknown>): Promise<QueryResult> {
			rpcCalls.push([name, args]);
			return Promise.resolve(options.rpc(name, args));
		},
	};
	return { client: client as unknown as ArrangeClient, fromCalls, rpcCalls };
}

function generatedCandidate(index: number, startsAt = `2026-09-0${5 + index}T10:00:00+09:00`) {
	return {
		starts_at: startsAt,
		timezone: "Asia/Tokyo",
		area: `Tokyo/Chiyoda-${index}`,
		format: index === 0 ? "cafe" : index === 1 ? "meal" : "activity",
		rationale: `Fits shared availability option ${index + 1}`,
	};
}

function validCandidates() {
	return [generatedCandidate(0), generatedCandidate(1), generatedCandidate(2)];
}

function meetupAccessRow(status: string): Record<string, unknown> {
	return {
		id: MEETUP_ID,
		match_id: MATCH_ID,
		initiator_id: USER_A,
		status,
		confirmed_start_at: null,
		confirmed_timezone: null,
		area: null,
		format: null,
		intent_expires_at: null,
		proposal_expires_at: null,
	};
}

function matchingProfile(
	id: string,
	overrides: Record<string, unknown> = {},
): Record<string, unknown> {
	return {
		id,
		age_verified_at: "2026-09-01T00:00:00Z",
		gender_identity: id === USER_A ? "woman" : "man",
		preferred_genders: [id === USER_A ? "man" : "woman"],
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: "2026-09-01T00:00:00Z",
		blocks_sent: [],
		...overrides,
	};
}

function meetupSnapshotRow(
	status: string,
	overrides: {
		meetup?: Record<string, unknown>;
		match?: Record<string, unknown>;
		profileA?: Record<string, unknown>;
		profileB?: Record<string, unknown>;
		directRoom?: Record<string, unknown> | null;
	} = {},
): Record<string, unknown> {
	const match = {
		id: MATCH_ID,
		user_a_id: USER_A,
		user_b_id: USER_B,
		status: "direct_chat_active",
		...overrides.match,
	};
	return {
		id: MEETUP_ID,
		match_id: match.id,
		initiator_id: USER_A,
		status,
		...overrides.meetup,
		match: {
			...match,
			profile_a: matchingProfile(match.user_a_id, overrides.profileA),
			profile_b: matchingProfile(match.user_b_id, overrides.profileB),
			direct_room: overrides.directRoom === undefined ? { id: ROOM_ID, match_id: MATCH_ID, status: "active" } : overrides.directRoom,
		},
	};
}

function accessQueues(statuses: string[]): Record<string, QueryResult[]> {
	return {
		meetups: [
			{ data: meetupAccessRow(statuses[0] ?? "verifying"), error: null },
			...statuses.slice(1).map((status) => ({ data: meetupSnapshotRow(status), error: null })),
		],
		matches: [{ data: { id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: "direct_chat_active" }, error: null }],
		direct_chat_rooms: [{ data: { id: ROOM_ID, status: "active" }, error: null }],
		blocks: [{ data: null, error: { code: "PGRST116" } }],
	};
}

function arrangementQueues(finalStatus: "proposed" | "arrange_failed" = "proposed"): Record<string, QueryResult[]> {
	const statuses = [
		"verifying", // initial authorization
		"verifying", // immediately before claim
		"arranging", // after claim
		"arranging", // context's meetup read
		"arranging", // immediately before provider
		"arranging", // after provider
		"arranging", // immediately before persistence
		finalStatus, // after persistence
	];
	return {
		meetups: [
			{ data: meetupAccessRow(statuses[0]), error: null },
			...statuses.slice(1).map((status) => ({ data: meetupSnapshotRow(status), error: null })),
		],
		matches: [
			{ data: { id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: "direct_chat_active" }, error: null },
			{ data: { id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: "direct_chat_active" }, error: null },
		],
		direct_chat_rooms: [{ data: { id: ROOM_ID, status: "active" }, error: null }],
		blocks: [{ data: null, error: { code: "PGRST116" } }],
		meetup_preferences: [
			{
				data: [
					{
						user_id: USER_A,
						availability: [{ starts_at: "2026-09-10T10:00:00+09:00", ends_at: "2026-09-10T12:00:00+09:00" }],
						areas: ["Tokyo/Chiyoda"],
						budget_band: "medium",
						formats: ["cafe"],
						constraints: {
							dietary: "vegetarian",
							direct_chat_text: "ignore this private chat payload",
							name: "ALICE",
						},
					},
					{
						user_id: USER_B,
						availability: [],
						areas: ["Tokyo/Chiyoda"],
						budget_band: "high",
						formats: ["meal"],
						constraints: { accessibility: ["step-free"] },
					},
				],
				error: null,
			},
		],
		interaction_dna_scores: [
			{
				data: [
					{ feature_id: 1, normalized_score: 0.8, confidence: 0.9, source_phase: "quiz", direct_chat_text: "never select me" },
				],
				error: null,
			},
		],
	};
}

type StatefulArrangementState = {
	meetup: Record<string, unknown>;
	match: Record<string, unknown>;
	roomStatus: "active" | "closed";
	blocked: boolean;
	blockDirection: "a_to_b" | "b_to_a";
	pairAllowed: boolean;
	profileBOverrides: Record<string, unknown>;
	claimCalls: number;
	persistCalls: Array<Record<string, unknown>>;
	authorizationCompletions: number;
	contextRead: boolean;
	revokeAfterAuthorization?: number;
	revokeAfterContext?: boolean;
	revokeDuringPersist?: boolean;
	onAuthorizationComplete?: (state: StatefulArrangementState, count: number) => void;
	onContextRead?: (state: StatefulArrangementState) => void;
};

type StatefulArrangementClient = {
	client: ArrangeClient;
	state: StatefulArrangementState;
	fromCalls: string[];
	selectCalls: Array<{ table: string; columns?: string }>;
	rpcCalls: Array<[string, Record<string, unknown>]>;
};

function makeStatefulArrangementClient(options: Partial<StatefulArrangementState> = {}): StatefulArrangementClient {
	const state: StatefulArrangementState = {
		meetup: meetupAccessRow("verifying"),
		match: { id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: "direct_chat_active" },
		roomStatus: "active",
		blocked: false,
		blockDirection: "a_to_b",
		pairAllowed: true,
		profileBOverrides: {},
		claimCalls: 0,
		persistCalls: [],
		authorizationCompletions: 0,
		contextRead: false,
		...options,
	};
	const fromCalls: string[] = [];
	const selectCalls: Array<{ table: string; columns?: string }> = [];
	const rpcCalls: Array<[string, Record<string, unknown>]> = [];
	const preferences = [
		{
			user_id: USER_A,
			availability: [{ starts_at: "2026-09-10T10:00:00+09:00", ends_at: "2026-09-10T12:00:00+09:00" }],
			areas: ["Tokyo/Chiyoda"],
			budget_band: "medium",
			formats: ["cafe"],
			constraints: {},
		},
		{
			user_id: USER_B,
			availability: [],
			areas: ["Tokyo/Chiyoda"],
			budget_band: "high",
			formats: ["meal"],
			constraints: {},
		},
	];

	function currentSnapshotRow(): Record<string, unknown> {
		const match = state.match;
		const invalidPair = state.pairAllowed ? {} : { preferred_genders: [] };
		const blockFromA = state.blocked && state.blockDirection === "a_to_b"
			? [{ id: "60000000-0000-0000-0000-000000000001", blocker_id: match.user_a_id, blocked_id: match.user_b_id }]
			: [];
		const blockFromB = state.blocked && state.blockDirection === "b_to_a"
			? [{ id: "60000000-0000-0000-0000-000000000002", blocker_id: match.user_b_id, blocked_id: match.user_a_id }]
			: [];
		return {
			id: state.meetup.id,
			match_id: state.meetup.match_id,
			initiator_id: state.meetup.initiator_id,
			status: state.meetup.status,
			match: {
				...match,
				profile_a: matchingProfile(String(match.user_a_id), {
					blocks_sent: blockFromA,
				}),
				profile_b: matchingProfile(String(match.user_b_id), {
					...state.profileBOverrides,
					...invalidPair,
					blocks_sent: blockFromB,
				}),
				direct_room: { id: ROOM_ID, match_id: match.id, status: state.roomStatus },
			},
		};
	}

	function read(table: string, filters: Array<[string, unknown]>, selectedColumns?: string): QueryResult {
		if (table === "meetups") {
			const requestedId = filters.find(([column]) => column === "id")?.[1];
			if (requestedId !== MEETUP_ID) return { data: null, error: { code: "PGRST116" } };
			if (!selectedColumns?.includes("match:matches!")) return { data: state.meetup, error: null };
			const expectedSnapshotFilters: Array<[string, unknown]> = [
				["id", MEETUP_ID],
				["match_id", MATCH_ID],
				["match.id", MATCH_ID],
				["match.user_a_id", USER_A],
				["match.user_b_id", USER_B],
				["match.profile_a.blocks_sent.blocked_id", USER_B],
				["match.profile_b.blocks_sent.blocked_id", USER_A],
			];
			if (
				!selectedColumns.includes("match:matches!meetups_match_id_fkey!inner") ||
				expectedSnapshotFilters.some(([column, value]) => !filters.some(([actualColumn, actualValue]) => actualColumn === column && actualValue === value))
			) {
				return { data: null, error: { message: "unexpected current-access snapshot query" } };
			}
			return { data: currentSnapshotRow(), error: null };
		}
		if (table === "matches") {
			const requestedId = filters.find(([column]) => column === "id")?.[1];
			return requestedId === undefined || requestedId === state.match.id ? { data: state.match, error: null } : { data: null, error: { code: "PGRST116" } };
		}
		if (table === "direct_chat_rooms") {
			const requestedMatchId = filters.find(([column]) => column === "match_id")?.[1];
			if (requestedMatchId !== state.match.id) return { data: null, error: { code: "PGRST116" } };
			return state.roomStatus === "active"
				? { data: { id: ROOM_ID, status: "active" }, error: null }
				: { data: null, error: { code: "PGRST116" } };
		}
		if (table === "blocks") {
			return state.blocked
				? { data: { id: "60000000-0000-0000-0000-000000000001" }, error: null }
				: { data: null, error: { code: "PGRST116" } };
		}
		if (table === "meetup_preferences") {
			const requestedUsers = filters.find(([column]) => column === "user_id")?.[1];
			if (!Array.isArray(requestedUsers) || requestedUsers.length !== 2 || !requestedUsers.includes(USER_A) || !requestedUsers.includes(USER_B)) {
				return { data: null, error: { message: "unexpected preference filter" } };
			}
			return { data: preferences, error: null };
		}
		if (table === "interaction_dna_scores") {
			const requestedMatchId = filters.find(([column]) => column === "match_id")?.[1];
			return requestedMatchId === state.match.id
				? { data: [{ feature_id: 1, normalized_score: 0.8, confidence: 0.9, source_phase: "quiz" }], error: null }
				: { data: null, error: { message: "unexpected DNA filter" } };
		}
		return { data: null, error: null };
	}

	function maybeRevokeAfterRead(table: string): void {
		if (table === "blocks") {
			state.authorizationCompletions += 1;
			if (state.revokeAfterAuthorization === state.authorizationCompletions) state.pairAllowed = false;
			state.onAuthorizationComplete?.(state, state.authorizationCompletions);
		}
		if (table === "interaction_dna_scores" && state.revokeAfterContext) {
			state.contextRead = true;
			state.pairAllowed = false;
		}
		if (table === "interaction_dna_scores") state.onContextRead?.(state);
	}

	function builderFor(table: string): Record<string, unknown> {
		const filters: Array<[string, unknown]> = [];
		let selectedColumns: string | undefined;
		const builder: Record<string, unknown> = {};
		builder.select = vi.fn((columns?: string) => {
			selectedColumns = columns;
			selectCalls.push({ table, columns });
			return builder;
		});
		for (const method of ["order", "limit"]) builder[method] = vi.fn(() => builder);
		builder.eq = vi.fn((column: string, value: unknown) => {
			filters.push([column, value]);
			return builder;
		});
		builder.or = vi.fn((value: string) => {
			filters.push(["or", value]);
			return builder;
		});
		builder.in = vi.fn((column: string, values: unknown[]) => {
			filters.push([column, values]);
			return builder;
		});
		builder.maybeSingle = vi.fn(async () => {
			const result = read(table, filters, selectedColumns);
			maybeRevokeAfterRead(table);
			return result;
		});
		return builder;
	}

	const client = {
		from(table: string): Record<string, unknown> {
			fromCalls.push(table);
			return builderFor(table);
		},
		rpc(name: string, args: Record<string, unknown>): Promise<QueryResult> {
			rpcCalls.push([name, args]);
			if (name === "claim_meetup_arrangement") {
				state.claimCalls += 1;
				state.meetup.status = "arranging";
				return Promise.resolve({ data: [claimedRow()], error: null });
			}
			if (name === "persist_meetup_proposal") {
				state.persistCalls.push(args);
				const hasCandidates = args.p_candidates !== null;
				state.meetup.status = hasCandidates ? "proposed" : "arrange_failed";
				if (state.revokeDuringPersist) state.pairAllowed = false;
				return Promise.resolve({
					data: [
						persistedRow(
							hasCandidates
								? {}
								: { proposal_id: null, outcome: "arrange_failed", status: "arrange_failed" },
						),
					],
					error: null,
				});
			}
			throw new Error(`unexpected RPC ${name}`);
		},
	};
	return { client: client as unknown as ArrangeClient, state, fromCalls, selectCalls, rpcCalls };
}

const claimedRow = (overrides: Record<string, unknown> = {}) => ({
	meetup_id: MEETUP_ID,
	match_id: MATCH_ID,
	status: "arranging",
	attempt_number: 1,
	billing_source: "meetup_arrange",
	transitioned: true,
	outcome: "claimed",
	...overrides,
});

const persistedRow = (overrides: Record<string, unknown> = {}) => ({
	meetup_id: MEETUP_ID,
	match_id: MATCH_ID,
	proposal_id: PROPOSAL_ID,
	attempt_number: 1,
	outcome: "proposed",
	status: "proposed",
	transitioned: true,
	...overrides,
});

function useStatefulPairGate(state: StatefulArrangementState): void {
	vi.mocked(checkVerifiedPair).mockImplementation(async () =>
		state.pairAllowed ? { ok: true } : { ok: false, reason: "unverified" },
	);
}

beforeEach(() => {
	vi.clearAllMocks();
	vi.mocked(checkVerifiedPair).mockResolvedValue({ ok: true });
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe("generated proposal boundary", () => {
	it("accepts exactly three distinct candidates through the 21-day inclusive edge", () => {
		const edgeCandidates = validCandidates();
		edgeCandidates[0] = generatedCandidate(0, "2026-09-25T00:00:00Z");
		expect(validateGeneratedCandidates(edgeCandidates, NOW)).toEqual(edgeCandidates);
	});

	it.each([
		["two candidates", validCandidates().slice(0, 2)],
		["four candidates", [...validCandidates(), generatedCandidate(3, "2026-09-08T10:00:00+09:00")]],
		["at now", [generatedCandidate(0, "2026-09-04T00:00:00Z"), generatedCandidate(1), generatedCandidate(2)]],
		["after 21 days", [generatedCandidate(0, "2026-09-25T00:00:00.001Z"), generatedCandidate(1), generatedCandidate(2)]],
		["unknown timezone", [ { ...generatedCandidate(0), timezone: "Mars/Olympus" }, generatedCandidate(1), generatedCandidate(2)]],
		["precise area", [ { ...generatedCandidate(0), area: "Tokyo/Chiyoda, 1-1-1" }, generatedCandidate(1), generatedCandidate(2)]],
		["extra output key", [ { ...generatedCandidate(0), venue_id: "secret" }, generatedCandidate(1), generatedCandidate(2)]],
		["unbounded rationale control", [ { ...generatedCandidate(0), rationale: "line 1\nline 2" }, generatedCandidate(1), generatedCandidate(2)]],
	])("rejects %s", (_label, candidates) => {
		expect(validateGeneratedCandidates(candidates, NOW)).toBeNull();
	});
});

describe("arrange RPC boundary", () => {
	it.each([
		["non-participant", "not_found", { ok: false, reason: "not_found" }],
		["identity gate", "identity_verification_required", { ok: false, reason: "identity_verification_required" }],
		["exhausted quota", "quota_exhausted", { ok: false, reason: "quota_exhausted" }],
	] as const)("stops before reads and generation for %s claim outcomes", async (_label, outcome, expected) => {
		const generator = vi.fn(async () => validCandidates());
		const fake = makeClient({
			queues: accessQueues(["verifying", "verifying"]),
			rpc: (name) => {
				expect(name).toBe("claim_meetup_arrangement");
			return {
				data: [
					claimedRow({
						outcome,
						status: outcome === "not_found" ? null : "verifying",
						match_id: outcome === "not_found" ? null : MATCH_ID,
						attempt_number: null,
						billing_source: null,
						transitioned: false,
					}),
				],
				error: null,
			};
		},
		});

		expect(await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: generator }, { idempotencyKey: "negative-claim" })).toEqual(expected);
		expect(generator).not.toHaveBeenCalled();
		expect(fake.fromCalls).toEqual(["meetups", "matches", "direct_chat_rooms", "blocks", "meetups"]);
		expect(fake.rpcCalls).toHaveLength(1);
	});

	it.each([
		["argument validation", { match_id: null, status: null }],
		["malformed profile timezone", { match_id: MATCH_ID, status: "verifying" }],
	] as const)("accepts the existing %s invalid_input shape", async (_label, shape) => {
		const fake = makeClient({
			queues: accessQueues(["verifying", "verifying"]),
			rpc: () => ({
				data: [
					claimedRow({
						outcome: "invalid_input",
						...shape,
						attempt_number: null,
						billing_source: null,
						transitioned: false,
					}),
				],
				error: null,
			}),
		});

		expect(await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: async () => validCandidates() }, { now: NOW, idempotencyKey: `invalid-input-${_label.replaceAll(" ", "-")}` })).toEqual({
			ok: false,
			reason: "bad_request",
		});
		expect(fake.rpcCalls).toHaveLength(1);
	});

	it.each([
		["different meetup", { meetup_id: OTHER_MATCH_ID }],
		["different match", { match_id: OTHER_MATCH_ID }],
		["wrong claimed status", { status: "proposed" }],
		["wrong transition marker", { transitioned: false }],
	] as const)("rejects a claim row with %s", async (_label, override) => {
		const fake = makeClient({
			queues: accessQueues(["verifying", "verifying"]),
			rpc: () => ({ data: [claimedRow(override)], error: null }),
		});
		const generator = vi.fn(async () => validCandidates());

		expect(await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: generator }, { now: NOW, idempotencyKey: `malformed-claim-${_label.replaceAll(" ", "-")}` })).toEqual({
			ok: false,
			reason: "internal",
		});
		expect(generator).not.toHaveBeenCalled();
		expect(fake.rpcCalls).toHaveLength(1);
	});

	it("marks retry separately at the atomic claim boundary", async () => {
		const fake = makeClient({
			queues: accessQueues(["verifying", "verifying", "proposed"]),
			rpc: (name, args) => {
				expect(name).toBe("claim_meetup_arrangement");
				expect(args.p_is_retry).toBe(true);
				return { data: [claimedRow({ outcome: "already_claimed", status: "proposed", attempt_number: 2, billing_source: "arrange_retry", transitioned: false })], error: null };
			},
		});

		const { retryMeetupArrangement } = await import("./meetups");
		expect(await retryMeetupArrangement(fake.client, USER_A, MEETUP_ID, { idempotencyKey: "retry-claim" })).toEqual({
			ok: true,
			status: "proposed",
			billingSource: "arrange_retry",
		});
		expect(fake.fromCalls).toHaveLength(6);
	});

	it("passes only allow-listed preference/DNA fields to the injected generator", async () => {
		let seenInput: ProposalGeneratorInput | undefined;
		const fake = makeClient({
			queues: arrangementQueues(),
			rpc: (name) => {
				if (name === "claim_meetup_arrangement") return { data: [claimedRow()], error: null };
				return { data: [persistedRow()], error: null };
			},
		});
		const result = await arrangeMeetup(
			fake.client,
			USER_A,
			MEETUP_ID,
			{
				generate: async (input) => {
					seenInput = input;
					return validCandidates();
				},
			},
			{ now: NOW, idempotencyKey: "arrange-test-1" },
		);

		expect(result).toMatchObject({ ok: true, status: "proposed" });
		expect(seenInput).toBeDefined();
		const serialized = JSON.stringify(seenInput);
		expect(serialized).not.toContain(USER_A);
		expect(serialized).not.toContain(USER_B);
		expect(serialized).not.toContain("ALICE");
		expect(serialized).not.toContain("private chat payload");
		expect(serialized).not.toContain("never select me");
		expect(seenInput?.preferences.first.constraints).toEqual({});
		expect(fake.rpcCalls.map(([name]) => name)).toEqual([
		"claim_meetup_arrangement",
		"persist_meetup_proposal",
		]);
	});

	it("turns invalid generator output into arrange_failed/N-14 without persisting candidates", async () => {
		const fake = makeClient({
			queues: arrangementQueues("arrange_failed"),
			rpc: (name, args) => {
				if (name === "claim_meetup_arrangement") return { data: [claimedRow()], error: null };
				expect(name).toBe("persist_meetup_proposal");
				expect(args.p_candidates).toBeNull();
				return { data: [persistedRow({ proposal_id: null, outcome: "arrange_failed", status: "arrange_failed" })], error: null };
			},
		});
		const result = await arrangeMeetup(
			fake.client,
			USER_A,
			MEETUP_ID,
			{ generate: async () => [generatedCandidate(0)] },
			{ now: NOW, idempotencyKey: "arrange-invalid-1" },
		);

		expect(result).toEqual({
			ok: true,
			status: "arrange_failed",
			billingSource: "meetup_arrange",
			notificationContexts: [
				{
					scenarioId: "N-14",
					meetupId: MEETUP_ID,
					matchId: MATCH_ID,
					recipientIds: [USER_A, USER_B],
				},
			],
		});
		expect(fake.fromCalls).not.toContain("usage_counters");
	});

	it.each([
		["different match", { match_id: OTHER_MATCH_ID }],
		["different attempt", { attempt_number: 2 }],
	] as const)("rejects a persistence row with %s without returning output", async (_label, override) => {
		const fake = makeClient({
			queues: arrangementQueues(),
			rpc: (name) => {
				if (name === "claim_meetup_arrangement") return { data: [claimedRow()], error: null };
				return { data: [persistedRow(override)], error: null };
			},
		});

		const result = await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: async () => validCandidates() }, { now: NOW, idempotencyKey: `malformed-persist-${_label.replaceAll(" ", "-")}` });
		expect(result).toEqual({ ok: false, reason: "internal" });
	});

	it("does not turn a provider failure into a proposed success when persistence lies about null candidates", async () => {
		const fake = makeClient({
			queues: arrangementQueues(),
			rpc: (name, args) => {
				if (name === "claim_meetup_arrangement") return { data: [claimedRow()], error: null };
				expect(args.p_candidates).toBeNull();
				return { data: [persistedRow()], error: null };
			},
		});

		const result = await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: async () => { throw new Error("provider failed"); } }, { now: NOW, idempotencyKey: "provider-failure-no-proposal" });
		expect(result).toEqual({ ok: false, reason: "internal" });
	});

	it("does not re-run the generator or bill when the claim is already owned", async () => {
		const generator = vi.fn(async () => validCandidates());
		const fake = makeClient({
			queues: accessQueues(["verifying", "verifying", "proposed"]),
			rpc: () => ({
			data: [claimedRow({ outcome: "already_claimed", status: "proposed", billing_source: "arrange_retry", transitioned: false })],
			error: null,
		}),
		});
		const result = await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: generator }, { idempotencyKey: "same-key" });

		expect(result).toEqual({ ok: true, status: "proposed", billingSource: "arrange_retry" });
		expect(generator).not.toHaveBeenCalled();
		expect(fake.fromCalls).toHaveLength(6);
	});
});

describe("arrangement current-access output guard", () => {
	it("serializes the ordered participants and both block filters in one current snapshot request", async () => {
		const responses: unknown[] = [
			meetupAccessRow("verifying"),
			{ id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: "direct_chat_active" },
			{ id: ROOM_ID, status: "active" },
			[],
			[],
		];
		let responseIndex = 0;
		const fetchMock = vi.fn(async (_input: RequestInfo | URL) =>
			new Response(JSON.stringify(responses[responseIndex++] ?? []), {
				status: 200,
				headers: { "Content-Type": "application/json" },
			}),
		);
		vi.stubGlobal("fetch", fetchMock);
		const supabase = createClient("https://supabase.test", "anon-key", {
			auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
		});

		expect(await arrangeMeetup(supabase, USER_B, MEETUP_ID, { generate: async () => validCandidates() }, { now: NOW, idempotencyKey: "snapshot-query" })).toEqual({
			ok: false,
			reason: "not_found",
		});
		expect(fetchMock).toHaveBeenCalledTimes(5);
		const request = fetchMock.mock.calls[4]?.[0];
		const url = new URL(String(request));
		expect(url.searchParams.get("id")).toBe(`eq.${MEETUP_ID}`);
		expect(url.searchParams.get("match_id")).toBe(`eq.${MATCH_ID}`);
		expect(url.searchParams.get("match.id")).toBe(`eq.${MATCH_ID}`);
		expect(url.searchParams.get("match.user_a_id")).toBe(`eq.${USER_A}`);
		expect(url.searchParams.get("match.user_b_id")).toBe(`eq.${USER_B}`);
		expect(url.searchParams.get("match.profile_a.blocks_sent.blocked_id")).toBe(`eq.${USER_B}`);
		expect(url.searchParams.get("match.profile_b.blocks_sent.blocked_id")).toBe(`eq.${USER_A}`);
		expect(url.searchParams.get("select")).toContain("match:matches!meetups_match_id_fkey!inner");
		expect(url.searchParams.get("select")).toContain("direct_room:direct_chat_rooms!direct_chat_rooms_match_id_fkey");
	});

	it.each([
		["reverse preference", (state: StatefulArrangementState) => { state.profileBOverrides = { preferred_genders: ["man"] }; }],
		["dating market", (state: StatefulArrangementState) => { state.profileBOverrides = { dating_market: "US" }; }],
		["age verification", (state: StatefulArrangementState) => { state.profileBOverrides = { age_verified_at: null }; }],
		["onboarding completion", (state: StatefulArrangementState) => { state.profileBOverrides = { onboarding_settings_completed_at: null }; }],
		["block", (state: StatefulArrangementState) => { state.blocked = true; }],
		["block in reverse direction", (state: StatefulArrangementState) => { state.blocked = true; state.blockDirection = "b_to_a"; }],
		["room close", (state: StatefulArrangementState) => { state.roomStatus = "closed"; }],
		["participant reassignment", (state: StatefulArrangementState) => {
			state.match = { ...state.match, user_b_id: USER_C };
		}],
		["initiator reassignment", (state: StatefulArrangementState) => {
			state.meetup = { ...state.meetup, initiator_id: USER_B };
		}],
		["meetup reassignment", (state: StatefulArrangementState) => {
			state.meetup = { ...state.meetup, match_id: OTHER_MATCH_ID };
			state.match = { ...state.match, id: OTHER_MATCH_ID };
		}],
	] as const)("does not claim after %s revokes access", async (_label, revoke) => {
		const fake = makeStatefulArrangementClient({
			onAuthorizationComplete: (_state, count) => {
				if (count === 1) revoke(fake.state);
			},
		});
		useStatefulPairGate(fake.state);
		const generator = vi.fn(async () => validCandidates());

		expect(await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: generator }, { now: NOW, idempotencyKey: `claim-revocation-${_label.replaceAll(" ", "-")}` })).toEqual({
			ok: false,
			reason: "not_found",
		});
		expect(fake.state.claimCalls).toBe(0);
		expect(generator).not.toHaveBeenCalled();
	});

	it("does not invoke the provider when access changes after the allow-listed context read", async () => {
		const fake = makeStatefulArrangementClient({ revokeAfterContext: true });
		useStatefulPairGate(fake.state);
		const generator = vi.fn(async () => validCandidates());

		expect(await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: generator }, { now: NOW, idempotencyKey: "context-revocation" })).toEqual({
			ok: false,
			reason: "not_found",
		});
		expect(fake.state.contextRead).toBe(true);
		expect(generator).not.toHaveBeenCalled();
		expect(fake.state.persistCalls).toHaveLength(0);
	});

	it.each([
		["success", async (state: StatefulArrangementState) => {
			state.pairAllowed = false;
			return validCandidates();
		}],
		["throw", async (state: StatefulArrangementState) => {
			state.pairAllowed = false;
			throw new Error("provider failed");
		}],
	] as const)("suppresses provider %s output after access is revoked", async (_label, generate) => {
		const fake = makeStatefulArrangementClient();
		useStatefulPairGate(fake.state);
		const generator = vi.fn(() => generate(fake.state));

		expect(await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: generator }, { now: NOW, idempotencyKey: `generator-revocation-${_label}` })).toEqual({
			ok: false,
			reason: "not_found",
		});
		expect(generator).toHaveBeenCalledTimes(1);
		expect(fake.state.persistCalls).toHaveLength(0);
		expect(fake.selectCalls.filter(({ columns }) => columns?.includes("match:matches!meetups_match_id_fkey!inner")).length).toBe(4);
		expect(fake.fromCalls.filter((table) => table === "matches")).toHaveLength(2);
		expect(fake.fromCalls.filter((table) => table === "direct_chat_rooms")).toHaveLength(1);
		expect(fake.fromCalls.filter((table) => table === "blocks")).toHaveLength(1);
		expect(checkVerifiedPair).toHaveBeenCalledTimes(1);
	});

	it("suppresses a proposal and notification context when access changes during persistence", async () => {
		const fake = makeStatefulArrangementClient({ revokeDuringPersist: true });
		useStatefulPairGate(fake.state);
		const generator = vi.fn(async () => validCandidates());

		expect(await arrangeMeetup(fake.client, USER_A, MEETUP_ID, { generate: generator }, { now: NOW, idempotencyKey: "persist-revocation" })).toEqual({
			ok: false,
			reason: "not_found",
		});
		expect(fake.state.persistCalls).toHaveLength(1);
		expect(fake.state.persistCalls[0].p_candidates).toEqual(validCandidates());
	});
});

describe("proposal response RPC boundary", () => {
	it("checks identity then calls the existing response RPC without direct response writes", async () => {
		const fake = makeClient({
			queues: {
				meetups: [
					{
						data: {
							id: MEETUP_ID,
							match_id: MATCH_ID,
							initiator_id: USER_A,
							status: "proposed",
							confirmed_start_at: null,
							confirmed_timezone: null,
							area: null,
							format: null,
							intent_expires_at: null,
							proposal_expires_at: "2026-09-12T00:00:00Z",
						},
						error: null,
					},
				],
				matches: [{ data: { id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: "direct_chat_active" }, error: null }],
				direct_chat_rooms: [{ data: { id: ROOM_ID, status: "active" }, error: null }],
				blocks: [{ data: null, error: { code: "PGRST116" } }],
				user_profiles: [
					{
						data: [
							{ id: USER_A, identity_verification_status: "verified", identity_verified_at: "2026-09-01T00:00:00Z" },
							{ id: USER_B, identity_verification_status: "verified", identity_verified_at: "2026-09-01T00:00:00Z" },
						],
						error: null,
					},
				],
			},
			rpc: (name, args) => {
				expect(name).toBe("record_meetup_proposal_response");
				expect(args).toEqual({
					p_meetup_id: MEETUP_ID,
					p_proposal_id: PROPOSAL_ID,
					p_user_id: USER_A,
					p_candidate_index: 1,
				});
				return {
					data: [{ meetup_id: MEETUP_ID, proposal_id: PROPOSAL_ID, outcome: "confirmed", status: "confirmed", confirmed_candidate_index: 1 }],
					error: null,
				};
			},
		});

		const result = await recordMeetupProposalResponse(fake.client, USER_A, MEETUP_ID, PROPOSAL_ID, 1);
		expect(result).toMatchObject({ ok: true, status: "confirmed" });
		expect(fake.rpcCalls).toHaveLength(1);
		expect(fake.fromCalls).not.toContain("meetup_proposal_responses");
	});
});
