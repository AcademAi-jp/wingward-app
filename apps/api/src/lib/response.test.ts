import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import type { Env } from "../env";
import { jsonError } from "./response";

function appFor(code: Parameters<typeof jsonError>[1], message: string) {
	const app = new Hono<Env>();
	app.get("/", (c) => jsonError(c, code, message));
	return app;
}

describe("jsonError", () => {
	it.each([
		["AGE_VERIFICATION_REQUIRED", 403],
		["FORBIDDEN", 403],
		["UNAUTHORIZED", 401],
		["NOT_FOUND", 404],
	] as const)("uses the stable status for %s", async (code, expectedStatus) => {
		const response = await appFor(code, "Age verification required").request("/");

		expect(response.status).toBe(expectedStatus);
		expect(await response.json()).toEqual({
			error: {
				code,
				message: "Age verification required",
			},
		});
	});

	it("keeps FORBIDDEN distinct from the age-gate machine code", async () => {
		const response = await appFor("FORBIDDEN", "Access denied").request("/");

		expect(response.status).toBe(403);
		expect(await response.json()).toEqual({
			error: { code: "FORBIDDEN", message: "Access denied" },
		});
	});
});
