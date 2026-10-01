import {
	RECORDING_REHEARSAL_GOOGLE_DAILY_UNIT_LIMITS,
	type RecordingRehearsalGoogleAdmission,
	type RecordingRehearsalGoogleOperation,
} from "./recording-rehearsal";

const CANONICAL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_TRACKED_REHEARSAL_WINDOWS = 4;

/**
 * Creates an isolate-local, counts-only admission policy. It retains no request
 * or idempotency data, charges every admitted fetch attempt (including retries),
 * and removes counters when their trusted rehearsal window expires. Counters
 * are best-effort per isolate, not a global, durable, or dollar cap.
 */
export function createRecordingRehearsalGoogleAdmission(
	now: () => number = Date.now,
): RecordingRehearsalGoogleAdmission {
	const totalsByExpiry = new Map<number, Map<RecordingRehearsalGoogleOperation, number>>();

	return async (request) => {
		const nowMs = now();
		if (!request || typeof request !== "object" || !Number.isFinite(nowMs)) return false;
		if (!Object.prototype.hasOwnProperty.call(RECORDING_REHEARSAL_GOOGLE_DAILY_UNIT_LIMITS, request.operation)) return false;
		const operation = request.operation;
		const unitLimit = RECORDING_REHEARSAL_GOOGLE_DAILY_UNIT_LIMITS[operation];
		if (!Number.isSafeInteger(request.expiresAtMs) || request.expiresAtMs <= nowMs) return false;
		if (request.dailyUnitLimit !== unitLimit || !Number.isSafeInteger(request.units) || request.units < 1 || request.units > unitLimit) return false;
		if (typeof request.idempotencyKey !== "string" || !CANONICAL_UUID.test(request.idempotencyKey)) return false;

		for (const expiresAtMs of totalsByExpiry.keys()) {
			if (expiresAtMs <= nowMs) totalsByExpiry.delete(expiresAtMs);
		}
		let totals = totalsByExpiry.get(request.expiresAtMs);
		if (!totals) {
			if (totalsByExpiry.size >= MAX_TRACKED_REHEARSAL_WINDOWS) return false;
			totals = new Map();
			totalsByExpiry.set(request.expiresAtMs, totals);
		}
		const current = totals.get(operation) ?? 0;
		if (current + request.units > unitLimit) return false;

		// Reserve synchronously before returning so concurrent awaited callers in
		// this isolate cannot both consume the same remaining units.
		totals.set(operation, current + request.units);
		return true;
	};
}

/** One process/isolate-local counter set; no counter data leaves this module. */
export const recordingRehearsalGoogleAdmission = createRecordingRehearsalGoogleAdmission();
