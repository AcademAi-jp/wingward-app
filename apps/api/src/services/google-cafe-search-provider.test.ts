import { describe, expect, it, vi } from "vitest";
import { isGoogleCafeReferenceProvider, searchFairCafeCandidates, type CafeSearchRequest } from "./chat-meetup-providers";
import { createGooglePlacesCafeSearchProvider, type GoogleCafeContentProjectionReview } from "./google-cafe-search-provider";
import { readRecordingRehearsalConfig } from "./recording-rehearsal";

const NOW = new Date("2026-09-26T09:00:00.000Z");
const TOKYO_NOW = new Date("2026-09-26T00:00:00.000Z");
const PROJECTION_REVIEW: GoogleCafeContentProjectionReview = {
	contentRetention: "transient-place-content",
	googleMapsAttribution: "visible-text",
	providerAttributions: "displayed",
};
function rehearsalConfigAt(now: Date) {
	const result = readRecordingRehearsalConfig({
		RECORDING_REHEARSAL_ENABLED: "enabled",
		RECORDING_REHEARSAL_ISSUED_AT: new Date(now.getTime() - 60_000).toISOString(),
		RECORDING_REHEARSAL_EXPIRES_AT: new Date(now.getTime() + 60 * 60_000).toISOString(),
		RECORDING_REHEARSAL_PAIR: "aoi-ren",
	}, now.getTime());
	if (result.kind !== "active") throw new Error("Test rehearsal config must be valid.");
	return result.config;
}
const TEST_REHEARSAL_CONFIG = rehearsalConfigAt(NOW);
const BASE_REQUEST: CafeSearchRequest = {
	first_participant: { consented: true, location: { kind: "coordinates", latitude: 37.77, longitude: -122.42 } },
	second_participant: { consented: true, location: { kind: "coordinates", latitude: 37.80, longitude: -122.40 } },
	time_options: [{ starts_at: "2026-09-26T17:00:00.000Z", ends_at: "2026-09-26T19:00:00.000Z" }],
	duration_minutes: 60,
};

function place(id: string, closeHour = 12, overrides: Record<string, unknown> = {}) {
	return {
		id,
		displayName: { text: `Cafe ${id}` },
		formattedAddress: "10 Sample Street, San Francisco, CA",
		location: { latitude: 37.785, longitude: -122.41 },
		types: ["cafe", "food"],
		businessStatus: "OPERATIONAL",
		timeZone: { id: "America/Los_Angeles" },
		currentOpeningHours: {
			periods: [{
				open: { date: { year: 2026, month: 9, day: 26 }, day: 6, hour: 9, minute: 0 },
				close: { date: { year: 2026, month: 9, day: 26 }, day: 6, hour: closeHour, minute: 0 },
			}],
		},
		attributions: [],
		googleMapsUri: "https://www.google.com/maps/place/" + encodeURIComponent(id),
		...overrides,
	};
}

const TOKYO_REQUEST: CafeSearchRequest = {
	first_participant: { consented: true, location: { kind: "coordinates", latitude: 35.6812, longitude: 139.7671 } },
	second_participant: { consented: true, location: { kind: "coordinates", latitude: 35.658, longitude: 139.7016 } },
	time_options: [{ starts_at: "2026-09-26T01:00:00.000Z", ends_at: "2026-09-26T03:00:00.000Z" }],
	duration_minutes: 60,
};

function tokyoPlace(id: string) {
	return place(id, 14, {
		formattedAddress: "1 Chome, Shibuya, Tokyo, Japan",
		location: { latitude: 35.67, longitude: 139.73 },
		timeZone: { id: "Asia/Tokyo" },
		currentOpeningHours: { periods: [{
			open: { date: { year: 2026, month: 9, day: 26 }, day: 6, hour: 9, minute: 0 },
			close: { date: { year: 2026, month: 9, day: 26 }, day: 6, hour: 14, minute: 0 },
		}] },
	});
}

function jsonResponse(body: unknown): Response {
	return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json; charset=utf-8" } });
}

function makeFetcher(options: { places?: unknown; routes?: unknown; stations?: unknown; details?: unknown } = {}) {
	const calls: Array<{ url: string; init: RequestInit }> = [];
	const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
		const url = String(input);
		const requestInit = init ?? {};
		calls.push({ url, init: requestInit });
		if (url === "https://places.googleapis.com/v1/places:searchNearby") return jsonResponse(options.places ?? { places: [place("ChI-cafe-1")] });
		if (url === "https://places.googleapis.com/v1/places:searchText") return jsonResponse(options.stations ?? { places: [] });
		if (url === "https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix") return jsonResponse(options.routes ?? [
			{ originIndex: 1, destinationIndex: 0, condition: "ROUTE_EXISTS", status: { code: 0 }, duration: "1500s" },
			{ originIndex: 0, destinationIndex: 0, condition: "ROUTE_EXISTS", status: { code: 0 }, duration: "1200s" },
		]);
		if (url.startsWith("https://places.googleapis.com/v1/places/") && requestInit.method === "GET") {
			return jsonResponse(options.details ?? place(decodeURIComponent(url.split("/").at(-1) ?? "ChI-detail")));
		}
		throw new Error("Unexpected test URL");
	});
	return { fetchImpl, calls };
}

function configuredProvider(
	fetchImpl: typeof fetch,
	request: Partial<{ enabled: string; key: string }> = {},
	now = NOW,
	beforePaidRequest: (request: { operation: string; units: number; idempotencyKey: string }) => Promise<boolean> = async () => true,
) {
	return createGooglePlacesCafeSearchProvider({
		GOOGLE_CAFE_SEARCH_ENABLED: request.enabled ?? "enabled",
		GOOGLE_MAPS_PLATFORM_API_KEY: request.key ?? "unit-test-key",
	}, PROJECTION_REVIEW, {
		fetchImpl,
		now: () => new Date(now),
		recordingRehearsalConfig: rehearsalConfigAt(now),
		beforePaidRequest,
	});
}

function bodyAt(calls: Array<{ url: string; init: RequestInit }>, url: string): Record<string, unknown> {
	const found = calls.find((call) => call.url === url);
	if (!found || typeof found.init.body !== "string") throw new Error("Test request body missing");
	return JSON.parse(found.init.body) as Record<string, unknown>;
}

describe("Google Places cafe adapter", () => {
	it.each([
		["missing gate", undefined, "unit-test-key", undefined],
		["non-exact gate", "true", "unit-test-key", PROJECTION_REVIEW],
		["missing key", "enabled", undefined, PROJECTION_REVIEW],
		["missing content/attribution review", "enabled", "unit-test-key", undefined],
	])("stays unavailable and performs no fetch when %s", async (_label, enabled, key, projection) => {
		const { fetchImpl } = makeFetcher();
		const provider = createGooglePlacesCafeSearchProvider({ GOOGLE_CAFE_SEARCH_ENABLED: enabled, GOOGLE_MAPS_PLATFORM_API_KEY: key }, projection, { fetchImpl, now: () => new Date(NOW), beforePaidRequest: async () => true });
		expect(provider.availability).toBe("unavailable");
		await expect(provider.search(BASE_REQUEST)).rejects.toThrow("Cafe search provider is not configured.");
		expect(fetchImpl).not.toHaveBeenCalled();
	});

	it("reserves each paid request before fetch and fails closed when reservation is denied", async () => {
		const { fetchImpl } = makeFetcher();
		const reservations: Array<{ operation: string; units: number }> = [];
		const provider = configuredProvider(fetchImpl, {}, NOW, async (request) => {
			reservations.push(request);
			return false;
		});
		await expect(searchFairCafeCandidates(provider, BASE_REQUEST, NOW)).resolves.toEqual({ status: "unavailable", reason: "provider_error" });
		expect(reservations).toHaveLength(1);
		expect(reservations[0]).toMatchObject({ operation: "google_places_nearby_search", units: 1 });
		expect(fetchImpl).not.toHaveBeenCalled();
	});

	it.each([301,302,303,307,308])("rejects vendor redirect %s without sending keys to Location",async status=>{
		const cancel=vi.fn();const fetchImpl=vi.fn(async(_url:RequestInfo|URL,_init?:RequestInit)=>new Response(new ReadableStream({cancel}),{status,headers:{Location:"https://untrusted.invalid/SYNTHETIC_SECRET"}}));
		await expect(configuredProvider(fetchImpl).search(BASE_REQUEST)).rejects.toThrow();
		expect(fetchImpl).toHaveBeenCalledOnce();expect(fetchImpl.mock.calls[0][1]!.redirect).toBe("manual");expect(cancel).toHaveBeenCalledOnce();
	});

	it("uses mocked Google responses, validates a full future opening interval, and orders measured transit fairly", async () => {
		const { fetchImpl, calls } = makeFetcher({
			places: { places: [place("ChI-cafe-1"), place("ChI-closes-before-slot", 10)] },
		});
		const provider = configuredProvider(fetchImpl);
		const result = await searchFairCafeCandidates(provider, BASE_REQUEST, NOW);

		expect(result.status).toBe("available");
		if (result.status !== "available") return;
		expect(result.candidates).toEqual([{
			id: "google:ChI-cafe-1",
			name: "Cafe ChI-cafe-1",
			address: "10 Sample Street, San Francisco, CA",
			starts_at: "2026-09-26T16:00:00.000Z",
			ends_at: "2026-09-26T19:00:00.000Z",
			travel_minutes_first: 20,
			travel_minutes_second: 25,
			verified_at: NOW.toISOString(),
			source: "google",
			google_maps_uri: "https://www.google.com/maps/place/ChI-cafe-1",
			attributions: [],
		}]);
		expect(calls).toHaveLength(2);
		const placesRequest = calls[0];
		expect(placesRequest.url).toBe("https://places.googleapis.com/v1/places:searchNearby");
		expect(placesRequest.init.redirect).toBe("manual");
		expect(fetchImpl.mock.contexts.every(value=>value===globalThis)).toBe(true);
		expect(new URL(placesRequest.url).searchParams.size).toBe(0);
		expect((placesRequest.init.headers as Record<string, string>)["X-Goog-Api-Key"]).toBe("unit-test-key");
		expect((placesRequest.init.headers as Record<string, string>)["X-Goog-FieldMask"]).toContain("places.currentOpeningHours");
		expect(bodyAt(calls, placesRequest.url)).toMatchObject({ includedTypes: ["cafe"], maxResultCount: 20, rankPreference: "DISTANCE" });
		const routeRequest = calls.find((call) => call.url.includes("computeRouteMatrix"));
		expect(routeRequest).toBeDefined();
		expect((routeRequest?.init.headers as Record<string, string>)["X-Goog-FieldMask"]).toBe("originIndex,destinationIndex,duration,condition,status");
		expect(bodyAt(calls, routeRequest?.url ?? "")).toMatchObject({ travelMode: "TRANSIT", arrivalTime: BASE_REQUEST.time_options[0].starts_at });
	});

	it("validates a Tokyo cafe opening interval from mocked Google responses", async () => {
		const { fetchImpl, calls } = makeFetcher({ places: { places: [tokyoPlace("ChI-tokyo-cafe")] } });
		const result = await searchFairCafeCandidates(configuredProvider(fetchImpl, {}, TOKYO_NOW), TOKYO_REQUEST, TOKYO_NOW);

		expect(result).toEqual({
			status: "available",
			candidates: [{
				id: "google:ChI-tokyo-cafe",
				name: "Cafe ChI-tokyo-cafe",
				address: "1 Chome, Shibuya, Tokyo, Japan",
				starts_at: "2026-09-26T00:00:00.000Z",
				ends_at: "2026-09-26T05:00:00.000Z",
				travel_minutes_first: 20,
				travel_minutes_second: 25,
				verified_at: TOKYO_NOW.toISOString(),
				source: "google",
				google_maps_uri: "https://www.google.com/maps/place/ChI-tokyo-cafe",
				attributions: [],
			}],
		});
		expect(calls).toHaveLength(2);
	});

	it("freshly hydrates a persisted reference with details only and reserves each paid request", async () => {
		const { fetchImpl, calls } = makeFetcher({ details: place("ChI-reference") });
		const reservations: Array<{ operation: string; units: number; idempotencyKey: string }> = [];
		const provider = configuredProvider(fetchImpl, {}, NOW, async (request) => {
			reservations.push(request);
			return true;
		});
		if (!isGoogleCafeReferenceProvider(provider)) throw new Error("Configured adapter should support reference hydration.");
		const hydrated = await provider.hydrateReference({
			id: "google:ChI-reference",
			starts_at: "2026-09-26T17:00:00.000Z",
			ends_at: "2026-09-26T19:00:00.000Z",
		});
		expect(hydrated).toMatchObject({
			id: "google:ChI-reference",
			starts_at: "2026-09-26T17:00:00.000Z",
			ends_at: "2026-09-26T19:00:00.000Z",
			travel_minutes_first: null,
			travel_minutes_second: null,
			source: "google",
		});
		expect(calls).toHaveLength(1);
		expect(calls[0].url).toBe("https://places.googleapis.com/v1/places/ChI-reference");
		expect(calls[0].init.method).toBe("GET");
		expect(reservations).toHaveLength(1);
		expect(reservations[0]).toMatchObject({ operation: "google_places_details", units: 1 });
		expect(reservations[0].idempotencyKey).toMatch(/^[0-9a-f-]{36}$/iu);
	});

	it("stops processing when the trusted rehearsal window expires during a provider response", async () => {
		let currentTime = new Date(NOW);
		const calls: Array<{ url: string; init: RequestInit }> = [];
		const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
			calls.push({ url: String(input), init: init ?? {} });
			currentTime = new Date(TEST_REHEARSAL_CONFIG.expiresAtMs);
			return jsonResponse({ places: [place("ChI-expiring-window")] });
		});
		const provider = createGooglePlacesCafeSearchProvider({
			GOOGLE_CAFE_SEARCH_ENABLED: "enabled",
			GOOGLE_MAPS_PLATFORM_API_KEY: "unit-test-key",
		}, PROJECTION_REVIEW, {
			fetchImpl,
			now: () => currentTime,
			recordingRehearsalConfig: TEST_REHEARSAL_CONFIG,
			beforePaidRequest: async () => true,
		});

		await expect(searchFairCafeCandidates(provider, BASE_REQUEST, NOW)).resolves.toEqual({ status: "unavailable", reason: "provider_error" });
		expect(calls).toHaveLength(1);
	});

	it("resolves a station only from one exact typed Places match and sends that place ID to Routes", async () => {
		const stations = { places: [{
			id: "Station-001", displayName: { text: "Embarcadero Station" },
			location: { latitude: 37.7929, longitude: -122.3971 }, types: ["transit_station"],
		}] };
		const request: CafeSearchRequest = {
			...BASE_REQUEST,
			first_participant: { consented: true, location: { kind: "station", station_name: "Embarcadero Station" } },
		};
		const { fetchImpl, calls } = makeFetcher({ stations });
		await expect(searchFairCafeCandidates(configuredProvider(fetchImpl), request, NOW)).resolves.toMatchObject({ status: "available" });
		const stationQuery = bodyAt(calls, "https://places.googleapis.com/v1/places:searchText");
		expect(stationQuery).toMatchObject({ textQuery: "Embarcadero Station", includedType: "transit_station", strictTypeFiltering: true, regionCode: "JP" });
		const routeBody = bodyAt(calls, "https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix");
		expect(routeBody.origins).toEqual([
			{ waypoint: { placeId: "Station-001" } },
			{ waypoint: { location: { latLng: { latitude: 37.8, longitude: -122.4 } } } },
		]);
	});

	it("rejects ambiguous station results without searching for cafes or computing routes", async () => {
		const stations = { places: [
			{ id: "Station-001", displayName: { text: "Central Station" }, location: { latitude: 1, longitude: 1 }, types: ["transit_station"] },
			{ id: "Station-002", displayName: { text: "Central Station" }, location: { latitude: 2, longitude: 2 }, types: ["transit_station"] },
		] };
		const request: CafeSearchRequest = {
			...BASE_REQUEST,
			first_participant: { consented: true, location: { kind: "station", station_name: "Central Station" } },
		};
		const { fetchImpl, calls } = makeFetcher({ stations });
		const result = await searchFairCafeCandidates(configuredProvider(fetchImpl), request, NOW);
		expect(result).toEqual({ status: "unavailable", reason: "provider_error" });
		expect(calls).toHaveLength(1);
		expect(calls[0].url).toBe("https://places.googleapis.com/v1/places:searchText");
	});

	it("does not return a cafe that closes before the requested meeting ends", async () => {
		const configuredPlace = place("ChI-short-hours", 10, {
			currentOpeningHours: { periods: [{
				open: { date: { year: 2026, month: 9, day: 26 }, day: 6, hour: 9, minute: 0 },
				close: { date: { year: 2026, month: 9, day: 26 }, day: 6, hour: 10, minute: 59 },
			}] },
		});
		const { fetchImpl, calls } = makeFetcher({ places: { places: [configuredPlace] } });
		const result = await searchFairCafeCandidates(configuredProvider(fetchImpl), BASE_REQUEST, NOW);
		expect(result).toEqual({ status: "available", candidates: [] });
		expect(calls).toHaveLength(1);
	});

	it("fails closed when current opening hours are absent", async () => {
		const configuredPlace = place("ChI-unknown-hours");
		delete (configuredPlace as { currentOpeningHours?: unknown }).currentOpeningHours;
		const { fetchImpl, calls } = makeFetcher({ places: { places: [configuredPlace] } });
		const result = await searchFairCafeCandidates(configuredProvider(fetchImpl), BASE_REQUEST, NOW);
		expect(result).toEqual({ status: "unavailable", reason: "provider_error" });
		expect(calls).toHaveLength(1);
	});

	it("rejects results outside the requested search circle", async () => {
		const { fetchImpl, calls } = makeFetcher({ places: { places: [place("ChI-far", 12, { location: { latitude: 38.2, longitude: -122.9 } })] } });
		const result = await searchFairCafeCandidates(configuredProvider(fetchImpl), BASE_REQUEST, NOW);
		expect(result).toEqual({ status: "available", candidates: [] });
		expect(calls).toHaveLength(1);
	});

	it("fails closed for an incomplete route matrix instead of fabricating either travel duration", async () => {
		const { fetchImpl } = makeFetcher({ routes: [{ originIndex: 0, destinationIndex: 0, condition: "ROUTE_EXISTS", status: { code: 0 }, duration: "600s" }] });
		await expect(searchFairCafeCandidates(configuredProvider(fetchImpl), BASE_REQUEST, NOW)).resolves.toEqual({ status: "unavailable", reason: "provider_error" });
	});

	it("preserves bounded Google and third-party attribution fields", async () => {
		const { fetchImpl } = makeFetcher({ places: { places: [place("ChI-attributed", 12, { attributions: [{ provider: "Sample Provider", providerUri: "https://provider.example.com/source" }] })] } });
		const result = await searchFairCafeCandidates(configuredProvider(fetchImpl), BASE_REQUEST, NOW);
		expect(result).toMatchObject({
			status: "available",
			candidates: [{
				source: "google",
				google_maps_uri: "https://www.google.com/maps/place/ChI-attributed",
				attributions: [{ provider: "Sample Provider", provider_uri: "https://provider.example.com/source" }],
			}],
		});
	});

	it("rejects control characters in third-party attribution labels", async () => {
		const { fetchImpl, calls } = makeFetcher({
			places: { places: [place("ChI-control-attribution", 12, { attributions: [{ provider: "Sample\u0000Provider" }] })] },
		});
		await expect(searchFairCafeCandidates(configuredProvider(fetchImpl), BASE_REQUEST, NOW)).resolves.toEqual({ status: "unavailable", reason: "provider_error" });
		expect(calls).toHaveLength(1);
	});

	it("bounds response bodies and hides provider error text", async () => {
		const fetchImpl = vi.fn(async () => new Response("x".repeat(256 * 1024 + 1), { status: 200, headers: { "Content-Type": "application/json" } }));
		const provider = configuredProvider(fetchImpl as typeof fetch);
		await expect(searchFairCafeCandidates(provider, BASE_REQUEST, NOW)).resolves.toEqual({ status: "unavailable", reason: "provider_error" });

		const rejectedFetch = vi.fn(async () => { throw new Error("key=never-reflect-this"); });
		const rejected = configuredProvider(rejectedFetch as typeof fetch);
		const error = await searchFairCafeCandidates(rejected, BASE_REQUEST, NOW);
		expect(error).toEqual({ status: "unavailable", reason: "provider_error" });
		expect(JSON.stringify(error)).not.toContain("never-reflect-this");
	});
});


describe("Synthetic filming provider diagnostics", () => {
  function diagnosticProvider(fetchImpl: typeof fetch, reserve = true, active = true) {
    const now = Date.now();
    const c = readRecordingRehearsalConfig({ RECORDING_REHEARSAL_ENABLED: "enabled", RECORDING_REHEARSAL_PAIR: "demo-maya-ren", RECORDING_REHEARSAL_ISSUED_AT: new Date(now - 60000).toISOString(), RECORDING_REHEARSAL_EXPIRES_AT: new Date(now + 3600000).toISOString(), RECORDING_REHEARSAL_SYNTHETIC_TEST_ADMISSION_ID: "f28c91f0-2230-48a3-b9d0-61c80c9ba1ec" }, now);
    if (c.kind !== "active") throw new Error("Expected synthetic test config");
    return createGooglePlacesCafeSearchProvider({ GOOGLE_CAFE_SEARCH_ENABLED: "enabled", GOOGLE_MAPS_PLATFORM_API_KEY: "never-log-secret" }, PROJECTION_REVIEW, { now: () => new Date(active ? now : now+7200000), recordingRehearsalConfig: c.config, fetchImpl, beforePaidRequest: async () => reserve });
  }
  const stationRequest = () => ({ first_participant: { consented: true as const, location: { kind: "station" as const, station_name: "Ginza Station, Tokyo" } }, second_participant: BASE_REQUEST.second_participant, time_options: [{ starts_at: new Date(Date.now()+3600000).toISOString(), ends_at: new Date(Date.now()+7200000).toISOString() }], duration_minutes: 60 });
  it("rejects one unqualified station display name without exposing either name", async()=>{
    const log=vi.spyOn(console,"info").mockImplementation(()=>{});const fetchImpl=vi.fn(async()=>jsonResponse({places:[{id:"station1",displayName:{text:"Ginza Station"},types:["transit_station"],location:{latitude:35,longitude:139}}]}));
    await expect(diagnosticProvider(fetchImpl).search(stationRequest())).rejects.toThrow();
    expect(log.mock.calls.map(([x])=>JSON.parse(x))).toEqual([{reason:"station_no_exact_match",operation:"google_places_text_search",http_status:null}]);expect(fetchImpl).toHaveBeenCalledTimes(1);expect(JSON.stringify(log.mock.calls)).not.toMatch(/Ginza|Tokyo|latitude|longitude/);log.mockRestore();
  });
  it.each([0,2])("logs fixed station reason for exact match count %s", async count => {
    const log=vi.spyOn(console,"info").mockImplementation(()=>{});
    const fetchImpl=vi.fn(async()=>jsonResponse({ places: Array.from({length:count},(_,i)=>({id:"station"+i,displayName:{text:count===0?"Ginza Station":"Ginza Station, Tokyo"},types:["transit_station"],location:{latitude:35,longitude:139}})) }));
    await expect(diagnosticProvider(fetchImpl).search(stationRequest())).rejects.toThrow();
    expect(log.mock.calls.map(([x])=>JSON.parse(x))).toContainEqual({ reason:count===0?"station_no_exact_match":"station_ambiguous",operation:"google_places_text_search",http_status:null });
    expect(JSON.stringify(log.mock.calls)).not.toMatch(/Ginza|Tokyo|never-log-secret|latitude|longitude/);
    expect(fetchImpl).toHaveBeenCalledTimes(1); log.mockRestore();
  });
  it.each(["http_error","response_invalid","network_error","reservation_denied"])("emits only safe fields for %s", async reason => {
    const log=vi.spyOn(console,"info").mockImplementation(()=>{});
    const fetchImpl=vi.fn(async()=>{if(reason==="network_error") throw new Error("never-log-secret Ginza Tokyo 35.0 139.0");return new Response(reason==="http_error"?"never-log-secret":"invalid Ginza Tokyo",{status:reason==="http_error"?403:200,headers:{"Content-Type":"application/json"}});});
    await expect(diagnosticProvider(fetchImpl,reason!=="reservation_denied").search(stationRequest())).rejects.toThrow();
    expect(log.mock.calls.map(([x])=>JSON.parse(x))).toContainEqual({reason,operation:"google_places_text_search",http_status:reason==="http_error"?403:reason==="response_invalid"?200:null});
    expect(JSON.stringify(log.mock.calls)).not.toMatch(/Ginza|Tokyo|never-log-secret|35.0|139.0/);
    expect(fetchImpl.mock.calls.length).toBe(reason==="reservation_denied"?0:1);log.mockRestore();
  });
  it("emits no diagnostics outside the active synthetic admission",async()=>{
    const log=vi.spyOn(console,"info").mockImplementation(()=>{});const fetchImpl=vi.fn(async()=>jsonResponse({places:[]}));
    await expect(configuredProvider(fetchImpl).search({...BASE_REQUEST,first_participant:{consented:true,location:{kind:"station",station_name:"Never log station"}}})).rejects.toThrow();
    expect(log).not.toHaveBeenCalled();diagnosticProvider(fetchImpl,true,false);expect(log).not.toHaveBeenCalled();log.mockRestore();
  });
  it("ignores unknown diagnostic values rather than reflecting them",()=>{
    const log=vi.spyOn(console,"info").mockImplementation(()=>{});const provider=diagnosticProvider(vi.fn(async()=>jsonResponse({places:[]}))) as unknown as {safeDiagnostic(reason:string,operation:string,status:number|null):void};
    for(const args of [["secret-location","google_places_text_search",200],["http_error","https://secret.example",200],["http_error","google_places_text_search",900]] as const)provider.safeDiagnostic(args[0],args[1],args[2]);expect(log).not.toHaveBeenCalled();log.mockRestore();
  });
});
