import { z } from "zod";
import { isRecordingRehearsalActive, type RecordingRehearsalGoogleCall, type RecordingRehearsalGoogleOperation, type RecordingRehearsalGoogleReservationHook, type ValidatedRecordingRehearsalConfig } from "./recording-rehearsal";
import {
	unavailableGoogleCafeReferenceProvider,
	type CafeCandidate,
	type CafeLocationInput,
	type CafeSearchProvider,
	type CafeSearchRequest,
	type GoogleCafeReference,
	type GoogleCafeReferenceProvider,
} from "./chat-meetup-providers";

const PLACES_NEARBY_URL = "https://places.googleapis.com/v1/places:searchNearby";
const PLACES_TEXT_URL = "https://places.googleapis.com/v1/places:searchText";
const ROUTE_MATRIX_URL = "https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix";
const PLACE_FIELD_MASK = [
	"places.id",
	"places.displayName",
	"places.formattedAddress",
	"places.location",
	"places.types",
	"places.businessStatus",
	"places.currentOpeningHours",
	"places.timeZone",
	"places.attributions",
	"places.googleMapsUri",
].join(",");
const STATION_FIELD_MASK = "places.id,places.displayName,places.location,places.types";
const PLACE_DETAILS_FIELD_MASK = [
	"id", "displayName", "formattedAddress", "location", "types", "businessStatus",
	"currentOpeningHours", "timeZone", "attributions", "googleMapsUri",
].join(",");
const ROUTE_FIELD_MASK = "originIndex,destinationIndex,duration,condition,status";
const GOOGLE_TIMEOUT_MS = 8_000;
const MAX_RESPONSE_BYTES = 256 * 1024;
const MAX_CAFE_RESULTS = 20;
const SEARCH_RADIUS_METERS = 15_000;
const DAY_MS = 24 * 60 * 60_000;
const SAFE_PROVIDER_ERROR = "Google cafe search is unavailable.";

const UtcTimestampSchema = z.string().datetime({ offset: false });
const IntervalSchema = z.object({
	starts_at: UtcTimestampSchema,
	ends_at: UtcTimestampSchema,
}).strict().refine((v) => Date.parse(v.starts_at) < Date.parse(v.ends_at));
const CoordinateLocationSchema = z.object({
	kind: z.literal("coordinates"),
	latitude: z.number().finite().min(-90).max(90),
	longitude: z.number().finite().min(-180).max(180),
	nearest_station: z.string().trim().min(1).max(120).optional(),
	nearby_station_names: z.array(z.string().trim().min(1).max(120)).max(16).optional(),
}).strict();
const StationLocationSchema = z.object({
	kind: z.literal("station"),
	station_name: z.string().trim().min(1).max(120),
	nearby_station_names: z.array(z.string().trim().min(1).max(120)).max(16).optional(),
}).strict();
const LocationSchema = z.discriminatedUnion("kind", [CoordinateLocationSchema, StationLocationSchema]);
const RequestSchema = z.object({
	first_participant: z.object({ consented: z.literal(true), location: LocationSchema }).strict(),
	second_participant: z.object({ consented: z.literal(true), location: LocationSchema }).strict(),
	time_options: z.array(IntervalSchema).length(1),
	duration_minutes: z.number().int().positive().max(24 * 60),
}).strict();

const LatLngSchema = z.object({
	latitude: z.number().finite().min(-90).max(90),
	longitude: z.number().finite().min(-180).max(180),
}).strict();
const LocalDateSchema = z.object({
	year: z.number().int().min(1).max(9999),
	month: z.number().int().min(1).max(12),
	day: z.number().int().min(1).max(31),
}).strict().refine((v) => {
	const date = new Date(Date.UTC(v.year, v.month - 1, v.day));
	return date.getUTCFullYear() === v.year && date.getUTCMonth() === v.month - 1 && date.getUTCDate() === v.day;
});
const OpeningPointSchema = z.object({
	date: LocalDateSchema,
	day: z.number().int().min(0).max(6),
	hour: z.number().int().min(0).max(23),
	minute: z.number().int().min(0).max(59),
	truncated: z.boolean().optional(),
}).passthrough().refine((v) => new Date(Date.UTC(v.date.year, v.date.month - 1, v.date.day)).getUTCDay() === v.day);
const OpeningPeriodSchema = z.object({
	open: OpeningPointSchema,
	close: OpeningPointSchema.optional().nullable(),
}).passthrough();
const CurrentOpeningHoursSchema = z.object({
	periods: z.array(OpeningPeriodSchema).max(100),
}).passthrough();
const PlaceAttributionSchema = z.object({
	provider: z.string().trim().min(1).max(120).refine((value) => !/[\u0000-\u001f\u007f\u2028\u2029]/u.test(value)),
	providerUri: z.string().url().max(2048).refine(isHttpsAttributionUri).optional(),
}).passthrough();
const GooglePlaceSchema = z.object({
	id: z.string().trim().min(1).max(220),
	displayName: z.object({ text: z.string().trim().min(1).max(120) }).passthrough(),
	formattedAddress: z.string().trim().min(1).max(300),
	location: LatLngSchema,
	types: z.array(z.string().min(1).max(100)).max(100),
	businessStatus: z.enum(["OPERATIONAL", "CLOSED_TEMPORARILY", "CLOSED_PERMANENTLY", "FUTURE_OPENING", "BUSINESS_STATUS_UNSPECIFIED"]),
	currentOpeningHours: CurrentOpeningHoursSchema.optional(),
	timeZone: z.object({ id: z.string().trim().min(1).max(128) }).passthrough().optional(),
	attributions: z.array(PlaceAttributionSchema).max(50).optional().default([]),
	googleMapsUri: z.string().url().max(2048).refine(isGoogleMapsUri),
}).passthrough();
const NearbyResponseSchema = z.object({ places: z.array(GooglePlaceSchema).max(MAX_CAFE_RESULTS) }).passthrough();
const StationResponseSchema = z.object({
	places: z.array(z.object({
		id: z.string().trim().min(1).max(220),
		displayName: z.object({ text: z.string().trim().min(1).max(120) }).passthrough(),
		location: LatLngSchema,
		types: z.array(z.string().min(1).max(100)).max(100),
	}).passthrough()).max(5),
}).passthrough();
const RouteMatrixElementSchema = z.object({
	originIndex: z.number().int().min(0).max(1),
	destinationIndex: z.number().int().min(0).max(MAX_CAFE_RESULTS - 1),
	condition: z.enum(["ROUTE_EXISTS", "ROUTE_NOT_FOUND"]),
	status: z.object({ code: z.number().int().optional() }).passthrough().optional(),
	duration: z.string().max(32).optional(),
}).passthrough();

/**
 * Google Places content is restricted. Legacy meetup projections persist
 * cafe names, addresses, hours, and route estimates, so this factory requires
 * an explicit review marker for transient projection, visible Google Maps
 * text attribution, and display of returned provider attributions. The additive
 * Google path persists only Place IDs and database-authored operation times.
 * Production route wiring remains closed pending a separate review.
 */
export interface GoogleCafeContentProjectionReview {
	contentRetention: "transient-place-content";
	googleMapsAttribution: "visible-text";
	providerAttributions: "displayed";
}

export interface GoogleCafeSearchBindings {
	/** Exact value `enabled` is required; absent and every other value stay closed. */
	GOOGLE_CAFE_SEARCH_ENABLED?: string;
	/** Server-only Google Maps Platform key, supplied as a runtime secret. */
	GOOGLE_MAPS_PLATFORM_API_KEY?: string;
}

export type GoogleCafeOperation = RecordingRehearsalGoogleOperation;
export type GoogleCafeReservationRequest = RecordingRehearsalGoogleCall;

export interface GoogleCafeSearchDependencies {
	fetchImpl?: typeof fetch;
	now?: () => Date;
	/** Trusted server config whose expiry is rechecked around provider waits. */
	recordingRehearsalConfig?: ValidatedRecordingRehearsalConfig;
	/** Reservation/admission guard called immediately before every paid fetch. */
	beforePaidRequest?: RecordingRehearsalGoogleReservationHook;
}

/**
 * Explicit factory for future reviewed route wiring. With no review marker,
 * no key, or anything except the exact opt-in value, this returns the no-op
 * provider. `chat-meetups.ts` intentionally does not call this yet.
 */
export function createGooglePlacesCafeSearchProvider(
	bindings: GoogleCafeSearchBindings,
	projectionReview?: GoogleCafeContentProjectionReview,
	dependencies: GoogleCafeSearchDependencies = {},
): CafeSearchProvider {
	const apiKey = bindings.GOOGLE_MAPS_PLATFORM_API_KEY?.trim();
	const reviewed = projectionReview?.contentRetention === "transient-place-content" &&
		projectionReview.googleMapsAttribution === "visible-text" &&
		projectionReview.providerAttributions === "displayed";
	const now = dependencies.now ?? (() => new Date());
	const currentTime = now();
	if (bindings.GOOGLE_CAFE_SEARCH_ENABLED !== "enabled" || !apiKey || !reviewed
		|| !dependencies.recordingRehearsalConfig
		|| !(currentTime instanceof Date)
		|| !isRecordingRehearsalActive(dependencies.recordingRehearsalConfig, currentTime.getTime())
		|| !dependencies.beforePaidRequest) {
		return unavailableGoogleCafeReferenceProvider;
	}
	return new GooglePlacesCafeSearchProvider(
		apiKey,
		dependencies.fetchImpl ?? fetch,
		now,
		dependencies.recordingRehearsalConfig,
		dependencies.beforePaidRequest,
	);
}

class GooglePlacesCafeSearchProvider implements GoogleCafeReferenceProvider {
	readonly availability = "configured" as const;
	readonly source = "google" as const;

	constructor(
		private readonly apiKey: string,
		private readonly fetchImpl: typeof fetch,
		private readonly now: () => Date,
		private readonly recordingRehearsalConfig: ValidatedRecordingRehearsalConfig,
		private readonly beforePaidRequest: RecordingRehearsalGoogleReservationHook,
	) {}

	private safeDiagnostic(reason: string, operation: string, httpStatus: number | null = null): void {
		if (this.recordingRehearsalConfig.pair !== "demo-maya-ren" || !this.recordingRehearsalConfig.syntheticTestAdmissionId || !this.isRehearsalActive()) return;
		if (!["reservation_denied", "network_error", "http_error", "response_invalid", "station_no_exact_match", "station_ambiguous", "opening_data_missing", "request_invalid", "window_inactive", "routes_invalid"].includes(reason)
			|| !["google_places_text_search", "google_places_nearby_search", "google_routes_matrix", "google_places_details"].includes(operation)
			|| (httpStatus !== null && (!Number.isInteger(httpStatus) || httpStatus < 100 || httpStatus > 599))) return;
		try { console.info(JSON.stringify({ reason, operation, http_status: httpStatus })); } catch { /* Diagnostics never change the provider result. */ }
	}

	async search(request: CafeSearchRequest): Promise<unknown> {
		const parsedRequest = RequestSchema.safeParse(request);
		if (!parsedRequest.success) { this.safeDiagnostic("request_invalid", "google_places_nearby_search"); throw new Error(SAFE_PROVIDER_ERROR); }
		const safeRequest = parsedRequest.data as CafeSearchRequest;
		const now = this.now();
		if (!(now instanceof Date) || !Number.isFinite(now.getTime())) { this.safeDiagnostic("window_inactive", "google_places_nearby_search"); throw new Error(SAFE_PROVIDER_ERROR); }
		const slot = safeRequest.time_options[0];
		const slotStart = Date.parse(slot.starts_at);
		const slotEnd = slotStart + safeRequest.duration_minutes * 60_000;
		if (slotStart <= now.getTime() || slotEnd > Date.parse(slot.ends_at) || slotEnd - now.getTime() > 8 * DAY_MS) {
			this.safeDiagnostic("request_invalid", "google_places_nearby_search"); throw new Error(SAFE_PROVIDER_ERROR);
		}

		const [firstOrigin, secondOrigin] = await Promise.all([
			this.resolveOrigin(safeRequest.first_participant.location),
			this.resolveOrigin(safeRequest.second_participant.location),
		]);
		let searchCenter: { latitude: number; longitude: number };
		try { searchCenter = geographicMidpoint(firstOrigin.location, secondOrigin.location); } catch { this.safeDiagnostic("request_invalid", "google_places_nearby_search"); throw new Error(SAFE_PROVIDER_ERROR); }
		const placesPayload = await this.postJson(PLACES_NEARBY_URL, PLACE_FIELD_MASK, {
			includedTypes: ["cafe"],
			maxResultCount: MAX_CAFE_RESULTS,
			rankPreference: "DISTANCE",
			locationRestriction: { circle: { center: searchCenter, radius: SEARCH_RADIUS_METERS } },
			languageCode: "en",
		}, "google_places_nearby_search");
		const placesParsed = NearbyResponseSchema.safeParse(placesPayload);
		if (!placesParsed.success) { this.safeDiagnostic("response_invalid", "google_places_nearby_search"); throw new Error(SAFE_PROVIDER_ERROR); }

		const openingCandidates: Array<{ place: z.infer<typeof GooglePlaceSchema>; opening: { starts_at: string; ends_at: string } }> = [];
		for (const place of placesParsed.data.places) {
			if (place.businessStatus !== "OPERATIONAL" || !place.types.includes("cafe")) continue;
			if (!place.currentOpeningHours || !place.timeZone) { this.safeDiagnostic("opening_data_missing", "google_places_nearby_search", null); throw new Error(SAFE_PROVIDER_ERROR); }
			let opening: { starts_at: string; ends_at: string } | null;
			try { opening = openingIntervalForSlot(place.currentOpeningHours, place.timeZone.id, slotStart, slotEnd, now.getTime()); } catch { this.safeDiagnostic("response_invalid", "google_places_nearby_search"); throw new Error(SAFE_PROVIDER_ERROR); }
			if (!opening) continue;
			if (distanceMeters(searchCenter, place.location) > SEARCH_RADIUS_METERS + 100) continue;
			openingCandidates.push({ place, opening });
		}
		if (openingCandidates.length === 0) return [];

		const routeTimes = await this.getTransitTimes(
			[firstOrigin, secondOrigin],
			openingCandidates.map(({ place }) => place),
			slot.starts_at,
		);
		return openingCandidates.map(({ place, opening }, destinationIndex): CafeCandidate => ({
			id: `google:${place.id}`,
			name: place.displayName.text,
			address: place.formattedAddress,
			starts_at: opening.starts_at,
			ends_at: opening.ends_at,
			travel_minutes_first: routeTimes.get(`0:${destinationIndex}`) ?? null,
			travel_minutes_second: routeTimes.get(`1:${destinationIndex}`) ?? null,
			verified_at: now.toISOString(),
			source: "google",
			google_maps_uri: place.googleMapsUri,
			attributions: place.attributions.map((item) => ({
				provider: item.provider,
				...(item.providerUri ? { provider_uri: item.providerUri } : {}),
			})),
		}));
	}

	async hydrateReference(reference: GoogleCafeReference): Promise<unknown | null> {
		const placeId = reference.id.startsWith("google:") ? reference.id.slice("google:".length) : "";
		const startsAt = Date.parse(reference.starts_at);
		const endsAt = Date.parse(reference.ends_at);
		const now = this.now();
		if (!(now instanceof Date) || !Number.isFinite(now.getTime()) || !/^[A-Za-z0-9_-]{1,220}$/u.test(placeId) || !Number.isFinite(startsAt) || !Number.isFinite(endsAt) || startsAt <= now.getTime() || endsAt <= startsAt || endsAt - startsAt > 24 * 60 * 60_000 || startsAt - now.getTime() > 8 * DAY_MS) return null;
		try {
			const place = await this.getPlaceDetails(placeId);
			if (place.businessStatus !== "OPERATIONAL" || !place.types.includes("cafe") || !place.currentOpeningHours || !place.timeZone) return null;
			if (!openingIntervalForSlot(place.currentOpeningHours, place.timeZone.id, startsAt, endsAt, now.getTime())) return null;
			return {
				id: `google:${place.id}`,
				name: place.displayName.text,
				address: place.formattedAddress,
				starts_at: new Date(startsAt).toISOString(),
				ends_at: new Date(endsAt).toISOString(),
				travel_minutes_first: null,
				travel_minutes_second: null,
				verified_at: now.toISOString(),
				source: "google",
				google_maps_uri: place.googleMapsUri,
				attributions: place.attributions.map((item) => ({
					provider: item.provider,
					...(item.providerUri ? { provider_uri: item.providerUri } : {}),
				})),
			};
		} catch {
			return null;
		}
	}

	async verifyReference(reference: GoogleCafeReference): Promise<boolean> {
		return (await this.hydrateReference(reference)) !== null;
	}

	private async resolveOrigin(location: CafeLocationInput): Promise<{ location: { latitude: number; longitude: number }; placeId?: string }> {
		if (location.kind === "coordinates") {
			return { location: { latitude: location.latitude, longitude: location.longitude } };
		}
		const payload = await this.postJson(PLACES_TEXT_URL, STATION_FIELD_MASK, {
			textQuery: location.station_name,
			includedType: "transit_station",
			strictTypeFiltering: true,
			pageSize: 5,
			regionCode: "JP",
			languageCode: "en",
		}, "google_places_text_search");
		const parsed = StationResponseSchema.safeParse(payload);
		if (!parsed.success) { this.safeDiagnostic("response_invalid", "google_places_text_search", null); throw new Error(SAFE_PROVIDER_ERROR); }
		const wanted = normalizeStationName(location.station_name);
		const exact = parsed.data.places.filter((place) =>
			place.types.includes("transit_station") && normalizeStationName(place.displayName.text) === wanted,
		);
		const unique = new Map(exact.map((place) => [place.id, place]));
		if (unique.size !== 1) { this.safeDiagnostic(unique.size === 0 ? "station_no_exact_match" : "station_ambiguous", "google_places_text_search", null); throw new Error(SAFE_PROVIDER_ERROR); }
		const place = unique.values().next().value;
		if (!place) { this.safeDiagnostic("station_no_exact_match", "google_places_text_search"); throw new Error(SAFE_PROVIDER_ERROR); }
		return { placeId: place.id, location: place.location };
	}

	private async getTransitTimes(
		origins: Array<{ location: { latitude: number; longitude: number }; placeId?: string }>,
		places: Array<z.infer<typeof GooglePlaceSchema>>,
		arrivalTime: string,
	): Promise<Map<string, number>> {
		const payload = await this.postJson(ROUTE_MATRIX_URL, ROUTE_FIELD_MASK, {
			origins: origins.map((origin) => ({ waypoint: origin.placeId
				? { placeId: origin.placeId }
				: { location: { latLng: origin.location } } })),
			destinations: places.map((place) => ({ waypoint: { placeId: place.id } })),
			travelMode: "TRANSIT",
			arrivalTime,
			transitPreferences: { routingPreference: "FEWER_TRANSFERS" },
			languageCode: "en",
		}, "google_routes_matrix", origins.length * places.length);
		if (!Array.isArray(payload) || payload.length !== origins.length * places.length) { this.safeDiagnostic("routes_invalid", "google_routes_matrix"); throw new Error(SAFE_PROVIDER_ERROR); }
		const expectedKeys = new Set<string>();
		const times = new Map<string, number>();
		for (const raw of payload) {
			const parsed = RouteMatrixElementSchema.safeParse(raw);
			if (!parsed.success) { this.safeDiagnostic("routes_invalid", "google_routes_matrix"); throw new Error(SAFE_PROVIDER_ERROR); }
			const item = parsed.data;
			const key = `${item.originIndex}:${item.destinationIndex}`;
			if (item.originIndex >= origins.length || item.destinationIndex >= places.length || expectedKeys.has(key)) { this.safeDiagnostic("routes_invalid", "google_routes_matrix"); throw new Error(SAFE_PROVIDER_ERROR); }
			expectedKeys.add(key);
			if (item.condition === "ROUTE_NOT_FOUND") continue;
			if (item.status?.code !== undefined && item.status.code !== 0) { this.safeDiagnostic("routes_invalid", "google_routes_matrix"); throw new Error(SAFE_PROVIDER_ERROR); }
			const duration = item.duration?.match(/^(\d+(?:\.\d+)?)s$/u);
			if (!duration) { this.safeDiagnostic("routes_invalid", "google_routes_matrix"); throw new Error(SAFE_PROVIDER_ERROR); }
			const seconds = Number(duration[1]);
			if (!Number.isFinite(seconds) || seconds < 0 || seconds > 24 * 60 * 60) { this.safeDiagnostic("routes_invalid", "google_routes_matrix"); throw new Error(SAFE_PROVIDER_ERROR); }
			times.set(key, Math.ceil(seconds / 60));
		}
		if (expectedKeys.size !== origins.length * places.length) { this.safeDiagnostic("routes_invalid", "google_routes_matrix"); throw new Error(SAFE_PROVIDER_ERROR); }
		return times;
	}

	private isRehearsalActive(): boolean {
		const now = this.now();
		return now instanceof Date && isRecordingRehearsalActive(this.recordingRehearsalConfig, now.getTime());
	}

	private async postJson(url: string, fieldMask: string, body: unknown, operation: GoogleCafeOperation, units = 1): Promise<unknown> {
		let response: Response;
		let fetchStarted = false;
		try {
			if (!await this.reserve(operation, units) || !this.isRehearsalActive()) { this.safeDiagnostic("reservation_denied", operation); throw new Error(SAFE_PROVIDER_ERROR); }
			fetchStarted = true;
			response = await this.fetchImpl.call(globalThis,url, {
				method: "POST",
				headers: {
					"Content-Type": "application/json",
					"X-Goog-Api-Key": this.apiKey,
					"X-Goog-FieldMask": fieldMask,
				},
				body: JSON.stringify(body),
				redirect: "manual",
				signal: AbortSignal.timeout(GOOGLE_TIMEOUT_MS),
			});
			if (!this.isRehearsalActive()) throw new Error(SAFE_PROVIDER_ERROR);
		} catch {
			if (fetchStarted) this.safeDiagnostic("network_error", operation);
			throw new Error(SAFE_PROVIDER_ERROR);
		}
		if (!response.ok) { await response.body?.cancel(); this.safeDiagnostic("http_error", operation, response.status); throw new Error(SAFE_PROVIDER_ERROR); }
		let payload: unknown;
		try { payload = await this.readJsonResponse(response); } catch { this.safeDiagnostic("response_invalid", operation, response.status); throw new Error(SAFE_PROVIDER_ERROR); }
		if (!this.isRehearsalActive()) throw new Error(SAFE_PROVIDER_ERROR);
		return payload;
	}

	private async getPlaceDetails(placeId: string): Promise<z.infer<typeof GooglePlaceSchema>> {
		const url = "https://places.googleapis.com/v1/places/" + encodeURIComponent(placeId);
		let response: Response;
		let fetchStarted = false;
		try {
			if (!await this.reserve("google_places_details", 1) || !this.isRehearsalActive()) { this.safeDiagnostic("reservation_denied", "google_places_details"); throw new Error(SAFE_PROVIDER_ERROR); }
			fetchStarted = true;
			response = await this.fetchImpl.call(globalThis,url, {
				method: "GET",
				headers: { "X-Goog-Api-Key": this.apiKey, "X-Goog-FieldMask": PLACE_DETAILS_FIELD_MASK },
				redirect: "manual",
				signal: AbortSignal.timeout(GOOGLE_TIMEOUT_MS),
			});
			if (!this.isRehearsalActive()) throw new Error(SAFE_PROVIDER_ERROR);
		} catch {
			if (fetchStarted) this.safeDiagnostic("network_error", "google_places_details");
			throw new Error(SAFE_PROVIDER_ERROR);
		}
		if (!response.ok) { await response.body?.cancel(); this.safeDiagnostic("http_error", "google_places_details", response.status); throw new Error(SAFE_PROVIDER_ERROR); }
		let payload: unknown;
		try { payload = await this.readJsonResponse(response); } catch { this.safeDiagnostic("response_invalid", "google_places_details", response.status); throw new Error(SAFE_PROVIDER_ERROR); }
		if (!this.isRehearsalActive()) throw new Error(SAFE_PROVIDER_ERROR);
		const parsed = GooglePlaceSchema.safeParse(payload);
		if (!parsed.success || parsed.data.id !== placeId) { this.safeDiagnostic("response_invalid", "google_places_details"); throw new Error(SAFE_PROVIDER_ERROR); }
		return parsed.data;
	}

	private async reserve(operation: GoogleCafeOperation, units: number): Promise<boolean> {
		if (!this.isRehearsalActive() || !Number.isInteger(units) || units < 1 || units > 100 || typeof globalThis.crypto?.randomUUID !== "function") return false;
		try {
			return await this.beforePaidRequest({ operation, units, idempotencyKey: globalThis.crypto.randomUUID() });
		} catch {
			return false;
		}
	}

	private async readJsonResponse(response: Response): Promise<unknown> {
		if (!response.ok || !/^application\/json(?:\s*;|$)/iu.test(response.headers.get("content-type") ?? "")) {
			throw new Error(SAFE_PROVIDER_ERROR);
		}
		const reader = response.body?.getReader();
		if (!reader) throw new Error(SAFE_PROVIDER_ERROR);
		const chunks: Uint8Array[] = [];
		let size = 0;
		try {
			while (true) {
				const { done, value } = await reader.read();
				if (done) break;
				size += value.byteLength;
				if (size > MAX_RESPONSE_BYTES) {
					void reader.cancel().catch(() => undefined);
					throw new Error(SAFE_PROVIDER_ERROR);
				}
				chunks.push(value);
			}
		} catch {
			throw new Error(SAFE_PROVIDER_ERROR);
		} finally {
			reader.releaseLock();
		}
		const bytes = new Uint8Array(size);
		let offset = 0;
		for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
		try {
			return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as unknown;
		} catch {
			throw new Error(SAFE_PROVIDER_ERROR);
		}
	}
}

function isHttpsAttributionUri(value: string): boolean {
	try {
		const uri = new URL(value);
		return uri.protocol === "https:" && !uri.username && !uri.password && (!uri.port || uri.port === "443");
	} catch {
		return false;
	}
}

function isGoogleMapsUri(value: string): boolean {
	try {
		const uri = new URL(value);
		if (!isHttpsAttributionUri(value)) return false;
		if (uri.hostname === "maps.google.com") return true;
		return ["google.com", "www.google.com"].includes(uri.hostname) && /^\/maps(?:\/|$)/u.test(uri.pathname);
	} catch {
		return false;
	}
}

function normalizeStationName(value: string): string {
	return value.normalize("NFKC").trim().replace(/[.,]/gu, "").replace(/\s+/gu, " ").toLocaleLowerCase("en-US");
}

function geographicMidpoint(first: { latitude: number; longitude: number }, second: { latitude: number; longitude: number }): { latitude: number; longitude: number } {
	const toRadians = (degrees: number) => degrees * Math.PI / 180;
	const toDegrees = (radians: number) => radians * 180 / Math.PI;
	const lat1 = toRadians(first.latitude); const lon1 = toRadians(first.longitude);
	const lat2 = toRadians(second.latitude); const lon2 = toRadians(second.longitude);
	const x = Math.cos(lat1) * Math.cos(lon1) + Math.cos(lat2) * Math.cos(lon2);
	const y = Math.cos(lat1) * Math.sin(lon1) + Math.cos(lat2) * Math.sin(lon2);
	const z = Math.sin(lat1) + Math.sin(lat2);
	const norm = Math.hypot(x, y, z);
	if (!Number.isFinite(norm) || norm < 1e-8) throw new Error(SAFE_PROVIDER_ERROR);
	return { latitude: toDegrees(Math.atan2(z, Math.hypot(x, y))), longitude: toDegrees(Math.atan2(y, x)) };
}

function distanceMeters(first: { latitude: number; longitude: number }, second: { latitude: number; longitude: number }): number {
	const radians = (degrees: number) => degrees * Math.PI / 180;
	const lat1 = radians(first.latitude); const lat2 = radians(second.latitude);
	const latDelta = lat2 - lat1; const lonDelta = radians(second.longitude - first.longitude);
	const haversine = Math.sin(latDelta / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(lonDelta / 2) ** 2;
	return 6_371_000 * 2 * Math.atan2(Math.sqrt(haversine), Math.sqrt(Math.max(0, 1 - haversine)));
}

type CivilDate = { year: number; month: number; day: number };
type CivilDateTime = CivilDate & { hour: number; minute: number };

function zonedParts(epochMs: number, timeZone: string): CivilDateTime & { second: number } {
	const formatter = new Intl.DateTimeFormat("en-US", {
		timeZone, year: "numeric", month: "2-digit", day: "2-digit",
		hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
	});
	const values = Object.fromEntries(formatter.formatToParts(new Date(epochMs)).map((part) => [part.type, part.value]));
	return {
		year: Number(values.year), month: Number(values.month), day: Number(values.day),
		hour: Number(values.hour), minute: Number(values.minute), second: Number(values.second),
	};
}

function sameCivil(value: CivilDateTime & { second: number }, expected: CivilDateTime): boolean {
	return value.year === expected.year && value.month === expected.month && value.day === expected.day && value.hour === expected.hour && value.minute === expected.minute && value.second === 0;
}

/** Convert local opening-hours wall time to UTC only when it has one exact instant. */
function localDateTimeToEpoch(value: CivilDateTime, timeZone: string): number | null {
	const wallAsUtc = Date.UTC(value.year, value.month - 1, value.day, value.hour, value.minute);
	const offsets = new Set<number>();
	try {
		for (let delta = -36; delta <= 36; delta += 3) {
			const probe = wallAsUtc + delta * 60 * 60_000;
			const local = zonedParts(probe, timeZone);
			const localAsUtc = Date.UTC(local.year, local.month - 1, local.day, local.hour, local.minute, local.second);
			offsets.add(localAsUtc - probe);
		}
	} catch {
		throw new Error(SAFE_PROVIDER_ERROR);
	}
	const matches = new Set<number>();
	for (const offset of offsets) {
		const instant = wallAsUtc - offset;
		try { if (sameCivil(zonedParts(instant, timeZone), value)) matches.add(instant); }
		catch { throw new Error(SAFE_PROVIDER_ERROR); }
	}
	return matches.size === 1 ? matches.values().next().value ?? null : null;
}

function localDateForEpoch(epochMs: number, timeZone: string): CivilDate {
	const { year, month, day } = zonedParts(epochMs, timeZone);
	return { year, month, day };
}

function civilDayNumber(value: CivilDate): number {
	return Math.floor(Date.UTC(value.year, value.month - 1, value.day) / DAY_MS);
}

function openingIntervalForSlot(
	hours: z.infer<typeof CurrentOpeningHoursSchema>,
	timeZone: string,
	slotStart: number,
	slotEnd: number,
	verifiedAt: number,
): { starts_at: string; ends_at: string } | null {
	let today: CivilDate;
	let startDate: CivilDate;
	let endDate: CivilDate;
	try {
		today = localDateForEpoch(verifiedAt, timeZone);
		startDate = localDateForEpoch(slotStart, timeZone);
		endDate = localDateForEpoch(slotEnd, timeZone);
	} catch {
		throw new Error(SAFE_PROVIDER_ERROR);
	}
	const todayNumber = civilDayNumber(today);
	if (civilDayNumber(startDate) < todayNumber || civilDayNumber(startDate) > todayNumber + 6 || civilDayNumber(endDate) > todayNumber + 6) return null;
	for (const period of hours.periods) {
		if (!period.close || period.open.truncated || period.close.truncated) continue;
		const open = localDateTimeToEpoch({ ...period.open.date, hour: period.open.hour, minute: period.open.minute }, timeZone);
		const close = localDateTimeToEpoch({ ...period.close.date, hour: period.close.hour, minute: period.close.minute }, timeZone);
		if (open === null || close === null || close <= open) continue;
		if (open <= slotStart && close >= slotEnd) return { starts_at: new Date(open).toISOString(), ends_at: new Date(close).toISOString() };
	}
	return null;
}
