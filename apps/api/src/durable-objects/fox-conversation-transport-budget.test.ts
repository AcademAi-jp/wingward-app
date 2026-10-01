import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * This file measures the production DO alarm with the real Supabase JS
 * client. Only the transport is synthetic: every request goes through a
 * deterministic fetch adapter that models the tables the engine reads and
 * writes. The adapter counts dispatched HTTP requests, while the Mistral
 * mock is counted separately. This is a Node simulation of transport volume,
 * not Cloudflare's runtime enforcement of the 50-subrequest limit.
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
	chatCompleteOnceBounded: vi.fn(),
	MISTRAL_LIGHT: "ministral-8b-2512",
}));

import { chatCompleteWithUsage, chatCompleteOnceBounded } from "../services/mistral";
import { checkFoxConversationCurrentAccess } from "../services/fox-conversation-access";
import { FoxConversationDO } from "./fox-conversation-do";
import { createClient } from "@supabase/supabase-js";

const SUPABASE_URL = "https://synthetic.supabase.invalid";
const SUPABASE_SERVICE_ROLE_KEY = "synthetic-service-role-key";
const CONVERSATION_ID = "11111111-1111-4111-8111-111111111111";
const MATCH_ID = "22222222-2222-4222-8222-222222222222";
const USER_A = "33333333-3333-4333-8333-333333333333";
const USER_B = "44444444-4444-4444-8444-444444444444";
const ONESIGNAL_API_ORIGIN = "https://api.onesignal.com";
const SYNTHETIC_ONESIGNAL_APP_ID = "synthetic-onesignal-app";
const SYNTHETIC_ONESIGNAL_API_KEY = "synthetic-onesignal-key";

type ConversationStatus = "in_progress" | "completed";

type SyntheticMessage = {
	speaker_user_id: string;
	content: string;
	round_number: number;
};

type InvocationLedger = {
	requests: number;
	byTable: Record<string, number>;
};

type SyntheticFeatureRow = Record<string, unknown>;

type SyntheticMatchScore = {
	profile_score: number;
	score_details: Record<string, unknown>;
};

type AdapterOptions = {
	totalRounds: number;
	registeredJudge?: boolean;
	initialMessages?: SyntheticMessage[];
	checkpointFailures?: number;
	initialInputTokens?: number | null;
	initialOutputTokens?: number | null;
	initialCacheHitTokens?: number | null;
	profileRows?: Array<Record<string, unknown>>;
	matchScore?: SyntheticMatchScore;
	featureRows?: SyntheticFeatureRow[];
	interactionWriteError?: boolean;
	interactionReadError?: boolean;
	personaMissingUserId?: string;
	oneSignalFailure?: boolean;
};

type SyntheticBlock = {
	id: string;
	blocker_id: string;
	blocked_id: string;
};

type SyntheticState = {
	conversationStatus: ConversationStatus;
	matchStatus: "fox_conversation_in_progress" | "fox_conversation_completed";
	currentRound: number;
	inputTokens: number | null;
	outputTokens: number | null;
	cacheHitTokens: number | null;
	accessProfiles: [Record<string, unknown>, Record<string, unknown>];
	blocksFromA: SyntheticBlock[];
	blocksFromB: SyntheticBlock[];
};

type SupabaseFetchAdapter = {
	fetch: typeof globalThis.fetch;
	beginInvocation: () => void;
	invocations: InvocationLedger[];
	errors: string[];
	state: SyntheticState;
	messages: SyntheticMessage[];
	featureRows: SyntheticFeatureRow[];
	featureUpserts: Array<{ rows: SyntheticFeatureRow[]; onConflict: string }>;
	matchUpdates: Array<Record<string, unknown>>;
	notifications: Array<Record<string, unknown>>;
	notificationEvents: Array<Record<string, unknown>>;
	oneSignalRequests: Array<{ body: Record<string, unknown>; status: number }>;
	profileLookupRequests: () => number;
	featureLoadRequests: () => number;
	matchScoreLookups: () => number;
	checkpointAttempts: () => number;
	currentAccessRequests: () => number;
};

function jsonResponse(data: unknown, status = 200): Response {
	return new Response(JSON.stringify(data), {
		status,
		headers: { "content-type": "application/json" },
	});
}

function emptyResponse(status = 204): Response {
	return new Response(null, { status });
}

// The N-01 notification path reached from FoxConversationDO only PATCHes
// these columns. Keep the synthetic table closed to arbitrary request fields
// while retaining the row object's in-place mutation semantics.
const SYNTHETIC_NOTIFICATION_PATCH_FIELDS = new Set([
	"scheduled_for",
	"payload",
	"suppressed_reason",
	"onesignal_notification_id",
	"sent_at",
]);

function applySyntheticNotificationPatch(
	row: Record<string, unknown>,
	body: unknown,
	reject: (message: string) => Error,
): void {
	if (typeof body !== "object" || body === null || Array.isArray(body)) {
		throw reject("synthetic notifications update body mismatch");
	}

	const patch = body as Record<string, unknown>;
	const has = (field: string): boolean => Object.prototype.hasOwnProperty.call(patch, field);
	for (const key of Object.keys(patch)) {
		if (!SYNTHETIC_NOTIFICATION_PATCH_FIELDS.has(key)) {
			throw reject(`synthetic notifications update field mismatch: ${key}`);
		}
	}

	if (has("scheduled_for") && typeof patch.scheduled_for !== "string") {
		throw reject("synthetic notifications scheduled_for update mismatch");
	}
	if (has("payload") && (typeof patch.payload !== "object" || patch.payload === null || Array.isArray(patch.payload))) {
		throw reject("synthetic notifications payload update mismatch");
	}
	if (has("suppressed_reason") && typeof patch.suppressed_reason !== "string") {
		throw reject("synthetic notifications suppressed_reason update mismatch");
	}
	if (has("onesignal_notification_id") && typeof patch.onesignal_notification_id !== "string") {
		throw reject("synthetic notifications onesignal_notification_id update mismatch");
	}
	if (has("sent_at") && typeof patch.sent_at !== "string") {
		throw reject("synthetic notifications sent_at update mismatch");
	}

	// Validate every field before mutating the fixture, then assign each
	// allowlisted field explicitly so the adapter cannot widen its schema.
	if (has("scheduled_for")) row.scheduled_for = patch.scheduled_for;
	if (has("payload")) row.payload = patch.payload;
	if (has("suppressed_reason")) row.suppressed_reason = patch.suppressed_reason;
	if (has("onesignal_notification_id")) row.onesignal_notification_id = patch.onesignal_notification_id;
	if (has("sent_at")) row.sent_at = patch.sent_at;
}

function eqFilter(url: URL, column: string): string | null {
	const value = url.searchParams.get(column);
	return value?.startsWith("eq.") ? value.slice(3) : null;
}

function gteFilter(url: URL, column: string): string | null {
	const value = url.searchParams.get(column);
	return value?.startsWith("gte.") ? value.slice(4) : null;
}

function inFilter(url: URL, column: string): string[] | null {
	const value = url.searchParams.get(column);
	if (!value?.startsWith("in.(") || !value.endsWith(")")) return null;
	return value.slice(4, -1).split(",").map((entry) => entry.replace(/^"|"$/g, ""));
}

function hasSelectedRepresentation(request: Request, url: URL): boolean {
	return url.searchParams.has("select") || request.headers.get("prefer")?.includes("return=representation") === true;
}

function isSingleRequest(request: Request): boolean {
	return request.headers.get("accept")?.includes("application/vnd.pgrst.object+json") === true;
}

function makeAccessProfiles(): [Record<string, unknown>, Record<string, unknown>] {
	return [
		{
			id: USER_A,
			age_verified_at: "2026-09-06T00:00:00Z",
			gender_identity: "woman",
			preferred_genders: ["man"],
			preference_mode: "selected",
			dating_market: "JP",
			onboarding_settings_completed_at: "2026-09-06T00:00:00Z",
		},
		{
			id: USER_B,
			age_verified_at: "2026-09-06T00:00:00Z",
			gender_identity: "man",
			preferred_genders: ["woman"],
			preference_mode: "selected",
			dating_market: "JP",
			onboarding_settings_completed_at: "2026-09-06T00:00:00Z",
		},
	];
}

function makeGenderLanguageProfiles() {
	return [
		{ id: USER_A, gender: "female", language: "ja" },
		{ id: USER_B, gender: "male", language: "ja" },
	];
}

function makeConfirmedScoringProfile(userId: string) {
	const timestamp = "2026-09-06T00:00:00Z";
	return {
		id: userId,
		user_id: userId,
		basic_info: { location: "Tokyo" },
		personality_tags: ["calm"],
		personality_analysis: {
			introvert_extrovert: 0.5,
			planned_spontaneous: 0.5,
			logical_emotional: 0.5,
		},
		interaction_style: {
			warmup_speed: 0.5,
			humor_responsiveness: 0.5,
			self_disclosure_depth: 0.5,
			emotional_responsiveness: 0.5,
			conflict_style: "dialogue",
			attachment_tendency: "secure",
			rhythm_preference: "moderate",
			mirroring_tendency: 0.5,
		},
		interests: [{ category: "music", items: ["jazz"] }],
		values: { work_life_balance: 0.5, experience_vs_material: 0.5 },
		romance_style: {},
		communication_style: {},
		lifestyle: {},
		status: "confirmed",
		version: 1,
		confirmed_at: timestamp,
		created_at: timestamp,
		updated_at: timestamp,
	};
}

function makeConfirmedScoringProfiles() {
	return [makeConfirmedScoringProfile(USER_A), makeConfirmedScoringProfile(USER_B)];
}

const CURRENT_ACCESS_SELECT = [
	"id",
	"match_id",
	"status",
	`match:matches!fox_conversations_match_id_fkey!inner(id,user_a_id,user_b_id,status,profile_a:user_profiles!matches_user_a_id_fkey!inner(id,age_verified_at,gender_identity,preferred_genders,preference_mode,dating_market,onboarding_settings_completed_at,blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)),profile_b:user_profiles!matches_user_b_id_fkey!inner(id,age_verified_at,gender_identity,preferred_genders,preference_mode,dating_market,onboarding_settings_completed_at,blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)))`,
].join(",");

const FINAL_NOTIFICATION_SELECT = [
	"id,scenario_id,user_id,match_id,meetup_id,payload,scheduled_for,sent_at,suppressed_reason,onesignal_notification_id",
	"scenario:notification_scenarios!notifications_scenario_id_fkey!inner(scenario_id,is_enabled)",
	"match:matches!notifications_match_id_fkey(id,user_a_id,user_b_id,status,profile_a:user_profiles!matches_user_a_id_fkey!inner(id,age_verified_at,gender_identity,preferred_genders,preference_mode,dating_market,onboarding_settings_completed_at,blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)),profile_b:user_profiles!matches_user_b_id_fkey!inner(id,age_verified_at,gender_identity,preferred_genders,preference_mode,dating_market,onboarding_settings_completed_at,blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)),compatibility_conversations:fox_conversations!fox_conversations_match_id_fkey(id,match_id,purpose,status),chat_requests:chat_requests!chat_requests_match_id_fkey(id,match_id,requester_id,responder_id,status,expires_at),direct_room:direct_chat_rooms!direct_chat_rooms_match_id_fkey(id,match_id,status))",
	"meetup:meetups!notifications_meetup_id_fkey(id,match_id,initiator_id,status,proposal_expires_at,proposals:meetup_proposals!meetup_proposals_meetup_id_fkey(id,meetup_id,attempt_number,expires_at))",
].join(",");

function normalizeSelect(value: string): string {
	return value.replace(/\s+/g, "");
}

function makeSupabaseFetchAdapter(options: AdapterOptions): SupabaseFetchAdapter {
	const state: SyntheticState = {
		conversationStatus: "in_progress",
		matchStatus: "fox_conversation_in_progress",
		currentRound: options.initialMessages?.at(-1)?.round_number ?? 0,
		inputTokens: options.initialInputTokens ?? null,
		outputTokens: options.initialOutputTokens ?? null,
		cacheHitTokens: options.initialCacheHitTokens ?? null,
		accessProfiles: makeAccessProfiles(),
		blocksFromA: [],
		blocksFromB: [],
	};
	const messages = [...(options.initialMessages ?? [])];
	const featureRows = [...(options.featureRows ?? [])];
	const featureUpserts: Array<{ rows: SyntheticFeatureRow[]; onConflict: string }> = [];
	const matchUpdates: Array<Record<string, unknown>> = [];
	const notifications: Array<Record<string, unknown>> = [];
	const notificationEvents: Array<Record<string, unknown>> = [];
	const oneSignalRequests: Array<{ body: Record<string, unknown>; status: number }> = [];
	const invocations: InvocationLedger[] = [];
	const errors: string[] = [];
	let currentInvocation = -1;
	let checkpointAttemptsValue = 0;
	let currentAccessRequestsValue = 0;
	let profileLookupRequestsValue = 0;
	let featureLoadRequestsValue = 0;
	let matchScoreLookupsValue = 0;
	let checkpointFailuresRemaining = options.checkpointFailures ?? 0;

	function adapterError(message: string): Error {
		errors.push(message);
		return new Error(message);
	}

	function rejectFixtureRequest(message: string): Response {
		errors.push(message);
		return jsonResponse({ message }, 409);
	}

	function recordRequest(table: string, method: string, url: URL): void {
		if (currentInvocation < 0) throw adapterError("synthetic fetch used before beginInvocation()");
		const ledger = invocations[currentInvocation];
		ledger.requests++;
		ledger.byTable[table] = (ledger.byTable[table] ?? 0) + 1;
		if (method !== "GET" && method !== "PATCH" && method !== "POST") {
			throw adapterError(`synthetic Supabase adapter: unknown method ${method} ${url.pathname}`);
		}
	}

	const fetch: typeof globalThis.fetch = async (input, init) => {
		const request = new Request(input, init);
		const url = new URL(request.url);
		if (url.origin !== SUPABASE_URL && url.origin !== ONESIGNAL_API_ORIGIN) {
			throw adapterError(`synthetic Supabase adapter: unexpected origin ${url.origin}`);
		}

		let body: unknown = null;
		if (request.method !== "GET") {
			const raw = await request.text();
			try {
				body = raw ? JSON.parse(raw) : null;
			} catch {
				throw adapterError(`synthetic adapter: malformed JSON body ${url.origin}${url.pathname}`);
			}
		}

		if (url.origin === ONESIGNAL_API_ORIGIN) {
			if (
				request.method !== "POST" ||
				url.pathname !== "/notifications" ||
				url.search.length > 0 ||
				typeof body !== "object" ||
				body === null ||
				Array.isArray(body) ||
				(request.headers.get("authorization") ?? "") !== `Key ${SYNTHETIC_ONESIGNAL_API_KEY}` ||
				(request.headers.get("content-type") ?? "").toLowerCase() !== "application/json"
			) {
				throw adapterError(`synthetic OneSignal request mismatch: ${request.method} ${url}`);
			}
			const oneSignalBody = body as Record<string, unknown>;
			const aliases = oneSignalBody.include_aliases;
			const data = oneSignalBody.data;
			const externalIds: unknown[] | null =
				typeof aliases === "object" && aliases !== null && Array.isArray((aliases as Record<string, unknown>).external_id)
					? ((aliases as Record<string, unknown>).external_id as unknown[])
					: null;
			if (
				oneSignalBody.app_id !== SYNTHETIC_ONESIGNAL_APP_ID ||
				typeof oneSignalBody.idempotency_key !== "string" ||
				oneSignalBody.target_channel !== "push" ||
				!externalIds ||
				externalIds.length !== 1 ||
				!([USER_A, USER_B] as string[]).includes(externalIds[0] as string) ||
				typeof data !== "object" ||
				data === null ||
				(data as Record<string, unknown>).scenario_id !== "N-01" ||
				(data as Record<string, unknown>).deep_link !== `wingward://match/${MATCH_ID}/fox-result` ||
				typeof (data as Record<string, unknown>).notification_id !== "string"
			) {
				throw adapterError("synthetic OneSignal body mismatch");
			}
			const status = options.oneSignalFailure ? 503 : 200;
			oneSignalRequests.push({ body: { ...oneSignalBody }, status });
			if (options.oneSignalFailure) return jsonResponse({ errors: ["synthetic OneSignal provider failure"] }, status);
			return jsonResponse({ id: `synthetic-onesignal-${oneSignalRequests.length}`, recipients: 1 }, status);
		}
		if (options.registeredJudge && url.pathname.startsWith("/rest/v1/rpc/")) {
			const operation = url.pathname.split("/").at(-1)!;
			recordRequest(operation, request.method, url);
			if (operation === "check_judge_access") return jsonResponse({ outcome: "allowed", actor_user_id: USER_A, counterpart_user_id: USER_B, account_kind: "judge", expires_at: "2026-10-13T19:00:00Z" });
			if (operation === "reserve_judge_provider_operation") return jsonResponse({ outcome: "allowed", reservation_id: "55555555-5555-4555-8555-555555555555", max_units: 20_000, max_seconds: 1 });
			throw adapterError("Unknown judge RPC");
		}
		const match = url.pathname.match(/^\/rest\/v1\/([^/]+)$/);
		if (!match) throw adapterError(`synthetic Supabase adapter: unknown path ${url.pathname}`);
		const table = decodeURIComponent(match[1]);
		recordRequest(table, request.method, url);

		if (table === "fox_conversations") {
			if (request.method === "GET") {
				const idFilter = url.searchParams.get("id");
				if (idFilter !== null && idFilter !== `eq.${CONVERSATION_ID}`) {
					return rejectFixtureRequest(`synthetic fox_conversations GET filter mismatch: ${url.search}`);
				}
				const select = url.searchParams.get("select") ?? "";
				if (select.includes("match:")) {
					const nestedAFilter = eqFilter(url, "match.profile_a.blocks_sent.blocked_id");
					const nestedBFilter = eqFilter(url, "match.profile_b.blocks_sent.blocked_id");
					if (
						normalizeSelect(select) !== normalizeSelect(CURRENT_ACCESS_SELECT) ||
						idFilter !== `eq.${CONVERSATION_ID}` ||
						eqFilter(url, "match_id") !== MATCH_ID ||
						nestedAFilter !== USER_B ||
						nestedBFilter !== USER_A ||
						!isSingleRequest(request)
					) {
						return rejectFixtureRequest(`synthetic current-access embedding mismatch: ${url.search}`);
					}
					currentAccessRequestsValue++;
					const [profileA, profileB] = state.accessProfiles;
					return jsonResponse({
						id: CONVERSATION_ID,
						match_id: MATCH_ID,
						status: state.conversationStatus,
						match: {
							id: MATCH_ID,
							user_a_id: USER_A,
							user_b_id: USER_B,
							status: state.matchStatus,
							profile_a: { ...profileA, blocks_sent: [...state.blocksFromA] },
							profile_b: { ...profileB, blocks_sent: [...state.blocksFromB] },
						},
					});
				}
				const row = {
					id: CONVERSATION_ID,
					match_id: MATCH_ID,
					status: state.conversationStatus,
					total_rounds: options.totalRounds,
					current_round: state.currentRound,
					input_tokens: state.inputTokens,
					output_tokens: state.outputTokens,
					cache_hit_tokens: state.cacheHitTokens,
					purpose: "compatibility",
				};
				return jsonResponse(isSingleRequest(request) ? row : [row]);
			}
			if (request.method !== "PATCH" || typeof body !== "object" || body === null || Array.isArray(body)) {
				throw adapterError(`synthetic Supabase adapter: unsupported fox_conversations request ${request.method}`);
			}
			const update = body as Record<string, unknown>;
			const id = eqFilter(url, "id");
			const matchId = eqFilter(url, "match_id");
			const statuses = inFilter(url, "status");
			if (id !== CONVERSATION_ID || (matchId !== null && matchId !== MATCH_ID) || (statuses && !statuses.includes(state.conversationStatus))) {
				return rejectFixtureRequest(`synthetic fox_conversations filter mismatch: ${url.search}`);
			}
			if (Object.prototype.hasOwnProperty.call(update, "input_tokens")) {
				checkpointAttemptsValue++;
				if (checkpointFailuresRemaining > 0) {
					checkpointFailuresRemaining--;
					return jsonResponse({ message: "synthetic checkpoint failure" }, 500);
				}
			}
			if (typeof update.status === "string") state.conversationStatus = update.status as ConversationStatus;
			if (typeof update.current_round === "number") state.currentRound = update.current_round;
			if (typeof update.input_tokens === "number") state.inputTokens = update.input_tokens;
			if (typeof update.output_tokens === "number") state.outputTokens = update.output_tokens;
			if (typeof update.cache_hit_tokens === "number" || update.cache_hit_tokens === null) {
				state.cacheHitTokens = update.cache_hit_tokens as number | null;
			}
			return hasSelectedRepresentation(request, url) ? jsonResponse({ id: CONVERSATION_ID }) : emptyResponse();
		}

		if (table === "fox_conversation_messages") {
			if (request.method === "GET") {
				const conversationFilter = url.searchParams.get("conversation_id");
				if (conversationFilter !== null && conversationFilter !== `eq.${CONVERSATION_ID}`) {
					return rejectFixtureRequest(`synthetic fox_conversation_messages GET filter mismatch: ${url.search}`);
				}
				return jsonResponse([...messages].sort((a, b) => a.round_number - b.round_number));
			}
			if (request.method !== "POST" || typeof body !== "object" || body === null || Array.isArray(body)) {
				throw adapterError(`synthetic Supabase adapter: unsupported fox_conversation_messages request ${request.method}`);
			}
			const inserted = body as Partial<SyntheticMessage>;
			if (
				typeof inserted.speaker_user_id !== "string" ||
				typeof inserted.content !== "string" ||
				typeof inserted.round_number !== "number"
			) {
				throw adapterError("synthetic Supabase adapter: malformed message insert");
			}
			messages.push({
				speaker_user_id: inserted.speaker_user_id,
				content: inserted.content,
				round_number: inserted.round_number,
			});
			return emptyResponse();
		}

		if (table === "matches") {
			if (request.method === "GET") {
				const idFilter = url.searchParams.get("id");
				if (idFilter !== null && idFilter !== `eq.${MATCH_ID}`) {
					return rejectFixtureRequest(`synthetic matches GET filter mismatch: ${url.search}`);
				}
				const select = url.searchParams.get("select") ?? "";
				if (select.includes("user_a_id")) {
					return jsonResponse(
						isSingleRequest(request)
							? { id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: state.matchStatus }
							: [{ id: MATCH_ID, user_a_id: USER_A, user_b_id: USER_B, status: state.matchStatus }],
					);
				}
				matchScoreLookupsValue++;
				const matchScore = options.matchScore ?? {
					profile_score: 50,
					score_details: { personality: 0.5, interests: 0.5, values: 0.5, communication: 0.5 },
				};
				return jsonResponse(isSingleRequest(request) ? matchScore : []);
			}
			if (request.method !== "PATCH" || typeof body !== "object" || body === null || Array.isArray(body)) {
				throw adapterError(`synthetic Supabase adapter: unsupported matches request ${request.method}`);
			}
			const update = body as Record<string, unknown>;
			const id = eqFilter(url, "id");
			const matchUserA = eqFilter(url, "user_a_id");
			const matchUserB = eqFilter(url, "user_b_id");
			const expectedStatus = eqFilter(url, "status");
			const statuses = inFilter(url, "status");
			if (
				id !== MATCH_ID ||
				(matchUserA !== null && matchUserA !== USER_A) ||
				(matchUserB !== null && matchUserB !== USER_B) ||
				(expectedStatus !== null && expectedStatus !== state.matchStatus) ||
				(statuses && !statuses.includes(state.matchStatus))
			) {
				return rejectFixtureRequest(`synthetic matches filter mismatch: ${url.search}`);
			}
			if (typeof update.status === "string") state.matchStatus = update.status as SyntheticState["matchStatus"];
			matchUpdates.push({ ...update });
			return hasSelectedRepresentation(request, url) ? jsonResponse({ id: MATCH_ID }) : emptyResponse();
		}

		if (table === "personas") {
			if (request.method !== "GET") throw adapterError(`synthetic Supabase adapter: unsupported personas request ${request.method}`);
			const userFilter = url.searchParams.get("user_id");
			const personaTypeFilter = url.searchParams.get("persona_type");
			if (
				(userFilter !== null && ![`eq.${USER_A}`, `eq.${USER_B}`].includes(userFilter)) ||
				(personaTypeFilter !== null && personaTypeFilter !== "eq.wingfox")
			) {
				return rejectFixtureRequest(`synthetic personas GET filter mismatch: ${url.search}`);
			}
			if (options.personaMissingUserId && userFilter === `eq.${options.personaMissingUserId}`) {
				return jsonResponse({ code: "PGRST116", message: "JSON object requested, multiple (or no) rows returned" }, 406);
			}
			return jsonResponse({ compiled_document: "synthetic persona document", name: "Synthetic Fox" });
		}

		if (table === "user_profiles") {
			if (request.method !== "GET") throw adapterError(`synthetic Supabase adapter: unsupported user_profiles request ${request.method}`);
			const idFilter = url.searchParams.get("id");
			const select = url.searchParams.get("select") ?? "";
			if (idFilter?.startsWith("eq.")) {
				if (select !== "timezone" || ![USER_A, USER_B].includes(idFilter.slice(3))) {
					return rejectFixtureRequest(`synthetic user_profiles timezone filter mismatch: ${url.search}`);
				}
				return jsonResponse({ timezone: "UTC" });
			}
			const requestedIds = inFilter(url, "id");
			if (
				(idFilter !== null && !idFilter.startsWith("in.(")) ||
				!requestedIds ||
				requestedIds.length !== 2 ||
				new Set(requestedIds).size !== 2 ||
				!requestedIds.every((id) => [USER_A, USER_B].includes(id))
			) {
				return rejectFixtureRequest(`synthetic user_profiles GET filter mismatch: ${url.search}`);
			}
			return jsonResponse(select.includes("language") ? makeGenderLanguageProfiles() : makeAccessProfiles());
		}

		if (table === "profiles") {
			if (request.method !== "GET") throw adapterError(`synthetic Supabase adapter: unsupported profiles request ${request.method}`);
			const requestedIds = inFilter(url, "user_id");
			if (
				url.searchParams.get("select") !== "*" ||
				!requestedIds ||
				requestedIds.length !== 2 ||
				new Set(requestedIds).size !== 2 ||
				!requestedIds.every((id) => [USER_A, USER_B].includes(id)) ||
				eqFilter(url, "status") !== "confirmed"
			) {
				return rejectFixtureRequest(`synthetic profiles GET filter mismatch: ${url.search}`);
			}
			profileLookupRequestsValue++;
			return jsonResponse(options.profileRows ?? []);
		}

		if (table === "blocks") {
			if (request.method !== "GET") throw adapterError(`synthetic Supabase adapter: unsupported blocks request ${request.method}`);
			return jsonResponse([]);
		}

		if (table === "interaction_dna_scores") {
			if (request.method === "POST") {
				if (!Array.isArray(body) || url.searchParams.get("on_conflict") !== "match_id,feature_id,source_phase") {
					return rejectFixtureRequest(`synthetic interaction_dna_scores POST shape mismatch: ${url.search}`);
				}
				const rows = body as SyntheticFeatureRow[];
				if (
					!rows.every((row) =>
						typeof row === "object" &&
						row !== null &&
						row.match_id === MATCH_ID &&
						typeof row.feature_id === "number" &&
						typeof row.normalized_score === "number" &&
						typeof row.confidence === "number" &&
						typeof row.source_phase === "string",
					)
				) {
					return rejectFixtureRequest("synthetic interaction_dna_scores POST row mismatch");
				}
				featureUpserts.push({
					rows: rows.map((row) => ({ ...row })),
					onConflict: "match_id,feature_id,source_phase",
				});
				if (options.interactionWriteError ?? true) {
					// saveFeatureScores logs write errors without throwing. This alone
					// does not enter simple-score fallback; interactionReadError below
					// makes loadFeatureScores throw and exercises that separate path.
					return jsonResponse({ message: "synthetic optional table unavailable" }, 500);
				}
				for (const row of rows) {
					const existingIndex = featureRows.findIndex(
						(existing) =>
							existing.match_id === row.match_id &&
							existing.feature_id === row.feature_id &&
							existing.source_phase === row.source_phase,
					);
					if (existingIndex >= 0) featureRows[existingIndex] = { ...featureRows[existingIndex], ...row };
					else featureRows.push({ ...row });
				}
				return emptyResponse();
			}
			if (request.method === "GET") {
				const matchFilter = url.searchParams.get("match_id");
				if (
					url.searchParams.get("select") !== "feature_id,normalized_score,confidence,source_phase" ||
					matchFilter !== `eq.${MATCH_ID}`
				) {
					return rejectFixtureRequest(`synthetic interaction_dna_scores GET filter mismatch: ${url.search}`);
				}
				featureLoadRequestsValue++;
				if (options.interactionReadError) {
					return jsonResponse({ message: "synthetic feature read failure" }, 500);
				}
				return jsonResponse(featureRows);
			}
			throw adapterError(`synthetic Supabase adapter: unsupported interaction_dna_scores request ${request.method}`);
		}

		if (table === "notification_scenarios") {
			if (
				request.method !== "GET" ||
				url.searchParams.get("select") !== "quiet_hours_exempt,is_enabled" ||
				eqFilter(url, "scenario_id") !== "N-01" ||
				!isSingleRequest(request)
			) {
				throw adapterError(`synthetic notification_scenarios request mismatch: ${request.method} ${url.search}`);
			}
			return jsonResponse({ quiet_hours_exempt: false, is_enabled: true });
		}

		if (table === "notifications") {
			if (request.method === "GET") {
				const select = url.searchParams.get("select") ?? "";
				if (select.includes("scenario:notification_scenarios")) {
					const expectedQueryKeys = [
						"select",
						"id",
						"scenario_id",
						"user_id",
						"payload->>deep_link",
						"sent_at",
						"suppressed_reason",
						"onesignal_notification_id",
						"match_id",
						"meetup_id",
						"scheduled_for",
						"match.user_a_id",
						"match.user_b_id",
						"match.profile_a.blocks_sent.blocked_id",
						"match.profile_b.blocks_sent.blocked_id",
						"match.compatibility_conversations.purpose",
						"payload->delivery_context->>conversation_id",
					].sort();
				const actualQueryKeys = [...url.searchParams.keys()].sort();
				const notificationId = eqFilter(url, "id");
				const userId = eqFilter(url, "user_id");
				if (
					normalizeSelect(select) !== normalizeSelect(FINAL_NOTIFICATION_SELECT) ||
					actualQueryKeys.length !== expectedQueryKeys.length ||
					actualQueryKeys.some((key, index) => key !== expectedQueryKeys[index]) ||
					!notificationId ||
					![USER_A, USER_B].includes(userId ?? "") ||
					eqFilter(url, "scenario_id") !== "N-01" ||
					eqFilter(url, "payload->>deep_link") !== `wingward://match/${MATCH_ID}/fox-result` ||
					url.searchParams.get("sent_at") !== "is.null" ||
					url.searchParams.get("suppressed_reason") !== "is.null" ||
					url.searchParams.get("onesignal_notification_id") !== "is.null" ||
					eqFilter(url, "match_id") !== MATCH_ID ||
					url.searchParams.get("meetup_id") !== "is.null" ||
					!eqFilter(url, "scheduled_for") ||
					eqFilter(url, "match.user_a_id") !== USER_A ||
					eqFilter(url, "match.user_b_id") !== USER_B ||
					eqFilter(url, "match.profile_a.blocks_sent.blocked_id") !== USER_B ||
					eqFilter(url, "match.profile_b.blocks_sent.blocked_id") !== USER_A ||
					eqFilter(url, "match.compatibility_conversations.purpose") !== "compatibility" ||
					eqFilter(url, "payload->delivery_context->>conversation_id") !== CONVERSATION_ID ||
					!isSingleRequest(request)
				) {
					throw adapterError(`synthetic notifications final snapshot mismatch: ${url.search}`);
				}
				const inserted = notifications.find((row) => row.id === notificationId && row.user_id === userId);
				if (!inserted) throw adapterError(`synthetic notifications final snapshot row mismatch: ${url.search}`);
				if (inserted.scheduled_for !== eqFilter(url, "scheduled_for")) {
					throw adapterError(`synthetic notifications final snapshot fencing mismatch: ${url.search}`);
				}
				const [profileA, profileB] = state.accessProfiles;
				return jsonResponse({
					id: inserted.id,
					scenario_id: inserted.scenario_id,
					user_id: inserted.user_id,
					match_id: inserted.match_id ?? null,
					meetup_id: inserted.meetup_id ?? null,
					payload: inserted.payload,
					scheduled_for: inserted.scheduled_for ?? null,
					sent_at: inserted.sent_at ?? null,
					suppressed_reason: inserted.suppressed_reason ?? null,
					onesignal_notification_id: inserted.onesignal_notification_id ?? null,
					scenario: { scenario_id: "N-01", is_enabled: true },
					match: {
						id: MATCH_ID,
						user_a_id: USER_A,
						user_b_id: USER_B,
						status: state.matchStatus,
						profile_a: { ...profileA, blocks_sent: [...state.blocksFromA] },
						profile_b: { ...profileB, blocks_sent: [...state.blocksFromB] },
						compatibility_conversations: [
							{ id: CONVERSATION_ID, match_id: MATCH_ID, purpose: "compatibility", status: state.conversationStatus },
						],
						chat_requests: [],
						direct_room: null,
					},
					meetup: null,
				});
				}
				if (
					select !== "id" ||
					eqFilter(url, "scenario_id") !== "N-01" ||
					![USER_A, USER_B].includes(eqFilter(url, "user_id") ?? "") ||
					eqFilter(url, "match_id") !== MATCH_ID ||
					!gteFilter(url, "dedup_window_start") ||
					url.searchParams.get("limit") !== "1"
				) {
					throw adapterError(`synthetic notifications dedup request mismatch: ${url.search}`);
				}
				return jsonResponse([]);
			}
			if (request.method === "POST") {
				if (typeof body !== "object" || body === null || Array.isArray(body)) {
					throw adapterError("synthetic notifications insert body mismatch");
				}
				const inserted = body as Record<string, unknown>;
				const payload = inserted.payload;
				if (
					inserted.scenario_id !== "N-01" ||
					![USER_A, USER_B].includes(inserted.user_id as string) ||
					inserted.match_id !== MATCH_ID ||
					inserted.meetup_id !== null ||
					typeof inserted.scheduled_for !== "string" ||
					typeof inserted.dedup_window_start !== "string" ||
					typeof payload !== "object" ||
					payload === null ||
					(payload as Record<string, unknown>).deep_link !== `wingward://match/${MATCH_ID}/fox-result`
				) {
					throw adapterError("synthetic notifications insert shape mismatch");
				}
				const id = `synthetic-notification-${notifications.length + 1}`;
				const row = { id, ...inserted };
				notifications.push(row);
				return hasSelectedRepresentation(request, url)
					? jsonResponse(isSingleRequest(request) ? { id } : [{ id }])
					: emptyResponse();
			}
			if (request.method === "PATCH") {
				const id = eqFilter(url, "id");
				const row = notifications.find((candidate) => candidate.id === id);
				if (!row || id === null) throw adapterError(`synthetic notifications update id mismatch: ${url.search}`);
				const fencingToken = eqFilter(url, "scheduled_for");
				if (fencingToken !== null && row.scheduled_for !== fencingToken) return jsonResponse([]);
				applySyntheticNotificationPatch(row, body, adapterError);
				return hasSelectedRepresentation(request, url) ? jsonResponse([{ id }]) : emptyResponse();
			}
			throw adapterError(`synthetic notifications request mismatch: ${request.method} ${url.search}`);
		}

		if (table === "notification_events") {
			if (request.method !== "POST" || typeof body !== "object" || body === null || Array.isArray(body)) {
				throw adapterError(`synthetic notification_events request mismatch: ${request.method}`);
			}
			const event = body as Record<string, unknown>;
			const notification = notifications.find((row) => row.id === event.notification_id);
			if (
				typeof event.id !== "string" ||
				!notification ||
				event.user_id !== notification.user_id ||
				event.event_type !== "sent" ||
				typeof event.occurred_at !== "string"
			) {
				throw adapterError("synthetic notification_events insert shape mismatch");
			}
			notificationEvents.push({ ...event });
			return emptyResponse();
		}

		throw adapterError(`synthetic Supabase adapter: unknown table ${table}`);
	};

	return {
		fetch,
		beginInvocation() {
			currentInvocation++;
			invocations.push({ requests: 0, byTable: {} });
		},
		invocations,
		errors,
		state,
		messages,
		featureRows,
		featureUpserts,
		matchUpdates,
		notifications,
		notificationEvents,
		oneSignalRequests,
		profileLookupRequests: () => profileLookupRequestsValue,
		featureLoadRequests: () => featureLoadRequestsValue,
		matchScoreLookups: () => matchScoreLookupsValue,
		checkpointAttempts: () => checkpointAttemptsValue,
		currentAccessRequests: () => currentAccessRequestsValue,
		};
}

function makeFakeCtx(initialState: unknown) {
	const store = new Map<string, unknown>([["state", initialState]]);
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

function makeNotifyingState() {
	return { ...makeInProgressState(), status: "notifying" as const };
}

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
			buildCatchUpMessage: (state: unknown) => Promise<{
				type: string;
				total_rounds: number;
				current_round: number;
				messages: unknown[];
			}>;
		}
	).buildCatchUpMessage.bind(doInstance);
}

function roundResponse(index: number) {
	return {
		content: `synthetic round ${index}`,
		usage: { inputTokens: 2, outputTokens: 1, cachedTokens: null },
	};
}

function scoreResponse() {
	return {
		content: JSON.stringify({
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
		}),
		usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null },
	};
}

function malformedScoreResponse(index: number) {
	return {
		content: `synthetic malformed score response ${index}`,
		usage: { inputTokens: 7, outputTokens: 6, cachedTokens: null },
	};
}

const mockedChatCompleteWithUsage = vi.mocked(chatCompleteWithUsage);

function installTransport(adapter: SupabaseFetchAdapter): void {
	vi.stubGlobal("fetch", adapter.fetch);
}

function makeDO(
	ctx: ReturnType<typeof makeFakeCtx>,
	envOverrides: Partial<Record<string, string>> = {},
) {
	// Do not replace FoxConversationDO.getSupabase here: alarm() constructs the
	// production Supabase JS client, which picks up the installed fetch adapter.
	return new FoxConversationDO(ctx as never, {
		SUPABASE_URL,
		SUPABASE_SERVICE_ROLE_KEY,
		MISTRAL_API_KEY: "synthetic-mistral-key",
		...envOverrides,
	} as never);
}

beforeEach(() => {
	mockedChatCompleteWithUsage.mockReset();
	vi.mocked(chatCompleteOnceBounded).mockReset();
});

afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
	vi.useRealTimers();
});

describe("FoxConversationDO.alarm() transport budget", () => {
	it.each([false, true])("advances ten registered judge rounds and scoring with one reserved attempt per alarm (full traits %s)", async fullTraits => {
		vi.spyOn(Date, "now").mockReturnValue(Date.parse("2026-10-01T00:01:00Z"));
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 10, registeredJudge: true,
			...(fullTraits ? { profileRows: makeConfirmedScoringProfiles(), matchScore: { profile_score: 50, score_details: {} }, interactionWriteError: false } : {}) });
		installTransport(adapter);
		const ctx = makeFakeCtx(makeInProgressState());
		const instance = makeDO(ctx, { JUDGE_ACCESS_ENABLED: "enabled", JUDGE_ACCESS_COHORT: ["shipaton", "20261001"].join("-"), JUDGE_ACCESS_ISSUED_AT: "2026-09-30T19:00:00Z", JUDGE_ACCESS_EXPIRES_AT: "2026-10-13T19:00:00Z", JUDGE_ACCESS_AI_EXPIRES_AT: "2026-10-01T00:00:00Z" });
		let providerCalls = 0;
		vi.mocked(chatCompleteOnceBounded).mockImplementation(async () => {
			providerCalls++;
			return { content: providerCalls <= 10 ? `synthetic round ${providerCalls}` : scoreResponse().content, finishReason: "stop", inputTokens: 100, outputTokens: 20 };
		});
		let status = "in_progress";
		for (let alarm = 0; alarm < 11; alarm++) {
			adapter.beginInvocation();
			await instance.alarm();
			status = (await ctx.storage.get("state") as { status: string }).status;
		}
		expect(status).toBe("notifying");
		expect(providerCalls).toBe(11);
		expect(chatCompleteWithUsage).not.toHaveBeenCalled();
		expect(adapter.errors).toEqual([]);
		expect(adapter.messages.map(message => message.round_number)).toEqual([1,2,3,4,5,6,7,8,9,10]);
		expect(adapter.invocations.map(invocation => invocation.byTable.reserve_judge_provider_operation)).toEqual(Array(11).fill(1));
		for (const invocation of adapter.invocations) expect(invocation.requests + 1).toBeLessThanOrEqual(50);
		console.log("Registered judge mocked transport dispatches", adapter.invocations.map(invocation => invocation.requests));
	});
	it("counts one actual HTTP request for one embedded current-access check", async () => {
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1 });
		installTransport(adapter);
		const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
			auth: { persistSession: false },
		});
		adapter.beginInvocation();

		await expect(
			checkFoxConversationCurrentAccess(
				supabase as never,
				{
					conversationId: CONVERSATION_ID,
					matchId: MATCH_ID,
					userA: USER_A,
					userB: USER_B,
				},
				"active",
			),
		).resolves.toMatchObject({ ok: true });

		expect(adapter.invocations).toHaveLength(1);
		expect(adapter.invocations[0].requests).toBe(1);
		expect(adapter.currentAccessRequests()).toBe(1);
		expect(adapter.invocations[0].byTable).toEqual({ fox_conversations: 1 });
		expect(adapter.errors).toEqual([]);
	});

	it("measures each one-round alarm through eventual completion without duplicate rounds", async () => {
		const TOTAL_ROUNDS = 4;
		const adapter = makeSupabaseFetchAdapter({ totalRounds: TOTAL_ROUNDS });
		installTransport(adapter);
		let modelCalls = 0;
		let activeInvocation = -1;
		const modelAttemptsByInvocation: number[] = [];
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelCalls++;
			modelAttemptsByInvocation[activeInvocation] = (modelAttemptsByInvocation[activeInvocation] ?? 0) + 1;
			if (modelCalls <= TOTAL_ROUNDS) return roundResponse(modelCalls);
			return scoreResponse();
		});

		const ctx = makeFakeCtx(makeInProgressState());
		const doInstance = makeDO(ctx);
		let iterations = 0;
		let status = (await ctx.storage.get("state") as { status: string }).status;
		while (status !== "completed" && iterations < TOTAL_ROUNDS + 3) {
			activeInvocation++;
			modelAttemptsByInvocation[activeInvocation] = 0;
			adapter.beginInvocation();
			await doInstance.alarm();
			status = (await ctx.storage.get("state") as { status: string }).status;
			iterations++;
		}

		expect(status).toBe("completed");
		expect(iterations).toBe(TOTAL_ROUNDS + 2);
		expect(modelCalls).toBe(TOTAL_ROUNDS + 1);
		// Model attempts are kept separate from database dispatches: four
		// rounds, one scoring call, then the notify-only alarm does no model work.
		expect(modelAttemptsByInvocation).toEqual([1, 1, 1, 1, 1, 0]);
		expect(adapter.invocations.map((invocation) => invocation.requests)).toEqual([22, 22, 22, 22, 29, 2]);
		expect(adapter.errors).toEqual([]);
		expect(adapter.messages).toHaveLength(TOTAL_ROUNDS);
		expect(adapter.messages.map((message) => message.round_number)).toEqual([1, 2, 3, 4]);
		expect(new Set(adapter.messages.map((message) => message.round_number)).size).toBe(TOTAL_ROUNDS);
		expect(adapter.state.currentRound).toBe(TOTAL_ROUNDS);
		expect(adapter.state.conversationStatus).toBe("completed");
		expect(adapter.state.matchStatus).toBe("fox_conversation_completed");
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("completed");
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(TOTAL_ROUNDS + 1);
	});

	it("measures the final one-round alarm separately from scoring", async () => {
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1 });
		installTransport(adapter);
		let modelCalls = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelCalls++;
			return roundResponse(modelCalls);
		});

		const ctx = makeFakeCtx(makeInProgressState());
		adapter.beginInvocation();
		await makeDO(ctx).alarm();

		expect(modelCalls).toBe(1);
		expect(adapter.invocations).toHaveLength(1);
		// One round uses 22 dispatches in this synthetic measurement with the
		// production guard fixed at MAX_ROUNDS_PER_ALARM=1.
		expect(adapter.invocations[0].requests).toBe(22);
		expect(adapter.invocations[0].requests).toBeLessThan(50);
		expect(adapter.errors).toEqual([]);
		expect(adapter.messages).toHaveLength(1);
		expect(new Set(adapter.messages.map((message) => message.round_number))).toEqual(new Set([1]));
		expect(adapter.state.currentRound).toBe(1);
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("in_progress");
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(1);
	});

	it("counts a scoring-only alarm after the round-only checkpoint without generating another round", async () => {
		const initialMessages = [1, 2, 3, 4].map((round_number) => ({
			speaker_user_id: round_number % 2 === 1 ? USER_A : USER_B,
			content: `prior round ${round_number}`,
			round_number,
		}));
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 4, initialMessages });
		installTransport(adapter);
		let modelCalls = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelCalls++;
			return scoreResponse();
		});

		const ctx = makeFakeCtx(makeInProgressState());
		adapter.beginInvocation();
		await makeDO(ctx).alarm();

		expect(modelCalls).toBe(1);
		expect(adapter.invocations).toHaveLength(1);
		// Scoring uses 29 dispatched Supabase HTTP requests before the notify-only
		// alarm in this synthetic measurement.
		expect(adapter.invocations[0].requests).toBe(29);
		expect(adapter.errors).toEqual([]);
		expect(adapter.invocations[0].byTable.interaction_dna_scores).toBeGreaterThan(0);
		expect(adapter.state.conversationStatus).toBe("completed");
		expect(adapter.state.matchStatus).toBe("fox_conversation_completed");
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("notifying");
	});

	it("includes a checkpoint retry in the same invocation while preserving the rounds-only boundary", async () => {
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1, checkpointFailures: 1 });
		installTransport(adapter);
		let modelCalls = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelCalls++;
			return roundResponse(modelCalls);
		});

		const ctx = makeFakeCtx(makeInProgressState());
		adapter.beginInvocation();
		await makeDO(ctx).alarm();

		expect(modelCalls).toBe(1);
		expect(adapter.checkpointAttempts()).toBe(2);
		// Compared with the 22-request one-round baseline, retrying adds one
		// embedded access read and one PATCH: two extra dispatches, for 24 total.
		expect(adapter.invocations[0].requests).toBe(24);
		expect(adapter.errors).toEqual([]);
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("in_progress");
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(1);
	});

	it("counts one transient provider failure and its successful retry separately from database dispatches", async () => {
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1 });
		installTransport(adapter);
		vi.spyOn(Math, "random").mockReturnValue(0);
		let modelAttempts = 0;
		let providerFailures = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelAttempts++;
			if (providerFailures === 0) {
				providerFailures++;
				throw new Error("synthetic transient provider failure");
			}
			return roundResponse(modelAttempts - 1);
		});

		const ctx = makeFakeCtx(makeInProgressState());
		adapter.beginInvocation();
		await makeDO(ctx).alarm();

		expect(providerFailures).toBe(1);
		expect(modelAttempts).toBe(2);
		expect(adapter.invocations).toHaveLength(1);
		// The failed provider attempt adds two embedded current-access rechecks
		// before the first round is persisted: 24 versus the 22-request baseline.
		expect(adapter.invocations[0].requests).toBe(24);
		expect(adapter.errors).toEqual([]);
		expect(adapter.messages).toHaveLength(1);
		expect(new Set(adapter.messages.map((message) => message.round_number))).toEqual(new Set([1]));
		expect(adapter.state.currentRound).toBe(1);
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("in_progress");
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(1);
	});

	it("counts the maximum provider retries before failure cleanup", async () => {
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1 });
		installTransport(adapter);
		let modelAttempts = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelAttempts++;
			throw new Error("synthetic provider unavailable");
		});

		const ctx = makeFakeCtx(makeInProgressState());
		adapter.beginInvocation();
		await makeDO(ctx).alarm();

		expect(modelAttempts).toBe(3);
		expect(adapter.invocations).toHaveLength(1);
		// Three provider attempts fail before the engine checkpoint and the DO's
		// current-access plus conversation/match failure cleanup writes.
		expect(adapter.invocations[0].requests).toBe(21);
		expect(adapter.errors).toEqual([]);
		expect(adapter.messages).toHaveLength(0);
		expect(adapter.state.conversationStatus).toBe("failed");
		expect(adapter.state.matchStatus).toBe("fox_conversation_failed");
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("failed");
		expect(ctx.storage.setAlarm).not.toHaveBeenCalled();
	}, 10000);

	it("counts maximum checkpoint retries and failure cleanup without rescheduling", async () => {
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1, checkpointFailures: Number.POSITIVE_INFINITY });
		installTransport(adapter);
		let modelAttempts = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelAttempts++;
			return roundResponse(modelAttempts);
		});

		const ctx = makeFakeCtx(makeInProgressState());
		adapter.beginInvocation();
		await makeDO(ctx).alarm();

		expect(modelAttempts).toBe(1);
		expect(adapter.checkpointAttempts()).toBe(4);
		expect(adapter.invocations).toHaveLength(1);
		// Three bounded checkpoint attempts plus the engine's best-effort error
		// checkpoint are followed by current-access and failure-state writes.
		expect(adapter.invocations[0].requests).toBe(30);
		expect(adapter.errors).toEqual([]);
		expect(adapter.messages).toHaveLength(1);
		expect(adapter.state.currentRound).toBe(1);
		expect(adapter.state.conversationStatus).toBe("failed");
		expect(adapter.state.matchStatus).toBe("fox_conversation_failed");
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("failed");
		expect(ctx.storage.setAlarm).not.toHaveBeenCalled();
	});

	it("counts combined provider retries and exhausted checkpoint cleanup in one invocation", async () => {
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1, checkpointFailures: Number.POSITIVE_INFINITY });
		installTransport(adapter);
		vi.spyOn(Math, "random").mockReturnValue(0);
		let modelAttempts = 0;
		let providerFailures = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelAttempts++;
			if (modelAttempts <= 2) {
				providerFailures++;
				throw new Error(`synthetic provider failure ${modelAttempts}`);
			}
			return roundResponse(1);
		});

		const ctx = makeFakeCtx(makeInProgressState());
		adapter.beginInvocation();
		await makeDO(ctx).alarm();

		expect(providerFailures).toBe(2);
		expect(modelAttempts).toBe(3);
		expect(adapter.checkpointAttempts()).toBe(4);
		expect(adapter.invocations).toHaveLength(1);
		// This deliberately combines the separately measured model attempts with
		// database dispatches: the two failed provider calls, one success, four
		// checkpoint attempts, and failure cleanup all belong to this alarm.
		expect(adapter.invocations[0].requests).toBe(34);
		expect(adapter.invocations[0].requests + modelAttempts).toBe(37);
		expect(adapter.errors).toEqual([]);
		expect(adapter.messages).toHaveLength(1);
		expect(adapter.state.currentRound).toBe(1);
		expect(adapter.state.conversationStatus).toBe("failed");
		expect(adapter.state.matchStatus).toBe("fox_conversation_failed");
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("failed");
		expect(ctx.storage.setAlarm).not.toHaveBeenCalled();
	}, 10000);

	it("keeps token totals when all scoring retries are malformed and uses the default score", async () => {
		const initialMessages = [{
			speaker_user_id: USER_A,
			content: "prior round 1",
			round_number: 1,
		}];
		const adapter = makeSupabaseFetchAdapter({
			totalRounds: 1,
			initialMessages,
			initialInputTokens: 10,
			initialOutputTokens: 20,
			initialCacheHitTokens: 3,
			profileRows: makeConfirmedScoringProfiles(),
			matchScore: { profile_score: 50, score_details: {} },
			interactionReadError: true,
		});
		installTransport(adapter);
		vi.spyOn(Math, "random").mockReturnValue(0);
		let modelAttempts = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelAttempts++;
			return malformedScoreResponse(modelAttempts);
		});

		const ctx = makeFakeCtx(makeInProgressState());
		adapter.beginInvocation();
		await makeDO(ctx).alarm();

		expect(modelAttempts).toBe(3);
		expect(adapter.errors).toEqual([]);
		expect(adapter.invocations[0].requests).toBe(41);
		expect(adapter.invocations[0].requests + modelAttempts).toBe(44);
		expect(adapter.profileLookupRequests()).toBe(1);
		expect(adapter.matchScoreLookups()).toBe(2);
		expect(adapter.featureLoadRequests()).toBe(1);
		expect(adapter.featureUpserts).toHaveLength(2);
		expect(adapter.featureUpserts[0].rows).toHaveLength(6);
		expect(adapter.featureUpserts[0].rows.every((row) => row.confidence === 0.3 && row.source_phase === "fox_conversation")).toBe(true);
		expect(adapter.featureUpserts[1].rows).toHaveLength(14);
		expect(adapter.featureUpserts[1].rows.every((row) => row.confidence === 0.6)).toBe(true);
		expect(adapter.featureRows).toHaveLength(0);
		expect(adapter.state.inputTokens).toBe(31);
		expect(adapter.state.outputTokens).toBe(38);
		expect(adapter.state.cacheHitTokens).toBe(3);
		expect(adapter.matchUpdates).toHaveLength(1);
		expect(adapter.matchUpdates[0]).toMatchObject({
			conversation_score: 50,
			final_score: 50,
			status: "fox_conversation_completed",
		});
		expect(adapter.matchUpdates[0]).not.toHaveProperty("layer_scores");
		expect(adapter.state.conversationStatus).toBe("completed");
		expect(adapter.state.matchStatus).toBe("fox_conversation_completed");
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("notifying");
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(1);
	}, 10000);

	it("persists and reloads both conversation and profile features when traits are absent", async () => {
		const initialMessages = [{
			speaker_user_id: USER_A,
			content: "prior round 1",
			round_number: 1,
		}];
		const adapter = makeSupabaseFetchAdapter({
			totalRounds: 1,
			initialMessages,
			profileRows: makeConfirmedScoringProfiles(),
			matchScore: { profile_score: 50, score_details: {} },
			interactionWriteError: false,
		});
		installTransport(adapter);
		let modelAttempts = 0;
		mockedChatCompleteWithUsage.mockImplementation(async () => {
			modelAttempts++;
			return scoreResponse();
		});

		const ctx = makeFakeCtx(makeInProgressState());
		adapter.beginInvocation();
		await makeDO(ctx).alarm();

		expect(modelAttempts).toBe(1);
		expect(adapter.errors).toEqual([]);
		expect(adapter.invocations[0].requests).toBe(32);
		expect(adapter.invocations[0].requests + modelAttempts).toBe(33);
		expect(adapter.profileLookupRequests()).toBe(1);
		expect(adapter.matchScoreLookups()).toBe(1);
		expect(adapter.featureLoadRequests()).toBe(1);
		expect(adapter.featureUpserts).toHaveLength(2);
		expect(adapter.featureUpserts.map((upsert) => upsert.onConflict)).toEqual([
			"match_id,feature_id,source_phase",
			"match_id,feature_id,source_phase",
		]);
		expect(adapter.featureUpserts[0].rows).toHaveLength(6);
		expect(adapter.featureUpserts[1].rows).toHaveLength(14);
		expect(new Set(adapter.featureUpserts[0].rows.map((row) => row.feature_id))).toEqual(new Set([4, 6, 7, 9, 11, 14]));
		expect(adapter.featureUpserts[0].rows.every((row) => row.confidence === 0.7 && row.source_phase === "fox_conversation")).toBe(true);
		expect(new Set(adapter.featureUpserts[1].rows.map((row) => row.feature_id))).toEqual(new Set(Array.from({ length: 14 }, (_, index) => index + 1)));
		expect(adapter.featureUpserts[1].rows.every((row) => row.confidence === 0.6)).toBe(true);
		expect(adapter.featureRows).toHaveLength(20);
		expect(adapter.featureRows.every((row) => row.match_id === MATCH_ID)).toBe(true);
		expect(new Set(adapter.featureRows.map((row) => row.feature_id))).toEqual(new Set(Array.from({ length: 14 }, (_, index) => index + 1)));
		expect(adapter.matchUpdates).toHaveLength(1);
		expect(adapter.matchUpdates[0]).toMatchObject({
			conversation_score: 80,
			final_score: 69,
			status: "fox_conversation_completed",
			score_details: {
				personality: 100,
				interests: 100,
				values: 100,
				communication: 100,
				layer1: 75,
				layer2: 57,
				layer3: 83,
			},
			layer_scores: { layer1: 0.75, layer2: 0.571, layer3: 0.833, dealbreakers: [] },
		});
		expect(Object.keys((adapter.matchUpdates[0].layer_scores as { feature_scores: Record<string, unknown> }).feature_scores)).toHaveLength(14);
		expect(adapter.state.conversationStatus).toBe("completed");
		expect(adapter.state.matchStatus).toBe("fox_conversation_completed");
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("notifying");
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(1);
	});

	it("runs /init through the real Supabase client, saves state, and schedules one alarm", async () => {
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1 });
		installTransport(adapter);
		const ctx = makeFakeCtx(undefined);
		adapter.beginInvocation();

		const response = await makeDO(ctx).fetch(new Request("https://do/init", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ conversationId: CONVERSATION_ID, matchId: MATCH_ID, staggerDelayMs: 1234 }),
		}));

		expect(response.status).toBe(200);
		expect(await response.text()).toBe("OK");
		expect(adapter.invocations[0].requests).toBe(6);
		expect(adapter.errors).toEqual([]);
		expect(adapter.state.conversationStatus).toBe("in_progress");
		expect((await ctx.storage.get("state"))).toMatchObject({
		conversationId: CONVERSATION_ID,
		matchId: MATCH_ID,
		userA: USER_A,
		userB: USER_B,
		status: "in_progress",
	});
		expect(ctx.storage.put).toHaveBeenCalledTimes(1);
		expect(ctx.storage.setAlarm).toHaveBeenCalledTimes(1);
	});

	it("returns 400 and marks both rows failed when /init cannot load a persona", async () => {
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1, personaMissingUserId: USER_B });
		installTransport(adapter);
		const ctx = makeFakeCtx(undefined);
		adapter.beginInvocation();

		const response = await makeDO(ctx).fetch(new Request("https://do/init", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ conversationId: CONVERSATION_ID, matchId: MATCH_ID }),
		}));

		expect(response.status).toBe(400);
		expect(await response.text()).toBe("Persona not found");
		expect(adapter.invocations[0].requests).toBe(7);
		expect(adapter.errors).toEqual([]);
		expect(adapter.state.conversationStatus).toBe("failed");
		expect(adapter.state.matchStatus).toBe("fox_conversation_failed");
		expect(ctx.storage.put).not.toHaveBeenCalled();
		expect(ctx.storage.setAlarm).not.toHaveBeenCalled();
		expect(mockedChatCompleteWithUsage).not.toHaveBeenCalled();
	});

	it("measures a participant reconnect's current-access and catch-up reads with the real Supabase client", async () => {
		const messages = [
			{ speaker_user_id: USER_B, content: "hi from B", round_number: 1 },
			{ speaker_user_id: USER_A, content: "hi from A", round_number: 2 },
			{ speaker_user_id: USER_B, content: "second from B", round_number: 3 },
		];
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 7, initialMessages: messages });
		installTransport(adapter);
		const ctx = makeFakeCtx(makeInProgressState());
		const doInstance = makeDO(ctx);
		adapter.beginInvocation();

		const access = await getResolveWsAccess(doInstance)(USER_A);
		expect(access).toMatchObject({ authorized: true, userId: USER_A });
		if (!access.authorized) throw new Error("unreachable");
		const catchUp = await getBuildCatchUpMessage(doInstance)(access.state);

		expect(catchUp).toEqual({
			type: "state",
			status: "in_progress",
			current_round: 3,
			total_rounds: 7,
			messages: [
				{ round_number: 1, speaker: "B", content: "hi from B" },
				{ round_number: 2, speaker: "A", content: "hi from A" },
				{ round_number: 3, speaker: "B", content: "second from B" },
			],
		});
		// Partial Node evidence: these are the private authorization and
		// catch-up methods used by the upgrade handler. Plain Vitest cannot
		// construct a real 101 WebSocketPair response, so this does not claim
		// Worker handshake or socket delivery coverage.
		expect(adapter.invocations[0].requests).toBe(3);
		expect(adapter.invocations[0].byTable).toEqual({ fox_conversations: 2, fox_conversation_messages: 1 });
		expect(adapter.currentAccessRequests()).toBe(1);
		expect(adapter.errors).toEqual([]);
	});

	it("delivers configured N-01 from its notify-only alarm to both participants", async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-09-06T12:00:00.000Z"));
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1 });
		adapter.state.conversationStatus = "completed";
		adapter.state.matchStatus = "fox_conversation_completed";
		installTransport(adapter);
		const ctx = makeFakeCtx(makeNotifyingState());
		adapter.beginInvocation();

		await makeDO(ctx, {
			ONESIGNAL_APP_ID: SYNTHETIC_ONESIGNAL_APP_ID,
			ONESIGNAL_API_KEY: SYNTHETIC_ONESIGNAL_API_KEY,
		}).alarm();

		expect(adapter.invocations[0].requests).toBe(24);
		expect(adapter.invocations[0].byTable).toEqual({
			fox_conversations: 1,
			matches: 3,
			notification_scenarios: 2,
			user_profiles: 4,
			notifications: 10,
			blocks: 2,
			notification_events: 2,
		});
		expect(adapter.invocations[0].requests + adapter.oneSignalRequests.length).toBe(26);
		expect(adapter.errors).toEqual([]);
		expect(adapter.oneSignalRequests).toHaveLength(2);
		expect(adapter.oneSignalRequests.every((request) => request.status === 200)).toBe(true);
		expect(adapter.oneSignalRequests.map((request) => (request.body.include_aliases as { external_id: string[] }).external_id[0])).toEqual([USER_A, USER_B]);
		expect(adapter.notifications).toHaveLength(2);
		expect(adapter.notifications.every((row) => typeof row.onesignal_notification_id === "string" && typeof row.sent_at === "string")).toBe(true);
		expect(adapter.notificationEvents).toHaveLength(2);
		expect(adapter.notificationEvents.every((event) => event.event_type === "sent")).toBe(true);
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("completed");
		expect(ctx.storage.put).toHaveBeenCalledTimes(1);
		expect(ctx.storage.setAlarm).not.toHaveBeenCalled();
	});

	it("records configured N-01 provider failures for retry without rescheduling the completed DO", async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-09-06T12:00:00.000Z"));
		const adapter = makeSupabaseFetchAdapter({ totalRounds: 1, oneSignalFailure: true });
		adapter.state.conversationStatus = "completed";
		adapter.state.matchStatus = "fox_conversation_completed";
		installTransport(adapter);
		const ctx = makeFakeCtx(makeNotifyingState());
		adapter.beginInvocation();

		await makeDO(ctx, {
			ONESIGNAL_APP_ID: SYNTHETIC_ONESIGNAL_APP_ID,
			ONESIGNAL_API_KEY: SYNTHETIC_ONESIGNAL_API_KEY,
		}).alarm();

		expect(adapter.invocations[0].requests).toBe(20);
		expect(adapter.invocations[0].byTable).toEqual({
			fox_conversations: 1,
			matches: 3,
			notification_scenarios: 2,
			user_profiles: 4,
			notifications: 8,
			blocks: 2,
		});
		expect(adapter.invocations[0].requests + adapter.oneSignalRequests.length).toBe(22);
		expect(adapter.errors).toEqual([]);
		expect(adapter.oneSignalRequests).toHaveLength(2);
		expect(adapter.oneSignalRequests.every((request) => request.status === 503)).toBe(true);
		expect(adapter.notifications).toHaveLength(2);
		expect(adapter.notifications.every((row) => row.scheduled_for !== null && row.sent_at === undefined && row.onesignal_notification_id === undefined)).toBe(true);
		expect(adapter.notifications.every((row) => (row.payload as { deferred_attempts?: number }).deferred_attempts === 1)).toBe(true);
		expect(adapter.notificationEvents).toHaveLength(0);
		expect((await ctx.storage.get("state") as { status: string }).status).toBe("completed");
		expect(ctx.storage.put).toHaveBeenCalledTimes(1);
		expect(ctx.storage.setAlarm).not.toHaveBeenCalled();
	});
});
