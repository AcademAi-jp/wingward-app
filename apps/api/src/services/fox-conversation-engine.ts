import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../db/types";
import { z } from "zod";
import { chatCompleteWithUsage, chatCompleteOnceBounded, MISTRAL_LIGHT, type ChatCompleteOptions, type ChatMessage, type TokenUsage } from "./mistral";
import { readJudgeAccess, reserveJudgeProviderOperation, judgeRpcClient } from "./judge-access";
import { buildFoxConversationSystemPrompt } from "../prompts/fox-conversation";
import { buildConversationScorePrompt } from "../prompts/fox-conversation";
import { truncateFoxMessage } from "../lib/truncate";
import { resolveConversationLangFromUserSettings } from "../lib/lang";
import {
	hasTraitScores,
	getProfileScoreDetailsForUsers,
} from "./matching";
import {
	saveFeatureScores,
	loadFeatureScores,
	calculateLayerScores,
	detectDealbreakers,
	type FeatureScore,
} from "./compatibility";
import {
	checkFoxConversationCurrentAccess,
	isFoxConversationAccessError,
	FoxConversationAccessError,
	type FoxConversationAccessExpectation,
	type FoxConversationAccessMode,
} from "./fox-conversation-access";
import {
	FOX_CONVERSATION_REHEARSAL_MAX_ROUNDS,
	FOX_CONVERSATION_REHEARSAL_MAX_PROMPT_BYTES,
	isFoxConversationPromptWithinRecordingWindow,
	type FoxConversationRecordingWindow,
} from "./fox-conversation-recording-window";

/**
 * The single implementation of the fox-conversation loop (step-3d). Both
 * `runFoxConversation` (the local-dev / no-DO-binding fallback) and
 * `FoxConversationDO.alarm()` (the production path) call this. See
 * docs/spec/impl/step-03d-unify-conversation-loop.md — before this, the DO
 * and the service each carried their own copy of this loop and had already
 * drifted (hardcoded round count, different max_tokens), which is exactly
 * the kind of divergence a single implementation is meant to make
 * impossible.
 */

const FeatureScoresSchema = z.object({
	reciprocity: z.number().min(0).max(1),
	humor_sharing: z.number().min(0).max(1),
	self_disclosure: z.number().min(0).max(1),
	emotional_responsiveness: z.number().min(0).max(1),
	self_esteem: z.number().min(0).max(1),
	conflict_resolution: z.number().min(0).max(1),
});

const ConversationScoreSchema = z.object({
	score: z.number().min(0).max(100),
	excitement_level: z.number().min(0).max(1),
	common_topics: z.array(z.string()),
	mutual_interest: z.number().min(0).max(1),
	topic_distribution: z.array(
		z.object({
			topic: z.string(),
			percentage: z.number(),
		}),
	),
	feature_scores: FeatureScoresSchema,
});

// Map from LLM feature key to feature_id
const CONVERSATION_FEATURE_MAP: Record<string, { id: number; nameJa: string }> = {
	reciprocity: { id: 4, nameJa: "好意の返報性" },
	humor_sharing: { id: 6, nameJa: "ユーモア共有" },
	self_disclosure: { id: 7, nameJa: "自己開示" },
	emotional_responsiveness: { id: 9, nameJa: "感情的応答性" },
	self_esteem: { id: 11, nameJa: "自己肯定感" },
	conflict_resolution: { id: 14, nameJa: "葛藤解決スタイル" },
};

const defaultSleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

type SupabaseErrorLike = { code?: string } | null | undefined;

function isMissingRowError(error: SupabaseErrorLike): boolean {
	return error?.code === "PGRST116";
}

function supabaseOperationError(operation: string): Error {
	console.error(`[runConversationLoop] Supabase operation failed: ${operation}`);
	return new Error(`[runConversationLoop] Supabase operation failed: ${operation}`);
}

export type ConversationLoopDeps = {
	supabase: SupabaseClient<Database>;
	apiKey: string;
	conversationId: string;
	/** Called once per confirmed round. DO passes its WebSocket broadcast; service leaves it unset (no-op). */
	onRound?: (round: number, speaker: "A" | "B", content: string) => void | Promise<void>;
	/** Defaults to a setTimeout-based sleep. Injectable so tests can shorten waits. */
	sleep?: (ms: number) => Promise<void>;
	/**
	 * Upper bound on how many rounds this single invocation advances. The DO
	 * passes this so one `alarm()` invocation's subrequest count stays under
	 * the Workers Free plan's per-invocation limit of 50; it reschedules
	 * another alarm to pick up the remaining rounds. Left undefined (no
	 * limit) by the local-dev fallback `runFoxConversation`, which always
	 * runs a conversation to completion in one call.
	 */
	maxRoundsPerRun?: number;
	/** Optional context derived from trusted server bindings; never sourced from request JSON or DO storage. */
	generationWindow?: FoxConversationRecordingWindow;
};

export type ConversationLoopResult = {
	conversationScore: number;
	finalScore: number;
	analysis: Record<string, unknown>;
	/** True when terminal persistence succeeded but the result is no longer safe to expose. */
	outputSuppressed?: boolean;
	/**
	 * True only when the loop stopped before any Mistral call was made, due to
	 * a precondition that is known to fail before the conversation starts
	 * (currently: missing persona for either participant). In that case
	 * `fox_conversations` and `matches` are already written as failed by the
	 * time this promise resolves (mirrors the pre-unification service
	 * behaviour — see D-3 in step-03d) and this function does NOT throw. A
	 * caller must check this flag and must not treat a resolved promise as
	 * "conversation completed successfully" without checking it first.
	 */
	failedBeforeStart?: boolean;
	/**
	 * True when `maxRoundsPerRun` is set and this invocation processed one or
	 * more rounds. This is unconditional on whether rounds remain: even the
	 * invocation that types the final round returns `incomplete: true` and
	 * does NOT score, because scoring's own retries (`SCORE_MAX_RETRIES`)
	 * must run in an invocation that spent zero of its subrequest budget on
	 * round generation, or the worst case (retried rounds + retried scoring
	 * in the same alarm) exceeds the Workers Free plan's 50-subrequest cap.
	 * No scoring has run, and `fox_conversations`/`matches` have NOT been
	 * written to any terminal status — the caller must call this loop again
	 * (it resumes on its own from `fox_conversation_messages`, no extra state
	 * needs to be passed back in). The next invocation, having `startRound >
	 * total_rounds`, processes zero rounds and this flag is naturally false
	 * on it, so it proceeds to scoring — this is what prevents an infinite
	 * incomplete/resume loop. `conversationScore` / `finalScore` / `analysis`
	 * are not meaningful when this is true and must not be read.
	 */
	incomplete?: boolean;
};

export async function runConversationLoop(deps: ConversationLoopDeps): Promise<ConversationLoopResult> {
	const { supabase, apiKey: mistralApiKey, conversationId, onRound, maxRoundsPerRun } = deps;
	const sleep = deps.sleep ?? defaultSleep;

	const { data: conv, error: convError } = await supabase
		.from("fox_conversations")
		.select("id, match_id, status, total_rounds, current_round, input_tokens, output_tokens, cache_hit_tokens")
		.eq("id", conversationId)
		.single();
	if (convError && !isMissingRowError(convError)) throw supabaseOperationError("load conversation");
	if (!conv || conv.total_rounds === 0) {
		// Preserves the pre-unification service behaviour exactly: a silent
		// return with no status write (see the deviations list in the PR
		// report for why this is left as-is rather than tightened here).
		console.error(`[runConversationLoop] Conversation not found or total_rounds=0: ${conversationId}`);
		return { conversationScore: 0, finalScore: 0, analysis: {}, failedBeforeStart: true };
	}
	const TOTAL_ROUNDS_LOCAL = conv.total_rounds;

	const { data: existingMsgs, error: existingMsgsError } = await supabase
		.from("fox_conversation_messages")
		.select("speaker_user_id, content, round_number")
		.eq("conversation_id", conversationId)
		.order("round_number");
	if (existingMsgsError) {
		// supabase-js resolves (never rejects) on a PostgREST error, so a
		// transient failure here silently leaves existingMsgs as null unless we
		// check for it explicitly. Failing open on that ("null = no messages
		// yet = start from round 1") would be wrong on a conversation that is
		// already several rounds in: startRound would fall back to 1, and
		// since (conversation_id, round_number) has no UNIQUE constraint, the
		// loop below would happily insert a second full set of rows rather
		// than reject a duplicate — re-billing Mistral for rounds already
		// paid for and corrupting both the score computation (which reads
		// every row back) and the WebSocket catch-up (which replays all rows
		// by round_number). Throw instead: the caller (runFoxConversation's
		// catch, or FoxConversationDO's alarm() catch) routes this to
		// failConversation, same as any other precondition failure. Logged
		// with only the conversation UUID, no user-authored content.
		console.error(`[runConversationLoop] Failed to load existing messages for conversationId=${conversationId}`);
		throw new Error(`[runConversationLoop] Failed to load existing messages for conversationId=${conversationId}`);
	}

	const existingRounds = (existingMsgs ?? []).map((m) => m.round_number);
	const startRound = existingRounds.length > 0 ? Math.max(...existingRounds) + 1 : 1;
	const { data: match, error: matchError } = await supabase
		.from("matches")
		.select("id, user_a_id, user_b_id, status")
		.eq("id", conv.match_id)
		.single();
	if (matchError && !isMissingRowError(matchError)) throw supabaseOperationError("load match");
	if (!match) {
		// Preserves the pre-unification service behaviour exactly: a silent
		// return with no status write.
		console.error(`[runConversationLoop] Match not found for conversation ${conversationId}, match_id=${conv.match_id}`);
		return { conversationScore: 0, finalScore: 0, analysis: {}, failedBeforeStart: true };
	}
	const [userA, userB] = [match.user_a_id, match.user_b_id];
	const accessExpectation: FoxConversationAccessExpectation = {
		conversationId,
		matchId: conv.match_id,
		userA,
		userB,
		generationWindow: deps.generationWindow,
	};
	const ensureCurrentAccess = async (mode: FoxConversationAccessMode): Promise<void> => {
		if (deps.generationWindow?.kind === "registered-judge") {
			const { config, access: expected } = deps.generationWindow;
			const current = await readJudgeAccess(judgeRpcClient(supabase), config, expected.actorId);
			if (!current || current.counterpartId !== expected.counterpartId || current.accountKind !== expected.accountKind) {
				throw new FoxConversationAccessError();
			}
		}
		const access = await checkFoxConversationCurrentAccess(supabase, accessExpectation, mode);
		if (!access.ok) throw new FoxConversationAccessError();
	};
	await ensureCurrentAccess("active");
	if ((deps.generationWindow?.kind === "active" || deps.generationWindow?.kind === "registered-judge")
		&& TOTAL_ROUNDS_LOCAL > FOX_CONVERSATION_REHEARSAL_MAX_ROUNDS) {
		// Do not truncate or resume an overlong row under the temporary permit.
		throw new FoxConversationAccessError();
	}
	const [personaAResult, personaBResult, userProfilesResult] = await Promise.all([
		supabase
			.from("personas")
			.select("compiled_document, name")
			.eq("user_id", userA)
			.eq("persona_type", "wingfox")
			.single(),
		supabase
			.from("personas")
			.select("compiled_document, name")
			.eq("user_id", userB)
			.eq("persona_type", "wingfox")
			.single(),
		supabase.from("user_profiles").select("id, gender, conversation_language").in("id", [userA, userB]),
	]);
	if (personaAResult.error && !isMissingRowError(personaAResult.error)) throw supabaseOperationError("load participant A persona");
	if (personaBResult.error && !isMissingRowError(personaBResult.error)) throw supabaseOperationError("load participant B persona");
	if (userProfilesResult.error || !userProfilesResult.data) throw supabaseOperationError("load participant profiles");
	const { data: personaA } = personaAResult;
	const { data: personaB } = personaBResult;
	const { data: userProfiles } = userProfilesResult;
	if (!personaA?.compiled_document || !personaB?.compiled_document) {
		// A failure that is known before any LLM call is made / any token is
		// spent: mirrors the pre-existing service behaviour of marking the row
		// failed and returning rather than throwing, since there is nothing to
		// clean up (no partial spend to persist).
		console.error(`[runConversationLoop] Persona missing for conversation ${conversationId}: personaA=${!!personaA?.compiled_document}, personaB=${!!personaB?.compiled_document}`);
		const latestAccess = await checkFoxConversationCurrentAccess(supabase, accessExpectation, "active");
		if (!latestAccess.ok) {
			return { conversationScore: 0, finalScore: 0, analysis: {}, failedBeforeStart: true };
		}
		const [{ error: conversationFailureError }, { error: matchFailureError }] = await Promise.all([
			supabase
				.from("fox_conversations")
				.update({ status: "failed" })
				.eq("id", conversationId)
				.eq("match_id", conv.match_id)
				.in("status", ["pending", "in_progress"]),
			supabase
				.from("matches")
				.update({ status: "fox_conversation_failed" })
				.eq("id", conv.match_id)
				.eq("user_a_id", userA)
				.eq("user_b_id", userB)
				.eq("status", "fox_conversation_in_progress"),
		]);
		if (conversationFailureError) throw supabaseOperationError("mark conversation failed");
		if (matchFailureError) throw supabaseOperationError("mark match failed");
		return { conversationScore: 0, finalScore: 0, analysis: {}, failedBeforeStart: true };
	}
	const genderByUserId = new Map<string, string | null>(
		(userProfiles ?? []).map((row) => [row.id, row.gender]),
	);
	const languageByUserId = new Map<string, string | null>(
		(userProfiles ?? []).map((row) => [row.id, row.conversation_language]),
	);
	await ensureCurrentAccess("active");
	// Note on `started_at` under `maxRoundsPerRun`: this runs once per
	// invocation, so a conversation resumed across several alarms rewrites it
	// each time and it ends up meaning "this run started at", not "the first
	// run started at". That is deliberate — the only reader is the stuck-
	// conversation sweep in routes/internal.ts, which asks "has this made no
	// progress for STUCK_IN_PROGRESS_MINUTES", and time-since-last-progress is
	// the more accurate signal for that question than time-since-first-start.
	const { error: inProgressError } = await supabase
		.from("fox_conversations")
		.update({ status: "in_progress", started_at: new Date().toISOString() })
		.eq("id", conversationId)
		.eq("match_id", conv.match_id)
		.in("status", ["pending", "in_progress"])
		.select("id")
		.single();
	if (inProgressError) throw supabaseOperationError("mark conversation in progress");
	await ensureCurrentAccess("active");
	const lang = resolveConversationLangFromUserSettings(
		languageByUserId.get(userA),
		languageByUserId.get(userB),
		personaA.compiled_document,
	);
	const systemA = buildFoxConversationSystemPrompt(
		personaA.compiled_document,
		personaA.name ?? "",
		lang,
		genderByUserId.get(userA),
	);
	const systemB = buildFoxConversationSystemPrompt(
		personaB.compiled_document,
		personaB.name ?? "",
		lang,
		genderByUserId.get(userB),
	);

	// Build history from existing messages (for retry: resume from existing)
	const history: { speaker: "A" | "B"; content: string }[] = (existingMsgs ?? []).map((m) => ({
		speaker: (m.speaker_user_id === userA ? "A" : "B") as "A" | "B",
		content: m.content ?? "",
	}));
	let currentSpeaker: "A" | "B" = startRound % 2 === 1 ? "A" : "B";

	// Token accounting across every round + scoring call. `cachedTokensReported`
	// tracks whether ANY call in this conversation reported a cached_tokens
	// figure at all; if none did, the stored total must be `null` (not
	// measured), never 0 (measured, zero hits) — those are different facts.
	// Seed accumulators from the row's existing values so a retry on the same
	// row (see routes/fox-search.ts and routes/internal.ts, which both reset
	// status/current_round but never these token columns) is cumulative rather
	// than overwriting the first paid attempt's spend with the second's alone.
	const seedTokenCount = (v: unknown): number =>
		typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : 0;
	let totalInputTokens = seedTokenCount(conv.input_tokens);
	let totalOutputTokens = seedTokenCount(conv.output_tokens);
	let totalCachedTokens = seedTokenCount(conv.cache_hit_tokens);
	let cachedTokensReported = typeof conv.cache_hit_tokens === "number";
	const recordUsage = (usage: TokenUsage) => {
		totalInputTokens += usage.inputTokens;
		totalOutputTokens += usage.outputTokens;
		if (usage.cachedTokens !== null) {
			cachedTokensReported = true;
			totalCachedTokens += usage.cachedTokens;
		}
	};
	const tokenTotalsForUpdate = () => ({
		input_tokens: totalInputTokens,
		output_tokens: totalOutputTokens,
		cache_hit_tokens: cachedTokensReported ? totalCachedTokens : null,
	});

	let conversationScore = 50;
	let analysis: Record<string, unknown> = {};
	let conversationFeatureScores: FeatureScore[] = [];
	const registeredJudge = deps.generationWindow?.kind === "registered-judge";
	const completeJudgeAttempt = async (messages: ChatMessage[], options: ChatCompleteOptions & { promptCacheKey?: string }) => {
		if (deps.generationWindow?.kind !== "registered-judge") throw new FoxConversationAccessError();
		const { access: expected } = deps.generationWindow;
		// SQL atomically admits the daily operation and request rate
		// reservation. Failed calls keep the reservation; no SDK retries occur.
		const reservation = await reserveJudgeProviderOperation(judgeRpcClient(supabase), expected, "ward_conversation", crypto.randomUUID());
		if (!reservation) throw new FoxConversationAccessError();
		await ensureCurrentAccess("active");
		const result = await chatCompleteOnceBounded(mistralApiKey, messages, {
			...options,
			model: MISTRAL_LIGHT,
			maxRequestBytes: FOX_CONVERSATION_REHEARSAL_MAX_PROMPT_BYTES,
			maxResponseBytes: 32_768,
			maxTotalTokenUnits: reservation.maxUnits,
		});
		return { content: result.content, usage: { inputTokens: result.inputTokens, outputTokens: result.outputTokens, cachedTokens: null } };
	};

	try {
	// The prior gate follows the in-progress write. Only synchronous prompt
	// setup occurs between that gate and this point; skip its duplicate SQL
	// read in registry mode so the full scoring alarm fits its dispatch budget.
	if (!registeredJudge) await ensureCurrentAccess("active");
	let roundsProcessedThisRun = 0;
	for (let round = startRound; round <= TOTAL_ROUNDS_LOCAL; round++) {
		const systemPrompt = currentSpeaker === "A" ? systemA : systemB;
		const selfLabel = lang === "en" ? "Me" : "自分";
		const otherLabel = lang === "en" ? "Them" : "相手";
		const context = history.length
			? history
					.map((m) =>
						m.speaker === currentSpeaker ? `${selfLabel}: ${m.content}` : `${otherLabel}: ${m.content}`,
					)
					.join("\n\n")
			: lang === "en" ? "Introduce yourself and ask the other person a question." : "自己紹介と、相手に一言聞いてください。";
		let raw: string | null = null;
		const MAX_RETRIES = registeredJudge ? 1 : 3;
		for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
			try {
				const roundMessages: ChatMessage[] = [
					{ role: "system", content: systemPrompt },
					{ role: "user", content: context },
				];
				await ensureCurrentAccess("active");
				if (!isFoxConversationPromptWithinRecordingWindow(deps.generationWindow, userA, userB, roundMessages)) {
					throw new FoxConversationAccessError();
				}
				// D-2: max_tokens for round generation is 200 everywhere in the
				// codebase — this is the only place it is specified. Do not add
				// another maxTokens literal for round generation elsewhere.
				const roundOptions = { maxTokens: 200, promptCacheKey: `${conversationId}:${currentSpeaker}` };
				const result = registeredJudge ? await completeJudgeAttempt(roundMessages, roundOptions) : await chatCompleteWithUsage(
					mistralApiKey,
					roundMessages,
					roundOptions,
				);
				raw = result.content;
				recordUsage(result.usage);
				// Usage is recorded before this gate. A provider response may have
				// been billed even when the pair became unavailable while it was in
				// flight, so that spend must survive the denial.
				await ensureCurrentAccess("active");
				break;
			} catch (err) {
				if (isFoxConversationAccessError(err)) throw err;
				if (attempt >= MAX_RETRIES) throw err;
				const is429 = err instanceof Error && (
					err.message.includes("429") ||
					err.message.includes("rate") ||
					err.message.includes("Too Many Requests")
				);
				const jitter = Math.floor(Math.random() * 2000);
				const delay = is429
					? 5000 * attempt + jitter
					: 2000 * attempt + jitter;
				console.warn(`[runConversationLoop] chatComplete failed (attempt ${attempt}/${MAX_RETRIES}), retrying in ${delay}ms is429=${is429}`);
				await sleep(delay);
				// A rejected provider call is still a point at which current access
				// may have changed; never issue the next retry without rechecking.
				await ensureCurrentAccess("active");
			}
		}
		const fallback = lang === "en" ? "(No response)" : "（応答なし）";
		const content = (raw && truncateFoxMessage(raw)) || fallback;
		const speakerUserId = currentSpeaker === "A" ? userA : userB;
		await ensureCurrentAccess("active");
		const { error: messageInsertError } = await supabase.from("fox_conversation_messages").insert({
			conversation_id: conversationId,
			speaker_user_id: speakerUserId,
			content,
			round_number: round,
		});
		if (messageInsertError) throw supabaseOperationError("persist conversation round message");
		await ensureCurrentAccess("active");
		const { error: currentRoundError } = await supabase
			.from("fox_conversations")
			.update({ current_round: round })
			.eq("id", conversationId);
		if (currentRoundError) throw supabaseOperationError("persist conversation current round");
		await ensureCurrentAccess("active");
		history.push({ speaker: currentSpeaker, content });
		await onRound?.(round, currentSpeaker, content);
		currentSpeaker = currentSpeaker === "A" ? "B" : "A";
		roundsProcessedThisRun++;

		const roundsRemain = round < TOTAL_ROUNDS_LOCAL;
		const budgetExhausted = maxRoundsPerRun !== undefined && roundsProcessedThisRun >= maxRoundsPerRun;
		if (budgetExhausted) {
			// Stop generating rounds this invocation. Whether to checkpoint and
			// return `incomplete` (rather than fall through to scoring) is
			// decided once, after the loop, purely from roundsProcessedThisRun —
			// see the block below and the `incomplete` field's doc comment for
			// why this must hold even when this was the conversation's last
			// round (round === TOTAL_ROUNDS_LOCAL, roundsRemain false).
			break;
		}

		// Rate-limit guard: delay between rounds to avoid Mistral 429 errors
		if (roundsRemain) {
			await sleep((registeredJudge ? 1000 : 500) + Math.floor(Math.random() * 500));
			await ensureCurrentAccess("active");
		}
	}

	if (maxRoundsPerRun !== undefined && roundsProcessedThisRun > 0) {
		// This invocation spent part of its subrequest budget generating
		// rounds (whether because maxRoundsPerRun was hit or because it typed
		// the conversation's final round) — never score in the same
		// invocation. Scoring has its own retries (SCORE_MAX_RETRIES) and
		// each retry is itself several Mistral calls plus DB writes; doing
		// that on top of a round-generation budget that already assumes
		// retries risks exceeding the Workers Free plan's 50-subrequest cap.
		// The caller (DO) reschedules another alarm to resume: the next
		// invocation has startRound > TOTAL_ROUNDS_LOCAL, so its round loop
		// above does not execute, roundsProcessedThisRun stays 0, and this
		// branch is skipped — that is what makes scoring actually happen
		// eventually instead of looping incomplete forever.
		//
		// Persist the token spend accumulated so far — the caller (DO)
		// reschedules another alarm to resume from
		// fox_conversation_messages, but this run's Mistral spend is real
		// and must not be dropped (same failure class as 3-B).
		//
		// supabase-js does NOT reject on a PostgREST error; it resolves with
		// `{ error }`. Returning `incomplete: true` after silently ignoring
		// that error would tell the caller "the checkpoint is safe, just
		// reschedule" when it may not be — the next alarm reseeds its token
		// accumulators from this row (see `seedTokenCount` above), so an
		// unpersisted checkpoint here means this run's real, already-billed
		// Mistral spend is gone for good. Retry a few times with a short
		// backoff, and if it still hasn't landed, THROW instead of
		// returning incomplete: a loud failure (the caller's catch routes
		// this to failConversation) is the deliberate choice over silently
		// losing billing data, even though it costs the user this
		// conversation attempt.
		const CHECKPOINT_RETRY_ATTEMPTS = 3;
		const CHECKPOINT_RETRY_BACKOFF_MS = 200;
		await ensureCurrentAccess("active");
		let checkpointError: { message: string } | null = null;
		for (let attempt = 1; attempt <= CHECKPOINT_RETRY_ATTEMPTS; attempt++) {
			const { error } = await supabase.from("fox_conversations").update(tokenTotalsForUpdate()).eq("id", conversationId);
			checkpointError = error;
			if (!error) break;
			console.error(`[runConversationLoop] Checkpoint token update failed (attempt ${attempt}/${CHECKPOINT_RETRY_ATTEMPTS}) conversationId=${conversationId}`);
			if (attempt < CHECKPOINT_RETRY_ATTEMPTS) {
				await sleep(CHECKPOINT_RETRY_BACKOFF_MS * attempt);
				await ensureCurrentAccess("active");
			}
		}
		if (checkpointError) {
			throw new Error(
				`[runConversationLoop] Failed to persist checkpoint token totals after ${CHECKPOINT_RETRY_ATTEMPTS} attempts, conversationId=${conversationId}`,
			);
		}
		return { conversationScore: 0, finalScore: 0, analysis: {}, incomplete: true };
	}

	// ─── Score computation ─────────────────────────────────────────────

	// Delay before scoring to avoid Mistral rate limits after rapid round calls
	await sleep(2000);
	await ensureCurrentAccess("active");

	const { data: allMsgs, error: allMsgsError } = await supabase
		.from("fox_conversation_messages")
		.select("speaker_user_id, content, round_number")
		.eq("conversation_id", conversationId)
		.order("round_number");
	if (allMsgsError) throw supabaseOperationError("load conversation scoring history");
	await ensureCurrentAccess("active");
	const logText = (allMsgs ?? [])
		.map((m) => `Round ${m.round_number} (${m.speaker_user_id === userA ? "A" : "B"}): ${m.content}`)
		.join("\n");

	console.log(`[runConversationLoop] Score computation START conversationId=${conversationId} messageCount=${allMsgs?.length ?? 0}`);

	const SCORE_MAX_RETRIES = registeredJudge ? 1 : 3;
	for (let scoreAttempt = 1; scoreAttempt <= SCORE_MAX_RETRIES; scoreAttempt++) {
		try {
			const scorePrompt = buildConversationScorePrompt(logText, lang);
			const scoreMessages: ChatMessage[] = [{ role: "user", content: scorePrompt }];
			await ensureCurrentAccess("active");
			if (!isFoxConversationPromptWithinRecordingWindow(deps.generationWindow, userA, userB, scoreMessages)) {
				throw new FoxConversationAccessError();
			}
			const scoreOptions: ChatCompleteOptions = {
				maxTokens: 2048,
				responseFormat: { type: "json_object" },
			};
			const scoreResult = registeredJudge ? await completeJudgeAttempt(scoreMessages, scoreOptions)
				: await chatCompleteWithUsage(mistralApiKey, scoreMessages, scoreOptions);
			const scoreRaw = scoreResult.content;
			recordUsage(scoreResult.usage);
			// As with round generation, retain usage before rejecting a response
			// whose pair became unavailable while the provider was in flight.
			await ensureCurrentAccess("active");
			let parsed: z.infer<typeof ConversationScoreSchema>;
			try {
				parsed = ConversationScoreSchema.parse(JSON.parse(scoreRaw ?? "{}"));
			} catch (parseErr) {
				const scoreMatch = (scoreRaw ?? "").match(/"score"\s*:\s*(\d+(?:\.\d+)?)/);
				if (scoreMatch) {
					const n = Number.parseFloat(scoreMatch[1]);
					const clamped = Math.min(100, Math.max(0, n));
					parsed = ConversationScoreSchema.parse({
						score: Math.round(clamped),
						excitement_level: 0.5,
						common_topics: [],
						mutual_interest: 0.5,
						topic_distribution: [],
						feature_scores: {
							reciprocity: 0.5,
							humor_sharing: 0.5,
							self_disclosure: 0.5,
							emotional_responsiveness: 0.5,
							self_esteem: 0.5,
							conflict_resolution: 0.5,
						},
					});
					parsed.score = Math.round(clamped);
				} else {
					throw parseErr;
				}
			}
			conversationScore = parsed.score;
			analysis = {
				excitement_level: parsed.excitement_level,
				common_topics: parsed.common_topics,
				mutual_interest: parsed.mutual_interest,
				topic_distribution: parsed.topic_distribution,
			};

			if (parsed.feature_scores) {
				conversationFeatureScores = [];
				for (const [key, value] of Object.entries(parsed.feature_scores)) {
					const mapping = CONVERSATION_FEATURE_MAP[key];
					if (!mapping) continue;
					conversationFeatureScores.push({
						featureId: mapping.id,
						featureName: mapping.nameJa,
						rawScore: value,
						normalizedScore: value,
						confidence: 0.7,
						evidence: { source: "fox_conversation", conversation_id: conversationId },
						sourcePhase: "fox_conversation",
					});
				}
			}
			console.log(`[runConversationLoop] Score computation OK attempt=${scoreAttempt} score=${conversationScore} conversationId=${conversationId}`);
			break;
		} catch (e) {
			if (isFoxConversationAccessError(e)) throw e;
			if (registeredJudge) throw e;
			const is429 = e instanceof Error && (
				e.message.includes("429") ||
				e.message.includes("rate") ||
				e.message.includes("Too Many Requests")
			);
			if (scoreAttempt < SCORE_MAX_RETRIES) {
				const jitter = Math.floor(Math.random() * 2000);
				const delay = is429
					? 5000 * scoreAttempt + jitter
					: 2000 * scoreAttempt + jitter;
				console.warn(`[runConversationLoop] Score computation failed (attempt ${scoreAttempt}/${SCORE_MAX_RETRIES}), retrying in ${delay}ms is429=${is429} conversationId=${conversationId}`);
				await sleep(delay);
				await ensureCurrentAccess("active");
			} else {
				await ensureCurrentAccess("active");
				console.error(`[runConversationLoop] Score computation FAILED after ${SCORE_MAX_RETRIES} attempts, using default score(50) conversationId=${conversationId}`);
				if (conversationFeatureScores.length === 0) {
					for (const [, mapping] of Object.entries(CONVERSATION_FEATURE_MAP)) {
						conversationFeatureScores.push({
							featureId: mapping.id,
							featureName: mapping.nameJa,
							rawScore: 0.5,
							normalizedScore: 0.5,
							confidence: 0.3,
							evidence: { source: "fox_conversation_fallback", conversation_id: conversationId },
							sourcePhase: "fox_conversation",
						});
					}
				}
			}
		}
	}

	// ─── 3-layer compatibility scoring (graceful: skips if interaction_dna_scores table missing) ───
	let finalScore: number;
	let layerData: Record<string, unknown> = {};

	// Build fox_feature_scores (0-100) for frontend display
	const foxFeatureScores: Record<string, number> = {};
	for (const fs of conversationFeatureScores) {
		const entry = Object.entries(CONVERSATION_FEATURE_MAP).find(([, v]) => v.id === fs.featureId);
		if (entry) {
			foxFeatureScores[entry[0]] = Math.round(fs.normalizedScore * 100);
		}
	}

	try {
		// Save conversation feature scores to interaction_dna_scores
		if (conversationFeatureScores.length > 0) {
			await ensureCurrentAccess("active");
			await saveFeatureScores(supabase, conv.match_id, conversationFeatureScores);
		}

		// Ensure profile-based feature scores exist
		const { data: matchRow, error: matchRowError } = await supabase.from("matches").select("profile_score, score_details").eq("id", conv.match_id).single();
		if (matchRowError) throw supabaseOperationError("load match score details");
		await ensureCurrentAccess("active");
		let existingDetails = (matchRow?.score_details as Record<string, unknown>) ?? {};

		if (!hasTraitScores(existingDetails)) {
			const computed = await getProfileScoreDetailsForUsers(supabase, match.user_a_id, match.user_b_id);
			if (computed) {
				await ensureCurrentAccess("active");
				await saveFeatureScores(supabase, conv.match_id, computed.featureScores);
				existingDetails = { ...computed.score_details, ...existingDetails };
			}
		}

		// Recalculate 3-layer final score with all available features
		const allFeatureScores = await loadFeatureScores(supabase, conv.match_id);
		await ensureCurrentAccess("active");
		const layerScores = calculateLayerScores(allFeatureScores);
		const dealbreakers = detectDealbreakers(allFeatureScores);

		finalScore = dealbreakers.triggered ? 0 : layerScores.finalScore;
		layerData = {
			score_details: {
				...existingDetails,
				conversation_analysis: analysis,
				fox_feature_scores: foxFeatureScores,
				layer1: Math.round(layerScores.layer1 * 100),
				layer2: Math.round(layerScores.layer2 * 100),
				layer3: Math.round(layerScores.layer3 * 100),
			} as Json,
			layer_scores: {
				layer1: layerScores.layer1,
				layer2: layerScores.layer2,
				layer3: layerScores.layer3,
				feature_scores: layerScores.featureScores,
				dealbreakers: dealbreakers.triggered ? dealbreakers.features : [],
			} as Json,
		};
	} catch (e) {
		if (isFoxConversationAccessError(e)) throw e;
		console.warn("[runConversationLoop] 3-layer scoring failed (interaction_dna_scores table may not exist), falling back to simple scoring");
		// Fallback: use simple profile + conversation weighted score
		await ensureCurrentAccess("active");
		const { data: matchRow, error: fallbackMatchRowError } = await supabase.from("matches").select("profile_score, score_details").eq("id", conv.match_id).single();
		if (fallbackMatchRowError) throw supabaseOperationError("load fallback match score details");
		await ensureCurrentAccess("active");
		const profileScore = (matchRow?.profile_score as number) ?? 50;
		const existingDetails = (matchRow?.score_details as Record<string, unknown>) ?? {};
		finalScore = profileScore * 0.4 + conversationScore * 0.6;
		layerData = {
			score_details: {
				...existingDetails,
				conversation_analysis: analysis,
				fox_feature_scores: foxFeatureScores,
			} as Json,
		};
	}

	await ensureCurrentAccess("active");
	const { error: matchUpdateError } = await supabase
		.from("matches")
		.update({
			conversation_score: conversationScore,
			final_score: finalScore,
			...layerData,
			status: "fox_conversation_completed",
			updated_at: new Date().toISOString(),
		})
		.eq("id", conv.match_id)
		.eq("user_a_id", userA)
		.eq("user_b_id", userB)
		.eq("status", "fox_conversation_in_progress")
		.select("id")
		.single();
	if (matchUpdateError) {
		console.error("[runConversationLoop] Failed to save scores to matches");
		throw supabaseOperationError("save match scores");
	}
	await ensureCurrentAccess("terminal");
	const { error: completionError } = await supabase
		.from("fox_conversations")
		.update({
			status: "completed",
			current_round: TOTAL_ROUNDS_LOCAL,
			conversation_analysis: analysis as Json,
			...tokenTotalsForUpdate(),
			completed_at: new Date().toISOString(),
		})
		.eq("id", conversationId)
		.eq("match_id", conv.match_id)
		.in("status", ["pending", "in_progress"])
		.select("id")
		.single();
	if (completionError) throw supabaseOperationError("mark conversation completed");

	// Terminal persistence has succeeded. Re-read once before returning the
	// analysis to callers so an access change after the writes suppresses the
	// result without turning a completed conversation back into a failure.
	const completedOutputAccess = await checkFoxConversationCurrentAccess(supabase, accessExpectation, "completed");
	const completedJudgeAccess = deps.generationWindow?.kind === "registered-judge"
		? await readJudgeAccess(judgeRpcClient(supabase), deps.generationWindow.config, deps.generationWindow.access.actorId)
		: undefined;
	if (!completedOutputAccess.ok || (deps.generationWindow?.kind === "registered-judge"
		&& (!completedJudgeAccess || completedJudgeAccess.counterpartId !== deps.generationWindow.access.counterpartId))) {
		console.warn(`[runConversationLoop] Completed output suppressed conversationId=${conversationId}`);
		return { conversationScore, finalScore, analysis: {}, outputSuppressed: true };
	}

	return { conversationScore, finalScore, analysis };
	} catch (err) {
		// Tokens already spent are billed by Mistral even when the conversation
		// never reaches "completed", so persist whatever accumulated before
		// propagating. The try deliberately spans everything after the first
		// paid call — including scoring and the matches update, which throw on
		// their own — because by then the entire token spend has happened. The
		// engine itself never sets fox_conversations/matches status to failed;
		// the caller (runFoxConversation's own catch, or FoxConversationDO's
		// alarm() catch calling failConversation) owns that.
		// Same "supabase-js resolves, never rejects, on a PostgREST error"
		// caveat as the checkpoint retry above — but here we are already
		// unwinding on `err` and must not swallow it, so this is a
		// best-effort persist: check the result and log loudly on failure
		// (rather than silently discarding it), but always propagate the
		// original `err` regardless of whether this checkpoint succeeded.
		try {
			// Accounting-only exception: preserve tokens for provider calls that were
			// already billed, even if the rehearsal window closed while they ran.
			// This writes no messages, scores, or completion state.
			const { error: checkpointError } = await supabase.from("fox_conversations").update(tokenTotalsForUpdate()).eq("id", conversationId);
			if (checkpointError) {
				console.error(`[runConversationLoop] Failed to persist checkpoint token totals while handling an error, conversationId=${conversationId}`);
			}
		} catch {
			console.error(`[runConversationLoop] Failed to persist checkpoint token totals while handling an error, conversationId=${conversationId}`);
		}
		throw err;
	}
}
