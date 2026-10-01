import { beforeEach, describe, expect, it, vi } from "vitest";
import {
	createMeetupReflectionService,
	createMistralReflectionDraftProvider,
	parseReflectionConfirmation,
	reflectionStatementsSchema,
	type ReflectionStore,
} from "./meetup-reflection";

const USER_ID = "11111111-1111-4111-8111-111111111111";
const MEETUP_ID = "22222222-2222-4222-8222-222222222222";
const KEY = "33333333-3333-4333-8333-333333333333";

function stateResult(version = 0) {
	return {
		data: {
			outcome: "ok",
			current_version: version,
			traits: version === 0 ? {} : { social_energy: "ambiverted", priority_value: "community" },
			confirmed_at: version === 0 ? null : "2026-09-26T01:00:00Z",
		},
		error: null,
	};
}

function makeStore(overrides: Partial<ReflectionStore> = {}): ReflectionStore {
	return {
		readState: vi.fn(async () => stateResult()),
		confirm: vi.fn(async () => ({
			data: {
				outcome: "confirmed",
				version: 1,
				confirmed_at: "2026-09-26T01:00:00Z",
				traits: { social_energy: "ambiverted" },
			},
			error: null,
		})),
		...overrides,
	};
}

describe("meetup reflection service", () => {
	beforeEach(() => vi.clearAllMocks());

	it.each([0, 1])("accepts a single table-RPC row for reflection version %s", async (version) => {
		const result = stateResult(version);
		const store = makeStore({ readState: vi.fn(async () => ({ ...result, data: [result.data] })) });
		const state = await createMeetupReflectionService(store, null).readState(USER_ID, MEETUP_ID);
		expect(state.ok).toBe(true);
		if (state.ok) expect(state.data.current_persona_version).toBe(version);
	});

	it.each([[], [{}, {}], [null], [[{}]]].map(data => ({ data })))("rejects empty, multiple, or invalid table-RPC rows $data", async ({ data }) => {
		const store = makeStore({ readState: vi.fn(async () => ({ data, error: null })) });
		expect(await createMeetupReflectionService(store, null).readState(USER_ID, MEETUP_ID)).toEqual({ ok: false, reason: "internal" });
	});

	it("maps a single not-found table-RPC row without exposing details", async () => {
		const store = makeStore({ readState: vi.fn(async () => ({ data: [{ outcome: "not_found" }], error: null })) });
		expect(await createMeetupReflectionService(store, null).readState(USER_ID, MEETUP_ID)).toEqual({ ok: false, reason: "not_found" });
	});

	it("bounds self-statements before sending them to a draft provider", () => {
		expect(reflectionStatementsSchema.safeParse([{ turn_id: "u1", text: "I like a slower pace." }]).success).toBe(true);
		expect(reflectionStatementsSchema.safeParse(new Array(25).fill({ turn_id: "u", text: "x" })).success).toBe(false);
		expect(reflectionStatementsSchema.safeParse([{ turn_id: "u1", text: "x", speaker: "peer" }]).success).toBe(false);
		expect(reflectionStatementsSchema.safeParse([{ turn_id: "u1", text: "x" }, { turn_id: "u1", text: "y" }]).success).toBe(false);
		expect(reflectionStatementsSchema.safeParse(Array.from({ length: 16 }, (_, index) => ({
			turn_id: "u" + index,
			text: "x".repeat(550),
		}))).success).toBe(false);
	});

	it("labels generated traits as drafts and keeps them ephemeral", async () => {
		const store = makeStore();
		const generate = vi.fn(async ({ statements }: { statements: Array<{ turn_id: string; text: string }> }) => {
			expect(statements).toEqual([{ turn_id: "u1", text: "I like taking time to warm up." }]);
			return {
				candidates: [
					{ trait_key: "social_energy", value: "introverted", source_turn_ids: ["u1"] },
					{ trait_key: "priority_value", value: "learning", source_turn_ids: ["u1"] },
				],
			};
		});
		const service = createMeetupReflectionService(store, { generate });

		const result = await service.createDraft(USER_ID, MEETUP_ID, "en", [
			{ turn_id: "u1", text: "I like taking time to warm up." },
		]);

		expect(result.ok).toBe(true);
		if (result.ok) {
			expect(result.data.expected_version).toBe(0);
			expect(result.data.candidates[0]).toMatchObject({
				trait_key: "social_energy",
				value: "introverted",
				evidence_label: "user_statement",
				confidence_label: "AI draft; not confirmed",
			});
			expect(result.data.candidates[0].candidate_id).toBeTruthy();
		}
		expect(store.readState).toHaveBeenCalledTimes(2);
		expect(store.confirm).not.toHaveBeenCalled();
	});

	it("rejects unsupported values and citations to AI or peer turns", async () => {
		const unsupported = createMeetupReflectionService(makeStore(), {
			generate: async () => ({
				candidates: [{ trait_key: "social_energy", value: "shy", source_turn_ids: ["u1"] }],
			}),
		});
		expect(await unsupported.createDraft(USER_ID, MEETUP_ID, "en", [{ turn_id: "u1", text: "I pause before speaking." }]))
			.toEqual({ ok: false, reason: "unavailable" });

		const ungrounded = createMeetupReflectionService(makeStore(), {
			generate: async () => ({
				candidates: [{ trait_key: "planning_style", value: "planned", source_turn_ids: ["assistant-1"] }],
			}),
		});
		expect(await ungrounded.createDraft(USER_ID, MEETUP_ID, "en", [{ turn_id: "u1", text: "I plan trips." }]))
			.toEqual({ ok: false, reason: "unavailable" });
	});

	it("discards drafts if the baseline changes while generation is running", async () => {
		const store = makeStore({
			readState: vi.fn()
				.mockResolvedValueOnce(stateResult(1))
				.mockResolvedValueOnce(stateResult(2)),
		});
		const service = createMeetupReflectionService(store, {
			generate: async () => ({
				candidates: [{ trait_key: "priority_value", value: "community", source_turn_ids: ["u1"] }],
			}),
		});
		expect(await service.createDraft(USER_ID, MEETUP_ID, "en", [{ turn_id: "u1", text: "Community matters." }]))
			.toEqual({ ok: false, reason: "conflict" });
	});

	it("keeps the ordinary Mistral provider on the existing SDK path", async () => {
		const mistral = await import("./mistral");
		const chatComplete = vi.spyOn(mistral, "chatComplete").mockResolvedValue(JSON.stringify({
			candidates: [{ trait_key: "social_energy", value: "ambiverted", source_turn_ids: ["u1"] }],
		}));
		const fetchMock = vi.fn();
		vi.stubGlobal("fetch", fetchMock);
		try {
			const provider = createMistralReflectionDraftProvider("test-only-key");
			await provider.generate({
				language: "en",
				statements: [{ turn_id: "u1", text: "I enjoy reading." }],
			});
			expect(chatComplete).toHaveBeenCalledOnce();
			expect(fetchMock).not.toHaveBeenCalled();
		} finally {
			vi.unstubAllGlobals();
			chatComplete.mockRestore();
		}
	});

	it("bounds full serialized rehearsal draft messages before consuming an attempt", async () => {
		const fetchMock = vi.fn();
		vi.stubGlobal("fetch", fetchMock);
		const reserveAttempt = vi.fn(() => true);
		try {
			const provider = createMistralReflectionDraftProvider("test-only-key", {
				isActive: () => true,
				reserveAttempt,
			});
			const statements = Array.from({ length: 13 }, (_, index) => ({
				turn_id: "turn-" + index,
				text: "a".repeat(600),
			}));
			await expect(provider.generate({ language: "en", statements })).rejects.toThrow("Reflection draft unavailable");
			expect(reserveAttempt).not.toHaveBeenCalled();
			expect(fetchMock).not.toHaveBeenCalled();
		} finally {
			vi.unstubAllGlobals();
		}
	});

	it("reserves one attempt before the guarded one-fetch provider and drops output after expiry", async () => {
		let active = true;
		const validResponse = () => Response.json({
			choices: [{
				message: { content: JSON.stringify({
					candidates: [{ trait_key: "social_energy", value: "ambiverted", source_turn_ids: ["u1"] }],
				}) },
				finish_reason: "stop",
			}],
			usage: { prompt_tokens: 10, completion_tokens: 8, prompt_tokens_details: {} },
		});
		const fetchMock = vi.fn(async () => {
			active = false;
			return validResponse();
		});
		vi.stubGlobal("fetch", fetchMock);
		const reserveAttempt = vi.fn(() => true);
		try {
			const provider = createMistralReflectionDraftProvider("test-only-key", {
				isActive: () => active,
				reserveAttempt,
			});
			await expect(provider.generate({
				language: "en",
				statements: [{ turn_id: "u1", text: "I enjoy reading." }],
			})).rejects.toThrow("Reflection draft unavailable");
			expect(reserveAttempt).toHaveBeenCalledOnce();
			expect(fetchMock).toHaveBeenCalledOnce();
		} finally {
			vi.unstubAllGlobals();
		}
	});

	it("drops rehearsal draft results when the final private-state await crosses expiry", async () => {
		let active = true;
		const store = makeStore({
			readState: vi.fn()
				.mockResolvedValueOnce(stateResult())
				.mockImplementationOnce(async () => {
					active = false;
					return stateResult();
				}),
		});
		const provider = {
			generate: vi.fn(async () => ({
				candidates: [{ trait_key: "social_energy", value: "ambiverted", source_turn_ids: ["u1"] }],
			})),
		};
		const service = createMeetupReflectionService(store, provider);
		const result = await service.createDraft(
			USER_ID,
			MEETUP_ID,
			"en",
			[{ turn_id: "u1", text: "I enjoy reading." }],
			{ isActive: () => active },
		);
		expect(result).toEqual({ ok: false, reason: "unavailable" });
		expect(store.readState).toHaveBeenCalledTimes(2);
	});

	it("fails closed without a configured draft provider", async () => {
		const service = createMeetupReflectionService(makeStore(), null);
		expect(await service.createDraft(USER_ID, MEETUP_ID, "ja", [{ turn_id: "u1", text: "予定は早めに決めたい。" }]))
			.toEqual({ ok: false, reason: "unavailable" });
	});

	it("requires explicit owner confirmation and unique allowed traits", () => {
		expect(parseReflectionConfirmation({
			idempotency_key: KEY,
			expected_version: 0,
			owner_confirmed: true,
			traits: [{ trait_key: "social_energy", value: "ambiverted" }],
		})).not.toBeNull();
		expect(parseReflectionConfirmation({
			idempotency_key: KEY,
			expected_version: 0,
			owner_confirmed: false,
			traits: [{ trait_key: "social_energy", value: "ambiverted" }],
		})).toBeNull();
		expect(parseReflectionConfirmation({
			idempotency_key: KEY,
			expected_version: 0,
			owner_confirmed: true,
			traits: [
				{ trait_key: "social_energy", value: "ambiverted" },
				{ trait_key: "social_energy", value: "extroverted" },
			],
		})).toBeNull();
		expect(parseReflectionConfirmation({
			idempotency_key: KEY,
			expected_version: 0,
			owner_confirmed: true,
			traits: [{ trait_key: "priority_value", value: "wealth" }],
		})).toBeNull();
	});

	it("sends only selected owner-confirmed enum traits to the atomic CAS RPC", async () => {
		const store = makeStore();
		const service = createMeetupReflectionService(store, null);
		const result = await service.confirm(USER_ID, MEETUP_ID, {
			idempotency_key: KEY,
			expected_version: 0,
			owner_confirmed: true,
			traits: [
				{ trait_key: "social_energy", value: "ambiverted" },
				{ trait_key: "favorite_activity", value: "reading" },
			],
		});

		expect(result.ok).toBe(true);
		expect(store.confirm).toHaveBeenCalledWith({
			userId: USER_ID,
			meetupId: MEETUP_ID,
			idempotencyKey: KEY,
			expectedVersion: 0,
			traits: { social_energy: "ambiverted", favorite_activity: "reading" },
		});
	});

	it("rejects malformed v0 state and malformed confirmed state instead of sanitizing them", async () => {
		for (const data of [
			{ outcome: "ok", current_version: 0, traits: { social_energy: "guess" }, confirmed_at: null },
			{ outcome: "ok", current_version: 1, traits: { social_energy: "guess" }, confirmed_at: null },
		]) {
			const store = makeStore({
				readState: vi.fn(async () => ({ data, error: null })),
			});
			expect(await createMeetupReflectionService(store, null).readState(USER_ID, MEETUP_ID))
				.toEqual({ ok: false, reason: "internal" });
		}
	});
});
