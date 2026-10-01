import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "user-1");
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));
vi.mock("../services/mistral", () => ({
	chatComplete: vi.fn(async () => "fox reply"),
	MISTRAL_SMALL: "small-test",
	MISTRAL_LARGE: "large-test",
}));

import { getSupabaseClient } from "../db/client";
import { chatComplete } from "../services/mistral";
import speedDating from "./speed-dating";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const mockedChatComplete = vi.mocked(chatComplete);
type Failure = "session" | "persona" | "user_insert" | "history" | "fox_insert" | "count_read" | "count_update" | "ai";

function makeSupabase(failure: Failure) {
	let sessionCalls = 0;
	let messageCalls = 0;
	const deletedIds: string[] = [];
	function makeChain(result: unknown) {
		const query: Record<string, unknown> = {};
		for (const method of ["select", "eq", "order", "maybeSingle", "single", "insert", "update"]) query[method] = () => query;
		query.delete = () => query;
		query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve(result).then(resolve, reject);
		return query;
	}
	return {
		deletedIds,
		from(table: string) {
			if (table === "user_profiles") {
				return makeChain({
					data: {
						conversation_language: "ja",
						age_verified_at: "2026-08-24T00:00:00Z",
						onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
					},
					error: null,
				});
			}
			if (table === "speed_dating_sessions") {
				sessionCalls += 1;
				if (sessionCalls === 1) return makeChain({ data: failure === "session" ? null : { id: "session-1", persona_id: "persona-1" }, error: failure === "session" ? { message: "canary" } : null });
				if (sessionCalls === 2) return makeChain({ data: failure === "count_read" ? null : { message_count: 2 }, error: failure === "count_read" ? { message: "canary" } : null });
				return makeChain({ data: null, error: failure === "count_update" ? { message: "canary" } : null });
			}
			if (table === "personas") {
				return makeChain({ data: failure === "persona" ? null : { compiled_document: "## profile\nJapanese" }, error: failure === "persona" ? { message: "canary" } : null });
			}
			if (table === "speed_dating_messages") {
				messageCalls += 1;
				const normalResult = messageCalls === 1
					? { data: null, error: failure === "user_insert" ? { message: "canary" } : null }
					: messageCalls === 2
						? { data: failure === "history" ? null : [{ role: "user", content: "hello" }], error: failure === "history" ? { message: "canary" } : null }
						: { data: failure === "fox_insert" ? null : { id: "fox-message", role: "persona", content: "fox reply", created_at: "now" }, error: failure === "fox_insert" ? { message: "canary" } : null };
				let deleting = false;
				const query = makeChain(normalResult) as Record<string, unknown>;
				query.delete = () => {
					deleting = true;
					query.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve({ data: null, error: null }).then(resolve, reject);
					return query;
				};
				query.eq = (_column: string, value: string) => {
					if (deleting) deletedIds.push(value);
					return query;
				};
				return query;
			}
			throw new Error(`unexpected table ${table}`);
		},
	};
}

function postMessage(supabase: ReturnType<typeof makeSupabase>) {
	mockedGetSupabaseClient.mockReturnValue(supabase as never);
	const app = new Hono();
	app.route("/api/speed-dating", speedDating);
	return app.request("/api/speed-dating/sessions/session-1/messages", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ content: "hello" }),
	}, { MISTRAL_API_KEY: "test-key" });
}

beforeEach(() => {
	vi.restoreAllMocks();
	mockedChatComplete.mockResolvedValue("fox reply");
});

describe("POST /api/speed-dating/sessions/:id/messages Supabase failures", () => {
	it.each(["session", "persona", "user_insert", "history", "fox_insert", "count_read", "count_update", "ai"] as const)(
		"fails closed and compensates partial messages when %s fails",
		async (failure) => {
			const supabase = makeSupabase(failure);
			if (failure === "ai") mockedChatComplete.mockRejectedValueOnce(new Error("canary"));
			const response = await postMessage(supabase);
			const body = await response.text();
			expect(response.status).toBe(500);
			expect(body).not.toContain("canary");
			if (["history", "fox_insert", "count_read", "count_update", "ai"].includes(failure)) {
				expect(supabase.deletedIds.length).toBeGreaterThan(0);
			}
		},
	);
});
