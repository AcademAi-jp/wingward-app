import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Database, Json } from "../db/types";

export const DURABLE_DAILY_BATCH_ALGORITHM_VERSION = "daily-matching-v1" as const;
export const DURABLE_DAILY_BATCH_PAGE_SIZE = 100;
/** Keep one Worker invocation finite; later invocations resume from SQL cursors. */
export const DURABLE_DAILY_BATCH_PAGE_BUDGET = 24;

export type DurableBatchState = "disabled" | "not_started" | "busy" | "resumable" | "completed";

export interface DurableBatchRunResult {
	state: DurableBatchState;
	batchId: string | null;
	totalUsers: number;
	usersMatched: number;
	totalMatches: number;
}

export interface DurableDailyPairSnapshot {
	user_a_id: string;
	user_b_id: string;
	eligibility_a: unknown;
	eligibility_b: unknown;
	profile_a: Record<string, unknown>;
	profile_b: Record<string, unknown>;
	persona_traits_a: unknown;
	persona_traits_b: unknown;
	profile_version_a: number;
	profile_version_b: number;
	profile_updated_at_a: string;
	profile_updated_at_b: string;
	persona_version_a: number;
	persona_version_b: number;
	blocked: boolean;
	existing_match: boolean;
}

export interface DurableDailyCandidate {
	user_a_id: string;
	user_b_id: string;
	score: number;
	score_details: Record<string, number>;
	layer_scores: Json;
	feature_scores: Json;
}

export interface DurableDailyBatchOptions {
	resumeOnly?: boolean;
	pageBudget?: number;
}

export type ScoreDurableDailyPair = (pair: DurableDailyPairSnapshot) => DurableDailyCandidate | null;

type RpcClient = {
	rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown }>;
};

const uuid = z.string().uuid();
const requiredJson = z.union([
	z.string(), z.number(), z.boolean(), z.null(),
	z.array(z.unknown()), z.record(z.string(), z.unknown()),
]);
const claimSchema = z.object({
	state: z.enum(["claimed", "busy", "completed", "not_started", "incompatible"]),
	batch_id: uuid.nullable(),
	lease_token: uuid.nullable(),
	lease_generation: z.number().int().nonnegative(),
	member_cursor: uuid.nullable(),
	member_scan_complete: z.boolean(),
	pair_cursor_user_a: uuid.nullable(),
	pair_cursor_user_b: uuid.nullable(),
	pair_scan_complete: z.boolean(),
	total_users: z.number().int().nonnegative(),
	users_matched: z.number().int().nonnegative(),
	total_matches: z.number().int().nonnegative(),
}).strict();
const memberPageSchema = z.object({
	next_user_id: uuid.nullable(),
	done: z.boolean(),
	scanned_count: z.number().int().min(0).max(DURABLE_DAILY_BATCH_PAGE_SIZE),
}).strict();
const profileSchema = z.object({
	user_id: uuid,
	basic_info: requiredJson,
	personality_tags: requiredJson,
	personality_analysis: requiredJson,
	interaction_style: requiredJson,
	interests: requiredJson,
	values: requiredJson,
	communication_style: requiredJson,
}).strict();
const eligibilitySchema = z.object({
	id: uuid,
	age_verified_at: requiredJson,
	gender_identity: requiredJson,
	preferred_genders: requiredJson,
	preference_mode: requiredJson,
	dating_market: requiredJson,
	onboarding_settings_completed_at: requiredJson,
}).strict();
const pairSchema = z.object({
	user_a_id: uuid,
	user_b_id: uuid,
	eligibility_a: eligibilitySchema,
	eligibility_b: eligibilitySchema,
	profile_a: profileSchema,
	profile_b: profileSchema,
	persona_traits_a: requiredJson,
	persona_traits_b: requiredJson,
	profile_version_a: z.number().int().positive(),
	profile_version_b: z.number().int().positive(),
	profile_updated_at_a: z.string().datetime({ offset: true }),
	profile_updated_at_b: z.string().datetime({ offset: true }),
	persona_version_a: z.number().int().nonnegative(),
	persona_version_b: z.number().int().nonnegative(),
	blocked: z.boolean(),
	existing_match: z.boolean(),
}).strict();
const pairPageSchema = z.object({
	pairs: z.array(pairSchema).max(DURABLE_DAILY_BATCH_PAGE_SIZE),
	next_user_a_id: uuid.nullable(),
	next_user_b_id: uuid.nullable(),
	done: z.boolean(),
}).strict();

function rpcClient(supabase: SupabaseClient<Database>): RpcClient {
	return supabase as unknown as RpcClient;
}

async function callRpc<T>(client: RpcClient, name: string, args: Record<string, unknown>, schema: z.ZodType<T>): Promise<T> {
	let result: { data: unknown; error: unknown };
	try {
		result = await client.rpc(name, args);
	} catch {
		throw new Error("Durable daily matching is unavailable");
	}
	if (result.error) throw new Error("Durable daily matching is unavailable");
	const parsed = schema.safeParse(result.data);
	if (!parsed.success) throw new Error("Durable daily matching returned an invalid response");
	return parsed.data;
}

function baseResult(state: DurableBatchState, batchId: string | null = null): DurableBatchRunResult {
	return { state, batchId, totalUsers: 0, usersMatched: 0, totalMatches: 0 };
}

/**
 * Runs the durable matching state machine. Snapshot and pair pages are read
 * from private SQL state, and every cursor update is fenced by the same lease.
 * The only write to user-visible matches happens in the final atomic publish
 * RPC after all pair pages have been scored.
 */
export async function executeDurableDailyBatch(
	supabase: SupabaseClient<Database>,
	batchDate: string,
	scorePair: ScoreDurableDailyPair,
	options: DurableDailyBatchOptions = {},
): Promise<DurableBatchRunResult> {
	const client = rpcClient(supabase);
	const pageBudget = options.pageBudget ?? DURABLE_DAILY_BATCH_PAGE_BUDGET;
	if (!Number.isInteger(pageBudget) || pageBudget < 1 || pageBudget > 200) {
		throw new Error("Invalid durable daily matching page budget");
	}
	const claim = await callRpc(client, "claim_durable_daily_matching_batch", {
		p_batch_date: batchDate,
		p_batch_timezone: "Asia/Tokyo",
		p_algorithm_version: DURABLE_DAILY_BATCH_ALGORITHM_VERSION,
		p_lease_seconds: 180,
		p_resume_only: options.resumeOnly === true,
	}, claimSchema);

	if (claim.state === "not_started") return baseResult("not_started");
	if (claim.state === "busy") return baseResult("busy", claim.batch_id);
	if (claim.state === "incompatible") throw new Error("Daily batch schema or algorithm version is incompatible");
	if (claim.state === "completed") {
		return {
			state: "completed",
			batchId: claim.batch_id,
			totalUsers: claim.total_users,
			usersMatched: claim.users_matched,
			totalMatches: claim.total_matches,
		};
	}
	if (!claim.batch_id || !claim.lease_token || claim.lease_generation < 1) {
		throw new Error("Durable daily matching returned an invalid lease");
	}

	const batchId = claim.batch_id;
	const lease = { p_batch_id: batchId, p_lease_token: claim.lease_token, p_lease_generation: claim.lease_generation };
	let memberCursor = claim.member_cursor;
	let membersDone = claim.member_scan_complete;
	let pairCursorA = claim.pair_cursor_user_a;
	let pairCursorB = claim.pair_cursor_user_b;
	let pairsDone = claim.pair_scan_complete;
	let pageOperations = 0;

	try {
		while (!membersDone && pageOperations < pageBudget) {
			const page = await callRpc(client, "scan_durable_daily_matching_member_page", {
				...lease,
				p_after_user_id: memberCursor,
				p_limit: DURABLE_DAILY_BATCH_PAGE_SIZE,
			}, memberPageSchema);
			memberCursor = page.next_user_id;
			membersDone = page.done;
			pageOperations++;
		}

		while (membersDone && !pairsDone && pageOperations + 2 <= pageBudget) {
			const page = await callRpc(client, "read_durable_daily_matching_pair_page", {
				...lease,
				p_after_user_a_id: pairCursorA,
				p_after_user_b_id: pairCursorB,
				p_limit: DURABLE_DAILY_BATCH_PAGE_SIZE,
			}, pairPageSchema);
			const candidates: DurableDailyCandidate[] = [];
			for (const pair of page.pairs) {
				if (pair.blocked || pair.existing_match) continue;
				const candidate = scorePair(pair);
				if (candidate) candidates.push(candidate);
			}
			const staged = await callRpc(client, "stage_durable_daily_matching_candidate_page", {
				...lease,
				p_after_user_a_id: pairCursorA,
				p_after_user_b_id: pairCursorB,
				p_next_user_a_id: page.next_user_a_id,
				p_next_user_b_id: page.next_user_b_id,
				p_candidates: candidates,
				p_done: page.done,
			}, z.boolean());
			if (!staged) throw new Error("Durable daily matching cursor was not advanced");
			pairCursorA = page.next_user_a_id;
			pairCursorB = page.next_user_b_id;
			pairsDone = page.done;
			pageOperations += 2;
		}

		if (!membersDone || !pairsDone) {
			await callRpc(client, "release_durable_daily_matching_lease", lease, z.boolean());
			return baseResult("resumable", batchId);
		}

		const published = await callRpc(client, "publish_durable_daily_matching_batch", {
			...lease,
			p_max_per_user: 1,
		}, z.object({
			state: z.literal("completed"),
			batch_id: uuid,
			total_users: z.number().int().nonnegative(),
			users_matched: z.number().int().nonnegative(),
			total_matches: z.number().int().nonnegative(),
		}).strict());
		return {
			state: "completed",
			batchId: published.batch_id,
			totalUsers: published.total_users,
			usersMatched: published.users_matched,
			totalMatches: published.total_matches,
		};
	} catch (error) {
		// Release only this still-current fence. If the RPC itself is unavailable,
		// lease expiry allows a future run to resume from the last committed cursor.
		try {
			await callRpc(client, "release_durable_daily_matching_lease", lease, z.boolean());
		} catch { /* The bounded lease expires automatically. */ }
		throw error instanceof Error && error.message.startsWith("Durable daily matching")
			? error
			: new Error("Durable daily matching could not finish");
	}
}
