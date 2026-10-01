import { describe, expect, it, vi } from "vitest";
import {
	MAX_PROFILE_PHOTO_BYTES,
	getOnboardingOptions,
	getProfilePhotoAdapter,
	isSafeOwnerPhotoReadUrl,
	isSupportedPhotoInput,
	saveProfilePhoto,
} from "./onboarding-settings";

function jpegFixture(size = 8): Uint8Array {
	const bytes = new Uint8Array(Math.max(size, 3));
	bytes.set([0xff, 0xd8, 0xff]);
	return bytes;
}

describe("onboarding fixture catalog", () => {
	it("keeps station IDs and coarse areas stable across locale labels", () => {
		const japanese = getOnboardingOptions("US", "ja");
		const english = getOnboardingOptions("US", "en");

		expect(japanese.stations).toEqual([
			{ id: "us-ca-sf-powell", name: "パウエル・ストリート", coarse_area_id: "us-ca-san-francisco" },
		]);
		expect(english.stations).toEqual([
			{ id: "us-ca-sf-powell", name: "Powell Street", coarse_area_id: "us-ca-san-francisco" },
		]);
		expect(japanese.terms).toEqual({ market: "US", status: "draft" });
		expect(japanese.catalog_status).toBe("fixture");
	});
});

describe("profile photo boundary", () => {
	it("rejects a MIME/signature mismatch before invoking a normalizer", async () => {
		const normalize = vi.fn();
		const result = await saveProfilePhoto("profile-1", jpegFixture(), "image/png", {
			normalizer: { normalize },
			storage: {
				putOwnerPhoto: vi.fn(),
				createOwnerReadUrl: vi.fn(),
			},
		});

		expect(result).toEqual({ kind: "invalid" });
		expect(normalize).not.toHaveBeenCalled();
	});

	it("rejects an oversized body before invoking a normalizer", async () => {
		const normalize = vi.fn();
		const bytes = new Uint8Array(MAX_PROFILE_PHOTO_BYTES + 1);
		bytes.set([0xff, 0xd8, 0xff]);

		const result = await saveProfilePhoto("profile-1", bytes, "image/jpeg", {
			normalizer: { normalize },
			storage: {
				putOwnerPhoto: vi.fn(),
				createOwnerReadUrl: vi.fn(),
			},
		});

		expect(result).toEqual({ kind: "invalid" });
		expect(normalize).not.toHaveBeenCalled();
	});

	it("returns unavailable with the default disabled adapter and never claims success", async () => {
		expect(getProfilePhotoAdapter({})).toBeNull();
		expect(await saveProfilePhoto("profile-1", jpegFixture(), "image/jpeg")).toEqual({ kind: "unavailable" });
	});

	it("passes only trusted normalized bytes and the owner key to private storage", async () => {
		const putOwnerPhoto = vi.fn(async () => ({ objectKey: "profile-1/photo-1", private: true as const }));
		const createOwnerReadUrl = vi.fn(async () => "https://private.example.test/signed/photo-1");
		const normalizedBytes = jpegFixture(12);
		const normalize = vi.fn(async () => ({
			bytes: normalizedBytes,
			contentType: "image/jpeg" as const,
			metadataStripped: true as const,
		}));

		const result = await saveProfilePhoto("profile-1", jpegFixture(), "image/jpeg", {
			normalizer: { normalize },
			storage: { putOwnerPhoto, createOwnerReadUrl },
		});

		expect(result).toEqual({
		kind: "saved",
		readUrl: "https://private.example.test/signed/photo-1",
		objectKey: "profile-1/photo-1",
	});
		expect(normalize).toHaveBeenCalledWith({ bytes: expect.any(Uint8Array), contentType: "image/jpeg" });
		expect(putOwnerPhoto).toHaveBeenCalledWith("profile-1", {
			bytes: normalizedBytes,
			contentType: "image/jpeg",
			metadataStripped: true,
		});
		expect(createOwnerReadUrl).toHaveBeenCalledWith("profile-1", "profile-1/photo-1", 300);
	});

	it("does not persist when the injected normalizer does not prove metadata removal", async () => {
		const putOwnerPhoto = vi.fn();
		const result = await saveProfilePhoto("profile-1", jpegFixture(), "image/jpeg", {
			normalizer: {
				normalize: async () => ({
					bytes: jpegFixture(),
					contentType: "image/jpeg" as const,
					metadataStripped: false as never,
				}),
			},
			storage: {
				putOwnerPhoto,
				createOwnerReadUrl: vi.fn(),
			},
		});

		expect(result).toEqual({ kind: "invalid" });
		expect(putOwnerPhoto).not.toHaveBeenCalled();
	});

	it.each([
		"http://private.example.test/signed/photo-1",
		"javascript:alert(1)",
		"not a URL",
		"https://user:pass@private.example.test/signed/photo-1",
	])("rejects an unsafe signed read URL (%s)", (url) => {
		expect(isSafeOwnerPhotoReadUrl(url)).toBe(false);
	});

	it("does not report success when private storage returns an unsafe signed URL", async () => {
		const removeOwnerPhoto = vi.fn(async () => undefined);
		const result = await saveProfilePhoto("profile-1", jpegFixture(), "image/jpeg", {
			normalizer: {
				normalize: async () => ({
					bytes: jpegFixture(),
					contentType: "image/jpeg" as const,
					metadataStripped: true as const,
				}),
			},
			storage: {
				putOwnerPhoto: async () => ({ objectKey: "profile-1/photo-1", private: true as const }),
				createOwnerReadUrl: async () => "http://private.example.test/signed/photo-1",
				removeOwnerPhoto,
			},
		});

		expect(result).toEqual({ kind: "invalid" });
		expect(removeOwnerPhoto).toHaveBeenCalledWith("profile-1", "profile-1/photo-1");
	});

	it("cleans up the new object when signed URL creation fails", async () => {
		const removeOwnerPhoto = vi.fn(async () => undefined);
		await expect(saveProfilePhoto("profile-1", jpegFixture(), "image/jpeg", {
			normalizer: {
				normalize: async () => ({
					bytes: jpegFixture(),
					contentType: "image/jpeg" as const,
					metadataStripped: true as const,
				}),
			},
			storage: {
				putOwnerPhoto: async () => ({ objectKey: "profile-1/photo-1", private: true as const }),
				createOwnerReadUrl: async () => { throw new Error("provider unavailable"); },
				removeOwnerPhoto,
			},
		})).rejects.toThrow("provider unavailable");
		expect(removeOwnerPhoto).toHaveBeenCalledWith("profile-1", "profile-1/photo-1");
	});

	it("accepts only supported image signatures", () => {
		expect(isSupportedPhotoInput(jpegFixture(), "image/jpeg")).toBe(true);
		expect(isSupportedPhotoInput(new Uint8Array([1, 2, 3]), "image/jpeg")).toBe(false);
		expect(isSupportedPhotoInput(jpegFixture(), "application/octet-stream")).toBe(false);
	});
});
