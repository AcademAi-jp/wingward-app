import { Hono } from "hono";
import { z } from "zod";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { errorHandler } from "./error";

/**
 * Reflected-error-message regression test (fix/error-message-reflection).
 *
 * The global error handler used to return the raw `Error.message` to the
 * client for any unexpected `Error`. If a user-controlled value (e.g. an
 * IANA timezone string fed into `Intl`) ever reaches an uncaught `Error`,
 * that value would be reflected verbatim in the JSON response. The handler
 * must now always return a generic, constant message for unexpected errors
 * while still logging the real error server-side.
 */

function buildApp() {
	const app = new Hono();
	app.onError(errorHandler);
	app.get("/boom-error", () => {
		throw new RangeError("Invalid time zone specified: <script>PWNED-CANARY</script>");
	});
	app.get("/boom-zod", () => {
		const schema = z.object({ name: z.string() });
		schema.parse({ name: 123 });
		return new Response("unreachable");
	});
	return app;
}

describe("errorHandler", () => {
	let consoleErrorSpy: ReturnType<typeof vi.spyOn>;

	beforeEach(() => {
		consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
	});

	afterEach(() => {
		consoleErrorSpy.mockRestore();
	});

	it("returns a generic message for an unexpected Error and never reflects the attacker-controlled text", async () => {
		const app = buildApp();
		const res = await app.request("/boom-error");
		const bodyText = await res.text();

		expect(res.status).toBe(500);
		expect(bodyText).not.toContain("PWNED-CANARY");
		expect(JSON.parse(bodyText)).toEqual({
			error: {
				code: "INTERNAL_ERROR",
				message: "An unexpected error occurred",
			},
		});
	});

	it("still returns field-level BAD_REQUEST feedback for ZodError (intentional validation feedback untouched)", async () => {
		const app = buildApp();
		const res = await app.request("/boom-zod");
		const body = (await res.json()) as { error: { code: string; message: string } };

		expect(res.status).toBe(400);
		expect(body.error.code).toBe("BAD_REQUEST");
		expect(body.error.message).toContain("name");
	});

	it("returns the generic 500 for a non-Error throw", async () => {
		// Hono's own dispatcher only routes `instanceof Error` throws to `onError`
		// (see hono-base.js #handleError) and rethrows anything else, so the
		// non-Error fallback branch is exercised by calling errorHandler directly.
		const app = new Hono();
		let capturedContext: unknown;
		app.get("/capture", (c) => {
			capturedContext = c;
			return c.text("ok");
		});
		await app.request("/capture");

		// biome-ignore lint/suspicious/noExplicitAny: test-only cast to reach the captured Hono Context
		const res = errorHandler("boom", capturedContext as any);
		const body = await res.json();

		expect(res.status).toBe(500);
		expect(body).toEqual({
			error: {
				code: "INTERNAL_ERROR",
				message: "An unexpected error occurred",
			},
		});
	});
});
