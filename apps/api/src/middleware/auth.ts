import type { Context, Next } from "hono";
import type { Env } from "../env";
import { getSupabaseAuthClient } from "../db/client";
import { getSupabaseClient } from "../db/client";
import { jsonError } from "../lib/response";

// Cache Auth provider verification for 5 minutes; cache hits still validate the
// live owner profile boundary with a narrow service-role lookup.
const authCache = new Map<string, { authUserId: string; userId: string; expiresAt: number }>();
const AUTH_CACHE_TTL = 5 * 60_000;
const AUTH_CACHE_MAX_ENTRIES = 1_000;

/**
 * Reclaim expired entries before an insert, then keep the module-level Map
 * bounded by evicting the oldest inserted entries. Eviction only causes a
 * later request to be verified with Supabase again; it never grants access.
 */
function evictAuthCacheForInsert(now: number): void {
	for (const [token, entry] of authCache) {
		if (entry.expiresAt <= now) authCache.delete(token);
	}

	while (authCache.size >= AUTH_CACHE_MAX_ENTRIES) {
		const oldestKey = authCache.keys().next().value;
		if (oldestKey === undefined) break;
		authCache.delete(oldestKey);
	}
}

export type ResolvedAuthUser = { authUserId: string; userId: string };

/**
 * Decode (NOT verify) a JWT's `exp` claim, in milliseconds since epoch.
 *
 * C1 (step-3c review, Codex P1): the auth cache used a flat 5-minute TTL
 * regardless of the token's own expiry, so a token cached one second before
 * `exp` kept authenticating for nearly five more minutes — during which
 * `supabase.auth.getUser()` would have rejected it. Reading `exp` here is
 * safe specifically because this is only ever called AFTER
 * `supabase.auth.getUser(token)` has already verified the signature
 * (see the call site below) — this function must never be used to establish
 * trust on its own, only to shorten a cache lifetime that's already bounded
 * by a verified call. Returns `null` on anything malformed (not a JWT,
 * unparseable payload, missing/non-numeric `exp`), and the caller falls
 * back to the flat TTL in that case — never extends it.
 */
function decodeJwtExpiryMs(token: string): number | null {
	try {
		const parts = token.split(".");
		if (parts.length !== 3) return null;
		const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
		const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
		const payload = JSON.parse(atob(padded)) as { exp?: unknown };
		if (typeof payload.exp !== "number" || !Number.isFinite(payload.exp)) return null;
		return payload.exp * 1000;
	} catch {
		return null;
	}
}

/**
 * A verified token may remain cryptographically valid after its profile is
 * deleted. Cache hits therefore re-check the exact profile/auth pair without
 * repeating the comparatively expensive Auth provider getUser call.
 */
async function isLiveCachedProfile(c: Context<Env>, cached: { authUserId: string; userId: string }): Promise<boolean> {
	try {
		const { data, error } = await getSupabaseClient(c.env)
			.from("user_profiles")
			.select("id, auth_user_id")
			.eq("id", cached.userId)
			.eq("auth_user_id", cached.authUserId)
			.maybeSingle();
		return !error
			&& data !== null
			&& data !== undefined
			&& data.id === cached.userId
			&& data.auth_user_id === cached.authUserId;
	} catch {
		return false;
	}
}

/**
 * Validates a bearer token and resolves it to a `user_profiles.id`, backed
 * by the same 5-minute cache `requireAuth` uses. Shared so the WebSocket
 * edge handshake (routes/fox-search-ws.ts) authenticates the same way as
 * every other route instead of re-implementing token verification — see
 * docs/spec/impl/step-03-lazy-generation.md §4-C-3(1).
 *
 * Returns `null` on any failure (invalid/expired token or profile lookup
 * failure) without distinguishing the reason to
 * the caller, so callers can't accidentally leak internal state in a 401.
 */
export async function resolveAuthUser(c: Context<Env>, bearer: string): Promise<ResolvedAuthUser | null> {
	const startedAt = Date.now();

	const cached = authCache.get(bearer);
	if (cached) {
		if (cached.expiresAt > Date.now()) {
			if (!(await isLiveCachedProfile(c, cached)) || cached.expiresAt <= Date.now()) {
				authCache.delete(bearer);
				return null;
			}
			const totalMs = Date.now() - startedAt;
			if (totalMs > 100) {
				console.warn(`[auth] slow cache hit ${totalMs}ms`);
			}
			return { authUserId: cached.authUserId, userId: cached.userId };
		}
		authCache.delete(bearer);
	}

	const supabase = getSupabaseAuthClient(c.env);
	const getUserStartedAt = Date.now();
	const {
		data: { user },
		error,
	} = await supabase.auth.getUser(bearer);
	const getUserMs = Date.now() - getUserStartedAt;
	if (error || !user) {
		authCache.delete(bearer);
		return null;
	}
	const admin = getSupabaseClient(c.env);
	const profileLookupStartedAt = Date.now();
	const { data: existing, error: profileLookupError } = await admin
		.from("user_profiles")
		.select("id")
		.eq("auth_user_id", user.id)
		.single();
	const profileLookupMs = Date.now() - profileLookupStartedAt;
	if (profileLookupError) {
		console.error("[auth] failed to look up user profile");
		return null;
	}
	const profile: { id: string } | null = existing ?? null;
	if (!profile) {
		return null;
	}

	// C1: bound the cache deadline by the token's own expiry, never extend
	// past it. `getUser()` above already verified the signature, so `exp` is
	// trustworthy for this narrow purpose — shortening our own cache, not
	// establishing trust.
	const now = Date.now();
	const expMs = decodeJwtExpiryMs(bearer);
	const expiresAt = expMs !== null ? Math.min(now + AUTH_CACHE_TTL, expMs) : now + AUTH_CACHE_TTL;

	// Do not retain a result whose verified token is already at its deadline.
	if (expiresAt > now) {
		evictAuthCacheForInsert(now);
		authCache.set(bearer, {
			authUserId: user.id,
			userId: profile.id,
			expiresAt,
		});
	}

	const totalMs = Date.now() - startedAt;
	if (totalMs > 300) {
		console.warn(
			`[auth] slow auth ${totalMs}ms (get_user=${getUserMs}ms, profile_lookup=${profileLookupMs}ms, cache=miss)`,
		);
	}

	return { authUserId: user.id, userId: profile.id };
}

export const __testing = {
	AUTH_CACHE_MAX_ENTRIES,
	authCacheSize: () => authCache.size,
	clearAuthCache: () => authCache.clear(),
};

export async function requireAuth(c: Context<Env>, next: Next) {
	const authHeader = c.req.header("Authorization");
	if (!authHeader?.startsWith("Bearer ")) {
		return jsonError(c, "UNAUTHORIZED", "Missing or invalid Authorization header");
	}
	const token = authHeader.slice(7);

	const resolved = await resolveAuthUser(c, token);
	if (!resolved) {
		return jsonError(c, "UNAUTHORIZED", "Invalid or expired token");
	}

	c.set("auth_user_id", resolved.authUserId);
	c.set("user_id", resolved.userId);
	await next();
}

export type AgeVerificationStatus = "verified" | "unverified" | "error";

/**
 * Reads the current age-verification state without caching it. The auth cache
 * above only establishes identity; age verification can change immediately
 * after the self-declaration endpoint returns and must not inherit that TTL.
 */
export async function getAgeVerificationStatus(
	c: Context<Env>,
	userId: string,
): Promise<AgeVerificationStatus> {
	try {
		const { data, error } = await getSupabaseClient(c.env)
			.from("user_profiles")
			.select("age_verified_at")
			.eq("id", userId)
			.maybeSingle();
		if (error) {
			console.error("[auth] age verification lookup failed");
			return "error";
		}
		if (!data) return "unverified";
		return data.age_verified_at ? "verified" : "unverified";
	} catch {
		console.error("[auth] age verification lookup failed");
		return "error";
	}
}

/**
 * Authorization gate for routes that expose contact or matching paths.
 * Always place this after requireAuth so the user id is server-resolved.
 */
export async function requireAgeVerified(c: Context<Env>, next: Next) {
	const userId = c.get("user_id");
	if (!userId) {
		return jsonError(c, "INTERNAL_ERROR", "Age verification is unavailable");
	}

	const status = await getAgeVerificationStatus(c, userId);
	if (status === "error") {
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify age status");
	}
	if (status === "unverified") {
		return jsonError(c, "AGE_VERIFICATION_REQUIRED", "Age verification required");
	}
	await next();
}
