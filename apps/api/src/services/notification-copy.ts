/**
 * Neutral, PII-free push copy per notification_scenarios.scenario_id.
 *
 * step-04-notifications.md §5 / §2: lock-screen text must not reveal the
 * app's purpose or any other person's name, and the payload must carry no
 * PII (names, message bodies, meetup locations). This is a fixed
 * server-side constant, never built from user input or from another user's
 * data, so it can't leak anything about the match/meetup it's attached to.
 *
 * Every notification_scenarios row (N-01..N-13, migration
 * 20260812100400_notifications.sql, plus the N-14 meetup migration) must have an entry here — the send
 * function looks this up by scenario_id and has nothing else to fall back
 * to for the visible notification text.
 */
export interface NotificationCopy {
	heading: string;
	content: string;
}

export const NOTIFICATION_COPY: Record<string, NotificationCopy> = {
	"N-01": { heading: "Wingward", content: "There's something new for you to see." },
	"N-02": { heading: "Wingward", content: "There's something new for you to see." },
	"N-03": { heading: "Wingward", content: "You have a new request waiting." },
	"N-04": { heading: "Wingward", content: "There's something new for you to see." },
	"N-05": { heading: "Wingward", content: "A few options are ready for you to review." },
	"N-06": { heading: "Wingward", content: "Something has been confirmed for you." },
	"N-07": { heading: "Wingward", content: "A quick step is needed from you." },
	"N-08": { heading: "Wingward", content: "You have something coming up tomorrow." },
	"N-09": { heading: "Wingward", content: "You have something coming up soon." },
	"N-10": { heading: "Wingward", content: "We'd like to hear how it went." },
	"N-11": { heading: "Wingward", content: "There's something new for you to see." },
	"N-12": { heading: "Wingward", content: "There's something new for you to see." },
	"N-13": { heading: "Wingward", content: "Something of yours is about to expire." },
	"N-14": { heading: "Wingward", content: "Something needs your attention." },
};

export function getNotificationCopy(scenarioId: string): NotificationCopy {
	const copy = NOTIFICATION_COPY[scenarioId];
	if (!copy) {
		throw new Error(`No notification copy defined for scenario_id ${scenarioId}`);
	}
	return copy;
}
