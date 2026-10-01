import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";

const soraProfileID = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";
vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", soraProfileID);
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import {
	isRecordingRehearsalSoraInterviewActive,
	readRecordingRehearsalConfig,
} from "../services/recording-rehearsal";
import speedDating from "./speed-dating";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const sessionID = "20000000-0000-0000-0000-00000000c390";
const personaID = "11000000-0000-0000-0000-00000000c373";
const oldSessionID = "20000000-0000-0000-0000-00000000c381";

function makeAdmission(subwindowRemainingMs = 20 * 60_000) {
	const now = Date.now();
	const result = readRecordingRehearsalConfig({
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 10 * 60_000).toISOString(),
		RECORDING_REHEARSAL_EXPIRES_AT: new Date(now + 60 * 60_000).toISOString(),
		RECORDING_REHEARSAL_PAIR: "sora-ren",
		RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "enabled",
		RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: new Date(now - 5_000).toISOString(),
		RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: new Date(now + subwindowRemainingMs).toISOString(),
	}, now);
	if (result.kind !== "active" || !isRecordingRehearsalSoraInterviewActive(result.config, now)) {
		throw new Error("Expected an active synthetic Sora admission");
	}
	return result.config;
}

function makeApp(admission = makeAdmission()) {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		c.set("recording_rehearsal", admission);
		c.set("production_e2e_read_only", true);
		await next();
	});
	app.route("/api/speed-dating", speedDating);
	return app;
}

function makeRpc() {
	return vi.fn(async () => ({
		data: [{
			session_id: sessionID,
			status: "completed",
			message_count: 2,
			all_sessions_completed: true,
			outcome: "stored",
		}],
		error: null,
	}));
}

function chain(result: unknown) {
	const query: Record<string, unknown> = {};
	for (const method of ["select", "eq", "in"]) query[method] = () => query;
	query.maybeSingle = () => Promise.resolve({ data: result, error: null });
	query.insert = () => { throw new Error("unexpected direct session insert"); };
	return query;
}

function validOwner() {
	return {
		conversation_language: "ja",
		age_verified_at: "2026-09-26T20:00:00.000Z",
		onboarding_settings_completed_at: "2026-09-26T20:00:00.000Z",
	};
}

function validSession(id = sessionID) {
	return {
		id,
		user_id: soraProfileID,
		persona_id: personaID,
		status: "active",
		personas: {
			id: personaID,
			user_id: soraProfileID,
			persona_type: "virtual_discovery",
			name: "Synthetic persona",
			compiled_document: "synthetic persona fixture",
		},
	};
}

function makeBootstrapSupabase(options: {
	claim?: { data: unknown; error: unknown };
	sessions?: unknown[];
	owners?: unknown[];
} = {}) {
	let ownerCalls = 0;
	let sessionCalls = 0;
	const rpc = vi.fn(async (name: string) => {
		if (name !== "issue_sora_recording_interview_token") throw new Error("unexpected RPC");
		return options.claim ?? { data: true, error: null };
	});
	return {
		rpc,
		from(table: string) {
			if (table === "user_profiles") {
				const owner = options.owners?.[ownerCalls] ?? validOwner();
				ownerCalls += 1;
				return chain(owner);
			}
			if (table === "speed_dating_sessions") {
				const result = options.sessions?.[sessionCalls] ?? validSession();
				sessionCalls += 1;
				return chain(result);
			}
			throw new Error(`unexpected table ${table}`);
		},
	};
}

const fetchMock = vi.fn();

function providerEnv() {
	return {
		OPENAI_REALTIME_ENABLED: "enabled",
		OPENAI_API_KEY: "synthetic-test-key",
	} as never;
}

async function bootstrap(app: Hono<Env>, id = sessionID) {
	return app.request(`/api/speed-dating/sessions/${id}/realtime-bootstrap`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ voice: "cedar" }),
	}, providerEnv());
}

async function createSession(rpc: ReturnType<typeof vi.fn>) {
	const app = makeApp();
	const supabase = {
		rpc,
		from(table: string) {
			if (table === "personas") {
				return chain({ id: personaID, compiled_document: "synthetic persona fixture", name: "Synthetic persona" });
			}
			throw new Error(`unexpected table ${table}`);
		},
	};
	mockedGetSupabaseClient.mockReturnValue(supabase as never);
	return app.request("/api/speed-dating/sessions", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ persona_id: personaID }),
	}, {});
}

async function complete(body?: unknown) {
	const app = makeApp();
	return app.request(`/api/speed-dating/sessions/${sessionID}/complete`, {
		method: "POST",
		headers: body === undefined ? undefined : { "Content-Type": "application/json" },
		body: body === undefined ? undefined : JSON.stringify(body),
	}, {});
}

beforeEach(() => {
	vi.restoreAllMocks();
	vi.stubGlobal("fetch", fetchMock);
	fetchMock.mockResolvedValue(Response.json({
		value: "ek_synthetic",
		expires_at: Math.floor(Date.now() / 1000) + 120,
		session: { type: "realtime", model: "gpt-realtime-2.1-mini" },
	}));
});

afterEach(() => vi.unstubAllGlobals());

describe("Sora interview admission routes", () => {
	it("creates the missing interview through the atomic reservation RPC", async () => {
		const rpc = vi.fn(async () => ({
			data: [{ session_id: sessionID, persona_id: personaID, outcome: "reserved" }],
			error: null,
		}));

		const response = await createSession(rpc);

		expect(response.status).toBe(200);
		expect(rpc).toHaveBeenCalledWith("reserve_sora_recording_interview", expect.objectContaining({
			p_user_id: soraProfileID,
			p_persona_id: personaID,
		}));
	});

	it("maps nullable fail-closed reservation outcomes to conflict", async () => {
		const rpc = vi.fn(async () => ({
			data: [{ session_id: null, persona_id: personaID, outcome: "not_eligible" }],
			error: null,
		}));

		const response = await createSession(rpc);

		expect(response.status).toBe(409);
		expect(await response.text()).toContain("review the saved interview status");
	});

	it("rejects a malformed failure row without a persona ID", async () => {
		const rpc = vi.fn(async () => ({
			data: [{ session_id: null, persona_id: null, outcome: "not_eligible" }],
			error: null,
		}));

		const response = await createSession(rpc);

		expect(response.status).toBe(503);
	});

	it("does not look up or mint a provider secret when the DB rejects an old session ID", async () => {
		const supabase = makeBootstrapSupabase({ claim: { data: false, error: null }, sessions: [validSession(oldSessionID)] });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		const app = makeApp();

		const response = await bootstrap(app, oldSessionID);

		expect(response.status).toBe(403);
		expect(supabase.rpc).toHaveBeenCalledWith("issue_sora_recording_interview_token", expect.objectContaining({
			p_session_id: oldSessionID,
		}));
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("requires six minutes before claiming a token", async () => {
		const supabase = makeBootstrapSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		const app = makeApp(makeAdmission(5 * 60_000 + 59_000));

		const response = await bootstrap(app);

		expect(response.status).toBe(403);
		expect(supabase.rpc).not.toHaveBeenCalled();
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("claims once before calling the OpenAI secret endpoint", async () => {
		const events: string[] = [];
		const supabase = makeBootstrapSupabase();
		supabase.rpc.mockImplementation(async () => {
			events.push("claim");
			return events.filter((event) => event === "claim").length === 1
				? { data: true, error: null }
				: { data: false, error: null };
		});
		mockedGetSupabaseClient.mockReturnValue(supabase as never);
		fetchMock.mockImplementation(async () => {
			events.push("provider");
			return Response.json({
				value: "ek_synthetic",
				expires_at: Math.floor(Date.now() / 1000) + 120,
				session: { type: "realtime", model: "gpt-realtime-2.1-mini" },
			});
		});
		const app = makeApp();

		const first = await bootstrap(app);
		const second = await bootstrap(app);

		expect(first.status).toBe(200);
		expect(second.status).toBe(403);
		expect(events).toEqual(["claim", "provider", "claim"]);
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});
});

describe("Sora native interview completion", () => {
	it.each([
		["omitted transcript", undefined],
		["only user speech", { transcript: [{ source: "user", message: "synthetic user utterance" }] }],
		["only AI speech", { transcript: [{ source: "ai", message: "synthetic AI utterance" }] }],
		["blank AI speech", { transcript: [
			{ source: "user", message: "synthetic user utterance" },
			{ source: "ai", message: "  " },
		] }],
	] as const)("rejects %s before the privileged completion RPC", async (_label, body) => {
		const rpc = makeRpc();
		mockedGetSupabaseClient.mockReturnValue({ rpc } as never);

		const response = await complete(body);

		expect(response.status).toBe(400);
		expect(rpc).not.toHaveBeenCalled();
	});

	it("requires both speaker transcripts and calls only the Sora-bound completion wrapper", async () => {
		const rpc = makeRpc();
		mockedGetSupabaseClient.mockReturnValue({ rpc } as never);
		const transcript = [
			{ source: "user", message: "synthetic user utterance" },
			{ source: "ai", message: "synthetic AI utterance" },
		];

		const response = await complete({ transcript });

		expect(response.status).toBe(200);
		expect(rpc).toHaveBeenCalledWith("complete_sora_recording_interview", expect.objectContaining({
			p_session_id: sessionID,
			p_user_id: soraProfileID,
			p_transcript: transcript,
		}));
	});
	it("rejects an admitted owner locale changing during provider fetch", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeBootstrapSupabase({ owners: [validOwner(), {...validOwner(), conversation_language: "en"}] }) as never);
		const response = await bootstrap(makeApp());
		expect(response.status).toBe(503);
		expect(await response.text()).not.toContain("ek_synthetic");
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});
	it("rejects an admitted session completing during provider fetch", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeBootstrapSupabase({ sessions: [validSession(), {...validSession(), status: "completed"}] }) as never);
		const response = await bootstrap(makeApp());
		expect(response.status).toBe(503);
		expect(await response.text()).not.toContain("ek_synthetic");
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});
	it.each([301, 401, 429, 500])("does not leak admitted provider failure %s", async status => {
		const poison = "POISONED_BODY POISONED_KEY POISONED_TOKEN";
		vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(makeBootstrapSupabase() as never);
		fetchMock.mockResolvedValue(new Response(poison, {status}));
		const response = await bootstrap(makeApp());
		expect(response.status).toBe(503);
		expect(await response.text()).not.toContain(poison);
		expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain(poison);
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});
	it.each([
		{value: "sk_invalid", expires_at: 0},
		{value: "ek_synthetic", expires_at: 1},
		{value: "ek_synthetic", expires_at: 999999999999},
	])("rejects admitted invalid credential envelope %j", async invalid => {
		mockedGetSupabaseClient.mockReturnValue(makeBootstrapSupabase() as never);
		fetchMock.mockResolvedValue(Response.json({...invalid, session: {type: "realtime", model: "gpt-realtime-2.1-mini"}}));
		expect((await bootstrap(makeApp())).status).toBe(503);
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

});
