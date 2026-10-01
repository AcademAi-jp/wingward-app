import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("./mistral", () => ({ chatComplete: vi.fn() }));

import { chatComplete } from "./mistral";
import { scoreInteractionDna } from "./interaction-dna";

const mockedChatComplete = vi.mocked(chatComplete);

function chain(result: { data: unknown; error: unknown }) {
	const query: Record<string, unknown> = {};
	for (const method of ["select", "eq", "in", "order", "limit"]) query[method] = () => query;
	query.then = (resolve: (value: typeof result) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve(result).then(resolve, reject);
	return query;
}

function makeSupabase(failure: "sessions" | "personas" | "messages") {
	const calls: string[] = [];
	const client = {
		from(table: string) {
			calls.push(table);
			if (table === "speed_dating_sessions") {
				return chain({
					data: [{ id: "s1", persona_id: "p1" }, { id: "s2", persona_id: "p2" }, { id: "s3", persona_id: "p3" }],
					error: failure === "sessions" ? { message: "PWNED-CANARY-SESSIONS" } : null,
				});
			}
			if (table === "personas") {
				return chain({ data: [], error: failure === "personas" ? { message: "PWNED-CANARY-PERSONAS" } : null });
			}
			if (table === "speed_dating_messages") {
				return chain({ data: [], error: failure === "messages" ? { message: "PWNED-CANARY-MESSAGES" } : null });
			}
			throw new Error(`unexpected table ${table}`);
		},
	};
	return { client, calls };
}

beforeEach(() => {
	vi.restoreAllMocks();
});

describe("scoreInteractionDna Supabase failures", () => {
	it.each(["sessions", "personas", "messages"] as const)("stops before the paid AI call when the %s read fails", async (failure) => {
		const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});

		const supabase = makeSupabase(failure);
		const result = await scoreInteractionDna(supabase.client as never, "user-1", "test-key", "en");

		expect(result).toBeNull();
		expect(mockedChatComplete).not.toHaveBeenCalled();
		expect(supabase.calls).toEqual({
			sessions: ["speed_dating_sessions"],
			personas: ["speed_dating_sessions", "personas"],
			messages: ["speed_dating_sessions", "personas", "speed_dating_messages"],
		}[failure]);
		expect(consoleError.mock.calls.flat().join(" ")).not.toMatch(/PWNED-CANARY/);
	});
});
