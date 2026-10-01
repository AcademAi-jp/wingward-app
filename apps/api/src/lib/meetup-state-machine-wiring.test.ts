import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

// Executed by ordinary CI. These are source tripwires, NOT proof of SQL runtime
// behavior. The SQL acceptance suite is a MANUAL procedure; no CI job runs it.
// Local synthetic SQL results from 2026-09-06 are recorded in
// docs/meetups-integration-notes.md. Exact-head independent review still gates merge.
type MigrationSource = {
	name: string;
	sql: string;
};

const migrationDir = join(__dirname, "../../../../supabase/migrations");
const migrationSources: MigrationSource[] = readdirSync(migrationDir)
	.filter((name) => name.endsWith(".sql"))
	.sort()
	.map((name) => ({
		name,
		sql: readFileSync(join(migrationDir, name), "utf8"),
	}));
const sql = migrationSources.map(({ sql: migrationSql }) => migrationSql).join("\n").replace(/--[^\n]*/g, "");

const functionPatterns = {
	create_or_match_meetup_intent: {
		create: /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.create_or_match_meetup_intent\s*\([\s\S]*?\$\$;/gi,
		drop: /DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?public\.create_or_match_meetup_intent(?:\s*\([^;]*\))?(?:\s+CASCADE)?\s*;/gi,
	},
	record_meetup_proposal_response: {
		create: /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.record_meetup_proposal_response\s*\([\s\S]*?\$\$;/gi,
		drop: /DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?public\.record_meetup_proposal_response(?:\s*\([^;]*\))?(?:\s+CASCADE)?\s*;/gi,
	},
} as const;
type MeetupFunctionName = keyof typeof functionPatterns;

function latestFunctionDefinition(functionName: MeetupFunctionName, sources: MigrationSource[] = migrationSources): string {
	let latest: string | undefined;

	for (const source of [...sources].sort((left, right) => left.name.localeCompare(right.name))) {
		const patterns = functionPatterns[functionName];
		const events: Array<{ position: number; kind: "create" | "drop"; definition?: string }> = [];
		for (const match of source.sql.matchAll(patterns.drop)) {
			events.push({ position: match.index ?? 0, kind: "drop" });
		}
		for (const match of source.sql.matchAll(patterns.create)) {
			events.push({ position: match.index ?? 0, kind: "create", definition: match[0] });
		}

		for (const event of events.sort((left, right) => left.position - right.position)) {
			latest = event.kind === "drop" ? undefined : event.definition;
		}
	}

	if (latest === undefined) {
		throw new Error(`Could not find public.${functionName} in sorted migration sources`);
	}
	return latest.replace(/--[^\n]*/g, "");
}

const meetupsSelectPolicyPatterns = {
	create: /CREATE\s+POLICY\s+meetups_select\s+ON\s+public\.meetups\b[\s\S]*?;/gi,
	drop: /DROP\s+POLICY\s+(?:IF\s+EXISTS\s+)?meetups_select\s+ON\s+public\.meetups\s*;/gi,
	alter: /ALTER\s+POLICY\s+meetups_select\s+ON\s+public\.meetups\b[\s\S]*?;/gi,
} as const;

type MeetupsSelectPolicyEvent = {
	position: number;
	kind: "create" | "drop" | "alter";
	statement?: string;
};

type ParenthesizedClause = {
	start: number;
	end: number;
	text: string;
};

function extractUsingClause(statement: string): ParenthesizedClause | undefined {
	const marker = /\bUSING\s*\(/i.exec(statement);
	if (!marker) {
		return undefined;
	}

	const openParenthesis = statement.indexOf("(", marker.index);
	let depth = 0;
	let inString = false;
	for (let index = openParenthesis; index < statement.length; index += 1) {
		const character = statement[index];
		if (character === "'") {
			if (inString && statement[index + 1] === "'") {
				index += 1;
				continue;
			}
			inString = !inString;
			continue;
		}
		if (inString) {
			continue;
		}
		if (character === "(") {
			depth += 1;
		} else if (character === ")") {
			depth -= 1;
			if (depth === 0) {
				return {
					start: marker.index,
					end: index + 1,
					text: statement.slice(marker.index, index + 1),
				};
			}
		}
	}

	return undefined;
}

function replaceUsingClause(statement: string, replacement: ParenthesizedClause): string {
	const existing = extractUsingClause(statement);
	if (!existing) {
		return statement;
	}
	return `${statement.slice(0, existing.start)}${replacement.text}${statement.slice(existing.end)}`;
}

function latestMeetupsSelectPolicy(sources: MigrationSource[] = migrationSources): string | undefined {
	let latest: string | undefined;

	for (const source of [...sources].sort((left, right) => left.name.localeCompare(right.name))) {
		const sourceSql = source.sql.replace(/--[^\n]*/g, "");
		const events: MeetupsSelectPolicyEvent[] = [];
		for (const match of sourceSql.matchAll(meetupsSelectPolicyPatterns.drop)) {
			events.push({ position: match.index ?? 0, kind: "drop" });
		}
		for (const match of sourceSql.matchAll(meetupsSelectPolicyPatterns.create)) {
			events.push({ position: match.index ?? 0, kind: "create", statement: match[0] });
		}
		for (const match of sourceSql.matchAll(meetupsSelectPolicyPatterns.alter)) {
			events.push({ position: match.index ?? 0, kind: "alter", statement: match[0] });
		}

		for (const event of events.sort((left, right) => left.position - right.position)) {
			if (event.kind === "drop") {
				latest = undefined;
			} else if (event.kind === "create") {
				latest = event.statement;
			} else if (latest && event.statement) {
				const replacement = extractUsingClause(event.statement);
				if (replacement) {
					latest = replaceUsingClause(latest, replacement);
				}
			}
		}
	}

	return latest?.replace(/--[^\n]*/g, "");
}

function assertMeetupsSelectPolicy(definition: string | undefined): void {
	expect(definition, "could not resolve the current public.meetups meetups_select policy").toBeDefined();
	const usingClause = extractUsingClause(definition!);
	expect(usingClause, "meetups_select must define a USING clause").toBeDefined();
	const normalizedUsing = usingClause!.text.replace(/\s+/g, " ").trim().toLowerCase().replace(/\s*([()])\s*/g, "$1");
	expect(normalizedUsing).toBe(
		"using ( public.get_user_profile_id() in ( select user_a_id from public.matches where id = match_id union all select user_b_id from public.matches where id = match_id ) and public.are_match_participants_age_verified(match_id) and ( initiator_id = public.get_user_profile_id() or ( intent_a_at is not null and intent_b_at is not null ) ) and wingward_private.can_read_unblocked_meetup_match(match_id) )".replace(/\s*([()])\s*/g, "$1"),
	);
}

const intent = latestFunctionDefinition("create_or_match_meetup_intent");
const response = latestFunctionDefinition("record_meetup_proposal_response");
const meetupsSelectPolicy = latestMeetupsSelectPolicy();

function assertResponseLockOrder(body: string): void {
	const match = body.indexOf("FROM public.matches");
	const room = body.indexOf("FROM public.direct_chat_rooms");
	const meetup = body.indexOf("WHERE id = p_meetup_id AND match_id = v_match.id");
	expect(match).toBeGreaterThan(0);
	expect(room).toBeGreaterThan(match);
	expect(meetup).toBeGreaterThan(room);
	expect(body.slice(match, room)).toContain("FOR UPDATE;");
	expect(body.slice(meetup)).toMatch(/^WHERE id = p_meetup_id AND match_id = v_match\.id\s+FOR UPDATE;/);
	expect(body.indexOf("v_room.status IS DISTINCT FROM 'active'")).toBeLessThan(body.indexOf("IF v_meetup.status = 'confirmed'"));
}

describe("Meetup transition security wiring", () => {
	it.each([intent, response])("keeps caller, age, block and room gates in both transitions", (body) => {
		expect(body).toContain("p_user_id <> v_match.user_a_id AND p_user_id <> v_match.user_b_id");
		expect(body).toContain("age_verified_at IS NOT NULL");
		expect(body).toContain("blocker_id = v_match.user_a_id AND blocked_id = v_match.user_b_id");
		expect(body).toContain("blocker_id = v_match.user_b_id AND blocked_id = v_match.user_a_id");
		expect(body).toContain("v_match.status IS DISTINCT FROM 'direct_chat_active'");
		expect(body).toMatch(/FROM public\.direct_chat_rooms\s+WHERE match_id = [^;]+FOR UPDATE;/);
		expect(body).toMatch(/IF NOT FOUND OR v_room\.status IS DISTINCT FROM 'active' THEN\s+RETURN QUERY SELECT[^;]+'not_found'/);
		expect(body).toMatch(/SECURITY DEFINER\s+SET search_path = ''/);
	});

	it("rejects a superseded proposal before expiry, replay or writes", () => {
		expect(response).toMatch(/FROM public\.meetup_proposals\s+WHERE meetup_proposals\.meetup_id = p_meetup_id\s+ORDER BY attempt_number DESC\s+LIMIT 1\s+FOR UPDATE;/);
		const guard = response.indexOf("IF NOT FOUND OR v_proposal.id IS DISTINCT FROM p_proposal_id THEN");
		expect(guard).toBeGreaterThan(0);
		expect(response.slice(guard)).toMatch(/^IF NOT FOUND OR v_proposal\.id IS DISTINCT FROM p_proposal_id THEN\s+RETURN QUERY SELECT[^;]+'not_found'/);
		for (const transition of ["IF v_meetup.status = 'confirmed'", "v_proposal.expires_at", "INSERT INTO public.meetup_proposal_responses", "UPDATE public.meetups"]) {
			expect(guard).toBeLessThan(response.indexOf(transition));
		}
	});

	it("locks match then room then the parent-bound meetup before responding", () => {
		assertResponseLockOrder(response);
	});

	it("resolves the latest meetups_select policy with every privacy gate", () => {
		assertMeetupsSelectPolicy(meetupsSelectPolicy);
	});

	it("rejects a later weakened meetups_select CREATE", () => {
		const syntheticLaterCreate: MigrationSource = {
			name: "99999999999996_synthetic_weakened_meetups_create.sql",
			sql: `
DROP POLICY IF EXISTS meetups_select ON public.meetups;
CREATE POLICY meetups_select ON public.meetups FOR SELECT USING (true);
`,
		};

		expect(() => assertMeetupsSelectPolicy(latestMeetupsSelectPolicy([...migrationSources, syntheticLaterCreate]))).toThrow();
	});

	it("rejects a later weakened meetups_select ALTER", () => {
		const syntheticLaterAlter: MigrationSource = {
			name: "99999999999995_synthetic_weakened_meetups_alter.sql",
			sql: "ALTER POLICY meetups_select ON public.meetups USING (true);",
		};

		expect(() => assertMeetupsSelectPolicy(latestMeetupsSelectPolicy([...migrationSources, syntheticLaterAlter]))).toThrow();
	});

	it("rejects an ALTER that weakens the existing intent gate", () => {
		const syntheticWeakenedIntentAlter: MigrationSource = {
			name: "99999999999993_synthetic_weakened_intent_alter.sql",
			sql: "ALTER POLICY meetups_select ON public.meetups USING (public.get_user_profile_id() IN (SELECT user_a_id FROM public.matches WHERE id = match_id) AND (intent_a_at IS NOT NULL OR true) AND wingward_private.can_read_unblocked_meetup_match(match_id));",
		};

		expect(() => assertMeetupsSelectPolicy(latestMeetupsSelectPolicy([...migrationSources, syntheticWeakenedIntentAlter]))).toThrow();
	});

	it("rejects a later meetups_select DROP", () => {
		const syntheticLaterDrop: MigrationSource = {
			name: "99999999999994_synthetic_meetups_drop.sql",
			sql: "DROP POLICY IF EXISTS meetups_select ON public.meetups;",
		};

		expect(() => assertMeetupsSelectPolicy(latestMeetupsSelectPolicy([...migrationSources, syntheticLaterDrop]))).toThrow();
	});

	it("resolves a later same-name migration override instead of the pinned base file", () => {
		const syntheticLaterOverride: MigrationSource = {
			name: "99999999999999_synthetic_later_override.sql",
			sql: `
CREATE OR REPLACE FUNCTION public.record_meetup_proposal_response(
  p_meetup_id uuid,
  p_proposal_id uuid,
  p_user_id uuid,
  p_candidate_index integer
)
RETURNS TABLE (
  meetup_id uuid,
  proposal_id uuid,
  outcome text,
  status text,
  confirmed_candidate_index integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'synthetic_later_override'::text, NULL::text, NULL::integer;
END;
$$;
`,
		};
		const resolved = latestFunctionDefinition("record_meetup_proposal_response", [
			...migrationSources,
			syntheticLaterOverride,
		]);

		expect(resolved).toContain("synthetic_later_override");
		expect(() => assertResponseLockOrder(resolved)).toThrow();
	});

	it("applies a later DROP followed by CREATE in statement order", () => {
		const syntheticDropThenCreate: MigrationSource = {
			name: "99999999999998_synthetic_drop_create.sql",
			sql: `
DROP FUNCTION IF EXISTS public.record_meetup_proposal_response(uuid,uuid,uuid,integer);
CREATE FUNCTION public.record_meetup_proposal_response(
  p_meetup_id uuid,
  p_proposal_id uuid,
  p_user_id uuid,
  p_candidate_index integer
)
RETURNS TABLE (
  meetup_id uuid,
  proposal_id uuid,
  outcome text,
  status text,
  confirmed_candidate_index integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'synthetic_drop_create'::text, NULL::text, NULL::integer;
END;
$$;
`,
		};
		const resolved = latestFunctionDefinition("record_meetup_proposal_response", [
			...migrationSources,
			syntheticDropThenCreate,
		]);

		expect(resolved).toContain("synthetic_drop_create");
		expect(() => assertResponseLockOrder(resolved)).toThrow();
	});

	it("clears a latest definition after a bare DROP", () => {
		const syntheticBareDrop: MigrationSource = {
			name: "99999999999997_synthetic_bare_drop.sql",
			sql: "DROP FUNCTION public.record_meetup_proposal_response(uuid,uuid,uuid,integer);",
		};

		expect(() =>
			latestFunctionDefinition("record_meetup_proposal_response", [
				...migrationSources,
				syntheticBareDrop,
			]),
		).toThrow(/Could not find public\.record_meetup_proposal_response/);
	});

	it("keeps identity status and timestamp checks and prevents direct client writes", () => {
		expect(response).toContain("identity_verification_status = 'verified'");
		expect(response).toContain("identity_verified_at IS NOT NULL");
		expect(sql).toMatch(/DROP POLICY IF EXISTS meetups_insert ON public\.meetups;/);
		expect(sql).toMatch(/DROP POLICY IF EXISTS meetup_proposal_responses_insert\s+ON public\.meetup_proposal_responses;/);
	});

	it("qualifies SQL predicates that share names with RETURNS TABLE variables", () => {
		for (const body of [intent, response]) {
			expect(body).not.toMatch(/(?:WHERE|AND|OR)\s+(?:status|proposal_id|meetup_id)\s*(?:=|IN\b)/);
		}
	});
});
