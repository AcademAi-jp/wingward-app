import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

const OWNER_ID = vi.hoisted(() => "11111111-1111-4111-8111-111111111111");

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", OWNER_ID);
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import speedDating from "./speed-dating";

const OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222";
const PERSONA_ONE_ID = "33333333-3333-4333-8333-333333333333";
const PERSONA_TWO_ID = "44444444-4444-4444-8444-444444444444";
const SESSION_ONE_ID = "55555555-5555-4555-8555-555555555555";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

type QueryState = {
	table: string;
	filters: Record<string, unknown>;
	order?: { column: string; ascending?: boolean; nullsFirst?: boolean };
	limit?: number;
};

type FakeOptions = {
	personas?: unknown[];
	sessionRows?: Record<string, unknown>;
	sessionError?: unknown;
};

function makeSupabase(options: FakeOptions = {}) {
	const tables: string[] = [];
	const sessionQueries: QueryState[] = [];
	const opts = {
		personas: options.personas ?? [
			{
				id: PERSONA_ONE_ID,
				user_id: OWNER_ID,
				persona_type: "virtual_similar",
				name: "Sakura",
				compiled_document: "private document",
			},
			{
				id: PERSONA_TWO_ID,
				user_id: OWNER_ID,
				persona_type: "virtual_discovery",
				name: "Aoi",
				compiled_document: "private document",
			},
		],
		sessionRows: options.sessionRows ?? {
			[PERSONA_ONE_ID]: {
				id: SESSION_ONE_ID,
				user_id: OWNER_ID,
				persona_id: PERSONA_ONE_ID,
				status: "completed",
				completed_at: "2026-09-14T00:00:00.000Z",
			},
			[PERSONA_TWO_ID]: null,
		},
		sessionError: options.sessionError ?? null,
	};

	function query(table: string) {
		const state: QueryState = { table, filters: {} };
		const builder: Record<string, unknown> = {};
		for (const method of ["select", "in", "eq", "maybeSingle"]) {
			builder[method] = (...args: unknown[]) => {
				if (method === "eq") state.filters[String(args[0])] = args[1];
				return builder;
			};
		}
		builder.order = (column: string, order: QueryState["order"]) => {
			state.order = { column, ...order };
			return builder;
		};
		builder.limit = (limit: number) => {
			state.limit = limit;
			return builder;
		};
		builder.then = (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => {
			let result: unknown;
			if (table === "personas") {
				result = { data: opts.personas, error: null };
			} else if (table === "persona_sections") {
				result = {
					data: [{ section_id: "core_identity", content: "A bounded section" }],
					error: null,
				};
			} else if (table === "speed_dating_sessions") {
				sessionQueries.push(state);
				result = {
					data: opts.sessionRows[String(state.filters.persona_id)] ?? null,
					error: opts.sessionError,
				};
			}
			return Promise.resolve(result).then(resolve, reject);
		};
		return builder;
	}

	return {
		tables,
		sessionQueries,
		from(table: string) {
			tables.push(table);
			return query(table);
		},
	};
}

function buildApp() {
	const app = new Hono();
	app.route("/api/speed-dating", speedDating);
	return app;
}

beforeEach(() => {
	vi.restoreAllMocks();
});

describe("GET /api/speed-dating/personas completed-session projection", () => {
	it("returns the latest bounded owned completed session ID and never reads transcripts", async () => {
		const supabase = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/speed-dating/personas");
		const body = (await response.json()) as { data: Array<Record<string, unknown>> };

		expect(response.status).toBe(200);
		expect(body.data).toHaveLength(2);
		expect(body.data[0]).toMatchObject({ id: PERSONA_ONE_ID, completed_session_id: SESSION_ONE_ID });
		expect(body.data[1]).toMatchObject({ id: PERSONA_TWO_ID, completed_session_id: null });
		expect(body.data[0]).not.toHaveProperty("user_id");
		expect(supabase.tables).not.toContain("speed_dating_messages");
		expect(supabase.sessionQueries).toHaveLength(2);
		expect(supabase.sessionQueries.every((query) =>
		query.order?.column === "completed_at"
		&& query.order.ascending === false
		&& query.order.nullsFirst === false
		&& query.limit === 1,
	)).toBe(true);
	});

	it("rejects a completed-session query error without exposing its details", async () => {
		const supabase = makeSupabase({ sessionError: { message: "PWNED-CANARY-SESSION-READ" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/speed-dating/personas");
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-SESSION-READ");
		expect(supabase.tables).not.toContain("speed_dating_messages");
	});

	it("rejects a service-role persona row owned by another user", async () => {
		const supabase = makeSupabase({
			personas: [{
				id: PERSONA_ONE_ID,
				user_id: OTHER_OWNER_ID,
				persona_type: "virtual_similar",
				name: "Private other user",
				compiled_document: "do not expose",
			}],
		});
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/speed-dating/personas");
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("Private other user");
		expect(supabase.tables).not.toContain("speed_dating_messages");
	});

	it("rejects a completed session row owned by another user", async () => {
		const supabase = makeSupabase({
			sessionRows: {
				[PERSONA_ONE_ID]: {
					id: SESSION_ONE_ID,
					user_id: OTHER_OWNER_ID,
					persona_id: PERSONA_ONE_ID,
					status: "completed",
					completed_at: "2026-09-14T00:00:00.000Z",
				},
			},
		});
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await buildApp().request("/api/speed-dating/personas");
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain(OTHER_OWNER_ID);
		expect(supabase.tables).not.toContain("speed_dating_messages");
	});
});
