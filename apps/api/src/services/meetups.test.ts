import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Database } from "../db/types";
import { checkVerifiedPair } from "./match-age-access";
import {
	createMeetupIntent,
	getMeetupDetail,
	getMeetupDetailByMatch,
	meetupPreferencesSchema,
	saveMeetupPreferences,
} from "./meetups";

vi.mock("./match-age-access", () => ({ checkVerifiedPair: vi.fn() }));

const USER_A = "10000000-0000-0000-0000-000000000001";
const USER_B = "10000000-0000-0000-0000-000000000002";
const MATCH_ID = "20000000-0000-0000-0000-000000000001";
const MEETUP_ID = "30000000-0000-0000-0000-000000000001";
const ROOM_ID = "40000000-0000-0000-0000-000000000001";
const PROPOSAL_ID = "50000000-0000-0000-0000-000000000001";

type QueryResult = { data: unknown; error: unknown };

type FakeDatabase = {
	fromCalls: string[];
	ors: string[];
	rpc: ReturnType<typeof vi.fn>;
	upserts: Array<{ values: Record<string, unknown>; options: Record<string, unknown> | undefined }>;
	updates: Array<{ values: Record<string, unknown>; filters: Array<[string, unknown]> }>;
	client: SupabaseClientLike;
};

type SupabaseClientLike = {
	from: (table: string) => unknown;
	rpc: (...args: unknown[]) => Promise<QueryResult>;
};

type FixtureOptions = {
	meetup?: Record<string, unknown> | null;
	meetupLookup?: Record<string, unknown> | null;
	match?: Record<string, unknown> | null;
	room?: Record<string, unknown> | null;
	block?: Record<string, unknown> | null;
	proposal?: Record<string, unknown> | null;
	preferencesWrite?: QueryResult;
};

function validMeetup(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		id: MEETUP_ID,
		match_id: MATCH_ID,
		initiator_id: USER_A,
		status: "verifying",
		confirmed_start_at: null,
		confirmed_timezone: null,
		area: null,
		format: null,
		intent_expires_at: null,
		proposal_expires_at: null,
		...overrides,
	};
}

function validMatch(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		id: MATCH_ID,
		user_a_id: USER_A,
		user_b_id: USER_B,
		status: "direct_chat_active",
		...overrides,
	};
}

function makeBuilder(
	table: string,
	result: QueryResult,
	fake: Omit<FakeDatabase, "client">,
): Record<string, unknown> {
	const filters: Array<[string, unknown]> = [];
	const builder: Record<string, unknown> = {};
	builder.select = vi.fn(() => builder);
	builder.eq = vi.fn((column: string, value: unknown) => {
		filters.push([column, value]);
		return builder;
	});
	builder.or = vi.fn((filters: string) => {
		fake.ors.push(filters);
		return builder;
	});
	builder.order = vi.fn(() => builder);
	builder.limit = vi.fn(() => builder);
	builder.update = vi.fn((values: Record<string, unknown>) => {
		fake.updates.push({ values, filters });
		return builder;
	});
	builder.upsert = vi.fn((values: Record<string, unknown>, options?: Record<string, unknown>) => {
		fake.upserts.push({ values, options });
		return builder;
	});
	builder.maybeSingle = vi.fn(async () => result);
	void table;
	return builder;
}

function makeDatabase(options: FixtureOptions = {}): FakeDatabase {
	const fake = {
		fromCalls: [] as string[],
		ors: [] as string[],
		rpc: vi.fn(),
		upserts: [] as Array<{ values: Record<string, unknown>; options: Record<string, unknown> | undefined }>,
		updates: [] as Array<{ values: Record<string, unknown>; filters: Array<[string, unknown]> }>,
	};
	const queues: Record<string, QueryResult[]> = {
		meetups: [
			{ data: options.meetupLookup === undefined ? (options.meetup === undefined ? validMeetup() : options.meetup) : options.meetupLookup, error: null },
			{ data: options.meetup === undefined ? validMeetup() : options.meetup, error: null },
		],
		matches: [{ data: options.match === undefined ? validMatch() : options.match, error: null }],
		direct_chat_rooms: [
		{
			data: options.room === undefined ? { id: ROOM_ID, status: "active" } : options.room,
			error: null,
		},
		],
		blocks: [{ data: options.block ?? null, error: null }],
		meetup_proposals: [{ data: options.proposal ?? null, error: null }],
		meetup_preferences: [options.preferencesWrite ?? { data: null, error: null }],
	};
	const client: SupabaseClientLike = {
		from: (table: string) => {
			fake.fromCalls.push(table);
			const result = queues[table]?.shift() ?? { data: null, error: null };
			return makeBuilder(table, result, fake);
		},
		rpc: fake.rpc,
	};
	return { ...fake, client };
}

function asClient(fake: FakeDatabase): DatabaseClient {
	return fake.client as unknown as DatabaseClient;
}

type DatabaseClient = Parameters<typeof createMeetupIntent>[0];

const intentRow = (overrides: Record<string, unknown> = {}) => ({
	meetup_id: MEETUP_ID,
	outcome: "created",
	status: "intent_pending",
	initiator_id: USER_A,
	matched: false,
	...overrides,
});

const validPreferences = {
	availability: [{ starts_at: "2026-09-10T10:00:00+09:00", ends_at: "2026-09-10T12:00:00+09:00" }],
	areas: ["Tokyo/Chiyoda"],
	budget_band: "medium",
	formats: ["cafe"],
	constraints: { dietary: "vegetarian" },
};

beforeEach(() => {
	vi.clearAllMocks();
	vi.mocked(checkVerifiedPair).mockResolvedValue({ ok: true });
});

describe("createMeetupIntent", () => {
	it("calls the atomic RPC first and accepts a created pending intent without a transition", async () => {
		const fake = makeDatabase();
		fake.rpc.mockResolvedValue({ data: [intentRow()], error: null });

		const result = await createMeetupIntent(asClient(fake), USER_A, MATCH_ID);

		expect(result).toEqual({ ok: true, transition: null });
		expect(fake.rpc).toHaveBeenCalledWith("create_or_match_meetup_intent", {
			p_match_id: MATCH_ID,
			p_user_id: USER_A,
		});
		expect(fake.fromCalls).toEqual([]);
	});

	it("conditionally advances a matched intent and exposes only the internal transition", async () => {
		const fake = makeDatabase();
		fake.rpc.mockResolvedValue({
			data: [intentRow({ outcome: "matched", status: "intent_matched", matched: true })],
			error: null,
		});
		const transitionBuilder = makeBuilder("meetups", { data: { id: MEETUP_ID }, error: null }, fake);
		fake.client.from = vi.fn((table: string) => {
			fake.fromCalls.push(table);
			return transitionBuilder;
		});

		const result = await createMeetupIntent(asClient(fake), USER_A, MATCH_ID);

		expect(result).toEqual({
			ok: true,
			transition: "mutual_intent",
			notificationContext: { meetupId: MEETUP_ID, matchId: MATCH_ID },
		});
			expect(fake.updates).toEqual([{ values: { status: "verifying" }, filters: [["id", MEETUP_ID], ["status", "intent_matched"]] }]);
	});

	it("returns notification context for an already-verifying retry", async () => {
		const fake = makeDatabase();
		fake.rpc.mockResolvedValue({
			data: [intentRow({ outcome: "already_active", status: "verifying", matched: true })],
			error: null,
		});

		expect(await createMeetupIntent(asClient(fake), USER_A, MATCH_ID)).toEqual({
			ok: true,
			transition: null,
			notificationContext: { meetupId: MEETUP_ID, matchId: MATCH_ID },
		});
		expect(fake.fromCalls).toEqual([]);
	});

	it("recovers an already-active intent without producing a second transition when another caller won", async () => {
		const fake = makeDatabase();
		fake.rpc.mockResolvedValue({
			data: [intentRow({ outcome: "already_active", status: "intent_matched", matched: true })],
			error: null,
		});
		const transitionBuilder = makeBuilder("meetups", { data: null, error: null }, fake);
		fake.client.from = vi.fn((table: string) => {
			fake.fromCalls.push(table);
			return transitionBuilder;
		});

		const result = await createMeetupIntent(asClient(fake), USER_A, MATCH_ID);

		expect(result).toEqual({ ok: true, transition: null });
		expect(fake.updates).toHaveLength(1);
	});

	it.each([
		["blocked", intentRow({ meetup_id: null, outcome: "blocked", status: null, initiator_id: null, matched: false })],
		["missing", intentRow({ meetup_id: null, outcome: "not_found", status: null, initiator_id: null, matched: false })],
	])("collapses %s RPC outcomes to the accepted result", async (_name, row) => {
		const fake = makeDatabase();
		fake.rpc.mockResolvedValue({ data: [row], error: null });

		expect(await createMeetupIntent(asClient(fake), USER_A, MATCH_ID)).toEqual({ ok: true, transition: null });
		expect(fake.fromCalls).toEqual([]);
	});

	it("collapses an already-active pending state without disclosing the counterpart", async () => {
		const fake = makeDatabase();
		fake.rpc.mockResolvedValue({
			data: [intentRow({ outcome: "already_active", status: "intent_pending", matched: false })],
			error: null,
		});

		expect(await createMeetupIntent(asClient(fake), USER_A, MATCH_ID)).toEqual({ ok: true, transition: null });
		expect(fake.fromCalls).toEqual([]);
	});

	it("returns a fixed internal failure for an RPC error", async () => {
		const fake = makeDatabase();
		fake.rpc.mockResolvedValue({ data: null, error: { code: "PGRST000" } });

		expect(await createMeetupIntent(asClient(fake), USER_A, MATCH_ID)).toEqual({ ok: false, reason: "internal" });
	});

	it.each([
		intentRow({ outcome: "blocked", status: "intent_pending" }),
		intentRow({ outcome: "not_found", status: "intent_pending" }),
	])("rejects a malformed safe RPC outcome instead of guessing its relationship", async (row) => {
		const fake = makeDatabase();
		fake.rpc.mockResolvedValue({ data: [row], error: null });

		expect(await createMeetupIntent(asClient(fake), USER_A, MATCH_ID)).toEqual({ ok: false, reason: "internal" });
	});

	it("rejects an RPC result unless it is exactly one valid RETURNS TABLE row", async () => {
		for (const data of [[], [intentRow(), intentRow()], [{ ...intentRow(), extra: "leak" }]]) {
			const fake = makeDatabase();
			fake.rpc.mockResolvedValue({ data, error: null });
			expect(await createMeetupIntent(asClient(fake), USER_A, MATCH_ID)).toEqual({ ok: false, reason: "internal" });
		}
	});
});

describe("meetupPreferencesSchema", () => {
	it.each([
		["missing required field", { ...validPreferences, availability: undefined }],
		["too many availability entries", { ...validPreferences, availability: Array.from({ length: 33 }, () => validPreferences.availability[0]) }],
		["non-offset timestamp", { ...validPreferences, availability: [{ starts_at: "2026-09-10T10:00:00", ends_at: "2026-09-10T12:00:00Z" }] }],
		["reversed interval", { ...validPreferences, availability: [{ starts_at: "2026-09-10T12:00:00Z", ends_at: "2026-09-10T10:00:00Z" }] }],
		["duplicate interval", { ...validPreferences, availability: [...validPreferences.availability, ...validPreferences.availability] }],
		["extra availability field", { ...validPreferences, availability: [{ ...validPreferences.availability[0], note: "x" }] }],
		["too many areas", { ...validPreferences, areas: Array.from({ length: 9 }, (_, index) => `area-${index}`) }],
		["untrimmed area", { ...validPreferences, areas: [" Tokyo"] }],
		["multiline area", { ...validPreferences, areas: ["Tokyo\nChiyoda"] }],
		["duplicate area", { ...validPreferences, areas: ["Tokyo", "Tokyo"] }],
		["invalid budget", { ...validPreferences, budget_band: "enterprise" }],
		["too many formats", { ...validPreferences, formats: ["cafe", "meal", "activity", "online", "cafe"] }],
		["invalid format", { ...validPreferences, formats: ["bar"] }],
		["duplicate format", { ...validPreferences, formats: ["cafe", "cafe"] }],
		["constraints array", { ...validPreferences, constraints: [] }],
		["constraints over UTF-8 bound", { ...validPreferences, constraints: { text: "あ".repeat(700) } }],
		["unknown top-level field", { ...validPreferences, meetup_id: MEETUP_ID }],
	])("rejects %s", (_name, payload) => {
		expect(meetupPreferencesSchema.safeParse(payload).success).toBe(false);
	});

	it("accepts a bounded, closed preference object", () => {
		expect(meetupPreferencesSchema.safeParse(validPreferences).success).toBe(true);
	});
});

describe("saveMeetupPreferences", () => {
	it("never writes when the preference DTO is invalid", async () => {
		const fake = makeDatabase();
		const result = await saveMeetupPreferences(asClient(fake), USER_A, MEETUP_ID, {
			...validPreferences,
			formats: ["unknown"],
		});
		expect(result).toEqual({ ok: false, reason: "bad_request" });
		expect(fake.upserts).toHaveLength(0);
	});

	it("upserts only the caller profile's preferences", async () => {
		const fake = makeDatabase({ preferencesWrite: { data: { user_id: USER_A }, error: null } });
		const result = await saveMeetupPreferences(asClient(fake), USER_A, MEETUP_ID, validPreferences);

		expect(result).toEqual({ ok: true });
		expect(fake.upserts).toEqual([
		{
			values: { ...validPreferences, user_id: USER_A },
			options: { onConflict: "user_id" },
		},
	]);
	});

	it("returns invalid_state for an owned terminal meetup and does not write", async () => {
		const fake = makeDatabase({ meetup: validMeetup({ status: "expired" }) });
		const result = await saveMeetupPreferences(asClient(fake), USER_A, MEETUP_ID, validPreferences);

		expect(result).toEqual({ ok: false, reason: "invalid_state" });
		expect(fake.upserts).toHaveLength(0);
	});

	it.each([
		["nonparticipant", validMatch({ user_a_id: USER_B, user_b_id: "10000000-0000-0000-0000-000000000003" })],
		["inactive match", validMatch({ status: "pending" })],
	])("does not write for %s", async (_name, match) => {
		const fake = makeDatabase({ match });
		const result = await saveMeetupPreferences(asClient(fake), USER_A, MEETUP_ID, validPreferences);
		expect(result).toEqual({ ok: false, reason: "not_found" });
		expect(fake.upserts).toHaveLength(0);
	});

	it("does not write when the pair is unverified or blocked", async () => {
		const unverified = makeDatabase();
		vi.mocked(checkVerifiedPair).mockResolvedValueOnce({ ok: false, reason: "unverified" });
		expect(await saveMeetupPreferences(asClient(unverified), USER_A, MEETUP_ID, validPreferences)).toEqual({ ok: false, reason: "not_found" });

		const blocked = makeDatabase({ block: { id: "60000000-0000-0000-0000-000000000001" } });
		expect(await saveMeetupPreferences(asClient(blocked), USER_A, MEETUP_ID, validPreferences)).toEqual({ ok: false, reason: "not_found" });
		expect(unverified.upserts).toHaveLength(0);
		expect(blocked.upserts).toHaveLength(0);
	});
});

describe("getMeetupDetail", () => {
	it("returns only the contract DTO fields and strips stored candidate extras", async () => {
		const fake = makeDatabase({
			meetup: validMeetup({ status: "proposed", proposal_expires_at: "2026-09-12T00:00:00Z", private_note: "do not expose" }),
			proposal: {
				id: PROPOSAL_ID,
				expires_at: "2026-09-12T00:00:00Z",
				candidates: [
					{ starts_at: "2026-09-08T10:00:00Z", timezone: "UTC", area: "Tokyo/Chiyoda", format: "cafe", rationale: "A quiet option", private_note: "hidden" },
					{ starts_at: "2026-09-09T10:00:00Z", timezone: "UTC", area: "Tokyo/Chiyoda", format: "meal", rationale: "A public option", private_note: "hidden" },
					{ starts_at: "2026-09-10T10:00:00Z", timezone: "UTC", area: "Tokyo/Chiyoda", format: "online", rationale: "A flexible option", private_note: "hidden" },
				],
			},
		});

		const result = await getMeetupDetail(asClient(fake), USER_A, MEETUP_ID);

		expect(result.ok).toBe(true);
		if (result.ok === false) return;
		expect(result.data).toEqual({
			id: MEETUP_ID,
			match_id: MATCH_ID,
			status: "proposed",
			proposal: {
				id: PROPOSAL_ID,
				expires_at: "2026-09-12T00:00:00Z",
				candidates: [
					{ starts_at: "2026-09-08T10:00:00Z", timezone: "UTC", area: "Tokyo/Chiyoda", format: "cafe", rationale: "A quiet option" },
					{ starts_at: "2026-09-09T10:00:00Z", timezone: "UTC", area: "Tokyo/Chiyoda", format: "meal", rationale: "A public option" },
					{ starts_at: "2026-09-10T10:00:00Z", timezone: "UTC", area: "Tokyo/Chiyoda", format: "online", rationale: "A flexible option" },
				],
			},
			confirmed_candidate: null,
			expires_at: "2026-09-12T00:00:00Z",
		});
	});

	it("shows a pending meetup only to its initiator", async () => {
		const fake = makeDatabase({ meetup: validMeetup({ status: "intent_pending", initiator_id: USER_A, intent_expires_at: "2026-09-12T00:00:00Z" }) });
		expect((await getMeetupDetail(asClient(fake), USER_A, MEETUP_ID)).ok).toBe(true);
		expect(await getMeetupDetail(asClient(makeDatabase({ meetup: validMeetup({ status: "intent_pending", initiator_id: USER_A }) })), USER_B, MEETUP_ID)).toEqual({ ok: false, reason: "not_found" });
	});

	it("returns fixed internal failure for malformed stored candidates or confirmed fields", async () => {
		const malformedCandidates = makeDatabase({
			meetup: validMeetup({ status: "proposed" }),
			proposal: { id: PROPOSAL_ID, expires_at: null, candidates: [{ starts_at: "2026-09-08T10:00:00Z" }] },
		});
		expect(await getMeetupDetail(asClient(malformedCandidates), USER_A, MEETUP_ID)).toEqual({ ok: false, reason: "internal" });

		const malformedConfirmed = makeDatabase({
			meetup: validMeetup({ status: "confirmed", confirmed_start_at: "2026-09-08T10:00:00Z" }),
		});
		expect(await getMeetupDetail(asClient(malformedConfirmed), USER_A, MEETUP_ID)).toEqual({ ok: false, reason: "internal" });
	});
});

describe("getMeetupDetailByMatch", () => {
	it("returns the authorized current meetup after mutual intent", async () => {
		const fake = makeDatabase();

		expect(await getMeetupDetailByMatch(asClient(fake), USER_A, MATCH_ID)).toEqual({
			ok: true,
			data: {
				id: MEETUP_ID,
				match_id: MATCH_ID,
				status: "verifying",
				proposal: null,
				confirmed_candidate: null,
				expires_at: null,
			},
		});
		expect(fake.ors[0]).toBe("status.eq.verifying,status.eq.arranging,status.eq.proposed,status.eq.confirmed,status.eq.arrange_failed");
	});

	it("hides a one-sided pending intent from both participants", async () => {
		for (const userID of [USER_A, USER_B]) {
			const fake = makeDatabase({
				meetup: validMeetup({ status: "intent_pending", initiator_id: USER_A }),
				// The database status filter should make a pending row look absent.
				meetupLookup: null,
			});

			expect(await getMeetupDetailByMatch(asClient(fake), userID, MATCH_ID)).toEqual({ ok: false, reason: "not_found" });
			expect(fake.ors[0]).not.toContain("intent_pending");
		}
	});

	it.each([
		[
			"nonparticipant",
			{ match: validMatch({ user_a_id: USER_B, user_b_id: "10000000-0000-0000-0000-000000000003" }) },
		],
		[
			"blocked pair",
			{ block: { id: "60000000-0000-0000-0000-000000000001" } },
		],
	] as const)("keeps %s indistinguishable from an absent meetup", async (_name, options) => {
		const fake = makeDatabase(options);

		expect(await getMeetupDetailByMatch(asClient(fake), USER_A, MATCH_ID)).toEqual({ ok: false, reason: "not_found" });
	});
});
