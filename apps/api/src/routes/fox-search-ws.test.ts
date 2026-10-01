import { describe, expect, it, vi, beforeEach } from "vitest";

/**
 * Step-3c, acceptance conditions 1-4 and 6: the WebSocket edge handshake
 * must authenticate and authorize BEFORE calling `idFromName` (gap G2,
 * step-3 §4-C-1) — calling it for an unauthorized request already spins up
 * a billable Durable Object regardless of what happens afterward.
 *
 * `resolveAuthUser` and `checkFoxConversationParticipant` are mocked here
 * because they're each covered by their own unit tests (middleware/auth.ts
 * has no dedicated test file yet, but fox-conversation-access is exercised
 * indirectly through fox-search.test.ts's status route coverage plus this
 * file); what this file verifies is the route's *ordering* and its
 * interaction with the DO namespace.
 */

vi.mock("../middleware/auth", () => ({
	resolveAuthUser: vi.fn(),
	getAgeVerificationStatus: vi.fn(),
}));
vi.mock("../services/fox-conversation-access", () => ({
	checkFoxConversationParticipant: vi.fn(),
}));
vi.mock("../db/client", () => ({
	getSupabaseClient: vi.fn(() => ({})),
}));

import { Hono } from "hono";
import { getAgeVerificationStatus, resolveAuthUser } from "../middleware/auth";
import { checkFoxConversationParticipant } from "../services/fox-conversation-access";
import foxSearchWs, { __testing } from "./fox-search-ws";

const mockedResolveAuthUser = vi.mocked(resolveAuthUser);
const mockedGetAgeVerificationStatus = vi.mocked(getAgeVerificationStatus);
const mockedCheckParticipant = vi.mocked(checkFoxConversationParticipant);

function buildApp() {
	const app = new Hono();
	app.route("/api/fox-search", foxSearchWs);
	return app;
}

function makeDoNamespace() {
	// A real 101 response isn't constructible outside the Workers runtime
	// (undici/Node's Response rejects status 101) — Task 0 already verified
	// the actual 101 + Sec-WebSocket-Protocol behavior empirically against
	// workerd. Here the DO stub is a plain mock; this test's job is only to
	// prove the edge route calls it correctly and forwards its response.
	const fetchSpy = vi.fn(async (_req: Request) => new Response(null, { status: 200, headers: { "X-Fake-Do-Reached": "true" } }));
	const getSpy = vi.fn(() => ({ fetch: fetchSpy }));
	const idFromNameSpy = vi.fn((name: string) => ({ __id: name }));
	return { ns: { idFromName: idFromNameSpy, get: getSpy }, idFromNameSpy, getSpy, fetchSpy };
}

function wsHeaders(extra: Record<string, string> = {}): Record<string, string> {
	return { Upgrade: "websocket", ...extra };
}

beforeEach(() => {
	mockedResolveAuthUser.mockReset();
	mockedGetAgeVerificationStatus.mockReset();
	mockedGetAgeVerificationStatus.mockResolvedValue("verified");
	mockedCheckParticipant.mockReset();
});

describe("GET /api/fox-search/ws/:conversationId", () => {
	it("condition 1: without an Upgrade header, returns 426 without touching auth or the DO", async () => {
		const app = buildApp();
		const { ns, idFromNameSpy } = makeDoNamespace();

		const res = await app.request(
			"/api/fox-search/ws/conv-1",
			{ headers: {} },
			{ FOX_CONVERSATION: ns },
		);

		expect(res.status).toBe(426);
		expect(mockedResolveAuthUser).not.toHaveBeenCalled();
		expect(idFromNameSpy).not.toHaveBeenCalled();
	});

	it("condition 1: with an Upgrade header but no Sec-WebSocket-Protocol, returns 401 (not 101) and never calls idFromName", async () => {
		const app = buildApp();
		const { ns, idFromNameSpy } = makeDoNamespace();

		const res = await app.request(
			"/api/fox-search/ws/conv-1",
			{ headers: wsHeaders() },
			{ FOX_CONVERSATION: ns },
		);

		expect(res.status).toBe(401);
		expect(mockedResolveAuthUser).not.toHaveBeenCalled();
		expect(idFromNameSpy).not.toHaveBeenCalled();
	});

	it("condition 1 variant: an invalid/expired JWT in the subprotocol returns 401 and never calls idFromName", async () => {
		mockedResolveAuthUser.mockResolvedValue(null);
		const app = buildApp();
		const { ns, idFromNameSpy } = makeDoNamespace();

		const res = await app.request(
			"/api/fox-search/ws/conv-1",
			{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "wingward.jwt.bad-token" }) },
			{ FOX_CONVERSATION: ns },
		);

		expect(res.status).toBe(401);
		expect(mockedResolveAuthUser).toHaveBeenCalledWith(expect.anything(), "bad-token");
		expect(idFromNameSpy).not.toHaveBeenCalled();
	});

	it("rejects an authenticated but unverified user before participant lookup or idFromName", async () => {
		mockedResolveAuthUser.mockResolvedValue({ authUserId: "auth-x", userId: "user-x" });
		mockedGetAgeVerificationStatus.mockResolvedValue("unverified");
		const app = buildApp();
		const { ns, idFromNameSpy } = makeDoNamespace();

		const res = await app.request(
			"/api/fox-search/ws/conv-1",
			{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "wingward.jwt.valid-token" }) },
			{ FOX_CONVERSATION: ns },
		);

		expect(res.status).toBe(403);
		expect(mockedCheckParticipant).not.toHaveBeenCalled();
		expect(idFromNameSpy).not.toHaveBeenCalled();
	});

	it("fails closed when the age lookup errors before participant lookup or idFromName", async () => {
		mockedResolveAuthUser.mockResolvedValue({ authUserId: "auth-x", userId: "user-x" });
		mockedGetAgeVerificationStatus.mockResolvedValue("error");
		const app = buildApp();
		const { ns, idFromNameSpy } = makeDoNamespace();

		const res = await app.request(
			"/api/fox-search/ws/conv-1",
			{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "wingward.jwt.valid-token" }) },
			{ FOX_CONVERSATION: ns },
		);

		expect(res.status).toBe(500);
		expect(mockedCheckParticipant).not.toHaveBeenCalled();
		expect(idFromNameSpy).not.toHaveBeenCalled();
	});

	/**
	 * Condition 2 / gap G2's core assertion: proving `idFromName` is never
	 * called for an unauthorized request — not just checking the response
	 * status, which a naively-ordered implementation could satisfy while
	 * still spinning up the DO. This is the assertion the task instructions
	 * call out by name as easy to fake.
	 */
	it("condition 2: a valid JWT for someone else's conversation returns 403 and idFromName is NEVER called", async () => {
		mockedResolveAuthUser.mockResolvedValue({ authUserId: "auth-x", userId: "user-outsider" });
		mockedCheckParticipant.mockResolvedValue({ ok: false, reason: "forbidden" });
		const app = buildApp();
		const { ns, idFromNameSpy, getSpy } = makeDoNamespace();

		const res = await app.request(
			"/api/fox-search/ws/conv-not-mine",
			{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "wingward.jwt.valid-token" }) },
			{ FOX_CONVERSATION: ns },
		);

		expect(res.status).toBe(403);
		const body = await res.text();
		expect(body).not.toMatch(/user-outsider|conv-not-mine/); // no internal state leaked (§5)
		expect(idFromNameSpy).not.toHaveBeenCalled();
		expect(getSpy).not.toHaveBeenCalled();
	});

	it("condition 3: a nonexistent conversation id returns 404 and idFromName is never called", async () => {
		mockedResolveAuthUser.mockResolvedValue({ authUserId: "auth-x", userId: "user-x" });
		mockedCheckParticipant.mockResolvedValue({ ok: false, reason: "not_found" });
		const app = buildApp();
		const { ns, idFromNameSpy } = makeDoNamespace();

		const res = await app.request(
			"/api/fox-search/ws/does-not-exist",
			{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "wingward.jwt.valid-token" }) },
			{ FOX_CONVERSATION: ns },
		);

		expect(res.status).toBe(404);
		expect(idFromNameSpy).not.toHaveBeenCalled();
	});

	it("condition 4: a participant with a valid JWT reaches the DO, with idFromName called only after auth+authz pass, subprotocol echoed by the DO response, and the verified user id forwarded", async () => {
		mockedResolveAuthUser.mockResolvedValue({ authUserId: "auth-a", userId: "user-a" });
		mockedCheckParticipant.mockResolvedValue({ ok: true, matchId: "match-1" });
		const app = buildApp();
		const { ns, idFromNameSpy, getSpy, fetchSpy } = makeDoNamespace();

		const res = await app.request(
			"/api/fox-search/ws/conv-mine",
			{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "wingward.jwt.valid-token" }) },
			{ FOX_CONVERSATION: ns },
		);

		expect(res.status).toBe(200);
		expect(res.headers.get("X-Fake-Do-Reached")).toBe("true");
		expect(idFromNameSpy).toHaveBeenCalledWith("conv-mine");
		expect(getSpy).toHaveBeenCalledTimes(1);
		expect(fetchSpy).toHaveBeenCalledTimes(1);
		const forwardedRequest = fetchSpy.mock.calls[0][0] as Request;
		expect(forwardedRequest.headers.get("X-Verified-User-Id")).toBe("user-a");
		expect(forwardedRequest.headers.get("X-Verified-Ws-Protocol")).toBe("wingward.jwt.valid-token");
	});

	it("rechecks a cached positive participant result on reconnect and rejects a newly forbidden user before DO creation", async () => {
		const conversationId = "conv-cache-recheck";
		const userId = "user-cache-recheck";
		mockedResolveAuthUser.mockResolvedValue({ authUserId: "auth-cache-recheck", userId });
		mockedGetAgeVerificationStatus.mockResolvedValue("verified");
		mockedCheckParticipant
			.mockResolvedValueOnce({ ok: true, matchId: "match-cache-recheck" })
			.mockResolvedValueOnce({ ok: false, reason: "forbidden" });
		const app = buildApp();
		const { ns, idFromNameSpy, getSpy, fetchSpy } = makeDoNamespace();
		const request = () =>
			app.request(
				`/api/fox-search/ws/${conversationId}`,
				{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "wingward.jwt.cache-recheck" }) },
				{ FOX_CONVERSATION: ns },
			);

		const first = await request();
		const second = await request();

		expect(first.status).toBe(200);
		expect(second.status).toBe(403);
		expect(mockedGetAgeVerificationStatus).toHaveBeenCalledTimes(2);
		expect(mockedCheckParticipant).toHaveBeenCalledTimes(2);
		expect(mockedCheckParticipant).toHaveBeenNthCalledWith(1, expect.anything(), conversationId, userId);
		expect(mockedCheckParticipant).toHaveBeenNthCalledWith(2, expect.anything(), conversationId, userId);
		expect(idFromNameSpy).toHaveBeenCalledTimes(1);
		expect(idFromNameSpy).toHaveBeenCalledWith(conversationId);
		expect(getSpy).toHaveBeenCalledTimes(1);
		expect(fetchSpy).toHaveBeenCalledTimes(1);
	});

	/**
	 * F1 (step-3c review): the edge must forward the single value it
	 * SELECTED out of the client's offer, not the raw (possibly
	 * comma-joined) Sec-WebSocket-Protocol header — RFC 6455 §4.1 requires
	 * echoing exactly one of the offered values, and the DO now trusts
	 * whatever arrives in X-Verified-Ws-Protocol verbatim (it no longer
	 * re-parses Sec-WebSocket-Protocol itself). A raw multi-value header
	 * forwarded as-is would echo a value the browser never offered as a
	 * single token, failing the handshake.
	 */
	it("F1: when the client offers multiple subprotocol values, only the selected wingward.jwt.* value is forwarded to the DO", async () => {
		mockedResolveAuthUser.mockResolvedValue({ authUserId: "auth-a", userId: "user-a" });
		mockedCheckParticipant.mockResolvedValue({ ok: true, matchId: "match-1" });
		const app = buildApp();
		const { ns, fetchSpy } = makeDoNamespace();

		const res = await app.request(
			"/api/fox-search/ws/conv-mine",
			{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "some-other-protocol, wingward.jwt.valid-token" }) },
			{ FOX_CONVERSATION: ns },
		);

		expect(res.status).toBe(200);
		const forwardedRequest = fetchSpy.mock.calls[0][0] as Request;
		const forwarded = forwardedRequest.headers.get("X-Verified-Ws-Protocol");
		expect(forwarded).toBe("wingward.jwt.valid-token");
		expect(forwarded).not.toContain(",");
		expect(forwarded).not.toContain("some-other-protocol");
	});

	it("returns 503 (not a crash) when the DO namespace binding is missing, even for an authorized participant", async () => {
		mockedResolveAuthUser.mockResolvedValue({ authUserId: "auth-a", userId: "user-a" });
		mockedCheckParticipant.mockResolvedValue({ ok: true, matchId: "match-1" });
		const app = buildApp();

		const res = await app.request(
			"/api/fox-search/ws/conv-mine",
			{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "wingward.jwt.valid-token" }) },
			{},
		);

		expect(res.status).toBe(503);
	});

	/**
	 * F2 (step-3c review): the participant cache is keyed by
	 * conversationId:userId where conversationId is arbitrary client input,
	 * and negative results are cached too (required for G4) — so without a
	 * cap, any authenticated caller could grow this module-global Map
	 * without bound just by varying conversationId across requests.
	 */
	it("F2: the participant cache never grows past its configured cap, even under many distinct conversation ids", async () => {
		mockedResolveAuthUser.mockResolvedValue({ authUserId: "auth-a", userId: "user-a" });
		mockedCheckParticipant.mockResolvedValue({ ok: false, reason: "forbidden" });
		const app = buildApp();
		const { ns } = makeDoNamespace();

		const requestCount = __testing.PARTICIPANT_CACHE_MAX_ENTRIES + 500;
		for (let i = 0; i < requestCount; i++) {
			await app.request(
				`/api/fox-search/ws/conv-${i}`,
				{ headers: wsHeaders({ "Sec-WebSocket-Protocol": "wingward.jwt.valid-token" }) },
				{ FOX_CONVERSATION: ns },
			);
		}

		expect(__testing.participantCacheSize()).toBeLessThanOrEqual(__testing.PARTICIPANT_CACHE_MAX_ENTRIES);
	});
});
