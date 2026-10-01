import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { assertValidTimeZone } from "../lib/date";

/**
 * OneSignal segmentation tags (step-04-notifications.md §3-1: "OneSignal
 * タグ: 課金状態・面会経験の有無・タイムゾーンを設定"). Computed server-side from
 * our own tables — never from client input — and used both to tag the
 * OneSignal user record and to build the re-engagement campaign segment
 * (docs/notifications/onesignal-campaign.md).
 */
export interface NotificationTags {
	billing_status: "active" | "free";
	has_meetup_experience: "true" | "false";
	timezone: string;
}

export type ComputeNotificationTagsResult =
	| { ok: true; tags: NotificationTags }
	| { ok: false; reason: "profile_lookup_failed" }
	| { ok: false; reason: "entitlement_lookup_failed" }
	| { ok: false; reason: "matches_lookup_failed" }
	| { ok: false; reason: "meetups_lookup_failed" }
	| { ok: false; reason: "invalid_timezone" };

/**
 * Computes the current tag values for `userId`.
 *
 * `has_meetup_experience` is true iff the user has at least one `meetups`
 * row with status `completed` on a match they're a participant in. Two
 * queries (their match ids, then completed meetups among those) rather
 * than a single join, matching the query style already used elsewhere in
 * this codebase (e.g. services/daily-batch.ts).
 *
 * Orchestrator review round 2, finding #4: this used to discard lookup
 * errors and fall back to guessed tag values — silently mistagging the user
 * rather than surfacing the failure. Lookup errors, missing profiles, and
 * malformed timezones now produce typed `{ ok: false }` results the caller
 * must handle, matching `lib/date.ts`'s "an invalid IANA name throws and
 * must never fall back to a default" rule (AGENTS.md security posture #2)
 * applied at this call site instead of only inside `assertValidTimeZone`.
 */
export async function computeNotificationTags(
	supabase: SupabaseClient<Database>,
	userId: string,
): Promise<ComputeNotificationTagsResult> {
	const [
		{ data: profile, error: profileError },
		{ data: entitlement, error: entitlementError },
		{ data: matches, error: matchesError },
	] = await Promise.all([
		supabase.from("user_profiles").select("timezone").eq("id", userId).single(),
		supabase.from("entitlements").select("is_active").eq("user_id", userId).maybeSingle(),
		supabase.from("matches").select("id").or(`user_a_id.eq.${userId},user_b_id.eq.${userId}`),
	]);

	if (profileError || !profile) {
		console.error("[notification-tags] failed to look up user_profiles.timezone");
		return { ok: false, reason: "profile_lookup_failed" };
	}
	if (entitlementError) {
		console.error("[notification-tags] failed to look up entitlements");
		return { ok: false, reason: "entitlement_lookup_failed" };
	}
	if (matchesError || !matches) {
		console.error("[notification-tags] failed to look up matches");
		return { ok: false, reason: "matches_lookup_failed" };
	}

	let timezone: string;
	try {
		timezone = assertValidTimeZone(profile.timezone);
	} catch {
		console.error("[notification-tags] stored timezone is not a valid IANA name");
		return { ok: false, reason: "invalid_timezone" };
	}

	const billingStatus: NotificationTags["billing_status"] = entitlement?.is_active ? "active" : "free";

	const matchIds = matches.map((m) => m.id);
	let hasMeetupExperience = false;
	if (matchIds.length > 0) {
		const { data: completedMeetups, error: meetupsError } = await supabase
			.from("meetups")
			.select("id")
			.in("match_id", matchIds)
			.eq("status", "completed")
			.limit(1);
		if (meetupsError || !completedMeetups) {
			console.error("[notification-tags] failed to look up meetups");
			return { ok: false, reason: "meetups_lookup_failed" };
		}
		hasMeetupExperience = (completedMeetups ?? []).length > 0;
	}

	return {
		ok: true,
		tags: {
			billing_status: billingStatus,
			has_meetup_experience: hasMeetupExperience ? "true" : "false",
			timezone,
		},
	};
}
