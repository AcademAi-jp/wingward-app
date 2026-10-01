/** Shared WingWard brand mark; the legacy exports preserve stored API contracts. */
export const WARD_ICON_URL = "/wingward-mark.svg";
export const FOX_ICONS: Record<string, string[]> = {
	male: [WARD_ICON_URL],
	female: [WARD_ICON_URL],
};

/** Avatar presentation uses the same Ward mark for every profile. */
export function getRandomIconUrlForGender(_gender: string): string {
	return WARD_ICON_URL;
}
