import { describe, expect, it, vi } from "vitest";
import {
	FOX_CONVERSATION_REHEARSAL_MAX_PROMPT_BYTES,
	isFoxConversationGenerationAllowed,
	isFoxConversationPromptWithinRecordingWindow,
	resolveFoxConversationRecordingWindow,
	resolveFoxConversationGenerationWindow,
} from "./fox-conversation-recording-window";
import { RECORDING_REHEARSAL_GENERATION_PAIRS } from "./recording-rehearsal";

const NOW = Date.parse("2026-09-27T02:00:00.000Z");
const [USER_A, USER_B] = RECORDING_REHEARSAL_GENERATION_PAIRS["aoi-ren"];

function activeBindings(overrides: Record<string, string | undefined> = {}) {
	return {
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: new Date(NOW - 60_000).toISOString(),
		RECORDING_REHEARSAL_EXPIRES_AT: new Date(NOW + 60 * 60_000).toISOString(),
		RECORDING_REHEARSAL_PAIR: "aoi-ren",
		...overrides,
	};
}

describe("Fox conversation recording window", () => {
	it("keeps the legacy path only when no rehearsal binding is present", () => {
		const window = resolveFoxConversationRecordingWindow(undefined, "user-a", "user-b", NOW);
		expect(window.kind).toBe("absent");
		expect(isFoxConversationGenerationAllowed(window, "user-a", "user-b", NOW)).toBe(
			isFoxConversationGenerationAllowed(undefined, "user-a", "user-b", NOW),
		);
	});

	it("authorizes only the selected exact pair in either database order", () => {
		const window = resolveFoxConversationRecordingWindow(activeBindings(), USER_A, USER_B, NOW);
		expect(window.kind).toBe("active");
		expect(isFoxConversationGenerationAllowed(window, USER_A, USER_B, NOW)).toBe(true);
		expect(isFoxConversationGenerationAllowed(window, USER_B, USER_A, NOW)).toBe(true);
		expect(resolveFoxConversationRecordingWindow(activeBindings(), USER_A, "other-user", NOW).kind).toBe("invalid");
	});

	it.each([
		["partial", { RECORDING_REHEARSAL_ISSUED_AT: undefined }],
		["disabled", { RECORDING_REHEARSAL_ENABLED: "disabled" }],
		["malformed expiry", { RECORDING_REHEARSAL_EXPIRES_AT: "not-a-date" }],
		["expired", { RECORDING_REHEARSAL_EXPIRES_AT: new Date(NOW - 1).toISOString() }],
		["wrong pair", { RECORDING_REHEARSAL_PAIR: "sora-ren" }],
	])("fails closed for %s bindings", (_label, override) => {
		const window = resolveFoxConversationRecordingWindow(activeBindings(override), USER_A, USER_B, NOW);
		expect(window.kind).toBe("invalid");
		expect(isFoxConversationGenerationAllowed(window, USER_A, USER_B, NOW)).toBe(false);
	});

	it("rechecks expiry on an already-resolved permit without falling back", () => {
		const expiresAt = new Date(NOW + 60_000);
		const window = resolveFoxConversationRecordingWindow(
			activeBindings({ RECORDING_REHEARSAL_EXPIRES_AT: expiresAt.toISOString() }),
			USER_A,
			USER_B,
			NOW,
		);
		expect(window.kind).toBe("active");
		expect(isFoxConversationGenerationAllowed(window, USER_A, USER_B, expiresAt.getTime())).toBe(false);
	});

	it("bounds UTF-8 serialized prompts for rehearsal calls only", () => {
		const window = resolveFoxConversationRecordingWindow(activeBindings(), USER_A, USER_B, NOW);
		expect(isFoxConversationPromptWithinRecordingWindow(
			window,
			USER_A,
			USER_B,
			[{ role: "system", content: "a".repeat(8_000) }],
			NOW,
		)).toBe(true);
		expect(isFoxConversationPromptWithinRecordingWindow(
			window,
			USER_A,
			USER_B,
			[{ role: "system", content: "日".repeat(FOX_CONVERSATION_REHEARSAL_MAX_PROMPT_BYTES) }],
			NOW,
		)).toBe(false);
		expect(isFoxConversationPromptWithinRecordingWindow(
			{ kind: "absent" },
			USER_A,
			USER_B,
			[{ role: "system", content: "日".repeat(FOX_CONVERSATION_REHEARSAL_MAX_PROMPT_BYTES) }],
			NOW,
		)).toBe(true);
	});
});

describe("registered judge actor and fictional counterpart window", () => {
	const actor = "11111111-1111-4111-8111-111111111111", counterpart = "22222222-2222-4222-8222-222222222222";
	const now = Date.parse("2026-09-30T20:00:00Z");
	const env = { JUDGE_ACCESS_ENABLED: "enabled", JUDGE_ACCESS_COHORT: ["shipaton", "20261001"].join("-"), JUDGE_ACCESS_ISSUED_AT: "2026-09-30T19:00:00Z", JUDGE_ACCESS_EXPIRES_AT: "2026-10-13T19:00:00Z", JUDGE_ACCESS_AI_EXPIRES_AT: "2026-10-01T00:00:00Z" };
	it.each([false, true])("admits only the SQL-owned pair, including reversed order (%s)", async reversed => {
		vi.useFakeTimers(); vi.setSystemTime(now);
		try {
			const rpc = vi.fn(async (_name: string, args: Record<string, unknown>) => ({ error: null, data: args.p_user_id === actor ? { outcome: "allowed", actor_user_id: actor, counterpart_user_id: counterpart, account_kind: "judge", expires_at: env.JUDGE_ACCESS_EXPIRES_AT } : null }));
			const first = reversed ? counterpart : actor, second = reversed ? actor : counterpart;
			const window = await resolveFoxConversationGenerationWindow({ rpc }, env, first, second);
			expect(window.kind).toBe("registered-judge");
			expect(isFoxConversationGenerationAllowed(window, first, second, now)).toBe(true);
			expect(isFoxConversationGenerationAllowed(window, actor, "different-user", now)).toBe(false);
			expect(isFoxConversationGenerationAllowed(window, actor, counterpart, Date.parse(env.JUDGE_ACCESS_EXPIRES_AT))).toBe(false);
			expect(resolveFoxConversationRecordingWindow(env, first, second, now).kind).toBe("invalid");
		} finally { vi.useRealTimers(); }
	});
	it("cannot use an actor grant with another account's fictional counterpart", async () => {
		vi.useFakeTimers(); vi.setSystemTime(now);
		try {
			const rpc = vi.fn(async () => ({ error: null, data: { outcome: "allowed", actor_user_id: actor, counterpart_user_id: counterpart, account_kind: "judge", expires_at: env.JUDGE_ACCESS_EXPIRES_AT } }));
			expect((await resolveFoxConversationGenerationWindow({ rpc }, env, actor, "33333333-3333-4333-8333-333333333333", actor)).kind).toBe("invalid");
		} finally { vi.useRealTimers(); }
	});
	it.each(["owner", "qa"])("expires %s AI at the owner-approved deadline", async accountKind => {
		vi.useFakeTimers(); vi.setSystemTime(now);
		try {
			const rpc = vi.fn(async () => ({ error: null, data: { outcome: "allowed", actor_user_id: actor, counterpart_user_id: counterpart, account_kind: accountKind, expires_at: env.JUDGE_ACCESS_EXPIRES_AT } }));
			const window = await resolveFoxConversationGenerationWindow({ rpc }, env, actor, counterpart, actor);
			expect(isFoxConversationGenerationAllowed(window, actor, counterpart, Date.parse(env.JUDGE_ACCESS_AI_EXPIRES_AT) - 1)).toBe(true);
			expect(isFoxConversationGenerationAllowed(window, actor, counterpart, Date.parse(env.JUDGE_ACCESS_AI_EXPIRES_AT))).toBe(false);
		} finally { vi.useRealTimers(); }
	});
});
