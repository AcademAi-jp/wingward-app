import { describe, expect, it } from "vitest";
import { RECORDING_REHEARSAL_PROFILE_IDS, readRecordingRehearsalConfig } from "./recording-rehearsal";
import {
	isRecordingRehearsalMeetupReady,
	reserveRecordingRehearsalReflectionAttempt,
	type RecordingRehearsalMeetupSession,
} from "./meetup-reflection-recording-window";

const NOW = Date.parse("2026-09-26T20:00:00.000Z");
const MEETUP_ID = "22222222-2222-4222-8222-222222222222";
const MATCH_ID = "33333333-3333-4333-8333-333333333333";
const ROOM_ID = "44444444-4444-4444-8444-444444444444";
let expiryOffset = 0;

function activeConfig(pair = "aoi-ren") {
	expiryOffset += 1_000;
	const result = readRecordingRehearsalConfig({
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: new Date(NOW - 30_000).toISOString(),
		RECORDING_REHEARSAL_EXPIRES_AT: new Date(NOW + 5 * 60_000 + expiryOffset).toISOString(),
		RECORDING_REHEARSAL_PAIR: pair,
	}, NOW);
	if (result.kind !== "active") throw new Error("Expected an active rehearsal window");
	return result.config;
}

function readySession(config: ReturnType<typeof activeConfig>, overrides: Record<string, unknown> = {}): RecordingRehearsalMeetupSession {
	const [userA, userB] = config.generationPair;
	const past = new Date(NOW - 60_000).toISOString();
	return {
		meetup_id: MEETUP_ID,
		match_id: MATCH_ID,
		room_id: ROOM_ID,
		user_a_id: userA,
		user_b_id: userB,
		status: "completed",
		confirmed_ends_at: past,
		completed_a_at: past,
		completed_b_at: null,
		...overrides,
	};
}

describe("recording rehearsal reflection gate", () => {
	it("requires the exact selected pair and the caller's own completed, ended meetup", () => {
		const config = activeConfig();
		const session = readySession(config);
		const userA = config.generationPair[0];
		const userB = config.generationPair[1];
		expect(isRecordingRehearsalMeetupReady(config, MEETUP_ID, userA, session, NOW)).toBe(true);
		expect(isRecordingRehearsalMeetupReady(config, MEETUP_ID, userB, session, NOW)).toBe(false);
		const bothCompleted = readySession(config, { completed_b_at: new Date(NOW - 60_000).toISOString() });
		expect(isRecordingRehearsalMeetupReady(config, MEETUP_ID, userB, bothCompleted, NOW)).toBe(true);
		expect(isRecordingRehearsalMeetupReady(config, MEETUP_ID, RECORDING_REHEARSAL_PROFILE_IDS[2], session, NOW)).toBe(false);
		expect(isRecordingRehearsalMeetupReady(config, MATCH_ID, userA, session, NOW)).toBe(false);
	});

	it.each([
		{ name: "wrong pair", overrides: { user_a_id: RECORDING_REHEARSAL_PROFILE_IDS[0], user_b_id: RECORDING_REHEARSAL_PROFILE_IDS[2] } },
		{ name: "pending meetup", overrides: { status: "cafe_proposed" } },
		{ name: "future end time", overrides: { confirmed_ends_at: new Date(NOW + 1).toISOString() } },
		{ name: "missing own completion", overrides: { completed_a_at: null } },
		{ name: "malformed room UUID", overrides: { room_id: "not-a-uuid" } },
		{ name: "different meetup", overrides: { meetup_id: "55555555-5555-4555-8555-555555555555" } },
	])("rejects $name before provider admission", ({ overrides }) => {
		const config = activeConfig();
		const session = readySession(config, overrides);
		expect(isRecordingRehearsalMeetupReady(config, MEETUP_ID, config.generationPair[0], session, NOW)).toBe(false);
	});

	it("allows only two reservations of each operation per active expiry and never refunds failures", () => {
		const config = activeConfig();
		expect(reserveRecordingRehearsalReflectionAttempt(config, "voice", NOW)).toBe(true);
		expect(reserveRecordingRehearsalReflectionAttempt(config, "voice", NOW)).toBe(true);
		// A failed/timed-out provider call has no refund API; the third attempt stays closed.
		expect(reserveRecordingRehearsalReflectionAttempt(config, "voice", NOW)).toBe(false);
		expect(reserveRecordingRehearsalReflectionAttempt(config, "draft", NOW)).toBe(true);
		expect(reserveRecordingRehearsalReflectionAttempt(config, "draft", NOW)).toBe(true);
		expect(reserveRecordingRehearsalReflectionAttempt(config, "draft", NOW)).toBe(false);
	});

	it("denies reservations and session access after the trusted expiry", () => {
		const config = activeConfig();
		const afterExpiry = config.expiresAtMs;
		expect(reserveRecordingRehearsalReflectionAttempt(config, "draft", afterExpiry)).toBe(false);
		expect(isRecordingRehearsalMeetupReady(config, MEETUP_ID, config.generationPair[0], readySession(config), afterExpiry)).toBe(false);
	});
});
