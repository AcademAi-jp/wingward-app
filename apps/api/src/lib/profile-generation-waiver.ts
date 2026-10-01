import type { Env } from "../env";

const CANONICAL_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STRICT_UTC_ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;

/**
 * The waiver is deliberately narrower than the existing production E2E gate:
 * the request must already have passed that authenticated, allowlisted gate,
 * and the operator must name this exact profile with a separate expiry.
 */
export function isInterviewGenerationWaiverActive(
	env: Env["Bindings"],
	userId: string,
	productionE2EActive: boolean | undefined,
	now = Date.now(),
): boolean {
	if (productionE2EActive !== true) return false;
	const configuredUserId = env.PROFILE_GENERATION_WAIVER_USER_ID?.trim().toLowerCase();
	const expiresAt = env.PROFILE_GENERATION_WAIVER_EXPIRES_AT?.trim();
	if (!configuredUserId || !CANONICAL_UUID.test(configuredUserId)) return false;
	if (!CANONICAL_UUID.test(userId) || configuredUserId !== userId.toLowerCase()) return false;
	const expiresAtMs = parseStrictUtcIso(expiresAt);
	return expiresAtMs !== null && now < expiresAtMs;
}

export function parseStrictUtcIso(value: unknown): number | null {
	if (typeof value !== "string" || !STRICT_UTC_ISO.test(value)) return null;
	const parsed = Date.parse(value);
	if (!Number.isFinite(parsed)) return null;
	const canonical = new Date(parsed).toISOString();
	const normalized = value.endsWith("Z") && !value.includes(".")
		? `${value.slice(0, -1)}.000Z`
		: value;
	return canonical === normalized ? parsed : null;
}

export const __testing = { parseStrictUtcIso };
