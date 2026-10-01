import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAgeVerified, requireAuth } from "../middleware/auth";
import { jsonData, jsonError } from "../lib/response";

export type BillingRouteOptions = {
	nowMs?: () => number;
};

const BILLING_STATUS_ERROR = "Billing status unavailable";
const MAX_CREDIT_BALANCE = 1_000_000;

type BillingStatusResponse = {
	is_active: boolean;
	product_id: string | null;
	store: string | null;
	current_period_end: string | null;
	consumable_credits: number;
};

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function inactiveBillingStatus(consumableCredits = 0): BillingStatusResponse {
	return {
		is_active: false,
		product_id: null,
		store: null,
		current_period_end: null,
		consumable_credits: consumableCredits,
	};
}

function readNullableString(value: unknown, maxLength: number): string | null {
	if (value === null) return null;
	if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
		throw new Error("invalid billing string");
	}
	return value;
}

function readCurrentPeriodEnd(value: unknown): string | null {
	if (value === null) return null;
	if (typeof value !== "string") throw new Error("invalid billing period");
	const timestamp = Date.parse(value);
	if (!Number.isFinite(timestamp)) throw new Error("invalid billing period");
	return new Date(timestamp).toISOString();
}

function readEntitlementStatus(row: unknown, nowMs: number): BillingStatusResponse {
	if (row === null) return inactiveBillingStatus();
	if (!isRecord(row) || typeof row.is_active !== "boolean") {
		throw new Error("invalid entitlement row");
	}

	const productID = readNullableString(row.product_id, 255);
	const store = readNullableString(row.store, 64);
	const currentPeriodEnd = readCurrentPeriodEnd(row.current_period_end);
	if (row.is_active && productID === null) throw new Error("active entitlement has no product");

	const isActive = row.is_active &&
		(currentPeriodEnd === null || Date.parse(currentPeriodEnd) > nowMs);
	if (!isActive) return inactiveBillingStatus();
	return {
		is_active: true,
		product_id: productID,
		store,
		current_period_end: currentPeriodEnd,
		consumable_credits: 0,
	};
}

function readCreditBalance(row: unknown): number {
	if (row === null) return 0;
	if (
		!isRecord(row) ||
		!Number.isSafeInteger(row.balance) ||
		(row.balance as number) < 0 ||
		(row.balance as number) > MAX_CREDIT_BALANCE
	) {
		throw new Error("invalid credit balance");
	}
	return row.balance as number;
}

/**
 * GET /api/billing/identity
 *
 * RevenueCat uses the Supabase auth user UUID as its appUserID, while the
 * native API is bound to the user_profiles.id UUID. Query and compare both
 * server-resolved identities before returning either value. Never look up an
 * arbitrary profile or expose an auth ID from another row.
 */
export function createBillingRoute(options: BillingRouteOptions = {}) {
	const billing = new Hono<Env>();
	const nowMs = options.nowMs ?? (() => Date.now());

	billing.get("/identity", requireAuth, requireAgeVerified, async (c) => {
		const profileID = c.get("user_id");
		const authUserID = c.get("auth_user_id");
		if (!profileID || !authUserID) {
			return jsonError(c, "NOT_FOUND", "Billing identity unavailable");
		}

		const { data, error } = await getSupabaseClient(c.env)
			.from("user_profiles")
			.select("id, auth_user_id")
			.eq("id", profileID)
			.eq("auth_user_id", authUserID)
			.maybeSingle();

		if (error || !data || data.id !== profileID || data.auth_user_id !== authUserID) {
			return jsonError(c, "NOT_FOUND", "Billing identity unavailable");
		}

		return jsonData(c, { profile_id: data.id, app_user_id: data.auth_user_id });
	});

	billing.get("/status", requireAuth, requireAgeVerified, async (c) => {
		const profileID = c.get("user_id");
		if (!profileID) return jsonError(c, "NOT_FOUND", BILLING_STATUS_ERROR);

		let now: number;
		try {
			now = nowMs();
			if (!Number.isFinite(now)) throw new Error("invalid clock");
		} catch {
			return jsonError(c, "INTERNAL_ERROR", BILLING_STATUS_ERROR);
		}

		try {
			const supabase = getSupabaseClient(c.env);
			const [entitlementResult, creditResult] = await Promise.all([
				supabase
					.from("entitlements")
					.select("is_active, product_id, store, current_period_end")
					.eq("user_id", profileID)
					.maybeSingle(),
				supabase
					.from("consumable_credit_balances")
					.select("balance")
					.eq("user_id", profileID)
					.maybeSingle(),
			]);
			if (entitlementResult.error || creditResult.error) {
				return jsonError(c, "INTERNAL_ERROR", BILLING_STATUS_ERROR);
			}

			const status = readEntitlementStatus(entitlementResult.data, now);
			status.consumable_credits = readCreditBalance(creditResult.data);
			return jsonData(c, status);
		} catch {
			return jsonError(c, "INTERNAL_ERROR", BILLING_STATUS_ERROR);
		}
	});

	return billing;
}

const billing = createBillingRoute();

export { billing };
export default billing;
