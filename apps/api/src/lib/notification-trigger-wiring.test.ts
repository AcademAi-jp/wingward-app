import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Pins WHERE the notification triggers are called from.
 *
 * The unit tests in services/notification-triggers.test.ts prove the trigger
 * functions behave correctly once called. Nothing there proves they are
 * called at all — and that was the exact state of the whole send pipeline
 * between PR #27 and this change: fully built, fully tested, and with no
 * production caller, so none of it ran. A trigger that quietly stops being
 * invoked looks identical to one that was never wired.
 *
 * Neither call site can be covered by a behavioural test cheaply: the DO's is
 * inside `alarm()` behind a full conversation run, and the route's goes
 * through `notifyInBackground`, which the caller never awaits. So the wiring
 * is asserted against the source, in the pattern of
 * lazy-fox-conversation-wiring.test.ts.
 */

const API_SRC = join(__dirname, "..");

function read(relPath: string): string {
	return readFileSync(join(API_SRC, relPath), "utf8");
}

function sourceFiles(dir: string): string[] {
	const out: string[] = [];
	for (const entry of readdirSync(dir)) {
		const full = join(dir, entry);
		if (statSync(full).isDirectory()) out.push(...sourceFiles(full));
		else if ((entry.endsWith(".ts") || entry.endsWith(".tsx")) && !entry.includes(".test.")) out.push(full);
	}
	return out;
}

describe("the notification send pipeline has production callers", () => {
	it("N-01 is triggered from the Durable Object's alarm", () => {
		const src = read("durable-objects/fox-conversation-do.ts");
		expect(src).toContain("notifyFoxConversationCompleted");
	});

	it("N-01 is NOT triggered from the failure path — no scenario covers a conversation that failed", () => {
		const src = read("durable-objects/fox-conversation-do.ts");
		const failConversation = src.slice(src.indexOf("private async failConversation"));
		expect(failConversation).not.toContain("notifyFoxConversationCompleted");
	});

	it("N-03 is triggered from the chat-request creation route", () => {
		const src = read("routes/chat-requests.ts");
		expect(src).toContain("notifyChatRequestCreated");
	});

	it("N-03 goes through notifyInBackground rather than blocking the response", () => {
		const src = read("routes/chat-requests.ts");
		expect(src).toMatch(/notifyInBackground\(\s*c,[\s\S]*?notifyChatRequestCreated/);
	});

	it("meetup mutual intent dispatches N-04/N-07 through notifyInBackground", () => {
		const src = read("routes/meetups.ts");
		expect(src).toContain("notifyMeetupMutualIntent");
		expect(src).toMatch(/notifyInBackground\(\s*c,[\s\S]*?notifyMeetupMutualIntent/);
	});

	it("arrangement and proposal-response contexts dispatch N-05/N-06/N-14 in the background", () => {
		const routeSource = read("routes/meetups.ts");
		expect(routeSource).toContain("notifyMeetupArrangement");
		expect(routeSource).toContain("queueArrangementNotifications");
		expect(routeSource).toMatch(/notifyInBackground\(\s*c,[\s\S]*?notifyMeetupArrangement/);

		const triggerSource = read("services/notification-triggers.ts");
		expect(triggerSource).toContain('z.enum(["N-05", "N-06", "N-14"])');
		expect(triggerSource).toContain('scenarioId: context.scenarioId');
	});

	it("meetup trigger owns the verifying-state safety boundary", () => {
		const src = read("services/notification-triggers.ts");
		expect(src).toContain('meetup.status !== "verifying"');
		expect(src).toContain('scenarioId: "N-04"');
		expect(src).toContain('scenarioId: "N-07"');
	});

	it("sendNotification is called only by scenario triggers or the fenced daily outbox", () => {
		// Scenario triggers and the durable outbox own recipient checks and
		// failure containment. Routes must not bypass those boundaries.
		const callers = sourceFiles(API_SRC)
			.filter((f) => /\bsendNotification\(/.test(readFileSync(f, "utf8")))
			.map((f) => f.slice(API_SRC.length + 1))
			.sort();

		expect(callers).toEqual(["services/daily-matching-notification-outbox.ts", "services/notification-triggers.ts", "services/notifications.ts"]);
	});
});
