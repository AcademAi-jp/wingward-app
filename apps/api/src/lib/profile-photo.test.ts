import { describe, expect, it, vi } from "vitest";
import {
	MAX_PROFILE_PHOTO_DIMENSION,
	MAX_PROFILE_PHOTO_PIXELS,
	createSupabaseProfilePhotoAdapter,
	createSupabaseProfilePhotoProfileStore,
	isOwnerProfilePhotoPath,
	normalizeProcessedPng,
 resolveAuthorizedPeerProfilePhotoUrl,
} from "./profile-photo";

vi.mock("../db/client", () => ({
	getSupabaseClient: vi.fn(() => ({ storage: { from: vi.fn() } })),
}));

const PNG_SIGNATURE = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function crc32(bytes: Uint8Array): number {
	let crc = 0xffffffff;
	for (const byte of bytes) {
		crc ^= byte;
		for (let bit = 0; bit < 8; bit += 1) crc = (crc & 1) === 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
	}
	return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
	const typeBytes = Uint8Array.from([...type].map((char) => char.charCodeAt(0)));
	const body = new Uint8Array(typeBytes.length + data.length);
	body.set(typeBytes);
	body.set(data, typeBytes.length);
	const output = new Uint8Array(12 + data.length);
	new DataView(output.buffer).setUint32(0, data.length);
	output.set(typeBytes, 4);
	output.set(data, 8);
	new DataView(output.buffer).setUint32(8 + data.length, crc32(body));
	return output;
}

function pngFixture(width = 2, height = 2, metadata = true): Uint8Array {
	const ihdr = new Uint8Array(13);
	const view = new DataView(ihdr.buffer);
	view.setUint32(0, width);
	view.setUint32(4, height);
	ihdr[8] = 8;
	ihdr[9] = 6;
	const chunks = [chunk("IHDR", ihdr)];
	if (metadata) chunks.push(chunk("tEXt", new TextEncoder().encode("Comment\0synthetic")));
	chunks.push(chunk("IDAT", Uint8Array.from([0x78, 0x9c, 0x03, 0x00])));
	chunks.push(chunk("IEND", new Uint8Array()));
	const output = new Uint8Array(PNG_SIGNATURE.length + chunks.reduce((sum, value) => sum + value.length, 0));
	output.set(PNG_SIGNATURE);
	let offset = PNG_SIGNATURE.length;
	for (const value of chunks) {
		output.set(value, offset);
		offset += value.length;
	}
	return output;
}

function setIhdrByte(bytes: Uint8Array, offset: number, value: number): Uint8Array {
	const output = new Uint8Array(bytes);
	output[16 + offset] = value;
	const ihdrBody = output.slice(12, 29);
	new DataView(output.buffer).setUint32(29, crc32(ihdrBody));
	return output;
}

describe("profile photo provider boundary", () => {
	it("keeps storage disabled when an operator binding is absent", () => {
		expect(createSupabaseProfilePhotoAdapter({})).toBeNull();
		expect(createSupabaseProfilePhotoAdapter({
		PROFILE_PHOTO_STORAGE_ENABLED: "true",
		PROFILE_PHOTO_STORAGE_PRIVATE: "true",
		PROFILE_PHOTO_STORAGE_BUCKET: "profile-photos",
		SUPABASE_URL: "https://project.supabase.co",
	})).toBeNull();
	});

	it("strips ancillary metadata from a processed PNG before storage", async () => {
		const result = await normalizeProcessedPng({ bytes: pngFixture(), contentType: "image/png" });

		expect(result).toMatchObject({ contentType: "image/png", metadataStripped: true });
		expect(new TextDecoder().decode(result?.bytes)).not.toContain("Comment");
	});

	it.each([
		["oversized dimensions", MAX_PROFILE_PHOTO_DIMENSION + 1, 1],
		["oversized pixel count", MAX_PROFILE_PHOTO_DIMENSION, MAX_PROFILE_PHOTO_DIMENSION + 1],
	])("rejects %s in the PNG header", async (_label, width, height) => {
		expect(await normalizeProcessedPng({ bytes: pngFixture(width, height, false), contentType: "image/png" })).toBeNull();
	});

	it.each([
		["unsupported bit depth", 8, 1],
		["unsupported color type", 9, 1],
		["unsupported compression", 10, 1],
		["unsupported filter", 11, 1],
		["unsupported interlace", 12, 2],
	])("rejects malformed IHDR %s", async (_label, field, value) => {
		expect(await normalizeProcessedPng({
			bytes: setIhdrByte(pngFixture(2, 2, false), field, value),
			contentType: "image/png",
		})).toBeNull();
	});

	it("rejects non-PNG input and unsafe owner paths", async () => {
		expect(await normalizeProcessedPng({ bytes: pngFixture(), contentType: "image/jpeg" })).toBeNull();
		expect(isOwnerProfilePhotoPath("profile-1", "profile-photos/profile-2/photo.png")).toBe(false);
		expect(isOwnerProfilePhotoPath("profile-1", "profile-photos/profile-1/../photo.png")).toBe(false);
		expect(isOwnerProfilePhotoPath("profile-1", "profile-photos/profile-1/photo.png")).toBe(true);
	});

	it("uses the current canonical path as a compare-and-set guard", async () => {
		const query = {
			select: vi.fn(),
			eq: vi.fn(),
			is: vi.fn(),
			update: vi.fn(),
			maybeSingle: vi.fn(),
		};
		query.select.mockReturnValue(query);
		query.eq.mockReturnValue(query);
		query.is.mockReturnValue(query);
		query.update.mockReturnValue(query);
		query.maybeSingle.mockResolvedValue({ data: { id: "profile-1", avatar_url: null, avatar_storage_path: null }, error: null });
		const supabase = { from: vi.fn(() => query) } as any;
		const store = createSupabaseProfilePhotoProfileStore(supabase);

		expect(await store.readOwnerPhotoState("profile-1")).toEqual({
			avatar_url: null,
			avatar_storage_path: null,
		});
		expect(await store.compareAndSetOwnerPhoto(
			"profile-1",
			null,
			"profile-photos/profile-1/new.png",
			"https://project.supabase.co/signed/new",
		)).toBe(true);
		expect(query.is).toHaveBeenCalledWith("avatar_storage_path", null);
	});

	it("guards replacement against a concurrent canonical path change", async () => {
		const query = {
			select: vi.fn(),
			eq: vi.fn(),
			is: vi.fn(),
			update: vi.fn(),
			maybeSingle: vi.fn(),
		};
		query.select.mockReturnValue(query);
		query.eq.mockReturnValue(query);
		query.is.mockReturnValue(query);
		query.update.mockReturnValue(query);
		query.maybeSingle.mockResolvedValue({ data: null, error: null });
		const supabase = { from: vi.fn(() => query) } as any;
		const store = createSupabaseProfilePhotoProfileStore(supabase);

		expect(await store.compareAndSetOwnerPhoto(
			"profile-1",
			"profile-photos/profile-1/old.png",
			"profile-photos/profile-1/new.png",
			"https://project.supabase.co/signed/new",
		)).toBe(false);
		expect(query.eq).toHaveBeenCalledWith("avatar_storage_path", "profile-photos/profile-1/old.png");
	});
});


describe("authorized peer photo renewal", () => {
 const pair = { user_a_id: "viewer", user_b_id: "peer" };
 const photo = { id: "peer", avatar_storage_path: "profile-photos/peer/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png", avatar_url: "https://old.invalid/photo" };
 function fixture() {
  const sign = vi.fn().mockResolvedValue("https://storage.invalid/fresh");
  const adapter = { storage: { createOwnerReadUrl: sign } } as unknown as import("../services/onboarding-settings").ProfilePhotoAdapter;
  return { sign, adapter };
 }
 it("renews only the peer-owned key for five minutes", async () => {
  const { sign, adapter } = fixture();
  expect(await resolveAuthorizedPeerProfilePhotoUrl(adapter, "viewer", pair, photo)).toBe("https://storage.invalid/fresh");
  expect(sign).toHaveBeenCalledWith("peer", photo.avatar_storage_path, 300);
 });
 it.each([
  ["outsider", pair, photo],
  ["viewer", pair, { ...photo, id: "someone-else" }],
  ["viewer", pair, { ...photo, avatar_storage_path: "profile-photos/other/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.png" }],
  ["viewer", { user_a_id: "viewer", user_b_id: "viewer" }, photo],
 ] as const)("does not sign an unrelated viewer/profile/path", async (viewer, match, profile) => {
  const { sign, adapter } = fixture();
  expect(await resolveAuthorizedPeerProfilePhotoUrl(adapter, viewer, match, profile)).toBeNull();
  expect(sign).not.toHaveBeenCalled();
 });
 it("hides canonical photos if storage is disabled or signing fails", async () => {
  expect(await resolveAuthorizedPeerProfilePhotoUrl(null, "viewer", pair, photo)).toBeNull();
  const { sign, adapter } = fixture();
  sign.mockRejectedValue(new Error("private provider error"));
  expect(await resolveAuthorizedPeerProfilePhotoUrl(adapter, "viewer", pair, photo)).toBeNull();
 });
 it("preserves a legacy URL for an authorized peer without a stored key", async () => {
  expect(await resolveAuthorizedPeerProfilePhotoUrl(null, "viewer", pair, { ...photo, avatar_storage_path: null })).toBe(photo.avatar_url);
 });
});
