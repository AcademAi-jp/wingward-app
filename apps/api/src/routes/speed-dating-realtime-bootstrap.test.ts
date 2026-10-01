import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "synthetic-user");
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));
import { getSupabaseClient } from "../db/client";
import speedDating from "./speed-dating";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const sessionId = "22222222-2222-4222-8222-222222222222";
const personaId = "33333333-3333-4333-8333-333333333333";
const ownerTimestamp = "2026-09-06T00:00:00.000Z";
const POISON = "POISONED_MESSAGE body=POISONED_BODY key=POISONED_KEY token=POISONED_TOKEN";

function validOwner(language: "ja" | "en" = "ja"): Record<string, unknown> {
	return {
		conversation_language: language,
		age_verified_at: ownerTimestamp,
		onboarding_settings_completed_at: ownerTimestamp,
		// These fields must never cross the provider boundary.
		preferred_genders: [POISON],
		station_id: POISON,
	};
}

function validPersona(): Record<string, unknown> {
	return {
		id: personaId,
		user_id: "synthetic-user",
		persona_type: "virtual_similar",
		name: "Sakura",
		compiled_document: "gender: male\n## Core Identity\nA calm reference.",
	};
}

function validSession(status: "active" | "completed" = "active"): Record<string, unknown> {
	return {
		id: sessionId,
		user_id: "synthetic-user",
		persona_id: personaId,
		status,
		personas: validPersona(),
	};
}

function chain(result: unknown, rejection?: unknown) {
	const query: Record<string, unknown> = {};
	for (const method of ["select", "eq"]) query[method] = () => query;
	query.maybeSingle = () => rejection === undefined
		? Promise.resolve(result)
		: Promise.reject(rejection);
	return query;
}

type SupabaseFixtureOptions = {
	owners?: Array<{ data: unknown; error?: unknown }>;
	sessions?: Array<{ data: unknown; error?: unknown }>;
	ownerThrows?: Array<unknown | undefined>;
	sessionThrows?: Array<unknown | undefined>;
};

function makeSupabase(options: SupabaseFixtureOptions = {}) {
	const owners = options.owners ?? [{ data: validOwner() }, { data: validOwner() }];
	const sessions = options.sessions ?? [{ data: validSession() }, { data: validSession() }];
	let ownerCalls = 0;
	let sessionCalls = 0;
	return {
		from(table: string) {
			if (table === "user_profiles") {
				const index = Math.min(ownerCalls++, owners.length - 1);
				const result = owners[index] ?? { data: null };
				return chain(result, options.ownerThrows?.[index]);
			}
			if (table === "speed_dating_sessions") {
				const index = Math.min(sessionCalls++, sessions.length - 1);
				const result = sessions[index] ?? { data: null };
				return chain(result, options.sessionThrows?.[index]);
			}
			throw new Error(`unexpected table ${table}`);
		},
	};
}


const fetchMock = vi.fn();
beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  fetchMock.mockResolvedValue(Response.json({ value: "ek_synthetic", expires_at: Math.floor(Date.now()/1000)+120, session: {type: "realtime", model: "gpt-realtime-2.1-mini"} }));
  vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); fetchMock.mockReset(); });
async function request(voice: unknown = "cedar", options: SupabaseFixtureOptions = {}, bindings: Record<string, unknown> = {}) {
  mockedGetSupabaseClient.mockReturnValue(makeSupabase(options) as never);
  const app = new Hono<Env>();
  app.route("/api/speed-dating", speedDating);
  return app.request(`/api/speed-dating/sessions/${sessionId}/realtime-bootstrap`, {
    method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({voice})
  }, {OPENAI_REALTIME_ENABLED:"enabled", OPENAI_API_KEY:"synthetic-test-key", ...bindings} as never);
}
describe("Realtime bootstrap", () => {
  it.each(["cedar", "marin", "ash"])("does not mint unreserved ordinary %s credentials", async voice => {
    const response = await request(voice);
    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.text()).not.toContain("synthetic-test-key");
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it("fails closed on repeated concurrent requests for an owned active session", async () => {
    const responses = await Promise.all(Array.from({length: 12}, () => request()));
    expect(responses.every(response => response.status === 503)).toBe(true);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it("also blocks saved English locale before provider calls", async () => {
    expect((await request("marin", {owners:[{data:validOwner("en")}] })).status).toBe(503);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it.each([null, "", "voice-clone", {}, 123])("rejects unsupported voice %j before provider calls", async voice => {
    expect((await request(voice)).status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it.each([{OPENAI_REALTIME_ENABLED:undefined}, {OPENAI_API_KEY:undefined}])("fails closed without operator setup", async bindings => {
    expect((await request("cedar", {}, bindings)).status).toBe(503);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it.each([
    {owners:[{data:null}]},
    {owners:[{data:{...validOwner(), age_verified_at:null}}]},
    {sessions:[{data:validSession("completed")}]},
    {sessions:[{data:{...validSession(), user_id:"another-owner"}}]},
    {sessions:[{data:{...validSession(), personas:{...validPersona(),user_id:"another-owner"}}}]},
  ])("does not mint a credential for an unauthorized session", async fixture => {
    expect((await request("cedar", fixture)).status).toBeGreaterThanOrEqual(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
