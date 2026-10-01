import { z } from "zod";

export const REVENUECAT_ENTITLEMENT_ID = "premium" as const;
export const REVENUECAT_SUBSCRIPTION_PRODUCT_ID = "wingward_premium_monthly" as const;
export const REVENUECAT_CONSUMABLE_PRODUCT_ID = "wingward_meetup_credit" as const;
export const REVENUECAT_WEBHOOK_RPC = "apply_revenuecat_webhook_event" as const;
export const REVENUECAT_WEBHOOK_TOLERANCE_MS = 300_000;

const HMAC_SHA256_HEX_LENGTH = 64;
const MAX_DATE_MILLISECONDS = 8_640_000_000_000_000;

/** The only action values accepted by the atomic database function. */
export type RevenueCatWebhookAction = "subscription" | "consumable" | "ignored";

export type RevenueCatWebhookRpcArgs = {
	p_event_id: string;
	p_event_type: string;
	p_rc_app_user_id: string | null;
	p_effective_at: string;
	p_action: RevenueCatWebhookAction;
	p_entitlement_is_active: boolean | null;
	p_product_id: string | null;
	p_store: string | null;
	p_current_period_end: string | null;
	p_credit_amount: number;
};

export type RevenueCatWebhookRpcRow = {
	result_status: "processed" | "duplicate" | "ignored";
	resolved_user_id: string | null;
	entitlement_was_applied: boolean;
	credit_was_granted: boolean;
};

/**
 * Deliberately narrow adapter for the one RPC this webhook may call. Keeping
 * this boundary structural avoids making the shared generated database types
 * a prerequisite for the feature worktree.
 */
export interface RevenueCatWebhookDatabase {
	rpc(
		functionName: typeof REVENUECAT_WEBHOOK_RPC,
		args: RevenueCatWebhookRpcArgs,
	): PromiseLike<{ data: unknown; error?: unknown | null }>;
}

export interface RevenueCatWebhookRpcClient {
	rpc(
		functionName: typeof REVENUECAT_WEBHOOK_RPC,
		args: RevenueCatWebhookRpcArgs,
	): PromiseLike<{ data: unknown; error?: unknown | null }>;
}

/** Expose only the fixed RPC operation to webhook processing. */
export function createRevenueCatWebhookDatabase(client: RevenueCatWebhookRpcClient): RevenueCatWebhookDatabase {
	return {
		rpc: (functionName, args) => client.rpc(functionName, args),
	};
}

export class InvalidRevenueCatWebhookPayloadError extends Error {
	constructor() {
		super("invalid RevenueCat webhook payload");
		this.name = "InvalidRevenueCatWebhookPayloadError";
	}
}

export class RevenueCatWebhookPersistenceError extends Error {
	constructor() {
		super("RevenueCat webhook persistence failed");
		this.name = "RevenueCatWebhookPersistenceError";
	}
}

function timingSafeEqual(left: Uint8Array, right: Uint8Array): boolean {
	let difference = left.length ^ right.length;
	const length = Math.max(left.length, right.length);
	for (let index = 0; index < length; index += 1) {
		const leftByte = index < left.length ? left[index] : 0;
		const rightByte = index < right.length ? right[index] : 0;
		difference |= leftByte ^ rightByte;
	}
	return difference === 0;
}

/**
 * Compare an exact configured Authorization value without early-exit string
 * comparison. The value is not trimmed: the configured header is a protocol
 * value, not a human-entered token to normalise.
 */
export function timingSafeEqualText(left: string, right: string): boolean {
	return timingSafeEqual(new TextEncoder().encode(left), new TextEncoder().encode(right));
}

type ParsedSignature = {
	timestampToken: string;
	timestampSeconds: number;
	signature: Uint8Array;
};

function decodeHex(hex: string): Uint8Array | null {
	if (hex.length !== HMAC_SHA256_HEX_LENGTH || !/^[0-9a-f]+$/.test(hex)) return null;

	const bytes = new Uint8Array(hex.length / 2);
	for (let index = 0; index < bytes.length; index += 1) {
		bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
	}
	return bytes;
}

/** RevenueCat's signature grammar is intentionally strict and non-extensible. */
export function parseRevenueCatSignatureHeader(value: string | undefined): ParsedSignature | null {
	const match = /^t=([0-9]+),v1=([0-9a-f]{64})$/.exec(value ?? "");
	if (!match) return null;

	const timestampSeconds = Number(match[1]);
	if (!Number.isSafeInteger(timestampSeconds) || timestampSeconds < 0) return null;
	if (timestampSeconds > Math.floor(MAX_DATE_MILLISECONDS / 1000)) return null;

	const signature = decodeHex(match[2]);
	if (!signature) return null;

	return {
		timestampToken: match[1],
		timestampSeconds,
		signature,
	};
}

/**
 * Verify the RevenueCat HMAC against the untouched request bytes. Parsing the
 * signature and checking freshness happen before any JSON decoding, and the
 * comparison is byte-wise with no early exit.
 */
export async function verifyRevenueCatWebhookSignature(
	rawBody: Uint8Array,
	signatureHeader: string | undefined,
	secret: string,
	nowMs: number,
	cryptoApi: Pick<Crypto, "subtle"> = globalThis.crypto,
): Promise<boolean> {
	const parsed = parseRevenueCatSignatureHeader(signatureHeader);
	if (!parsed || !Number.isFinite(nowMs)) return false;

	const timestampMs = parsed.timestampSeconds * 1000;
	if (Math.abs(nowMs - timestampMs) > REVENUECAT_WEBHOOK_TOLERANCE_MS) return false;

	try {
		const key = await cryptoApi.subtle.importKey(
			"raw",
			new TextEncoder().encode(secret),
			{ name: "HMAC", hash: "SHA-256" },
			false,
			["sign"],
		);
		const timestampBytes = new TextEncoder().encode(`${parsed.timestampToken}.`);
		const signingBytes = new Uint8Array(timestampBytes.length + rawBody.length);
		signingBytes.set(timestampBytes);
		signingBytes.set(rawBody, timestampBytes.length);
		const expected = new Uint8Array(await cryptoApi.subtle.sign("HMAC", key, signingBytes));
		return timingSafeEqual(expected, parsed.signature);
	} catch {
		// A crypto/runtime failure is indistinguishable from an invalid signature
		// to the caller. Never continue to payload parsing or database work.
		return false;
	}
}

const timestampMillisecondsSchema = z
	.number()
	.refine((value) => Number.isSafeInteger(value), "must be a safe integer")
	.refine((value) => value >= 0 && value <= MAX_DATE_MILLISECONDS, "must be a valid Unix timestamp");

const revenueCatEventSchema = z
	.object({
		id: z.string().min(1).max(128),
		type: z.string().min(1).max(100),
		app_user_id: z.string().max(255).nullable().optional(),
		product_id: z.string().max(255).nullable().optional(),
		entitlement_ids: z.array(z.string().min(1).max(255)).nullable().optional(),
		event_timestamp_ms: timestampMillisecondsSchema,
		purchased_at_ms: timestampMillisecondsSchema.nullable().optional(),
		expiration_at_ms: timestampMillisecondsSchema.nullable().optional(),
		store: z.string().max(64).nullable().optional(),
	})
	.passthrough();

const revenueCatPayloadSchema = z
	.object({
		event: revenueCatEventSchema,
	})
	.passthrough();

export type RevenueCatWebhookEvent = z.infer<typeof revenueCatEventSchema>;

/** Decode and validate only after HMAC verification has succeeded. */
export function parseRevenueCatWebhookBody(bodyText: string): RevenueCatWebhookEvent {
	let json: unknown;
	try {
		json = JSON.parse(bodyText);
	} catch {
		throw new InvalidRevenueCatWebhookPayloadError();
	}

	const parsed = revenueCatPayloadSchema.safeParse(json);
	if (!parsed.success) throw new InvalidRevenueCatWebhookPayloadError();
	return parsed.data.event;
}

function toIsoTimestamp(milliseconds: number): string {
	const date = new Date(milliseconds);
	if (!Number.isFinite(date.getTime())) throw new InvalidRevenueCatWebhookPayloadError();
	return date.toISOString();
}

function nonBlankIdentity(value: string | null | undefined): string | null {
	return value && value.trim() !== "" ? value : null;
}

const subscriptionEventTypes = new Set([
	"INITIAL_PURCHASE",
	"RENEWAL",
	"PRODUCT_CHANGE",
	"UNCANCELLATION",
	"CANCELLATION",
	"EXPIRATION",
]);

const consumableEventTypes = new Set(["NON_RENEWING_PURCHASE"]);

export type NormalizedRevenueCatWebhookEvent = {
	args: RevenueCatWebhookRpcArgs;
};

function ignoredEventArgs(event: RevenueCatWebhookEvent, effectiveAt: string): RevenueCatWebhookRpcArgs {
	return {
		p_event_id: event.id,
		p_event_type: event.type,
		p_rc_app_user_id: nonBlankIdentity(event.app_user_id),
		p_effective_at: effectiveAt,
		p_action: "ignored",
		p_entitlement_is_active: null,
		p_product_id: null,
		p_store: null,
		p_current_period_end: null,
		p_credit_amount: 0,
	};
}

/**
 * Convert the closed RevenueCat event/product mapping into RPC arguments.
 * Unsupported events deliberately remain auditable as ignored events.
 */
export function normalizeRevenueCatWebhookEvent(
	event: RevenueCatWebhookEvent,
	nowMs: number,
): NormalizedRevenueCatWebhookEvent {
	const effectiveAt = toIsoTimestamp(event.event_timestamp_ms);
	const identity = nonBlankIdentity(event.app_user_id);

	if (!Number.isFinite(nowMs)) throw new InvalidRevenueCatWebhookPayloadError();

	if (
		!identity ||
		event.type === "TRANSFER" ||
		(!subscriptionEventTypes.has(event.type) && !consumableEventTypes.has(event.type))
	) {
		return { args: ignoredEventArgs(event, effectiveAt) };
	}

	if (
		subscriptionEventTypes.has(event.type) &&
		event.product_id === REVENUECAT_SUBSCRIPTION_PRODUCT_ID &&
		event.entitlement_ids?.includes(REVENUECAT_ENTITLEMENT_ID) &&
		event.expiration_at_ms != null
	) {
		const currentPeriodEnd = toIsoTimestamp(event.expiration_at_ms);
		const active =
			event.type === "EXPIRATION"
				? false
				: event.type === "CANCELLATION"
					? event.expiration_at_ms > nowMs
					: true;

		return {
			args: {
				p_event_id: event.id,
				p_event_type: event.type,
				p_rc_app_user_id: identity,
				p_effective_at: effectiveAt,
				p_action: "subscription",
				p_entitlement_is_active: active,
				p_product_id: REVENUECAT_SUBSCRIPTION_PRODUCT_ID,
				p_store: event.store ?? null,
				p_current_period_end: currentPeriodEnd,
				p_credit_amount: 0,
			},
		};
	}

	if (
		consumableEventTypes.has(event.type) &&
		event.product_id === REVENUECAT_CONSUMABLE_PRODUCT_ID &&
		event.purchased_at_ms != null
	) {
		// A consumable has no entitlement period. purchased_at_ms is required
		// for a valid purchase event, while event_timestamp_ms remains the
		// ordering timestamp recorded by the database.
		toIsoTimestamp(event.purchased_at_ms);
		return {
			args: {
				p_event_id: event.id,
				p_event_type: event.type,
				p_rc_app_user_id: identity,
				p_effective_at: effectiveAt,
				p_action: "consumable",
				p_entitlement_is_active: null,
				p_product_id: REVENUECAT_CONSUMABLE_PRODUCT_ID,
				p_store: event.store ?? null,
				p_current_period_end: null,
				p_credit_amount: 1,
			},
		};
	}

	// A recognised event with the wrong product or missing required period is
	// safely ignored. It must not be coerced into a grant or entitlement write.
	return { args: ignoredEventArgs(event, effectiveAt) };
}

const rpcRowSchema = z.object({
	result_status: z.enum(["processed", "duplicate", "ignored"]),
	resolved_user_id: z.string().min(1).nullable(),
	entitlement_was_applied: z.boolean(),
	credit_was_granted: z.boolean(),
});

function validateRpcResult(data: unknown): RevenueCatWebhookRpcRow {
	if (!Array.isArray(data) || data.length !== 1) {
		throw new RevenueCatWebhookPersistenceError();
	}
	const parsed = rpcRowSchema.safeParse(data[0]);
	if (!parsed.success) throw new RevenueCatWebhookPersistenceError();
	// Copy the validated fields into the public result instead of asserting the
	// untrusted RPC response's shape. The schema above is the runtime boundary.
	return {
		result_status: parsed.data.result_status,
		resolved_user_id: parsed.data.resolved_user_id,
		entitlement_was_applied: parsed.data.entitlement_was_applied,
		credit_was_granted: parsed.data.credit_was_granted,
	};
}

/** Apply exactly one normalized event through the atomic server-side RPC. */
export async function applyRevenueCatWebhookEvent(
	database: RevenueCatWebhookDatabase,
	normalized: NormalizedRevenueCatWebhookEvent,
): Promise<RevenueCatWebhookRpcRow> {
	let response: { data: unknown; error?: unknown | null };
	try {
		response = await database.rpc(REVENUECAT_WEBHOOK_RPC, normalized.args);
	} catch {
		throw new RevenueCatWebhookPersistenceError();
	}

	if (response.error) throw new RevenueCatWebhookPersistenceError();
	return validateRpcResult(response.data);
}
