import { describe, expect, it } from "vitest";
import { app } from "./app";

/**
 * The unit tests in middleware/internal-auth.test.ts build their own Hono app,
 * so they cannot catch the wiring regression that actually matters: someone
 * removing the `app.use("/api/internal/*", ...)` line from app.ts. These tests
 * hit the real app to prove every /api/internal/* route is guarded.
 */

const INTERNAL_ROUTES: Array<[string, string]> = [
	["POST", "/api/internal/matching/execute"],
	["POST", "/api/internal/fox-conversations/execute"],
	["POST", "/api/internal/chat-requests/expire"],
	["POST", "/api/internal/fox-conversations/retry-failed"],
	["POST", "/api/internal/data-integrity/check"],
	["POST", "/api/internal/daily-batch/execute"],
	["GET", "/api/internal/daily-batch/status"],
	["POST", "/api/internal/daily-batch/retry"],
];

describe("app: /api/internal/* is guarded", () => {
	it.each(INTERNAL_ROUTES)(
		"%s %s is rejected without a token when INTERNAL_API_TOKEN is set",
		async (method, path) => {
			const res = await app.request(path, { method }, { INTERNAL_API_TOKEN: "configured-secret" });
			expect(res.status).toBe(401);
		},
	);

	it.each(INTERNAL_ROUTES)(
		"%s %s is closed (503), not open, when INTERNAL_API_TOKEN is unset",
		async (method, path) => {
			const res = await app.request(path, { method }, {});
			expect(res.status).toBe(503);
		},
	);
});
