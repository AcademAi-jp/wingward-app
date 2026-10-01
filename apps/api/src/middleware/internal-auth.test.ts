import { describe, expect, it, vi } from "vitest";
import { Hono } from "hono";
import type { Env } from "../env";
import { requireInternalAuth } from "./internal-auth";

function buildApp(handler: () => void) {
	const app = new Hono<Env>();
	app.use("/api/internal/*", requireInternalAuth);
	app.get("/api/internal/ping", (c) => {
		handler();
		return c.json({ data: { message: "pong" } });
	});
	return app;
}

describe("requireInternalAuth", () => {
	it("returns 503 and does not call the handler when INTERNAL_API_TOKEN is unset", async () => {
		const handler = vi.fn();
		const app = buildApp(handler);
		const res = await app.request("/api/internal/ping", {}, {});
		expect(res.status).toBe(503);
		expect(handler).not.toHaveBeenCalled();
	});

	it("returns 503 when INTERNAL_API_TOKEN is whitespace only", async () => {
		const handler = vi.fn();
		const app = buildApp(handler);
		const res = await app.request("/api/internal/ping", {}, { INTERNAL_API_TOKEN: "   " });
		expect(res.status).toBe(503);
		expect(handler).not.toHaveBeenCalled();
	});

	it("returns 401 when the X-Internal-Token header is missing", async () => {
		const handler = vi.fn();
		const app = buildApp(handler);
		const res = await app.request("/api/internal/ping", {}, { INTERNAL_API_TOKEN: "secret-token" });
		expect(res.status).toBe(401);
		expect(handler).not.toHaveBeenCalled();
	});

	it("returns 401 for a wrong token of the same length", async () => {
		const handler = vi.fn();
		const app = buildApp(handler);
		const res = await app.request(
			"/api/internal/ping",
			{ headers: { "X-Internal-Token": "wrong-token!" } },
			{ INTERNAL_API_TOKEN: "secret-token" },
		);
		expect(res.status).toBe(401);
		expect(handler).not.toHaveBeenCalled();
	});

	it("returns 401 for a wrong token of a different length", async () => {
		const handler = vi.fn();
		const app = buildApp(handler);
		const res = await app.request(
			"/api/internal/ping",
			{ headers: { "X-Internal-Token": "short" } },
			{ INTERNAL_API_TOKEN: "secret-token" },
		);
		expect(res.status).toBe(401);
		expect(handler).not.toHaveBeenCalled();
	});

	it("returns 200 and calls the handler when the token matches", async () => {
		const handler = vi.fn();
		const app = buildApp(handler);
		const res = await app.request(
			"/api/internal/ping",
			{ headers: { "X-Internal-Token": "secret-token" } },
			{ INTERNAL_API_TOKEN: "secret-token" },
		);
		expect(res.status).toBe(200);
		expect(handler).toHaveBeenCalledTimes(1);
	});

	it("does not echo the configured token in the 401 response body", async () => {
		const app = buildApp(vi.fn());
		const res = await app.request(
			"/api/internal/ping",
			{ headers: { "X-Internal-Token": "wrong-token!" } },
			{ INTERNAL_API_TOKEN: "secret-token" },
		);
		const body = await res.text();
		expect(body).not.toContain("secret-token");
	});
});
