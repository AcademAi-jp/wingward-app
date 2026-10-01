import type { Context } from "hono";
import type { Env } from "../env";
import { jsonError } from "./response";

export type GenerationFailureStage =
	| "profile_input"
	| "profile_model"
	| "profile_save"
	| "profile_read"
	| "wingfox_input"
	| "wingfox_model"
	| "wingfox_save"
	| "wingfox_read";

function readVerifiedUpstreamStatus(error: unknown): number | undefined {
	if (!error || typeof error !== "object" || Array.isArray(error)) return undefined;
	try {
		const record = error as Record<string, unknown>;
		for (const key of ["statusCode", "status"]) {
			const value = record[key];
			if (typeof value === "number" && Number.isInteger(value) && value >= 400 && value <= 599) {
				return value;
			}
		}
	} catch {
		// A hostile accessor is not a verified upstream status.
	}
	return undefined;
}

/**
 * Report a bounded generation failure and return its fixed public error. Only
 * the trusted production E2E context receives the optional diagnostics headers.
 */
export function generationError(
	c: Context<Env>,
	stage: GenerationFailureStage,
	message: string,
	error?: unknown,
) {
	const upstreamStatus = readVerifiedUpstreamStatus(error);
	console.error(
		upstreamStatus === undefined
			? `[wingward/generation] stage=${stage}`
			: `[wingward/generation] stage=${stage} upstream_status=${upstreamStatus}`,
	);
	if (c.get("production_e2e_active") === true) {
		c.header("X-Wingward-Generation-Stage", stage);
		if (upstreamStatus !== undefined) {
			c.header("X-Wingward-Generation-Upstream-Status", String(upstreamStatus));
		}
	}
	return jsonError(c, "INTERNAL_ERROR", message);
}

export const __testing = { readVerifiedUpstreamStatus };
