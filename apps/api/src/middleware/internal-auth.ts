import type { Context, Next } from "hono";
import type { Env } from "../env";
import { jsonError } from "../lib/response";

/**
 * Constant-time comparison of two token strings.
 * Does not import node:crypto because this runs on Cloudflare Workers.
 * Always iterates the full length of `configured` (and folds any length
 * mismatch into the accumulator) so the comparison time does not leak
 * information about how many leading bytes of `presented` were correct.
 */
function timingSafeEqual(presented: string, configured: string): boolean {
	const presentedBytes = new TextEncoder().encode(presented);
	const configuredBytes = new TextEncoder().encode(configured);
	let acc = presentedBytes.length ^ configuredBytes.length;
	for (let i = 0; i < configuredBytes.length; i++) {
		const presentedByte = i < presentedBytes.length ? presentedBytes[i] : 0;
		acc |= presentedByte ^ configuredBytes[i];
	}
	return acc === 0;
}

/**
 * Guards /api/internal/* routes with a shared secret.
 *
 * If INTERNAL_API_TOKEN is unset (or blank), we respond 503 rather than
 * letting the request through. These routes trigger batch execution and
 * row deletion, so an unconfigured secret must mean the routes are closed,
 * never that they become open to anyone.
 */
export async function requireInternalAuth(c: Context<Env>, next: Next) {
	const configuredToken = c.env.INTERNAL_API_TOKEN;
	if (!configuredToken || configuredToken.trim() === "") {
		return jsonError(c, "INTERNAL_ERROR", "Internal API is not configured", 503);
	}

	const presentedToken = c.req.header("X-Internal-Token");
	if (!presentedToken) {
		return jsonError(c, "UNAUTHORIZED", "Missing internal API token");
	}

	if (!timingSafeEqual(presentedToken, configuredToken)) {
		return jsonError(c, "UNAUTHORIZED", "Invalid internal API token");
	}

	await next();
}
