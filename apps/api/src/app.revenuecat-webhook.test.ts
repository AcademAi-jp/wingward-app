import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { app } from "./app";

const APP_SOURCE = readFileSync(new URL("./app.ts", import.meta.url), "utf8");
const FIXTURE_ENV = {
	SUPABASE_URL: "https://fixture.invalid",
	SUPABASE_SERVICE_ROLE_KEY: "fixture-service-role-value",
	INTERNAL_API_TOKEN: "fixture-internal-value",
};

describe("app: RevenueCat webhook is public and fail-closed", () => {
	it("mounts before the internal auth boundary", () => {
		const webhookMount = APP_SOURCE.indexOf('app.route("/api/webhooks/revenuecat"');
		const internalBoundary = APP_SOURCE.indexOf('app.use("/api/internal/*"');

		expect(webhookMount).toBeGreaterThanOrEqual(0);
		expect(internalBoundary).toBeGreaterThan(webhookMount);
	});

	it("reaches the real route and returns a fixed 503 when configuration is missing", async () => {
		const response = await app.request(
			"/api/webhooks/revenuecat",
			{
				method: "POST",
				body: "{}",
			},
			FIXTURE_ENV,
		);

		expect(response.status).toBe(503);
		const body = await response.text();
		expect(body).toContain('"RevenueCat webhook is not configured"');
		expect(body).not.toContain("fixture-service-role-value");
		expect(body).not.toContain("fixture-internal-value");
	});
});
