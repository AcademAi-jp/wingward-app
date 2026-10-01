import { readDemoJudgeConfig, isDemoJudgePair, type DemoJudgeBindings, type ValidatedDemoJudgeConfig } from "./demo-judge-window";
import {
	isRecordingRehearsalActive,
	readRecordingRehearsalConfig,
	type RecordingRehearsalBindings,
	type ValidatedRecordingRehearsalConfig,
} from "./recording-rehearsal";
import { syntheticGenerationAllowed } from "./synthetic-matching-cohort";
import type { Env } from "../env";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import {
	hasJudgeAccessConfig, readJudgeAccessConfig, readJudgeAccess, isJudgeAccessActive, judgeRpcClient,
	type JudgeRpcClient, type JudgeAccessConfig, type JudgeAccess,
} from "./judge-access";

type GenerationBindings = RecordingRehearsalBindings & DemoJudgeBindings & Partial<Pick<Env["Bindings"],
	"JUDGE_ACCESS_ENABLED" | "JUDGE_ACCESS_COHORT" | "JUDGE_ACCESS_ISSUED_AT" | "JUDGE_ACCESS_EXPIRES_AT" | "JUDGE_ACCESS_AI_EXPIRES_AT">>;

export const FOX_CONVERSATION_REHEARSAL_MAX_ROUNDS = 10;
export const FOX_CONVERSATION_REHEARSAL_MAX_PROMPT_BYTES = 8_192;

export type FoxConversationRecordingWindow =
	| Readonly<{ kind: "absent" }>
	| Readonly<{ kind: "invalid" }>
	| Readonly<{ kind: "registered-judge"; config: JudgeAccessConfig; access: JudgeAccess }>
	| Readonly<{ kind: "judge"; config: ValidatedDemoJudgeConfig }>
	| Readonly<{ kind: "active"; config: ValidatedRecordingRehearsalConfig }>;

export type FoxConversationPromptMessage = Readonly<{
	role: string;
	content: string;
}>;

function isExactGenerationPair(
	config: ValidatedRecordingRehearsalConfig,
	userA: string,
	userB: string,
): boolean {
	const [first, second] = config.generationPair;
	return (first === userA && second === userB) || (first === userB && second === userA);
}

/** Resolve only from server bindings plus the pair read from the database. */
export function resolveFoxConversationRecordingWindow(
	env: GenerationBindings | undefined,
	userA: string,
	userB: string,
	nowMs = Date.now(),
): FoxConversationRecordingWindow {
	// New registry grants require a database lookup. A synchronous caller may
	// never inherit a legacy permit while the registry mode is configured.
	if (hasJudgeAccessConfig(env as Env["Bindings"] | undefined)) return { kind: "invalid" };
	const judge = readDemoJudgeConfig(env, nowMs);
	if (judge.kind === "invalid") return { kind: "invalid" };
	if (judge.kind === "active") return isDemoJudgePair(judge.config, userA, userB, nowMs) ? { kind: "judge", config: judge.config } : { kind: "invalid" };
	const result = readRecordingRehearsalConfig(env, nowMs);
	if (result.kind === "absent") return { kind: "absent" };
	if (result.kind !== "active" || result.config.ownerPrepOnly || !isExactGenerationPair(result.config, userA, userB)) {
		return { kind: "invalid" };
	}
	return { kind: "active", config: result.config };
}

/** Authorize one registered actor and its own fictional counterpart only. */
export async function resolveFoxConversationGenerationWindow(
	client: JudgeRpcClient | SupabaseClient<Database>,
	env: GenerationBindings | undefined,
	userA: string,
	userB: string,
	actorId?: string,
): Promise<FoxConversationRecordingWindow> {
	const judge = readJudgeAccessConfig(env as Env["Bindings"] | undefined);
	if (judge.kind === "absent") return resolveFoxConversationRecordingWindow(env, userA, userB);
	if (judge.kind !== "active" || userA === userB || (actorId !== undefined && actorId !== userA && actorId !== userB)) {
		return { kind: "invalid" };
	}
	for (const candidate of actorId ? [actorId] : [userA, userB]) {
		const access = await readJudgeAccess(judgeRpcClient(client), judge.config, candidate);
		if (!access) continue;
		const counterpart = candidate === userA ? userB : userA;
		if (access.counterpartId !== counterpart || !isJudgeAccessActive(access)) return { kind: "invalid" };
		return { kind: "registered-judge", config: judge.config, access };
	}
	return { kind: "invalid" };
}

/**
 * The active rehearsal permit is strict: it never falls through to the legacy
 * synthetic matcher after expiry or when the selected pair does not match.
 */
export function isFoxConversationGenerationAllowed(
	window: FoxConversationRecordingWindow | undefined,
	userA: string,
	userB: string,
	nowMs = Date.now(),
): boolean {
	if (window === undefined || window.kind === "absent") {
		return syntheticGenerationAllowed(userA, userB);
	}
	if (window.kind === "registered-judge") {
		return isJudgeAccessActive(window.access, nowMs)
			&& ((window.access.actorId === userA && window.access.counterpartId === userB)
				|| (window.access.actorId === userB && window.access.counterpartId === userA));
	}
	if (window.kind === "judge") return isDemoJudgePair(window.config, userA, userB, nowMs);
	return window.kind === "active"
		&& !window.config.ownerPrepOnly
		&& isRecordingRehearsalActive(window.config, nowMs)
		&& isExactGenerationPair(window.config, userA, userB);
}

/**
 * Rehearsal-only prompt byte cap. It counts the UTF-8 JSON representation that
 * will be submitted and never truncates source prompts or saved history.
 */
export function isFoxConversationPromptWithinRecordingWindow(
	window: FoxConversationRecordingWindow | undefined,
	userA: string,
	userB: string,
	messages: readonly FoxConversationPromptMessage[],
	nowMs = Date.now(),
): boolean {
	if (window === undefined || window.kind === "absent") return true;
	if (!isFoxConversationGenerationAllowed(window, userA, userB, nowMs)) return false;
	try {
		return new TextEncoder().encode(JSON.stringify(messages)).byteLength
			<= FOX_CONVERSATION_REHEARSAL_MAX_PROMPT_BYTES;
	} catch {
		return false;
	}
}
