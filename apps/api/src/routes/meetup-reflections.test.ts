import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";
import { readRecordingRehearsalConfig, type ValidatedRecordingRehearsalConfig } from "../services/recording-rehearsal";

const OWNER_ID = "11111111-1111-4111-8111-111111111111";
const MEETUP_ID = "22222222-2222-4222-8222-222222222222";
const POISON = "PEER_PRIVATE_EVALUATION_SHOULD_NEVER_APPEAR";
const REHEARSAL_AOI_ID = "96b31c0a-b8c4-4536-ada2-f3537dadd146";
const REHEARSAL_REN_ID = "9d836fee-7b93-41ce-b577-34a63006aaea";
const REHEARSAL_SORA_ID = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";
let authenticatedUserId = OWNER_ID;
let rehearsalExpiryOffset = 0;

function activeRehearsal(pair = "aoi-ren", nowMs = Date.now()): ValidatedRecordingRehearsalConfig {
	rehearsalExpiryOffset += 1_000;
	const result = readRecordingRehearsalConfig({
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: new Date(nowMs - 30_000).toISOString(),
		RECORDING_REHEARSAL_EXPIRES_AT: new Date(nowMs + 60 * 60_000 + rehearsalExpiryOffset).toISOString(),
		RECORDING_REHEARSAL_PAIR: pair,
	}, nowMs);
	if (result.kind !== "active") throw new Error("Expected active rehearsal config");
	return result.config;
}

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", authenticatedUserId);
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import meetupReflections from "./meetup-reflections";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const fetchMock = vi.fn();

function okState(version = 0) {
	return {
		outcome: "ok",
		current_version: version,
		traits: version === 0 ? {} : { social_energy: "ambiverted" },
		confirmed_at: version === 0 ? null : "2026-09-26T01:00:00Z",
	};
}

type SupabaseOptions = {
	states?: unknown[];
	confirm?: unknown;
	owner?: unknown;
	persona?: unknown;
	session?: unknown;
	rpcError?: unknown;
	admission?: unknown;
};

function makeSupabase(
	options: SupabaseOptions = {},
	userId = OWNER_ID,
	rehearsal?: ValidatedRecordingRehearsalConfig,
) {
	const states = options.states ?? [[okState()]];
	let stateCall = 0;
	const rpcCalls: Array<{ name: string; args: Record<string, unknown> }> = [];
	const reads: string[] = [];
	return {
		rpcCalls,
		reads,
		async rpc(name: string, args: Record<string, unknown>) {
			rpcCalls.push({ name, args });
			if (name === "check_synthetic_recording_admission") {
				return { data: options.admission ?? { outcome: "not_found" }, error: null };
			}
			if (name === "get_meetup_reflection_state" || name === "demo_recording_get_meetup_reflection_state") {
				const value = states[Math.min(stateCall, states.length - 1)];
				stateCall += 1;
				return { data: value, error: options.rpcError ?? null };
			}
			if (name === "confirm_meetup_reflection" || name === "demo_recording_confirm_meetup_reflection") {
				return { data: options.confirm ?? { outcome: "not_found" }, error: options.rpcError ?? null };
			}
			throw new Error("unexpected rpc " + name);
		},
		from(table: string) {
			reads.push(table);
			let queryResult: unknown;
			if (table === "user_profiles") {
				queryResult = options.owner ?? { id: userId, conversation_language: "en" };
			} else if (table === "personas") {
				queryResult = options.persona ?? {
					id: "33333333-3333-4333-8333-333333333333",
					user_id: userId,
					persona_type: "wingfox",
					compiled_document: "Name: Ward. Speaks warmly.",
				};
			} else if (table === "chat_meetup_sessions") {
				const [userA, userB] = rehearsal?.generationPair ?? [REHEARSAL_AOI_ID, REHEARSAL_REN_ID];
				const past = new Date(Date.now() - 60_000).toISOString();
				queryResult = options.session ?? {
					meetup_id: MEETUP_ID,
					match_id: "44444444-4444-4444-8444-444444444444",
					room_id: "55555555-5555-4555-8555-555555555555",
					user_a_id: userA,
					user_b_id: userB,
					status: "completed",
					confirmed_ends_at: past,
					completed_a_at: past,
					completed_b_at: null,
				};
			} else {
				throw new Error("unexpected table " + table);
			}
			const query: Record<string, unknown> = {};
			query.select = () => query;
			query.eq = () => query;
			query.maybeSingle = async () => ({ data: queryResult, error: null });
			return query;
		},
	};
}

function buildApp(rehearsal?: ValidatedRecordingRehearsalConfig) {
	const app = new Hono<Env>();
	if (rehearsal) {
		app.use("*", async (c, next) => {
			c.set("recording_rehearsal", rehearsal);
			await next();
		});
	}
	app.route("/api/meetup-reflections", meetupReflections);
	return app;
}

async function request(
	path: string,
	method = "GET",
	body?: unknown,
	options: SupabaseOptions = {},
	bindings: Record<string, unknown> = {},
	rehearsal?: ValidatedRecordingRehearsalConfig,
	userId = rehearsal?.generationPair[0] ?? OWNER_ID,
) {
	const supabase = makeSupabase(options, userId, rehearsal);
	mockedGetSupabaseClient.mockReturnValue(supabase as never);
	authenticatedUserId = userId;
	try {
		const response = await buildApp(rehearsal).request(
			"/api/meetup-reflections/" + path,
			{
				method,
				headers: body === undefined ? {} : { "Content-Type": "application/json" },
				body: body === undefined ? undefined : JSON.stringify(body),
			},
			{
				CHAT_MEETUP_ENABLED: "enabled",
				OPENAI_API_KEY: "test-key-only",
				MEETUP_REFLECTION_REALTIME_ENABLED: "enabled",
				MEETUP_REFLECTION_DRAFTS_ENABLED: "enabled",
				MISTRAL_API_KEY: "test-draft-key-only",
				...bindings,
			} as never,
		);
		return { response, supabase };
	} finally {
		authenticatedUserId = OWNER_ID;
	}
}

beforeEach(() => {
	vi.stubGlobal("fetch", fetchMock);
	fetchMock.mockReset();
	fetchMock.mockImplementation(() => Promise.resolve(Response.json({
		value: "ek_test_ephemeral",
		expires_at: Math.floor(Date.now() / 1000) + 120,
		session: { type: "realtime", model: "gpt-realtime-2.1-mini" },
	})));
	vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe("meetup reflection routes", () => {
	it.each(["GET", "bootstrap", "drafts", "confirm"])("requires the exact chat feature flag for %s", async (route) => {
		const path = route === "GET" ? MEETUP_ID : MEETUP_ID + "/" + route;
		const method = route === "GET" ? "GET" : "POST";
		const body = route === "bootstrap" ? { voice: "cedar" }
			: route === "drafts" ? { statements: [{ turn_id: "u1", text: "I like reading." }] }
			: route === "confirm" ? {
				idempotency_key: "33333333-3333-4333-8333-333333333333",
				expected_version: 0, owner_confirmed: true,
				traits: [{ trait_key: "favorite_activity", value: "reading" }],
			} : undefined;
		for (const flag of [undefined, "true", "ENABLED", "enabled "]) {
			const { response, supabase } = await request(path, method, body, {}, { CHAT_MEETUP_ENABLED: flag });
			expect(response.status).toBe(503);
			expect(supabase.rpcCalls).toEqual([]);
			expect(supabase.reads).toEqual([]);
			expect(fetchMock).not.toHaveBeenCalled();
		}
	});
	it("returns only the owner's latest confirmed traits and never caches them", async () => {
		const { response, supabase } = await request(MEETUP_ID, "GET", undefined, {
			states: [okState(2)],
		});
		expect(response.status).toBe(200);
		expect(response.headers.get("cache-control")).toBe("private, no-store");
		expect(await response.json()).toEqual({
			data: {
				meetup_id: MEETUP_ID,
				current_persona_version: 2,
				confirmed_traits: { social_energy: "ambiverted" },
				confirmed_at: "2026-09-26T01:00:00Z",
			},
		});
		expect(JSON.stringify(supabase.rpcCalls)).not.toContain(POISON);
	});

	it("returns a generic not-found for a meetup the owner cannot access", async () => {
		const { response } = await request(MEETUP_ID + "1", "GET", undefined, {
			states: [{ outcome: "not_found" }],
		});
		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain(POISON);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("fails closed when the reflection realtime provider gate is absent", async () => {
		const { response, supabase } = await request(
			MEETUP_ID + "/bootstrap",
			"POST",
			{ voice: "cedar" },
			{ states: [okState()] },
			{ MEETUP_REFLECTION_REALTIME_ENABLED: undefined },
		);
		expect(response.status).toBe(503);
		expect(fetchMock).not.toHaveBeenCalled();
		expect(supabase.reads).toEqual([]);
	});

	it("creates a purpose-specific private Ward session with short-lived credentials", async () => {
		const { response, supabase } = await request(
			MEETUP_ID + "/bootstrap",
			"POST",
			{ voice: "marin" },
			{ states: [okState(1), okState(1)] },
		);
		expect(response.status).toBe(200);
		expect(response.headers.get("cache-control")).toBe("private, no-store");
		const body = await response.json() as {
			data: {
				session_id: string;
				client_secret: string;
				model: string;
				overrides: { agent: { prompt: { prompt: string }; language: string }; tts: { voiceId: string } };
			};
		};
		expect(body.data.client_secret).toBe("ek_test_ephemeral");
		expect(body.data.model).toBe("gpt-realtime-2.1-mini");
		expect(body.data.overrides.agent.prompt.prompt).toContain("Do not rate, criticize, diagnose");
		expect(body.data.overrides.agent.prompt.prompt).toContain("previously owner-confirmed preference data");
		expect(body.data.overrides.agent.language).toBe("en");
		expect(body.data.overrides.tts.voiceId).toBe("marin");
		expect(supabase.reads).toEqual(["user_profiles", "personas"]);
		const [url, init] = fetchMock.mock.calls[0];
		expect(url).toBe("https://api.openai.com/v1/realtime/client_secrets");
		expect(init.redirect).toBe("manual");
		const sent = JSON.parse(init.body);
		expect(sent.expires_after.seconds).toBe(120);
		expect(sent.session.instructions).toContain("Never record or send a private evaluation");
		expect(sent.session.tracing).toBeNull();
		expect(JSON.stringify(body)).not.toContain("test-key-only");
	});

	it("limits rehearsal voice bootstrap to the selected pair, ended meetup, and two reserved fetches", async () => {
		const rehearsal = activeRehearsal();
		const body = { voice: "marin" };

		const outsider = await request(
			MEETUP_ID + "/bootstrap",
			"POST",
			body,
			{},
			{},
			rehearsal,
			REHEARSAL_SORA_ID,
		);
		expect(outsider.response.status).toBe(503);
		expect(fetchMock).not.toHaveBeenCalled();

		const wrongPair = await request(
			MEETUP_ID + "/bootstrap",
			"POST",
			body,
			{ session: {
				meetup_id: MEETUP_ID,
				match_id: "44444444-4444-4444-8444-444444444444",
				room_id: "55555555-5555-4555-8555-555555555555",
				user_a_id: REHEARSAL_AOI_ID,
				user_b_id: REHEARSAL_SORA_ID,
				status: "completed",
				confirmed_ends_at: new Date(Date.now() - 60_000).toISOString(),
				completed_a_at: new Date(Date.now() - 60_000).toISOString(),
				completed_b_at: null,
			} },
			{},
			rehearsal,
		);
		expect(wrongPair.response.status).toBe(503);
		expect(fetchMock).not.toHaveBeenCalled();

		const incomplete = await request(
			MEETUP_ID + "/bootstrap",
			"POST",
			body,
			{ session: {
				meetup_id: MEETUP_ID,
				match_id: "44444444-4444-4444-8444-444444444444",
				room_id: "55555555-5555-4555-8555-555555555555",
				user_a_id: REHEARSAL_AOI_ID,
				user_b_id: REHEARSAL_REN_ID,
				status: "completed",
				confirmed_ends_at: new Date(Date.now() - 60_000).toISOString(),
				completed_a_at: null,
				completed_b_at: null,
			} },
			{},
			rehearsal,
		);
		expect(incomplete.response.status).toBe(503);
		expect(fetchMock).not.toHaveBeenCalled();

		const first = await request(MEETUP_ID + "/bootstrap", "POST", body, {}, {}, rehearsal);
		const second = await request(MEETUP_ID + "/bootstrap", "POST", body, {}, {}, rehearsal);
		const third = await request(MEETUP_ID + "/bootstrap", "POST", body, {}, {}, rehearsal);
		expect(first.response.status).toBe(200);
		expect(second.response.status).toBe(200);
		expect(third.response.status).toBe(503);
		expect(fetchMock).toHaveBeenCalledTimes(2);
		const thirdBody = await third.response.text();
		expect(thirdBody).not.toContain("ek_test_ephemeral");
	});

	it("drops a rehearsal voice credential when its trusted window expires during fetch", async () => {
		let runNow = Date.now();
		vi.spyOn(Date, "now").mockImplementation(() => runNow);
		const rehearsal = activeRehearsal("aoi-ren", runNow);
		fetchMock.mockImplementation(async () => {
			runNow = rehearsal.expiresAtMs;
			return Response.json({
				value: "ek_test_ephemeral",
				expires_at: Math.floor(runNow / 1000) + 120,
				session: { type: "realtime", model: "gpt-realtime-2.1-mini" },
			});
		});

		const { response } = await request(MEETUP_ID + "/bootstrap", "POST", { voice: "cedar" }, {}, {}, rehearsal);
		expect(response.status).toBe(503);
		expect(await response.text()).not.toContain("ek_test_ephemeral");
		expect(fetchMock).toHaveBeenCalledOnce();
	});

	it("requires English and a bounded serialized prompt before a rehearsal draft call", async () => {
		const languageWindow = activeRehearsal();
		const wrongLanguage = await request(
			MEETUP_ID + "/drafts",
			"POST",
			{ statements: [{ turn_id: "u1", text: "I enjoy reading." }] },
			{ owner: { id: REHEARSAL_AOI_ID, conversation_language: "ja" } },
			{},
			languageWindow,
		);
		expect(wrongLanguage.response.status).toBe(503);
		expect(fetchMock).not.toHaveBeenCalled();

		const rehearsal = activeRehearsal();
		const oversizedStatements = Array.from({ length: 13 }, (_, index) => ({
			turn_id: "turn-" + index,
			text: "a".repeat(600),
		}));
		const oversized = await request(
			MEETUP_ID + "/drafts",
			"POST",
			{ statements: oversizedStatements },
			{},
			{},
			rehearsal,
		);
		expect(oversized.response.status).toBe(503);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("counts failed Mistral attempts, permits two, and drops a draft if expiry occurs during fetch", async () => {
		const rehearsal = activeRehearsal();
		fetchMock
			.mockResolvedValueOnce(Response.json({ error: "test-only" }, { status: 500 }))
			.mockResolvedValueOnce(Response.json({
				choices: [{
					message: { content: JSON.stringify({
						candidates: [{ trait_key: "social_energy", value: "introverted", source_turn_ids: ["u1"] }],
					}) },
					finish_reason: "stop",
				}],
				usage: { prompt_tokens: 10, completion_tokens: 8, prompt_tokens_details: {} },
			}));
		const draftBody = { statements: [{ turn_id: "u1", text: "I like a slower pace." }] };
		const failed = await request(MEETUP_ID + "/drafts", "POST", draftBody, {}, {}, rehearsal);
		const succeeded = await request(MEETUP_ID + "/drafts", "POST", draftBody, {}, {}, rehearsal);
		const limited = await request(MEETUP_ID + "/drafts", "POST", draftBody, {}, {}, rehearsal);
		expect(failed.response.status).toBe(503);
		expect(succeeded.response.status).toBe(200);
		expect(limited.response.status).toBe(503);
		expect(fetchMock).toHaveBeenCalledTimes(2);
		expect(await limited.response.text()).not.toContain("introverted");

		fetchMock.mockReset();
		let runNow = Date.now();
		vi.spyOn(Date, "now").mockImplementation(() => runNow);
		const expiringWindow = activeRehearsal("aoi-ren", runNow);
		fetchMock.mockImplementation(async () => {
			runNow = expiringWindow.expiresAtMs;
			return Response.json({
				choices: [{
					message: { content: JSON.stringify({
						candidates: [{ trait_key: "social_energy", value: "introverted", source_turn_ids: ["u1"] }],
					}) },
					finish_reason: "stop",
				}],
				usage: { prompt_tokens: 10, completion_tokens: 8, prompt_tokens_details: {} },
			});
		});
		const expiredDuringFetch = await request(MEETUP_ID + "/drafts", "POST", draftBody, {}, {}, expiringWindow);
		expect(expiredDuringFetch.response.status).toBe(503);
		expect(await expiredDuringFetch.response.text()).not.toContain("introverted");
		expect(fetchMock).toHaveBeenCalledOnce();
	});

	it("rejects unsupported voice before realtime provider access", async () => {
		const { response } = await request(MEETUP_ID + "/bootstrap", "POST", { voice: "voice-clone" });
		expect(response.status).toBe(400);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("drops an ephemeral credential if access or baseline changes during the provider call", async () => {
		const { response } = await request(
			MEETUP_ID + "/bootstrap",
			"POST",
			{ voice: "cedar" },
			{ states: [okState(1), { outcome: "not_found" }] },
		);
		expect(response.status).toBe(404);
		expect(await response.text()).not.toContain("ek_test_ephemeral");
	});

	it("rejects peer or AI turns before checking draft-provider readiness", async () => {
		const { response } = await request(MEETUP_ID + "/drafts", "POST", {
			statements: [{ turn_id: "turn-1", text: "I enjoy museums.", speaker: "peer" }],
		});
		expect(response.status).toBe(400);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("keeps draft generation unavailable without the dedicated gate and never falls back", async () => {
		const { response, supabase } = await request(
			MEETUP_ID + "/drafts",
			"POST",
			{ statements: [{ turn_id: "turn-1", text: "I enjoy museums." }] },
			{ states: [okState()] },
			{ MEETUP_REFLECTION_DRAFTS_ENABLED: undefined },
		);
		expect(response.status).toBe(503);
		expect(supabase.rpcCalls.map((call) => call.name)).toEqual(["get_meetup_reflection_state"]);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("requires explicit owner confirmation before calling the version RPC", async () => {
		const { response, supabase } = await request(MEETUP_ID + "/confirm", "POST", {
			idempotency_key: "33333333-3333-4333-8333-333333333333",
			expected_version: 0,
			owner_confirmed: false,
			traits: [{ trait_key: "social_energy", value: "ambiverted" }],
		});
		expect(response.status).toBe(400);
		expect(supabase.rpcCalls).toEqual([]);
	});

	it("maps a stale baseline to conflict without exposing database details", async () => {
		const { response } = await request(
			MEETUP_ID + "/confirm",
			"POST",
			{
				idempotency_key: "33333333-3333-4333-8333-333333333333",
				expected_version: 0,
				owner_confirmed: true,
				traits: [{ trait_key: "social_energy", value: "ambiverted" }],
			},
			{ confirm: { outcome: "version_conflict" } },
		);
		expect(response.status).toBe(409);
		expect(await response.text()).not.toContain(POISON);
	});

	it("returns the confirmed cumulative persona version and safe idempotent replay marker", async () => {
		const { response, supabase } = await request(
			MEETUP_ID + "/confirm",
			"POST",
			{
				idempotency_key: "33333333-3333-4333-8333-333333333333",
				expected_version: 1,
				owner_confirmed: true,
				traits: [{ trait_key: "favorite_activity", value: "reading" }],
			},
			{
				confirm: {
					outcome: "replayed",
					version: 2,
					confirmed_at: "2026-09-26T01:00:00Z",
					traits: { social_energy: "ambiverted", favorite_activity: "reading" },
				},
			},
		);
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				version: 2,
				confirmed_at: "2026-09-26T01:00:00Z",
				confirmed_traits: { social_energy: "ambiverted", favorite_activity: "reading" },
				replayed: true,
			},
		});
		expect(supabase.rpcCalls[0].name).toBe("confirm_meetup_reflection");
		expect(supabase.rpcCalls[0].args.p_expected_version).toBe(1);
	});
});


describe("synthetic reflection admission", () => {
	const id = "77777777-7777-4777-8777-777777777777";
	function config() { return { ...activeRehearsal("demo-maya-ren"), syntheticTestAdmissionId: id }; }
	function metadata(c: ValidatedRecordingRehearsalConfig) {
		return { outcome: "admitted", admission_id: id, user_a_id: REHEARSAL_REN_ID, user_b_id: c.generationPair[0], match_id: "44444444-4444-4444-8444-444444444444", room_id: "55555555-5555-4555-8555-555555555555", meetup_id: MEETUP_ID, issued_at: c.issuedAt, expires_at: c.expiresAt };
	}
	it("requires private DB admission and selects only dedicated read RPC", async () => {
		const c = config();
		const result = await request(MEETUP_ID, "GET", undefined, { admission: metadata(c) }, {}, c);
		expect(result.response.status).toBe(200);
		expect(result.supabase.rpcCalls.map(call => call.name)).toEqual(["check_synthetic_recording_admission", "demo_recording_get_meetup_reflection_state"]);
		expect(fetchMock).not.toHaveBeenCalled();
	});
	it("missing admission never falls back or fetches provider", async () => {
		const c = config();
		const result = await request(MEETUP_ID + "/bootstrap", "POST", { voice: "marin" }, {}, {}, c);
		expect(result.response.status).not.toBe(200);
		expect(result.supabase.rpcCalls.map(call => call.name)).toEqual(["check_synthetic_recording_admission"]);
		expect(fetchMock).not.toHaveBeenCalled();
	});
	it.each(["future-end", "no-own-completion"])("refuses %s before provider despite valid permit", async (reason) => {
		const c = config(); const past = new Date(Date.now() - 60_000).toISOString();
		const session = { meetup_id: MEETUP_ID, match_id: "44444444-4444-4444-8444-444444444444", room_id: "55555555-5555-4555-8555-555555555555", user_a_id: c.generationPair[0], user_b_id: REHEARSAL_REN_ID, status: "confirmed", confirmed_ends_at: reason === "future-end" ? new Date(Date.now() + 60_000).toISOString() : past, completed_a_at: reason === "no-own-completion" ? null : past, completed_b_at: null };
		const result = await request(MEETUP_ID + "/bootstrap", "POST", { voice: "marin" }, { admission: metadata(c), session }, {}, c);
		expect(result.response.status).not.toBe(200);
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

describe("judge reflection simulation metadata", () => {
  const PEER = "44444444-4444-4444-8444-444444444444";
  async function judgeRead(peer = PEER) {
    const supabase = makeSupabase({ session: { user_a_id: OWNER_ID, user_b_id: peer } });
    mockedGetSupabaseClient.mockReturnValue(supabase as never);
    const app = new Hono<Env>();
    app.use("*", async (c, next) => { c.set("judge_access", { actorId: OWNER_ID, counterpartId: PEER, accountKind: "judge", expiresAtMs: Date.parse("2026-10-13T19:00:00Z") }); await next(); });
    app.route("/api/meetup-reflections", meetupReflections);
    return app.request(`/api/meetup-reflections/${MEETUP_ID}`, {}, { CHAT_MEETUP_ENABLED: "enabled" });
  }
  it("marks only registry pair reflection snapshot", async () => {
    const r = await judgeRead(); expect(r.status).toBe(200); expect(await r.json()).toMatchObject({ data: { simulated_counterpart: true, meetup_id: MEETUP_ID } });
  });
  it("rejects another pair snapshot", async () => {
    expect((await judgeRead(MEETUP_ID)).status).toBe(404);
  });
});


describe("judge reflection voice admission", () => {
 const FIXED_NOW = Date.parse("2026-10-02T00:00:00Z");
 async function voiceRequest(options: {access?: Record<string,unknown>|null; bindings?: Record<string,unknown>; state?:unknown; path?:string; body?:unknown} = {}) {
  vi.spyOn(Date,"now").mockReturnValue(FIXED_NOW);
  const db=makeSupabase({states:[options.state ?? okState(1)]});
  const originalRpc=db.rpc.bind(db);
  const rpc=vi.fn(async(name:string,args:Record<string,unknown>)=>{
   if(name==="reserve_judge_reflection_voice_session")return {error:null,data:{outcome:"allowed",reservation_id:"44444444-4444-4444-8444-444444444444",max_units:20000,max_seconds:180,expires_at:new Date(FIXED_NOW+180000).toISOString()}};
   if(name==="check_judge_access")return {error:null,data:{outcome:"allowed",actor_user_id:OWNER_ID,account_kind:"judge"}};
   return originalRpc(name,args);
  });
  mockedGetSupabaseClient.mockReturnValue({...db,rpc} as never);
  const doFetch=vi.fn(async(_request:Request)=>Response.json({sdp:"v=0\r\na=answer\r\n",max_duration_seconds:180},{status:201}));
  const namespace={idFromName:vi.fn((name:string)=>name),get:vi.fn(()=>({fetch:doFetch}))};
  const app=new Hono<Env>();
  app.use("*",async(c,next)=>{if(options.access!==null)c.set("judge_access",{actorId:OWNER_ID,counterpartId:"55555555-5555-4555-8555-555555555555",accountKind:"judge",expiresAtMs:FIXED_NOW+3600000,...options.access} as never);await next();});
  app.route("/api/meetup-reflections",meetupReflections);
  const response=await app.request(`/api/meetup-reflections/${options.path ?? MEETUP_ID+"/realtime-call"}`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(options.body ?? {sdp:"v=0\r\na=offer\r\n",voice:"marin"})},{CHAT_MEETUP_ENABLED:"enabled",MEETUP_REFLECTION_REALTIME_ENABLED:"enabled",OPENAI_REALTIME_ENABLED:"enabled",OPENAI_API_KEY:"synthetic",JUDGE_REALTIME_CALLS:namespace,...options.bindings} as never);
  return {response,rpc,namespace,doFetch};
 }
 it("dispatches the completed owner's confirmed traits to the reflection namespace",async()=>{
  const f=await voiceRequest();expect(f.response.status).toBe(201);
  expect(f.namespace.idFromName.mock.calls).toEqual([[`reflection:${MEETUP_ID}`]]);
  expect(f.rpc.mock.calls).toContainEqual(["reserve_judge_reflection_voice_session",{p_user_id:OWNER_ID,p_meetup_id:MEETUP_ID,p_idempotency_key:MEETUP_ID}]);
  expect(await f.doFetch.mock.calls[0][0].json()).toMatchObject({kind:"reflection",ownerId:OWNER_ID,sessionId:MEETUP_ID,confirmedTraits:{social_energy:"ambiverted"},language:"en"});
  expect(fetchMock).not.toHaveBeenCalled();
 });
 it.each([{access:null},{access:{actorId:MEETUP_ID}},{access:{expiresAtMs:FIXED_NOW}},{bindings:{CHAT_MEETUP_ENABLED:"disabled"}},{bindings:{MEETUP_REFLECTION_REALTIME_ENABLED:"disabled"}},{bindings:{JUDGE_REALTIME_CALLS:undefined}},{state:{outcome:"not_found"}},{path:"invalid/realtime-call"},{body:{sdp:"bad",voice:"marin"}}])("rejects invalid reflection input or authority before reservation %j",async options=>{
  const f=await voiceRequest(options);expect(f.response.status).not.toBe(201);expect(f.doFetch).not.toHaveBeenCalled();
  expect(f.rpc.mock.calls.some(([name])=>name==="reserve_judge_reflection_voice_session")).toBe(false);expect(fetchMock).not.toHaveBeenCalled();
 });
 it("judge bootstrap returns bounded metadata without a reservation or provider credential",async()=>{
  const f=await voiceRequest({path:MEETUP_ID+"/bootstrap",body:{voice:"marin"}});expect(f.response.status).toBe(200);
  const body=await f.response.json();expect(body).toMatchObject({data:{session_id:MEETUP_ID,mode:"server_bounded",max_duration_seconds:180}});
  expect(JSON.stringify(body)).not.toContain("client_secret");expect(f.doFetch).not.toHaveBeenCalled();
  expect(f.rpc.mock.calls.some(([name])=>name.startsWith("reserve_"))).toBe(false);expect(fetchMock).not.toHaveBeenCalled();
 });
});
