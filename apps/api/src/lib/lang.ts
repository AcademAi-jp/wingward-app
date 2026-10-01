/** Detect the language a persona was generated in by checking for Japanese content */
export function detectLangFromDocument(compiledDocument: string): "ja" | "en" {
	// Count Japanese characters (hiragana, katakana, CJK) in the content
	const jpChars = (compiledDocument.match(/[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF]/g) ?? []).length;
	// If significant Japanese content exists, treat as Japanese
	if (jpChars > 20) return "ja";
	return "en";
}

export function normalizeUserLanguage(lang: string | null | undefined): "ja" | "en" | null {
	const normalized = (lang ?? "").trim().toLowerCase();
	if (normalized.startsWith("en")) return "en";
	if (normalized.startsWith("ja")) return "ja";
	return null;
}

/**
 * Resolve conversation language from both users' saved settings.
 * Rule: if either user prefers English, use English.
 * Otherwise, if one or both are Japanese, use Japanese.
 * Fallback to document detection (or Japanese) when no preference is available.
 */
export function resolveConversationLangFromUserSettings(
	userLangA: string | null | undefined,
	userLangB: string | null | undefined,
	fallbackDocument?: string,
): "ja" | "en" {
	const a = normalizeUserLanguage(userLangA);
	const b = normalizeUserLanguage(userLangB);
	if (a === "en" || b === "en") return "en";
	if (a === "ja" || b === "ja") return "ja";
	if (fallbackDocument) return detectLangFromDocument(fallbackDocument);
	return "en";
}
