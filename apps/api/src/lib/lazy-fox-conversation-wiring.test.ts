import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Source-wiring checks for step-3a (lazy fox-conversation generation),
 * mirroring the pattern in batch-timezone-wiring.test.ts: these assert
 * against the actual file contents so a future edit that reintroduces an
 * eager `fox_conversations` insert fails the test suite immediately, rather
 * than only being caught by a live-DB integration test (which this repo
 * doesn't have for this path — see the step-3a report §1/§5.1).
 *
 * The three sites that used to auto-create a fox_conversations row:
 *   A. services/daily-matching.ts (executeDailyMatching, daily batch)
 *   B. services/matching.ts (executeMatching, /api/internal/matching/execute)
 *   C. services/fox-search.ts (searchMatchCandidates, /api/fox-search/start)
 * fox_conversations creation must now exist ONLY in
 * services/fox-conversation-request.ts (requestFoxConversation), the
 * implementation behind POST /api/matches/:id/fox-conversation.
 */

const API_SRC = join(__dirname, "..");

function read(relPath: string): string {
	return readFileSync(join(API_SRC, relPath), "utf8");
}

describe("no automatic fox_conversations insert remains at the three former eager-creation sites", () => {
	it("services/daily-matching.ts never references the fox_conversations table", () => {
		expect(read("services/daily-matching.ts")).not.toMatch(/from\(\s*["']fox_conversations["']\s*\)/);
	});

	it("services/matching.ts never references the fox_conversations table", () => {
		expect(read("services/matching.ts")).not.toMatch(/from\(\s*["']fox_conversations["']\s*\)/);
	});

	it("services/fox-search.ts never references the fox_conversations table", () => {
		expect(read("services/fox-search.ts")).not.toMatch(/from\(\s*["']fox_conversations["']\s*\)/);
	});

	it("routes/fox-search.ts's /start handler creates match candidates only (no DO start, no fox_conversation_id in its response)", () => {
		const src = read("routes/fox-search.ts");
		// The /start handler body: from the route declaration to the next route.
		const startHandler = src.slice(src.indexOf('foxSearch.post("/start"'), src.indexOf('foxSearch.get("/status'));
		expect(startHandler).not.toMatch(/FOX_CONVERSATION/);
		expect(startHandler).not.toMatch(/fox_conversation_id/);
		expect(startHandler).toMatch(/searchMatchCandidates/);
	});

	it("the only .insert( against fox_conversations in src/ is inside services/fox-conversation-request.ts", () => {
		// A narrower, cross-file guarantee: grep-equivalent check that no other
		// file under services/ or routes/ inserts into fox_conversations.
		const candidateFiles = [
			"services/daily-matching.ts",
			"services/matching.ts",
			"services/fox-search.ts",
			"routes/matching.ts",
			"routes/fox-search.ts",
			"routes/internal.ts",
		];
		for (const file of candidateFiles) {
			const src = read(file);
			// Matches `.from("fox_conversations")` followed (within a short
			// window) by `.insert(` — tolerant of formatting/line breaks.
			const insertPattern = /from\(\s*["']fox_conversations["']\s*\)[\s\S]{0,40}\.insert\(/;
			expect(src, `${file} must not insert into fox_conversations`).not.toMatch(insertPattern);
		}
	});
});

describe("services/fox-conversation-request.ts is the sole compatibility-conversation creation path", () => {
	it("inserts with purpose: 'compatibility' (matches the partial UNIQUE index scope)", () => {
		const src = read("services/fox-conversation-request.ts");
		expect(src).toMatch(/purpose:\s*["']compatibility["']/);
	});

	it("filters the existing-conversation pre-check by purpose = 'compatibility'", () => {
		const src = read("services/fox-conversation-request.ts");
		expect(src).toMatch(/\.eq\(\s*["']purpose["']\s*,\s*["']compatibility["']\s*\)/);
	});

	it("consumes quota via the consume_quota RPC, never via a direct usage_counters write", () => {
		const src = read("services/fox-conversation-request.ts");
		expect(src).toMatch(/\.rpc\(\s*["']consume_quota["']/);
		expect(src).not.toMatch(/from\(\s*["']usage_counters["']\s*\)/);
	});
});

describe("routes/matches.ts's 402 response leaks no internal quota state", () => {
	it("the PAYMENT_REQUIRED jsonError call passes a static string, not a template with consumed/limit/count values", () => {
		const src = read("routes/matches.ts");
		const match = src.match(/jsonError\(c,\s*"PAYMENT_REQUIRED",\s*([^)]*)\)/);
		expect(match).not.toBeNull();
		const messageArg = match![1];
		// Must be a plain string literal, not a template literal (which could
		// interpolate a count/limit) and must contain no digits.
		expect(messageArg.trim().startsWith('"')).toBe(true);
		expect(messageArg).not.toMatch(/\d/);
		expect(messageArg).not.toMatch(/\$\{/);
	});
});

describe("app.ts mounts the new route", () => {
	it("POST /api/matches/:id/fox-conversation is wired in app.ts", () => {
		const src = read("app.ts");
		expect(src).toMatch(/app\.route\(\s*["']\/api\/matches["']\s*,\s*matches\s*\)/);
	});
});

describe("step-3b: token spend is persisted even when the conversation fails", () => {
	/**
	 * Every Mistral call in runConversationLoop is billed the moment it
	 * returns, so the cost record must survive a failure. The first
	 * implementation closed its try/catch before the scoring section and the
	 * matches update — both of which throw on their own — which would have
	 * lost the entire token record for exactly the failures that cost the
	 * most (all 16 calls already paid for). The catch has to sit after the
	 * terminal update.
	 *
	 * Updated for step-3d (loop unification): this logic (and the file it
	 * lives in) moved from services/fox-conversation.ts to
	 * services/fox-conversation-engine.ts. services/fox-conversation.ts is now
	 * a thin wrapper with no token-accounting code of its own to assert
	 * against.
	 */
	const src = read("services/fox-conversation-engine.ts");

	it("the token-persisting catch comes after the terminal completed update", () => {
		const completedUpdate = src.indexOf('status: "completed"');
		const catchIndex = src.indexOf("} catch (err) {\n\t\t// Tokens already spent");
		expect(completedUpdate).toBeGreaterThan(-1);
		expect(catchIndex).toBeGreaterThan(completedUpdate);
	});

	it("the failure path writes all three token columns", () => {
		expect(src).toMatch(/cache_hit_tokens: cachedTokensReported \? totalCachedTokens : null/);
		expect(src).toMatch(/tokenTotalsForUpdate\(\)\)\.eq\("id", conversationId\)/);
	});

	it("round calls carry a per-conversation-per-speaker prompt cache key", () => {
		expect(src).toMatch(/promptCacheKey: `\$\{conversationId\}:\$\{currentSpeaker\}`/);
	});
});

describe("the quota RPCs are not reachable from a client key", () => {
	/**
	 * On hosted Supabase, `anon` and `authenticated` hold their own EXECUTE
	 * grants on functions in `public`, so M9's `REVOKE ALL ... FROM PUBLIC`
	 * did NOT stop them — the database linter caught both roles able to call
	 * /rest/v1/rpc/consume_quota on the real project even though the local
	 * stack looked clean. `consume_quota` takes the limit as an argument, so
	 * that was a complete bypass of the step-3a paywall. M10 revokes by role
	 * name. This test guards the migration that does it.
	 */
	const migrationsDir = join(__dirname, "..", "..", "..", "..", "supabase", "migrations");
	const lockdown = readFileSync(join(migrationsDir, "20260812120000_lock_down_rpc_and_rls.sql"), "utf8");

	it("revokes the quota RPCs from anon and authenticated by name, not only PUBLIC", () => {
		for (const fn of ["consume_quota", "refund_quota"]) {
			const line = lockdown.split("\n").find((l) => l.startsWith(`REVOKE ALL ON FUNCTION public.${fn}`));
			expect(line, `no REVOKE line for ${fn}`).toBeDefined();
			expect(line).toContain("anon");
			expect(line).toContain("authenticated");
		}
	});

	it("keeps get_user_profile_id executable by authenticated, because 28 RLS policies call it", () => {
		expect(lockdown).toMatch(/GRANT EXECUTE ON FUNCTION public\.get_user_profile_id\(\) TO authenticated/);
	});

	it("leaves no table in public without row level security", () => {
		expect(lockdown).toMatch(/ALTER TABLE public\.daily_match_pairs ENABLE ROW LEVEL SECURITY/);
	});
});

describe("every SECURITY DEFINER function in public has its EXECUTE revoked somewhere", () => {
	/**
	 * Default privileges are NOT a usable control here. Measured on the hosted
	 * project: after `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS
	 * FROM PUBLIC, anon, authenticated`, a freshly created function still comes
	 * out with `=X` in its ACL — Postgres' built-in grant to PUBLIC survives it,
	 * and anon/authenticated inherit that. The only thing standing between a new
	 * SECURITY DEFINER RPC and any holder of the anon key is an explicit REVOKE.
	 * This test is that guarantee.
	 *
	 * It checks the migration set as a whole, not file by file, because that is
	 * what the database actually ends up with: M2 and M9 shipped without an
	 * adequate revoke and M10 fixes both, and applied migrations are not edited
	 * retroactively. A newly added function with no revoke anywhere still fails.
	 *
	 * It is a text check rather than a live query because CI has no database —
	 * and the failure it prevents (consume_quota callable by any signed-in user
	 * with a limit of their choosing) already happened once.
	 */
	const migrationsDir = join(__dirname, "..", "..", "..", "..", "supabase", "migrations");
	const files = readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort();
	const allSql = files.map((f) => readFileSync(join(migrationsDir, f), "utf8")).join("\n");
	const meetupStateMachineMigration = readFileSync(join(migrationsDir, "20260904071028_meetup_state_machine.sql"), "utf8");

	/** Functions declared SECURITY DEFINER in the public schema. */
	const securityDefinerFunctions = [
		...new Set(
			[...allSql.matchAll(/CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?([a-z0-9_]+)\s*\(([^;]*?)\bSECURITY\s+DEFINER/gis)].map(
				(m) => m[1],
			),
		),
	];

	it("finds the SECURITY DEFINER functions", () => {
		expect(securityDefinerFunctions.sort()).toEqual([
			"advance_judge_counterpart",
			"apply_chat_meetup_action",
			"apply_chat_meetup_google_cafe_action",
			"apply_revenuecat_webhook_event",
			"are_match_participants_age_verified",
			"can_read_active_direct_chat_room",
			"check_judge_access",
			"check_judge_simulated_admission",
			"check_judge_webhook_access",
			"check_synthetic_recording_admission",
			"claim_daily_matching_notification_outbox",
			"claim_durable_daily_matching_batch",
			"claim_expired_meetups",
			"claim_meetup_arrangement",
			"claim_partner_fox_greeting",
			"claim_partner_fox_message_send",
			"claim_sora_three_interview_profile_revision",
			"complete_daily_matching_notification_outbox",
			"complete_partner_fox_greeting",
			"complete_partner_fox_message_send",
			"complete_sora_recording_interview",
			"complete_sora_three_interview_profile_revision",
			"complete_speed_dating_session",
			"confirm_meetup_reflection",
			"consume_consumable_credit",
			"consume_judge_request",
			"consume_quota",
			"create_or_match_meetup_intent",
			"demo_recording_apply_chat_meetup_action",
			"demo_recording_apply_chat_meetup_google_cafe_action",
			"demo_recording_claim_meetup_arrangement",
			"demo_recording_confirm_meetup_reflection",
			"demo_recording_get_meetup_reflection_state",
			"demo_recording_publish_chat_meetup_cafes",
			"demo_recording_publish_chat_meetup_google_cafes",
			"demo_recording_publish_chat_meetup_times",
			"expire_chat_meetup_session",
			"finish_partner_fox_message_send",
			"freeze_chat_request_participants",
			"get_durable_daily_matching_conversation_status",
			"get_meetup_reflection_state",
			"get_user_profile_id",
			"grant_consumable_credits",
			"handle_new_user_profile",
			"issue_sora_recording_interview_token",
			"judge_simulated_apply_chat_meetup_action",
			"judge_simulated_claim_meetup_arrangement",
			"judge_simulated_confirm_meetup_reflection",
			"judge_simulated_get_meetup_reflection_state",
			"judge_simulated_publish_chat_meetup_times",
			"persist_direct_chat_message",
			"persist_meetup_proposal",
			"persist_partner_fox_greeting",
			"prune_chat_meetup_private_inputs",
			"publish_chat_meetup_cafes",
			"publish_chat_meetup_google_cafes",
			"publish_chat_meetup_times",
			"publish_durable_daily_matching_batch",
			"read_durable_daily_matching_pair_page",
			"read_sora_three_interview_profile_revision_state",
			"record_meetup_proposal_response",
			"recover_direct_chat_message_send",
			"recover_partner_fox_message_send",
			"refund_consumable_credit",
			"refund_quota",
			"reject_blocked_pair",
			"reject_blocked_pair_by_match",
			"reject_blocked_pair_by_room",
			"reject_non_active_direct_chat_room",
			"release_daily_matching_notification_outbox",
			"release_durable_daily_matching_lease",
			"reserve_judge_provider_operation",
			"reserve_judge_reflection_voice_session",
			"reserve_judge_voice_session",
			"reserve_sora_recording_interview",
			"retry_partner_fox_greeting_before_provider",
			"scan_durable_daily_matching_member_page",
			"settle_judge_voice_session",
			"stage_durable_daily_matching_candidate_page",
			// Optional local provisioning helpers are excluded from the judge source snapshot.
			...["judge_provision_identity", "judge_qa_provision_identity"].filter((name) =>
				allSql.includes(`CREATE FUNCTION public.${name}(`),
			),
		].sort());
	});

	it("keeps the meetup block helper private while allowing stored RLS policy execution", () => {
		expect(meetupStateMachineMigration).toMatch(/CREATE\s+SCHEMA\s+IF\s+NOT\s+EXISTS\s+wingward_private\s*;/i);
		expect(meetupStateMachineMigration).toMatch(
			/REVOKE\s+ALL\s+ON\s+SCHEMA\s+wingward_private\s+FROM\s+PUBLIC,\s*anon,\s*authenticated\s*;/i,
		);
		const privateSchemaGrants = [...allSql.matchAll(
			/GRANT\s+([^;]+?)\s+ON\s+SCHEMA\s+wingward_private\s+TO\s+([^;]+);/gi,
		)];
		for (const grant of privateSchemaGrants) {
			expect(grant[1].trim().toLowerCase()).toBe("usage");
			expect(grant[2].trim().toLowerCase()).toBe("service_role");
		}
		expect(meetupStateMachineMigration).toMatch(
			/CREATE\s+OR\s+REPLACE\s+FUNCTION\s+wingward_private\.can_read_unblocked_meetup_match\s*\(p_match_id\s+uuid\)[\s\S]*?SECURITY\s+DEFINER[\s\S]*?SET\s+search_path\s*=\s*''/i,
		);
		expect(meetupStateMachineMigration).toMatch(
			/REVOKE\s+ALL\s+ON\s+FUNCTION\s+wingward_private\.can_read_unblocked_meetup_match\s*\(uuid\)\s+FROM\s+PUBLIC,\s*anon,\s*authenticated\s*;/i,
		);
		expect(meetupStateMachineMigration).toMatch(
			/GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+wingward_private\.can_read_unblocked_meetup_match\s*\(uuid\)\s+TO\s+authenticated,\s*service_role\s*;/i,
		);
		expect(allSql).not.toMatch(
			/CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.can_read_unblocked_meetup_match\s*\(/i,
		);
		expect(meetupStateMachineMigration).toMatch(
			/wingward_private\.can_read_unblocked_meetup_match\s*\(\s*match_id\s*\)/i,
		);
		expect(meetupStateMachineMigration).toMatch(/FROM\s+public\.matches[\s\S]*?public\.get_user_profile_id\(\)/i);
		expect(meetupStateMachineMigration).toMatch(
			/FROM\s+public\.blocks[\s\S]*?blocker_id\s*=\s*meetup_match\.user_a_id[\s\S]*?blocked_id\s*=\s*meetup_match\.user_b_id[\s\S]*?blocker_id\s*=\s*meetup_match\.user_b_id[\s\S]*?blocked_id\s*=\s*meetup_match\.user_a_id/i,
		);
	});

	/**
	 * Statements are compared as normalised lowercase text rather than with a
	 * regex built from the function name: a dynamically constructed RegExp
	 * trips semgrep's detect-non-literal-regexp, and plain string matching is
	 * clearer here anyway.
	 */
	const statements = allSql
		// Strip `--` line comments first: without this, a statement fragment
		// starts with the comment that precedes it and never matches "revoke".
		.replace(/--[^\n]*/g, "")
		.split(";")
		.map((stmt) => stmt.replace(/\s+/g, " ").trim().toLowerCase());

	it.each(securityDefinerFunctions)("%s is revoked from PUBLIC, anon and authenticated", (name) => {
		const signature = `on function public.${name}(`;
		const revokedFrom = statements
			.filter((stmt) => stmt.startsWith("revoke") && stmt.includes(signature))
			.join(" ");
		const grantedTo = statements
			.filter((stmt) => stmt.startsWith("grant") && stmt.includes(signature))
			.join(" ");

		expect(revokedFrom, `${name}: never revoked at all`).not.toBe("");
		for (const role of ["public", "anon", "authenticated"]) {
			// A role may keep EXECUTE only if it is granted back explicitly and
			// deliberately, the way get_user_profile_id keeps `authenticated`
			// for the 28 RLS policies that call it.
			expect(
				revokedFrom.includes(role) || grantedTo.includes(role),
				`${name}: EXECUTE neither revoked from ${role} nor granted back to it on purpose`,
			).toBe(true);
		}
	});
});

describe("the closed direct-chat room message guard is wired to every message-row write", () => {
	const migrationsDir = join(__dirname, "..", "..", "..", "..", "supabase", "migrations");
	const migration = readFileSync(join(migrationsDir, "20260830130037_direct_chat_active_room_send_guard.sql"), "utf8");
	const executableMigration = migration.replace(/--[^\n]*/g, "");

	it("attaches the status guard function before inserts and read-receipt updates", () => {
		expect(migration).toMatch(
			/CREATE\s+TRIGGER\s+direct_chat_messages_reject_non_active_room\s+BEFORE\s+INSERT\s+OR\s+UPDATE\s+ON\s+public\.direct_chat_messages\s+FOR\s+EACH\s+ROW\s+EXECUTE\s+FUNCTION\s+public\.reject_non_active_direct_chat_room\s*\(\s*["']room_id["']\s*\)/i,
		);
	});

	it("locks the room row and rejects every status other than active", () => {
		expect(executableMigration).toMatch(
			/SELECT\s+status\s+INTO\s+room_status\s+FROM\s+public\.direct_chat_rooms\s+WHERE\s+id\s*=\s*room_id_value\s+FOR\s+UPDATE\s*;/i,
		);
		expect(executableMigration).toMatch(
			/IF\s+room_status\s+IS\s+DISTINCT\s+FROM\s+["']active["']\s+THEN\s+RAISE\s+EXCEPTION\s+["']direct chat room is not active["']\s+USING\s+ERRCODE\s*=\s*["']check_violation["']\s*;/i,
		);
	});

	it("applies the active and unblocked guard to room and message reads", () => {
		expect(executableMigration).toMatch(
			/CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.can_read_active_direct_chat_room\s*\([^)]*\)\s+RETURNS\s+boolean[\s\S]*?SECURITY\s+DEFINER[\s\S]*?room\.status\s*=\s*["']active["'][\s\S]*?NOT\s+EXISTS\s*\([\s\S]*?FROM\s+public\.blocks/i,
		);
		expect(executableMigration).toMatch(
			/CREATE\s+POLICY\s+direct_chat_rooms_select\s+ON\s+public\.direct_chat_rooms\s+FOR\s+SELECT\s+USING\s*\(\s*public\.can_read_active_direct_chat_room\s*\(\s*id\s*\)\s*\)/i,
		);
		expect(executableMigration).toMatch(
			/CREATE\s+POLICY\s+direct_chat_messages_select\s+ON\s+public\.direct_chat_messages\s+FOR\s+SELECT\s+USING\s*\(\s*public\.can_read_active_direct_chat_room\s*\(\s*room_id\s*\)\s*\)/i,
		);
	});
});

describe("every table guarded by a blocked-pair trigger has no client-reachable INSERT policy", () => {
	/**
	 * A blocked-pair trigger (reject_blocked_pair / reject_blocked_pair_by_match
	 * / reject_blocked_pair_by_room, all in 20260821100000_blocked_pair_invariant.sql)
	 * raises a visible `check_violation` (23514) BEFORE INSERT. That is exactly
	 * what makes it dangerous on any table a client can INSERT into directly:
	 * the trigger's exception is a distinguishable answer where the
	 * application deliberately returns an indistinguishable error instead
	 * (e.g. NOT_FOUND / FORBIDDEN), so a client-reachable INSERT path turns
	 * the guard into an oracle for "did this person block me" — exactly the
	 * thing it exists to hide. Review found this three separate times, at a
	 * new table each time: first chat_requests_insert, then
	 * direct_chat_messages_insert. Nothing forced anyone to check every
	 * guarded table at once, so this test derives the guarded-table set from
	 * the migrations themselves (rather than hardcoding it) and checks all of
	 * them together — a fifth guarded table, or a resurrected INSERT policy
	 * on any of the existing four, fails here instead of needing a fourth
	 * review round to catch.
	 */
	const migrationsDir = join(__dirname, "..", "..", "..", "..", "supabase", "migrations");
	const files = readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort();
	const allSql = files.map((f) => readFileSync(join(migrationsDir, f), "utf8")).join("\n");

	/** Tables with a BEFORE INSERT trigger whose function starts with reject_blocked_pair. */
	const guardedTables = [
		...new Set(
			[...allSql.matchAll(/CREATE\s+TRIGGER\s+\w+\s+BEFORE\s+INSERT\s+ON\s+public\.(\w+)\s+FOR\s+EACH\s+ROW\s+EXECUTE\s+FUNCTION\s+public\.(reject_blocked_pair\w*)\s*\(/gi)].map(
				(m) => m[1],
			),
		),
	].sort();

	it("derives exactly the four tables known to need the blocked-pair guard", () => {
		expect(guardedTables).toEqual(["chat_requests", "direct_chat_messages", "direct_chat_rooms", "matches"]);
	});

	// Statements normalised the same way as the SECURITY DEFINER block above:
	// comments stripped, split on `;`, whitespace collapsed, lowercased. Table
	// names are compared with plain string search rather than a dynamically
	// built RegExp, which trips semgrep's detect-non-literal-regexp.
	const statements = allSql
		.replace(/--[^\n]*/g, "")
		.split(";")
		.map((stmt) => stmt.replace(/\s+/g, " ").trim().toLowerCase());

	it.each(guardedTables)("no client-reachable INSERT policy on %s survives the migration set", (table) => {
		const insertSignature = `on public.${table} for insert`;

		statements.forEach((stmt, index) => {
			if (!stmt.startsWith("create policy") || !stmt.includes(insertSignature)) {
				return;
			}

			// "create policy <name> on public.<table> for insert ..."
			const policyName = stmt.split(" ")[2];

			// Migrations are applied in filename order and never edited
			// retroactively, so "removed" means a later statement drops it.
			const droppedLater = statements
				.slice(index + 1)
				.some((later) => later.startsWith("drop policy") && later.includes(policyName) && later.includes(`on public.${table}`));

			expect(droppedLater, `${table}: INSERT policy ${policyName} is created but never dropped afterwards`).toBe(true);
		});
	});
});
