import { resolveAuthorizedPeerProfilePhotoUrl } from "../lib/profile-photo";
import { getProfilePhotoAdapter } from "../services/onboarding-settings";
import { hasJudgeAccessConfig, isJudgeAccessActive, type JudgeAccess } from "../services/judge-access";
import { Hono, type Context } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";
import { parseLimit, parseCursor } from "../lib/pagination";
import { getBatchTimeZone, getTodayInTimeZone } from "../lib/date";
import { checkVerifiedPair, filterVerifiedMatches } from "../services/match-age-access";
import { isRecordingRehearsalActive, type ValidatedRecordingRehearsalConfig } from "../services/recording-rehearsal";
import {
	MAX_MATCHING_CURRENT_SNAPSHOT_EXPECTATIONS,
	readMatchingCurrentSnapshot,
	type MatchingCurrentSnapshot,
	type MatchingCurrentSnapshotExpectation,
} from "../services/matching-current-access";

const matching = new Hono<Env>();

/** in_progress のマッチで、created_at からこの分数を超えていたら stuck とみなし failed に落とす */
const STUCK_MATCH_MINUTES = 3;

type FoxConversationRepairState =
	| { id: string; status: string; match_id: string }
	| null
	| "ambiguous";

type MatchIdentity = {
	id: string;
	user_a_id: string;
	user_b_id: string;
};

function partnerIdFor(match: MatchIdentity, userId: string): string {
	return match.user_a_id === userId ? match.user_b_id : match.user_a_id;
}

function matchingExpectation(match: MatchIdentity, userId: string): MatchingCurrentSnapshotExpectation {
	return {
		matchId: match.id,
		ownerId: userId,
		participantIds: [match.user_a_id, match.user_b_id],
	};
}

function emptyDailyResults(batchDate: string) {
	return {
		data: {
			batch_date: batchDate,
			batch_status: "completed",
			matches: [],
			is_new: false,
			conversations_completed: 0,
			conversations_failed: 0,
			total_matches: 0,
		},
	};
}

/** The judge journey uses the registry pair directly, never the global daily batch. */
async function readJudgeDailyResults(c: Context<Env>, db: ReturnType<typeof getSupabaseClient>, actor: string, access: JudgeAccess, batchDate: string) {
	c.header("Cache-Control", "private, no-store");
	const unavailable = () => jsonError(c, "INTERNAL_ERROR", "Discovery unavailable", 503);
	if (access.actorId !== actor || !isJudgeAccessActive(access)) return unavailable();
	try {
		const pair = [actor, access.counterpartId];
		const result = await db.from("matches").select("id,user_a_id,user_b_id")
			.in("user_a_id", pair).in("user_b_id", pair)
			.or(`user_a_id.eq.${actor},user_b_id.eq.${actor}`).order("profile_score", { ascending: false }).limit(20);
		if (!isJudgeAccessActive(access) || result.error || !Array.isArray(result.data)
			|| result.data.some(row => !((row.user_a_id === actor && row.user_b_id === access.counterpartId)
				|| (row.user_b_id === actor && row.user_a_id === access.counterpartId)))) return unavailable();
		const snapshot = await readMatchingCurrentSnapshot(db, result.data.map(row => matchingExpectation(row, actor)));
		if (!isJudgeAccessActive(access) || !snapshot.ok) return unavailable();
		const matches = [...snapshot.rows.values()].map(row => {
			const partner = partnerSnapshot(row, actor);
			return { id: row.id, partner_id: access.counterpartId,
				partner: { nickname: partner.nickname, avatar_url: null, persona_icon_url: null },
				status: row.status, final_score: row.final_score, profile_score: row.profile_score,
				conversation_score: row.conversation_score, score_details: row.score_details,
				fox_conversation_id: row.compatibilityConversation?.id ?? null };
		});
		return c.json({ data: { batch_date: batchDate, batch_status: "completed", matches,
			is_new: matches.length > 0, conversations_completed: matches.filter(row => row.status === "fox_conversation_completed").length,
			conversations_failed: matches.filter(row => row.status === "fox_conversation_failed").length,
			total_matches: matches.length, simulated_counterpart: true } });
	} catch { return unavailable(); }
}

function partnerSnapshot(snapshot: MatchingCurrentSnapshot, userId: string) {
	return snapshot.user_a_id === userId ? snapshot.profile_b : snapshot.profile_a;
}

function scoreSummary(value: unknown): string {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return "";
	const summary = (value as Record<string, unknown>).summary;
	return typeof summary === "string" ? summary : "";
}

function buildCompatibilityRepairMap(
	rows: Array<{ id: string; match_id: string; status: string }> | null | undefined,
): Map<string, FoxConversationRepairState> {
	const map = new Map<string, FoxConversationRepairState>();
	for (const row of rows ?? []) {
		if (map.has(row.match_id)) {
			map.set(row.match_id, "ambiguous");
			continue;
		}
		map.set(row.match_id, { id: row.id, match_id: row.match_id, status: row.status });
	}
	return map;
}

function repairError(c: Parameters<typeof jsonError>[0], message: string) {
	return jsonError(c, "INTERNAL_ERROR", message);
}

type RecordingRehearsalAwait<T> = { ok: true; value: T } | { ok: false };

async function awaitDuringRecordingRehearsal<T>(
	config: ValidatedRecordingRehearsalConfig,
	operation: () => PromiseLike<T> | T,
): Promise<RecordingRehearsalAwait<T>> {
	if (!isRecordingRehearsalActive(config)) return { ok: false };
	try {
		const value = await operation();
		return isRecordingRehearsalActive(config) ? { ok: true, value } : { ok: false };
	} catch {
		// Do not let raw database/provider exceptions escape this temporary
		// no-store read path; callers receive the same generic unavailable result.
		return { ok: false };
	}
}

function recordingRehearsalUnavailable(c: Context<Env>) {
	c.header("Cache-Control", "private, no-store");
	return jsonError(c, "INTERNAL_ERROR", "Service unavailable", 503);
}

function recordingRehearsalError(
	c: Context<Env>,
	config: ValidatedRecordingRehearsalConfig,
	message: string,
) {
	if (!isRecordingRehearsalActive(config)) return recordingRehearsalUnavailable(c);
	c.header("Cache-Control", "private, no-store");
	return repairError(c, message);
}

function recordingRehearsalDailyResults(c: Context<Env>, config: ValidatedRecordingRehearsalConfig, batchDate: string, matches: unknown[]) {
	if (!isRecordingRehearsalActive(config)) return recordingRehearsalUnavailable(c);
	const conversationsCompleted = matches.filter((match) =>
		typeof match === "object" && match !== null && "status" in match && match.status === "fox_conversation_completed",
	).length;
	const conversationsFailed = matches.filter((match) =>
		typeof match === "object" && match !== null && "status" in match && match.status === "fox_conversation_failed",
	).length;
	c.header("Cache-Control", "private, no-store");
	return c.json({
		data: {
			batch_date: batchDate,
			batch_status: "rehearsal",
			matches,
			is_new: false,
			conversations_completed: conversationsCompleted,
			conversations_failed: conversationsFailed,
			total_matches: matches.length,
		},
	});
}

async function readRecordingRehearsalDailyResults(
	c: Context<Env>,
	supabase: ReturnType<typeof getSupabaseClient>,
	userId: string,
	config: ValidatedRecordingRehearsalConfig,
	batchDate: string,
) {
	c.header("Cache-Control", "private, no-store");
	if (!isRecordingRehearsalActive(config)) return recordingRehearsalUnavailable(c);
	const pairIds: readonly string[] = [...config.generationPair];
	const [configuredA, configuredB] = pairIds;
	if (typeof configuredA !== "string" || typeof configuredB !== "string" || configuredA === configuredB) {
		return recordingRehearsalUnavailable(c);
	}
	const userA = configuredA < configuredB ? configuredA : configuredB;
	const userB = configuredA < configuredB ? configuredB : configuredA;
	if (!pairIds.includes(userId)) return recordingRehearsalDailyResults(c, config, batchDate, []);

	// The rehearsal reads only the exact canonical persisted pair. It neither
	// consults scheduler rows nor creates, repairs, or re-scores a match.
	const pairRead = await awaitDuringRecordingRehearsal(config, () => supabase
		.from("matches")
		.select("id, user_a_id, user_b_id, final_score, profile_score, conversation_score, status, score_details")
		.eq("user_a_id", userA)
		.eq("user_b_id", userB)
		.limit(2));
	if (!pairRead.ok) return recordingRehearsalUnavailable(c);
	if (pairRead.value.error || !Array.isArray(pairRead.value.data)) {
		return recordingRehearsalError(c, config, "Failed to fetch rehearsal match");
	}
	const persistedMatches = pairRead.value.data;
	if (persistedMatches.length > 1 || persistedMatches.some((match) =>
		typeof match.id !== "string" || match.user_a_id !== userA || match.user_b_id !== userB,
	)) {
		return recordingRehearsalError(c, config, "Failed to verify rehearsal match");
	}
	if (persistedMatches.length === 0) return recordingRehearsalDailyResults(c, config, batchDate, []);

	const verifiedRead = await awaitDuringRecordingRehearsal(config, () => filterVerifiedMatches(supabase, persistedMatches));
	if (!verifiedRead.ok) return recordingRehearsalUnavailable(c);
	if (!verifiedRead.value.ok) return recordingRehearsalError(c, config, "Failed to verify rehearsal match eligibility");
	if (verifiedRead.value.rows.some((match) => match.user_a_id !== userA || match.user_b_id !== userB)) {
		return recordingRehearsalError(c, config, "Failed to verify rehearsal match participants");
	}
	if (verifiedRead.value.rows.length === 0) return recordingRehearsalDailyResults(c, config, batchDate, []);

	const peerId = userId === userA ? userB : userA;
	const blockRead = await awaitDuringRecordingRehearsal(config, () => supabase
		.from("blocks")
		.select("blocker_id, blocked_id")
		.or(`and(blocker_id.eq.${userId},blocked_id.eq.${peerId}),and(blocker_id.eq.${peerId},blocked_id.eq.${userId})`));
	if (!blockRead.ok) return recordingRehearsalUnavailable(c);
	if (blockRead.value.error || !Array.isArray(blockRead.value.data)) {
		return recordingRehearsalError(c, config, "Failed to verify rehearsal safety");
	}
	if (blockRead.value.data.some((block) =>
		!pairIds.includes(block.blocker_id) || !pairIds.includes(block.blocked_id),
	)) {
		return recordingRehearsalError(c, config, "Failed to verify rehearsal safety");
	}
	const isBlocked = blockRead.value.data.some((block) =>
		(block.blocker_id === userId && block.blocked_id === peerId)
		|| (block.blocker_id === peerId && block.blocked_id === userId),
	);
	if (isBlocked) return recordingRehearsalDailyResults(c, config, batchDate, []);

	const candidate = verifiedRead.value.rows[0]!;
	if (candidate.id !== persistedMatches[0]!.id) {
		return recordingRehearsalError(c, config, "Failed to verify rehearsal match");
	}
	const partnerIds = [peerId];
	const detailsRead = await awaitDuringRecordingRehearsal(config, () => Promise.all([
		supabase.from("user_profiles").select("id, nickname, avatar_url").in("id", partnerIds),
		supabase.from("personas").select("user_id, icon_url").eq("persona_type", "wingfox").in("user_id", partnerIds),
		supabase.from("fox_conversations").select("id, match_id, purpose, status").eq("purpose", "compatibility").eq("match_id", candidate.id),
	]));
	if (!detailsRead.ok) return recordingRehearsalUnavailable(c);
	const [{ data: profiles, error: profilesError }, { data: partnerPersonas, error: partnerPersonasError }, { error: foxConvsError }] = detailsRead.value;
	if (profilesError || partnerPersonasError || foxConvsError) {
		return recordingRehearsalError(c, config, "Failed to fetch rehearsal match details");
	}
	if (profiles?.length !== 1) return recordingRehearsalError(c, config, "Failed to fetch rehearsal match participant");
	const personaIconMap = new Map((partnerPersonas ?? []).map((persona) => [persona.user_id, persona.icon_url]));

	const snapshotRead = await awaitDuringRecordingRehearsal(config, () => readMatchingCurrentSnapshot(
		supabase,
		[matchingExpectation(candidate, userId)],
	));
	if (!snapshotRead.ok) return recordingRehearsalUnavailable(c);
	if (!snapshotRead.value.ok) return recordingRehearsalError(c, config, "Failed to verify current rehearsal match");
	const snapshot = snapshotRead.value.rows.get(candidate.id);
	if (!snapshot || snapshot.id !== candidate.id || snapshot.user_a_id !== userA || snapshot.user_b_id !== userB) {
		return recordingRehearsalDailyResults(c, config, batchDate, []);
	}
	const partner = partnerSnapshot(snapshot, userId);
	if (partner.id !== peerId) return recordingRehearsalError(c, config, "Failed to verify rehearsal participant");
	const photoAdapter = getProfilePhotoAdapter(c.env);
	const photoRead = await awaitDuringRecordingRehearsal(config, async () => {
		if (!isRecordingRehearsalActive(config)) return null;
		const avatarUrl = await resolveAuthorizedPeerProfilePhotoUrl(photoAdapter, userId, snapshot, partner);
		return isRecordingRehearsalActive(config) ? avatarUrl : null;
	});
	if (!photoRead.ok || !isRecordingRehearsalActive(config)) return recordingRehearsalUnavailable(c);
	const result = {
		id: snapshot.id,
		partner_id: peerId,
		partner: {
			nickname: partner.nickname,
			avatar_url: photoRead.value,
			persona_icon_url: personaIconMap.get(peerId) ?? null,
		},
		final_score: snapshot.final_score,
		profile_score: snapshot.profile_score,
		conversation_score: snapshot.conversation_score,
		status: snapshot.status,
		fox_conversation_id: snapshot.compatibilityConversation?.id ?? null,
		score_details: snapshot.score_details,
	};
	return recordingRehearsalDailyResults(c, config, batchDate, [result]);
}

/** GET /api/matching/results */
matching.get("/results", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const limit = parseLimit(c.req.query("limit"));
	const cursor = parseCursor(c.req.query("cursor"));
	const statusFilter = c.req.query("status");
	const supabase = getSupabaseClient(c.env);

	let q = supabase
		.from("matches")
		.select(
			"id, user_a_id, user_b_id, final_score, profile_score, conversation_score, status, score_details, created_at",
		)
		.or(`user_a_id.eq.${userId},user_b_id.eq.${userId}`)
		.order("final_score", { ascending: false, nullsFirst: false });
	const judgeAccess = c.get("judge_access");
	if (judgeAccess) q = q.in("user_a_id", [judgeAccess.actorId, judgeAccess.counterpartId]).in("user_b_id", [judgeAccess.actorId, judgeAccess.counterpartId]);
	if (statusFilter) {
		const statuses = statusFilter.split(",");
		q = statuses.length === 1 ? q.eq("status", statuses[0]) : q.in("status", statuses);
	}
	if (cursor) q = q.lt("created_at", cursor);
	const { data: rows, error } = await q.limit(limit + 1);
	if (error) return repairError(c, "Failed to fetch matches");

	const candidates = rows ?? [];
	if (judgeAccess && (judgeAccess.actorId !== userId || !isJudgeAccessActive(judgeAccess)
		|| candidates.some(match => !((match.user_a_id === userId && match.user_b_id === judgeAccess.counterpartId)
			|| (match.user_b_id === userId && match.user_a_id === judgeAccess.counterpartId))))) {
		return jsonError(c, "INTERNAL_ERROR", "Discovery unavailable", 503);
	}
	if (candidates.length === 0) {
		return c.json({ data: [], next_cursor: null, has_more: false });
	}
	const verifiedCandidates = await filterVerifiedMatches(supabase, candidates);
	if (!verifiedCandidates.ok) return repairError(c, "Failed to verify match eligibility");
	const [{ data: blockedByMe, error: blockedByMeError }, { data: blockedMe, error: blockedMeError }] = await Promise.all([
		supabase.from("blocks").select("blocked_id").eq("blocker_id", userId),
		supabase.from("blocks").select("blocker_id").eq("blocked_id", userId),
	]);
	if (blockedByMeError || blockedMeError) return repairError(c, "Failed to fetch matches");
	const blockedIds = new Set([
		...(blockedByMe ?? []).map((block) => block.blocked_id),
		...(blockedMe ?? []).map((block) => block.blocker_id),
	]);
	const filteredCandidates = verifiedCandidates.rows.filter(
		(match) => !blockedIds.has(partnerIdFor(match, userId)),
	);
	const list = filteredCandidates.slice(0, limit);
	const hasMore = filteredCandidates.length > limit;
	const next = hasMore ? list[list.length - 1]?.created_at : null;
	if (list.length === 0) {
		return c.json({ data: [], next_cursor: null, has_more: false });
	}

	const partnerIds = list.map((match) => partnerIdFor(match, userId));
	const matchIds = list.map((match) => match.id);
	const [{ data: partnerPersonas, error: partnerPersonasError }, { data: foxConvs, error: foxConvsError }] = await Promise.all([
		supabase
			.from("personas")
			.select("user_id, icon_url")
			.eq("persona_type", "wingfox")
			.in("user_id", partnerIds),
		supabase
			.from("fox_conversations")
			.select("id, match_id, purpose, status")
			.eq("purpose", "compatibility")
			.in("match_id", matchIds),
	]);
	if (partnerPersonasError) return repairError(c, "Failed to fetch match participants");
	if (foxConvsError) return repairError(c, "Failed to fetch matches");
	const personaIconMap = new Map((partnerPersonas ?? []).map((persona) => [persona.user_id, persona.icon_url]));
	const fcMap = buildCompatibilityRepairMap(foxConvs);

	// バックエンドで完了/失敗しているのに matches が in_progress のままのものを同期する（DO が match を更新し損ねた場合の自己修復）
	const stuckCutoff = new Date(Date.now() - STUCK_MATCH_MINUTES * 60 * 1000).toISOString();
	for (const match of list) {
		if (match.status !== "fox_conversation_in_progress") continue;
		const fc = fcMap.get(match.id);
		if (fc && fc !== "ambiguous" && fc.status === "completed") {
			const { error: repairMatchError } = await supabase
				.from("matches")
				.update({ status: "fox_conversation_completed", updated_at: new Date().toISOString() })
				.eq("id", match.id)
				.eq("status", "fox_conversation_in_progress");
			if (repairMatchError) return repairError(c, "Failed to synchronize match status");
		} else if (fc && fc !== "ambiguous" && fc.status === "failed") {
			const { error: repairMatchError } = await supabase
				.from("matches")
				.update({ status: "fox_conversation_failed", updated_at: new Date().toISOString() })
				.eq("id", match.id)
				.eq("status", "fox_conversation_in_progress");
			if (repairMatchError) return repairError(c, "Failed to synchronize match status");
		} else if (fc !== "ambiguous" && fc?.status === "pending" && match.created_at < stuckCutoff) {
			const { data: repairedConversation, error: conversationRepairError } = await supabase
				.from("fox_conversations")
				.update({ status: "failed" })
				.eq("match_id", match.id)
				.eq("purpose", "compatibility")
				.eq("status", "pending")
				.select("id");
			if (conversationRepairError) return repairError(c, "Failed to synchronize match status");
			if (!repairedConversation?.length) continue;
			const { error: repairMatchError } = await supabase
				.from("matches")
				.update({ status: "fox_conversation_failed", updated_at: new Date().toISOString() })
				.eq("id", match.id)
				.eq("status", "fox_conversation_in_progress");
			if (repairMatchError) return repairError(c, "Failed to synchronize match status");
		}
	}

	const finalSnapshot = await readMatchingCurrentSnapshot(
		supabase,
		list.map((match) => matchingExpectation(match, userId)),
	);
	if (!finalSnapshot.ok) return repairError(c, "Failed to verify current match eligibility");

	const visible = list.filter((match) => finalSnapshot.rows.has(match.id));
	if (visible.length === 0) {
		return c.json({ data: [], next_cursor: next ?? null, has_more: hasMore });
	}

	const photoAdapter = getProfilePhotoAdapter(c.env);
	const results = await Promise.all(visible.map(async (match) => {
		const snapshot = finalSnapshot.rows.get(match.id)!;
		const partner = partnerSnapshot(snapshot, userId);
		const partnerId = snapshot.user_a_id === userId ? snapshot.user_b_id : snapshot.user_a_id;
		const conversation = snapshot.compatibilityConversation;
		return {
			id: snapshot.id,
			partner_id: partnerId,
			partner: {
				nickname: partner.nickname,
				avatar_url: await resolveAuthorizedPeerProfilePhotoUrl(photoAdapter, userId, snapshot, partner),
				persona_icon_url: personaIconMap.get(partnerId) ?? null,
			},
			final_score: snapshot.final_score,
			profile_score: snapshot.profile_score,
			conversation_score: snapshot.conversation_score,
			score_details: snapshot.score_details,
			common_tags: [] as string[],
			status: snapshot.status,
			fox_conversation_status: conversation?.status ?? null,
			fox_conversation_id: conversation?.id ?? null,
			created_at: snapshot.created_at ?? match.created_at,
		};
	}));
	return c.json({
		data: results,
		next_cursor: next ?? null,
		has_more: hasMore,
	});
});

/** GET /api/matching/results/:id */
matching.get("/results/:id", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const id = c.req.param("id");
	const supabase = getSupabaseClient(c.env);
	const { data: match, error } = await supabase
		.from("matches")
		.select("*")
		.eq("id", id)
		.or(`user_a_id.eq.${userId},user_b_id.eq.${userId}`)
		.single();
	if (error || !match) return jsonError(c, "NOT_FOUND", "Match not found");
	const partnerId = match.user_a_id === userId ? match.user_b_id : match.user_a_id;
	const judgeAccess = c.get("judge_access");
	if (judgeAccess && (judgeAccess.actorId !== userId || !isJudgeAccessActive(judgeAccess) || partnerId !== judgeAccess.counterpartId)) return jsonError(c, "NOT_FOUND", "Match not found");
	const agePair = await checkVerifiedPair(supabase, userId, partnerId);
	if (agePair.ok === false) return jsonError(c, "NOT_FOUND", "Match not found");
	const { data: blockRow, error: blockError } = await supabase
		.from("blocks")
		.select("id")
		.or(`and(blocker_id.eq.${userId},blocked_id.eq.${partnerId}),and(blocker_id.eq.${partnerId},blocked_id.eq.${userId})`)
		.limit(1)
		.maybeSingle();
	if (blockError) return repairError(c, "Failed to verify match eligibility");
	if (blockRow) return jsonError(c, "NOT_FOUND", "Match not found");
	const { error: partnerError } = await supabase
		.from("user_profiles")
		.select("nickname, avatar_url")
		.eq("id", partnerId)
		.single();
	if (partnerError) return repairError(c, "Failed to fetch match participant");

	const { data: partnerPersona, error: partnerPersonaError } = await supabase
		.from("personas")
		.select("icon_url")
		.eq("user_id", partnerId)
		.eq("persona_type", "wingfox")
		.maybeSingle();
	if (partnerPersonaError) return repairError(c, "Failed to fetch match participant");

	const { data: fcRows, error: fcError } = await supabase
		.from("fox_conversations")
		.select("id, match_id, purpose, status")
		.eq("match_id", id)
		.eq("purpose", "compatibility")
		.limit(2);
	if (fcError) return repairError(c, "Failed to fetch match conversation");
	const fc = fcRows?.length === 1 ? fcRows[0] : null;

	// 一覧と同様: in_progress のままになっている場合は fc の状態に合わせて同期。matches.created_at から3分超なら stuck とみなす
	if (match.status === "fox_conversation_in_progress" && fc) {
		const stuckCutoff = new Date(Date.now() - STUCK_MATCH_MINUTES * 60 * 1000).toISOString();
		if (fc.status === "completed") {
			const { error: repairMatchError } = await supabase
				.from("matches")
				.update({ status: "fox_conversation_completed", updated_at: new Date().toISOString() })
				.eq("id", id)
				.eq("status", "fox_conversation_in_progress");
			if (repairMatchError) return repairError(c, "Failed to synchronize match status");
		} else if (fc.status === "failed") {
			const { error: repairMatchError } = await supabase
				.from("matches")
				.update({ status: "fox_conversation_failed", updated_at: new Date().toISOString() })
				.eq("id", id)
				.eq("status", "fox_conversation_in_progress");
			if (repairMatchError) return repairError(c, "Failed to synchronize match status");
		} else if (fc.status === "in_progress") {
			// 会話が正常に実行中 → 何もしない（stuckチェックをスキップ）
		} else if (fc.status === "pending" && match.created_at < stuckCutoff) {
			const { data: repairedConversation, error: conversationRepairError } = await supabase
				.from("fox_conversations")
				.update({ status: "failed" })
				.eq("match_id", id)
				.eq("purpose", "compatibility")
				.eq("status", "pending")
				.select("id");
			if (conversationRepairError) return repairError(c, "Failed to synchronize match status");
			if (repairedConversation?.length) {
				const { error: repairMatchError } = await supabase
					.from("matches")
					.update({ status: "fox_conversation_failed", updated_at: new Date().toISOString() })
					.eq("id", id)
					.eq("status", "fox_conversation_in_progress");
				if (repairMatchError) return repairError(c, "Failed to synchronize match status");
			}
		}
	}

	const { data: pfc, error: pfcError } = await supabase.from("partner_fox_chats").select("id").eq("match_id", id).eq("user_id", userId).maybeSingle();
	const { data: cr, error: crError } = await supabase.from("chat_requests").select("status").eq("match_id", id).maybeSingle();
	const { data: room, error: roomError } = await supabase.from("direct_chat_rooms").select("id").eq("match_id", id).maybeSingle();
	if (pfcError || crError || roomError) return repairError(c, "Failed to fetch match contact state");

	const finalSnapshot = await readMatchingCurrentSnapshot(supabase, [
		matchingExpectation(match, userId),
	]);
	if (!finalSnapshot.ok) return repairError(c, "Failed to verify current match eligibility");
	const snapshot = finalSnapshot.rows.get(id);
	if (!snapshot) return jsonError(c, "NOT_FOUND", "Match not found");

	const finalPartnerId = snapshot.user_a_id === userId ? snapshot.user_b_id : snapshot.user_a_id;
	const partner = partnerSnapshot(snapshot, userId);
	const conversation = snapshot.compatibilityConversation;
	const photoAdapter = getProfilePhotoAdapter(c.env);
	return jsonData(c, {
		id: snapshot.id,
		...(judgeAccess ? { simulated_counterpart: true } : {}),
		partner_id: finalPartnerId,
		partner: {
			nickname: partner.nickname,
			avatar_url: await resolveAuthorizedPeerProfilePhotoUrl(photoAdapter, userId, snapshot, partner),
			persona_icon_url: partnerPersona?.icon_url ?? null,
		},
		profile_score: snapshot.profile_score,
		conversation_score: snapshot.conversation_score,
		final_score: snapshot.final_score,
		score_details: snapshot.score_details,
		layer_scores: snapshot.layer_scores,
		fox_summary: scoreSummary(snapshot.score_details),
		status: snapshot.status,
		fox_conversation_id: conversation?.id ?? null,
		partner_fox_chat_id: pfc?.id ?? null,
		chat_request_status: cr?.status ?? null,
		direct_chat_room_id: room?.id ?? null,
	});
});

// ─── Daily Results Endpoints ───────────────────────────────────────────

/** GET /api/matching/daily-results — 本日の日次マッチ結果取得 */
matching.get("/daily-results", requireAuth, requireAgeVerified, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const rehearsalConfig = c.get("recording_rehearsal");
	const dateParam = c.req.query("date");
	const batchDate = rehearsalConfig
		? getTodayInTimeZone(getBatchTimeZone(c.env))
		: dateParam ?? getTodayInTimeZone(getBatchTimeZone(c.env));
	const judgeAccess = c.get("judge_access");
	if (judgeAccess) return readJudgeDailyResults(c, supabase, userId, judgeAccess, getTodayInTimeZone(getBatchTimeZone(c.env)));
	if (hasJudgeAccessConfig(c.env)) return jsonError(c, "INTERNAL_ERROR", "Discovery unavailable", 503);
	if (rehearsalConfig) {
		return readRecordingRehearsalDailyResults(c, supabase, userId, rehearsalConfig, batchDate);
	}

	// The trusted production E2E journey intentionally uses a no-answer owner
	// who is never eligible for matching. Resolve that preference before any
	// daily-pair, peer, provider, or repair work so the response stays empty
	// without touching another user's data. Any unexpected owner state fails
	// closed rather than falling through to the normal matching path.
	if (c.get("production_e2e_active") === true && c.get("production_e2e_synthetic") !== true) {
		const { data: owner, error: ownerError } = await supabase
			.from("user_profiles")
			.select("preference_mode")
			.eq("id", userId)
			.maybeSingle();
		if (ownerError || owner?.preference_mode !== "no_answer") {
			return jsonError(c, "FORBIDDEN", "Forbidden");
		}
		return c.json(emptyDailyResults(batchDate));
	}

	const { data: pairs, error: pairsError } = await supabase
		.from("daily_match_pairs")
		.select("match_id")
		.eq("match_date", batchDate);

	if (pairsError) {
		return repairError(c, "Failed to fetch daily match pairs");
	}

	const dailyMatchIds = [...new Set((pairs ?? []).map((pair) => pair.match_id))];

	if (dailyMatchIds.length === 0) {
		return c.json(emptyDailyResults(batchDate));
	}

	// 当日に作成された日次マッチのうち、自分が関与するものを取得
	const { data: dayMatches, error: matchesError } = await supabase
		.from("matches")
		.select("id, user_a_id, user_b_id, final_score, profile_score, conversation_score, status, score_details")
		.in("id", dailyMatchIds)
		.or(`user_a_id.eq.${userId},user_b_id.eq.${userId}`)
		.order("final_score", { ascending: false, nullsFirst: false });

	if (matchesError) {
		return repairError(c, "Failed to fetch daily matches");
	}

	if (!dayMatches?.length) {
		return c.json(emptyDailyResults(batchDate));
	}
	const verifiedDayMatches = await filterVerifiedMatches(supabase, dayMatches);
	if (!verifiedDayMatches.ok) return repairError(c, "Failed to verify daily match eligibility");
	const [{ data: blockedByMe, error: blockedByMeError }, { data: blockedMe, error: blockedMeError }] = await Promise.all([
		supabase.from("blocks").select("blocked_id").eq("blocker_id", userId),
		supabase.from("blocks").select("blocker_id").eq("blocked_id", userId),
	]);
	if (blockedByMeError || blockedMeError) return repairError(c, "Failed to fetch daily matches");
	const blockedIds = new Set([
		...(blockedByMe ?? []).map((block) => block.blocked_id),
		...(blockedMe ?? []).map((block) => block.blocker_id),
	]);
	const filtered = verifiedDayMatches.rows.filter(
		(match) => !blockedIds.has(partnerIdFor(match, userId)),
	);
	if (filtered.length === 0) {
		return c.json(emptyDailyResults(batchDate));
	}
	if (filtered.length > MAX_MATCHING_CURRENT_SNAPSHOT_EXPECTATIONS) {
		return repairError(c, "Failed to verify current daily matches");
	}

	const partnerIds = filtered.map((match) => partnerIdFor(match, userId));
	const [{ data: profiles, error: profilesError }, { data: partnerPersonas, error: partnerPersonasError }, { error: foxConvsError }] = await Promise.all([
		supabase.from("user_profiles").select("id, nickname, avatar_url").in("id", partnerIds),
		supabase
			.from("personas")
			.select("user_id, icon_url")
			.eq("persona_type", "wingfox")
			.in("user_id", partnerIds),
		supabase
			.from("fox_conversations")
			.select("id, match_id, purpose, status")
			.eq("purpose", "compatibility")
			.in("match_id", filtered.map((match) => match.id)),
	]);
	if (profilesError || partnerPersonasError || foxConvsError) return repairError(c, "Failed to fetch daily match details");
	if (profiles?.length !== partnerIds.length) return repairError(c, "Failed to fetch daily match participants");
	const personaIconMap = new Map((partnerPersonas ?? []).map((persona) => [persona.user_id, persona.icon_url]));

	const finalSnapshot = await readMatchingCurrentSnapshot(
		supabase,
		filtered.map((match) => matchingExpectation(match, userId)),
	);
	if (!finalSnapshot.ok) return repairError(c, "Failed to verify current daily matches");

	const visible = filtered.filter((match) => finalSnapshot.rows.has(match.id));
	if (visible.length === 0) {
		return c.json(emptyDailyResults(batchDate));
	}

	const photoAdapter = getProfilePhotoAdapter(c.env);
	const results = await Promise.all(visible.map(async (match) => {
		const snapshot = finalSnapshot.rows.get(match.id)!;
		const partner = partnerSnapshot(snapshot, userId);
		const partnerId = snapshot.user_a_id === userId ? snapshot.user_b_id : snapshot.user_a_id;
		return {
			id: snapshot.id,
			partner_id: partnerId,
			partner: {
				nickname: partner.nickname,
				avatar_url: await resolveAuthorizedPeerProfilePhotoUrl(photoAdapter, userId, snapshot, partner),
				persona_icon_url: personaIconMap.get(partnerId) ?? null,
			},
			final_score: snapshot.final_score,
			profile_score: snapshot.profile_score,
			conversation_score: snapshot.conversation_score,
			status: snapshot.status,
			fox_conversation_id: snapshot.compatibilityConversation?.id ?? null,
			score_details: snapshot.score_details,
		};
	}));

	const conversationsCompleted = results.filter((match) => match.status === "fox_conversation_completed").length;
	const conversationsFailed = results.filter((match) => match.status === "fox_conversation_failed").length;

	return c.json({
		data: {
			batch_date: batchDate,
			batch_status: "completed",
			matches: results,
			is_new: results.length > 0,
			conversations_completed: conversationsCompleted,
			conversations_failed: conversationsFailed,
			total_matches: results.length,
		},
	});
});

export default matching;
