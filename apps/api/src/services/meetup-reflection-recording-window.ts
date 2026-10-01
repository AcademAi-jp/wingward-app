import {
	isRecordingRehearsalActive,
	type ValidatedRecordingRehearsalConfig,
} from "./recording-rehearsal";

export type RecordingRehearsalReflectionOperation = "voice" | "draft";

export type RecordingRehearsalMeetupSession = Readonly<{
	meetup_id: unknown;
	match_id: unknown;
	room_id: unknown;
	user_a_id: unknown;
	user_b_id: unknown;
	status: unknown;
	confirmed_ends_at: unknown;
	completed_a_at: unknown;
	completed_b_at: unknown;
}>;

const CANONICAL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_ATTEMPTS_PER_OPERATION = 2;
const MAX_TRACKED_EXPIRIES_PER_ISOLATE = 4;

/**
 * Counts only provider-attempt reservations in this Worker isolate. The map
 * holds expiry timestamps and two small counters; it never stores account IDs,
 * prompts, transcripts, provider responses, or credentials. Reservations are
 * consumed before a fetch and intentionally have no refund operation.
 */
const attemptsByExpiry = new Map<number, Record<RecordingRehearsalReflectionOperation, number>>();

function persistedTimestamp(value: unknown): number | null {
	if (typeof value !== "string") return null;
	const parsed = Date.parse(value);
	return Number.isFinite(parsed) ? parsed : null;
}

/** Confirms the private server row is the selected pair's ended meetup. */
export function isRecordingRehearsalMeetupReady(
	config: ValidatedRecordingRehearsalConfig | undefined,
	meetupId: string,
	actorId: string,
	value: unknown,
	nowMs = Date.now(),
): value is RecordingRehearsalMeetupSession {
	if (!isRecordingRehearsalActive(config, nowMs) || config.ownerPrepOnly || !CANONICAL_UUID.test(meetupId) || !CANONICAL_UUID.test(actorId)) {
		return false;
	}
	if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
	const session = value as Record<string, unknown>;
	const selectedPair = config.generationPair as readonly string[];
	if (
		selectedPair.length !== 2
		|| selectedPair[0] === selectedPair[1]
		|| !selectedPair.every((id) => CANONICAL_UUID.test(id))
		|| session.meetup_id !== meetupId
		|| typeof session.match_id !== "string"
		|| !CANONICAL_UUID.test(session.match_id)
		|| typeof session.room_id !== "string"
		|| !CANONICAL_UUID.test(session.room_id)
		|| typeof session.user_a_id !== "string"
		|| typeof session.user_b_id !== "string"
		|| session.user_a_id === session.user_b_id
		|| !selectedPair.includes(session.user_a_id)
		|| !selectedPair.includes(session.user_b_id)
		|| !selectedPair.includes(actorId)
		|| !["confirmed", "completed"].includes(session.status as string)
	) {
		return false;
	}

	const confirmedEnd = persistedTimestamp(session.confirmed_ends_at);
	if (confirmedEnd === null || confirmedEnd > nowMs) return false;
	const ownCompletion = actorId === session.user_a_id
		? persistedTimestamp(session.completed_a_at)
		: actorId === session.user_b_id
			? persistedTimestamp(session.completed_b_at)
			: null;
	return ownCompletion !== null && ownCompletion <= nowMs;
}

/**
 * Reserves one bounded provider attempt for the active rehearsal. Failed or
 * timed-out fetches still consume the attempt; this count is not a dollar cap.
 */
export function reserveRecordingRehearsalReflectionAttempt(
	config: ValidatedRecordingRehearsalConfig | undefined,
	operation: RecordingRehearsalReflectionOperation,
	nowMs = Date.now(),
): boolean {
	if (
		!isRecordingRehearsalActive(config, nowMs)
		|| config.ownerPrepOnly
		|| (operation !== "voice" && operation !== "draft")
	) {
		return false;
	}
	for (const expiry of attemptsByExpiry.keys()) {
		if (expiry <= nowMs) attemptsByExpiry.delete(expiry);
	}
	let counts = attemptsByExpiry.get(config.expiresAtMs);
	if (!counts) {
		if (attemptsByExpiry.size >= MAX_TRACKED_EXPIRIES_PER_ISOLATE) return false;
		counts = { voice: 0, draft: 0 };
		attemptsByExpiry.set(config.expiresAtMs, counts);
	}
	if (counts[operation] >= MAX_ATTEMPTS_PER_OPERATION) return false;
	counts[operation] += 1;
	return true;
}
