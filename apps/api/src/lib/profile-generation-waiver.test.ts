import { describe, expect, it } from "vitest";
import { isInterviewGenerationWaiverActive } from "./profile-generation-waiver";

const OWNER_ID = "da3da1d3-c9ce-46df-8841-d856c7c12c66";
const EXPIRY = "2026-09-20T12:00:00.000Z";
const NOW = Date.parse("2026-09-20T11:00:00.000Z");

function env(overrides: Record<string, string | undefined> = {}) {
	return {
		SUPABASE_URL: "https://example.test",
		SUPABASE_SERVICE_ROLE_KEY: "test",
		PROFILE_GENERATION_WAIVER_USER_ID: OWNER_ID,
		PROFILE_GENERATION_WAIVER_EXPIRES_AT: EXPIRY,
		...overrides,
	};
}

describe("profile generation waiver", () => {
	it("requires the trusted E2E context, exact owner, and a future strict UTC expiry", () => {
		expect(isInterviewGenerationWaiverActive(env(), OWNER_ID, true, NOW)).toBe(true);
		expect(isInterviewGenerationWaiverActive(env(), OWNER_ID, false, NOW)).toBe(false);
		expect(isInterviewGenerationWaiverActive(env(), "11111111-1111-4111-8111-111111111111", true, NOW)).toBe(false);
	});

	it.each([
		["missing owner", { PROFILE_GENERATION_WAIVER_USER_ID: undefined }],
		["malformed owner", { PROFILE_GENERATION_WAIVER_USER_ID: "not-a-uuid" }],
		["missing expiry", { PROFILE_GENERATION_WAIVER_EXPIRES_AT: undefined }],
		["malformed expiry", { PROFILE_GENERATION_WAIVER_EXPIRES_AT: "2026-09-20T21:00:00+09:00" }],
		["expired", { PROFILE_GENERATION_WAIVER_EXPIRES_AT: "2026-09-20T10:59:59.999Z" }],
	] as const)("fails closed for %s", (_name, overrides) => {
		expect(isInterviewGenerationWaiverActive(env(overrides), OWNER_ID, true, NOW)).toBe(false);
	});
});
