import { createClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
	PARTNER_FOX_ALLOWED_MATCH_STATUSES,
	checkPartnerFoxChatAccess,
	checkPartnerFoxChatStartAccess,
} from "./partner-fox-chat-access";

const MATCH_ID = "match-1";
const CHAT_ID = "chat-1";
const USER_A = "user-a";
const USER_B = "user-b";

afterEach(() => {
	vi.unstubAllGlobals();
});

type Trace = { table: string; selects: string[]; filters: [string, unknown][]; singleCalls: number };

const baseProfile = (id: string, overrides: Record<string, unknown> = {}) => ({
	id,
	age_verified_at: "2026-08-24T00:00:00Z",
	gender_identity: "woman",
	preferred_genders: ["woman"],
	preference_mode: "selected",
	dating_market: "JP",
	onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
	blocks_sent: [],
	...overrides,
});

type FixtureOptions = {
	status?: string;
	profileA?: Record<string, unknown> | null;
	profileB?: Record<string, unknown> | null;
	conversation?: unknown;
	room?: unknown;
	currentData?: unknown;
	currentError?: unknown;
	identityData?: unknown;
	identityError?: unknown;
	startData?: unknown;
	startError?: unknown;
};

function fixture(options: FixtureOptions = {}) {
	const status = options.status ?? "partner_chat_started";
	const profiles = {
		profile_a: options.profileA === undefined ? baseProfile(USER_A) : options.profileA,
		profile_b: options.profileB === undefined ? baseProfile(USER_B) : options.profileB,
	};
	const conversation = options.conversation === undefined
		? [{ id: "fox-compat", match_id: MATCH_ID, purpose: "compatibility", status: "completed" }]
		: options.conversation;
	const match = {
		id: MATCH_ID,
		user_a_id: USER_A,
		user_b_id: USER_B,
		status,
		...profiles,
		fox_conversation: conversation,
		direct_room: options.room === undefined ? null : options.room,
	};
	const current = options.currentData === undefined
		? { id: CHAT_ID, match_id: MATCH_ID, user_id: USER_A, partner_user_id: USER_B, match }
		: options.currentData;
	const start = options.startData === undefined ? match : options.startData;
	const traces: Trace[] = [];

	const from = (table: string) => {
		let selection = "";
		const trace: Trace = { table, selects: [], filters: [], singleCalls: 0 };
		traces.push(trace);
		const query: Record<string, unknown> = {};
		query.select = (value: unknown) => {
			selection = String(value);
			trace.selects.push(selection);
			return query;
		};
		query.eq = (column: unknown, value: unknown) => {
			trace.filters.push([String(column), value]);
			return query;
		};
		query.single = async () => {
			trace.singleCalls += 1;
			if (table === "partner_fox_chats") return { data: filterEmbedded(current, trace.filters), error: options.currentError ?? null };
			if (selection === "id,user_a_id,user_b_id,status") return { data: options.identityData ?? { id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status }, error: options.identityError ?? null };
			return { data: filterEmbedded(start, trace.filters), error: options.startError ?? null };
		};
		return query;
	};

	return { from, traces, match };
}

function filterEmbedded(value: unknown, filters: [string, unknown][]): unknown {
	if (!value || typeof value !== "object" || Array.isArray(value)) return value;
	const row = value as Record<string, unknown>;
	if (Array.isArray(row.match)) return row;
	const match = row.match && typeof row.match === "object" && !Array.isArray(row.match) ? row.match as Record<string, unknown> : row;
	const profileAFilter = filters.find(([column]) => column === "match.profile_a.blocks_sent.blocked_id" || column === "profile_a.blocks_sent.blocked_id")?.[1];
	const profileBFilter = filters.find(([column]) => column === "match.profile_b.blocks_sent.blocked_id" || column === "profile_b.blocks_sent.blocked_id")?.[1];
	const purposeFilter = filters.find(([column]) => column === "match.fox_conversation.purpose" || column === "fox_conversation.purpose")?.[1];
	const filteredMatch = { ...match };
	for (const [profileKey, blockedId] of [["profile_a", profileAFilter], ["profile_b", profileBFilter]] as const) {
		const profile = filteredMatch[profileKey];
		if (!profile || typeof profile !== "object" || Array.isArray(profile) || blockedId === undefined) continue;
		const profileRecord = profile as Record<string, unknown>;
		if (Array.isArray(profileRecord.blocks_sent)) {
			filteredMatch[profileKey] = {
				...profileRecord,
				blocks_sent: profileRecord.blocks_sent.filter((block) =>
					block && typeof block === "object" && !Array.isArray(block) && (block as Record<string, unknown>).blocked_id === blockedId,
				),
			};
		}
	}
	if (purposeFilter !== undefined && Array.isArray(filteredMatch.fox_conversation)) {
		filteredMatch.fox_conversation = filteredMatch.fox_conversation.filter((conversation) =>
			conversation && typeof conversation === "object" && !Array.isArray(conversation) && (conversation as Record<string, unknown>).purpose === purposeFilter,
		);
	}
	return row.match ? { ...row, match: filteredMatch } : filteredMatch;
}

function accessExpectation(userId = USER_A, partnerUserId = USER_B) {
	return { chatId: CHAT_ID, matchId: MATCH_ID, userId, partnerUserId };
}

	describe("partner-Fox current access", () => {
	it("accepts either ordered participant as the caller and uses one filtered snapshot", async () => {
		// The same match can be represented by a chat owned by either side; the
		// match snapshot remains ordered even when the caller is B.
		const first = fixture();
		await expect(checkPartnerFoxChatAccess(first as never, accessExpectation())).resolves.toEqual({
			ok: true,
			matchStatus: "partner_chat_started",
			partnerUserId: USER_B,
		});
		const reverse = fixture({ currentData: { id: CHAT_ID, match_id: MATCH_ID, user_id: USER_B, partner_user_id: USER_A, match: fixture().match } });
		await expect(checkPartnerFoxChatAccess(reverse as never, accessExpectation(USER_B, USER_A))).resolves.toEqual({
			ok: true,
			matchStatus: "partner_chat_started",
			partnerUserId: USER_A,
		});
		expect(first.traces).toHaveLength(1);
		expect(reverse.traces).toHaveLength(1);
		expect(first.traces[0].filters).toEqual([
			["id", CHAT_ID],
			["match_id", MATCH_ID],
			["user_id", USER_A],
			["partner_user_id", USER_B],
			["match.fox_conversation.purpose", "compatibility"],
			["match.profile_a.blocks_sent.blocked_id", USER_B],
			["match.profile_b.blocks_sent.blocked_id", USER_A],
		]);
		expect(reverse.traces[0].filters.slice(-2)).toEqual([
			["match.profile_a.blocks_sent.blocked_id", USER_B],
			["match.profile_b.blocks_sent.blocked_id", USER_A],
		]);
		expect(first.traces[0].selects[0]).not.toContain("*");
	});

	it("serializes the ordered block and compatibility filters through Supabase JS", async () => {
		const base = fixture();
		const responseRow = {
			id: CHAT_ID,
			match_id: MATCH_ID,
			user_id: USER_B,
			partner_user_id: USER_A,
			match: base.match,
		};
		let requestUrl = "";
		vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
			requestUrl = String(input);
			return new Response(JSON.stringify(responseRow), {
				status: 200,
				headers: { "Content-Type": "application/json" },
			});
		});
		const supabase = createClient("https://supabase.test", "anon-key", {
			auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
		});
		await expect(checkPartnerFoxChatAccess(supabase as never, accessExpectation(USER_B, USER_A))).resolves.toMatchObject({ ok: true, partnerUserId: USER_A });
		const url = new URL(requestUrl);
		expect(url.searchParams.get("id")).toBe(`eq.${CHAT_ID}`);
		expect(url.searchParams.get("match_id")).toBe(`eq.${MATCH_ID}`);
		expect(url.searchParams.get("user_id")).toBe(`eq.${USER_B}`);
		expect(url.searchParams.get("partner_user_id")).toBe(`eq.${USER_A}`);
		expect(url.searchParams.get("match.profile_a.blocks_sent.blocked_id")).toBe(`eq.${USER_B}`);
		expect(url.searchParams.get("match.profile_b.blocks_sent.blocked_id")).toBe(`eq.${USER_A}`);
		expect(url.searchParams.get("match.fox_conversation.purpose")).toBe("eq.compatibility");
		expect(url.searchParams.get("select")).toContain("fox_conversation:fox_conversations");
	});

	it.each([
		["A blocks B", { profileA: baseProfile(USER_A, { blocks_sent: [{ id: "ab", blocker_id: USER_A, blocked_id: USER_B }] }) }],
		["B blocks A", { profileB: baseProfile(USER_B, { blocks_sent: [{ id: "ba", blocker_id: USER_B, blocked_id: USER_A }] }) }],
	])("denies %s even when the opposite side cannot see that block", async (_label, options) => {
		const callerA = fixture(options);
		await expect(checkPartnerFoxChatAccess(callerA as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "forbidden" });
		const callerBFixture = fixture(options);
		const callerB = fixture({
			...options,
			currentData: { id: CHAT_ID, match_id: MATCH_ID, user_id: USER_B, partner_user_id: USER_A, match: callerBFixture.match },
		});
		await expect(checkPartnerFoxChatAccess(callerB as never, accessExpectation(USER_B, USER_A))).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it("filters unrelated blocks before validation and preserves the unblocked positive", async () => {
		const supabase = fixture({
			profileA: baseProfile(USER_A, { blocks_sent: [{ id: "other", blocker_id: USER_A, blocked_id: "unrelated" }] }),
			profileB: baseProfile(USER_B, { blocks_sent: [{ id: "other-2", blocker_id: USER_B, blocked_id: "unrelated" }] }),
		});
		await expect(checkPartnerFoxChatAccess(supabase as never, accessExpectation())).resolves.toMatchObject({ ok: true });
	});

	it.each(["pending", "in_progress", "failed", "unknown"])("rejects disallowed match status %s", async (status) => {
		await expect(checkPartnerFoxChatAccess(fixture({ status }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it.each(PARTNER_FOX_ALLOWED_MATCH_STATUSES)("accepts allowed contact status %s when room requirements hold", async (status) => {
		const room = ["direct_chat_active", "meetup_intent", "meetup_confirmed"].includes(status)
			? { id: "room-1", match_id: MATCH_ID, status: "active" }
			: null;
		await expect(checkPartnerFoxChatAccess(fixture({ status, room }) as never, accessExpectation())).resolves.toMatchObject({ ok: true, matchStatus: status });
	});

	it("requires an active room for direct contact states and rejects a closed room after unblock", async () => {
		await expect(checkPartnerFoxChatAccess(fixture({ status: "direct_chat_active" }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(checkPartnerFoxChatAccess(fixture({ room: { id: "room-1", match_id: MATCH_ID, status: "closed" } }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it.each([
		["market", { dating_market: "US" }],
		["age", { age_verified_at: null }],
		["completion", { onboarding_settings_completed_at: null }],
		["preference", { preferred_genders: ["man"] }],
	])("rejects a current %s change", async (_label, fields) => {
		await expect(checkPartnerFoxChatAccess(fixture({ profileB: baseProfile(USER_B, fields) }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it("requires an exact completed compatibility conversation and fails closed on malformed relationships", async () => {
		await expect(checkPartnerFoxChatAccess(fixture({ conversation: [{ id: "scheduling", match_id: MATCH_ID, purpose: "scheduling", status: "completed" }] }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(checkPartnerFoxChatAccess(fixture({ conversation: [{ id: "fox-compat", match_id: MATCH_ID, purpose: "compatibility", status: "completed" }, { id: "duplicate", match_id: MATCH_ID, purpose: "compatibility", status: "completed" }] }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(checkPartnerFoxChatAccess(fixture({ profileA: null }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "error" });
		await expect(checkPartnerFoxChatAccess(fixture({ currentData: { id: CHAT_ID, match_id: MATCH_ID, user_id: USER_A, partner_user_id: USER_B, match: [] } }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "error" });
	});

	it("fails closed for missing, authless, reassigned, and database-error inputs", async () => {
		await expect(checkPartnerFoxChatAccess(fixture({ currentData: null }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "error" });
		await expect(checkPartnerFoxChatAccess(fixture() as never, { ...accessExpectation(), userId: "" })).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(checkPartnerFoxChatAccess(fixture() as never, accessExpectation("outsider", USER_B))).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(checkPartnerFoxChatAccess(fixture({ currentData: { id: "other", match_id: MATCH_ID, user_id: USER_A, partner_user_id: USER_B, match: {} } }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(checkPartnerFoxChatAccess(fixture({ currentError: { code: "PGRST116" } }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "not_found" });
		await expect(checkPartnerFoxChatAccess(fixture({ currentError: { message: "db unavailable" } }) as never, accessExpectation())).resolves.toEqual({ ok: false, reason: "error" });
	});
});

describe("partner-Fox chat start access", () => {
	it("returns immutable ordered IDs and accepts the later allowed states", async () => {
		for (const status of PARTNER_FOX_ALLOWED_MATCH_STATUSES) {
			const room = ["direct_chat_active", "meetup_intent", "meetup_confirmed"].includes(status)
				? { id: "room-1", match_id: MATCH_ID, status: "active" }
				: null;
			const result = await checkPartnerFoxChatStartAccess(fixture({ status, room }) as never, { matchId: MATCH_ID, userId: USER_B });
			expect(result).toEqual({ ok: true, matchStatus: status, userAId: USER_A, userBId: USER_B, partnerUserId: USER_A });
		}
	});

	it("requires the completed compatibility conversation and filters both block directions", async () => {
		await expect(checkPartnerFoxChatStartAccess(fixture({ status: "fox_conversation_completed", profileA: baseProfile(USER_A, { blocks_sent: [{ id: "ab", blocker_id: USER_A, blocked_id: USER_B }] }) }) as never, { matchId: MATCH_ID, userId: USER_B })).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(checkPartnerFoxChatStartAccess(fixture({ status: "fox_conversation_completed", profileB: baseProfile(USER_B, { blocks_sent: [{ id: "ba", blocker_id: USER_B, blocked_id: USER_A }] }) }) as never, { matchId: MATCH_ID, userId: USER_A })).resolves.toEqual({ ok: false, reason: "forbidden" });
		const supabase = fixture({ status: "fox_conversation_completed" });
		await expect(checkPartnerFoxChatStartAccess(supabase as never, { matchId: MATCH_ID, userId: USER_A })).resolves.toMatchObject({ ok: true, partnerUserId: USER_B });
		expect(supabase.traces).toHaveLength(2);
		expect(supabase.traces[1].filters).toContainEqual(["user_a_id", USER_A]);
		expect(supabase.traces[1].filters).toContainEqual(["user_b_id", USER_B]);
		expect(supabase.traces[1].filters).toContainEqual(["fox_conversation.purpose", "compatibility"]);
	});

	it.each(["pending", "in_progress", "failed", "unknown"])("rejects start from disallowed state %s", async (status) => {
		await expect(checkPartnerFoxChatStartAccess(fixture({ status }) as never, { matchId: MATCH_ID, userId: USER_A })).resolves.toEqual({ ok: false, reason: "forbidden" });
	});

	it("maps a missing start match and malformed identity to safe failures", async () => {
		await expect(checkPartnerFoxChatStartAccess(fixture({ identityError: { code: "PGRST116" } }) as never, { matchId: MATCH_ID, userId: USER_A })).resolves.toEqual({ ok: false, reason: "not_ready" });
		await expect(checkPartnerFoxChatStartAccess(fixture({ identityData: { id: MATCH_ID, user_a_id: USER_B, user_b_id: USER_A, status: "fox_conversation_completed" } }) as never, { matchId: MATCH_ID, userId: USER_A })).resolves.toEqual({ ok: false, reason: "forbidden" });
		await expect(checkPartnerFoxChatStartAccess(fixture() as never, { matchId: "", userId: USER_A })).resolves.toEqual({ ok: false, reason: "forbidden" });
	});
});
