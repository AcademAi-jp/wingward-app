import { describe, expect, it } from "vitest";
import { loadSoraProfileRevisionInputs } from "./sora-profile-revision-inputs";

const ownerId = "d327a193-9eeb-42b1-bac4-fb5bea3ca21f";
const sessions = [
	{ id: "20000000-0000-0000-0000-00000000c001", persona_id: "11000000-0000-0000-0000-00000000c001", completed_at: "2026-09-29T03:00:00Z" },
	{ id: "20000000-0000-0000-0000-00000000c002", persona_id: "11000000-0000-0000-0000-00000000c002", completed_at: "2026-09-29T02:00:00Z" },
	{ id: "20000000-0000-0000-0000-00000000c003", persona_id: "11000000-0000-0000-0000-00000000c003", completed_at: "2026-09-29T01:00:00Z" },
];
const personas = [
	{ id: sessions[0]!.persona_id, user_id: ownerId, persona_type: "virtual_similar" },
	{ id: sessions[1]!.persona_id, user_id: ownerId, persona_type: "virtual_complementary" },
	{ id: sessions[2]!.persona_id, user_id: ownerId, persona_type: "virtual_discovery" },
];
const messagesBySession = new Map(sessions.map((session) => [session.id, [
	{ role: "user", content: "Synthetic user line one." },
	{ role: "persona", content: "Synthetic persona line one." },
	{ role: "user", content: "Synthetic user line two." },
	{ role: "persona", content: "Synthetic persona line two." },
]]));

type FixtureOverrides = {
	answers?: unknown[];
	sessions?: unknown[];
	personas?: unknown[];
	messagesBySession?: Map<string, unknown[]>;
};

function fakeSupabase(overrides: FixtureOverrides = {}) {
	return {
		from(table: string) {
			const filters: Record<string, unknown> = {};
			const query: Record<string, unknown> = {
				select: () => query,
				eq: (column: string, value: unknown) => { filters[column] = value; return query; },
				in: (column: string, values: unknown) => { filters[column] = values; return query; },
				order: () => query,
				limit: () => query,
				then: (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => {
					let data: unknown[];
					if (table === "quiz_answers") data = overrides.answers ?? [{ question_id: "q1", selected: ["thoughtful", "kind"] }];
					else if (table === "speed_dating_sessions") data = overrides.sessions ?? sessions;
					else if (table === "personas") data = overrides.personas ?? personas;
					else if (table === "speed_dating_messages") data = overrides.messagesBySession?.get(String(filters.session_id)) ?? messagesBySession.get(String(filters.session_id)) ?? [];
					else throw new Error(`unexpected synthetic table: ${table}`);
					return Promise.resolve({ data, error: null }).then(resolve, reject);
				},
			};
			return query;
		},
	} as never;
}

describe("bounded inputs for Sora three-interview revision", () => {
	it("loads and freezes exactly three owner-owned virtual interviews for both prompts", async () => {
		const result = await loadSoraProfileRevisionInputs(fakeSupabase() as never, ownerId);
		expect(result.sessionIds).toEqual(sessions.map((session) => session.id));
		expect(result.sessions.map((session) => session.personaType)).toEqual([
			"virtual_similar", "virtual_complementary", "virtual_discovery",
		]);
		expect(result.sessions.every((session) => session.messages.length === 4)).toBe(true);
		expect(result.conversationLogs).toContain("Interview 1 (virtual_similar)");
		expect(result.conversationLogs).not.toContain(sessions[0]!.id);
		expect(JSON.parse(result.quizText)).toEqual([{ question_id: "q1", selected: ["thoughtful", "kind"] }]);
	});

	it("rejects wrong-count sessions and persona ownership before producing prompts", async () => {
		await expect(loadSoraProfileRevisionInputs(fakeSupabase({ sessions: sessions.slice(0, 2) }) as never, ownerId))
			.rejects.toThrow(/exactly three/);
		const foreignPersonas = personas.map((persona, index) => index === 2 ? { ...persona, user_id: "10000000-0000-0000-0000-000000000001" } : persona);
		await expect(loadSoraProfileRevisionInputs(fakeSupabase({ personas: foreignPersonas }) as never, ownerId))
			.rejects.toThrow(/ownership/);
	});

	it("rejects quiz answers outside the existing stored-answer schema", async () => {
		await expect(loadSoraProfileRevisionInputs(fakeSupabase({ answers: [{ question_id: "q1", selected: [] }] }) as never, ownerId))
			.rejects.toThrow(/quiz input is invalid/);
	});

	it("requires nonblank user and persona messages in each interview", async () => {
		const changed = new Map(messagesBySession);
		changed.set(sessions[1]!.id, [
			{ role: "user", content: "   " },
			{ role: "persona", content: "Synthetic persona line." },
			{ role: "persona", content: "More synthetic persona." },
			{ role: "persona", content: "Still synthetic." },
		]);
		await expect(loadSoraProfileRevisionInputs(fakeSupabase({ messagesBySession: changed }) as never, ownerId))
			.rejects.toThrow(/both sides/);
	});
});
