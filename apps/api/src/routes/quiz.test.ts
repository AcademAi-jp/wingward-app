import { Hono } from "hono";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", "user-1");
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import quiz from "./quiz";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);
const questionIds = Array.from({ length: 10 }, (_, index) => `q${index + 1}`);
const questions = questionIds.map((id) => ({ id, allow_multiple: false }));
const validAnswers = questionIds.map((question_id) => ({ question_id, selected: ["a"] }));

type Failure = "questions" | "answer" | "profile" | "onboarding" | null;
type Operation = "select" | "upsert" | "update";
type QueryCall = {
	table: string;
	operation: Operation;
	columns?: string;
	values?: unknown;
	options?: unknown;
	filters: Array<{ column: string; value: unknown; operator?: "neq" }>;
};

function makeSupabase(options: {
	failure?: Failure;
	onboardingStatus?: string;
	confirmBeforeUpdate?: boolean;
	questionRows?: Array<{ id: string; allow_multiple: boolean }>;
} = {}) {
	const calls: QueryCall[] = [];
	const profileState = { status: options.onboardingStatus ?? "not_started" };
	return {
		calls,
		profileState,
		from(table: string) {
			const trace: QueryCall = { table, operation: "select", filters: [] };
			const query: Record<string, (...args: never[]) => unknown> = {};
			let executed = false;

			const execute = () => {
				if (!executed) {
					calls.push({ ...trace, filters: [...trace.filters] });
					executed = true;
				}
				if (table === "quiz_questions") {
					return options.failure === "questions"
						? { data: null, error: { message: "canary" } }
						: { data: options.questionRows ?? questions, error: null };
				}
				if (table === "quiz_answers" && trace.operation === "upsert") {
					return options.failure === "answer"
						? { data: null, error: { message: "canary" } }
						: { data: null, error: null };
				}
				if (table === "user_profiles" && trace.operation === "select") {
					return options.failure === "profile"
						? { data: null, error: { message: "canary" } }
						: { data: { onboarding_status: profileState.status }, error: null };
				}
				if (table === "user_profiles" && trace.operation === "update") {
					if (options.confirmBeforeUpdate) profileState.status = "confirmed";
					if (options.failure === "onboarding") return { data: null, error: { message: "canary" } };
					const avoidsConfirmedDowngrade = trace.filters.some(
						(filter) => filter.column === "onboarding_status" && filter.value === "confirmed" && filter.operator === "neq",
					);
					if (profileState.status !== "confirmed" || !avoidsConfirmedDowngrade) {
						profileState.status = "quiz_completed";
					}
					return { data: null, error: null };
				}
				throw new Error(`unexpected query ${table}.${trace.operation}`);
			};

			query.select = ((columns: string) => {
				trace.columns = columns;
				return query;
			}) as never;
			query.order = (() => query) as never;
			query.eq = ((column: string, value: unknown) => {
				trace.filters.push({ column, value });
				return query;
			}) as never;
			query.neq = ((column: string, value: unknown) => {
				trace.filters.push({ column, value, operator: "neq" });
				return query;
			}) as never;
			query.upsert = ((values: unknown, upsertOptions: unknown) => {
				trace.operation = "upsert";
				trace.values = values;
				trace.options = upsertOptions;
				return query;
			}) as never;
			query.update = ((values: unknown) => {
				trace.operation = "update";
				trace.values = values;
				return query;
			}) as never;
			query.single = (() => Promise.resolve(execute())) as never;
			query.then = ((resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) =>
				Promise.resolve(execute()).then(resolve, reject)) as never;
			return query;
		},
	};
}

function createApp() {
	const app = new Hono();
	app.route("/api/quiz", quiz);
	return app;
}

function submit(payload: unknown = { answers: validAnswers }) {
	return createApp().request("/api/quiz/answers", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(payload),
	});
}

function submitRaw(body: string) {
	return createApp().request("/api/quiz/answers", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body,
	});
}

function writes(calls: QueryCall[]) {
	return calls.filter((call) => call.operation === "upsert" || call.operation === "update");
}

beforeEach(() => vi.restoreAllMocks());

describe("POST /api/quiz/answers", () => {
	it("validates and saves the full catalog in one owner-scoped bulk upsert", async () => {
		const supabase = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await submit();
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { message: "Answers saved", count: 10 } });

		const answerUpserts = supabase.calls.filter((call) => call.table === "quiz_answers" && call.operation === "upsert");
		expect(answerUpserts).toHaveLength(1);
		expect(answerUpserts[0].options).toEqual({ onConflict: "user_id,question_id" });
		expect(answerUpserts[0].values).toEqual(
			validAnswers.map(({ question_id, selected }) => ({ user_id: "user-1", question_id, selected })),
		);
		expect(supabase.calls.findIndex((call) => call.table === "user_profiles" && call.operation === "select"))
			.toBeLessThan(supabase.calls.findIndex((call) => call.table === "quiz_answers" && call.operation === "upsert"));

		const profileUpdate = supabase.calls.find((call) => call.table === "user_profiles" && call.operation === "update");
		expect(profileUpdate?.filters).toContainEqual({ column: "id", value: "user-1" });
		expect(profileUpdate?.filters).toContainEqual({ column: "onboarding_status", value: "confirmed", operator: "neq" });
	});

	it("preserves confirmed onboarding status while allowing answer edits", async () => {
		const supabase = makeSupabase({ onboardingStatus: "confirmed" });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await submit();

		expect(response.status).toBe(200);
		expect(supabase.calls.filter((call) => call.table === "quiz_answers" && call.operation === "upsert")).toHaveLength(1);
		expect(supabase.calls.filter((call) => call.table === "user_profiles" && call.operation === "update")).toHaveLength(0);
	});

	it("does not downgrade onboarding if another request confirms it after the status read", async () => {
		const supabase = makeSupabase({ confirmBeforeUpdate: true });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await submit();

		expect(response.status).toBe(200);
		expect(supabase.profileState.status).toBe("confirmed");
		expect(supabase.calls.find((call) => call.table === "user_profiles" && call.operation === "update")?.filters)
			.toContainEqual({ column: "onboarding_status", value: "confirmed", operator: "neq" });
	});

	it("returns 400 for malformed JSON without touching the database", async () => {
		const supabase = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await submitRaw("{");

		expect(response.status).toBe(400);
		expect(writes(supabase.calls)).toHaveLength(0);
		expect(supabase.calls).toHaveLength(0);
	});

	it.each([
		["empty answer list", { answers: [] }],
		["missing a catalog question", { answers: validAnswers.slice(1) }],
		["contains an unknown question", { answers: [...validAnswers.slice(0, 9), { question_id: "q11", selected: ["a"] }] }],
		["contains a duplicate question", { answers: [...validAnswers.slice(0, 9), { question_id: "q1", selected: ["b"] }] }],
		["contains an empty selection", { answers: validAnswers.map((answer, index) => index === 0 ? { ...answer, selected: [] } : answer) }],
		["contains multiple values for a single-choice question", { answers: validAnswers.map((answer, index) => index === 0 ? { ...answer, selected: ["a", "b"] } : answer) }],
		["contains an unsupported choice", { answers: validAnswers.map((answer, index) => index === 0 ? { ...answer, selected: ["z"] } : answer) }],
		["contains duplicate selected values", { answers: validAnswers.map((answer, index) => index === 0 ? { ...answer, selected: ["a", "a"] } : answer) }],
		["attempts to provide an owner", { answers: validAnswers, user_id: "user-2" }],
	] as const)("rejects a request that %s before writing", async (_description, payload) => {
		const supabase = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await submit(payload);

		expect(response.status).toBe(400);
		expect(writes(supabase.calls)).toHaveLength(0);
	});
});

describe("POST /api/quiz/answers failures", () => {
	it.each(["questions", "profile", "answer", "onboarding"] as const)("fails closed when the %s operation fails", async (failure) => {
		const supabase = makeSupabase({ failure });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await submit();
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("canary");
		if (failure === "questions" || failure === "profile") {
			expect(writes(supabase.calls)).toHaveLength(0);
		}
		if (failure === "answer") {
			expect(supabase.calls.filter((call) => call.table === "quiz_answers" && call.operation === "upsert")).toHaveLength(1);
			expect(supabase.calls.filter((call) => call.table === "user_profiles" && call.operation === "update")).toHaveLength(0);
		}
	});

	it("fails closed before writing when the database catalog drifts from the supported catalog", async () => {
		const supabase = makeSupabase({ questionRows: [...questions.slice(0, 9), { id: "q11", allow_multiple: false }] });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await submit();

		expect(response.status).toBe(500);
		expect(writes(supabase.calls)).toHaveLength(0);
	});
});
