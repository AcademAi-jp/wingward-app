import { describe, expect, it, vi } from "vitest";
import {
	UnavailableCafeSearchProvider,
	intersectFreeTime,
	intersectMeetupAvailability,
	searchFairCafeCandidates,
	type BusyCalendar,
	type MeetupAvailabilityInput,
	type TimeInterval,
	type CafeCandidate,
	type CafeSearchProvider,
	type CafeSearchRequest,
} from "./chat-meetup-providers";

const NOW = new Date("2026-09-26T00:00:00.000Z");

const baseRequest: CafeSearchRequest = {
	first_participant: {
		consented: true,
		location: {
			kind: "coordinates",
			latitude: 37.7749,
			longitude: -122.4194,
			nearest_station: "Embarcadero",
			nearby_station_names: ["Powell", "Montgomery"],
		},
	},
	second_participant: {
		consented: true,
		location: {
			kind: "station",
			station_name: "Oakland Central",
			nearby_station_names: ["West Oakland", "Lake Merritt"],
		},
	},
	time_options: [
		{
			starts_at: "2026-09-27T10:00:00.000Z",
			ends_at: "2026-09-27T14:00:00.000Z",
		},
	],
	duration_minutes: 60,
};

function candidate(overrides: Partial<CafeCandidate> = {}): CafeCandidate {
	return {
		id: "place-001",
		name: "Harbor Cafe",
		address: "10 Sample Street, Oakland",
		starts_at: "2026-09-27T09:00:00.000Z",
		ends_at: "2026-09-27T18:00:00.000Z",
		travel_minutes_first: 20,
		travel_minutes_second: 20,
		verified_at: "2026-09-26T00:00:00.000Z",
		...overrides,
	};
}

function configuredProvider(response: unknown): CafeSearchProvider {
	return {
		availability: "configured",
		search: vi.fn().mockResolvedValue(response),
	};
}

describe("intersectFreeTime", () => {
	it("subtracts and merges each person's busy intervals, then keeps shared ranges long enough", () => {
		const first: BusyCalendar = {
			window: {
				starts_at: "2026-10-01T10:00:00Z",
				ends_at: "2026-10-01T16:00:00Z",
			},
			busy: [
				{ starts_at: "2026-10-01T14:00:00Z", ends_at: "2026-10-01T14:30:00Z" },
				{ starts_at: "2026-10-01T11:00:00Z", ends_at: "2026-10-01T12:00:00Z" },
				{ starts_at: "2026-10-01T11:30:00Z", ends_at: "2026-10-01T12:15:00Z" },
			],
		};
		const second: BusyCalendar = {
			window: {
				starts_at: "2026-10-01T10:30:00Z",
				ends_at: "2026-10-01T15:30:00Z",
			},
			busy: [{ starts_at: "2026-10-01T13:00:00Z", ends_at: "2026-10-01T13:30:00Z" }],
		};

		expect(intersectFreeTime(first, second, 60)).toEqual([
			{ starts_at: "2026-10-01T14:30:00.000Z", ends_at: "2026-10-01T15:30:00.000Z" },
		]);
	});

	it("returns only actual shared openings that meet the duration threshold", () => {
		const first: BusyCalendar = {
			window: { starts_at: "2026-10-01T10:00:00Z", ends_at: "2026-10-01T12:00:00Z" },
			busy: [],
		};
		const second: BusyCalendar = {
			window: { starts_at: "2026-10-01T10:30:00Z", ends_at: "2026-10-01T11:30:00Z" },
			busy: [],
		};

		expect(intersectFreeTime(first, second, 61)).toEqual([]);
		expect(intersectFreeTime(first, second, 60)).toEqual([
			{ starts_at: "2026-10-01T10:30:00.000Z", ends_at: "2026-10-01T11:30:00.000Z" },
		]);
	});

	it("rejects titles, locations, attendees, and any other calendar detail", () => {
		const calendar = {
			window: { starts_at: "2026-10-01T10:00:00Z", ends_at: "2026-10-01T12:00:00Z" },
			busy: [
				{
					starts_at: "2026-10-01T10:30:00Z",
					ends_at: "2026-10-01T11:00:00Z",
					title: "Private appointment",
					location: "Home",
					attendees: ["peer@example.invalid"],
				},
			],
		} as unknown as BusyCalendar;
		const valid: BusyCalendar = {
			window: { starts_at: "2026-10-01T10:00:00Z", ends_at: "2026-10-01T12:00:00Z" },
			busy: [],
		};

		expect(() => intersectFreeTime(calendar, valid, 30)).toThrow("Invalid free/busy calendar input.");
		expect(() =>
			intersectFreeTime(
				{
					...valid,
					window: { ...valid.window, title: "Not allowed" },
				} as unknown as BusyCalendar,
				valid,
				30,
			),
		).toThrow("Invalid free/busy calendar input.");
	});

	it("rejects non-UTC, reversed, out-of-window, and over-21-day calendar inputs", () => {
		const valid: BusyCalendar = {
			window: { starts_at: "2026-10-01T10:00:00Z", ends_at: "2026-10-01T12:00:00Z" },
			busy: [],
		};
		const offsetTimestamp = {
			...valid,
			window: { starts_at: "2026-10-01T10:00:00+00:00", ends_at: "2026-10-01T12:00:00Z" },
		} as unknown as BusyCalendar;
		const reversed = {
			...valid,
			busy: [{ starts_at: "2026-10-01T11:00:00Z", ends_at: "2026-10-01T10:30:00Z" }],
		};
		const outside = {
			...valid,
			busy: [{ starts_at: "2026-10-01T09:00:00Z", ends_at: "2026-10-01T10:30:00Z" }],
		};
		const tooLong: BusyCalendar = {
			window: { starts_at: "2026-10-01T00:00:00Z", ends_at: "2026-10-23T00:00:00Z" },
			busy: [],
		};

		expect(() => intersectFreeTime(offsetTimestamp, valid, 30)).toThrow();
		expect(() => intersectFreeTime(reversed, valid, 30)).toThrow();
		expect(() => intersectFreeTime(outside, valid, 30)).toThrow();
		expect(() => intersectFreeTime(tooLong, valid, 30)).toThrow();
		expect(() => intersectFreeTime(valid, valid, 0)).toThrow("Invalid meeting duration.");
	});
});

describe("intersectMeetupAvailability", () => {
	const now = new Date("2026-09-26T00:00:00.000Z");
	const window: TimeInterval = {
		starts_at: "2026-10-01T10:00:00.000Z",
		ends_at: "2026-10-01T16:00:00.000Z",
	};

	it("intersects two calendar busy schedules and returns exact-duration future slots", () => {
		const first: MeetupAvailabilityInput = {
			source: "calendar",
			calendar: {
				window,
				busy: [{ starts_at: "2026-10-01T11:00:00.000Z", ends_at: "2026-10-01T12:00:00.000Z" }],
			},
		};
		const second: MeetupAvailabilityInput = {
			source: "calendar",
			calendar: {
				window,
				busy: [{ starts_at: "2026-10-01T13:00:00.000Z", ends_at: "2026-10-01T14:00:00.000Z" }],
			},
		};

		expect(intersectMeetupAvailability(first, second, 60, now)).toEqual([
			{ starts_at: "2026-10-01T10:00:00.000Z", ends_at: "2026-10-01T11:00:00.000Z" },
			{ starts_at: "2026-10-01T12:00:00.000Z", ends_at: "2026-10-01T13:00:00.000Z" },
			{ starts_at: "2026-10-01T14:00:00.000Z", ends_at: "2026-10-01T15:00:00.000Z" },
		]);
	});

	it("merges overlapping manual free intervals before combining two manual schedules", () => {
		const first: MeetupAvailabilityInput = {
			source: "manual",
			window,
			available: [
				{ starts_at: "2026-10-01T14:00:00.000Z", ends_at: "2026-10-01T16:00:00.000Z" },
				{ starts_at: "2026-10-01T10:00:00.000Z", ends_at: "2026-10-01T12:00:00.000Z" },
				{ starts_at: "2026-10-01T11:30:00.000Z", ends_at: "2026-10-01T13:00:00.000Z" },
			],
		};
		const second: MeetupAvailabilityInput = {
			source: "manual",
			window,
			available: [{ starts_at: "2026-10-01T11:00:00.000Z", ends_at: "2026-10-01T15:00:00.000Z" }],
		};

		expect(intersectMeetupAvailability(first, second, 60, now)).toEqual([
			{ starts_at: "2026-10-01T11:00:00.000Z", ends_at: "2026-10-01T12:00:00.000Z" },
			{ starts_at: "2026-10-01T14:00:00.000Z", ends_at: "2026-10-01T15:00:00.000Z" },
		]);
	});

	it("combines a calendar schedule with a manual permission fallback", () => {
		const calendar: MeetupAvailabilityInput = {
			source: "calendar",
			calendar: {
				window,
				busy: [{ starts_at: "2026-10-01T10:00:00.000Z", ends_at: "2026-10-01T11:00:00.000Z" }],
			},
		};
		const manualFallback: MeetupAvailabilityInput = {
			source: "manual",
			window,
			available: [{ starts_at: "2026-10-01T11:00:00.000Z", ends_at: "2026-10-01T14:00:00.000Z" }],
		};

		expect(intersectMeetupAvailability(calendar, manualFallback, 60, now)).toEqual([
			{ starts_at: "2026-10-01T11:00:00.000Z", ends_at: "2026-10-01T12:00:00.000Z" },
		]);
	});

	it("rejects deep calendar metadata, unknown source fields, and out-of-window manual intervals", () => {
		const calendarWithDetails = {
			source: "calendar",
			calendar: {
				window,
				busy: [
					{
						starts_at: "2026-10-01T11:00:00.000Z",
						ends_at: "2026-10-01T12:00:00.000Z",
						title: "Private meeting",
						location: "Home",
						attendees: [{ email: "private@example.invalid" }],
					},
				],
			},
		} as unknown as MeetupAvailabilityInput;
		const manualWithDetails = {
			source: "manual",
			window,
			available: [
				{
					starts_at: "2026-10-01T11:00:00.000Z",
					ends_at: "2026-10-01T12:00:00.000Z",
					metadata: { title: "private" },
				},
			],
		} as unknown as MeetupAvailabilityInput;
		const outOfWindow: MeetupAvailabilityInput = {
			source: "manual",
			window,
			available: [{ starts_at: "2026-10-01T09:00:00.000Z", ends_at: "2026-10-01T12:00:00.000Z" }],
		};
		const unknownSourceField = {
			source: "calendar",
			calendar: { window, busy: [] },
			account_id: "owner",
		} as unknown as MeetupAvailabilityInput;

		expect(() => intersectMeetupAvailability(calendarWithDetails, manualWithDetails, 60, now)).toThrow(
			"Invalid meetup availability input.",
		);
		expect(() => intersectMeetupAvailability(manualWithDetails, calendarWithDetails, 60, now)).toThrow(
			"Invalid meetup availability input.",
		);
		expect(() => intersectMeetupAvailability(outOfWindow, calendarWithDetails, 60, now)).toThrow(
			"Meetup intervals must stay inside their window.",
		);
		expect(() => intersectMeetupAvailability(unknownSourceField, manualWithDetails, 60, now)).toThrow(
			"Invalid meetup availability input.",
		);
	});

	it("rejects more than 128 busy or available intervals", () => {
		const repeated = Array.from({ length: 129 }, () => ({
			starts_at: "2026-10-01T11:00:00.000Z",
			ends_at: "2026-10-01T12:00:00.000Z",
		}));
		const tooManyBusy = {
			source: "calendar",
			calendar: { window, busy: repeated },
		} as unknown as MeetupAvailabilityInput;
		const tooManyAvailable = {
			source: "manual",
			window,
			available: repeated,
		} as unknown as MeetupAvailabilityInput;
		const valid: MeetupAvailabilityInput = {
			source: "calendar",
			calendar: { window, busy: [] },
		};

		expect(() => intersectMeetupAvailability(tooManyBusy, valid, 30, now)).toThrow(
			"Invalid meetup availability input.",
		);
		expect(() => intersectMeetupAvailability(tooManyAvailable, valid, 30, now)).toThrow(
			"Invalid meetup availability input.",
		);
	});

	it("requires future windows within 21 days and keeps no more than three future slots", () => {
		const futureWindow: TimeInterval = {
			starts_at: "2026-09-26T00:00:00.000Z",
			ends_at: "2026-10-17T00:00:00.000Z",
		};
		const manySlots: MeetupAvailabilityInput = {
			source: "manual",
			window: futureWindow,
			available: [
				{ starts_at: "2026-09-26T00:00:00.000Z", ends_at: "2026-10-17T00:00:00.000Z" },
			],
		};
		const other: MeetupAvailabilityInput = {
			source: "manual",
			window: futureWindow,
			available: [
				{ starts_at: "2026-09-26T00:00:00.000Z", ends_at: "2026-10-17T00:00:00.000Z" },
			],
		};
		const invalidWindow: MeetupAvailabilityInput = {
			source: "manual",
			window: {
				starts_at: "2026-09-26T00:00:00.000Z",
				ends_at: "2026-10-17T00:00:00.001Z",
			},
			available: [],
		};
		const crowded: MeetupAvailabilityInput = {
			source: "calendar",
			calendar: {
				window,
				busy: [
					{ starts_at: "2026-10-01T11:00:00.000Z", ends_at: "2026-10-01T12:00:00.000Z" },
					{ starts_at: "2026-10-01T13:00:00.000Z", ends_at: "2026-10-01T14:00:00.000Z" },
					{ starts_at: "2026-10-01T15:00:00.000Z", ends_at: "2026-10-01T15:30:00.000Z" },
				],
			},
		};
		const fullAvailability: MeetupAvailabilityInput = {
			source: "calendar",
			calendar: { window, busy: [] },
		};

		expect(intersectMeetupAvailability(manySlots, other, 60, now)).toEqual([
			{
				starts_at: "2026-09-26T00:01:00.000Z",
				ends_at: "2026-09-26T01:01:00.000Z",
			},
		]);
		expect(() => intersectMeetupAvailability(invalidWindow, other, 60, now)).toThrow(
			"Meetup availability window must be within the next 21 days.",
		);
		expect(intersectMeetupAvailability(fullAvailability, crowded, 30, now)).toHaveLength(3);
	});
});

describe("searchFairCafeCandidates", () => {
	it("passes only consented private location inputs and returns public fields ranked by balanced travel", async () => {
		const exactBalance = candidate({
			id: "exact-balance",
			area: "Oakland/Downtown",
			travel_minutes_first: 35,
			travel_minutes_second: 35,
		});
		const nearBalance = candidate({
			id: "near-balance",
			travel_minutes_first: 18.5,
			travel_minutes_second: 20.5,
		});
		const unbalanced = candidate({
			id: "unbalanced",
			travel_minutes_first: 10,
			travel_minutes_second: 35,
		});
		const tooFar = candidate({
			id: "too-far",
			travel_minutes_first: 121,
			travel_minutes_second: 121,
		});
		const stale = candidate({
			id: "stale",
			verified_at: "2026-09-25T16:00:00.000Z",
		});
		const closed = candidate({
			id: "closed",
			starts_at: "2026-09-27T15:00:00.000Z",
			ends_at: "2026-09-27T16:00:00.000Z",
		});
		const provider = configuredProvider([
			nearBalance,
			tooFar,
			exactBalance,
			stale,
			closed,
			unbalanced,
			candidate({
				id: "opens-after-selected-start",
				starts_at: "2026-09-27T10:30:00.000Z",
			}),
		]);

		const result = await searchFairCafeCandidates(provider, baseRequest, NOW);

		expect(result).toEqual({
			status: "available",
			candidates: [exactBalance, nearBalance],
		});
		expect(provider.search).toHaveBeenCalledTimes(1);
		expect(provider.search).toHaveBeenCalledWith(baseRequest);
		const serialized = JSON.stringify(result);
		expect(serialized).not.toContain("37.7749");
		expect(serialized).not.toContain("-122.4194");
		expect(serialized).not.toContain("Oakland Central");
		expect(serialized).not.toContain("Embarcadero");
		expect(serialized).not.toContain("Powell");
		expect(serialized).not.toContain("Lake Merritt");
	});

	it("accepts only an optional coarse City/Ward area and never derives it from an address", async () => {
		const provider = configuredProvider([
			candidate({ id: "verified-area", area: "Tokyo/Chiyoda" }),
			candidate({ id: "street-as-area", area: "123 Main Street/Suite 5" }),
		]);

		await expect(searchFairCafeCandidates(provider, baseRequest, NOW)).resolves.toEqual({
			status: "unavailable",
			reason: "invalid_provider_response",
		});
	});

	it("returns no cafe when every candidate exceeds the travel-burden bound", async () => {
		const provider = configuredProvider([
			candidate({
				id: "far-from-one",
				travel_minutes_first: 120,
				travel_minutes_second: 1,
			}),
		]);

		await expect(searchFairCafeCandidates(provider, baseRequest, NOW)).resolves.toEqual({
			status: "available",
			candidates: [],
		});
	});

	it("requires the cafe to be open for the exact selected start and full meeting duration", async () => {
		const provider = configuredProvider([
			candidate({
				id: "opens-too-late",
				starts_at: "2026-09-27T10:30:00.000Z",
			}),
			candidate({
				id: "closes-too-early",
				ends_at: "2026-09-27T10:59:00.000Z",
			}),
			candidate({ id: "open-for-full-slot" }),
		]);

		await expect(searchFairCafeCandidates(provider, baseRequest, NOW)).resolves.toEqual({
			status: "available",
			candidates: [candidate({ id: "open-for-full-slot" })],
		});
	});

	it("requires both participants to consent before calling a provider", async () => {
		const provider = configuredProvider([candidate()]);
		const request = {
			...baseRequest,
			second_participant: { ...baseRequest.second_participant, consented: false },
		} as unknown as CafeSearchRequest;

		await expect(searchFairCafeCandidates(provider, request, NOW)).rejects.toThrow("Invalid cafe search request.");
		expect(provider.search).not.toHaveBeenCalled();
	});

	it("rejects extra request fields before the provider receives calendar or identity details", async () => {
		const provider = configuredProvider([candidate()]);
		const request = {
			...baseRequest,
			participant_id: "owner-id",
			direct_chat_text: "private conversation",
		} as unknown as CafeSearchRequest;

		await expect(searchFairCafeCandidates(provider, request, NOW)).rejects.toThrow("Invalid cafe search request.");
		expect(provider.search).not.toHaveBeenCalled();
	});

	it("reports an unconfigured provider explicitly without returning synthetic cafes", async () => {
		const provider = new UnavailableCafeSearchProvider();
		const search = vi.spyOn(provider, "search");

		await expect(searchFairCafeCandidates(provider, baseRequest, NOW)).resolves.toEqual({
			status: "unavailable",
			reason: "provider_not_configured",
		});
		expect(search).not.toHaveBeenCalled();
	});

	it("rejects malformed provider payloads instead of reflecting extra details", async () => {
		const provider = configuredProvider([
			{
				...candidate(),
				title: "private calendar title",
				reservation_status: "booked",
			},
		]);

		await expect(searchFairCafeCandidates(provider, baseRequest, NOW)).resolves.toEqual({
			status: "unavailable",
			reason: "invalid_provider_response",
		});
	});

	it("rejects negative travel estimates", async () => {
		const provider = configuredProvider([candidate({ travel_minutes_first: -1 })]);

		await expect(searchFairCafeCandidates(provider, baseRequest, NOW)).resolves.toEqual({
			status: "unavailable",
			reason: "invalid_provider_response",
		});
	});

	it("keeps ordinary cafe names and street numbers in separate fields", async () => {
		const ordinaryCafe = candidate({
			id: "google:ChI-cafe-1",
			name: "Cafe ChI-cafe-1",
			address: "10 Sample Street, Oakland",
		});
		const provider = configuredProvider([ordinaryCafe]);

		await expect(searchFairCafeCandidates(provider, baseRequest, NOW)).resolves.toEqual({
			status: "available",
			candidates: [ordinaryCafe],
		});
	});

	it("drops coordinate-bearing fields, split consented coordinates, and future-dated verification", async () => {
		const coordinateLeak = candidate({
			id: "coordinate-leak",
			address: "Harbor Cafe at 37.7749, -122.4194",
		});
		const splitOriginCoordinates = candidate({
			id: "split-origin-coordinates",
			name: "37.7749",
			address: "-122.4194 Sample Street, Oakland",
		});
		const futureVerified = candidate({
			id: "future-verified",
			verified_at: "2026-09-26T00:10:00.000Z",
		});
		const provider = configuredProvider([coordinateLeak, splitOriginCoordinates, futureVerified, candidate({ id: "safe" })]);

		await expect(searchFairCafeCandidates(provider, baseRequest, NOW)).resolves.toEqual({
			status: "available",
			candidates: [candidate({ id: "safe" })],
		});
	});

	it("returns a generic provider error without reflecting the failure detail", async () => {
		const provider: CafeSearchProvider = {
			availability: "configured",
			search: vi.fn().mockRejectedValue(new Error("37.7749, -122.4194 SECRET")),
		};

		const result = await searchFairCafeCandidates(provider, baseRequest, NOW);

		expect(result).toEqual({ status: "unavailable", reason: "provider_error" });
		expect(JSON.stringify(result)).not.toContain("SECRET");
		expect(JSON.stringify(result)).not.toContain("37.7749");
	});
});
