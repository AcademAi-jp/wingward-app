import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../env";

const USER_ID = "10000000-0000-0000-0000-000000000001";
const MATCH_ID = "20000000-0000-0000-0000-000000000001";
const MEETUP_ID = "30000000-0000-0000-0000-000000000001";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("auth_user_id", "90000000-0000-0000-0000-000000000001");
		c.set("user_id", USER_ID);
		await next();
	},
	requireAgeVerified: async (_c: import("hono").Context, next: () => Promise<void>) => next(),
}));

vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn(() => ({})) }));
const notifyInBackground = vi.fn();
vi.mock("../lib/background", () => ({
	notifyInBackground: (...args: unknown[]) => notifyInBackground(...args),
}));
const notifyMeetupMutualIntentMock = vi.fn();
const notifyMeetupArrangementMock = vi.fn();
vi.mock("../services/notification-triggers", () => ({
	notifyMeetupMutualIntent: (...args: unknown[]) => notifyMeetupMutualIntentMock(...args),
	notifyMeetupArrangement: (...args: unknown[]) => notifyMeetupArrangementMock(...args),
}));
vi.mock("../services/meetups", () => ({
	arrangeMeetup: vi.fn(),
	createMeetupIntent: vi.fn(),
	getMeetupProposalGenerator: vi.fn(() => ({ generate: vi.fn() })),
	getMeetupDetail: vi.fn(),
	getMeetupDetailByMatch: vi.fn(),
	recordMeetupProposalResponse: vi.fn(),
	retryMeetupArrangement: vi.fn(),
	saveMeetupPreferences: vi.fn(),
}));

import {
	arrangeMeetup,
	createMeetupIntent,
	getMeetupDetail,
	getMeetupDetailByMatch,
	recordMeetupProposalResponse,
	retryMeetupArrangement,
	saveMeetupPreferences,
} from "../services/meetups";
import meetups from "./meetups";

const mockedCreateMeetupIntent = vi.mocked(createMeetupIntent);
const mockedGetMeetupDetail = vi.mocked(getMeetupDetail);
const mockedGetMeetupDetailByMatch = vi.mocked(getMeetupDetailByMatch);
const mockedArrangeMeetup = vi.mocked(arrangeMeetup);
const mockedRetryMeetupArrangement = vi.mocked(retryMeetupArrangement);
const mockedRecordMeetupProposalResponse = vi.mocked(recordMeetupProposalResponse);
const mockedSaveMeetupPreferences = vi.mocked(saveMeetupPreferences);

function makeApp() {
	const app = new Hono<Env>();
	app.route("/api/meetups", meetups);
	return app;
}

beforeEach(() => {
	vi.clearAllMocks();
});

describe("POST /api/meetups/intents", () => {
	it("returns the identical non-disclosing success body for an accepted intent", async () => {
		mockedCreateMeetupIntent.mockResolvedValue({ ok: true, transition: "mutual_intent" });

		const response = await makeApp().request("/api/meetups/intents", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { accepted: true } });
		expect(mockedCreateMeetupIntent).toHaveBeenCalledWith(expect.anything(), USER_ID, MATCH_ID);
	});

	it.each([
		["malformed UUID", { match_id: "not-a-uuid" }],
		["unknown field", { match_id: MATCH_ID, meetup_id: MEETUP_ID }],
		["invalid JSON", "{"],
	])("rejects %s with a fixed error and does not call the service", async (_name, body) => {
		const response = await makeApp().request("/api/meetups/intents", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: typeof body === "string" ? body : JSON.stringify(body),
		});

		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: { code: "BAD_REQUEST", message: "Invalid request" } });
		expect(mockedCreateMeetupIntent).not.toHaveBeenCalled();
	});

	it.each([
		["blocked", { ok: true as const, transition: null }],
		["not found", { ok: true as const, transition: null }],
		["already active", { ok: true as const, transition: null }],
	])("returns one identical acknowledgement for a safe intent outcome (%s)", async (_name, result) => {
		mockedCreateMeetupIntent.mockResolvedValue(result);
		const response = await makeApp().request("/api/meetups/intents", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		});

		expect(response.status).toBe(200);
		const body = await response.json();
		expect(body).toEqual({ data: { accepted: true } });
		expect(JSON.stringify(body)).not.toContain(MATCH_ID);
	});

	it("collapses a legacy non-disclosing not-found service result too", async () => {
		mockedCreateMeetupIntent.mockResolvedValue({ ok: false, reason: "not_found" });
		const response = await makeApp().request("/api/meetups/intents", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { accepted: true } });
	});

	it("keeps RPC/service failures as a fixed 500", async () => {
		mockedCreateMeetupIntent.mockResolvedValue({ ok: false, reason: "internal" });
		const response = await makeApp().request("/api/meetups/intents", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		});

		expect(response.status).toBe(500);
		expect(await response.json()).toEqual({
			error: { code: "INTERNAL_ERROR", message: "Unable to process meetup" },
		});
	});

	it("queues mutual-intent notifications after a verifying transition", async () => {
		mockedCreateMeetupIntent.mockResolvedValue({
			ok: true,
			transition: "mutual_intent",
			notificationContext: { meetupId: MEETUP_ID, matchId: MATCH_ID },
		});

		const response = await makeApp().request("/api/meetups/intents", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ match_id: MATCH_ID }),
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { accepted: true } });
		expect(notifyInBackground).toHaveBeenCalledTimes(1);
		expect(notifyInBackground.mock.calls[0][0]).toBeInstanceOf(Object);
		expect(typeof notifyInBackground.mock.calls[0][1]).toBe("function");
		await notifyInBackground.mock.calls[0][1]();
		expect(notifyMeetupMutualIntentMock).toHaveBeenCalledWith(
			expect.objectContaining({ supabase: expect.anything() }),
			{ meetupId: MEETUP_ID, matchId: MATCH_ID },
		);
	});
});

describe("GET /api/meetups/:id", () => {
	it("returns the service's contract DTO without adding route fields", async () => {
		mockedGetMeetupDetail.mockResolvedValue({
			ok: true,
			data: {
				id: MEETUP_ID,
				match_id: MATCH_ID,
				status: "verifying",
				proposal: null,
				confirmed_candidate: null,
				expires_at: null,
			},
		});

		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}`);

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: {
				id: MEETUP_ID,
				match_id: MATCH_ID,
				status: "verifying",
				proposal: null,
				confirmed_candidate: null,
				expires_at: null,
			},
		});
		expect(mockedGetMeetupDetail).toHaveBeenCalledWith(expect.anything(), USER_ID, MEETUP_ID);
	});

	it("maps all unavailable relationships to the same fixed 404", async () => {
		for (const reason of ["not_found", "not_found", "not_found"] as const) {
			mockedGetMeetupDetail.mockResolvedValueOnce({ ok: false, reason });
			const response = await makeApp().request(`/api/meetups/${MEETUP_ID}`);
			expect(response.status).toBe(404);
			expect(await response.json()).toEqual({ error: { code: "NOT_FOUND", message: "Meetup not found" } });
		}
	});

	it("uses fixed errors for malformed path and stored data failures", async () => {
		const malformedPath = await makeApp().request("/api/meetups/not-a-uuid");
		expect(malformedPath.status).toBe(400);
		expect(await malformedPath.json()).toEqual({ error: { code: "BAD_REQUEST", message: "Invalid request" } });

		mockedGetMeetupDetail.mockResolvedValue({ ok: false, reason: "internal" });
		const malformedStoredData = await makeApp().request(`/api/meetups/${MEETUP_ID}`);
		expect(malformedStoredData.status).toBe(500);
		expect(await malformedStoredData.json()).toEqual({ error: { code: "INTERNAL_ERROR", message: "Unable to process meetup" } });
	});
});

describe("GET /api/meetups/by-match/:matchId", () => {
	const detail = {
		id: MEETUP_ID,
		match_id: MATCH_ID,
		status: "verifying",
		proposal: null,
		confirmed_candidate: null,
		expires_at: null,
	} as const;

	it("returns the authorized meetup DTO after mutual intent", async () => {
		mockedGetMeetupDetailByMatch.mockResolvedValue({ ok: true, data: detail });

		const response = await makeApp().request(`/api/meetups/by-match/${MATCH_ID}`);

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: detail });
		expect(mockedGetMeetupDetailByMatch).toHaveBeenCalledWith(expect.anything(), USER_ID, MATCH_ID);
	});

	it.each(["not_found", "internal"] as const)("maps a %s lookup without exposing the match id", async (reason) => {
		mockedGetMeetupDetailByMatch.mockResolvedValue({ ok: false, reason });

		const response = await makeApp().request(`/api/meetups/by-match/${MATCH_ID}`);
		const expected = reason === "not_found"
			? { error: { code: "NOT_FOUND", message: "Meetup not found" } }
			: { error: { code: "INTERNAL_ERROR", message: "Unable to process meetup" } };

		expect(response.status).toBe(reason === "not_found" ? 404 : 500);
		expect(await response.json()).toEqual(expected);
		expect(JSON.stringify(expected)).not.toContain(MATCH_ID);
	});

	it("rejects a malformed match id before service access", async () => {
		const response = await makeApp().request("/api/meetups/by-match/not-a-uuid");

		expect(response.status).toBe(400);
		expect(await response.json()).toEqual({ error: { code: "BAD_REQUEST", message: "Invalid request" } });
		expect(mockedGetMeetupDetailByMatch).not.toHaveBeenCalled();
	});
});

describe("PUT /api/meetups/:id/preferences", () => {
	const validBody = {
		availability: [{ starts_at: "2026-09-10T10:00:00+09:00", ends_at: "2026-09-10T12:00:00+09:00" }],
		areas: ["Tokyo/Chiyoda"],
		budget_band: "medium",
		formats: ["cafe"],
		constraints: {},
	};

	it("returns the contract saved body and passes no caller-selected user id", async () => {
		mockedSaveMeetupPreferences.mockResolvedValue({ ok: true });
		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}/preferences`, {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(validBody),
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { saved: true } });
		expect(mockedSaveMeetupPreferences).toHaveBeenCalledWith(expect.anything(), USER_ID, MEETUP_ID, validBody);
	});

	it("maps invalid preferences and owned terminal state without leaking payload values", async () => {
		mockedSaveMeetupPreferences.mockResolvedValueOnce({ ok: false, reason: "bad_request" });
		const badBody = { ...validBody, areas: ["private-value"] };
		const badResponse = await makeApp().request(`/api/meetups/${MEETUP_ID}/preferences`, {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(badBody),
		});
		expect(badResponse.status).toBe(400);
		expect(JSON.stringify(await badResponse.json())).not.toContain("private-value");

		mockedSaveMeetupPreferences.mockResolvedValueOnce({ ok: false, reason: "invalid_state" });
		const conflictResponse = await makeApp().request(`/api/meetups/${MEETUP_ID}/preferences`, {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(validBody),
		});
		expect(conflictResponse.status).toBe(409);
		expect(await conflictResponse.json()).toEqual({ error: { code: "CONFLICT", message: "Meetup cannot be updated" } });
	});

	it("does not distinguish an unavailable meetup from a blocked participant", async () => {
		mockedSaveMeetupPreferences.mockResolvedValue({ ok: false, reason: "not_found" });
		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}/preferences`, {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(validBody),
		});
		expect(response.status).toBe(404);
		expect(await response.json()).toEqual({ error: { code: "NOT_FOUND", message: "Meetup not found" } });
	});
});

describe("POST /api/meetups/:id/arrange and retry", () => {
	it("returns the frozen accepted/status envelope and forwards the idempotency key", async () => {
		mockedArrangeMeetup.mockResolvedValue({ ok: true, status: "proposed", billingSource: "meetup_arrange" });
		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}/arrange`, {
			method: "POST",
			headers: { "Idempotency-Key": "arrange-1" },
		});
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { accepted: true, status: "arranging" } });
		expect(mockedArrangeMeetup).toHaveBeenCalledWith(expect.anything(), USER_ID, MEETUP_ID, expect.anything(), { idempotencyKey: "arrange-1" });
	});

	it("maps identity and quota failures to fixed, non-disclosing errors", async () => {
		mockedArrangeMeetup.mockResolvedValueOnce({ ok: false, reason: "identity_verification_required" });
		const identityResponse = await makeApp().request(`/api/meetups/${MEETUP_ID}/arrange`, { method: "POST" });
		expect(identityResponse.status).toBe(409);
		expect(await identityResponse.json()).toEqual({ error: { code: "CONFLICT", message: "Identity verification required" } });

		mockedArrangeMeetup.mockResolvedValueOnce({ ok: false, reason: "quota_exhausted" });
		const quotaResponse = await makeApp().request(`/api/meetups/${MEETUP_ID}/arrange`, { method: "POST" });
		expect(quotaResponse.status).toBe(402);
		const quotaBody = await quotaResponse.json();
		expect(quotaBody).toEqual({ error: { code: "PAYMENT_REQUIRED", message: "Meetup arrangement is unavailable", source: "meetup_arrange" } });
		expect(JSON.stringify(quotaBody)).not.toMatch(/count|limit|period|balance/i);
	});

	it("uses the retry paywall source and rejects caller fields", async () => {
		const invalidBody = await makeApp().request(`/api/meetups/${MEETUP_ID}/retry`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ user_id: USER_ID }),
		});
		expect(invalidBody.status).toBe(400);
		expect(mockedRetryMeetupArrangement).not.toHaveBeenCalled();

		mockedRetryMeetupArrangement.mockResolvedValue({ ok: false, reason: "quota_exhausted" });
		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}/retry`, { method: "POST" });
		expect(response.status).toBe(402);
		expect(await response.json()).toEqual({ error: { code: "PAYMENT_REQUIRED", message: "Meetup arrangement is unavailable", source: "arrange_retry" } });
	});

	it("queues arrangement notifications without changing the accepted acknowledgement", async () => {
		mockedArrangeMeetup.mockResolvedValue({
			ok: true,
			status: "proposed",
			billingSource: "meetup_arrange",
			notificationContexts: [
				{
					scenarioId: "N-05",
					meetupId: MEETUP_ID,
					matchId: MATCH_ID,
					proposalId: "50000000-0000-0000-0000-000000000001",
					recipientIds: [USER_ID, "90000000-0000-0000-0000-000000000002"],
				},
			],
		});

		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}/arrange`, { method: "POST" });

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { accepted: true, status: "arranging" } });
		expect(notifyInBackground).toHaveBeenCalledTimes(1);
		await notifyInBackground.mock.calls[0][1]();
		expect(notifyMeetupArrangementMock).toHaveBeenCalledWith(
			expect.objectContaining({ supabase: expect.anything() }),
			expect.objectContaining({ scenarioId: "N-05", proposalId: "50000000-0000-0000-0000-000000000001" }),
		);
	});

	it("queues retry failure notifications through the same best-effort boundary", async () => {
		mockedRetryMeetupArrangement.mockResolvedValue({
			ok: true,
			status: "arrange_failed",
			billingSource: "arrange_retry",
			notificationContexts: [
				{
					scenarioId: "N-14",
					meetupId: MEETUP_ID,
					matchId: MATCH_ID,
					recipientIds: [USER_ID, "90000000-0000-0000-0000-000000000002"],
				},
			],
		});

		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}/retry`, { method: "POST" });

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { accepted: true, status: "arranging" } });
		expect(notifyInBackground).toHaveBeenCalledTimes(1);
		await notifyInBackground.mock.calls[0][1]();
		expect(notifyMeetupArrangementMock).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ scenarioId: "N-14", meetupId: MEETUP_ID }),
		);
	});
});

describe("POST /api/meetups/:id/proposals/:proposalId/responses", () => {
	const proposalId = "50000000-0000-0000-0000-000000000001";

	it("accepts only an integer candidate index and returns the response status", async () => {
		mockedRecordMeetupProposalResponse.mockResolvedValue({ ok: true, status: "confirmed" });
		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}/proposals/${proposalId}/responses`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ selected_candidate_index: 2 }),
		});
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { accepted: true, status: "confirmed" } });
		expect(mockedRecordMeetupProposalResponse).toHaveBeenCalledWith(expect.anything(), USER_ID, MEETUP_ID, proposalId, 2);

		for (const body of [{ selected_candidate_index: 1.5 }, { selected_candidate_index: 3 }, { selected_candidate_index: 0, user_id: USER_ID }]) {
			const invalid = await makeApp().request(`/api/meetups/${MEETUP_ID}/proposals/${proposalId}/responses`, {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify(body),
			});
			expect(invalid.status).toBe(400);
		}
	});

	it("maps every unavailable response relationship to the same 404", async () => {
		mockedRecordMeetupProposalResponse.mockResolvedValue({ ok: false, reason: "not_found" });
		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}/proposals/${proposalId}/responses`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ selected_candidate_index: 0 }),
		});
		expect(response.status).toBe(404);
		expect(await response.json()).toEqual({ error: { code: "NOT_FOUND", message: "Meetup not found" } });
	});

	it("queues confirmation notifications after a confirmed response", async () => {
		mockedRecordMeetupProposalResponse.mockResolvedValue({
			ok: true,
			status: "confirmed",
			notificationContexts: [
				{
					scenarioId: "N-06",
					meetupId: MEETUP_ID,
					matchId: MATCH_ID,
					recipientIds: [USER_ID, "90000000-0000-0000-0000-000000000002"],
				},
			],
		});

		const response = await makeApp().request(`/api/meetups/${MEETUP_ID}/proposals/${proposalId}/responses`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ selected_candidate_index: 1 }),
		});

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { accepted: true, status: "confirmed" } });
		expect(notifyInBackground).toHaveBeenCalledTimes(1);
		await notifyInBackground.mock.calls[0][1]();
		expect(notifyMeetupArrangementMock).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ scenarioId: "N-06" }),
		);
		expect(notifyMeetupArrangementMock.mock.calls[0][1]).not.toHaveProperty("proposalId");
	});
});

describe("meetup middleware/source boundary", () => {
	it("requires auth before age middleware in every route declaration", async () => {
		// The mocked middleware is intentionally no-op for age after setting the
		// server-resolved profile. This verifies the route cannot be mounted
		// without both named gates in the source contract, in the safe order.
		const moduleSource = await import("node:fs").then(({ readFileSync }) => readFileSync(new URL("./meetups.ts", import.meta.url), "utf8"));
		expect(moduleSource).toMatch(/meetups\.post\("\/intents",\s*requireAuth,\s*requireAgeVerified,/);
		expect(moduleSource).toMatch(/meetups\.get\("\/by-match\/:matchId",\s*requireAuth,\s*requireAgeVerified,/);
		expect(moduleSource).toMatch(/meetups\.get\("\/:id",\s*requireAuth,\s*requireAgeVerified,/);
		expect(moduleSource).toMatch(/meetups\.put\("\/:id\/preferences",\s*requireAuth,\s*requireAgeVerified,/);
		expect(moduleSource).toMatch(/meetups\.post\("\/:id\/arrange",\s*requireAuth,\s*requireAgeVerified,/);
		expect(moduleSource).toMatch(/meetups\.post\("\/:id\/retry",\s*requireAuth,\s*requireAgeVerified,/);
		expect(moduleSource).toMatch(/meetups\.post\("\/:id\/proposals\/\:proposalId\/responses",\s*requireAuth,\s*requireAgeVerified,/);
	});
});
