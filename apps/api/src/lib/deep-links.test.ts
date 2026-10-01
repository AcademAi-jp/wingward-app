import { describe, expect, it } from "vitest";
import { isAllowedDeepLink } from "./deep-links";

const UUID = "11111111-1111-1111-1111-111111111111";

describe("isAllowedDeepLink", () => {
	it.each([
		`wingward://match/${UUID}/fox-result`,
		`wingward://chat-requests/${UUID}`,
		`wingward://meetup/${UUID}`,
		`wingward://meetup/${UUID}/verify`,
		`wingward://meetup/${UUID}/feedback`,
		`wingward://meetup/${UUID}/result`,
		`wingward://match/${UUID}/fox-learned`,
		"wingward://availability",
	])("allows the known in-app screen template %s", (link) => {
		expect(isAllowedDeepLink(link)).toBe(true);
	});

	it.each([
		["https://evil.example.com/phish", "an arbitrary external https URL"],
		["http://wingward://match/x", "a scheme-confused string"],
		[`wingward://match/${UUID}`, "missing the required screen suffix"],
		[`wingward://match/not-a-uuid/fox-result`, "a non-UUID path parameter"],
		[`wingward://match/${UUID}/fox-result?redirect=https://evil.example.com`, "a query string appended to an otherwise-valid link"],
		[`wingward://match/${UUID}/fox-result/../../../etc/passwd`, "path traversal appended to an otherwise-valid link"],
		["", "empty string"],
		["javascript:alert(1)", "a javascript: URI"],
		[`wingward://availability/extra`, "extra path segments on a fixed screen"],
		[`wingward://match/${"-".repeat(36)}/fox-result`, "36 hyphens (matches the old too-loose [0-9a-fA-F-]{36} pattern but is not a UUID) (P3)"],
		[`wingward://match/${"a".repeat(36)}/fox-result`, "36 hex chars with no hyphens at all (P3)"],
		[`wingward://match/${UUID.slice(0, -1)}g/fox-result`, "a UUID-shaped string with a non-hex character (P3)"],
	])("rejects %s (%s)", (link) => {
		expect(isAllowedDeepLink(link)).toBe(false);
	});

	it("rejects non-string input defensively", () => {
		// Deliberately passing non-string values (e.g. from an untyped JSON
		// body) to check the runtime guard, not just the type signature.
		expect(isAllowedDeepLink(null as unknown as string)).toBe(false);
		expect(isAllowedDeepLink(undefined as unknown as string)).toBe(false);
	});
});
