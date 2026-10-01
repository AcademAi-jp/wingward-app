import { describe, expect, it } from "vitest";
import type { RecordingRehearsalGoogleReservationRequest } from "./recording-rehearsal";
import { createRecordingRehearsalGoogleAdmission } from "./recording-rehearsal-google-admission";

const KEY = "11111111-1111-4111-8111-111111111111";
const BASE_REQUEST: RecordingRehearsalGoogleReservationRequest = {
	operation: "google_places_nearby_search",
	units: 1,
	idempotencyKey: KEY,
	expiresAtMs: 2_000,
	dailyUnitLimit: 5,
};

describe("recording rehearsal Google admission counts", () => {
	it("counts repeated logical request IDs as new fetch attempts and rejects over-limit units", async () => {
		const admission = createRecordingRehearsalGoogleAdmission(() => 1_000);

		await expect(admission({ ...BASE_REQUEST, units: 3 })).resolves.toBe(true);
		await expect(admission({ ...BASE_REQUEST, units: 2 })).resolves.toBe(true);
		await expect(admission(BASE_REQUEST)).resolves.toBe(false);
	});

	it("rejects expired reservations and purges their counts before a later window", async () => {
		let nowMs = 1_000;
		const admission = createRecordingRehearsalGoogleAdmission(() => nowMs);
		await expect(admission(BASE_REQUEST)).resolves.toBe(true);

		nowMs = 2_000;
		await expect(admission(BASE_REQUEST)).resolves.toBe(false);
		await expect(admission({ ...BASE_REQUEST, expiresAtMs: 3_000 })).resolves.toBe(true);
	});

	it("rejects malformed operation limits, unit counts, expiry, and idempotency keys", async () => {
		const admission = createRecordingRehearsalGoogleAdmission(() => 1_000);
		await expect(admission({ ...BASE_REQUEST, dailyUnitLimit: 6 })).resolves.toBe(false);
		await expect(admission({ ...BASE_REQUEST, units: 0 })).resolves.toBe(false);
		await expect(admission({ ...BASE_REQUEST, expiresAtMs: Number.NaN })).resolves.toBe(false);
		await expect(admission({ ...BASE_REQUEST, idempotencyKey: "not-a-uuid" })).resolves.toBe(false);
	});
});
