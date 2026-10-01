import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";

/**
 * Guards for step-3b's "retry reuses the row" fix (P2 finding): a failed
 * fox_conversations row is retried in place (see routes/fox-search.ts and
 * routes/internal.ts, both of which reset status/current_round on the SAME
 * row rather than creating a new one), so runFoxConversation has to seed its
 * token accumulators from the row's pre-existing input_tokens/output_tokens/
 * cache_hit_tokens before it starts, or the terminal UPDATE silently replaces
 * the first paid attempt's spend with the second attempt's alone.
 *
 * `chatCompleteWithUsage` is mocked here (not `fetch`, unlike
 * mistral-usage.test.ts): those tests already cover the HTTP-level contract;
 * this file is purely about how runFoxConversation folds repeated usage
 * readings into the row.
 *
 * The Supabase fake is deliberately narrow: it implements only the call
 * shapes runFoxConversation actually makes for a `total_rounds: 1`
 * conversation, keyed by table name. `interaction_dna_scores` always throws
 * on `.upsert()`, which forces the 3-layer scoring branch inside
 * runFoxConversation's own try/catch to fall back to the simple scoring path
 * — deliberately, so this fake never has to model interaction_dna_scores
 * read-back or matching.ts's profile-score computation, neither of which
 * this file is testing.
 */

vi.mock("./mistral", () => ({
	chatCompleteWithUsage: vi.fn(),
	chatCompleteOnceBounded: vi.fn(),
	MISTRAL_LIGHT: "ministral-8b-2512",
}));

import { chatCompleteWithUsage, chatCompleteOnceBounded } from "./mistral";
import type { FoxConversationRecordingWindow } from "./fox-conversation-recording-window";
import { runFoxConversation } from "./fox-conversation";
import { runConversationLoop } from "./fox-conversation-engine";
import { resolveFoxConversationRecordingWindow } from "./fox-conversation-recording-window";
import { RECORDING_REHEARSAL_GENERATION_PAIRS } from "./recording-rehearsal";

const CONVERSATION_ID = "conv-1";
const MATCH_ID = "match-1";
const USER_A = "user-a";
const USER_B = "user-b";

type ExistingTokens = {
	input_tokens: number | null;
	output_tokens: number | null;
	cache_hit_tokens: number | null;
};

type CapturedUpdate = Record<string, unknown>;

type SupabaseFaults = {
	initialConversationRead?: boolean;
	matchRead?: boolean;
	personaRead?: boolean;
	profileRead?: boolean;
	inProgressUpdate?: boolean;
	roundMessageInsert?: boolean;
	currentRoundUpdate?: boolean;
	scoreHistoryRead?: boolean;
	completionUpdate?: boolean;
	invalidateAccessOnFeatureUpsert?: boolean;
	revokeAccessOnCompletionUpdate?: boolean;
};

type CurrentAccessProfile = {
	id: string;
	age_verified_at: string | null;
	gender_identity: "woman" | "man" | "nonbinary";
	preferred_genders: ("woman" | "man" | "nonbinary")[];
	preference_mode: "selected" | string;
	dating_market: "JP" | "US" | string;
	onboarding_settings_completed_at: string | null;
	gender: string;
	language: string;
	conversation_language: "ja" | "en";
};

function buildSupabaseFake(
	existing: ExistingTokens,
	faults: SupabaseFaults = {},
	options: {
		userA?: string;
		userB?: string;
		totalRounds?: number;
		personaDocuments?: Partial<Record<string, string>>;
		conversationLanguages?: Partial<Record<string, "ja" | "en">>;
	} = {},
) {
	const userA = options.userA ?? USER_A;
	const userB = options.userB ?? USER_B;
	const foxConversationUpdates: CapturedUpdate[] = [];
	let messageSelectCount = 0;
	let conversationStatus = "in_progress";
	let matchStatus = "fox_conversation_in_progress";
	let currentAccessProfiles: CurrentAccessProfile[] = [
		{
			id: userA,
			age_verified_at: "2026-08-24T00:00:00Z",
			gender_identity: "woman",
			preferred_genders: ["woman"],
			preference_mode: "selected",
			dating_market: "JP",
			onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
			gender: "female",
			language: "ja",
			conversation_language: options.conversationLanguages?.[userA] ?? "ja",
		},
		{
			id: userB,
			age_verified_at: "2026-08-24T00:00:00Z",
			gender_identity: "woman",
			preferred_genders: ["woman"],
			preference_mode: "selected",
			dating_market: "JP",
			onboarding_settings_completed_at: "2026-08-24T00:00:00Z",
			gender: "male",
			language: "ja",
			conversation_language: options.conversationLanguages?.[userB] ?? "ja",
		},
	];
	let currentBlocks: unknown = null;
	let clearBlocksAfterLookup = false;
	let currentAccessQueryError = false;

	function makeCurrentAccessRow() {
		const profileForAccess = (profile: CurrentAccessProfile) => ({
			id: profile.id,
			age_verified_at: profile.age_verified_at,
			gender_identity: profile.gender_identity,
			preferred_genders: profile.preferred_genders,
			preference_mode: profile.preference_mode,
			dating_market: profile.dating_market,
			onboarding_settings_completed_at: profile.onboarding_settings_completed_at,
		});
		const blocked = Array.isArray(currentBlocks) && currentBlocks.length > 0;
		return {
			id: CONVERSATION_ID,
			match_id: MATCH_ID,
			status: conversationStatus,
			match: {
				id: MATCH_ID,
				user_a_id: userA,
				user_b_id: userB,
				status: matchStatus,
				profile_a: {
					...profileForAccess(currentAccessProfiles[0]),
					blocks_sent: blocked ? [{ id: "synthetic-block-a-to-b", blocker_id: userA, blocked_id: userB }] : [],
				},
				profile_b: {
					...profileForAccess(currentAccessProfiles[1]),
					blocks_sent: [],
				},
			},
		};
	}

	function makeQuery(resolve: (state: QueryState) => { data: unknown; error: unknown } | never) {
		const state: QueryState = {};
		const builder = {
			select(cols: string) {
				state.select = cols;
				return builder;
			},
			eq(col: string, val: unknown) {
				(state.eq ??= []).push([col, val]);
				return builder;
			},
			in(col: string, vals: unknown[]) {
				state.in = [col, vals];
				return builder;
			},
			order() {
				return builder;
			},
			update(obj: Record<string, unknown>) {
				state.update = obj;
				return builder;
			},
			insert(obj: Record<string, unknown>) {
				state.insert = obj;
				return builder;
			},
			upsert(obj: Record<string, unknown>) {
				state.upsert = obj;
				return builder;
			},
			or() {
				return builder;
			},
			limit() {
				return builder;
			},
			single() {
				return Promise.resolve().then(() => resolve(state));
			},
			maybeSingle() {
				return Promise.resolve().then(() => resolve(state));
			},
			then(onFulfilled: (v: unknown) => unknown, onRejected?: (e: unknown) => unknown) {
				return Promise.resolve()
					.then(() => resolve(state))
					.then(onFulfilled, onRejected);
			},
		};
		return builder;
	}

	interface QueryState {
		select?: string;
		eq?: [string, unknown][];
		in?: [string, unknown[]];
		update?: Record<string, unknown>;
		insert?: Record<string, unknown>;
		upsert?: Record<string, unknown>;
	}

	const supabase = {
		from(table: string) {
			return makeQuery((state) => {
				switch (table) {
					case "fox_conversations": {
						if ((state.select ?? "").includes("match:matches!")) {
							if (currentAccessQueryError) {
								return { data: null, error: { message: "simulated current-access query failure" } };
							}
							const data = makeCurrentAccessRow();
							if (clearBlocksAfterLookup) {
								currentBlocks = null;
								clearBlocksAfterLookup = false;
							}
							return { data, error: null };
						}
						if (state.update) {
							foxConversationUpdates.push(state.update);
							if (typeof state.update.status === "string") conversationStatus = state.update.status;
							if (faults.revokeAccessOnCompletionUpdate && state.update.status === "completed") {
								currentBlocks = [{ id: "block-after-completion" }];
							}
							if (state.update.status === "in_progress" && faults.inProgressUpdate) {
								return { data: null, error: { message: "simulated in_progress update failure" } };
							}
							if (state.update.status === "completed" && faults.completionUpdate) {
								return { data: null, error: { message: "simulated completion update failure" } };
							}
							if ("current_round" in state.update && !("status" in state.update) && faults.currentRoundUpdate) {
								return { data: null, error: { message: "simulated current_round update failure" } };
							}
							return { data: null, error: null };
						}
						if (faults.initialConversationRead) {
							return { data: null, error: { message: "simulated conversation read failure" } };
						}
						// Initial select: id, match_id, total_rounds, current_round,
						// input_tokens, output_tokens, cache_hit_tokens
						return {
							data: {
								id: CONVERSATION_ID,
								match_id: MATCH_ID,
								status: conversationStatus,
								total_rounds: options.totalRounds ?? 1,
								current_round: 0,
								...existing,
							},
							error: null,
						};
					}
					case "fox_conversation_messages": {
						if (state.insert) {
							if (faults.roundMessageInsert) {
								return { data: null, error: { message: "simulated round message insert failure" } };
							}
							return { data: null, error: null };
						}
						messageSelectCount++;
						if (faults.scoreHistoryRead && messageSelectCount >= 2) {
							return { data: null, error: { message: "simulated scoring history read failure" } };
						}
						// Both the pre-loop existingMsgs select and the post-loop
						// allMsgs select can return the same empty history: neither
						// is under test here.
						return { data: [], error: null };
					}
					case "matches": {
						if (state.update) {
							if (typeof state.update.status === "string") matchStatus = state.update.status;
							return { data: { id: MATCH_ID }, error: null };
						}
						const cols = state.select ?? "";
						if (cols.includes("user_a_id")) {
							if (faults.matchRead) {
								return { data: null, error: { message: "simulated match read failure" } };
							}
							return { data: { id: MATCH_ID, user_a_id: userA, user_b_id: userB, status: matchStatus }, error: null };
						}
						// score_details lookup in the 3-layer-scoring catch fallback
						return { data: { profile_score: 50, score_details: {} }, error: null };
					}
					case "personas": {
						if (faults.personaRead) {
							return { data: null, error: { message: "simulated persona read failure" } };
						}
						const userId = state.eq?.find(([col]) => col === "user_id")?.[1];
						return {
							data: {
								compiled_document: options.personaDocuments?.[String(userId)] ?? `persona document for ${userId}`,
								name: userId === userA ? "Alice" : "Bob",
							},
							error: null,
						};
					}
					case "user_profiles": {
						if (faults.profileRead) {
							return { data: null, error: { message: "simulated profile read failure" } };
						}
						return {
							data: currentAccessProfiles,
							error: null,
						};
					}
					case "blocks": {
						const data = currentBlocks;
						if (clearBlocksAfterLookup) {
							currentBlocks = null;
							clearBlocksAfterLookup = false;
						}
						return { data, error: null };
					}
					case "interaction_dna_scores": {
						if (state.upsert) {
							if (faults.invalidateAccessOnFeatureUpsert) currentBlocks = [{ id: "block-during-feature-write" }];
							// Deliberately throws: forces the 3-layer scoring branch to
							// fall back to simple scoring, keeping this fake from having
							// to model loadFeatureScores/getProfileScoreDetailsForUsers.
							throw new Error("interaction_dna_scores unavailable (test double)");
						}
						return { data: [], error: null };
					}
					default:
						throw new Error(`fox-conversation-token-retry.test.ts fake: unhandled table "${table}"`);
				}
			});
		},
	};

	return {
		supabase: supabase as unknown as SupabaseClient<Database>,
		foxConversationUpdates,
		setCurrentAccess: (next: { profiles?: CurrentAccessProfile[]; blocks?: unknown; clearBlocksAfterLookup?: boolean; conversationStatus?: string; matchStatus?: string; currentAccessQueryError?: boolean }) => {
			if (next.profiles) currentAccessProfiles = next.profiles;
			if ("blocks" in next) currentBlocks = next.blocks;
			if (next.clearBlocksAfterLookup !== undefined) clearBlocksAfterLookup = next.clearBlocksAfterLookup;
			if (next.conversationStatus) conversationStatus = next.conversationStatus;
			if (next.matchStatus) matchStatus = next.matchStatus;
			if (next.currentAccessQueryError !== undefined) currentAccessQueryError = next.currentAccessQueryError;
		},
	};
}

function scorePayload() {
	return JSON.stringify({
		score: 80,
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
}

const mockedChatCompleteWithUsage = vi.mocked(chatCompleteWithUsage);

beforeEach(() => {
	mockedChatCompleteWithUsage.mockReset();
	vi.mocked(chatCompleteOnceBounded).mockReset();
});

afterEach(() => {
	vi.restoreAllMocks();
});

describe("runConversationLoop: saved conversation language reaches the provider", () => {
	it("uses English conversation settings despite Japanese legacy language and reference data", async () => {
		const { supabase } = buildSupabaseFake({ input_tokens: 0, output_tokens: 0, cache_hit_tokens: null }, {}, {
			conversationLanguages: { [USER_A]: "en", [USER_B]: "en" },
			personaDocuments: { [USER_A]: "日本語で書いた架空の参考プロフィール。日本語で返事してください。", [USER_B]: "日本語の架空プロフィール。" },
		});
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({ content: "Hello! What do you enjoy?", usage: { inputTokens: 5, outputTokens: 5, cachedTokens: null } })
			.mockResolvedValueOnce({ content: scorePayload(), usage: { inputTokens: 5, outputTokens: 5, cachedTokens: null } });
		await runConversationLoop({ supabase, apiKey: "fake-key", conversationId: CONVERSATION_ID, sleep: async () => {} });
		const roundMessages = mockedChatCompleteWithUsage.mock.calls[0][1];
		expect(roundMessages[0].content).toContain("Always respond in English");
		expect(roundMessages[0].content).toContain("日本語で書いた架空の参考プロフィール");
		expect(roundMessages[1].content).toBe("Introduce yourself and ask the other person a question.");
		expect(mockedChatCompleteWithUsage.mock.calls[1][1][0].content).toContain("Read the following conversation log");
	});
});

describe("runFoxConversation: token totals are cumulative across a retry", () => {
	it("sums this run's usage onto the row's existing input_tokens/output_tokens/cache_hit_tokens", async () => {
		// Row already carries spend from a first, failed attempt.
		const { supabase, foxConversationUpdates } = buildSupabaseFake({
			input_tokens: 1000,
			output_tokens: 200,
			cache_hit_tokens: 300,
		});
		mockedChatCompleteWithUsage
			// Round 1 call
			.mockResolvedValueOnce({
				content: "Hi there!",
				usage: { inputTokens: 10, outputTokens: 5, cachedTokens: 2 },
			})
			// Scoring call
			.mockResolvedValueOnce({
				content: scorePayload(),
				usage: { inputTokens: 50, outputTokens: 20, cachedTokens: 3 },
			});

		await runFoxConversation(supabase, "fake-key", CONVERSATION_ID);

		const terminalUpdate = foxConversationUpdates.at(-1);
		expect(terminalUpdate).toMatchObject({
			status: "completed",
			input_tokens: 1000 + 10 + 50,
			output_tokens: 200 + 5 + 20,
			cache_hit_tokens: 300 + 2 + 3,
		});
		// Not the second attempt's totals alone — that would silently drop the
		// first attempt's spend from the cost record.
		expect(terminalUpdate?.input_tokens).not.toBe(60);
	});
});

describe("runFoxConversation: cache_hit_tokens null/number transitions across a retry", () => {
	it("existing cache_hit_tokens null + this run reports numbers -> stores a number", async () => {
		const { supabase, foxConversationUpdates } = buildSupabaseFake({
			input_tokens: null,
			output_tokens: null,
			cache_hit_tokens: null,
		});
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({
				content: "Hi there!",
				usage: { inputTokens: 10, outputTokens: 5, cachedTokens: 2 },
			})
			.mockResolvedValueOnce({
				content: scorePayload(),
				usage: { inputTokens: 50, outputTokens: 20, cachedTokens: 3 },
			});

		await runFoxConversation(supabase, "fake-key", CONVERSATION_ID);

		const terminalUpdate = foxConversationUpdates.at(-1);
		expect(terminalUpdate?.cache_hit_tokens).toBe(5);
	});

	it("existing cache_hit_tokens a number + this run reports none -> still stores a number, not null", async () => {
		const { supabase, foxConversationUpdates } = buildSupabaseFake({
			input_tokens: 500,
			output_tokens: 100,
			cache_hit_tokens: 300,
		});
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({
				content: "Hi there!",
				usage: { inputTokens: 10, outputTokens: 5, cachedTokens: null },
			})
			.mockResolvedValueOnce({
				content: scorePayload(),
				usage: { inputTokens: 50, outputTokens: 20, cachedTokens: null },
			});

		await runFoxConversation(supabase, "fake-key", CONVERSATION_ID);

		const terminalUpdate = foxConversationUpdates.at(-1);
		// The prior attempt's 300 must survive: it was measured, and "this run
		// measured nothing new" must not revert the fact to "never measured".
		expect(terminalUpdate?.cache_hit_tokens).toBe(300);
		expect(terminalUpdate?.cache_hit_tokens).not.toBeNull();
	});
});

describe("runConversationLoop: round persistence failures fail closed", () => {
	const emptyTokens = { input_tokens: null, output_tokens: null, cache_hit_tokens: null };

	it("rejects when the round message INSERT returns a Supabase error", async () => {
		const { supabase } = buildSupabaseFake(emptyTokens, { roundMessageInsert: true });
		mockedChatCompleteWithUsage.mockResolvedValueOnce({
			content: "Hi there!",
			usage: { inputTokens: 10, outputTokens: 5, cachedTokens: 2 },
		});

		await expect(runConversationLoop({
			supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {},
		})).rejects.toThrow("persist conversation round message");
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1);
	});

	it("rejects when the current_round UPDATE returns a Supabase error", async () => {
		const { supabase } = buildSupabaseFake(emptyTokens, { currentRoundUpdate: true });
		mockedChatCompleteWithUsage.mockResolvedValueOnce({
			content: "Hi there!",
			usage: { inputTokens: 10, outputTokens: 5, cachedTokens: 2 },
		});

		await expect(runConversationLoop({
			supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {},
		})).rejects.toThrow("persist conversation current round");
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1);
	});
});

describe("runConversationLoop: current output eligibility gates", () => {
	const emptyTokens = { input_tokens: null, output_tokens: null, cache_hit_tokens: null };

	function activeRehearsalWindow() {
		const [userA, userB] = RECORDING_REHEARSAL_GENERATION_PAIRS["aoi-ren"];
		const now = Date.now();
		const generationWindow = resolveFoxConversationRecordingWindow({
			RECORDING_REHEARSAL_ENABLED: "enabled",
			RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 60_000).toISOString(),
			RECORDING_REHEARSAL_EXPIRES_AT: new Date(now + 60 * 60_000).toISOString(),
			RECORDING_REHEARSAL_PAIR: "aoi-ren",
		}, userA, userB, now);
		return { userA, userB, generationWindow };
	}

	it("does not call the provider for a rehearsal row longer than ten rounds", async () => {
		const { userA, userB, generationWindow } = activeRehearsalWindow();
		const fake = buildSupabaseFake(emptyTokens, {}, { userA, userB, totalRounds: 11 });

		await expect(runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			generationWindow,
			sleep: async () => {},
		})).rejects.toThrow("Current conversation access is no longer available");

		expect(mockedChatCompleteWithUsage).not.toHaveBeenCalled();
	});

	it("does not call the provider when a rehearsal prompt exceeds the UTF-8 cap", async () => {
		const { userA, userB, generationWindow } = activeRehearsalWindow();
		const fake = buildSupabaseFake(emptyTokens, {}, {
			userA,
			userB,
			personaDocuments: { [userA]: "日".repeat(3_000) },
		});

		await expect(runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			generationWindow,
			sleep: async () => {},
		})).rejects.toThrow("Current conversation access is no longer available");

		expect(mockedChatCompleteWithUsage).not.toHaveBeenCalled();
	});

	it("retains provider usage but suppresses the round when access changes in flight", async () => {
		const fake = buildSupabaseFake(emptyTokens);
		let resolveProvider: (result: { content: string; usage: { inputTokens: number; outputTokens: number; cachedTokens: number } }) => void = () => {};
		mockedChatCompleteWithUsage.mockImplementationOnce(
			() => new Promise((resolve) => {
				resolveProvider = resolve;
			}),
		);

		const run = runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {},
		});
		await vi.waitFor(() => expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1));

		fake.setCurrentAccess({ blocks: [{ id: "block-after-provider" }] });
		resolveProvider({ content: "paid but now forbidden", usage: { inputTokens: 11, outputTokens: 7, cachedTokens: 2 } });

		await expect(run).rejects.toThrow("Current conversation access is no longer available");
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1);
		expect(fake.foxConversationUpdates).toContainEqual({ input_tokens: 11, output_tokens: 7, cache_hit_tokens: 2 });
		expect(fake.foxConversationUpdates.some((update) => "current_round" in update)).toBe(false);
	});

	it("rejects a transient revocation at the post-provider gate before the next output write", async () => {
		const fake = buildSupabaseFake(emptyTokens);
		let resolveProvider: (result: { content: string; usage: { inputTokens: number; outputTokens: number; cachedTokens: number } }) => void = () => {};
		mockedChatCompleteWithUsage.mockImplementationOnce(
			() => new Promise((resolve) => {
				resolveProvider = resolve;
			}),
		).mockResolvedValueOnce({ content: scorePayload(), usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null } });

		const run = runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {},
		});
		await vi.waitFor(() => expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1));

		fake.setCurrentAccess({ blocks: [{ id: "one-check-revocation" }], clearBlocksAfterLookup: true });
		resolveProvider({ content: "must not be persisted", usage: { inputTokens: 11, outputTokens: 7, cachedTokens: 2 } });

		await expect(run).rejects.toThrow("Current conversation access is no longer available");
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1);
		expect(fake.foxConversationUpdates.some((update) => "current_round" in update)).toBe(false);
	});

	it("does not retry a rejected provider call after access changes during the retry wait", async () => {
		const fake = buildSupabaseFake(emptyTokens);
		let releaseRetryWait: () => void = () => {};
		let retryWaitStarted = false;
		mockedChatCompleteWithUsage.mockRejectedValueOnce(new Error("temporary provider failure"));

		const run = runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {
				retryWaitStarted = true;
				await new Promise<void>((resolve) => {
					releaseRetryWait = resolve;
				});
			},
		});
		await vi.waitFor(() => expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1));
		await vi.waitFor(() => expect(retryWaitStarted).toBe(true));

		fake.setCurrentAccess({ blocks: [{ id: "block-during-retry" }] });
		releaseRetryWait();

		await expect(run).rejects.toThrow("Current conversation access is no longer available");
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1);
	});

	it("does not retry scoring after access changes during its retry wait", async () => {
		const fake = buildSupabaseFake(emptyTokens);
		let sleepCalls = 0;
		let releaseRetryWait: () => void = () => {};
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({ content: "round one", usage: { inputTokens: 3, outputTokens: 2, cachedTokens: null } })
			.mockRejectedValueOnce(new Error("temporary scoring failure"));

		const run = runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {
				sleepCalls++;
				if (sleepCalls === 1) return;
				await new Promise<void>((resolve) => {
					releaseRetryWait = resolve;
				});
			},
		});
		await vi.waitFor(() => expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(2));

		fake.setCurrentAccess({ blocks: [{ id: "block-during-score-retry" }] });
		releaseRetryWait();

		await expect(run).rejects.toThrow("Current conversation access is no longer available");
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(2);
		expect(fake.foxConversationUpdates.some((update) => update.status === "completed")).toBe(false);
	});

	it("escapes the three-layer fallback when access changes during a scoring write", async () => {
		const fake = buildSupabaseFake(emptyTokens, { invalidateAccessOnFeatureUpsert: true });
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({ content: "round one", usage: { inputTokens: 3, outputTokens: 2, cachedTokens: null } })
			.mockResolvedValueOnce({ content: scorePayload(), usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null } });

		await expect(
			runConversationLoop({
				supabase: fake.supabase,
				apiKey: "fake-key",
				conversationId: CONVERSATION_ID,
				sleep: async () => {},
			}),
		).rejects.toThrow("Current conversation access is no longer available");
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(2);
		expect(fake.foxConversationUpdates.some((update) => update.status === "completed")).toBe(false);
	});

	it("awaits the production round callback before starting scoring", async () => {
		const fake = buildSupabaseFake(emptyTokens);
		let callbackStarted = false;
		let releaseCallback: () => void = () => {};
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({ content: "round one", usage: { inputTokens: 3, outputTokens: 2, cachedTokens: null } })
			.mockResolvedValueOnce({ content: scorePayload(), usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null } });

		const run = runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {},
			onRound: async () => {
				callbackStarted = true;
				await new Promise<void>((resolve) => {
					releaseCallback = resolve;
				});
			},
		});

		await vi.waitFor(() => expect(callbackStarted).toBe(true));
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(1);
		releaseCallback();
		await run;
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(2);
	});

	it("keeps billed scoring usage when access is revoked while the score response is in flight", async () => {
		const fake = buildSupabaseFake(emptyTokens);
		let resolveScore: (result: { content: string; usage: { inputTokens: number; outputTokens: number; cachedTokens: number } }) => void = () => {};
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({ content: "round one", usage: { inputTokens: 3, outputTokens: 2, cachedTokens: 1 } })
			.mockImplementationOnce(
				() => new Promise((resolve) => {
					resolveScore = resolve;
				}),
			);

		const run = runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {},
		});
		await vi.waitFor(() => expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(2));

		fake.setCurrentAccess({ blocks: [{ id: "block-during-score-response" }] });
		resolveScore({ content: scorePayload(), usage: { inputTokens: 13, outputTokens: 9, cachedTokens: 4 } });

		await expect(run).rejects.toThrow("Current conversation access is no longer available");
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(2);
		expect(fake.foxConversationUpdates).toContainEqual({ input_tokens: 16, output_tokens: 11, cache_hit_tokens: 5 });
		expect(fake.foxConversationUpdates.some((update) => update.status === "completed")).toBe(false);
	});

	it("does not retry or fall back when a current-access query errors after scoring", async () => {
		const fake = buildSupabaseFake(emptyTokens);
		let resolveScore: (result: { content: string; usage: { inputTokens: number; outputTokens: number; cachedTokens: null } }) => void = () => {};
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({ content: "round one", usage: { inputTokens: 3, outputTokens: 2, cachedTokens: null } })
			.mockImplementationOnce(
				() => new Promise((resolve) => {
					resolveScore = resolve;
				}),
			);

		const run = runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {},
		});
		await vi.waitFor(() => expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(2));

		fake.setCurrentAccess({ currentAccessQueryError: true });
		resolveScore({ content: scorePayload(), usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null } });

		await expect(run).rejects.toThrow("Current conversation access is no longer available");
		expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(2);
		expect(fake.foxConversationUpdates.some((update) => update.status === "completed")).toBe(false);
	});

	it("suppresses post-completion analysis while retaining terminal writes", async () => {
		const fake = buildSupabaseFake(emptyTokens, { revokeAccessOnCompletionUpdate: true });
		mockedChatCompleteWithUsage
			.mockResolvedValueOnce({ content: "round one", usage: { inputTokens: 3, outputTokens: 2, cachedTokens: null } })
			.mockResolvedValueOnce({ content: scorePayload(), usage: { inputTokens: 5, outputTokens: 4, cachedTokens: null } });

		const result = await runConversationLoop({
			supabase: fake.supabase,
			apiKey: "fake-key",
			conversationId: CONVERSATION_ID,
			sleep: async () => {},
		});

		expect(result.outputSuppressed).toBe(true);
		expect(result.analysis).toEqual({});
		expect(fake.foxConversationUpdates.some((update) => update.status === "completed")).toBe(true);
		expect(fake.foxConversationUpdates.some((update) => update.status === "failed")).toBe(false);
	});
});

describe("source-level guard: the DO path is instrumented the same way", () => {
	/**
	 * Updated for step-3d (loop unification): the round-generation call
	 * (chatCompleteWithUsage + promptCacheKey) no longer lives in
	 * durable-objects/fox-conversation-do.ts at all — it moved to
	 * services/fox-conversation-engine.ts, the single implementation the DO's
	 * alarm() now calls into. So instead of asserting the DO contains the
	 * instrumented call, this now asserts (a) the DO contains no LLM call of
	 * any kind, old or new, and (b) the engine — reached by both the DO and
	 * the local-dev fallback — is the one instrumented call site.
	 */
	it("durable-objects/fox-conversation-do.ts has no remaining bare chatComplete( call", async () => {
		const { readFileSync } = await import("node:fs");
		const { join } = await import("node:path");
		const src = readFileSync(join(__dirname, "..", "durable-objects", "fox-conversation-do.ts"), "utf8");
		// Matches a call to the old string-returning helper, not
		// `chatCompleteWithUsage(`.
		expect(src).not.toMatch(/[^a-zA-Z0-9_]chatComplete\(/);
	});

	it("durable-objects/fox-conversation-do.ts no longer calls chatCompleteWithUsage directly (moved to the engine)", async () => {
		const { readFileSync } = await import("node:fs");
		const { join } = await import("node:path");
		const src = readFileSync(join(__dirname, "..", "durable-objects", "fox-conversation-do.ts"), "utf8");
		expect(src).not.toMatch(/chatCompleteWithUsage/);
	});

	it("services/fox-conversation-engine.ts passes promptCacheKey on its round call", async () => {
		const { readFileSync } = await import("node:fs");
		const { join } = await import("node:path");
		const src = readFileSync(join(__dirname, "fox-conversation-engine.ts"), "utf8");
		expect(src).toMatch(/promptCacheKey:\s*`\$\{conversationId\}:\$\{currentSpeaker\}`/);
	});

	it("services/fox-conversation-engine.ts checkpoints provider usage before the post-result access gate", async () => {
		const { readFileSync } = await import("node:fs");
		const { join } = await import("node:path");
		const src = readFileSync(join(__dirname, "fox-conversation-engine.ts"), "utf8");
		expect(src).toMatch(/recordUsage\(result\.usage\);[\s\S]{0,400}await ensureCurrentAccess\("active"\);[\s\S]{0,100}break;/);
	});

	it("services/fox-conversation-engine.ts checks current access immediately before round provider work", async () => {
		const { readFileSync } = await import("node:fs");
		const { join } = await import("node:path");
		const src = readFileSync(join(__dirname, "fox-conversation-engine.ts"), "utf8");
		expect(src).toMatch(/for \(let attempt = 1; attempt <= MAX_RETRIES; attempt\+\+\) \{[\s\S]{0,500}await ensureCurrentAccess\("active"\);[\s\S]{0,1000}const result = registeredJudge \? await completeJudgeAttempt[\s\S]{0,100}await chatCompleteWithUsage/);
	});
});

describe("judge provider expiry boundaries",()=>{
 it.each([false,true])("suppresses generation/output if expired before provider or in flight (%s)",async inFlight=>{
  vi.useFakeTimers();const now=Date.parse("2026-09-30T10:00:00Z");vi.setSystemTime(now);
  try {
   const {DEMO_20260930_PROFILE_IDS:ids}=await import("./synthetic-matching-cohort");const [userA,userB]=ids;
   const generationWindow=resolveFoxConversationRecordingWindow({DEMO_JUDGE_ENABLED:"enabled",DEMO_JUDGE_COHORT:"demo-20260930",DEMO_JUDGE_ISSUED_AT:new Date(now).toISOString(),DEMO_JUDGE_EXPIRES_AT:new Date(now+1000).toISOString()},userA,userB,now);
   const fake=buildSupabaseFake({input_tokens:null,output_tokens:null,cache_hit_tokens:null},{},{userA,userB});const published=vi.fn();
   mockedChatCompleteWithUsage.mockImplementationOnce(async()=>{vi.setSystemTime(now+1000);return{content:"never published",usage:{inputTokens:10,outputTokens:5,cachedTokens:null}};});
   if(!inFlight)vi.setSystemTime(now+1000);
   await expect(runConversationLoop({supabase:fake.supabase,apiKey:"mock-no-network",conversationId:CONVERSATION_ID,generationWindow,onRound:published,sleep:async()=>{}})).rejects.toThrow("Current conversation access is no longer available");
   expect(mockedChatCompleteWithUsage).toHaveBeenCalledTimes(inFlight?1:0);
   expect(published).not.toHaveBeenCalled();
  }finally{vi.useRealTimers();}
 });
});

describe("registered judge Ward reservations", () => {
 const userA = "11111111-1111-4111-8111-111111111111", userB = "22222222-2222-4222-8222-222222222222";
 function judgeFake(options: { denial?: boolean; revokeOnReserve?: boolean; totalRounds?: number; expiresAtMs?: number } = {}) {
  const expiry = options.expiresAtMs ?? Date.now() + 60_000;
  const fake = buildSupabaseFake({ input_tokens: null, output_tokens: null, cache_hit_tokens: null }, {}, { userA, userB, totalRounds: options.totalRounds ?? 10 });
  let revoked = false;
  const events: string[] = [];
  const rpc = vi.fn(async (name: string) => {
   events.push(name);
   if (name === "check_judge_access") return { data: revoked ? null : { outcome: "allowed", actor_user_id: userA, account_kind: "judge", counterpart_user_id: userB, expires_at: new Date(expiry).toISOString() }, error: null };
   if (name === "reserve_judge_provider_operation") {
    if (options.revokeOnReserve) revoked = true;
    return { data: options.denial ? { outcome: "budget_exhausted" } : { outcome: "allowed", reservation_id: "33333333-3333-4333-8333-333333333333", max_units: 20_000, max_seconds: 1 }, error: null };
   }
   throw new Error("Unexpected RPC");
  });
  Object.assign(fake.supabase, { rpc });
  const generationWindow: FoxConversationRecordingWindow = { kind: "registered-judge", config: { issuedAtMs: Date.now() - 1000, expiresAtMs: expiry, aiExpiresAtMs: expiry }, access: { actorId: userA, accountKind: "judge", counterpartId: userB, expiresAtMs: expiry } };
  return { ...fake, generationWindow, rpc, events };
 }
 it("reserves each of ten rounds and scoring before one bounded provider attempt", async () => {
  const fake = judgeFake();
  vi.mocked(chatCompleteOnceBounded).mockImplementation(async (_key, _messages, options) => {
   expect(fake.events.at(-2)).toBe("reserve_judge_provider_operation");
   expect(fake.events.at(-1)).toBe("check_judge_access");
   fake.events.push("provider");
   expect(options).toMatchObject({ model: "ministral-8b-2512", maxTotalTokenUnits: 20_000, maxRequestBytes: 8192 });
   return { content: options.responseFormat ? scorePayload() : "synthetic Ward answer", finishReason: "stop", inputTokens: 100, outputTokens: 20 };
  });
  const result = await runConversationLoop({ supabase: fake.supabase, apiKey: "synthetic-key", conversationId: CONVERSATION_ID, generationWindow: fake.generationWindow, sleep: async () => {} });
  expect(result.failedBeforeStart).toBeUndefined();
  expect(vi.mocked(chatCompleteOnceBounded)).toHaveBeenCalledTimes(11);
  expect(fake.rpc.mock.calls.filter(([name]) => name === "reserve_judge_provider_operation")).toHaveLength(11);
  expect(chatCompleteWithUsage).not.toHaveBeenCalled();
 });
 it.each([{ denial: true }, { revokeOnReserve: true }, { totalRounds: 11 }])("denies provider work for %j", async options => {
  const fake = judgeFake(options);
  await expect(runConversationLoop({ supabase: fake.supabase, apiKey: "synthetic-key", conversationId: CONVERSATION_ID, generationWindow: fake.generationWindow, sleep: async () => {} })).rejects.toThrow("Current conversation access is no longer available");
  expect(chatCompleteOnceBounded).not.toHaveBeenCalled();
  expect(chatCompleteWithUsage).not.toHaveBeenCalled();
 });
 it("keeps one reservation after a failed provider call and does not retry", async () => {
  const fake = judgeFake();
  vi.mocked(chatCompleteOnceBounded).mockRejectedValueOnce(new Error("Mistral API request failed: HTTP 429"));
  await expect(runConversationLoop({ supabase: fake.supabase, apiKey: "synthetic-key", conversationId: CONVERSATION_ID, generationWindow: fake.generationWindow, sleep: async () => {} })).rejects.toThrow("429");
  expect(chatCompleteOnceBounded).toHaveBeenCalledTimes(1);
  expect(fake.rpc.mock.calls.filter(([name]) => name === "reserve_judge_provider_operation")).toHaveLength(1);
 });
 it("keeps billed usage but suppresses round output at expiry in flight", async () => {
  vi.useFakeTimers(); const now = Date.now();
  try {
   const fake = judgeFake({ expiresAtMs: now + 1000 }); const onRound = vi.fn();
   vi.mocked(chatCompleteOnceBounded).mockImplementationOnce(async () => { vi.setSystemTime(now + 1000); return { content: "suppressed synthetic result", finishReason: "stop", inputTokens: 100, outputTokens: 20 }; });
   await expect(runConversationLoop({ supabase: fake.supabase, apiKey: "synthetic-key", conversationId: CONVERSATION_ID, generationWindow: fake.generationWindow, sleep: async () => {}, onRound })).rejects.toThrow("Current conversation access is no longer available");
   expect(chatCompleteOnceBounded).toHaveBeenCalledTimes(1); expect(onRound).not.toHaveBeenCalled();
   expect(fake.foxConversationUpdates.some(update => update.input_tokens === 100 && update.output_tokens === 20)).toBe(true);
  } finally { vi.useRealTimers(); }
 });
});
