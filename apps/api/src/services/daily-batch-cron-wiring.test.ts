import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DAILY_BATCH_CRON, DEFERRED_SEND_CRON } from "./daily-batch";

/**
 * Two separate guards on `[triggers]` in wrangler.toml.
 *
 * 1. The cron expressions written there must equal the constants
 *    `handleScheduled` routes on. Cloudflare passes `scheduled` the raw
 *    expression the Worker was configured with, and the handler compares by
 *    string equality, so a single space or a changed step field produces the
 *    same silent outcome in production — the trigger fires, no job runs, and
 *    the only evidence is a log line. No other test in this suite can catch
 *    that, because they all call `handleScheduled` with a literal they chose
 *    themselves.
 *
 * 2. The `crons` line must be ACTIVE, and must declare exactly those two
 *    expressions. This half was inverted on 2026-08-20. While the account was
 *    on Workers Free, the test asserted that NO active line existed: a plain
 *    `wrangler deploy` would otherwise install schedules whose daily batch
 *    cannot meet the 10 ms CPU ceiling, and Codex's point on PR #29 was that a
 *    warning comment does not gate Wrangler while a test does. The account
 *    moved to Workers Paid, so the gate came down — deliberately, by editing
 *    this test, which is exactly the step it existed to force.
 *
 *    It now asserts the opposite, because leaving the schedules off is not
 *    neutral either: `sendNotification` returns a successful `deferred`
 *    outcome for anything created during quiet hours and relies entirely on
 *    `sendDeferredNotifications`, which only `handleScheduled` calls. No
 *    schedule means every quiet-hours notification sits unsent indefinitely
 *    (Codex P1, PR #31 review round 3).
 */

const WRANGLER_TOML = join(__dirname, "..", "..", "wrangler.toml");

function triggersSection(): string {
	const toml = readFileSync(WRANGLER_TOML, "utf8");
	const start = toml.indexOf("[triggers]");
	if (start === -1) return "";
	const rest = toml.slice(start + "[triggers]".length);
	const nextTable = rest.search(/^\s*\[/m);
	return nextTable === -1 ? rest : rest.slice(0, nextTable);
}

/**
 * Every cron expression written in the `[triggers]` section, commented or not.
 * Checking the commented form matters: it is the form the file is meant to be
 * in, so leaving it unchecked would mean the documented schedule could drift
 * from the code for as long as the gate stays closed, and only break at the
 * moment of the upgrade — the worst possible time to discover it.
 */
function documentedCrons(): string[] {
	return [...new Set([...triggersSection().matchAll(/"([\d*/,\s-]+)"/g)].map((m) => m[1]))];
}

/** A `crons = [...]` assignment Wrangler would actually act on. */
function activeCronsLine(): string | null {
	const uncommented = triggersSection()
		.split("\n")
		.filter((line) => !line.trimStart().startsWith("#"))
		.join("\n");
	const match = uncommented.match(/^\s*crons\s*=.*/m);
	return match ? match[0].trim() : null;
}

describe("4-C: wrangler.toml's cron triggers and handleScheduled's routing constants agree", () => {
	it("documents exactly the two cron expressions the handler routes on", () => {
		expect(documentedCrons().sort()).toEqual([DAILY_BATCH_CRON, DEFERRED_SEND_CRON].sort());
	});

	it("the two schedules are distinct — sharing one expression would collapse the split that 4-C exists to create", () => {
		expect(DAILY_BATCH_CRON).not.toBe(DEFERRED_SEND_CRON);
	});

	it("the daily batch runs once a day and the deferred executor much more often", () => {
		// A daily expression pins minute and hour; a stepped minute field does not.
		expect(DAILY_BATCH_CRON).toMatch(/^\d+ \d+ \* \* \*$/);
		expect(DEFERRED_SEND_CRON).toMatch(/^\*\/\d+ /);
	});

	it("stays within the Workers Free ceiling of 5 cron triggers per account", () => {
		// Paid allows 250. This is the limit that binds today; if a third
		// schedule is ever added, recount rather than assuming headroom.
		expect(documentedCrons().length).toBeLessThanOrEqual(5);
	});
});

describe("4-C: the cron triggers are live, so deferred notifications actually get delivered", () => {
	it("has an active crons line — without one, every quiet-hours notification sits unsent forever", () => {
		expect(activeCronsLine()).not.toBeNull();
	});

	it("the active line declares exactly the two expressions the handler routes on, not just any two", () => {
		const active = activeCronsLine() ?? "";
		const activeCrons = [...active.matchAll(/"([^"]*)"/g)].map((m) => m[1]).sort();
		expect(activeCrons).toEqual([DAILY_BATCH_CRON, DEFERRED_SEND_CRON].sort());
	});
});

/**
 * The registered-account iOS demo uses this Worker's existing workers.dev URL.
 * Explicit routing keeps the endpoint available after a Wrangler deployment.
 * The temporary recording gate controls app access; changing the route or
 * deploying the Worker still requires a separate reviewed cloud approval.
 */
describe("the deploy preserves its workers.dev URL", () => {
  const uncommented = readFileSync(WRANGLER_TOML, "utf8")
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("#"))
    .join("\n");

  it("uses no TOML escape sequence that would evade the raw token checks", () => {
    expect(uncommented).not.toMatch(/\\/);
  });

  it("declares workers_dev = true explicitly at the top level", () => {
    const firstTableHeader = uncommented.search(/^\s*\[/m);
    const keyLine = uncommented.search(/^\s*workers_dev\s*=\s*true\s*$/m);
    expect(keyLine).toBeGreaterThanOrEqual(0);
    expect(firstTableHeader).toBeGreaterThanOrEqual(0);
    expect(keyLine).toBeLessThan(firstTableHeader);
  });

  it("does not contain a conflicting workers_dev=false setting", () => {
    expect(uncommented).not.toMatch(/^\s*workers_dev\s*=\s*false/m);
    expect(uncommented.match(/\bworkers_dev\b/g) ?? []).toHaveLength(1);
  });

  it("declares no alternate route or environment that changes this target", () => {
    expect(uncommented).not.toMatch(/\broutes?\b/);
    expect(uncommented).not.toMatch(/\benv\b/);
  });
});
