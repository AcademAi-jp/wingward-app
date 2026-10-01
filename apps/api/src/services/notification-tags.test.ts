import { describe, expect, it } from "vitest";
import { computeNotificationTags } from "./notification-tags";

/**
 * Coverage for orchestrator review round 2, finding #4: lookup errors and a
 * malformed stored timezone must not be silently forwarded — each must
 * produce a typed failure instead of a guessed default or an uncaught throw.
 */

function makeQuery(result: { data: unknown; error: unknown }) {
	return {
		select() {
			return this;
		},
		eq() {
			return this;
		},
		or() {
			return this;
		},
		in() {
		return this;
		},
		limit() {
			return Promise.resolve(result);
		},
		single() {
			return Promise.resolve(result);
		},
		maybeSingle() {
			return Promise.resolve(result);
		},
		then(resolve: (v: unknown) => unknown) {
			return Promise.resolve(result).then(resolve);
		},
	};
}

function buildSupabaseFake(opts: {
	profile?: { data: unknown; error: unknown };
	entitlement?: { data: unknown; error: unknown };
	matches?: { data: unknown; error: unknown };
	meetups?: { data: unknown; error: unknown };
}) {
	const profile = opts.profile ?? { data: { timezone: "Asia/Tokyo" }, error: null };
	const entitlement = opts.entitlement ?? { data: { is_active: false }, error: null };
	const matches = opts.matches ?? { data: [], error: null };
	return {
		from(table: string) {
			if (table === "user_profiles") return makeQuery(profile);
			if (table === "entitlements") return makeQuery(entitlement);
			if (table === "matches") return makeQuery(matches);
			if (table === "meetups") return makeQuery(opts.meetups ?? { data: [], error: null });
			throw new Error(`unexpected table ${table}`);
		},
	};
}

describe("computeNotificationTags", () => {
	it("returns ok:true with the computed tags on the happy path", async () => {
		const supabase = buildSupabaseFake({
			profile: { data: { timezone: "Asia/Tokyo" }, error: null },
			entitlement: { data: { is_active: true }, error: null },
		});

		const result = await computeNotificationTags(supabase as never, "user-1");

		expect(result).toEqual({
			ok: true,
			tags: { billing_status: "active", has_meetup_experience: "false", timezone: "Asia/Tokyo" },
		});
	});

	it("propagates a profile lookup DB error instead of guessing a default timezone", async () => {
		const supabase = buildSupabaseFake({
			profile: { data: null, error: { message: "simulated DB error" } },
		});

		const result = await computeNotificationTags(supabase as never, "user-1");

		expect(result).toEqual({ ok: false, reason: "profile_lookup_failed" });
	});

	it("propagates a missing profile row instead of guessing a default timezone", async () => {
		const supabase = buildSupabaseFake({
			profile: { data: null, error: null },
		});

		const result = await computeNotificationTags(supabase as never, "user-1");

		expect(result).toEqual({ ok: false, reason: "profile_lookup_failed" });
	});

	it("rejects a malformed stored timezone instead of forwarding it unvalidated", async () => {
		const supabase = buildSupabaseFake({
			profile: { data: { timezone: "not/a/real/zone" }, error: null },
		});

		const result = await computeNotificationTags(supabase as never, "user-1");

		expect(result).toEqual({ ok: false, reason: "invalid_timezone" });
	});

	it("returns failure when the entitlement lookup errors instead of computing a free tag", async () => {
		const supabase = buildSupabaseFake({
			entitlement: { data: null, error: { message: "entitlements unavailable" } },
		});

		const result = await computeNotificationTags(supabase as never, "user-1");

		expect(result).toEqual({ ok: false, reason: "entitlement_lookup_failed" });
	});

	it("returns failure when the matches lookup errors instead of computing no meetup tag", async () => {
		const supabase = buildSupabaseFake({
			matches: { data: null, error: { message: "matches unavailable" } },
		});

		const result = await computeNotificationTags(supabase as never, "user-1");

		expect(result).toEqual({ ok: false, reason: "matches_lookup_failed" });
	});

	it("returns failure when the meetups lookup errors instead of computing false", async () => {
		const supabase = buildSupabaseFake({
			matches: { data: [{ id: "match-1" }], error: null },
			meetups: { data: null, error: { message: "meetups unavailable" } },
		});

		const result = await computeNotificationTags(supabase as never, "user-1");

		expect(result).toEqual({ ok: false, reason: "meetups_lookup_failed" });
	});
});
