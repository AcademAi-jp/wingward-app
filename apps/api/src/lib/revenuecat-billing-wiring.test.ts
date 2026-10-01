import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Static guards for the additive RevenueCat billing migration. The API uses
 * the service_role client, so these checks protect the database boundary even
 * when a local Supabase instance is not available in CI.
 */
const migrationsDir = join(__dirname, "..", "..", "..", "..", "supabase", "migrations");
const migrationName = "20260904071046_revenuecat_billing.sql";
const sql = readFileSync(join(migrationsDir, migrationName), "utf8");
const atomicMigrationName = "20260904072758_apply_revenuecat_webhook_event_atomically.sql";
const atomicSql = readFileSync(join(migrationsDir, atomicMigrationName), "utf8");
const nullableIdentityMigrationName = "20260904074400_revenuecat_nullable_identity.sql";
const nullableIdentitySql = readFileSync(join(migrationsDir, nullableIdentityMigrationName), "utf8");

describe("RevenueCat billing migration", () => {
	it("adds durable event idempotency and ordering metadata without retaining a body", () => {
		expect(sql).toMatch(/CREATE TABLE public\.revenuecat_webhook_events/);
		expect(sql).toMatch(/event_id text NOT NULL UNIQUE/);
		expect(sql).toMatch(/effective_at timestamptz NOT NULL/);
		expect(sql).toMatch(/processing_status text NOT NULL DEFAULT 'received'/);
		expect(sql).toMatch(/entitlement_applied boolean NOT NULL DEFAULT false/);
		expect(sql).toMatch(/ALTER TABLE public\.entitlements[\s\S]*last_webhook_event_at/);
		expect(sql).toMatch(/last_webhook_event_id text/);
		expect(sql).not.toMatch(/raw_body|request_body|webhook_body/i);
	});

	it("has RLS enabled and no client grants on every new table", () => {
		for (const [table, grant] of [
			["revenuecat_webhook_events", "SELECT, INSERT, UPDATE"],
			["consumable_credit_balances", "SELECT"],
			["consumable_credit_ledger", "SELECT"],
		]) {
			expect(sql).toContain(`ALTER TABLE public.${table} ENABLE ROW LEVEL SECURITY`);
			expect(sql).toContain(`REVOKE ALL ON TABLE public.${table} FROM PUBLIC, anon, authenticated`);
			expect(sql).toContain(`GRANT ${grant} ON TABLE public.${table} TO service_role`);
		}
	});

	it("keeps the ledger append-only in the schema and keys entries for idempotency", () => {
		expect(sql).toMatch(/delta integer NOT NULL CHECK \(delta <> 0\)/);
		expect(sql).toMatch(/entry_type text NOT NULL CHECK \(entry_type IN \('purchase', 'consume', 'refund', 'adjustment'\)\)/);
		expect(sql).toMatch(/UNIQUE \(user_id, entry_type, reference_id\)/);
		expect(sql).toMatch(/CREATE UNIQUE INDEX idx_consumable_credit_purchase_reference[\s\S]*WHERE entry_type = 'purchase'/);
		expect(sql).not.toMatch(/CREATE POLICY[\s\S]*consumable_credit_/i);
	});

	it.each([
		["grant_consumable_credits", "(uuid, text, integer)"],
		["consume_consumable_credit", "(uuid, text)"],
		["refund_consumable_credit", "(uuid, text)"],
	])("restricts %s to service_role and fixes its search path", (name, signature) => {
		const definition = `CREATE OR REPLACE FUNCTION public.${name}`;
		const definitionStart = sql.indexOf(definition);
		expect(definitionStart).toBeGreaterThanOrEqual(0);
		const definitionEnd = sql.indexOf("$$;", definitionStart);
		const body = sql.slice(definitionStart, definitionEnd < 0 ? undefined : definitionEnd);
		expect(body).toMatch(/SECURITY DEFINER/);
		expect(body).toMatch(/SET search_path = ''/);
		expect(sql).toContain(`REVOKE ALL ON FUNCTION public.${name}${signature} FROM PUBLIC, anon, authenticated`);
		expect(sql).toContain(`GRANT EXECUTE ON FUNCTION public.${name}${signature} TO service_role`);
	});

	it("locks one balance row before grant, consume, and refund mutations", () => {
		const functionBodies = [...sql.matchAll(/CREATE OR REPLACE FUNCTION public\.(grant_consumable_credits|consume_consumable_credit|refund_consumable_credit)[\s\S]*?\$\$;\n/g)].map(
			(match) => match[0],
		);
		expect(functionBodies).toHaveLength(3);
		for (const body of functionBodies) {
			expect(body).toMatch(/FOR UPDATE/);
			expect(body).toMatch(/consumable_credit_balances/);
			expect(body).toMatch(/consumable_credit_ledger/);
		}
	});

	it("makes consume and refund idempotent by reference and keeps balance non-negative", () => {
		expect(sql).toMatch(/balance integer NOT NULL DEFAULT 0 CHECK \(balance >= 0\)/);
		expect(sql).toMatch(/entry_type = 'consume'[\s\S]*reference_id = p_reference_id/);
		expect(sql).toMatch(/entry_type = 'refund'[\s\S]*reference_id = p_reference_id/);
		expect(sql).toMatch(/IF current_balance <= 0 THEN[\s\S]*RETURN false/);
	});

	it("applies normalized webhook events through one service-role-only transaction", () => {
		expect(atomicSql).toMatch(/CREATE OR REPLACE FUNCTION public\.apply_revenuecat_webhook_event/);
		expect(atomicSql).toMatch(/SECURITY DEFINER/);
		expect(atomicSql).toMatch(/SET search_path = ''/);
		expect(atomicSql).toMatch(/INSERT INTO public\.revenuecat_webhook_events[\s\S]*ON CONFLICT \(event_id\) DO NOTHING/);
		expect(atomicSql).toMatch(/INSERT INTO public\.entitlements[\s\S]*ON CONFLICT \(user_id\) DO UPDATE/);
		expect(atomicSql).toMatch(/public\.grant_consumable_credits\([\s\S]*resolved_user_id,[\s\S]*p_event_id/);
		expect(atomicSql).toContain(
			"GRANT EXECUTE ON FUNCTION public.apply_revenuecat_webhook_event(\n  text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer\n) TO service_role",
		);
		expect(atomicSql).toContain(
			"FROM PUBLIC, anon, authenticated",
		);
		expect(atomicSql).toContain(
			"REVOKE ALL ON FUNCTION public.apply_revenuecat_webhook_event(\n  text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer\n) FROM PUBLIC, anon, authenticated",
		);
	});

	it("resolves the profile from the RevenueCat app user id and accepts no profile id", () => {
		const signature = atomicSql.slice(
			atomicSql.indexOf("CREATE OR REPLACE FUNCTION public.apply_revenuecat_webhook_event"),
			atomicSql.indexOf(") RETURNS TABLE"),
		);
		expect(signature).not.toMatch(/\bp_user_id\b|\bp_profile_id\b/);
		expect(atomicSql).toMatch(/profile\.auth_user_id::text = p_rc_app_user_id/);
		expect(atomicSql).toMatch(/IF resolved_user_id IS NULL OR p_action = 'ignored'/);
	});

	it("uses a conditional upsert so older events cannot roll back entitlement state", () => {
		expect(atomicSql).toMatch(
			/EXCLUDED\.last_webhook_event_at > public\.entitlements\.last_webhook_event_at/,
		);
		expect(atomicSql).toMatch(
			/EXCLUDED\.last_webhook_event_at = public\.entitlements\.last_webhook_event_at[\s\S]*EXCLUDED\.last_webhook_event_id COLLATE "C"[\s\S]*public\.entitlements\.last_webhook_event_id COLLATE "C"/,
		);
		expect(atomicSql).toMatch(/Subscription ordering is the tuple \(effective_at, event_id\)/);
		expect(atomicSql).toMatch(/A larger event[\s\S]*same effective_at/);
		expect(atomicSql).toMatch(/result_status := CASE WHEN entitlement_was_applied THEN 'processed' ELSE 'ignored' END/);
	});

	it("removes split webhook writes and direct purchase grants from service_role", () => {
		expect(atomicSql).toContain(
			"REVOKE INSERT, UPDATE ON TABLE public.revenuecat_webhook_events FROM service_role",
		);
		expect(atomicSql).toContain(
			"REVOKE ALL ON FUNCTION public.grant_consumable_credits(uuid, text, integer) FROM service_role",
		);
		expect(atomicSql).toContain(
			"REVOKE ALL ON TABLE public.entitlements FROM service_role",
		);
		expect(atomicSql).toContain(
			"GRANT SELECT ON TABLE public.entitlements TO service_role",
		);
	});

	it("allows NULL app-user IDs only for ignored events and keeps the atomic boundary", () => {
		expect(nullableIdentitySql).toMatch(
			/ALTER TABLE public\.revenuecat_webhook_events\s+ALTER COLUMN rc_app_user_id DROP NOT NULL/,
		);
		expect(nullableIdentitySql).toMatch(
			/CREATE OR REPLACE FUNCTION public\.apply_revenuecat_webhook_event/,
		);
		expect(nullableIdentitySql).toMatch(
			/\(p_rc_app_user_id IS NULL AND p_action <> 'ignored'\)/,
		);
		expect(nullableIdentitySql).toMatch(
			/INSERT INTO public\.revenuecat_webhook_events[\s\S]*p_rc_app_user_id/,
		);
		expect(nullableIdentitySql).toMatch(
			/IF resolved_user_id IS NULL OR p_action = 'ignored'/,
		);
		expect(nullableIdentitySql).toMatch(/SECURITY DEFINER/);
		expect(nullableIdentitySql).toMatch(/SET search_path = ''/);
		expect(nullableIdentitySql).toContain(
			"REVOKE INSERT, UPDATE ON TABLE public.revenuecat_webhook_events FROM service_role",
		);
		expect(nullableIdentitySql).toContain(
			"REVOKE ALL ON TABLE public.entitlements FROM service_role",
		);
		expect(nullableIdentitySql).toContain(
			"REVOKE ALL ON FUNCTION public.apply_revenuecat_webhook_event(\n  text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer\n) FROM PUBLIC, anon, authenticated",
		);
		expect(nullableIdentitySql).toContain(
			"GRANT EXECUTE ON FUNCTION public.apply_revenuecat_webhook_event(\n  text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer\n) TO service_role",
		);
	});
});
