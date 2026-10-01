import { describe, expect, it } from "vitest";
import { isAtLeast18, parseBirthDate } from "./age-verification";

describe("parseBirthDate", () => {
	it("accepts the inclusive lower bound and UTC today", () => {
		expect(parseBirthDate("1900-01-01", "2026-08-24")).toBe("1900-01-01");
		expect(parseBirthDate("2026-08-24", "2026-08-24")).toBe("2026-08-24");
	});

	it.each(["1899-12-31", "2026-08-25", "2001-02-29", "2000-04-31", "2000-1-01", "20000101"])(
		"rejects %s",
		(value) => {
			expect(parseBirthDate(value, "2026-08-24")).toBeNull();
		},
	);
});

describe("isAtLeast18", () => {
	it("allows a user on their 18th birthday and later", () => {
		expect(isAtLeast18("2008-08-24", "2026-08-24")).toBe(true);
		expect(isAtLeast18("2008-08-24", "2026-08-25")).toBe(true);
		expect(isAtLeast18("2008-08-24", "2026-08-23")).toBe(false);
	});

	it("uses March 1 for a February 29 birthday in a non-leap anniversary year", () => {
		expect(isAtLeast18("2008-02-29", "2026-02-28")).toBe(false);
		expect(isAtLeast18("2008-02-29", "2026-03-01")).toBe(true);
	});

});
