import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DAILY_BATCH_TIME_ZONE, getBatchTimeZone, getTodayInTimeZone, toDateStringInTimeZone } from "./date";

const API_SRC = join(__dirname, "..");
function read(relPath: string): string {
	return readFileSync(join(API_SRC, relPath), "utf8");
}

describe("daily batch date is consistently fixed to Tokyo", () => {
	it("defaults to Asia/Tokyo and rejects an incompatible override", () => {
		expect(DAILY_BATCH_TIME_ZONE).toBe("Asia/Tokyo");
		expect(getBatchTimeZone({})).toBe("Asia/Tokyo");
		expect(getBatchTimeZone({ BATCH_TIMEZONE: "Asia/Tokyo" })).toBe("Asia/Tokyo");
		expect(() => getBatchTimeZone({ BATCH_TIMEZONE: "America/Los_Angeles" })).toThrow(/fixed to Asia\/Tokyo/);
	});

	it("derives the 09:00 JST batch date from its UTC scheduledTime", () => {
		const scheduledTime = new Date("2026-06-15T00:00:00.000Z");
		expect(toDateStringInTimeZone(scheduledTime, getBatchTimeZone({}))).toBe("2026-06-15");
		expect(getTodayInTimeZone(getBatchTimeZone({ BATCH_TIMEZONE: "Asia/Tokyo" }))).toMatch(/^\d{4}-\d{2}-\d{2}$/);
	});
});

describe("source wiring protects the fixed date and shared reads", () => {
	it("matching routes resolve the daily result date from the shared timezone helper", () => {
		const src = read("routes/matching.ts");
		expect(src).not.toMatch(/TOKYO_TIMEZONE/);
		expect(src).toMatch(/getTodayInTimeZone\(getBatchTimeZone\(c\.env\)\)/);
	});

	it("internal status and retry resolve the same JST date", () => {
		const src = read("routes/internal.ts");
		expect(src).not.toMatch(/TOKYO_TIMEZONE/);
		expect(src.match(/getTodayInTimeZone\(getBatchTimeZone\(c\.env\)\)/g) ?? []).toHaveLength(1);
		expect(src).toMatch(/runDailyBatch\(supabase, c\.env\.MISTRAL_API_KEY \?\? "", getBatchTimeZone\(c\.env\), body\.data\.batch_date/);
		expect(src).toMatch(/const date = supplied \?\? getTodayInTimeZone\(getBatchTimeZone\(c\.env\)\)/);
	});

	it("scheduled execution uses the event time and passes the fixed batch date", () => {
		const src = read("services/daily-batch.ts");
		expect(src).toMatch(/export async function runDailyBatch\([\s\S]*?_mistralApiKey: string \| undefined,[\s\S]*?batchTimeZone: string,/);
		expect(src).toMatch(/batchTimeZone !== DAILY_BATCH_TIME_ZONE/);
		expect(src).toMatch(/toDateStringInTimeZone\(new Date\(event\.scheduledTime\), batchTimeZone\)/);
		expect(src).toMatch(/runDailyBatch\(supabase, env\.MISTRAL_API_KEY, batchTimeZone, scheduledDate/);
	});

	it("does not leave any imports of the deleted legacy Tokyo constant", () => {
		expect(read("lib/date.ts")).not.toMatch(/TOKYO_TIMEZONE/);
	});
});
