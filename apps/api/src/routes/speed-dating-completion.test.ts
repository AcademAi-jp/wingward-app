import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "10000000-0000-0000-0000-000000000001");
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import speedDating from "./speed-dating";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const sessionID = "20000000-0000-0000-0000-000000000001";
const ownerID = "10000000-0000-0000-0000-000000000001";

type RpcRow = {
	session_id: string | null;
	status: string | null;
	message_count: number | null;
	all_sessions_completed: boolean;
	outcome: "stored" | "already_completed" | "not_found" | "invalid_input" | "invalid_state" | "conflict";
};

function makeRpc(row: RpcRow | null = {
	session_id: sessionID,
	status: "completed",
	message_count: 2,
	all_sessions_completed: false,
	outcome: "stored",
}) {
	return vi.fn(async () => ({ data: row ? [row] : null, error: null }));
}

function makeRequest(body?: string) {
	const app = new Hono();
	app.route("/api/speed-dating", speedDating);
	return app.request(`/api/speed-dating/sessions/${sessionID}/complete`, {
		method: "POST",
		headers: body === undefined ? undefined : { "Content-Type": "application/json" },
		body,
	}, {});
}

beforeEach(() => {
	vi.restoreAllMocks();
});

describe("POST /api/speed-dating/sessions/:id/complete", () => {
	it("keeps the incremental web path and passes an omitted body as null", async () => {
		const rpc = makeRpc();
		mockedGetSupabaseClient.mockReturnValue({ rpc } as never);

		const response = await makeRequest();

		expect(response.status).toBe(200);
		expect(rpc).toHaveBeenCalledWith("complete_speed_dating_session", {
			p_session_id: sessionID,
			p_user_id: ownerID,
			p_transcript: null,
		});
	});

	it("passes a bounded transcript to the atomic RPC", async () => {
		const rpc = makeRpc();
		mockedGetSupabaseClient.mockReturnValue({ rpc } as never);
		const transcript = [
			{ source: "user", message: "A quiet morning." },
			{ source: "ai", message: "That sounds restorative." },
		];

		const response = await makeRequest(JSON.stringify({ transcript }));

		expect(response.status).toBe(200);
		expect(rpc).toHaveBeenCalledWith("complete_speed_dating_session", {
			p_session_id: sessionID,
			p_user_id: ownerID,
			p_transcript: transcript,
		});
		expect(await response.json()).toEqual({
			data: { session_id: sessionID, status: "completed", all_sessions_completed: false },
		});
	});

	it.each([
		["malformed JSON", "{"],
		["an empty transcript", JSON.stringify({ transcript: [] })],
		["a blank message", JSON.stringify({ transcript: [{ source: "user", message: "  " }] })],
		["too many entries", JSON.stringify({ transcript: Array.from({ length: 201 }, () => ({ source: "user", message: "x" })) })],
		["an overlong message", JSON.stringify({ transcript: [{ source: "user", message: "x".repeat(2001) }] })],
	] as const)("rejects %s before calling the RPC", async (_label, body) => {
		const rpc = makeRpc();
		mockedGetSupabaseClient.mockReturnValue({ rpc } as never);

		const response = await makeRequest(body);

		expect(response.status).toBe(400);
		expect(rpc).not.toHaveBeenCalled();
	});

	it("maps not found, conflicts, and malformed stored state to safe outcomes", async () => {
		for (const [outcome, status] of [["not_found", 404], ["invalid_input", 400], ["conflict", 409], ["invalid_state", 409]] as const) {
			const rpc = makeRpc({
				session_id: outcome === "not_found" ? null : sessionID,
				status: ["not_found", "invalid_input"].includes(outcome) ? null : "active",
				message_count: ["not_found", "invalid_input"].includes(outcome) ? null : 1,
				all_sessions_completed: false,
				outcome,
			});
			mockedGetSupabaseClient.mockReturnValue({ rpc } as never);

			const response = await makeRequest();

			expect(response.status).toBe(status);
		}
	});

	it("returns the same stable envelope for an idempotent completed replay", async () => {
		const rpc = makeRpc({
			session_id: sessionID,
			status: "completed",
			message_count: 2,
			all_sessions_completed: true,
			outcome: "already_completed",
		});
		mockedGetSupabaseClient.mockReturnValue({ rpc } as never);

		const response = await makeRequest(JSON.stringify({
			transcript: [{ source: "user", message: "same saved body" }],
		}));

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({
			data: { session_id: sessionID, status: "completed", all_sessions_completed: true },
		});
	});

	it("fails closed when the RPC response is unavailable or malformed", async () => {
		const rpc = vi.fn(async () => ({ data: null, error: { message: "database unavailable" } }));
		mockedGetSupabaseClient.mockReturnValue({ rpc } as never);
		const response = await makeRequest();
		expect(response.status).toBe(500);
		expect(await response.text()).not.toContain("database unavailable");

		const malformedRpc = vi.fn(async () => ({
			data: [{ session_id: sessionID, status: "completed", message_count: 1, all_sessions_completed: false, outcome: "unexpected" }],
			error: null,
		}));
		mockedGetSupabaseClient.mockReturnValue({ rpc: malformedRpc } as never);
		const malformedResponse = await makeRequest();
		expect(malformedResponse.status).toBe(500);
	});
});
