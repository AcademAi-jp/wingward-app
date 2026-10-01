import { readDemoJudgeConfig } from "../services/demo-judge-window";
import { demoJudgeGate } from "./demo-judge-gate";
import type { Context, Next } from "hono";
import type { Env } from "../env";
import { resolveAuthUser } from "./auth";
import { jsonError } from "../lib/response";
import { SYNTHETIC_MATCHING_PROFILE_IDS, SYNTHETIC_MATCHING_EXPIRES_AT } from "../services/synthetic-matching-cohort";
import {
	RECORDING_REHEARSAL_SORA_PROFILE_ID,
	isRecordingRehearsalActive,
	isRecordingRehearsalSoraInterviewActive,
	matchesRecordingRehearsalSoraInterviewMutation,
	matchesRecordingRehearsalRoute,
	readRecordingRehearsalConfig,
	type ValidatedRecordingRehearsalConfig,
} from "../services/recording-rehearsal";

/**
 * The temporary production E2E surface is deliberately described as exact
 * method/path pairs. Keep this list aligned with the native voice journey;
 * every other HTTP route is closed while the gate is active.
 */
export const PRODUCTION_E2E_ALLOWED_ROUTES = [
	{ method: "GET", path: "/api/auth/me" },
	{ method: "POST", path: "/api/auth/me/photo" },
	{ method: "GET", path: "/api/billing/identity" },
	{ method: "GET", path: "/api/billing/status" },
	{ method: "GET", path: "/api/auth/me/onboarding-settings" },
	{ method: "PUT", path: "/api/auth/me/onboarding-settings" },
	{ method: "GET", path: "/api/auth/me/onboarding-options" },
	{ method: "PUT", path: "/api/auth/me/age-verification" },
	{ method: "GET", path: "/api/quiz/questions" },
	{ method: "GET", path: "/api/quiz/answers" },
	{ method: "POST", path: "/api/quiz/answers" },
	{ method: "GET", path: "/api/profiles/me" },
	{ method: "POST", path: "/api/profiles/generate" },
	{ method: "POST", path: "/api/personas/wingfox/generate" },
	{ method: "POST", path: "/api/profiles/me/confirm" },
	{ method: "GET", path: "/api/profiles/me/generation-state" },
	{ method: "GET", path: "/api/speed-dating/personas" },
	{ method: "POST", path: "/api/speed-dating/personas" },
	{ method: "POST", path: "/api/speed-dating/sessions" },
	{ method: "GET", path: "/api/speed-dating/sessions/:id" },
	{ method: "GET", path: "/api/speed-dating/sessions/:id/native-bootstrap" },
	{ method: "POST", path: "/api/speed-dating/sessions/:id/realtime-bootstrap" },
	{ method: "POST", path: "/api/speed-dating/sessions/:id/complete" },
	{ method: "GET", path: "/api/matching/daily-results" },
] as const;

const CANONICAL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const STRICT_UTC_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;

type ProductionE2EConfig =
	| { kind: "absent" }
	| { kind: "invalid" }
	| {
			kind: "active";
			profileIds: readonly string[];
			syntheticProfileIds: readonly string[];
		expiresAtMs: number;
			readOnly: boolean;
			ownerPrepOnly?: boolean;
			billingOnly?: boolean;
			soraProfileRevision?: boolean;
			recordingOnly?: boolean;
			recordingRehearsal?: ValidatedRecordingRehearsalConfig;
		};

function parseStrictUtcIso(value: unknown): number | null {
	if (typeof value !== "string" || !STRICT_UTC_ISO.test(value)) return null;
	const parsed = Date.parse(value);
	if (!Number.isFinite(parsed)) return null;

	// Date.parse accepts some invalid calendar values by normalizing them. A
	// canonical round-trip prevents those values from becoming an activation
	// deadline by accident.
	const canonical = new Date(parsed).toISOString();
	const normalized = value.endsWith("Z") && !value.includes(".")
		? `${value.slice(0, -1)}.000Z`
		: value;
	return canonical === normalized ? parsed : null;
}

function parseProfileIds(value: unknown): readonly string[] | null {
	if (typeof value !== "string") return null;
	const ids = value.split(",").map((id) => id.trim());
	if (ids.length < 1 || ids.length > 3 || ids.some((id) => !CANONICAL_UUID.test(id))) return null;
	if (new Set(ids).size !== ids.length) return null;
	return ids;
}

function parseReadOnlyFlag(value: unknown): boolean | null {
	if (value === undefined) return false;
	if (value === "true") return true;
	if (value === "false") return false;
	return null;
}

const OWNER_PREP_READS = new Set([
	"/api/auth/me",
	"/api/auth/me/onboarding-settings",
	"/api/auth/me/onboarding-options",
	"/api/profiles/me",
	"/api/profiles/me/generation-state",
	"/api/personas",
	"/api/personas/section-definitions",
	"/api/speed-dating/personas",
	"/api/matching/results",
	"/api/matching/daily-results",
]);

function matchesOwnerPrepRoute(method: string, pathname: string): boolean {
	if (method === "GET") {
		return OWNER_PREP_READS.has(pathname)
			|| new RegExp("^/api/personas/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").test(pathname);
	}
	return (method === "PUT" && pathname === "/api/auth/me/onboarding-settings")
		|| (method === "POST" && (pathname === "/api/profiles/me/confirm"
			|| pathname === "/api/recording-rehearsal/matching/preview"));
}

export function readProductionE2EConfig(env: Env["Bindings"] | undefined): ProductionE2EConfig {
	const billingBinding = env?.RECORDING_REHEARSAL_BILLING_ONLY;
	if (billingBinding !== undefined && billingBinding !== "enabled" && billingBinding !== "disabled") return { kind: "invalid" };
	const billingOnly = billingBinding === "enabled";
	const rehearsal = readRecordingRehearsalConfig(env);
	if (rehearsal.kind === "invalid") return { kind: "invalid" };
	if (rehearsal.kind === "active") {
		const readOnly = parseReadOnlyFlag(env?.PRODUCTION_E2E_READ_ONLY);
		if (readOnly === null) return { kind: "invalid" };
		if (rehearsal.config.soraInterviewAdmission && !readOnly) return { kind: "invalid" };
		const ownerPrepBinding = env?.RECORDING_REHEARSAL_OWNER_PREP_ONLY;
		if (ownerPrepBinding !== undefined && ownerPrepBinding !== "enabled" && ownerPrepBinding !== "disabled") return { kind: "invalid" };
		const ownerPrepOnly = ownerPrepBinding === "enabled";
		const revisionBinding = env?.RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED;
		if (revisionBinding !== undefined && revisionBinding !== "enabled" && revisionBinding !== "disabled") return { kind: "invalid" };
		const soraProfileRevision = revisionBinding === "enabled";
		if (ownerPrepOnly && (readOnly
			|| (rehearsal.config.pair !== "sora-ren" && rehearsal.config.pair !== "demo-maya-ren")
			|| (rehearsal.config.pair === "sora-ren" && env?.RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED !== "disabled"))) return { kind: "invalid" };
		if (soraProfileRevision && (!ownerPrepOnly || readOnly || rehearsal.config.pair !== "sora-ren"
			|| env?.RECORDING_REHEARSAL_SORA_INTERVIEW_ENABLED !== "disabled")) return { kind: "invalid" };
		if (billingOnly && (rehearsal.config.pair !== "demo-maya-ren" || readOnly || ownerPrepOnly || soraProfileRevision || rehearsal.config.soraInterviewAdmission)) return { kind: "invalid" };
		return {
			kind: "active",
			billingOnly,
			profileIds: rehearsal.config.profileIds,
			syntheticProfileIds: [],
			expiresAtMs: rehearsal.config.expiresAtMs,
			readOnly,
			ownerPrepOnly,
			soraProfileRevision,
			recordingRehearsal: rehearsal.config,
		};
	}
	if (billingBinding !== undefined) return { kind: "invalid" };
	// Explicitly re-enabled for the owner's requested audio retake. This does
	// not reopen the expired matching cohort, other accounts, or billing.
	if (env?.PRODUCTION_E2E_RECORDING_WINDOW !== undefined) {
		if (env.PRODUCTION_E2E_RECORDING_WINDOW !== "2026-09-22T12:00:00Z") return { kind: "invalid" };
		const readOnly = parseReadOnlyFlag(env.PRODUCTION_E2E_READ_ONLY);
		if (readOnly === null) return { kind: "invalid" };
		return { kind: "active", profileIds: ["d327a193-9eeb-42b1-bac4-fb5bea3ca21f"], syntheticProfileIds: [],
			expiresAtMs: Date.parse(env.PRODUCTION_E2E_RECORDING_WINDOW), readOnly, recordingOnly: true };
	}
	const profileIds = env?.PRODUCTION_E2E_PROFILE_IDS;
	const expiresAt = env?.PRODUCTION_E2E_EXPIRES_AT;
	const readOnly = env?.PRODUCTION_E2E_READ_ONLY;
	const syntheticIds = env?.PRODUCTION_E2E_SYNTHETIC_PROFILE_IDS;
	if (profileIds === undefined && expiresAt === undefined && readOnly === undefined && syntheticIds === undefined) return { kind: "absent" };

	const parsedProfileIds = parseProfileIds(profileIds);
	const expiresAtMs = parseStrictUtcIso(expiresAt);
	const parsedReadOnly = parseReadOnlyFlag(readOnly);
	if (!parsedProfileIds || expiresAtMs === null || parsedReadOnly === null) return { kind: "invalid" };

	const syntheticProfileIds = syntheticIds === undefined ? [] : parseProfileIds(syntheticIds);
	if (!syntheticProfileIds || (syntheticIds !== undefined && (
		syntheticProfileIds.length !== SYNTHETIC_MATCHING_PROFILE_IDS.length
		|| !SYNTHETIC_MATCHING_PROFILE_IDS.every(id => syntheticProfileIds.includes(id))
		|| parsedProfileIds.some(id => syntheticProfileIds.includes(id))
		|| expiresAtMs > Date.parse(SYNTHETIC_MATCHING_EXPIRES_AT)
	))) return { kind: "invalid" };
	return { kind: "active", profileIds: parsedProfileIds, syntheticProfileIds, expiresAtMs, readOnly: parsedReadOnly };
}

function matchesSyntheticRoute(method: string, pathname: string): boolean {
  if (method === "GET" && pathname === "/api/matching/results") return true;
  const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
  if (method === "GET") return new RegExp(`^/api/(?:matching/results/${uuid}|fox-conversations/${uuid}(?:/messages)?|meetups/by-match/${uuid})$`).test(pathname);
  return method === "POST" && new RegExp(`^/api/matches/${uuid}/fox-conversation$`).test(pathname);
}

function isExpired(config: Extract<ProductionE2EConfig, { kind: "active" }>): boolean {
	return Date.now() >= config.expiresAtMs;
}

function matchesAllowedRoute(method: string, pathname: string): boolean {
	return PRODUCTION_E2E_ALLOWED_ROUTES.some((route) => {
		if (route.method !== method) return false;
		if (route.path === "/api/speed-dating/sessions/:id") {
			const parts = pathname.split("/");
			return parts.length === 5
				&& parts[1] === "api"
				&& parts[2] === "speed-dating"
				&& parts[3] === "sessions"
				&& CANONICAL_UUID.test(parts[4] ?? "");
		}
		if (route.path === "/api/speed-dating/sessions/:id/native-bootstrap") {
			const parts = pathname.split("/");
			return parts.length === 6
				&& parts[1] === "api"
				&& parts[2] === "speed-dating"
				&& parts[3] === "sessions"
				&& CANONICAL_UUID.test(parts[4] ?? "")
				&& parts[5] === "native-bootstrap";
		}
		if (route.path === "/api/speed-dating/sessions/:id/realtime-bootstrap") {
			return new RegExp("^/api/speed-dating/sessions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/realtime-bootstrap$").test(pathname);
		}
		if (route.path === "/api/speed-dating/sessions/:id/complete") {
			const parts = pathname.split("/");
			return parts.length === 6
				&& parts[1] === "api"
				&& parts[2] === "speed-dating"
				&& parts[3] === "sessions"
				&& CANONICAL_UUID.test(parts[4] ?? "")
				&& parts[5] === "complete";
		}
		return route.path === pathname;
	});
}

function isNativeBootstrapRoute(pathname: string): boolean {
	const parts = pathname.split("/");
	return parts.length === 6
		&& parts[1] === "api"
		&& parts[2] === "speed-dating"
		&& parts[3] === "sessions"
		&& CANONICAL_UUID.test(parts[4] ?? "")
		&& parts[5] === "native-bootstrap";
}

function unavailable(c: Context<Env>) {
	return jsonError(c, "INTERNAL_ERROR", "Service unavailable", 503);
}

function unauthorized(c: Context<Env>) {
	return jsonError(c, "UNAUTHORIZED", "Unauthorized");
}

function forbidden(c: Context<Env>) {
	return jsonError(c, "FORBIDDEN", "Forbidden");
}

/** Expired filming closes all actions, while the same authenticated owners may still read their own saved profile. */
async function expiredRecordingOwnProfileRead(c: Context<Env>, next: Next) {
	const pathname = new URL(c.req.url).pathname;
	if (c.req.method !== "GET" || !["/api/auth/me", "/api/profiles/me"].includes(pathname)
		|| c.env.RECORDING_REHEARSAL_PAIR !== "demo-maya-ren"
		|| parseReadOnlyFlag(c.env.PRODUCTION_E2E_READ_ONLY) === null) return unavailable(c);
	const expiry = parseStrictUtcIso(c.env.RECORDING_REHEARSAL_EXPIRES_AT);
	if (expiry === null || Date.now() < expiry) return unavailable(c);
	// Validate the complete operator configuration at its last valid instant;
	// this grants no recording admission and never injects an expired config.
	const billingBinding = c.env.RECORDING_REHEARSAL_BILLING_ONLY;
	if (billingBinding !== undefined && billingBinding !== "enabled" && billingBinding !== "disabled") return unavailable(c);
	const historical = readRecordingRehearsalConfig(c.env, expiry - 1);
	if (historical.kind !== "active"
		|| (historical.config.ownerPrepOnly && parseReadOnlyFlag(c.env.PRODUCTION_E2E_READ_ONLY) !== false)
		|| (billingBinding === "enabled" && (historical.config.ownerPrepOnly || historical.config.soraInterviewAdmission || parseReadOnlyFlag(c.env.PRODUCTION_E2E_READ_ONLY) !== false))
		|| (c.env.RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED !== undefined
			&& c.env.RECORDING_REHEARSAL_SORA_PROFILE_REVISION_ENABLED !== "disabled")) return unavailable(c);
	const authorization = c.req.header("Authorization");
	if (!authorization?.startsWith("Bearer ")) return unauthorized(c);
	const bearer = authorization.slice("Bearer ".length);
	if (!bearer || bearer.trim() !== bearer) return unauthorized(c);
	let resolved: Awaited<ReturnType<typeof resolveAuthUser>> = null;
	try { resolved = await resolveAuthUser(c, bearer); } catch { resolved = null; }
	if (!resolved) return unauthorized(c);
	if (!historical.config.profileIds.includes(resolved.userId)) return forbidden(c);
	c.set("auth_user_id", resolved.authUserId);
	c.set("user_id", resolved.userId);
	c.set("production_e2e_active", true);
	c.set("production_e2e_synthetic", false);
	c.set("production_e2e_read_only", true);
	return next();
}

/**
 * Optional, fail-closed production E2E boundary.
 *
 * With both bindings absent, this middleware is a no-op. As soon as either
 * binding is present, malformed configuration closes the HTTP app. Expired demo filming permits
 * only authenticated same-cohort own auth/profile reads; every action stays closed. An active configuration allows only the route list above and
 * requires the existing Supabase-backed auth resolver plus an exact profile
 * ID allowlist match. `PRODUCTION_E2E_READ_ONLY=true` additionally closes all
 * method-side effects, including the native provider bootstrap GET. The
 * scheduled handler never passes through app.fetch.
 */
export async function productionE2EGate(c: Context<Env>, next: Next) {
	if (c.get("judge_access") || c.get("judge_vendor_active") === true) return next();
	if (readDemoJudgeConfig(c.env).kind !== "absent") return demoJudgeGate(c, next);
	const config = readProductionE2EConfig(c.env);
	if (config.kind === "absent") return next();
	if (config.kind === "invalid" || isExpired(config)) return expiredRecordingOwnProfileRead(c, next);

	const pathname = new URL(c.req.url).pathname;
	if (config.billingOnly) {
		if (c.req.method === "POST" && pathname === "/api/webhooks/revenuecat") return next();
		if (c.req.method !== "GET" || !["/api/auth/me", "/api/profiles/me", "/api/billing/identity", "/api/billing/status"].includes(pathname)) return forbidden(c);
	}
	const soraInterviewMutation = config.recordingRehearsal !== undefined
		&& matchesRecordingRehearsalSoraInterviewMutation(c.req.method, pathname);
	const soraInterviewWriteAllowed = soraInterviewMutation
		&& config.recordingRehearsal?.pair === "sora-ren"
		&& config.readOnly
		&& isRecordingRehearsalSoraInterviewActive(config.recordingRehearsal);
	const soraProfileRevisionRoute = config.soraProfileRevision === true
		&& c.req.method === "POST" && pathname === "/api/profiles/generate";
	if (config.recordingRehearsal && !config.billingOnly) {
		if (!soraProfileRevisionRoute && !matchesRecordingRehearsalRoute(c.req.method, pathname)) return forbidden(c);
		if (config.ownerPrepOnly && !soraProfileRevisionRoute && !matchesOwnerPrepRoute(c.req.method, pathname)) return forbidden(c);
		if (soraInterviewMutation && !soraInterviewWriteAllowed) return forbidden(c);
		if (config.readOnly && c.req.method !== "GET" && !soraInterviewWriteAllowed) return forbidden(c);
	}
	if (config.recordingOnly) {
		const reads = ["/api/auth/me", "/api/auth/me/onboarding-settings", "/api/auth/me/onboarding-options", "/api/profiles/me", "/api/profiles/me/generation-state", "/api/speed-dating/personas"];
		const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
		const allowed = (c.req.method === "GET" && reads.includes(pathname))
			|| (c.req.method === "POST" && (pathname === "/api/speed-dating/sessions"
				|| new RegExp(`^/api/speed-dating/sessions/${uuid}/(?:realtime-bootstrap|complete)$`).test(pathname)));
		if (!allowed) return forbidden(c);
	}
  // Password-authenticated login for the three disposable identities only.
  // The route independently rechecks configuration and expiry after Auth.
  if (c.req.method === "POST" && pathname === "/api/testing/synthetic-session") {
    if (config.readOnly || config.syntheticProfileIds.length !== 3) return forbidden(c);
    return next();
  }
  // The vendor webhook uses its own HMAC + authorization, not user JWT auth.
  // Its route independently restricts test-store events to these same profiles.
  if (c.req.method === "POST" && pathname === "/api/webhooks/revenuecat") {
    if (config.readOnly) return forbidden(c);
    return next();
  }
	const syntheticRoute = !config.recordingRehearsal
		&& config.syntheticProfileIds.length === 3
		&& matchesSyntheticRoute(c.req.method, pathname);
	if (!config.recordingRehearsal && !matchesAllowedRoute(c.req.method, pathname) && !syntheticRoute) return forbidden(c);
	// Native bootstrap is a provider-token side effect despite using GET; keep
	// it closed while a read-only verification window is active.
	if (config.readOnly && ((c.req.method !== "GET" && !soraInterviewWriteAllowed) || isNativeBootstrapRoute(pathname))) return forbidden(c);

	const authorization = c.req.header("Authorization");
	if (!authorization?.startsWith("Bearer ")) return unauthorized(c);
	const bearer = authorization.slice("Bearer ".length);
	if (!bearer || bearer.trim() !== bearer) return unauthorized(c);

	let resolved: Awaited<ReturnType<typeof resolveAuthUser>> = null;
	try {
		resolved = await resolveAuthUser(c, bearer);
	} catch {
		resolved = null;
	}

	// Re-check after the awaited provider/database work. This closes the
	// activation boundary even when authentication finishes after expiry.
	if (isExpired(config)) return unavailable(c);
	if (config.recordingRehearsal && !isRecordingRehearsalActive(config.recordingRehearsal)) return unavailable(c);
	if (!resolved) return unauthorized(c);
	if (soraInterviewWriteAllowed && resolved.userId !== RECORDING_REHEARSAL_SORA_PROFILE_ID) return forbidden(c);
	if (config.ownerPrepOnly) {
		const pair = config.recordingRehearsal?.generationPair;
		if (!pair?.some((id) => id === resolved.userId)) return forbidden(c);
		if (pathname === "/api/profiles/me/confirm") {
			const confirmationActor = config.recordingRehearsal?.pair === "demo-maya-ren"
				? pair[0] : RECORDING_REHEARSAL_SORA_PROFILE_ID;
			if (resolved.userId !== confirmationActor) return forbidden(c);
		}
	}
	if (soraProfileRevisionRoute && resolved.userId !== RECORDING_REHEARSAL_SORA_PROFILE_ID) return forbidden(c);
	const isSynthetic = config.syntheticProfileIds.includes(resolved.userId);
	if (!config.profileIds.includes(resolved.userId) && !isSynthetic) return forbidden(c);
	if (syntheticRoute && !isSynthetic) return forbidden(c);

	c.set("auth_user_id", resolved.authUserId);
	c.set("user_id", resolved.userId);
	c.set("production_e2e_active", true);
	c.set("production_e2e_synthetic", isSynthetic);
	// The legacy profile GET inserts an empty draft when a row is absent. During
	// owner preparation, this read must remain read-only even though the two
	// explicit owner writes are open.
	c.set("production_e2e_read_only", config.readOnly || config.billingOnly === true
		|| (config.ownerPrepOnly === true && c.req.method === "GET" && pathname === "/api/profiles/me"));
	if (config.recordingRehearsal && !config.billingOnly) c.set("recording_rehearsal", config.recordingRehearsal);
	return next();
}

export const __testing = {
	parseProfileIds,
	parseReadOnlyFlag,
	parseStrictUtcIso,
	matchesAllowedRoute,
	readProductionE2EConfig,
	matchesRecordingRehearsalRoute,
};
