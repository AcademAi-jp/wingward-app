import { describe, expect, it, vi } from "vitest";
import { MATCHING_ELIGIBILITY_COLUMNS } from "./matching-eligibility";
import { insertMatchesRejectingBlockedPairs } from "./insert-matches";

const TIMESTAMP = "2026-09-05T00:00:00.000Z";

function eligibilityProfile(
	id: string,
	identity: "woman" | "man" | "nonbinary",
	preferredGenders: Array<"woman" | "man" | "nonbinary">,
) {
	return {
		id,
		age_verified_at: TIMESTAMP,
		gender_identity: identity,
		preferred_genders: preferredGenders,
		preference_mode: "selected",
		dating_market: "JP",
		onboarding_settings_completed_at: TIMESTAMP,
	};
}

function makeRefreshScenario(options: {
	profileRows: unknown[];
	profileError?: unknown;
	throwProfileLookup?: boolean;
	blocks?: unknown[];
	retryError?: unknown;
}) {
	const insertedRows: Array<Array<{ user_a_id: string; user_b_id: string }>> = [];
	let selectedColumns = "";
	let insertCallCount = 0;

	// biome-ignore lint/suspicious/noExplicitAny: minimal Supabase test double
	const supabase: any = {
		from(table: string) {
			if (table === "matches") {
				return {
					insert(inserted: Array<{ user_a_id: string; user_b_id: string }>) {
						insertedRows.push(inserted);
						return {
							select: async () => {
								insertCallCount += 1;
								if (insertCallCount === 1) {
									return { data: null, error: { code: "23514", message: "stale eligibility" } };
								}
								if (options.retryError) return { data: null, error: options.retryError };
								return { data: inserted.map(() => ({ id: "match-valid" })), error: null };
							},
						};
					},
				};
			}
			if (table === "blocks") {
				return { select: async () => ({ data: options.blocks ?? [], error: null }) };
			}
			if (table === "user_profiles") {
				return {
					select(columns: string) {
						selectedColumns = columns;
						return {
							in: async () => {
								if (options.throwProfileLookup) throw new Error("raw eligibility details");
								return { data: options.profileRows, error: options.profileError ?? null };
							},
						};
					},
				};
			}
			throw new Error(`unexpected table: ${table}`);
		},
	};

	return { supabase, insertedRows, getSelectedColumns: () => selectedColumns, getInsertCallCount: () => insertCallCount };
}

describe("insertMatchesRejectingBlockedPairs", () => {
	it("refreshes block and preference eligibility and preserves kept indices on a 23514 retry", async () => {
		const rows = [
			// Preference changed to one-way after discovery; this row must be dropped.
			{ user_a_id: "user-a", user_b_id: "user-b" },
			// Preferences remain valid, but a block committed after discovery.
			{ user_a_id: "user-a", user_b_id: "user-c" },
			// This row remains valid and must retain its original index (2).
			{ user_a_id: "user-a", user_b_id: "user-d" },
		];
		const profiles = [
			eligibilityProfile("user-a", "woman", ["man"]),
			eligibilityProfile("user-b", "man", ["nonbinary"]),
			eligibilityProfile("user-c", "man", ["woman"]),
			eligibilityProfile("user-d", "man", ["woman"]),
		];
		const consoleWarnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
		const { supabase, insertedRows, getSelectedColumns } = makeRefreshScenario({
			profileRows: profiles,
			blocks: [{ blocker_id: "user-a", blocked_id: "user-c" }],
		});

		try {
			const result = await insertMatchesRejectingBlockedPairs(supabase as never, rows, "[insert-test]");

			expect(getSelectedColumns()).toBe(MATCHING_ELIGIBILITY_COLUMNS);
			expect(insertedRows).toEqual([rows, [rows[2]]]);
			expect(result).toEqual({ inserted: [{ id: "match-valid" }], keptIndices: [2] });
		} finally {
			consoleWarnSpy.mockRestore();
		}
	});

	it("fails closed when refreshed eligibility returns a database error", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const { supabase, getInsertCallCount } = makeRefreshScenario({
			profileRows: [
				eligibilityProfile("user-a", "woman", ["man"]),
				eligibilityProfile("user-b", "man", ["woman"]),
			],
			profileError: { code: "PGRST000", message: "raw profile failure" },
		});

		try {
			await expect(
				insertMatchesRejectingBlockedPairs(supabase as never, [{ user_a_id: "user-a", user_b_id: "user-b" }], "[insert-test]"),
			).rejects.toThrow("matching eligibility could not be re-read");
			expect(getInsertCallCount()).toBe(1);
			expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("raw profile failure");
		} finally {
			consoleErrorSpy.mockRestore();
		}
	});

	it("fails closed when refreshed eligibility lookup throws", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const { supabase, getInsertCallCount } = makeRefreshScenario({
			profileRows: [],
			throwProfileLookup: true,
		});

		try {
			await expect(
				insertMatchesRejectingBlockedPairs(supabase as never, [{ user_a_id: "user-a", user_b_id: "user-b" }], "[insert-test]"),
			).rejects.toThrow("matching eligibility could not be re-read");
			expect(getInsertCallCount()).toBe(1);
			expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("raw eligibility details");
		} finally {
			consoleErrorSpy.mockRestore();
		}
	});

	it("bounds a repeated 23514 to the single retry", async () => {
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		const { supabase, getInsertCallCount } = makeRefreshScenario({
			profileRows: [
				eligibilityProfile("user-a", "woman", ["man"]),
				eligibilityProfile("user-b", "man", ["woman"]),
			],
			retryError: { code: "23514", message: "raw retry constraint details" },
		});

		try {
			await expect(
				insertMatchesRejectingBlockedPairs(supabase as never, [{ user_a_id: "user-a", user_b_id: "user-b" }], "[insert-test]"),
			).rejects.toThrow("matches insert failed even after filtering blocked pairs");
			expect(getInsertCallCount()).toBe(2);
			expect(consoleErrorSpy).toHaveBeenCalledWith("[insert-test] matches insert retry after filtering blocked pairs failed");
			expect(consoleErrorSpy.mock.calls.flat().join(" ")).not.toContain("raw retry constraint details");
		} finally {
			consoleErrorSpy.mockRestore();
		}
	});

	it("returns a safe zero when every refreshed pair is invalid", async () => {
		const consoleWarnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
		const { supabase, getInsertCallCount } = makeRefreshScenario({
			profileRows: [
				eligibilityProfile("user-a", "woman", ["man"]),
				eligibilityProfile("user-b", "man", ["nonbinary"]),
			],
		});

		try {
			await expect(
				insertMatchesRejectingBlockedPairs(supabase as never, [{ user_a_id: "user-a", user_b_id: "user-b" }], "[insert-test]"),
			).resolves.toEqual({ inserted: [], keptIndices: [] });
			expect(getInsertCallCount()).toBe(1);
			expect(consoleWarnSpy.mock.calls.flat().join(" ")).not.toContain("user-a");
		} finally {
			consoleWarnSpy.mockRestore();
		}
	});
});

describe("judge constraint-race scope",()=>{
 it.each([false,true])("re-reads only fixed20 blocks and rejects outside rows (%s)",async outside=>{
  const {DEMO_20260930_PROFILE_IDS:ids}=await import("./synthetic-matching-cohort");const rows=[{user_a_id:ids[0],user_b_id:ids[1]},{user_a_id:ids[0],user_b_id:ids[2]}];
  const profileRows=ids.slice(0,3).map(id=>eligibilityProfile(id,"woman",["woman"]));
  const f=makeRefreshScenario({profileRows});const filters:Array<[string,string[]]>=[];const original=f.supabase.from;
  f.supabase.from=(table:string)=>{
   if(table!=="blocks")return original(table);
   const q={select:()=>q,in:(key:string,values:string[])=>{filters.push([key,values]);return q;},then:(resolve:(value:unknown)=>unknown)=>Promise.resolve({data:outside?[{blocker_id:ids[0],blocked_id:"outsider"}]:[{blocker_id:ids[0],blocked_id:ids[1]}],error:null}).then(resolve)};return q;
  };
  const call=insertMatchesRejectingBlockedPairs(f.supabase,rows,"[judge-race]",{judgeScope:{profileIds:ids,actorId:ids[0]},canWrite:()=>true});
  if(outside){await expect(call).rejects.toThrow("invalid judge block scope");expect(f.insertedRows).toHaveLength(1);}else{expect(await call).toMatchObject({keptIndices:[1]});expect(f.insertedRows[1]).toEqual([rows[1]]);}
  expect(filters).toEqual([["blocker_id",[...ids]],["blocked_id",[...ids]]]);
 });
 it("rejects arbitrary broadened scopes before any database read",async()=>{
  const db={from:vi.fn()};await expect(insertMatchesRejectingBlockedPairs(db as never,[],"[judge-race]",{judgeScope:{profileIds:["a","b"],actorId:"a"}})).rejects.toThrow("invalid judge insertion scope");expect(db.from).not.toHaveBeenCalled();
 });
});
