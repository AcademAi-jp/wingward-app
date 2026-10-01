import { Hono } from "hono";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "user-1");
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));
vi.mock("../services/mistral", () => ({ chatComplete: vi.fn() }));
vi.mock("../lib/fox-icons", () => ({ getRandomIconUrlForGender: vi.fn(() => "/fox.png") }));

import { getSupabaseClient } from "../db/client";
import { chatComplete } from "../services/mistral";
import speedDating from "./speed-dating";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const mockedChatComplete = vi.mocked(chatComplete);

const GENERATED = [
	"name: Sakura",
	"gender: female",
	"## Core Identity",
	"A calm listener.",
].join("\n");
const POISON = "POISONED_MESSAGE body=POISONED_BODY key=POISONED_KEY";

function chain(result: unknown) {
	const query: Record<string, unknown> = {};
	for (const method of ["select", "eq", "upsert", "maybeSingle", "single"]) query[method] = () => query;
	query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve(result).then(resolve, reject);
	return query;
}

function makeSupabase(failure?: { table: "user_profiles" | "quiz_answers" | "personas" | "persona_sections"; statusCode: number }) {
	let personaID = 0;
	return {
		from(table: string) {
			if (table === "user_profiles") {
				return chain({
					data: { conversation_language: "en", age_verified_at: "2026-08-24T00:00:00Z", onboarding_settings_completed_at: "2026-08-24T00:00:00Z" },
					error: failure?.table === table ? { statusCode: failure.statusCode, message: POISON } : null,
				});
			}
			if (table === "quiz_answers") {
				return chain({
					data: [{ question_id: "q1", selected: ["a1"] }],
					error: failure?.table === table ? { statusCode: failure.statusCode, body: POISON } : null,
				});
			}
			if (table === "personas") {
				personaID += 1;
				return chain({
					data: failure?.table === table ? null : { id: `persona-${personaID}` },
					error: failure?.table === table ? { statusCode: failure.statusCode, key: POISON } : null,
				});
			}
			if (table === "persona_sections") {
				return chain({
					data: null,
					error: failure?.table === table ? { statusCode: failure.statusCode, message: POISON } : null,
				});
			}
			throw new Error(`unexpected table ${table}`);
		},
	};
}

function buildApp(activeE2E = false) {
	const app = new Hono<Env>();
	app.use("*", async (c, next) => {
		if (activeE2E) c.set("production_e2e_active", true);
		await next();
	});
	app.route("/api/speed-dating", speedDating);
	return app;
}

async function postPersonas(options: {
	activeE2E?: boolean;
	failure?: { table: "user_profiles" | "quiz_answers" | "personas" | "persona_sections"; statusCode: number };
	} = {}) {
	mockedGetSupabaseClient.mockReturnValue(makeSupabase(options.failure) as never);
	return buildApp(options.activeE2E).request(
		"/api/speed-dating/personas",
		{ method: "POST" },
		{ MISTRAL_API_KEY: "test-key" },
	);
}

describe("POST /api/speed-dating/personas safe diagnostics", () => {
	let consoleErrorSpy: ReturnType<typeof vi.spyOn>;

	beforeEach(() => {
		vi.clearAllMocks();
		mockedChatComplete.mockResolvedValue(GENERATED);
		consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
	});

	afterEach(() => {
		consoleErrorSpy.mockRestore();
	});

	it.each([401, 429])("attributes numeric Mistral status %s without exposing provider data", async (statusCode) => {
		mockedChatComplete.mockRejectedValueOnce({ statusCode, message: POISON, body: POISON, key: POISON });
		const response = await postPersonas({ activeE2E: true });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).toContain("AI session unavailable");
		expect(body).not.toContain(POISON);
		expect(response.headers.get("X-Wingward-E2E-Stage")).toBe("mistral_request");
		expect(response.headers.get("X-Wingward-E2E-Upstream-Status")).toBe(String(statusCode));
		expect(consoleErrorSpy).toHaveBeenCalledWith(`[wingward/persona-generation] stage=mistral_request status=${statusCode} kind=unknown`);
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	it("uses status zero for an unknown error and keeps diagnostics off without the active gate", async () => {
		mockedChatComplete.mockRejectedValueOnce({ statusCode: 600, message: POISON, body: POISON, key: POISON });
		const response = await postPersonas();
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain(POISON);
		expect(response.headers.has("X-Wingward-E2E-Stage")).toBe(false);
		expect(response.headers.has("X-Wingward-E2E-Upstream-Status")).toBe(false);
		expect(consoleErrorSpy).toHaveBeenCalledWith("[wingward/persona-generation] stage=mistral_request status=0 kind=unknown");
		expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain(POISON);
	});

	it.each([
		["user_profiles", "owner_lookup"],
		["quiz_answers", "answers_lookup"],
		["personas", "persona_persist"],
		["persona_sections", "section_persist"],
	] as const)("attributes %s persistence/lookup failures by fixed stage", async (table, stage) => {
		const response = await postPersonas({ activeE2E: true, failure: { table, statusCode: 401 } });
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain(POISON);
		expect(response.headers.get("X-Wingward-E2E-Stage")).toBe(stage);
		expect(response.headers.get("X-Wingward-E2E-Upstream-Status")).toBe("401");
		expect(consoleErrorSpy).toHaveBeenCalledWith(`[wingward/persona-generation] stage=${stage} status=401 kind=unknown`);
	});

  it("starts all three generation calls before waiting for any response", async () => {
    const resolvers: ((value: string) => void)[] = [];
    mockedChatComplete.mockImplementation(() => new Promise(resolve => resolvers.push(resolve)));
    const response = postPersonas({ activeE2E: true });
    await vi.waitFor(() => expect(resolvers).toHaveLength(3));
    resolvers.forEach(resolve => resolve(GENERATED));
    expect((await response).status).toBe(200);
  });

	it("preserves the successful three-persona response without diagnostics", async () => {
		const response = await postPersonas({ activeE2E: true });
		const body = (await response.json()) as { data: Array<{ persona_type: string; name: string }> };

		expect(response.status).toBe(200);
		expect(body.data).toHaveLength(3);
		expect(body.data.map((persona) => persona.persona_type)).toEqual([
			"virtual_similar",
			"virtual_complementary",
			"virtual_discovery",
		]);
		expect(body.data.every((persona) => persona.name === "Sakura")).toBe(true);
		expect(response.headers.has("X-Wingward-E2E-Stage")).toBe(false);
		expect(consoleErrorSpy).not.toHaveBeenCalled();
		expect(mockedChatComplete).toHaveBeenCalledTimes(3);
	});
});
