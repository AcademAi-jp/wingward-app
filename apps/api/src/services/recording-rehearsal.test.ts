import { describe, expect, it, vi } from "vitest";
import {
	RECORDING_REHEARSAL_GENERATION_PAIRS,
	RECORDING_REHEARSAL_GOOGLE_DAILY_UNIT_LIMITS,
	RECORDING_REHEARSAL_OPERATION_BOUNDS,
	RECORDING_REHEARSAL_PROFILE_IDS,
	RECORDING_REHEARSAL_SORA_INTERVIEW_MAX_WINDOW_MS,
	RECORDING_REHEARSAL_SORA_INTERVIEW_MIN_BOOTSTRAP_REMAINING_MS,
	RECORDING_REHEARSAL_SORA_PROFILE_ID,
	createRecordingRehearsalGoogleReservationGuard,
	hasRecordingRehearsalConfig,
	isRecordingRehearsalGenerationProfile,
	isRecordingRehearsalProfile,
	isRecordingRehearsalSoraInterviewActive,
	matchesRecordingRehearsalSoraInterviewMutation,
	matchesRecordingRehearsalRoute,
	readRecordingRehearsalConfig,
} from "./recording-rehearsal";

const NOW = Date.parse("2026-09-26T20:00:00.000Z");
const VALID = {
	RECORDING_REHEARSAL_ENABLED: "enabled",
	RECORDING_REHEARSAL_ISSUED_AT: "2026-09-26T19:30:00.000Z",
	RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T21:30:00.000Z",
	RECORDING_REHEARSAL_PAIR: "aoi-ren",
} as const;
const SORA_INTERVIEW_VALID = {
	...VALID,
	RECORDING_REHEARSAL_PAIR: "sora-ren",
	RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "enabled",
	RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: "2026-09-26T20:00:00.000Z",
	RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-26T20:30:00.000Z",
} as const;

describe("recording rehearsal window", () => {
	it("keeps the new configuration absent by default", () => {
		expect(hasRecordingRehearsalConfig(undefined)).toBe(false);
		expect(readRecordingRehearsalConfig(undefined, NOW)).toEqual({ kind: "absent" });
		expect(hasRecordingRehearsalConfig({ RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enabled" })).toBe(true);
		expect(readRecordingRehearsalConfig({ RECORDING_REHEARSAL_OWNER_PREP_ONLY: "enabled" }, NOW)).toEqual({ kind: "invalid" });
	});

	it("accepts only a short Sora third-interview subwindow inside the Sora/Ren gate", () => {
		const result = readRecordingRehearsalConfig(SORA_INTERVIEW_VALID, NOW);
		expect(result.kind).toBe("active");
		if (result.kind !== "active") throw new Error("Expected active recording rehearsal");
		expect(result.config.pair).toBe("sora-ren");
		expect(result.config.soraInterviewAdmission).toMatchObject({
			kind: "sora-third-interview",
			issuedAtMs: Date.parse(SORA_INTERVIEW_VALID.RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT),
			expiresAtMs: Date.parse(SORA_INTERVIEW_VALID.RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT),
		});
		expect(isRecordingRehearsalSoraInterviewActive(result.config, NOW)).toBe(true);
		expect(isRecordingRehearsalSoraInterviewActive(result.config, NOW - 1)).toBe(false);
		expect(RECORDING_REHEARSAL_SORA_PROFILE_ID).toBe("d327a193-9eeb-42b1-bac4-fb5bea3ca21f");
		expect(RECORDING_REHEARSAL_SORA_INTERVIEW_MAX_WINDOW_MS).toBe(30 * 60_000);
		expect(RECORDING_REHEARSAL_SORA_INTERVIEW_MIN_BOOTSTRAP_REMAINING_MS).toBe(6 * 60_000);
	});

	it("treats a complete disabled subwindow as an explicit tombstone for the writable parent gate", () => {
		const disabled = {
			...SORA_INTERVIEW_VALID,
			RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled",
		};
		const result = readRecordingRehearsalConfig(disabled, Date.parse("2026-09-26T20:45:00.000Z"));
		expect(result.kind).toBe("active");
		if (result.kind !== "active") throw new Error("Expected an active parent rehearsal window");
		expect(result.config.soraInterviewAdmission).toBeUndefined();
		expect(isRecordingRehearsalSoraInterviewActive(result.config, Date.parse("2026-09-26T20:45:00.000Z"))).toBe(false);
	});

	it("allows a fresh parent window to retain the prior disabled Sora timestamps", () => {
		const result = readRecordingRehearsalConfig({
			...SORA_INTERVIEW_VALID,
			RECORDING_REHEARSAL_ISSUED_AT: "2026-09-26T20:35:00.000Z",
			RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled",
		}, Date.parse("2026-09-26T20:45:00.000Z"));
		expect(result.kind).toBe("active");
		if (result.kind !== "active") throw new Error("Expected a fresh active parent window");
		expect(result.config.soraInterviewAdmission).toBeUndefined();
	});

	it.each([
		{ name: "partial Sora fields", env: { ...SORA_INTERVIEW_VALID, RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: undefined } },
		{ name: "partial disabled tombstone", env: { ...SORA_INTERVIEW_VALID, RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled", RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: undefined } },
		{ name: "disabled tombstone with another pair", env: { ...SORA_INTERVIEW_VALID, RECORDING_REHEARSAL_PAIR: "aoi-ren", RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled" } },
		{ name: "disabled tombstone issued too far in the future", env: { ...SORA_INTERVIEW_VALID, RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disabled", RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT: "2026-09-26T20:05:00.001Z" } },
		{ name: "unknown subwindow mode", env: { ...SORA_INTERVIEW_VALID, RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED: "disable" } },
		{ name: "wrong base pair", env: { ...SORA_INTERVIEW_VALID, RECORDING_REHEARSAL_PAIR: "aoi-ren" } },
		{ name: "too long", env: { ...SORA_INTERVIEW_VALID, RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-26T20:30:00.001Z" } },
		{ name: "outside parent expiry", env: { ...SORA_INTERVIEW_VALID, RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-26T21:31:00.000Z" } },
		{ name: "expired subwindow", env: { ...SORA_INTERVIEW_VALID, RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT: "2026-09-26T20:00:00.000Z" } },
	])("rejects $name Sora admission config", ({ env }) => {
		expect(hasRecordingRehearsalConfig(env)).toBe(true);
		expect(readRecordingRehearsalConfig(env, NOW)).toEqual({ kind: "invalid" });
	});

	it.each([
		{ name: "partial fields", env: { RECORDING_REHEARSAL_ENABLED: "enabled" } },
		{ name: "wrong enable value", env: { ...VALID, RECORDING_REHEARSAL_ENABLED: "true" } },
		{ name: "missing pair selector", env: { ...VALID, RECORDING_REHEARSAL_PAIR: undefined } },
		{ name: "unknown pair selector", env: { ...VALID, RECORDING_REHEARSAL_PAIR: "aoi-sora" } },
		{ name: "offset timestamp", env: { ...VALID, RECORDING_REHEARSAL_ISSUED_AT: "2026-09-26T19:30:00+00:00" } },
		{ name: "normalized invalid calendar day", env: { ...VALID, RECORDING_REHEARSAL_EXPIRES_AT: "2026-02-30T21:30:00Z" } },
		{ name: "expiry before issue", env: { ...VALID, RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T19:00:00Z" } },
		{ name: "expiry more than two hours after issue", env: { ...VALID, RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T21:30:00.001Z" } },
		{ name: "issued too far in the future", env: { ...VALID, RECORDING_REHEARSAL_ISSUED_AT: "2026-09-26T20:05:00.001Z" } },
		{ name: "already expired", env: { ...VALID, RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T20:00:00.000Z" } },
	])("rejects $name as present-invalid configuration", ({ env }) => {
		expect(hasRecordingRehearsalConfig(env)).toBe(true);
		expect(readRecordingRehearsalConfig(env, NOW)).toEqual({ kind: "invalid" });
	});

	it("accepts a strict window with at most five minutes of clock skew", () => {
		const result = readRecordingRehearsalConfig({
			...VALID,
			RECORDING_REHEARSAL_ISSUED_AT: "2026-09-26T20:05:00.000Z",
			RECORDING_REHEARSAL_EXPIRES_AT: "2026-09-26T22:05:00.000Z",
		}, NOW);
		expect(result.kind).toBe("active");
		if (result.kind !== "active") throw new Error("Expected active rehearsal");
		expect(result.config.profileIds).toEqual(RECORDING_REHEARSAL_PROFILE_IDS);
		expect(result.config.pair).toBe("aoi-ren");
		expect(result.config.generationPair).toEqual(RECORDING_REHEARSAL_GENERATION_PAIRS["aoi-ren"]);
		expect(isRecordingRehearsalProfile(result.config, RECORDING_REHEARSAL_PROFILE_IDS[2], NOW)).toBe(true);
		expect(isRecordingRehearsalProfile(result.config, "22222222-2222-4222-8222-222222222222", NOW)).toBe(false);
		expect(isRecordingRehearsalGenerationProfile(result.config, RECORDING_REHEARSAL_PROFILE_IDS[0], NOW)).toBe(true);
		expect(isRecordingRehearsalGenerationProfile(result.config, RECORDING_REHEARSAL_PROFILE_IDS[1], NOW)).toBe(true);
		expect(isRecordingRehearsalGenerationProfile(result.config, RECORDING_REHEARSAL_PROFILE_IDS[2], NOW)).toBe(false);
		const soraRen = readRecordingRehearsalConfig({ ...VALID, RECORDING_REHEARSAL_PAIR: "sora-ren" }, NOW);
		if (soraRen.kind !== "active") throw new Error("Expected active Sora/Ren rehearsal");
		expect(isRecordingRehearsalGenerationProfile(soraRen.config, RECORDING_REHEARSAL_PROFILE_IDS[2], NOW)).toBe(true);
		expect(soraRen.config.generationPair).toEqual(RECORDING_REHEARSAL_GENERATION_PAIRS["sora-ren"]);
		expect(RECORDING_REHEARSAL_GOOGLE_DAILY_UNIT_LIMITS).toEqual({
			google_places_text_search: 10,
			google_places_nearby_search: 5,
			google_places_details: 20,
			google_routes_matrix: 80,
		});
		expect(RECORDING_REHEARSAL_OPERATION_BOUNDS).toEqual({
			compatibilityConversations: 1,
			compatibilityTurnsPerConversation: 10,
			realtimeVoiceSessions: 2,
			realtimeVoiceMaxSeconds: 180,
		});
	});

	it("keeps exact path and method boundaries for the native chat flow", () => {
		expect(matchesRecordingRehearsalRoute("POST", "/api/partner-fox-chats")).toBe(true);
		expect(matchesRecordingRehearsalRoute("GET", "/api/partner-fox-chats/11111111-1111-4111-8111-111111111111")).toBe(true);
		expect(matchesRecordingRehearsalRoute("GET", "/api/partner-fox-chats/11111111-1111-4111-8111-111111111111/messages")).toBe(true);
		expect(matchesRecordingRehearsalRoute("GET", "/api/auth/me")).toBe(true);
		expect(matchesRecordingRehearsalRoute("POST", "/api/profiles/me/confirm")).toBe(true);
		expect(matchesRecordingRehearsalRoute("POST", "/api/recording-rehearsal/matching/preview")).toBe(true);
		expect(matchesRecordingRehearsalRoute("POST", "/api/recording-rehearsal/matching/start")).toBe(true);
		expect(matchesRecordingRehearsalRoute("POST", "/api/matches/11111111-1111-4111-8111-111111111111/fox-conversation")).toBe(true);
		expect(matchesRecordingRehearsalRoute("GET", "/api/direct-chats")).toBe(true);
		expect(matchesRecordingRehearsalRoute("GET", "/api/direct-chats/11111111-1111-4111-8111-111111111111/messages")).toBe(true);
		expect(matchesRecordingRehearsalRoute("POST", "/api/direct-chats/11111111-1111-4111-8111-111111111111/messages")).toBe(true);
		expect(matchesRecordingRehearsalRoute("POST", "/api/direct-chats/11111111-1111-4111-8111-111111111111/messages/send-recovery")).toBe(true);
		expect(matchesRecordingRehearsalRoute("PUT", "/api/direct-chats/11111111-1111-4111-8111-111111111111/messages/22222222-2222-4222-8222-222222222222/read")).toBe(true);
		expect(matchesRecordingRehearsalRoute("POST", "/api/chat-meetups/rooms/11111111-1111-4111-8111-111111111111/actions")).toBe(true);
		expect(matchesRecordingRehearsalRoute("GET", "/api/meetup-reflections/11111111-1111-4111-8111-111111111111")).toBe(true);
		expect(matchesRecordingRehearsalRoute("POST", "/api/meetup-reflections/11111111-1111-4111-8111-111111111111/bootstrap")).toBe(true);
		for (const [method, path] of [
			["POST", "/api/partner-fox-chats/11111111-1111-4111-8111-111111111111/messages"],
			["POST", "/api/partner-fox-chats/11111111-1111-4111-8111-111111111111/messages/send-recovery"],
			["GET", "/api/partner-fox-chats/not-a-uuid"],
			["POST", "/api/partner-fox-chats/extra"],
			["GET", "/api/billing/status"],
			["GET", "/api/profiles/me/confirm"],
			["POST", "/api/profiles/me/confirm/extra"],
			["POST", "/api/profiles/generate"],
			["GET", "/api/recording-rehearsal/matching/preview"],
			["POST", "/api/recording-rehearsal/matching/start/extra"],
			["POST", "/api/recording-rehearsal/matching/preview/"],
			["DELETE", "/api/recording-rehearsal/matching/start"],
			["GET", "/api/matches/11111111-1111-4111-8111-111111111111/fox-conversation"],
			["POST", "/api/matches/not-a-uuid/fox-conversation"],
			["POST", "/api/matches/11111111-1111-4111-8111-111111111111/fox-conversation/extra"],
			["POST", "/api/webhooks/revenuecat"],
			["GET", "/api/internal/daily-batch/status"],
			["GET", "/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/native-bootstrap"],
			["POST", "/api/speed-dating/sessions/not-a-uuid/realtime-bootstrap"],
			["GET", "/api/meetup-reflections/11111111-1111-4111-8111-111111111111/bootstrap"],
			["POST", "/api/meetup-reflections/11111111-1111-4111-8111-111111111111/realtime-bootstrap"],
			["POST", "/api/meetup-reflections/not-a-uuid/bootstrap"],
			["POST", "/api/meetup-reflections/11111111-1111-4111-8111-111111111111/bootstrap/extra"],
			["GET", "/api/direct-chats/not-a-uuid/messages"],
			["POST", "/api/direct-chats/11111111-1111-4111-8111-111111111111/messages/send-recovery/extra"],
			["PUT", "/api/direct-chats/11111111-1111-4111-8111-111111111111/messages/invalid/read"],
			["GET", "/api/direct-chats/11111111-1111-4111-8111-111111111111/messages/send-recovery"],
			["GET", "/api/chat-meetups/rooms/not-a-uuid"],
			["POST", "/api/chat-meetups/rooms/11111111-1111-4111-8111-111111111111/actions/extra"],
			["POST", "/api/meetups/11111111-1111-4111-8111-111111111111/proposals/not-a-uuid/responses"],
			["GET", "/api/auth/me/"],
		] as const) {
			expect(matchesRecordingRehearsalRoute(method, path)).toBe(false);
		}
	});

	it("matches only the three exact interview mutation routes", () => {
		expect(matchesRecordingRehearsalSoraInterviewMutation("POST", "/api/speed-dating/sessions")).toBe(true);
		expect(matchesRecordingRehearsalSoraInterviewMutation("POST", "/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/realtime-bootstrap")).toBe(true);
		expect(matchesRecordingRehearsalSoraInterviewMutation("POST", "/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/complete")).toBe(true);
		for (const [method, path] of [
			["GET", "/api/speed-dating/sessions"],
			["POST", "/api/speed-dating/sessions/invalid/complete"],
			["POST", "/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/native-bootstrap"],
			["POST", "/api/speed-dating/sessions/11111111-1111-4111-8111-111111111111/complete/extra"],
		] as const) expect(matchesRecordingRehearsalSoraInterviewMutation(method, path)).toBe(false);
	});
});

describe("bounded Google paid-call admission", () => {
	it("fails closed without a validated window or admission callback", async () => {
		const configResult = readRecordingRehearsalConfig(VALID, NOW);
		if (configResult.kind !== "active") throw new Error("Expected active rehearsal");
		const noConfig = createRecordingRehearsalGoogleReservationGuard(undefined, vi.fn(), () => NOW);
		const noAdmission = createRecordingRehearsalGoogleReservationGuard(configResult.config, undefined, () => NOW);
		const call = { operation: "google_places_text_search" as const, units: 1, idempotencyKey: "11111111-1111-4111-8111-111111111111" };
		await expect(noConfig(call)).resolves.toBe(false);
		await expect(noAdmission(call)).resolves.toBe(false);
	});

	it("reserves before permitting the call and injects only the validated expiry", async () => {
		const configResult = readRecordingRehearsalConfig(VALID, NOW);
		if (configResult.kind !== "active") throw new Error("Expected active rehearsal");
		const admission = vi.fn().mockResolvedValue(true);
		const guard = createRecordingRehearsalGoogleReservationGuard(configResult.config, admission, () => NOW);
		const call = { operation: "google_routes_matrix" as const, units: 4, idempotencyKey: "11111111-1111-4111-8111-111111111111" };
		await expect(guard(call)).resolves.toBe(true);
		expect(admission).toHaveBeenCalledOnce();
		expect(admission).toHaveBeenCalledWith({
			...call,
			expiresAtMs: Date.parse(VALID.RECORDING_REHEARSAL_EXPIRES_AT),
			dailyUnitLimit: 80,
		});
	});

	it.each([
		{ operation: "google_places_details" as const, units: 0, idempotencyKey: "11111111-1111-4111-8111-111111111111" },
		{ operation: "google_routes_matrix" as const, units: 101, idempotencyKey: "11111111-1111-4111-8111-111111111111" },
		{ operation: "google_places_nearby_search" as const, units: 1, idempotencyKey: "not-a-uuid" },
	])("rejects invalid requests before admission callback", async (call) => {
		const configResult = readRecordingRehearsalConfig(VALID, NOW);
		if (configResult.kind !== "active") throw new Error("Expected active rehearsal");
		const admission = vi.fn().mockResolvedValue(true);
		const guard = createRecordingRehearsalGoogleReservationGuard(configResult.config, admission, () => NOW);
		await expect(guard(call)).resolves.toBe(false);
		expect(admission).not.toHaveBeenCalled();
	});

	it("rejects a reservation that completes after expiry before the adapter fetches", async () => {
		const configResult = readRecordingRehearsalConfig(VALID, NOW);
		if (configResult.kind !== "active") throw new Error("Expected active rehearsal");
		let clock = NOW;
		let finish!: (allowed: boolean) => void;
		const admission = vi.fn(() => new Promise<boolean>((resolve) => { finish = resolve; }));
		const guard = createRecordingRehearsalGoogleReservationGuard(configResult.config, admission, () => clock);
		const pending = guard({
			operation: "google_places_nearby_search",
			units: 1,
			idempotencyKey: "11111111-1111-4111-8111-111111111111",
		});
		await Promise.resolve();
		clock = configResult.config.expiresAtMs;
		finish(true);
		await expect(pending).resolves.toBe(false);
		expect(admission).toHaveBeenCalledOnce();
	});
});
