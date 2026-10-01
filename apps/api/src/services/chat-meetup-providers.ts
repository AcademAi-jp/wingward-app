import { z } from "zod";

export interface TimeInterval {
	starts_at: string;
	ends_at: string;
}

export interface BusyCalendar {
	window: TimeInterval;
	busy: TimeInterval[];
}

export type MeetupAvailabilityInput =
	| { source: "calendar"; calendar: BusyCalendar }
	| { source: "manual"; window: TimeInterval; available: TimeInterval[] };

export interface CafeCandidate {
	id: string;
	name: string;
	address: string;
	/** Coarse city/ward verified by the venue adapter; omitted when unavailable. */
	area?: string;
	/** Provider-verified opening interval in UTC during the transient search request. */
	starts_at: string;
	ends_at: string;
	/** Null means a fresh estimate is unavailable; never substitute zero. */
	travel_minutes_first: number | null;
	travel_minutes_second: number | null;
	verified_at: string;
	/** Present only for a freshly hydrated Google Places candidate. */
	source?: "google";
	google_maps_uri?: string;
	attributions?: Array<{ provider: string; provider_uri?: string }>;
}

export type CafeLocationInput =
	| {
			kind: "coordinates";
			latitude: number;
			longitude: number;
			nearest_station?: string;
			nearby_station_names?: string[];
	  }
	| { kind: "station"; station_name: string; nearby_station_names?: string[] };

export interface CafeSearchRequest {
	/**
	 * Each participant's own location is supplied only after that participant
	 * consents. These are ephemeral provider-query inputs: providers must not
	 * log, retain, or forward them to an AI service.
	 */
	first_participant: { consented: true; location: CafeLocationInput };
	second_participant: { consented: true; location: CafeLocationInput };
	time_options: TimeInterval[];
	duration_minutes: number;
}

export interface CafeSearchProvider {
	availability: "configured" | "unavailable";
	/**
	 * Provider data is untrusted at runtime even when an adapter has a
	 * TypeScript return type. Return raw JSON-like data for strict validation.
	 */
	search(request: CafeSearchRequest): Promise<unknown>;
}

export interface GoogleCafeReference {
	id: string;
	starts_at: string;
	ends_at: string;
}

export interface GoogleCafeReferenceProvider extends CafeSearchProvider {
	readonly source: "google";
	hydrateReference(reference: GoogleCafeReference): Promise<unknown | null>;
	verifyReference(reference: GoogleCafeReference): Promise<boolean>;
}

export function isGoogleCafeReferenceProvider(provider: CafeSearchProvider): provider is GoogleCafeReferenceProvider {
	const candidate = provider as Partial<GoogleCafeReferenceProvider>;
	return candidate.source === "google" &&
		typeof candidate.hydrateReference === "function" &&
		typeof candidate.verifyReference === "function";
}

export type CafeSearchResult =
	| { status: "available"; candidates: CafeCandidate[] }
	| {
			status: "unavailable";
			reason: "provider_not_configured" | "provider_error" | "invalid_provider_response";
	  };

const MINUTE_MS = 60_000;
const MAX_WINDOW_MS = 21 * 24 * 60 * MINUTE_MS;
const MAX_INTERVALS = 1_000;
const MAX_SEARCH_OPTIONS = 64;
const MAX_PROVIDER_CANDIDATES = 100;
const MAX_MEETING_DURATION_MINUTES = 24 * 60;
const MAX_CAFE_OPEN_INTERVAL_MS = 24 * 60 * MINUTE_MS;
const MAX_CAFE_TRAVEL_MINUTES = 120;
const MAX_CAFE_TRAVEL_IMBALANCE_MINUTES = 30;
const MIN_CAFE_TRAVEL_IMBALANCE_MINUTES = 10;
const MAX_VERIFICATION_AGE_MS = 6 * 60 * MINUTE_MS;
const MAX_FUTURE_CLOCK_SKEW_MS = 5 * MINUTE_MS;

/** Require UTC timestamps so the API never guesses a timezone. */
const UtcTimestampSchema = z.string().datetime({ offset: false });

const TimeIntervalSchema = z
	.object({
		starts_at: UtcTimestampSchema,
		ends_at: UtcTimestampSchema,
	})
	.strict()
	.refine((interval) => Date.parse(interval.starts_at) < Date.parse(interval.ends_at));

const BusyCalendarSchema = z
	.object({
		window: TimeIntervalSchema,
		busy: z.array(TimeIntervalSchema).max(MAX_INTERVALS),
	})
	.strict()
	.superRefine((calendar, context) => {
		const windowStart = Date.parse(calendar.window.starts_at);
		const windowEnd = Date.parse(calendar.window.ends_at);

		if (windowEnd - windowStart > MAX_WINDOW_MS) {
			context.addIssue({
				code: z.ZodIssueCode.custom,
				path: ["window"],
				message: "The calendar window exceeds 21 days.",
			});
		}

		for (let index = 0; index < calendar.busy.length; index += 1) {
			const busy = calendar.busy[index];
			if (Date.parse(busy.starts_at) < windowStart || Date.parse(busy.ends_at) > windowEnd) {
				context.addIssue({
					code: z.ZodIssueCode.custom,
					path: ["busy", index],
					message: "Busy intervals must remain inside the calendar window.",
				});
			}
		}
	});

const CalendarMeetupAvailabilitySchema = z
	.object({
		source: z.literal("calendar"),
		calendar: z
			.object({
				window: TimeIntervalSchema,
				busy: z.array(TimeIntervalSchema).max(128),
			})
			.strict(),
	})
	.strict();

const ManualMeetupAvailabilitySchema = z
	.object({
		source: z.literal("manual"),
		window: TimeIntervalSchema,
		available: z.array(TimeIntervalSchema).max(128),
	})
	.strict();

const MeetupAvailabilityInputSchema = z.discriminatedUnion("source", [
	CalendarMeetupAvailabilitySchema,
	ManualMeetupAvailabilitySchema,
]);

const DurationMinutesSchema = z.number().int().positive().max(MAX_MEETING_DURATION_MINUTES);

function parseBusyCalendar(input: BusyCalendar): z.infer<typeof BusyCalendarSchema> {
	const parsed = BusyCalendarSchema.safeParse(input);
	if (!parsed.success) throw new TypeError("Invalid free/busy calendar input.");
	return parsed.data;
}

function parseDurationMinutes(input: number): number {
	const parsed = DurationMinutesSchema.safeParse(input);
	if (!parsed.success) throw new TypeError("Invalid meeting duration.");
	return parsed.data;
}

function mergeBusyIntervals(intervals: TimeInterval[]): Array<{ start: number; end: number }> {
	const sorted = intervals
		.map(({ starts_at, ends_at }) => ({ start: Date.parse(starts_at), end: Date.parse(ends_at) }))
		.sort((left, right) => left.start - right.start || left.end - right.end);
	const merged: Array<{ start: number; end: number }> = [];

	for (const interval of sorted) {
		const previous = merged.at(-1);
		if (previous && interval.start <= previous.end) {
			previous.end = Math.max(previous.end, interval.end);
		} else {
			merged.push({ ...interval });
		}
	}
	return merged;
}

function subtractBusy(
	windowStart: number,
	windowEnd: number,
	busyIntervals: TimeInterval[],
): Array<{ start: number; end: number }> {
	const free: Array<{ start: number; end: number }> = [];
	let cursor = windowStart;

	for (const busy of mergeBusyIntervals(busyIntervals)) {
		if (busy.start > cursor) free.push({ start: cursor, end: busy.start });
		cursor = Math.max(cursor, busy.end);
	}
	if (cursor < windowEnd) free.push({ start: cursor, end: windowEnd });
	return free;
}

/**
 * Finds shared free ranges from two strict free/busy-only calendar payloads.
 * Busy ranges use half-open semantics: an event ending at 10:00 does not make
 * a 10:00 start busy. Returned ranges are full shared openings at least as
 * long as the requested duration.
 */
export function intersectFreeTime(
	first: BusyCalendar,
	second: BusyCalendar,
	durationMinutes: number,
): TimeInterval[] {
	const firstCalendar = parseBusyCalendar(first);
	const secondCalendar = parseBusyCalendar(second);
	const durationMs = parseDurationMinutes(durationMinutes) * MINUTE_MS;

	const sharedStart = Math.max(
		Date.parse(firstCalendar.window.starts_at),
		Date.parse(secondCalendar.window.starts_at),
	);
	const sharedEnd = Math.min(
		Date.parse(firstCalendar.window.ends_at),
		Date.parse(secondCalendar.window.ends_at),
	);
	if (sharedEnd - sharedStart < durationMs) return [];

	const firstFree = subtractBusy(
		sharedStart,
		sharedEnd,
		firstCalendar.busy.filter(
			({ starts_at, ends_at }) =>
				Date.parse(ends_at) > sharedStart && Date.parse(starts_at) < sharedEnd,
		),
	);
	const secondFree = subtractBusy(
		sharedStart,
		sharedEnd,
		secondCalendar.busy.filter(
			({ starts_at, ends_at }) =>
				Date.parse(ends_at) > sharedStart && Date.parse(starts_at) < sharedEnd,
		),
	);

	const intersections: TimeInterval[] = [];
	let firstIndex = 0;
	let secondIndex = 0;
	while (firstIndex < firstFree.length && secondIndex < secondFree.length) {
		const firstInterval = firstFree[firstIndex];
		const secondInterval = secondFree[secondIndex];
		const start = Math.max(firstInterval.start, secondInterval.start);
		const end = Math.min(firstInterval.end, secondInterval.end);

		if (end - start >= durationMs) {
			intersections.push({
				starts_at: new Date(start).toISOString(),
				ends_at: new Date(end).toISOString(),
			});
		}

		if (firstInterval.end <= secondInterval.end) firstIndex += 1;
		if (secondInterval.end <= firstInterval.end) secondIndex += 1;
	}
	return intersections;
}

const NearbyStationNamesSchema = z.array(z.string().trim().min(1).max(120)).max(8);

function parseMeetupAvailabilityInput(
	input: MeetupAvailabilityInput,
	nowMs: number,
): z.infer<typeof MeetupAvailabilityInputSchema> {
	const parsed = MeetupAvailabilityInputSchema.safeParse(input);
	if (!parsed.success) throw new TypeError("Invalid meetup availability input.");

	const window = parsed.data.source === "calendar" ? parsed.data.calendar.window : parsed.data.window;
	const windowStart = Date.parse(window.starts_at);
	const windowEnd = Date.parse(window.ends_at);
	if (windowStart < nowMs || windowEnd > nowMs + MAX_WINDOW_MS) {
		throw new TypeError("Meetup availability window must be within the next 21 days.");
	}

	const intervals = parsed.data.source === "calendar" ? parsed.data.calendar.busy : parsed.data.available;
	for (const interval of intervals) {
		if (Date.parse(interval.starts_at) < windowStart || Date.parse(interval.ends_at) > windowEnd) {
			throw new TypeError("Meetup intervals must stay inside their window.");
		}
	}
	return parsed.data;
}

function manualAvailabilityToBusy(
	input: Extract<z.infer<typeof MeetupAvailabilityInputSchema>, { source: "manual" }>,
): BusyCalendar {
	const windowStart = Date.parse(input.window.starts_at);
	const windowEnd = Date.parse(input.window.ends_at);
	const busy: TimeInterval[] = [];
	let cursor = windowStart;

	for (const interval of mergeBusyIntervals(input.available)) {
		if (interval.start > cursor) {
			busy.push({
				starts_at: new Date(cursor).toISOString(),
				ends_at: new Date(interval.start).toISOString(),
			});
		}
		cursor = Math.max(cursor, interval.end);
	}
	if (cursor < windowEnd) {
		busy.push({
			starts_at: new Date(cursor).toISOString(),
			ends_at: new Date(windowEnd).toISOString(),
		});
	}
	return { window: input.window, busy };
}

/**
 * Combines calendar busy intervals and manually supplied free intervals for
 * both participants. Calendar/manual payloads are strict UTC endpoint-only
 * data; manual free time is merged and complemented into busy ranges before
 * the shared intersection. Each returned option is one exact-duration future
 * slot, with no more than three options.
 */
export function intersectMeetupAvailability(
	first: MeetupAvailabilityInput,
	second: MeetupAvailabilityInput,
	durationMinutes: number,
	now: Date,
): TimeInterval[] {
	if (!(now instanceof Date) || !Number.isFinite(now.getTime())) {
		throw new TypeError("Invalid availability clock.");
	}
	const duration = parseDurationMinutes(durationMinutes);
	const nowMs = now.getTime();
	const firstInput = parseMeetupAvailabilityInput(first, nowMs);
	const secondInput = parseMeetupAvailabilityInput(second, nowMs);

	const firstCalendar =
		firstInput.source === "calendar" ? firstInput.calendar : manualAvailabilityToBusy(firstInput);
	const secondCalendar =
		secondInput.source === "calendar" ? secondInput.calendar : manualAvailabilityToBusy(secondInput);

	const durationMs = duration * MINUTE_MS;
	const futureMinute = Math.ceil((nowMs + 1) / MINUTE_MS) * MINUTE_MS;
	return intersectFreeTime(firstCalendar, secondCalendar, duration)
		.flatMap((range) => {
			const rangeStart = Date.parse(range.starts_at);
			const rangeEnd = Date.parse(range.ends_at);
			const slotStart = rangeStart > nowMs ? rangeStart : futureMinute;
			const slotEnd = slotStart + durationMs;
			if (slotEnd > rangeEnd) return [];
			return [
				{
					starts_at: new Date(slotStart).toISOString(),
					ends_at: new Date(slotEnd).toISOString(),
				},
			];
		})
		.slice(0, 3);
}

const CoordinateLocationSchema = z
	.object({
		kind: z.literal("coordinates"),
		latitude: z.number().finite().min(-90).max(90),
		longitude: z.number().finite().min(-180).max(180),
		nearest_station: z.string().trim().min(1).max(120).optional(),
		nearby_station_names: NearbyStationNamesSchema.optional(),
	})
	.strict();

const StationLocationSchema = z
	.object({
		kind: z.literal("station"),
		station_name: z.string().trim().min(1).max(120),
		nearby_station_names: NearbyStationNamesSchema.optional(),
	})
	.strict();

const CafeLocationSchema = z.discriminatedUnion("kind", [
	CoordinateLocationSchema,
	StationLocationSchema,
]);

const ConsentedParticipantSchema = z
	.object({
		consented: z.literal(true),
		location: CafeLocationSchema,
	})
	.strict();

const CafeSearchRequestSchema = z
	.object({
		first_participant: ConsentedParticipantSchema,
		second_participant: ConsentedParticipantSchema,
		time_options: z.array(TimeIntervalSchema).min(1).max(MAX_SEARCH_OPTIONS),
		duration_minutes: DurationMinutesSchema,
	})
	.strict()
	.superRefine((request, context) => {
		const starts = request.time_options.map(({ starts_at }) => Date.parse(starts_at));
		const ends = request.time_options.map(({ ends_at }) => Date.parse(ends_at));
		const totalSpan = Math.max(...ends) - Math.min(...starts);
		if (totalSpan > MAX_WINDOW_MS) {
			context.addIssue({
				code: z.ZodIssueCode.custom,
				path: ["time_options"],
				message: "Cafe search options must stay inside a 21-day window.",
			});
		}
	});

function hasNoControlCharacters(value: string): boolean {
	return !/[\u0000-\u001f\u007f\u2028\u2029]/u.test(value);
}

function isCoarseArea(value: string): boolean {
	const parts = value.split("/");
	if (value !== value.trim() || value.length > 161 || parts.length !== 2) return false;
	return parts.every(
		(part) =>
			part === part.trim() &&
			part.length > 0 &&
			part.length <= 80 &&
			!/[0-9,;@#$%]/u.test(part) &&
			hasNoControlCharacters(part),
	);
}

const CoarseAreaSchema = z.string().min(3).max(161).refine(isCoarseArea);

const CafeCandidateSchema = z
	.object({
		id: z.string().trim().min(1).max(256).refine(hasNoControlCharacters),
		name: z.string().trim().min(1).max(120).refine(hasNoControlCharacters),
		address: z.string().trim().min(1).max(300).refine(hasNoControlCharacters),
		area: CoarseAreaSchema.optional(),
		starts_at: UtcTimestampSchema,
		ends_at: UtcTimestampSchema,
		travel_minutes_first: z.number().finite().nonnegative().max(24 * 60).nullable(),
		travel_minutes_second: z.number().finite().nonnegative().max(24 * 60).nullable(),
		verified_at: UtcTimestampSchema,
		source: z.literal("google").optional(),
		google_maps_uri: z.string().url().max(2048).optional(),
		attributions: z.array(z.object({
			provider: z.string().trim().min(1).max(120).refine(hasNoControlCharacters),
			provider_uri: z.string().url().max(2048).optional(),
		}).strict()).max(50).optional(),
	})
	.strict()
	.superRefine((candidate, context) => {
		const startsAt = Date.parse(candidate.starts_at);
		const endsAt = Date.parse(candidate.ends_at);
		if (endsAt <= startsAt || endsAt - startsAt > MAX_CAFE_OPEN_INTERVAL_MS) {
			context.addIssue({ code: z.ZodIssueCode.custom, path: ["ends_at"], message: "Invalid cafe opening interval." });
		}
		if (candidate.source === "google") {
			if (!candidate.google_maps_uri || !isGoogleMapsUri(candidate.google_maps_uri) || !candidate.attributions) {
				context.addIssue({ code: z.ZodIssueCode.custom, path: ["google_maps_uri"], message: "Google attribution is required." });
			}
		} else if (
			candidate.google_maps_uri !== undefined || candidate.attributions !== undefined ||
			candidate.travel_minutes_first === null || candidate.travel_minutes_second === null
		) {
			context.addIssue({ code: z.ZodIssueCode.custom, path: ["source"], message: "Google-only fields require a Google source." });
		}
	});

function isGoogleMapsUri(value: string): boolean {
	try {
		const uri = new URL(value);
		if (uri.protocol !== "https:" || uri.username || uri.password || (uri.port && uri.port !== "443")) return false;
		if (uri.hostname === "maps.google.com") return true;
		return ["google.com", "www.google.com"].includes(uri.hostname) && /^\/maps(?:\/|$)/u.test(uri.pathname);
	} catch {
		return false;
	}
}

const CafeCandidateArraySchema = z.array(CafeCandidateSchema).max(MAX_PROVIDER_CANDIDATES);

function parseCafeSearchRequest(input: CafeSearchRequest): z.infer<typeof CafeSearchRequestSchema> {
	const parsed = CafeSearchRequestSchema.safeParse(input);
	if (!parsed.success) throw new TypeError("Invalid cafe search request.");
	return parsed.data;
}

function hasExactUpcomingOpening(
	candidate: CafeCandidate,
	timeOptions: TimeInterval[],
	durationMs: number,
	nowMs: number,
): boolean {
	return timeOptions.some((option) => {
		const meetingStart = Date.parse(option.starts_at);
		const meetingEnd = meetingStart + durationMs;
		return (
			meetingStart >= nowMs &&
			meetingEnd <= Date.parse(option.ends_at) &&
			Date.parse(candidate.starts_at) <= meetingStart &&
			Date.parse(candidate.ends_at) >= meetingEnd
		);
	});
}

function hasRawCoordinatePairInPublicFields(
	candidate: CafeCandidate,
	request: z.infer<typeof CafeSearchRequestSchema>,
): boolean {
	const publicFields = [candidate.id, candidate.name, candidate.address, candidate.area ?? ""];
	const coordinatePattern = /(?:^|[^\d])(-?\d{1,2}(?:\.\d+)?)[,\s/]+(-?\d{1,3}(?:\.\d+)?)(?![\d.])/u;
	if (publicFields.some((field) => coordinatePattern.test(field))) return true;

	const tokens = publicFields.join("\n").match(/-?\d+(?:\.\d+)?/gu) ?? [];
	for (const location of [request.first_participant.location, request.second_participant.location]) {
		if (location.kind !== "coordinates") continue;
		const latitude = coordinateVariants(location.latitude);
		const longitude = coordinateVariants(location.longitude);
		if (tokens.some((token) => latitude.has(token)) && tokens.some((token) => longitude.has(token))) return true;
	}
	return false;
}

function coordinateVariants(value: number): Set<string> {
	const variants = new Set([value.toString()]);
	for (let precision = 2; precision <= 8; precision += 1) {
		variants.add(Number(value.toFixed(precision)).toString());
	}
	return variants;
}

function hasFairTravelBurden(candidate: CafeCandidate): boolean {
	if (candidate.travel_minutes_first === null || candidate.travel_minutes_second === null) return true;
	const difference = Math.abs(candidate.travel_minutes_first - candidate.travel_minutes_second);
	const maximum = Math.max(candidate.travel_minutes_first, candidate.travel_minutes_second);
	const allowedDifference = Math.min(
		MAX_CAFE_TRAVEL_IMBALANCE_MINUTES,
		Math.max(MIN_CAFE_TRAVEL_IMBALANCE_MINUTES, Math.round(maximum * 0.25)),
	);
	return difference <= allowedDifference;
}

function compareFairness(left: CafeCandidate, right: CafeCandidate): number {
	const leftFirst = left.travel_minutes_first;
	const leftSecond = left.travel_minutes_second;
	const rightFirst = right.travel_minutes_first;
	const rightSecond = right.travel_minutes_second;
	const leftHasRoutes = leftFirst !== null && leftSecond !== null;
	const rightHasRoutes = rightFirst !== null && rightSecond !== null;
	if (leftHasRoutes !== rightHasRoutes) return leftHasRoutes ? -1 : 1;
	if (!leftHasRoutes || !rightHasRoutes) return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
	if (leftFirst === null || leftSecond === null) return 1;
	if (rightFirst === null || rightSecond === null) return -1;

	const leftDifference = Math.abs(leftFirst - leftSecond);
	const rightDifference = Math.abs(rightFirst - rightSecond);
	if (leftDifference !== rightDifference) return leftDifference - rightDifference;

	const leftMaximum = Math.max(leftFirst, leftSecond);
	const rightMaximum = Math.max(rightFirst, rightSecond);
	if (leftMaximum !== rightMaximum) return leftMaximum - rightMaximum;

	const leftTotal = leftFirst + leftSecond;
	const rightTotal = rightFirst + rightSecond;
	if (leftTotal !== rightTotal) return leftTotal - rightTotal;
	return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
}

/**
 * An explicit no-provider boundary. It makes no network call and never returns
 * synthetic cafes as if they were real or reserved.
 */
export class UnavailableCafeSearchProvider implements CafeSearchProvider {
	readonly availability = "unavailable" as const;

	async search(_request: CafeSearchRequest): Promise<unknown> {
		throw new Error("Cafe search provider is not configured.");
	}
}

export const unavailableCafeSearchProvider: CafeSearchProvider = new UnavailableCafeSearchProvider();

/** Preserves Google reference-only confirmed-plan projection without any paid fetch. */
export class UnavailableGoogleCafeReferenceProvider extends UnavailableCafeSearchProvider implements GoogleCafeReferenceProvider {
	readonly source = "google" as const;

	async hydrateReference(_reference: GoogleCafeReference): Promise<unknown | null> {
		return null;
	}

	async verifyReference(_reference: GoogleCafeReference): Promise<boolean> {
		return false;
	}
}

export const unavailableGoogleCafeReferenceProvider = new UnavailableGoogleCafeReferenceProvider();

/**
 * Calls a configured place provider with mutually consented private inputs,
 * validates its untrusted response, removes stale/closed/over-distance results,
 * and returns public candidate fields ranked by balanced travel burden.
 * No request or provider error details are logged or reflected to callers.
 */
export async function searchFairCafeCandidates(
	provider: CafeSearchProvider,
	request: CafeSearchRequest,
	now: Date = new Date(),
): Promise<CafeSearchResult> {
	const safeRequest = parseCafeSearchRequest(request);
	if (!(now instanceof Date) || !Number.isFinite(now.getTime())) {
		return { status: "unavailable", reason: "provider_error" };
	}
	if (!provider || provider.availability !== "configured" || typeof provider.search !== "function") {
		return { status: "unavailable", reason: "provider_not_configured" };
	}

	let rawResponse: unknown;
	try {
		rawResponse = await provider.search(safeRequest);
	} catch {
		return { status: "unavailable", reason: "provider_error" };
	}

	const parsedResponse = CafeCandidateArraySchema.safeParse(rawResponse);
	if (!parsedResponse.success) {
		return { status: "unavailable", reason: "invalid_provider_response" };
	}

	const nowMs = now.getTime();
	const durationMs = safeRequest.duration_minutes * MINUTE_MS;
	const candidates = parsedResponse.data
		.filter((candidate) => {
			const verifiedAt = Date.parse(candidate.verified_at);
			if (verifiedAt > nowMs + MAX_FUTURE_CLOCK_SKEW_MS) return false;
			if (nowMs - verifiedAt > MAX_VERIFICATION_AGE_MS) return false;
			if (candidate.travel_minutes_first !== null && candidate.travel_minutes_first > MAX_CAFE_TRAVEL_MINUTES) return false;
			if (candidate.travel_minutes_second !== null && candidate.travel_minutes_second > MAX_CAFE_TRAVEL_MINUTES) return false;
			if (!hasFairTravelBurden(candidate)) return false;
			if (!hasExactUpcomingOpening(candidate, safeRequest.time_options, durationMs, nowMs)) return false;
			if (hasRawCoordinatePairInPublicFields(candidate, safeRequest)) return false;
			return true;
		})
		.sort(compareFairness);

	const seenIds = new Set<string>();
	const uniqueCandidates = candidates.filter((candidate) => {
		if (seenIds.has(candidate.id)) return false;
		seenIds.add(candidate.id);
		return true;
	});

	return {
		status: "available",
		candidates: uniqueCandidates.map((candidate) => ({
			id: candidate.id,
			name: candidate.name,
			address: candidate.address,
			...(candidate.area ? { area: candidate.area } : {}),
			starts_at: candidate.starts_at,
			ends_at: candidate.ends_at,
			travel_minutes_first: candidate.travel_minutes_first,
			travel_minutes_second: candidate.travel_minutes_second,
			verified_at: candidate.verified_at,
			...(candidate.source === "google" ? {
				source: "google" as const,
				google_maps_uri: candidate.google_maps_uri,
				attributions: candidate.attributions ?? [],
			} : {}),
		})),
	};
}
