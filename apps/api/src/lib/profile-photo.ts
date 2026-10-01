import { getSupabaseClient } from "../db/client";
import type { Env } from "../env";
import type {
	PhotoNormalizer,
	PrivatePhotoStorage,
	ProfilePhotoAdapter,
	StoredPrivatePhoto,
	TrustedNormalizedPhoto,
} from "../services/onboarding-settings";

export const MAX_PROFILE_PHOTO_BYTES = 5 * 1024 * 1024;
export const PROFILE_PHOTO_SIGNED_URL_TTL_SECONDS = 5 * 60;
export const MAX_PROFILE_PHOTO_DIMENSION = 1200;
export const MAX_PROFILE_PHOTO_PIXELS = MAX_PROFILE_PHOTO_DIMENSION * MAX_PROFILE_PHOTO_DIMENSION;

export const PROFILE_PHOTO_STORAGE_ENABLED_BINDING = "PROFILE_PHOTO_STORAGE_ENABLED" as const;
export const PROFILE_PHOTO_STORAGE_PRIVATE_BINDING = "PROFILE_PHOTO_STORAGE_PRIVATE" as const;
export const PROFILE_PHOTO_STORAGE_BUCKET_BINDING = "PROFILE_PHOTO_STORAGE_BUCKET" as const;

const OWNER_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const BUCKET_NAME_PATTERN = /^[a-z0-9][a-z0-9._-]{0,62}$/;
const PNG_SIGNATURE = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const RETAINED_PNG_CHUNKS = new Set(["IHDR", "PLTE", "tRNS", "IDAT", "IEND"]);

type UnknownBindings = Record<string, unknown>;

export type ProfilePhotoProfileState = {
	avatar_url: string | null;
	avatar_storage_path: string | null;
};

export type ProfilePhotoProfileStore = {
	readOwnerPhotoState: (ownerId: string) => Promise<ProfilePhotoProfileState | null>;
	compareAndSetOwnerPhoto: (
		ownerId: string,
		expectedStoragePath: string | null,
		nextStoragePath: string,
		nextAvatarUrl: string,
	) => Promise<boolean>;
};

function asBindings(value: unknown): UnknownBindings {
	return value && typeof value === "object" ? (value as UnknownBindings) : {};
}

function nonEmptyString(value: unknown): value is string {
	return typeof value === "string" && value.length > 0;
}

function isLocalHttpOrigin(url: URL): boolean {
	return url.protocol === "http:" && (url.hostname === "localhost" || url.hostname === "127.0.0.1");
}

function isAllowedSupabaseUrl(value: unknown): value is string {
	if (!nonEmptyString(value)) return false;
	try {
		const url = new URL(value);
		return url.protocol === "https:" || isLocalHttpOrigin(url);
	} catch {
		return false;
	}
}

export function isSafeProfilePhotoOwnerId(ownerId: string): boolean {
	return OWNER_ID_PATTERN.test(ownerId);
}

export function isOwnerProfilePhotoPath(ownerId: string, objectKey: string): boolean {
	if (!isSafeProfilePhotoOwnerId(ownerId) || typeof objectKey !== "string") return false;
	const prefix = `profile-photos/${ownerId}/`;
	if (!objectKey.startsWith(prefix)) return false;
	const filename = objectKey.slice(prefix.length);
	return /^[A-Za-z0-9_-]{1,128}\.png$/.test(filename) && !objectKey.includes("..");
}

function buildOwnerPhotoPath(ownerId: string): string {
	if (!isSafeProfilePhotoOwnerId(ownerId)) throw new Error("invalid profile photo owner");
	return `profile-photos/${ownerId}/${crypto.randomUUID()}.png`;
}

function crc32(bytes: Uint8Array, ranges: Array<[number, number]>): number {
	let crc = 0xffffffff;
	for (const [start, end] of ranges) {
		for (let index = start; index < end; index += 1) {
			crc ^= bytes[index] ?? 0;
			for (let bit = 0; bit < 8; bit += 1) {
				crc = (crc & 1) === 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
			}
		}
	}
	return (crc ^ 0xffffffff) >>> 0;
}

function readUint32(bytes: Uint8Array, offset: number): number {
	return (
		((bytes[offset] ?? 0) << 24)
		| ((bytes[offset + 1] ?? 0) << 16)
		| ((bytes[offset + 2] ?? 0) << 8)
		| (bytes[offset + 3] ?? 0)
	) >>> 0;
}

function chunkType(bytes: Uint8Array, offset: number): string {
	return String.fromCharCode(bytes[offset] ?? 0, bytes[offset + 1] ?? 0, bytes[offset + 2] ?? 0, bytes[offset + 3] ?? 0);
}

function isPngSignature(bytes: Uint8Array): boolean {
	return bytes.length >= PNG_SIGNATURE.length && PNG_SIGNATURE.every((value, index) => bytes[index] === value);
}

function isCriticalChunk(type: string): boolean {
	return type.length === 4 && (type.charCodeAt(0) & 0x20) === 0;
}

/**
 * Validates the PNG container and drops all ancillary metadata chunks before
 * storage.  Core Image already sends a processed PNG from iOS; this second
 * pass keeps the storage boundary fail-closed when a different client sends
 * an image with EXIF, text, or time metadata attached.
 */
export function normalizeProcessedPng(input: { bytes: Uint8Array; contentType: string }): Promise<TrustedNormalizedPhoto | null> {
	const contentType = input.contentType.split(";", 1)[0]?.trim().toLowerCase() ?? "";
	if (contentType !== "image/png" || !isPngSignature(input.bytes) || input.bytes.byteLength > MAX_PROFILE_PHOTO_BYTES) {
		return Promise.resolve(null);
	}

	const bytes = new Uint8Array(input.bytes);
	const kept: Uint8Array[] = [PNG_SIGNATURE];
	let offset = PNG_SIGNATURE.length;
	let sawHeader = false;
	let sawPalette = false;
	let sawTransparency = false;
	let sawData = false;
	let sawEnd = false;
	let dataClosed = false;
	let headerWidth = 0;
	let headerHeight = 0;
	let colorType = -1;
	let bitDepth = -1;

	while (offset < bytes.length) {
		if (bytes.length - offset < 12) return Promise.resolve(null);
		const length = readUint32(bytes, offset);
		if (length > MAX_PROFILE_PHOTO_BYTES || offset > bytes.length - 12 - length) return Promise.resolve(null);
		const type = chunkType(bytes, offset + 4);
		const dataStart = offset + 8;
		const dataEnd = dataStart + length;
		const chunkEnd = dataEnd + 4;
		const expectedCrc = readUint32(bytes, dataEnd);
		const actualCrc = crc32(bytes, [ [offset + 4, offset + 8], [dataStart, dataEnd] ]);
		if (expectedCrc !== actualCrc) return Promise.resolve(null);

		if (!sawHeader && type !== "IHDR") return Promise.resolve(null);
		if (type === "IHDR") {
			if (sawHeader || length !== 13) return Promise.resolve(null);
			sawHeader = true;
			headerWidth = readUint32(bytes, dataStart);
			headerHeight = readUint32(bytes, dataStart + 4);
			bitDepth = bytes[dataStart + 8] ?? -1;
			colorType = bytes[dataStart + 9] ?? -1;
			const compressionMethod = bytes[dataStart + 10] ?? -1;
			const filterMethod = bytes[dataStart + 11] ?? -1;
			const interlaceMethod = bytes[dataStart + 12] ?? -1;
			const allowedBitDepths = colorType === 3
				? new Set([1, 2, 4, 8])
				: colorType === 0
					? new Set([1, 2, 4, 8, 16])
					: new Set([8, 16]);
			const allowedColorType = new Set([0, 2, 3, 4, 6]);
			if (
				headerWidth === 0
				|| headerHeight === 0
				|| headerWidth > MAX_PROFILE_PHOTO_DIMENSION
				|| headerHeight > MAX_PROFILE_PHOTO_DIMENSION
				|| headerWidth * headerHeight > MAX_PROFILE_PHOTO_PIXELS
				|| !allowedColorType.has(colorType)
				|| !allowedBitDepths.has(bitDepth)
				|| compressionMethod !== 0
				|| filterMethod !== 0
				|| (interlaceMethod !== 0 && interlaceMethod !== 1)
			) return Promise.resolve(null);
		} else if (type === "PLTE") {
			if (sawPalette || sawData || length === 0 || length % 3 !== 0 || length > 768 || colorType === 0 || colorType === 4) return Promise.resolve(null);
			sawPalette = true;
		} else if (type === "tRNS") {
			if (sawTransparency || sawData) return Promise.resolve(null);
			sawTransparency = true;
		} else if (type === "IDAT") {
			if (dataClosed) return Promise.resolve(null);
			sawData = true;
		} else if (type === "IEND") {
			if (!sawData || length !== 0 || sawEnd || chunkEnd !== bytes.length) return Promise.resolve(null);
			sawEnd = true;
		} else if (sawData) {
			dataClosed = true;
		}

		if (isCriticalChunk(type) && !RETAINED_PNG_CHUNKS.has(type)) return Promise.resolve(null);
		if (RETAINED_PNG_CHUNKS.has(type)) kept.push(bytes.slice(offset, chunkEnd));
		offset = chunkEnd;
		if (sawEnd) break;
	}

	if (!sawHeader || !sawData || !sawEnd || offset !== bytes.length || (colorType === 3 && !sawPalette)) return Promise.resolve(null);

	const outputLength = kept.reduce((total, chunk) => total + chunk.byteLength, 0);
	if (outputLength === 0 || outputLength > MAX_PROFILE_PHOTO_BYTES) return Promise.resolve(null);
	const output = new Uint8Array(outputLength);
	let outputOffset = 0;
	for (const chunk of kept) {
		output.set(chunk, outputOffset);
		outputOffset += chunk.byteLength;
	}

	// Keep these reads in the validator so a future caller cannot accidentally
	// remove the structural checks while retaining only a signature check.
	void headerWidth;
	void headerHeight;
	return Promise.resolve({ bytes: output, contentType: "image/png", metadataStripped: true });
}

function createSupabasePhotoStorage(
	supabase: ReturnType<typeof getSupabaseClient>,
	bucket: string,
	supabaseUrl: string,
): PrivatePhotoStorage {
	const bucketApi = supabase.storage.from(bucket);
	const expectedOrigin = new URL(supabaseUrl).origin;

	const storage: PrivatePhotoStorage = {
		async putOwnerPhoto(ownerId, photo): Promise<StoredPrivatePhoto> {
			if (photo.contentType !== "image/png" || photo.metadataStripped !== true || !isSafeProfilePhotoOwnerId(ownerId)) {
				throw new Error("invalid normalized profile photo");
			}
			const objectKey = buildOwnerPhotoPath(ownerId);
			const uploadBytes = new Uint8Array(photo.bytes.byteLength);
			uploadBytes.set(photo.bytes);
			const { data, error } = await bucketApi.upload(objectKey, new Blob([uploadBytes.buffer as ArrayBuffer], { type: "image/png" }), {
				cacheControl: "31536000",
				contentType: "image/png",
				upsert: false,
			});
			if (error || !data || data.path !== objectKey) throw new Error("profile photo storage upload failed");
			return { objectKey, private: true };
		},
		async createOwnerReadUrl(ownerId, objectKey, expiresInSeconds): Promise<string> {
			if (!isOwnerProfilePhotoPath(ownerId, objectKey) || !Number.isSafeInteger(expiresInSeconds) || expiresInSeconds < 1 || expiresInSeconds > 3600) {
				throw new Error("invalid profile photo read request");
			}
			const { data, error } = await bucketApi.createSignedUrl(objectKey, expiresInSeconds);
			if (error || !data || typeof data.signedUrl !== "string") throw new Error("profile photo signed URL failed");
			const url = new URL(data.signedUrl);
			if (url.origin !== expectedOrigin || url.username || url.password || url.protocol !== new URL(supabaseUrl).protocol) {
				throw new Error("profile photo signed URL origin failed");
			}
			return data.signedUrl;
		},
		async removeOwnerPhoto(ownerId, objectKey): Promise<void> {
			if (!isOwnerProfilePhotoPath(ownerId, objectKey)) throw new Error("invalid profile photo cleanup request");
			const { error } = await bucketApi.remove([objectKey]);
			if (error) throw new Error("profile photo cleanup failed");
		},
	};
	return storage;
}

/**
 * Production opt-in is intentionally triple-gated.  The binding names are
 * non-secret configuration; the existing Supabase service key is consumed
 * only after an operator explicitly enables this private provider.
 */
export function createSupabaseProfilePhotoAdapter(env: unknown): ProfilePhotoAdapter | null {
	const bindings = asBindings(env);
	const enabled = bindings[PROFILE_PHOTO_STORAGE_ENABLED_BINDING] === "true";
	const privateBucket = bindings[PROFILE_PHOTO_STORAGE_PRIVATE_BINDING] === "true";
	const bucket = bindings[PROFILE_PHOTO_STORAGE_BUCKET_BINDING];
	const supabaseUrl = bindings.SUPABASE_URL;
	const serviceRoleKey = bindings.SUPABASE_SERVICE_ROLE_KEY;
	if (!enabled || !privateBucket || typeof bucket !== "string" || !BUCKET_NAME_PATTERN.test(bucket)) return null;
	if (!isAllowedSupabaseUrl(supabaseUrl) || !nonEmptyString(serviceRoleKey)) return null;

	const supabase = getSupabaseClient(bindings as Env["Bindings"]);
	const normalizer: PhotoNormalizer = { normalize: normalizeProcessedPng };
	return {
		normalizer,
		storage: createSupabasePhotoStorage(supabase, bucket, supabaseUrl),
	};
}

export function createSupabaseProfilePhotoProfileStore(
	supabase: ReturnType<typeof getSupabaseClient>,
): ProfilePhotoProfileStore {
	return {
		async readOwnerPhotoState(ownerId) {
			const { data, error } = await supabase
				.from("user_profiles")
				.select("id, avatar_url, avatar_storage_path")
				.eq("id", ownerId)
				.maybeSingle();
			if (error) throw new Error("profile photo owner lookup failed");
			if (!data || data.id !== ownerId) return null;
			return {
				avatar_url: data.avatar_url,
				avatar_storage_path: data.avatar_storage_path,
			};
		},
		async compareAndSetOwnerPhoto(ownerId, expectedStoragePath, nextStoragePath, nextAvatarUrl) {
			if (!isOwnerProfilePhotoPath(ownerId, nextStoragePath)) throw new Error("invalid profile photo state");
			let query = supabase
				.from("user_profiles")
				.update({ avatar_storage_path: nextStoragePath, avatar_url: nextAvatarUrl, updated_at: new Date().toISOString() })
				.eq("id", ownerId);
			query = expectedStoragePath === null
				? query.is("avatar_storage_path", null)
				: query.eq("avatar_storage_path", expectedStoragePath);
			const { data, error } = await query.select("id").maybeSingle();
			if (error) throw new Error("profile photo owner update failed");
			return Boolean(data && data.id === ownerId);
		},
	};
}

export async function cleanupStoredOwnerPhoto(
	adapter: ProfilePhotoAdapter,
	ownerId: string,
	objectKey: string | null | undefined,
): Promise<boolean> {
	if (!objectKey || !isOwnerProfilePhotoPath(ownerId, objectKey) || !adapter.storage.removeOwnerPhoto) return false;
	try {
		await adapter.storage.removeOwnerPhoto(ownerId, objectKey);
		return true;
	} catch {
		return false;
	}
}

function isSafeSignedReadUrl(value: string): boolean {
	try {
		const url = new URL(value);
		return url.protocol === "https:" && url.hostname.length > 0 && !url.username && !url.password;
	} catch {
		return false;
	}
}

/** Re-issues a short-lived URL only for a canonical path owned by this profile. */
export async function renewOwnerProfilePhotoReadUrl(
	adapter: ProfilePhotoAdapter,
	ownerId: string,
	objectKey: string,
): Promise<string> {
	if (!isOwnerProfilePhotoPath(ownerId, objectKey)) throw new Error("invalid profile photo owner path");
	const readUrl = await adapter.storage.createOwnerReadUrl(
		ownerId,
		objectKey,
		PROFILE_PHOTO_SIGNED_URL_TTL_SECONDS,
	);
	if (!isSafeSignedReadUrl(readUrl)) throw new Error("invalid profile photo signed URL");
	return readUrl;
}

/**
 * Resolves a photo for a participant after the caller has already enforced
 * match/chat authorization. A canonical path is never returned to clients;
 * renewal failures hide only the image and leave the authorized DTO intact.
 */
export async function resolveAuthorizedProfilePhotoUrl(
	adapter: ProfilePhotoAdapter | null,
	profileId: string,
	objectKey: unknown,
	fallbackUrl: string | null,
): Promise<string | null> {
	if (typeof objectKey !== "string") return fallbackUrl;
	if (!adapter) return null;
	try {
		return await renewOwnerProfilePhotoReadUrl(adapter, profileId, objectKey);
	} catch {
		return null;
	}
}

/** Caller must first check current eligibility and blocks for this match/chat. */
export async function resolveAuthorizedPeerProfilePhotoUrl(
  adapter: ProfilePhotoAdapter | null,
  viewerId: string,
  match: { user_a_id: string; user_b_id: string },
  profile: { id: string; avatar_storage_path?: unknown; avatar_url?: unknown },
): Promise<string | null> {
  if (match.user_a_id === match.user_b_id) return null;
  const peerId = match.user_a_id === viewerId ? match.user_b_id
    : match.user_b_id === viewerId ? match.user_a_id : null;
  if (!peerId || profile.id !== peerId) return null;
  return resolveAuthorizedProfilePhotoUrl(adapter, peerId, profile.avatar_storage_path,
    typeof profile.avatar_url === "string" ? profile.avatar_url : null);
}
