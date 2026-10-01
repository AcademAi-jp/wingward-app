import { z } from "zod";
import { assertValidTimeZone } from "../lib/date";
import {
	createSupabaseProfilePhotoAdapter,
	MAX_PROFILE_PHOTO_BYTES,
	PROFILE_PHOTO_SIGNED_URL_TTL_SECONDS,
} from "../lib/profile-photo";

export { MAX_PROFILE_PHOTO_BYTES, PROFILE_PHOTO_SIGNED_URL_TTL_SECONDS } from "../lib/profile-photo";

export const UI_LOCALES = ["ja", "en"] as const;
export const DATING_MARKETS = ["JP", "US"] as const;
export const CONVERSATION_LANGUAGES = ["ja", "en"] as const;
export const DISTANCE_UNITS = ["km", "mi"] as const;
export const GENDER_CATEGORIES = ["woman", "man", "nonbinary"] as const;

export type UiLocale = (typeof UI_LOCALES)[number];
export type DatingMarket = (typeof DATING_MARKETS)[number];
export type ConversationLanguage = (typeof CONVERSATION_LANGUAGES)[number];
export type DistanceUnit = (typeof DISTANCE_UNITS)[number];
export type GenderCategory = (typeof GENDER_CATEGORIES)[number];

type CatalogStation = {
	id: string;
	names: Record<UiLocale, string>;
	coarse_area_id: string;
};

type CatalogArea = {
	id: string;
	names: Record<UiLocale, string>;
};

type MarketCatalog = {
	stations: readonly CatalogStation[];
	areas: readonly CatalogArea[];
};

const CATALOGS: Record<DatingMarket, MarketCatalog> = {
	JP: {
		stations: [
			{
				id: "jp-tokyo-shimokitazawa",
				names: { ja: "下北沢", en: "Shimokitazawa" },
				coarse_area_id: "jp-tokyo-setagaya",
			},
			{
				id: "jp-tokyo-shibuya",
				names: { ja: "渋谷", en: "Shibuya" },
				coarse_area_id: "jp-tokyo-shibuya",
			},
		],
		areas: [
			{ id: "jp-tokyo-setagaya", names: { ja: "世田谷区", en: "Setagaya" } },
			{ id: "jp-tokyo-shibuya", names: { ja: "渋谷区", en: "Shibuya" } },
		],
	},
	US: {
		stations: [
			{
				id: "us-ca-sf-powell",
				names: { ja: "パウエル・ストリート", en: "Powell Street" },
				coarse_area_id: "us-ca-san-francisco",
			},
		],
		areas: [{ id: "us-ca-san-francisco", names: { ja: "サンフランシスコ", en: "San Francisco" } }],
	},
};

export type OnboardingOptions = {
	stations: Array<{ id: string; name: string; coarse_area_id: string }>;
	areas: Array<{ id: string; name: string }>;
	terms: { market: DatingMarket; status: "draft" };
	catalog_status: "fixture";
};

export function getOnboardingOptions(market: DatingMarket, locale: UiLocale): OnboardingOptions {
	const catalog = CATALOGS[market];
	return {
		stations: catalog.stations.map((station) => ({
			id: station.id,
			name: station.names[locale],
			coarse_area_id: station.coarse_area_id,
		})),
		areas: catalog.areas.map((area) => ({ id: area.id, name: area.names[locale] })),
		terms: { market, status: "draft" },
		catalog_status: "fixture",
	};
}

function isValidIanaTimeZone(value: string): boolean {
	// Node/ICU accepts fixed numeric offsets such as "+01:00" as a time zone,
	// but onboarding stores named IANA zones only. Reject those before calling
	// the shared Intl-backed validator.
	if (/^[+-]\d{1,2}(?::?\d{2})?$/.test(value)) return false;
	try {
		assertValidTimeZone(value);
		return true;
	} catch {
		return false;
	}
}

const catalogIdSchema = z
	.string()
	.min(1)
	.max(100)
	.regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/);

const preferredGendersSchema = z
	.array(z.enum(GENDER_CATEGORIES))
	.max(GENDER_CATEGORIES.length)
	.superRefine((values, ctx) => {
		if (new Set(values).size !== values.length) {
			ctx.addIssue({ code: z.ZodIssueCode.custom, message: "duplicate values" });
		}
	});

const onboardingSettingsBaseSchema = z
	.object({
		ui_locale: z.enum(UI_LOCALES),
		dating_market: z.enum(DATING_MARKETS),
		conversation_language: z.enum(CONVERSATION_LANGUAGES),
		timezone: z.string().min(1).max(100).refine(isValidIanaTimeZone),
		distance_unit: z.enum(DISTANCE_UNITS),
		gender_identity: z.enum(GENDER_CATEGORIES).nullable(),
		gender_visibility: z.literal("private"),
		preferred_genders: preferredGendersSchema,
		preference_mode: z.enum(["selected", "no_answer"]),
		location_mode: z.enum(["station", "no_transit", "not_set"]),
		station_id: catalogIdSchema.nullable(),
		coarse_area_id: catalogIdSchema.nullable(),
	})
	.strict();

export const onboardingSettingsSchema = onboardingSettingsBaseSchema
	.superRefine((value, ctx) => {
		if (value.preference_mode === "no_answer" && value.preferred_genders.length !== 0) {
			ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["preferred_genders"], message: "no-answer must be empty" });
		}
		if (value.preference_mode === "selected" && value.preferred_genders.length === 0) {
			ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["preferred_genders"], message: "selected must not be empty" });
		}

		const catalog = CATALOGS[value.dating_market];
		const knownArea = value.coarse_area_id === null
			? undefined
			: catalog.areas.find((area) => area.id === value.coarse_area_id);
		if (value.coarse_area_id !== null && !knownArea) {
			ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["coarse_area_id"], message: "unknown area" });
		}

		if (value.location_mode === "not_set") {
			if (value.station_id !== null || value.coarse_area_id !== null) {
				ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["location_mode"], message: "not-set must not include a location" });
			}
			return;
		}

		if (value.location_mode === "no_transit") {
			if (value.dating_market !== "US" || value.station_id !== null || value.coarse_area_id === null) {
				ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["location_mode"], message: "invalid no-transit location" });
			}
			return;
		}

		const station = value.station_id === null
			? undefined
			: catalog.stations.find((entry) => entry.id === value.station_id);
		if (!station || value.coarse_area_id !== station.coarse_area_id) {
			ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["station_id"], message: "invalid station location" });
		}
	});

export type OnboardingSettings = z.infer<typeof onboardingSettingsSchema>;

const ONBOARDING_SETTINGS_KEYS = [
	"ui_locale",
	"dating_market",
	"conversation_language",
	"timezone",
	"distance_unit",
	"gender_identity",
	"gender_visibility",
	"preferred_genders",
	"preference_mode",
	"location_mode",
	"station_id",
	"coarse_area_id",
] as const;

export const ONBOARDING_SETTINGS_COLUMNS = [
	...ONBOARDING_SETTINGS_KEYS,
	"onboarding_settings_completed_at",
].join(", ");

type StoredSettingsRow = Record<string, unknown>;

/**
 * Converts a service-role row to the closed public DTO.  The completion
 * marker is intentionally inspected separately and never returned to clients.
 */
export function readCompletedOnboardingSettings(row: StoredSettingsRow): OnboardingSettings | null {
	if (row.onboarding_settings_completed_at === null || row.onboarding_settings_completed_at === undefined) {
		return null;
	}
	const candidate: Record<string, unknown> = {};
	for (const key of ONBOARDING_SETTINGS_KEYS) candidate[key] = row[key];
	const parsed = onboardingSettingsSchema.safeParse(candidate);
	return parsed.success ? parsed.data : null;
}

export type TrustedNormalizedPhoto = {
	bytes: Uint8Array;
	contentType: "image/jpeg" | "image/png" | "image/webp";
	/** Set only by a decoder/re-encoder after metadata removal. */
	metadataStripped: true;
};

export type PhotoNormalizer = {
	normalize: (input: { bytes: Uint8Array; contentType: string }) => Promise<TrustedNormalizedPhoto | null>;
};

export type StoredPrivatePhoto = {
	objectKey: string;
	private: true;
};

export type PrivatePhotoStorage = {
	putOwnerPhoto: (ownerId: string, photo: TrustedNormalizedPhoto) => Promise<StoredPrivatePhoto>;
	createOwnerReadUrl: (ownerId: string, objectKey: string, expiresInSeconds: number) => Promise<string>;
	/** Optional cleanup hook used after CAS replacement, failed profile update, or account deletion. */
	removeOwnerPhoto?: (ownerId: string, objectKey: string) => Promise<void>;
};

export type ProfilePhotoAdapter = {
	normalizer: PhotoNormalizer;
	storage: PrivatePhotoStorage;
};

export type PhotoSaveResult =
	| { kind: "saved"; readUrl: string; objectKey: string }
	| { kind: "unavailable" }
	| { kind: "invalid" };

const SUPPORTED_PHOTO_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);

/**
 * Reads at most `maxBytes` from a request body. A Content-Length header is
 * useful as an early rejection, but is not authoritative for chunked or
 * deceptive requests; the stream itself must be bounded before buffering.
 */
export async function readBoundedRequestBody(
	request: Request,
	maxBytes = MAX_PROFILE_PHOTO_BYTES,
): Promise<Uint8Array | null> {
	const body = request.body;
	if (!body) return new Uint8Array();
	const reader = body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	try {
		while (true) {
			const result = await reader.read();
			if (result.done) break;
			if (!(result.value instanceof Uint8Array)) return null;
			total += result.value.byteLength;
			if (total > maxBytes) {
				await reader.cancel();
				return null;
			}
			chunks.push(result.value);
		}
		const bytes = new Uint8Array(total);
		let offset = 0;
		for (const chunk of chunks) {
			bytes.set(chunk, offset);
			offset += chunk.byteLength;
		}
		return bytes;
	} catch {
		try {
			await reader.cancel();
		} catch {
			// The original body failure is already handled as an invalid request.
		}
		return null;
	} finally {
		reader.releaseLock();
	}
}

function normalizedContentType(contentType: string): string {
	return contentType.split(";", 1)[0]?.trim().toLowerCase() ?? "";
}

export function isSafeOwnerPhotoReadUrl(value: string): boolean {
	try {
		const url = new URL(value);
		return url.protocol === "https:"
			&& url.hostname.length > 0
			&& url.username.length === 0
			&& url.password.length === 0;
	} catch {
		return false;
	}
}

function hasImageSignature(bytes: Uint8Array, contentType: string): boolean {
	if (contentType === "image/jpeg") return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
	if (contentType === "image/png") {
		return bytes.length >= 8
			&& bytes[0] === 0x89
			&& bytes[1] === 0x50
			&& bytes[2] === 0x4e
			&& bytes[3] === 0x47
			&& bytes[4] === 0x0d
			&& bytes[5] === 0x0a
			&& bytes[6] === 0x1a
			&& bytes[7] === 0x0a;
	}
	return bytes.length >= 12
		&& bytes[0] === 0x52
		&& bytes[1] === 0x49
		&& bytes[2] === 0x46
		&& bytes[3] === 0x46
		&& bytes[8] === 0x57
		&& bytes[9] === 0x45
		&& bytes[10] === 0x42
		&& bytes[11] === 0x50;
}

export function isSupportedPhotoInput(bytes: Uint8Array, contentType: string): boolean {
	const type = normalizedContentType(contentType);
	return bytes.byteLength > 0
		&& bytes.byteLength <= MAX_PROFILE_PHOTO_BYTES
		&& SUPPORTED_PHOTO_TYPES.has(type)
		&& hasImageSignature(bytes, type);
}

function isTrustedNormalizedPhoto(photo: TrustedNormalizedPhoto): boolean {
	const contentType = normalizedContentType(photo.contentType);
	return photo.metadataStripped === true
		&& SUPPORTED_PHOTO_TYPES.has(contentType)
		&& photo.bytes instanceof Uint8Array
		&& photo.bytes.byteLength > 0
		&& photo.bytes.byteLength <= MAX_PROFILE_PHOTO_BYTES
		&& hasImageSignature(photo.bytes, contentType);
}

/**
 * The default is intentionally disabled.  A real decoder/re-encoder and
 * private storage implementation must be injected before this endpoint can
 * save anything; raw request bytes are never handed to storage.
 */
export function getProfilePhotoAdapter(_env: unknown): ProfilePhotoAdapter | null {
	return createSupabaseProfilePhotoAdapter(_env);
}

export async function saveProfilePhoto(
	ownerId: string,
	bytes: Uint8Array,
	contentType: string,
	adapter: ProfilePhotoAdapter | null = null,
): Promise<PhotoSaveResult> {
	if (!isSupportedPhotoInput(bytes, contentType)) return { kind: "invalid" };
	if (!adapter) return { kind: "unavailable" };

	const normalized = await adapter.normalizer.normalize({
		bytes: new Uint8Array(bytes),
		contentType: normalizedContentType(contentType),
	});
	if (!normalized || !isTrustedNormalizedPhoto(normalized)) return { kind: "invalid" };

	const stored = await adapter.storage.putOwnerPhoto(ownerId, normalized);
	if (
		!stored
		|| typeof stored !== "object"
		|| stored.private !== true
		|| typeof stored.objectKey !== "string"
		|| stored.objectKey.length === 0
		|| stored.objectKey.length > 500
	) return { kind: "invalid" };
	let readUrl: string;
	try {
		readUrl = await adapter.storage.createOwnerReadUrl(
			ownerId,
			stored.objectKey,
			PROFILE_PHOTO_SIGNED_URL_TTL_SECONDS,
		);
	} catch (error) {
		try {
			await adapter.storage.removeOwnerPhoto?.(ownerId, stored.objectKey);
		} catch {
			// Preserve the signed URL/storage failure without exposing provider details.
		}
		throw error;
	}
	if (typeof readUrl !== "string" || readUrl.length === 0 || readUrl.length > 4096 || !isSafeOwnerPhotoReadUrl(readUrl)) {
		try {
			await adapter.storage.removeOwnerPhoto?.(ownerId, stored.objectKey);
		} catch {
			// A failed cleanup remains private and is recorded by the caller's provider logs.
		}
		return { kind: "invalid" };
	}
	return { kind: "saved", readUrl, objectKey: stored.objectKey };
}
