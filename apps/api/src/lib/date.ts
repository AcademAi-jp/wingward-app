export function toDateStringInTimeZone(
	date: Date,
	timeZone: string,
): string {
	const parts = new Intl.DateTimeFormat("en-US", {
		timeZone,
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
	}).formatToParts(date);

	const year = parts.find((part) => part.type === "year")?.value;
	const month = parts.find((part) => part.type === "month")?.value;
	const day = parts.find((part) => part.type === "day")?.value;

	if (!year || !month || !day) {
		throw new Error(`Failed to format date in timezone: ${timeZone}`);
	}

	return `${year}-${month}-${day}`;
}

export function getTodayInTimeZone(timeZone: string): string {
	return toDateStringInTimeZone(new Date(), timeZone);
}

/**
 * The local hour (0-23) `date` reads as in `timeZone`. Used for quiet-hours
 * checks (22:00-08:00 local, step-04-notifications.md §3-1) — kept here
 * rather than inlined at the call site per the "lib/date.ts is the only
 * place that converts" rule (AGENTS.md security posture #2).
 */
export function getHourInTimeZone(date: Date, timeZone: string): number {
	const parts = new Intl.DateTimeFormat("en-US", {
		timeZone,
		hourCycle: "h23",
		hour: "2-digit",
	}).formatToParts(date);
	const hour = parts.find((part) => part.type === "hour")?.value;
	if (hour === undefined) {
		throw new Error(`Failed to read hour in timezone: ${timeZone}`);
	}
	return hour === "24" ? 0 : Number(hour);
}

/**
 * Validates that `tz` is a real IANA timezone name Intl can resolve.
 *
 * There is deliberately no fallback: silently computing a local time in the
 * wrong timezone is worse than failing loudly, so an invalid `tz` throws
 * (via the underlying `RangeError`) instead of being swallowed.
 */
export function assertValidTimeZone(tz: string): string {
	// Intl.DateTimeFormat throws a RangeError for an unrecognized timeZone;
	// let it propagate rather than catching it here.
	new Intl.DateTimeFormat(undefined, { timeZone: tz });
	return tz;
}

/**
 * A point in time expressed as a UTC instant plus what that instant looks
 * like in a given IANA timezone.
 *
 * Deliberately not a `Date`: a JS `Date` is always a UTC instant underneath,
 * so a "local Date" would misrepresent the timezone it was computed for and
 * invite bugs where that timezone gets silently dropped on the next hop.
 */
export interface LocalTime {
	/** ISO 8601 instant (UTC), e.g. "2026-08-12T09:30:00.000Z" */
	iso: string;
	/** Calendar date in `timeZone`, e.g. "2026-08-12" */
	dateString: string;
	/** The IANA timezone this was computed for */
	timeZone: string;
}

function toLocal(utc: Date, timeZone: string): LocalTime {
	assertValidTimeZone(timeZone);
	return {
		iso: utc.toISOString(),
		dateString: toDateStringInTimeZone(utc, timeZone),
		timeZone,
	};
}

export interface UserWithTimeZone {
	timezone: string;
}

export interface VenueWithTimeZone {
	timezone: string;
}

/** Converts a UTC instant to how it reads in `user`'s stored timezone. */
export function toUserLocal(utc: Date, user: UserWithTimeZone): LocalTime {
	return toLocal(utc, user.timezone);
}

/** Converts a UTC instant to how it reads in `venue`'s stored timezone. */
export function toVenueLocal(utc: Date, venue: VenueWithTimeZone): LocalTime {
	return toLocal(utc, venue.timezone);
}

/** Env shape accepted by {@link getBatchTimeZone}; kept minimal so callers
 * (Hono `c.env`, the Cloudflare `scheduled` handler's `env`, Node's
 * `process.env`-derived bindings) can all satisfy it without a shared type. */
export interface BatchTimeZoneEnv {
	BATCH_TIMEZONE?: string;
}

export const DAILY_BATCH_TIME_ZONE = "Asia/Tokyo" as const;
const DEFAULT_BATCH_TIMEZONE = DAILY_BATCH_TIME_ZONE;

/**
 * Resolves the timezone the daily batch treats as authoritative for "today".
 *
 * The daily batch date is fixed to Tokyo. `env.BATCH_TIMEZONE` may be omitted
 * or explicitly name Tokyo; any other or invalid value throws rather than
 * silently shifting the matching cohort to another calendar day.
 */
export function getBatchTimeZone(env: BatchTimeZoneEnv): string {
	if (env.BATCH_TIMEZONE) {
		const configured = assertValidTimeZone(env.BATCH_TIMEZONE);
		if (configured !== DAILY_BATCH_TIME_ZONE) {
			throw new Error(`Daily matching timezone is fixed to ${DAILY_BATCH_TIME_ZONE}`);
		}
	}
	return DEFAULT_BATCH_TIMEZONE;
}

/**
 * The calendar-month period (UTC) a quota counter belongs to, as `date`
 * strings (`YYYY-MM-DD`) matching `usage_counters.period_start` /
 * `period_end`.
 *
 * Deliberately UTC, not a user's or the batch's timezone: quota periods are
 * a billing concept, not a "what day is it for this person" concept, and
 * fixing them to UTC means every caller (route, cron, retry) agrees on the
 * same period without threading a timezone through the quota system.
 */
/**
 * The offset (ms) such that `instant.getTime() + offset` equals the UTC
 * timestamp you'd get by reading `instant`'s wall-clock time in `timeZone`
 * and treating those same numbers as if they were already UTC.
 *
 * Internal helper for {@link nextClockTimeInTimeZone}'s reverse conversion
 * (wall-clock-in-a-timezone -> UTC instant), which none of the existing
 * exports here provide — every other function in this file goes UTC -> local
 * string, not local wall-clock -> UTC instant. Kept in this file (not a new
 * module) per the "lib/date.ts is the only place that converts" rule
 * (AGENTS.md security posture #2).
 */
function tzOffsetMs(instant: Date, timeZone: string): number {
	const parts = new Intl.DateTimeFormat("en-US", {
		timeZone,
		hourCycle: "h23",
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
		second: "2-digit",
	}).formatToParts(instant);
	const map: Record<string, string> = {};
	for (const part of parts) map[part.type] = part.value;
	const asUtc = Date.UTC(
		Number(map.year),
		Number(map.month) - 1,
		Number(map.day),
		Number(map.hour === "24" ? "0" : map.hour),
		Number(map.minute),
		Number(map.second),
	);
	return asUtc - instant.getTime();
}

/**
 * Finds the UTC instant whose wall-clock reading in `timeZone` is
 * `year-month-day hour:minute:00`, resolving the DST offset by fixed-point
 * iteration instead of a single naive lookup.
 *
 * Orchestrator review round 3, finding #1 (P1, breaks A-1): the previous
 * version computed the offset once, AT the naive "target numbers treated
 * as UTC" instant, not at the actual target instant — which is wrong
 * whenever those two fall on opposite sides of a DST transition. Confirmed
 * by hand for America/Los_Angeles: targeting 08:00 local the day after the
 * spring-forward transition resolved to 09:00 PDT (an hour late, because
 * the naive instant was still on the PST side of the boundary), and
 * targeting 08:00 the day after fall-back resolved to 07:00 PST (still
 * inside quiet hours, same direction of error). This function's own doc
 * comment previously claimed the bug was confined to "the rare hour a DST
 * transition itself skips or repeats" — that claim was wrong; the offset
 * resolution itself was wrong on any date near a transition, not just the
 * transition hour. See lib/date.test.ts's "nextClockTimeInTimeZone"
 * describe block ("DST transition dates" tests) for coverage on real 2026
 * US transition dates in both directions, with Asia/Tokyo (no DST) as a
 * control.
 *
 * The fix: treat the naive value only as a first guess, then repeatedly
 * re-resolve the offset at the current guess and recompute — this
 * converges because a timezone's UTC offset only takes a small, fixed set
 * of values (there is no oscillation once the guess lands on the correct
 * side of the transition). See {@link resolveZonedWallClockToUtc} for the
 * loop and its documented behavior when the requested wall-clock time
 * doesn't exist (a spring-forward gap).
 */
function resolveZonedWallClockToUtc(year: number, month: number, day: number, hour: number, minute: number, timeZone: string): Date {
	const targetAsUtc = Date.UTC(year, month - 1, day, hour, minute, 0);
	let guess = targetAsUtc;
	// A timezone's UTC offset changes at most a handful of times a year and
	// each change is a single small step, so this converges in 2-3
	// iterations for every real IANA zone; the cap just bounds worst case.
	const MAX_ITERATIONS = 4;
	for (let i = 0; i < MAX_ITERATIONS; i++) {
		const offset = tzOffsetMs(new Date(guess), timeZone);
		const next = targetAsUtc - offset;
		if (next === guess) break;
		guess = next;
	}
	// If the requested wall-clock time falls inside a spring-forward gap (it
	// never actually occurs on the clock), the loop above is not guaranteed
	// to reach a fixed point and this returns its last computed estimate
	// rather than looping forever or throwing. Every caller in this
	// codebase requests a fixed clock time (08:00, quiet-hours end), and US
	// (and most) DST transitions happen in the small hours (typically
	// 00:00-03:00 local), so this fallback is not expected to be exercised
	// in practice — documented here rather than silently relied on.
	return new Date(guess);
}

/**
 * The next UTC instant at or after `from` whose wall-clock reading in
 * `timeZone` is `hour:minute:00`. Used to compute quiet-hours holds
 * (e.g. "hold until the next 08:00 in the user's timezone").
 *
 * If `from` already reads at or after `hour:minute` in `timeZone`, this
 * rolls forward to the next calendar day; otherwise it resolves to later
 * today. The day-roll anchors on a noon-UTC instant for the current local
 * calendar date purely to get a stable Y/M/D to roll forward by one day
 * without landing on the wrong side of midnight-local — the actual
 * DST-aware resolution of that Y/M/D + hour:minute happens in
 * {@link resolveZonedWallClockToUtc} below, not here.
 */
export function nextClockTimeInTimeZone(from: Date, timeZone: string, hour: number, minute = 0): Date {
	assertValidTimeZone(timeZone);
	const parts = new Intl.DateTimeFormat("en-US", {
		timeZone,
		hourCycle: "h23",
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	}).formatToParts(from);
	const map: Record<string, string> = {};
	for (const part of parts) map[part.type] = part.value;
	let year = Number(map.year);
	let month = Number(map.month);
	let day = Number(map.day);
	const curHour = Number(map.hour === "24" ? "0" : map.hour);
	const curMinute = Number(map.minute);

	if (curHour > hour || (curHour === hour && curMinute >= minute)) {
		const anchor = new Date(Date.UTC(year, month - 1, day, 12));
		anchor.setUTCDate(anchor.getUTCDate() + 1);
		year = anchor.getUTCFullYear();
		month = anchor.getUTCMonth() + 1;
		day = anchor.getUTCDate();
	}

	return resolveZonedWallClockToUtc(year, month, day, hour, minute, timeZone);
}

export function getUtcMonthPeriod(now: Date = new Date()): { periodStart: string; periodEnd: string } {
	const year = now.getUTCFullYear();
	const month = now.getUTCMonth();
	const start = new Date(Date.UTC(year, month, 1));
	const end = new Date(Date.UTC(year, month + 1, 0)); // day 0 of next month = last day of this month
	const fmt = (d: Date) => d.toISOString().slice(0, 10);
	return { periodStart: fmt(start), periodEnd: fmt(end) };
}
