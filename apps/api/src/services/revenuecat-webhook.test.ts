import { describe, expect, it } from "vitest";
import {
	applyRevenueCatWebhookEvent,
	normalizeRevenueCatWebhookEvent,
	parseRevenueCatSignatureHeader,
	parseRevenueCatWebhookBody,
	REVENUECAT_WEBHOOK_RPC,
	verifyRevenueCatWebhookSignature,
	type RevenueCatWebhookDatabase,
} from "./revenuecat-webhook";

const NOW_MS = Date.parse("2026-09-04T08:00:00.000Z");
const SECRET = "webhook-test-secret";

function payload(event: Record<string, unknown>) {
	return JSON.stringify({
		event: {
			id: "event-1",
			type: "INITIAL_PURCHASE",
			app_user_id: "00000000-0000-0000-0000-000000000001",
			product_id: "wingward_premium_monthly",
			entitlement_ids: ["premium"],
			event_timestamp_ms: NOW_MS,
			purchased_at_ms: NOW_MS,
			expiration_at_ms: NOW_MS + 30 * 24 * 60 * 60 * 1000,
			store: "APP_STORE",
			...event,
		},
	});
}

async function signatureFor(body: Uint8Array, timestampSeconds: number, secret = SECRET) {
	const key = await crypto.subtle.importKey(
		"raw",
		new TextEncoder().encode(secret),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign"],
	);
	const timestamp = String(timestampSeconds);
	const prefix = new TextEncoder().encode(`${timestamp}.`);
	const input = new Uint8Array(prefix.length + body.length);
	input.set(prefix);
	input.set(body, prefix.length);
	const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, input));
	const hex = [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
	return `t=${timestamp},v1=${hex}`;
}

describe("RevenueCat webhook signature verification", () => {
	it("accepts the exact RevenueCat header grammar and raw-byte HMAC", async () => {
		const body = new TextEncoder().encode('{ "event": { "id": "raw" } }');
		const timestampSeconds = Math.floor(NOW_MS / 1000);
		const header = await signatureFor(body, timestampSeconds);

		expect(parseRevenueCatSignatureHeader(header)).not.toBeNull();
		expect(await verifyRevenueCatWebhookSignature(body, header, SECRET, NOW_MS)).toBe(true);

		const changedWhitespace = new TextEncoder().encode('{"event":{"id":"raw"}}');
		expect(await verifyRevenueCatWebhookSignature(changedWhitespace, header, SECRET, NOW_MS)).toBe(false);
	});

	it.each([
		"t=1,v1=ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789",
		"t=1,v1=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde",
		"t=1.0,v1=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"t=1,v1=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef,extra=x",
		" t=1,v1=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	])("rejects non-strict signature header %s", (header) => {
		expect(parseRevenueCatSignatureHeader(header)).toBeNull();
	});

	it("rejects timestamps outside the injected five-minute window", async () => {
		const body = new TextEncoder().encode("{}");
		const staleHeader = await signatureFor(body, Math.floor((NOW_MS - 300_001) / 1000));
		const edgeHeader = await signatureFor(body, Math.floor((NOW_MS - 300_000) / 1000));
		expect(await verifyRevenueCatWebhookSignature(body, staleHeader, SECRET, NOW_MS)).toBe(false);
		expect(await verifyRevenueCatWebhookSignature(body, edgeHeader, SECRET, NOW_MS)).toBe(true);
	});
});

describe("RevenueCat webhook payload normalization", () => {
	it("maps the fixed premium subscription and period", () => {
		const event = parseRevenueCatWebhookBody(payload({}));
		const normalized = normalizeRevenueCatWebhookEvent(event, NOW_MS);
		expect(normalized.args).toMatchObject({
			p_event_id: "event-1",
			p_event_type: "INITIAL_PURCHASE",
			p_rc_app_user_id: "00000000-0000-0000-0000-000000000001",
			p_action: "subscription",
			p_entitlement_is_active: true,
			p_product_id: "wingward_premium_monthly",
			p_current_period_end: "2026-10-04T08:00:00.000Z",
			p_credit_amount: 0,
		});
	});

	it("uses expiration to decide cancellation activity", () => {
		const future = parseRevenueCatWebhookBody(payload({ type: "CANCELLATION" }));
		const past = parseRevenueCatWebhookBody(payload({ type: "CANCELLATION", expiration_at_ms: NOW_MS - 1 }));
		expect(normalizeRevenueCatWebhookEvent(future, NOW_MS).args.p_entitlement_is_active).toBe(true);
		expect(normalizeRevenueCatWebhookEvent(past, NOW_MS).args.p_entitlement_is_active).toBe(false);
	});

	it("maps exactly one fixed consumable credit", () => {
		const event = parseRevenueCatWebhookBody(
			payload({
				id: "credit-1",
				type: "NON_RENEWING_PURCHASE",
				product_id: "wingward_meetup_credit",
				entitlement_ids: [],
			}),
		);
		const normalized = normalizeRevenueCatWebhookEvent(event, NOW_MS);
		expect(normalized.args).toMatchObject({
			p_action: "consumable",
			p_product_id: "wingward_meetup_credit",
			p_credit_amount: 1,
			p_entitlement_is_active: null,
		});
	});

	it.each([
		{ type: "TRANSFER", app_user_id: "user-1" },
		{ type: "BILLING_ISSUE", app_user_id: "user-1" },
		{ type: "FUTURE_EVENT", app_user_id: "user-1" },
		{ type: "INITIAL_PURCHASE", app_user_id: null },
		{ type: "INITIAL_PURCHASE", app_user_id: "   " },
		{ type: "INITIAL_PURCHASE", product_id: "other-product" },
		{ type: "INITIAL_PURCHASE", expiration_at_ms: null },
	])("safely normalizes unsupported or incomplete events to ignored", (change) => {
		const event = parseRevenueCatWebhookBody(payload(change));
		expect(normalizeRevenueCatWebhookEvent(event, NOW_MS).args).toMatchObject({
			p_action: "ignored",
			p_entitlement_is_active: null,
			p_current_period_end: null,
			p_credit_amount: 0,
		});
	});

	it("rejects malformed JSON or missing required event timestamps before the RPC", () => {
		expect(() => parseRevenueCatWebhookBody("not-json")).toThrow();
		expect(() => parseRevenueCatWebhookBody(JSON.stringify({ event: { id: "x", type: "TRANSFER" } }))).toThrow();
	});
});

describe("RevenueCat webhook RPC boundary", () => {
	it("calls only the atomic RPC and validates exactly one result row", async () => {
		const rpc = async (...args: Parameters<RevenueCatWebhookDatabase["rpc"]>) => {
			expect(args[0]).toBe(REVENUECAT_WEBHOOK_RPC);
			return {
				data: [
					{
						result_status: "processed",
						resolved_user_id: "profile-1",
						entitlement_was_applied: true,
						credit_was_granted: false,
					},
				],
				error: null,
			};
		};
		const database = { rpc };
		const normalized = normalizeRevenueCatWebhookEvent(
			parseRevenueCatWebhookBody(payload({})),
			NOW_MS,
		);

		await expect(applyRevenueCatWebhookEvent(database, normalized)).resolves.toMatchObject({
			result_status: "processed",
		});
	});

	it.each([
		{ data: [], error: null },
		{ data: [{ result_status: "processed" }], error: null },
		{ data: [{ result_status: "processed", resolved_user_id: null, entitlement_was_applied: true, credit_was_granted: false }, {}], error: null },
		{ data: null, error: { message: "canary" } },
	])("fails closed for an invalid or failed RPC response", async (response) => {
		const database: RevenueCatWebhookDatabase = { rpc: async () => response };
		const normalized = normalizeRevenueCatWebhookEvent(
			parseRevenueCatWebhookBody(payload({})),
			NOW_MS,
		);
		await expect(applyRevenueCatWebhookEvent(database, normalized)).rejects.toThrow();
	});
});
