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
import personas from "./personas";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

interface FakeOpts {
	personaLookupError?: { message: string } | null;
	definition?: { editable: boolean } | null;
	definitionError?: { message: string } | null;
	sectionUpdateError?: { message: string } | null;
	sectionsReadError?: { message: string } | null;
	personaUpdateError?: { message: string } | null;
	updatedReadError?: { message: string } | null;
	updatedData?: Record<string, unknown> | null;
}

function makeFakeSupabase(opts: FakeOpts = {}) {
	let sectionUpdateCount = 0;
	let personaUpdateCount = 0;
	const updatedData = opts.updatedData === undefined
		? { id: "section-1", section_id: "conversation_references", content: "new content", source: "manual", updated_at: "2026-08-30T00:00:00.000Z" }
		: opts.updatedData;
	return {
		sectionUpdateCount: () => sectionUpdateCount,
		personaUpdateCount: () => personaUpdateCount,
		from(table: string) {
			if (table === "personas") {
				return {
					select: () => ({
						eq: () => ({
							eq: () => ({ single: async () => ({ data: { id: "persona-1" }, error: opts.personaLookupError ?? null }) }),
						}),
					}),
					update: () => {
						personaUpdateCount += 1;
						return { eq: async () => ({ error: opts.personaUpdateError ?? null }) };
					},
				};
			}
			if (table === "persona_section_definitions") {
				return {
					select: () => ({
						eq: () => ({
							single: async () => ({
								data: opts.definition ?? null,
								error: opts.definitionError ?? null,
							}),
						}),
					}),
				};
			}
			if (table === "persona_sections") {
				return {
					update: () => {
						sectionUpdateCount += 1;
						return { eq: () => ({ eq: async () => ({ error: opts.sectionUpdateError ?? null }) }) };
					},
					select: (columns: string) => {
						if (columns === "section_id, content") {
							return {
								eq: () => ({
									order: async () => ({
										data: [{ section_id: "conversation_references", content: "new content" }],
										error: opts.sectionsReadError ?? null,
									}),
								}),
							};
						}
						return {
							eq: () => ({
								eq: () => ({
									single: async () => ({ data: updatedData, error: opts.updatedReadError ?? null }),
								}),
							}),
						};
					},
				};
			}
			throw new Error(`unexpected table ${table}`);
		},
	};
}

function buildApp() {
	const app = new Hono();
	app.route("/api/personas", personas);
	return app;
}

async function updateSection() {
	return buildApp().request("/api/personas/persona-1/sections/conversation_references", {
		method: "PUT",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ content: "new content" }),
	});
}

beforeEach(() => {
	vi.restoreAllMocks();
});

describe("PUT /api/personas/:personaId/sections/:sectionId definition guard", () => {
	it("fails closed before updating when persona ownership cannot be verified", async () => {
		const supabase = makeFakeSupabase({ personaLookupError: { message: "PWNED-CANARY-OWNERSHIP" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await updateSection();
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-OWNERSHIP");
		expect(supabase.sectionUpdateCount()).toBe(0);
	});

	it("fails closed without updating when the definition lookup errors", async () => {
		const supabase = makeFakeSupabase({ definitionError: { message: "PWNED-CANARY-DEFINITION" } });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await updateSection();
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toContain("PWNED-CANARY-DEFINITION");
		expect(supabase.sectionUpdateCount()).toBe(0);
	});

	it("treats a missing definition as non-editable instead of allowing the update", async () => {
		const supabase = makeFakeSupabase({ definition: null });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await updateSection();
		const body = (await response.json()) as { error: { code: string; message: string } };

		expect(response.status).toBe(403);
		expect(body.error).toEqual({ code: "FORBIDDEN", message: "Section not editable" });
		expect(supabase.sectionUpdateCount()).toBe(0);
	});
});

describe("PUT /api/personas/:personaId/sections/:sectionId persistence failures", () => {
	it.each([
		{
			name: "section update",
			options: { sectionUpdateError: { message: "PWNED-CANARY-SECTION-UPDATE" } },
			message: "Failed to update persona section",
		},
		{
			name: "sections read",
			options: { sectionsReadError: { message: "PWNED-CANARY-SECTIONS-READ" } },
			message: "Failed to read persona sections",
		},
		{
			name: "compiled document update",
			options: { personaUpdateError: { message: "PWNED-CANARY-PERSONA-UPDATE" } },
			message: "Failed to update persona",
		},
		{
			name: "updated section read",
			options: { updatedReadError: { message: "PWNED-CANARY-UPDATED-READ" } },
			message: "Failed to read updated persona section",
		},
		{
			name: "updated section missing",
			options: { updatedData: null },
			message: "Failed to read updated persona section",
		},
	] as const)("fails closed when the $name fails", async ({ options, message }) => {
		const supabase = makeFakeSupabase({ definition: { editable: true }, ...options });
		mockedGetSupabaseClient.mockReturnValue(supabase as never);

		const response = await updateSection();
		const body = await response.text();

		expect(response.status).toBe(500);
		expect(body).not.toMatch(/PWNED-CANARY/);
		expect(JSON.parse(body)).toEqual({ error: { code: "INTERNAL_ERROR", message } });
	});
});
