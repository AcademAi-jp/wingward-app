import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const API_SRC = join(__dirname, "..");
const readRoute = (name: string) => readFileSync(join(API_SRC, "routes", name), "utf8");
const readService = (name: string) => readFileSync(join(API_SRC, "services", name), "utf8");
const readAuthMiddleware = () => readFileSync(join(API_SRC, "middleware", "auth.ts"), "utf8");
const readAgeMigration = () =>
	readFileSync(
		join(API_SRC, "..", "..", "..", "supabase", "migrations", "20260824100000_age_verification_lockdown.sql"),
		"utf8",
	);

const withoutComments = (source: string) => source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\r\n]*/g, "");

const HTTP_GATED_ROUTES = [
	"matching.ts",
	"matches.ts",
	"fox-conversations.ts",
	"partner-fox-chats.ts",
	"chat-requests.ts",
	"direct-chats.ts",
	"fox-search.ts",
] as const;

/**
 * Derive the route registrations from each module instead of treating a
 * hand-maintained count as the source of truth. A registration block ends at
 * the next Hono HTTP registration, so multiline middleware lists are covered
 * as well as the current one-line style.
 */
function routeRegistrations(source: string): string[] {
	const starts = [...source.matchAll(/^\s*[A-Za-z_$][\w$]*\.(?:get|post|put|patch|delete)\s*\(/gm)];
	return starts.map((start, index) => {
		const begin = start.index ?? 0;
		const next = starts[index + 1]?.index ?? source.length;
		return source.slice(begin, next);
	});
}

describe("B1-A age verification route wiring", () => {
	it("emits the exact machine code only for the unverified state", () => {
		const source = readAuthMiddleware();
		const unverified = source.indexOf('status === "unverified"');
		expect(unverified).toBeGreaterThan(-1);
		const unverifiedBlock = source.slice(unverified, source.indexOf("\n\t}", unverified) + 3);
		expect(unverifiedBlock).toContain('jsonError(c, "AGE_VERIFICATION_REQUIRED", "Age verification required")');
		expect(unverifiedBlock).not.toContain('jsonError(c, "FORBIDDEN"');
		expect(readRoute("auth.ts")).toContain('jsonError(c, "FORBIDDEN", "Age verification requires the user to be at least 18")');
	});

	it.each(HTTP_GATED_ROUTES)("gates every %s HTTP registration", (file) => {
		const registrations = routeRegistrations(readRoute(file));
		expect(registrations.length).toBeGreaterThan(0);
		for (const registration of registrations) {
			expect(registration).toMatch(/requireAuth\s*,\s*requireAgeVerified/);
		}
	});

	it("gates the fox-search WebSocket before participant checks and DO creation", () => {
		const source = readRoute("fox-search-ws.ts");
		const ageCheck = source.indexOf("getAgeVerificationStatus(c, userId)");
		const participantCheck = source.indexOf("const access = await checkParticipantCached");
		const doCreation = source.indexOf("const doId = doNs.idFromName");
		expect(source).toContain("getAgeVerificationStatus");
		expect(ageCheck).toBeGreaterThan(-1);
		expect(ageCheck).toBeLessThan(participantCheck);
		expect(ageCheck).toBeLessThan(doCreation);
	});

	it("does not add the age gate to the explicitly exempt route modules", () => {
		for (const file of ["quiz.ts", "speed-dating.ts", "profiles.ts", "personas.ts", "moderation.ts"]) {
			expect(readRoute(file)).not.toContain("requireAgeVerified");
		}
	});

	it("resets legacy age-verification values before defining the age-gated helper", () => {
		const source = readAgeMigration();
		const reset = source.indexOf("UPDATE public.user_profiles\nSET birth_date = NULL");
		const helper = source.indexOf("CREATE OR REPLACE FUNCTION public.get_user_profile_id()");
		expect(reset).toBeGreaterThan(-1);
		expect(helper).toBeGreaterThan(reset);

		const resetBlock = source.slice(reset, helper);
		expect(resetBlock).toMatch(/SET\s+birth_date\s*=\s*NULL/);
		expect(resetBlock).toMatch(/age_verified_at\s*=\s*NULL/);
		expect(resetBlock).toMatch(/age_verification_method\s*=\s*NULL/);
		expect(resetBlock).toMatch(
			/WHERE[\s\S]*birth_date\s+IS\s+NOT\s+NULL[\s\S]*OR\s+age_verified_at\s+IS\s+NOT\s+NULL[\s\S]*OR\s+age_verification_method\s+IS\s+NOT\s+NULL/,
		);
	});

	it("backfills pre-existing auth users without replacing profiles or age fields", () => {
		const source = readAgeMigration();
		const trigger = source.indexOf("CREATE TRIGGER user_profiles_after_auth_insert");
		const backfill = source.indexOf(
			"INSERT INTO public.user_profiles (auth_user_id, nickname)\nSELECT u.id, 'User'",
		);
		const directWriteLockdown = source.indexOf("-- Direct authenticated writes", backfill);

		expect(trigger).toBeGreaterThan(-1);
		expect(backfill).toBeGreaterThan(trigger);
		expect(directWriteLockdown).toBeGreaterThan(backfill);
		const triggerBlock = source.slice(source.indexOf("CREATE OR REPLACE FUNCTION public.handle_new_user_profile()"), trigger);
		expect(triggerBlock).toMatch(/ON CONFLICT \(auth_user_id\) DO NOTHING/);

		const backfillBlock = source.slice(backfill, directWriteLockdown);
		expect(backfillBlock).toMatch(/FROM auth\.users AS u/);
		expect(backfillBlock).toMatch(/LEFT JOIN public\.user_profiles AS p ON p\.auth_user_id = u\.id/);
		expect(backfillBlock).toMatch(/WHERE p\.auth_user_id IS NULL/);
		expect(backfillBlock).toMatch(/ON CONFLICT \(auth_user_id\) DO NOTHING/);
		expect(backfillBlock).not.toMatch(/age_verified_at|birth_date|age_verification_method/);
	});

	it("defines a non-oracular participant helper and gates every match-derived RLS policy", () => {
		const source = readAgeMigration();
		expect(source).toMatch(/CREATE OR REPLACE FUNCTION public\.are_match_participants_age_verified\(p_match_id uuid\)/);
		expect(source).toMatch(/SECURITY DEFINER[\s\S]*SET search_path = ''/);
		expect(source).toMatch(/REVOKE ALL ON FUNCTION public\.are_match_participants_age_verified\(uuid\) FROM PUBLIC, anon, authenticated/);
		expect(source).toMatch(/GRANT EXECUTE ON FUNCTION public\.are_match_participants_age_verified\(uuid\) TO authenticated, service_role/);
		expect(source).toMatch(/auth_user_id = \(SELECT auth\.uid\(\)\)/);

		const expectedPolicies = [
			["matches_select", "matches"],
			["interaction_dna_scores_select", "interaction_dna_scores"],
			["fox_conversations_select", "fox_conversations"],
			["fox_conversation_messages_select", "fox_conversation_messages"],
			["partner_fox_chats_select", "partner_fox_chats"],
			["partner_fox_chats_insert", "partner_fox_chats"],
			["partner_fox_messages_select", "partner_fox_messages"],
			["partner_fox_messages_insert", "partner_fox_messages"],
			["chat_requests_select", "chat_requests"],
			["chat_requests_update", "chat_requests"],
			["direct_chat_rooms_select", "direct_chat_rooms"],
			["direct_chat_messages_select", "direct_chat_messages"],
			["meetups_select", "meetups"],
			["meetups_insert", "meetups"],
			["meetup_proposals_select", "meetup_proposals"],
			["meetup_proposal_responses_select", "meetup_proposal_responses"],
			["meetup_proposal_responses_insert", "meetup_proposal_responses"],
			["venue_checkins_select", "venue_checkins"],
			["venue_checkins_insert", "venue_checkins"],
			["notifications_select", "notifications"],
			["notification_events_select", "notification_events"],
			["notification_events_insert", "notification_events"],
		] as const;

		const policyBody = (policy: string, table: string) => {
			const marker = `CREATE POLICY ${policy} ON public.${table}`;
			const start = source.indexOf(marker);
			expect(start, `${marker} missing`).toBeGreaterThan(-1);
			const next = source.indexOf("\nCREATE POLICY ", start + marker.length);
			return source.slice(start, next === -1 ? source.length : next);
		};

		for (const [policy, table] of expectedPolicies) {
			const body = policyBody(policy, table);
			expect(body, `${policy} missing participant age helper`).toContain("public.are_match_participants_age_verified");
		}
		for (const policy of ["notification_events_select", "notification_events_insert"] as const) {
			const body = policyBody(policy, "notification_events");
			expect(body, `${policy} must require the parent notification to be visible`).toContain("EXISTS");
			expect(body).toContain("FROM public.notifications AS n");
			expect(body).toContain("public.get_user_profile_id() = n.user_id");
			expect(body).toContain("n.match_id IS NULL");
		}
		expect(policyBody("notification_events_insert", "notification_events")).toContain("event_type <> 'sent'");

		// These policies are intentionally absent after the blocked-pair
		// invariant migration; the age migration must not recreate them.
		expect(source).not.toMatch(/CREATE POLICY chat_requests_insert ON public\.chat_requests/);
		expect(source).not.toMatch(/CREATE POLICY direct_chat_messages_insert ON public\.direct_chat_messages/);
	});
});

describe("B1-A existing-pair access wiring", () => {
	it("applies the shared pair filter to matching, chat-request, and direct-chat lists", () => {
		expect(readRoute("matching.ts")).toMatch(/filterVerifiedMatches/);
		expect(readRoute("matching.ts")).toMatch(/checkVerifiedPair/);
		expect(readRoute("chat-requests.ts")).toMatch(/filterVerifiedMatches/);
		expect(readRoute("direct-chats.ts")).toMatch(/filterVerifiedMatches/);
	});

	it.each(["chat-requests.ts", "direct-chats.ts", "fox-search.ts"]) (
		"gates %s action/read paths with the shared pair check",
		(file) => {
			expect(readRoute(file)).toMatch(/checkVerifiedPair|checkVerifiedMatch/);
		},
	);

	it("gates every Fox conversation public-read registration with its initial and current access helpers", () => {
		const registrations = routeRegistrations(readRoute("fox-conversations.ts"));
		expect(registrations).toHaveLength(2);
		for (const registration of registrations) {
			const code = withoutComments(registration);
			const initialAccess = code.indexOf("readFoxConversationPublicAccess(");
			const currentAccess = code.indexOf("checkFoxConversationCurrentAccess(");
			expect(initialAccess).toBeGreaterThan(-1);
			expect(currentAccess).toBeGreaterThan(initialAccess);
			expect(code.slice(currentAccess)).toMatch(/checkFoxConversationCurrentAccess\([\s\S]*"public_read"/);
		}
	});

	it("gates every partner-Fox action/read path with its current access helper", () => {
		const source = readRoute("partner-fox-chats.ts");
		const code = withoutComments(source);
		const registrations = routeRegistrations(source);
		expect(registrations).toHaveLength(5);
		for (const registration of registrations) {
			expect(withoutComments(registration)).toMatch(/\bcheckCurrentAccess\s*\(/);
		}
		expect(code).toMatch(/\bcheckPartnerFoxChatAccess\s*\(/);
		expect(code).toMatch(/\bcheckPartnerFoxChatStartAccess\s*\(/);
		expect(code).not.toMatch(/\bcheckVerifiedPair\b|\bcheckVerifiedMatch\b/);
	});

	it("keeps the partner-Fox guard on shared eligibility columns and predicate", () => {
		const source = withoutComments(readService("partner-fox-chat-access.ts"));
		expect(source).toMatch(/MATCHING_ELIGIBILITY_COLUMNS/);
		expect(source).toMatch(/areMutuallyEligible/);
		expect(source).toMatch(/const PARTNER_FOX_PROFILE_SELECT\s*=\s*`\$\{MATCHING_ELIGIBILITY_COLUMNS\}/);
		expect(source).toMatch(/if\s*\(\s*!areMutuallyEligible\(match\.profileA,\s*match\.profileB\)\s*\)/);
	});

	it("keeps Fox conversation current access on shared eligibility columns and predicate", () => {
		const source = withoutComments(readService("fox-conversation-access.ts"));
		const validationStart = source.indexOf("function validateCurrentAccessRow(");
		const validationEnd = source.indexOf("type PublicInitialIdentity", validationStart);
		const validation = source.slice(validationStart, validationEnd);
		expect(source).toMatch(/MATCHING_ELIGIBILITY_COLUMNS/);
		expect(source).toMatch(/areMutuallyEligible/);
		expect(validation).toMatch(/if\s*\(\s*!areMutuallyEligible\(profileA,\s*profileB\)\s*\)\s*return\s*\{\s*ok:\s*false,\s*reason:\s*"forbidden"\s*\}/);
	});

	it("rechecks match-derived notifications in the common send sink", () => {
		const source = readFileSync(join(API_SRC, "services", "notifications.ts"), "utf8");
		expect(source).toMatch(/checkNotificationAgeVerified/);
		const finalAccessBeforeSend = (candidate: string) => {
			const deliverNow = candidate.indexOf("async function deliverNow");
			const finalAccess = candidate.indexOf("const access = await checkNotificationDeliveryAccess(", deliverNow);
			const send = candidate.indexOf("const result = await sendOneSignalNotification", deliverNow);
			return deliverNow >= 0 && finalAccess > deliverNow && send > finalAccess;
		};
		expect(finalAccessBeforeSend(source)).toBe(true);

		// Negative control: the same helper after the provider call must fail the
		// ordering predicate, so this test cannot pass on a stale pre-check alone.
		const lateFinalCheck = `
			async function deliverNow() {
				const result = await sendOneSignalNotification();
				const access = await checkNotificationDeliveryAccess();
			}`;
		expect(finalAccessBeforeSend(lateFinalCheck)).toBe(false);
	});

	it("gates the match-linked notification event action before inserting an event", () => {
		const source = readRoute("notification-events.ts");
		expect(source).toMatch(/select\("id, user_id, match_id"\)/);
		expect(source).toMatch(/checkVerifiedMatch/);
		expect(source.indexOf("const ageCheck = await checkVerifiedMatch")).toBeLessThan(source.indexOf("const { data: inserted"));
	});

	it("keeps the WebSocket participant check before Durable Object creation", () => {
		const source = readRoute("fox-search-ws.ts");
		expect(source).toMatch(/checkFoxConversationParticipant/);
		expect(source.indexOf("const access = await checkParticipantCached")).toBeLessThan(source.indexOf("const doId = doNs.idFromName"));
	});
});
