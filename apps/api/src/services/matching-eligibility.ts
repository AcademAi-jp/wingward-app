import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { shareMatchingCohort } from "./synthetic-matching-cohort";

/**
 * The only user-profile columns that may participate in a matching decision.
 * Keep this selection closed: legacy `gender`, `region`, and owner-only
 * location/language fields must not leak into matching or scoring inputs.
 */
export const MATCHING_ELIGIBILITY_COLUMNS =
	"id, age_verified_at, gender_identity, preferred_genders, preference_mode, dating_market, onboarding_settings_completed_at" as const;

export const MATCHING_GENDER_CATEGORIES = ["woman", "man", "nonbinary"] as const;
export const MATCHING_MARKETS = ["JP", "US"] as const;

export type MatchingGenderCategory = (typeof MATCHING_GENDER_CATEGORIES)[number];
export type MatchingMarket = (typeof MATCHING_MARKETS)[number];

/**
 * This is intentionally narrower than the public user-profile DTO. Values
 * are left as runtime data until the strict predicate validates them, so a
 * malformed service-role response cannot be trusted merely because generated
 * database types describe the normal row shape.
 */
export type MatchingEligibilityProfile = {
	id: string;
	age_verified_at: string;
	gender_identity: MatchingGenderCategory;
	preferred_genders: MatchingGenderCategory[];
	preference_mode: "selected";
	dating_market: MatchingMarket;
	onboarding_settings_completed_at: string;
};

/** A profile row before the strict field-level validator has accepted it. */
export type MatchingEligibilityProfileRow = { id: string } & Record<string, unknown>;

export type MatchingEligibilityProfileMap = ReadonlyMap<string, MatchingEligibilityProfileRow>;

export type MatchingEligibilityLookupErrorKind = "query" | "invalid_rows";

/** A non-disclosing error used at service boundaries after a lookup fails. */
export class MatchingEligibilityLookupError extends Error {
	readonly kind: MatchingEligibilityLookupErrorKind;

	constructor(kind: MatchingEligibilityLookupErrorKind) {
		super("Matching eligibility data could not be read");
		this.name = "MatchingEligibilityLookupError";
		this.kind = kind;
	}
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

function isNonEmptyString(value: unknown): value is string {
	return typeof value === "string" && value.trim().length > 0;
}

function isKnownGenderCategory(value: unknown): value is MatchingGenderCategory {
	return typeof value === "string" && (MATCHING_GENDER_CATEGORIES as readonly string[]).includes(value);
}

function isKnownMarket(value: unknown): value is MatchingMarket {
	return typeof value === "string" && (MATCHING_MARKETS as readonly string[]).includes(value);
}

function isCompletedTimestamp(value: unknown): value is string {
	return isNonEmptyString(value) && Number.isFinite(Date.parse(value));
}

function isUniqueKnownPreferenceCategories(value: unknown): value is MatchingGenderCategory[] {
	if (!Array.isArray(value) || value.length === 0) return false;
	const categories = value as unknown[];
	if (!categories.every(isKnownGenderCategory)) return false;
	return new Set(categories).size === categories.length;
}

/**
 * Returns true only for a complete, explicit, mutually selected pair.
 *
 * This function is pure and deliberately does not normalize, infer, or fall
 * back to legacy fields. In particular, null/unknown identities, no-answer
 * preferences, malformed arrays, missing completion markers, and differing
 * markets all reject the pair.
 */
export function isMutuallyEligiblePair(
	first: unknown,
	second: unknown,
): first is MatchingEligibilityProfile {
	if (!isMatchingProfileComplete(first) || !isMatchingProfileComplete(second)) return false;
	if (first.id === second.id) return false;
	if (!shareMatchingCohort(first.id, second.id)) return false;
	if (first.dating_market !== second.dating_market) return false;

	return (
		first.preferred_genders.includes(second.gender_identity) &&
		second.preferred_genders.includes(first.gender_identity)
	);
}

/** Alias with a verb that reads naturally at callers. */
export const areMutuallyEligible = isMutuallyEligiblePair;

/**
 * Validates the fields needed by the pair predicate for one side of a pair.
 * It is exported for discovery paths that need to count only profiles that
 * can possibly participate, while pair decisions still use the mutual gate.
 */
export function isMatchingProfileComplete(value: unknown): value is MatchingEligibilityProfile {
	if (!isRecord(value)) return false;
	if (!isNonEmptyString(value.id)) return false;
	if (!isCompletedTimestamp(value.age_verified_at)) return false;
	if (!isCompletedTimestamp(value.onboarding_settings_completed_at)) return false;
	if (!isKnownGenderCategory(value.gender_identity)) return false;
	if (value.preference_mode !== "selected") return false;
	if (!isUniqueKnownPreferenceCategories(value.preferred_genders)) return false;
	if (!isKnownMarket(value.dating_market)) return false;
	return true;
}

/**
 * Indexes a service-role response without allowing Map's last-write-wins
 * behaviour to hide duplicate rows. If requested IDs are supplied, every
 * returned ID must belong to that closed request set; missing requested rows
 * remain absent so callers can turn them into the existing generic
 * unavailable/not-found result without widening public errors.
 */
export function indexMatchingEligibilityProfiles(
	rows: unknown,
	requestedIds?: readonly string[],
): Map<string, MatchingEligibilityProfileRow> | null {
	if (!Array.isArray(rows)) return null;

	let requested: Set<string> | undefined;
	if (requestedIds !== undefined) {
		if (
			requestedIds.some((id) => !isNonEmptyString(id)) ||
			new Set(requestedIds).size !== requestedIds.length
		) {
			return null;
		}
		requested = new Set(requestedIds);
	}

	const indexed = new Map<string, MatchingEligibilityProfileRow>();
	for (const row of rows) {
		if (!isRecord(row) || !isNonEmptyString(row.id)) return null;
		if (requested && !requested.has(row.id)) return null;
		if (indexed.has(row.id)) return null;
		indexed.set(row.id, { ...row, id: row.id });
	}

	return indexed;
}

/**
 * Reads current matching fields for a closed set of user IDs. Query failures,
 * malformed responses, unexpected IDs, and duplicate IDs are all represented
 * by the same non-disclosing lookup error at service boundaries.
 */
export async function loadMatchingEligibilityProfiles(
	supabase: SupabaseClient<Database>,
	userIds: readonly string[],
): Promise<MatchingEligibilityProfileMap> {
	if (
		userIds.some((id) => !isNonEmptyString(id)) ||
		new Set(userIds).size !== userIds.length
	) {
		throw new MatchingEligibilityLookupError("invalid_rows");
	}
	if (userIds.length === 0) return new Map();

	let result: { data: unknown; error: unknown };
	try {
		result = await supabase
			.from("user_profiles")
			.select(MATCHING_ELIGIBILITY_COLUMNS)
			.in("id", [...userIds]);
	} catch {
		throw new MatchingEligibilityLookupError("query");
	}

	if (result.error || !Array.isArray(result.data)) {
		throw new MatchingEligibilityLookupError("query");
	}

	const indexed = indexMatchingEligibilityProfiles(result.data, userIds);
	if (!indexed) throw new MatchingEligibilityLookupError("invalid_rows");
	return indexed;
}
