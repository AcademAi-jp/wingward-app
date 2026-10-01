/** Explicit, owner-issued runtime window for the registered recording cohort. */
import { SYNTHETIC_MATCHING_PROFILE_IDS } from "./synthetic-matching-cohort";

// Legacy three-account admission remains unchanged for the original pairs.
export const RECORDING_REHEARSAL_PROFILE_IDS = SYNTHETIC_MATCHING_PROFILE_IDS;
export const RECORDING_REHEARSAL_DEMO_MAYA_PROFILE_ID = "a88a89e2-5421-5ce9-a33b-76d512898c37";

export const RECORDING_REHEARSAL_GENERATION_PAIRS = Object.freeze({
	"aoi-ren": [SYNTHETIC_MATCHING_PROFILE_IDS[0], SYNTHETIC_MATCHING_PROFILE_IDS[1]],
	"sora-ren": [SYNTHETIC_MATCHING_PROFILE_IDS[2], SYNTHETIC_MATCHING_PROFILE_IDS[1]],
	"demo-maya-ren": [RECORDING_REHEARSAL_DEMO_MAYA_PROFILE_ID, SYNTHETIC_MATCHING_PROFILE_IDS[1]],
} as const);
export type RecordingRehearsalPair = keyof typeof RECORDING_REHEARSAL_GENERATION_PAIRS;
type RecordingRehearsalGenerationPair = typeof RECORDING_REHEARSAL_GENERATION_PAIRS[RecordingRehearsalPair];

/** Permanent synthetic membership does not grant temporary recording access. */
export function recordingRehearsalProfileIds(pair: RecordingRehearsalPair): readonly string[] {
	return pair === "demo-maya-ren"
		? RECORDING_REHEARSAL_GENERATION_PAIRS[pair]
		: RECORDING_REHEARSAL_PROFILE_IDS;
}

const ENABLED_KEY = "RECORDING_REHEARSAL_ENABLED";
const ISSUED_AT_KEY = "RECORDING_REHEARSAL_ISSUED_AT";
const EXPIRES_AT_KEY = "RECORDING_REHEARSAL_EXPIRES_AT";
const PAIR_KEY = "RECORDING_REHEARSAL_PAIR";
const SORA_INTERVIEW_ENABLED_KEY = "RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED";
const SORA_INTERVIEW_ISSUED_AT_KEY = "RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT";
const SORA_INTERVIEW_EXPIRES_AT_KEY = "RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT";
const OWNER_PREP_ONLY_KEY = "RECORDING_REHEARSAL_OWNER_PREP_ONLY";
const SYNTHETIC_TEST_ADMISSION_ID_KEY = "RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID";
const SORA_PROFILE_REVISION_KEY = "RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED";
const CONFIG_KEYS = [
	ENABLED_KEY, ISSUED_AT_KEY, EXPIRES_AT_KEY, PAIR_KEY,
	SORA_INTERVIEW_ENABLED_KEY, SORA_INTERVIEW_ISSUED_AT_KEY, SORA_INTERVIEW_EXPIRES_AT_KEY,
	OWNER_PREP_ONLY_KEY, SORA_PROFILE_REVISION_KEY, SYNTHETIC_TEST_ADMISSION_ID_KEY,
] as const;
const STRICT_UTC_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;
const CANONICAL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_ISSUED_IN_FUTURE_MS = 5 * 60_000;
const MAX_WINDOW_MS = 2 * 60 * 60_000;
const MAX_PROVIDER_UNITS_PER_CALL = 100;
export const RECORDING_REHEARSAL_SORA_INTERVIEW_MAX_WINDOW_MS = 30 * 60_000;
/** Preserve the 180-second client interview target plus a short completion buffer before minting a token. */
export const RECORDING_REHEARSAL_SORA_INTERVIEW_MIN_BOOTSTRAP_REMAINING_MS = 6 * 60_000;
export const RECORDING_REHEARSAL_SORA_PROFILE_ID = SYNTHETIC_MATCHING_PROFILE_IDS[2];

export type RecordingRehearsalBindings = Readonly<{
	RECORDING_REHEARSAL_ENABLED?: string;
	RECORDING_REHEARSAL_ISSUED_AT?: string;
	RECORDING_REHEARSAL_EXPIRES_AT?: string;
	RECORDING_REHEARSAL_PAIR?: string;
	RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID?: string;
	RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED?: string;
	RECORDING_REHEARSAL_SORA_INTERVIEW_ISSUED_AT?: string;
	RECORDING_REHEARSAL_SORA_INTERVIEW_EXPIRES_AT?: string;
	RECORDING_REHEARSAL_OWNER_PREP_ONLY?: string;
	RECORDING_REHEARSAL_BILLING_ONLY?: string;
	RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED?: string;
}>;

export type ValidatedSoraRecordingInterviewAdmission = Readonly<{
	kind: "sora-third-interview";
	issuedAt: string;
	expiresAt: string;
	issuedAtMs: number;
	expiresAtMs: number;
}>;

export type ValidatedRecordingRehearsalConfig = Readonly<{
	kind: "active";
	issuedAt: string;
	expiresAt: string;
	issuedAtMs: number;
	expiresAtMs: number;
	profileIds: readonly string[];
	ownerPrepOnly?: boolean;
	syntheticTestAdmissionId?: string;
	pair: RecordingRehearsalPair;
	generationPair: RecordingRehearsalGenerationPair;
	soraInterviewAdmission?: ValidatedSoraRecordingInterviewAdmission;
}>;

export type RecordingRehearsalConfigResult =
	| Readonly<{ kind: "absent" }>
	| Readonly<{ kind: "invalid" }>
	| Readonly<{ kind: "active"; config: ValidatedRecordingRehearsalConfig }>;

/**
 * Presence is checked independently of validity so partial, malformed,
 * expired, or disabled rehearsal bindings can never fall through to normal
 * scheduled work or the older E2E configuration.
 */
export function hasRecordingRehearsalConfig(env: RecordingRehearsalBindings | undefined): boolean {
	return env?.RECORDING_REHEARSAL_BILLING_ONLY !== undefined || CONFIG_KEYS.some((key) => env?.[key] !== undefined);
}

function parseStrictUtcIso(value: unknown): number | null {
	if (typeof value !== "string" || !STRICT_UTC_ISO.test(value)) return null;
	const parsed = Date.parse(value);
	if (!Number.isFinite(parsed)) return null;
	const canonical = new Date(parsed).toISOString();
	const normalized = value.endsWith("Z") && !value.includes(".")
		? `${value.slice(0, -1)}.000Z`
		: value;
	return canonical === normalized ? parsed : null;
}

export function isRecordingRehearsalActive(config: ValidatedRecordingRehearsalConfig | undefined, nowMs = Date.now()): config is ValidatedRecordingRehearsalConfig {
	return config !== undefined
		&& Number.isFinite(nowMs)
		&& nowMs < config.expiresAtMs
		&& config.issuedAtMs <= nowMs + MAX_ISSUED_IN_FUTURE_MS;
}

export function readRecordingRehearsalConfig(
	env: RecordingRehearsalBindings | undefined,
	nowMs = Date.now(),
): RecordingRehearsalConfigResult {
	if (!hasRecordingRehearsalConfig(env)) return { kind: "absent" };
	if (env?.RECORDING_REHEARSAL_ENABLED !== "enabled" || !Number.isFinite(nowMs)) return { kind: "invalid" };
	const pair = env.RECORDING_REHEARSAL_PAIR;
	if (pair !== "aoi-ren" && pair !== "sora-ren" && pair !== "demo-maya-ren") return { kind: "invalid" };

	const ownerPrepBinding = env.RECORDING_REHEARSAL_OWNER_PREP_ONLY;
	if (ownerPrepBinding !== undefined && ownerPrepBinding !== "enabled" && ownerPrepBinding !== "disabled") return { kind: "invalid" };
	const ownerPrepOnly = ownerPrepBinding === "enabled";
	const syntheticTestAdmissionId = env.RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID;
	if (syntheticTestAdmissionId !== undefined && (!CANONICAL_UUID.test(syntheticTestAdmissionId)
		|| pair !== "demo-maya-ren" || ownerPrepOnly)) return { kind: "invalid" };

	const issuedAtMs = parseStrictUtcIso(env.RECORDING_REHEARSAL_ISSUED_AT);
	const expiresAtMs = parseStrictUtcIso(env.RECORDING_REHEARSAL_EXPIRES_AT);
	if (issuedAtMs === null || expiresAtMs === null) return { kind: "invalid" };
	if (issuedAtMs > nowMs + MAX_ISSUED_IN_FUTURE_MS) return { kind: "invalid" };
	if (expiresAtMs <= nowMs || expiresAtMs <= issuedAtMs || expiresAtMs - issuedAtMs > MAX_WINDOW_MS) {
		return { kind: "invalid" };
	}

	const soraInterviewKeys = [
		SORA_INTERVIEW_ENABLED_KEY,
		SORA_INTERVIEW_ISSUED_AT_KEY,
		SORA_INTERVIEW_EXPIRES_AT_KEY,
	] as const;
	const hasSoraInterviewBinding = soraInterviewKeys.some((key) => env?.[key] !== undefined);
	let soraInterviewAdmission: ValidatedSoraRecordingInterviewAdmission | undefined;
	if (hasSoraInterviewBinding) {
		if ((pair !== "sora-ren" && pair !== "demo-maya-ren") || soraInterviewKeys.some((key) => env?.[key] === undefined)) {
			return { kind: "invalid" };
		}
		const soraInterviewEnabled = env?.[SORA_INTERVIEW_ENABLED_KEY];
		const soraInterviewIssuedAtMs = parseStrictUtcIso(env?.[SORA_INTERVIEW_ISSUED_AT_KEY]);
		const soraInterviewExpiresAtMs = parseStrictUtcIso(env?.[SORA_INTERVIEW_EXPIRES_AT_KEY]);
		if (soraInterviewIssuedAtMs === null || soraInterviewExpiresAtMs === null) return { kind: "invalid" };
		if (soraInterviewExpiresAtMs <= soraInterviewIssuedAtMs
			|| soraInterviewExpiresAtMs - soraInterviewIssuedAtMs > RECORDING_REHEARSAL_SORA_INTERVIEW_MAX_WINDOW_MS
			|| soraInterviewIssuedAtMs > nowMs + MAX_ISSUED_IN_FUTURE_MS) {
			return { kind: "invalid" };
		}
		// A new pair can preserve only a complete, expired disabled tombstone.
		// It never inherits Sora interview admission or reopens the old interval.
		if (pair === "demo-maya-ren" && (soraInterviewEnabled !== "disabled" || soraInterviewExpiresAtMs > nowMs)) {
			return { kind: "invalid" };
		}
		if (soraInterviewEnabled === "enabled") {
			if (soraInterviewExpiresAtMs <= nowMs
				|| soraInterviewIssuedAtMs < issuedAtMs
				|| soraInterviewExpiresAtMs > expiresAtMs) return { kind: "invalid" };
			soraInterviewAdmission = Object.freeze({
				kind: "sora-third-interview" as const,
				issuedAt: env[SORA_INTERVIEW_ISSUED_AT_KEY]!,
				expiresAt: env[SORA_INTERVIEW_EXPIRES_AT_KEY]!,
				issuedAtMs: soraInterviewIssuedAtMs,
				expiresAtMs: soraInterviewExpiresAtMs,
			});
		} else if (soraInterviewEnabled !== "disabled") {
			return { kind: "invalid" };
		}
	}

	return {
		kind: "active",
		config: Object.freeze({
			kind: "active" as const,
			issuedAt: env.RECORDING_REHEARSAL_ISSUED_AT!,
			expiresAt: env.RECORDING_REHEARSAL_EXPIRES_AT!,
			issuedAtMs,
			expiresAtMs,
			profileIds: recordingRehearsalProfileIds(pair),
			ownerPrepOnly,
			...(syntheticTestAdmissionId ? { syntheticTestAdmissionId } : {}),
			pair,
			generationPair: RECORDING_REHEARSAL_GENERATION_PAIRS[pair],
			...(soraInterviewAdmission ? { soraInterviewAdmission } : {}),
		}),
	};
}

export function isRecordingRehearsalSoraInterviewActive(
	config: ValidatedRecordingRehearsalConfig | undefined,
	nowMs = Date.now(),
): config is ValidatedRecordingRehearsalConfig & { soraInterviewAdmission: ValidatedSoraRecordingInterviewAdmission } {
	return config !== undefined
		&& config.pair === "sora-ren"
		&& config.soraInterviewAdmission !== undefined
		&& isRecordingRehearsalActive(config, nowMs)
		&& Number.isFinite(nowMs)
		&& nowMs >= config.soraInterviewAdmission.issuedAtMs
		&& nowMs < config.soraInterviewAdmission.expiresAtMs;
}

const SORA_INTERVIEW_SESSION_ID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
export function matchesRecordingRehearsalSoraInterviewMutation(method: string, pathname: string): boolean {
	return (method === "POST" && pathname === "/api/speed-dating/sessions")
		|| (method === "POST" && new RegExp(`^/api/speed-dating/sessions/${SORA_INTERVIEW_SESSION_ID}/(?:realtime-bootstrap|complete)$`).test(pathname));
}

export function isRecordingRehearsalProfile(
	config: ValidatedRecordingRehearsalConfig | undefined,
	profileId: string,
	nowMs = Date.now(),
): boolean {
	return isRecordingRehearsalActive(config, nowMs)
		&& config.profileIds.includes(profileId as (typeof config.profileIds)[number]);
}

export function isRecordingRehearsalGenerationProfile(
	config: ValidatedRecordingRehearsalConfig | undefined,
	profileId: string,
	nowMs = Date.now(),
): boolean {
	return isRecordingRehearsalActive(config, nowMs)
		&& (config.generationPair as readonly string[]).includes(profileId);
}

export const RECORDING_REHEARSAL_GOOGLE_DAILY_UNIT_LIMITS = Object.freeze({
	google_places_text_search: 10,
	google_places_nearby_search: 5,
	google_places_details: 20,
	google_routes_matrix: 80,
} as const);

export const RECORDING_REHEARSAL_OPERATION_BOUNDS = Object.freeze({
	compatibilityConversations: 1,
	compatibilityTurnsPerConversation: 10,
	realtimeVoiceSessions: 2,
	realtimeVoiceMaxSeconds: 180,
} as const);

/** Operation labels supplied by the server-side Google adapter. */
export type RecordingRehearsalGoogleOperation =
	| "google_places_text_search"
	| "google_places_nearby_search"
	| "google_routes_matrix"
	| "google_places_details";

export type RecordingRehearsalGoogleCall = Readonly<{
	operation: RecordingRehearsalGoogleOperation;
	/** Provider requests for Places calls; origin × destination elements for route matrices. */
	units: number;
	/** Opaque canonical UUID, reused only for retries of the same logical fetch. */
	idempotencyKey: string;
}>;

export type RecordingRehearsalGoogleReservationRequest = RecordingRehearsalGoogleCall & Readonly<{
	/** Derived only from the validated server config; never accepted from a request body. */
	expiresAtMs: number;
	/** Per-operation daily ceiling passed to the admission policy, in requests or route elements. */
	dailyUnitLimit: number;
}>;

export type RecordingRehearsalGoogleAdmission =
	(request: RecordingRehearsalGoogleReservationRequest) => Promise<boolean>;

export type RecordingRehearsalGoogleReservationHook =
	(request: RecordingRehearsalGoogleCall) => Promise<boolean>;

/**
 * Builds a per-provider-call guard. The server-side admission callback must
 * approve the request before the adapter fetches. A missing callback, invalid
 * request, failed admission, or expiry crossed while it is awaited denies the
 * provider fetch. This count-based interface does not assert or guarantee a
 * dollar cap; owner-approved activation still requires a bounded call plan.
 */
export function createRecordingRehearsalGoogleReservationGuard(
	config: ValidatedRecordingRehearsalConfig | undefined,
	admission: RecordingRehearsalGoogleAdmission | undefined,
	now: () => number = Date.now,
): RecordingRehearsalGoogleReservationHook {
	return async (request) => {
		if (!config || config.ownerPrepOnly || !admission || !isRecordingRehearsalActive(config, now())) return false;
		if (!isGoogleCallValid(request)) return false;
		let reserved = false;
		try {
			reserved = await admission({
				...request,
				expiresAtMs: config.expiresAtMs,
				dailyUnitLimit: RECORDING_REHEARSAL_GOOGLE_DAILY_UNIT_LIMITS[request.operation],
			});
		} catch {
			return false;
		}
		return reserved === true && isRecordingRehearsalActive(config, now());
	};
}

function isGoogleCallValid(value: RecordingRehearsalGoogleCall): boolean {
	return typeof value === "object"
		&& value !== null
		&& ["google_places_text_search", "google_places_nearby_search", "google_routes_matrix", "google_places_details"].includes(value.operation)
		&& Number.isSafeInteger(value.units)
		&& value.units > 0
		&& value.units <= Math.min(MAX_PROVIDER_UNITS_PER_CALL, RECORDING_REHEARSAL_GOOGLE_DAILY_UNIT_LIMITS[value.operation])
		&& typeof value.idempotencyKey === "string"
		&& CANONICAL_UUID.test(value.idempotencyKey);
}

const UUID_PATH = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const RECORDING_REHEARSAL_ROUTES: ReadonlyArray<Readonly<{ method: string; path: RegExp }>> = [
	{ method: "GET", path: /^\/api\/auth\/me$/ },
	{ method: "GET", path: /^\/api\/auth\/me\/onboarding-settings$/ },
	{ method: "GET", path: /^\/api\/auth\/me\/onboarding-options$/ },
	{ method: "PUT", path: /^\/api\/auth\/me\/onboarding-settings$/ },
	{ method: "GET", path: /^\/api\/profiles\/me$/ },
	{ method: "POST", path: /^\/api\/profiles\/me\/confirm$/ },
	{ method: "GET", path: /^\/api\/profiles\/me\/generation-state$/ },
	{ method: "GET", path: /^\/api\/personas$/ },
	{ method: "GET", path: /^\/api\/personas\/section-definitions$/ },
	{ method: "GET", path: new RegExp(`^/api/personas/${UUID_PATH}$`) },
	{ method: "GET", path: /^\/api\/speed-dating\/personas$/ },
	{ method: "POST", path: /^\/api\/speed-dating\/sessions$/ },
	{ method: "POST", path: new RegExp(`^/api/speed-dating/sessions/${UUID_PATH}/realtime-bootstrap$`) },
	{ method: "POST", path: new RegExp(`^/api/speed-dating/sessions/${UUID_PATH}/complete$`) },
	{ method: "GET", path: /^\/api\/matching\/results$/ },
	{ method: "GET", path: new RegExp(`^/api/matching/results/${UUID_PATH}$`) },
	{ method: "GET", path: /^\/api\/matching\/daily-results$/ },
	{ method: "POST", path: /^\/api\/recording-rehearsal\/matching\/preview$/ },
	{ method: "POST", path: /^\/api\/recording-rehearsal\/matching\/start$/ },
	{ method: "POST", path: new RegExp("^/api/matches/" + UUID_PATH + "/fox-conversation$") },
	{ method: "POST", path: /^\/api\/partner-fox-chats$/ },
	{ method: "GET", path: new RegExp(`^/api/partner-fox-chats/${UUID_PATH}$`) },
	{ method: "GET", path: new RegExp(`^/api/partner-fox-chats/${UUID_PATH}/messages$`) },
	{ method: "POST", path: /^\/api\/chat-requests$/ },
	{ method: "GET", path: /^\/api\/chat-requests$/ },
	{ method: "GET", path: new RegExp(`^/api/chat-requests/by-match/${UUID_PATH}$`) },
	{ method: "GET", path: /^\/api\/direct-chats$/ },
	{ method: "GET", path: new RegExp(`^/api/direct-chats/${UUID_PATH}/messages$`) },
	{ method: "POST", path: new RegExp(`^/api/direct-chats/${UUID_PATH}/messages$`) },
	{ method: "POST", path: new RegExp(`^/api/direct-chats/${UUID_PATH}/messages/send-recovery$`) },
	{ method: "PUT", path: new RegExp(`^/api/direct-chats/${UUID_PATH}/messages/${UUID_PATH}/read$`) },
	{ method: "PUT", path: new RegExp(`^/api/chat-requests/${UUID_PATH}$`) },
	{ method: "GET", path: new RegExp(`^/api/chat-meetups/rooms/${UUID_PATH}$`) },
	{ method: "POST", path: new RegExp(`^/api/chat-meetups/rooms/${UUID_PATH}/actions$`) },
	{ method: "GET", path: new RegExp(`^/api/chat-meetups/rooms/${UUID_PATH}/ward-conversation$`) },
	{ method: "POST", path: /^\/api\/meetups\/intents$/ },
	{ method: "GET", path: new RegExp(`^/api/meetups/by-match/${UUID_PATH}$`) },
	{ method: "POST", path: new RegExp(`^/api/meetups/${UUID_PATH}/arrange$`) },
	{ method: "POST", path: new RegExp(`^/api/meetups/${UUID_PATH}/retry$`) },
	{ method: "POST", path: new RegExp(`^/api/meetups/${UUID_PATH}/proposals/${UUID_PATH}/responses$`) },
	{ method: "GET", path: new RegExp(`^/api/meetups/${UUID_PATH}$`) },
	{ method: "PUT", path: new RegExp(`^/api/meetups/${UUID_PATH}/preferences$`) },
	{ method: "GET", path: new RegExp(`^/api/meetup-reflections/${UUID_PATH}$`) },
	{ method: "POST", path: new RegExp(`^/api/meetup-reflections/${UUID_PATH}/bootstrap$`) },
	{ method: "POST", path: new RegExp(`^/api/meetup-reflections/${UUID_PATH}/drafts$`) },
	{ method: "POST", path: new RegExp(`^/api/meetup-reflections/${UUID_PATH}/confirm$`) },
	{ method: "GET", path: new RegExp(`^/api/fox-conversations/${UUID_PATH}$`) },
	{ method: "GET", path: new RegExp(`^/api/fox-conversations/${UUID_PATH}/messages$`) },
];

export function matchesRecordingRehearsalRoute(method: string, pathname: string): boolean {
	return RECORDING_REHEARSAL_ROUTES.some((route) => route.method === method && route.path.test(pathname));
}
