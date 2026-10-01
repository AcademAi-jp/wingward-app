import { describe, expect, it } from "vitest";
import {
	assertValidTimeZone,
	getBatchTimeZone,
	getHourInTimeZone,
	getTodayInTimeZone,
	getUtcMonthPeriod,
	nextClockTimeInTimeZone,
	toDateStringInTimeZone,
	toUserLocal,
	toVenueLocal,
} from "./date";

describe("assertValidTimeZone", () => {
	it("returns the timezone unchanged when valid", () => {
		expect(assertValidTimeZone("America/New_York")).toBe("America/New_York");
		expect(assertValidTimeZone("Asia/Tokyo")).toBe("Asia/Tokyo");
		expect(assertValidTimeZone("UTC")).toBe("UTC");
	});

	it.each([
		["Tokyo", "not an IANA name (missing region)"],
		["<script>", "injection-shaped garbage"],
		["", "empty string"],
		["../../etc", "path-traversal-shaped garbage"],
	])("throws for %j (%s) and does not fall back to a default", (bad) => {
		expect(() => assertValidTimeZone(bad)).toThrow();
	});
});

describe("toUserLocal / toVenueLocal", () => {
	// 2026-06-15T12:00:00Z — a fixed UTC instant, no DST ambiguity, used to
	// check the conversion for two different timezones.
	const utc = new Date("2026-06-15T12:00:00.000Z");

	it("converts correctly for America/New_York", () => {
		const local = toUserLocal(utc, { timezone: "America/New_York" });
		expect(local).toEqual({
			iso: utc.toISOString(),
			dateString: "2026-06-15", // EDT (UTC-4) in June: 12:00Z -> 08:00 local, same day
			timeZone: "America/New_York",
		});
	});

	it("converts correctly for Asia/Tokyo", () => {
		const local = toVenueLocal(utc, { timezone: "Asia/Tokyo" });
		expect(local).toEqual({
			iso: utc.toISOString(),
			dateString: "2026-06-15", // JST (UTC+9): 12:00Z -> 21:00 local, same day
			timeZone: "Asia/Tokyo",
		});
	});

	it("returns a struct, never a Date instance", () => {
		const local = toUserLocal(utc, { timezone: "Asia/Tokyo" });
		expect(local).not.toBeInstanceOf(Date);
		expect(typeof local.iso).toBe("string");
		expect(typeof local.dateString).toBe("string");
		expect(typeof local.timeZone).toBe("string");
	});

	it("crosses the calendar date boundary correctly across timezones", () => {
		// 2026-06-15T02:00:00Z: still 2026-06-14 in New York (22:00 EDT the
		// previous day), already 2026-06-15 in Tokyo (11:00 JST).
		const boundary = new Date("2026-06-15T02:00:00.000Z");
		expect(toUserLocal(boundary, { timezone: "America/New_York" }).dateString).toBe("2026-06-14");
		expect(toVenueLocal(boundary, { timezone: "Asia/Tokyo" }).dateString).toBe("2026-06-15");
	});

	it("propagates the RangeError for an invalid stored timezone rather than defaulting", () => {
		expect(() => toUserLocal(utc, { timezone: "Not/AZone" })).toThrow();
		expect(() => toVenueLocal(utc, { timezone: "" })).toThrow();
	});
});

describe("getBatchTimeZone", () => {
	it("defaults the daily matching key to Asia/Tokyo", () => {
		expect(getBatchTimeZone({})).toBe("Asia/Tokyo");
		expect(getBatchTimeZone({ BATCH_TIMEZONE: "" })).toBe("Asia/Tokyo");
	});

	it("accepts only the fixed Asia/Tokyo batch timezone", () => {
		expect(getBatchTimeZone({ BATCH_TIMEZONE: "Asia/Tokyo" })).toBe("Asia/Tokyo");
	});

	it.each(["Tokyo", "America/Los_Angeles", "America/New_York", "<script>"])(
		"rejects incompatible or invalid BATCH_TIMEZONE %j",
		(timeZone) => expect(() => getBatchTimeZone({ BATCH_TIMEZONE: timeZone })).toThrow(),
	);
});

describe("America/New_York DST boundaries: the date string neither skips nor repeats", () => {
	/**
	 * Walks hourly UTC instants across a window and returns the sequence of
	 * distinct local date strings encountered, in order. A correct,
	 * DST-aware conversion must produce a strictly increasing run of
	 * calendar dates with no date skipped and no date revisited once left.
	 */
	function distinctDateStringRun(startUtc: Date, hours: number, timeZone: string): string[] {
		const seen: string[] = [];
		for (let h = 0; h < hours; h++) {
			const instant = new Date(startUtc.getTime() + h * 60 * 60 * 1000);
			const dateString = toDateStringInTimeZone(instant, timeZone);
			if (seen[seen.length - 1] !== dateString) seen.push(dateString);
		}
		return seen;
	}

	it("spring-forward 2026-03-08 (clocks skip 02:00->03:00 EST->EDT)", () => {
		// Window: 2026-03-07T12:00Z .. 2026-03-09T12:00Z (48 hourly steps)
		const start = new Date("2026-03-07T12:00:00.000Z");
		const run = distinctDateStringRun(start, 48, "America/New_York");
		expect(run).toEqual(["2026-03-07", "2026-03-08", "2026-03-09"]);
	});

	it("fall-back 2026-11-01 (clocks repeat 01:00-02:00 EDT->EST)", () => {
		// Window: 2026-10-31T12:00Z .. 2026-11-02T12:00Z (48 hourly steps)
		const start = new Date("2026-10-31T12:00:00.000Z");
		const run = distinctDateStringRun(start, 48, "America/New_York");
		expect(run).toEqual(["2026-10-31", "2026-11-01", "2026-11-02"]);
	});

	it("the fall-back day is not double-counted despite the repeated local hour", () => {
		// The 01:00-02:00 local hour occurs twice in wall-clock terms on
		// 2026-11-01, but toDateStringInTimeZone must still report exactly
		// one calendar date across the whole window it spans.
		const start = new Date("2026-11-01T04:00:00.000Z"); // ~00:00 EDT
		const dateStrings = new Set<string>();
		for (let m = 0; m < 6 * 60; m += 10) {
			// 6 hours in 10-minute steps, covering the repeated hour
			dateStrings.add(toDateStringInTimeZone(new Date(start.getTime() + m * 60 * 1000), "America/New_York"));
		}
		expect([...dateStrings].sort()).toEqual(["2026-11-01"]);
	});
});

describe("getUtcMonthPeriod", () => {
	it("returns the first and last day of the UTC month containing the instant", () => {
		expect(getUtcMonthPeriod(new Date("2026-02-15T10:00:00.000Z"))).toEqual({
			periodStart: "2026-02-01",
			periodEnd: "2026-02-28",
		});
	});

	it("handles a leap-year February correctly", () => {
		expect(getUtcMonthPeriod(new Date("2028-02-01T00:00:00.000Z"))).toEqual({
			periodStart: "2028-02-01",
			periodEnd: "2028-02-29",
		});
	});

	it("handles December -> next January rollover (year boundary)", () => {
		expect(getUtcMonthPeriod(new Date("2026-12-31T23:59:59.000Z"))).toEqual({
			periodStart: "2026-12-01",
			periodEnd: "2026-12-31",
		});
	});

	it("is anchored to the UTC calendar date, not a local one: 23:xx UTC on the last day of the month stays in that month", () => {
		// This instant is already the next day in timezones ahead of UTC (e.g.
		// Asia/Tokyo, UTC+9), but the period must still be fixed to UTC.
		expect(getUtcMonthPeriod(new Date("2026-01-31T23:00:00.000Z")).periodStart).toBe("2026-01-01");
	});

	it("adjacent months produce different period_start values (drives quota rollover)", () => {
		const jan = getUtcMonthPeriod(new Date("2026-01-15T00:00:00.000Z"));
		const feb = getUtcMonthPeriod(new Date("2026-02-15T00:00:00.000Z"));
		expect(jan.periodStart).not.toBe(feb.periodStart);
	});
});

describe("nextClockTimeInTimeZone", () => {
	it("Asia/Tokyo: 23:00 local (14:00Z) -> next 08:00 JST the following day", () => {
		// 2026-06-15T14:00:00Z is 2026-06-15 23:00 JST (UTC+9, no DST).
		const from = new Date("2026-06-15T14:00:00.000Z");
		const result = nextClockTimeInTimeZone(from, "Asia/Tokyo", 8, 0);
		// Next 08:00 JST is 2026-06-16 08:00 JST == 2026-06-15 23:00Z.
		expect(result.toISOString()).toBe("2026-06-15T23:00:00.000Z");
	});

	it("America/Los_Angeles: 23:00 local (summer, PDT UTC-7) -> next 08:00 local the following day", () => {
		// 2026-06-16T06:00:00Z is 2026-06-15 23:00 PDT (UTC-7).
		const from = new Date("2026-06-16T06:00:00.000Z");
		const result = nextClockTimeInTimeZone(from, "America/Los_Angeles", 8, 0);
		// Next 08:00 PDT is 2026-06-16 08:00 PDT == 2026-06-16 15:00Z.
		expect(result.toISOString()).toBe("2026-06-16T15:00:00.000Z");
	});

	it("America/Los_Angeles: 23:00 local (winter, PST UTC-8) -> next 08:00 local the following day", () => {
		// 2026-01-16T07:00:00Z is 2026-01-15 23:00 PST (UTC-8).
		const from = new Date("2026-01-16T07:00:00.000Z");
		const result = nextClockTimeInTimeZone(from, "America/Los_Angeles", 8, 0);
		// Next 08:00 PST is 2026-01-16 08:00 PST == 2026-01-16 16:00Z.
		expect(result.toISOString()).toBe("2026-01-16T16:00:00.000Z");
	});

	it("resolves to later today when the target clock time hasn't passed yet", () => {
		// 2026-06-15T20:00:00Z is 2026-06-16 05:00 JST — before 08:00 JST today.
		const from = new Date("2026-06-15T20:00:00.000Z");
		const result = nextClockTimeInTimeZone(from, "Asia/Tokyo", 8, 0);
		expect(result.toISOString()).toBe("2026-06-15T23:00:00.000Z"); // 2026-06-16 08:00 JST
	});

	it("throws for an invalid IANA timezone rather than defaulting", () => {
		expect(() => nextClockTimeInTimeZone(new Date(), "Tokyo", 8)).toThrow();
	});

	describe("DST transition dates (America/Los_Angeles, real 2026 transitions)", () => {
		// Confirmed by direct inspection (Intl.DateTimeFormat) rather than
		// assumed: 2026 spring-forward is 2026-03-08T10:00:00Z (02:00->03:00
		// local), 2026 fall-back is 2026-11-01T09:00:00Z (02:00->01:00 local).
		// Orchestrator review round 3, finding #1: the old implementation
		// resolved the DST offset at the naive "target numbers as UTC" instant
		// instead of near the actual target, which put it on the wrong side of
		// exactly these boundaries.

		it("spring-forward: a hold created 23:00 PST the night before resolves to 08:00 PDT, not 09:00", () => {
			// 2026-03-08T07:00:00Z = 2026-03-07 23:00 PST (still winter offset).
			const from = new Date("2026-03-08T07:00:00.000Z");
			const result = nextClockTimeInTimeZone(from, "America/Los_Angeles", 8, 0);
			// The old (buggy) implementation produced 2026-03-08T16:00:00.000Z
			// here (09:00 PDT) — an hour late.
			expect(result.toISOString()).toBe("2026-03-08T15:00:00.000Z");

			// Confirm this instant actually formats to 08:00 in the zone —
			// the assertion above isn't just "a plausible-looking timestamp".
			const formatted = new Intl.DateTimeFormat("en-US", {
				timeZone: "America/Los_Angeles",
				hourCycle: "h23",
				hour: "2-digit",
				minute: "2-digit",
			}).format(result);
			expect(formatted).toBe("08:00");
		});

		it("fall-back: a hold created 23:00 PDT the night before resolves to 08:00 PST, not 07:00", () => {
			// 2026-11-01T06:00:00Z = 2026-10-31 23:00 PDT (still summer offset).
			const from = new Date("2026-11-01T06:00:00.000Z");
			const result = nextClockTimeInTimeZone(from, "America/Los_Angeles", 8, 0);
			// The old (buggy) implementation produced 2026-11-01T15:00:00.000Z
			// here (07:00 PST) — still inside quiet hours, an A-1 violation.
			expect(result.toISOString()).toBe("2026-11-01T16:00:00.000Z");

			const formatted = new Intl.DateTimeFormat("en-US", {
				timeZone: "America/Los_Angeles",
				hourCycle: "h23",
				hour: "2-digit",
				minute: "2-digit",
			}).format(result);
			expect(formatted).toBe("08:00");
		});

		it("control: Asia/Tokyo (no DST) is unaffected by the fix across the same calendar dates", () => {
			const springFrom = new Date("2026-03-08T07:00:00.000Z"); // 2026-03-08 16:00 JST
			const springResult = nextClockTimeInTimeZone(springFrom, "Asia/Tokyo", 8, 0);
			expect(springResult.toISOString()).toBe("2026-03-08T23:00:00.000Z"); // 2026-03-09 08:00 JST

			const fallFrom = new Date("2026-11-01T06:00:00.000Z"); // 2026-11-01 15:00 JST
			const fallResult = nextClockTimeInTimeZone(fallFrom, "Asia/Tokyo", 8, 0);
			expect(fallResult.toISOString()).toBe("2026-11-01T23:00:00.000Z"); // 2026-11-02 08:00 JST
		});
	});
});

describe("getHourInTimeZone", () => {
	it("Asia/Tokyo: 14:00Z reads as 23 local", () => {
		expect(getHourInTimeZone(new Date("2026-06-15T14:00:00.000Z"), "Asia/Tokyo")).toBe(23);
	});

	it("America/Los_Angeles: 06:00Z (summer PDT) reads as 23 local the previous day", () => {
		expect(getHourInTimeZone(new Date("2026-06-16T06:00:00.000Z"), "America/Los_Angeles")).toBe(23);
	});

	it("America/Los_Angeles: 16:00Z (winter PST) reads as 8 local", () => {
		expect(getHourInTimeZone(new Date("2026-01-16T16:00:00.000Z"), "America/Los_Angeles")).toBe(8);
	});

	it("throws for an invalid IANA timezone", () => {
		expect(() => getHourInTimeZone(new Date(), "Tokyo")).toThrow();
	});
});

describe("getTodayInTimeZone / toDateStringInTimeZone signatures are unchanged", () => {
	it("getTodayInTimeZone still takes a single timeZone string and returns a date string", () => {
		const today = getTodayInTimeZone("UTC");
		expect(today).toMatch(/^\d{4}-\d{2}-\d{2}$/);
	});

	it("toDateStringInTimeZone still takes (Date, timeZone)", () => {
		expect(toDateStringInTimeZone(new Date("2026-01-01T00:00:00.000Z"), "UTC")).toBe("2026-01-01");
	});
});
