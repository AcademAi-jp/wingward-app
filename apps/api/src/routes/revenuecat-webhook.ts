import { judgeRpcClient, readJudgeAccessConfig, readJudgeWebhookAccess } from "../services/judge-access";
import { Hono } from "hono";
import { readProductionE2EConfig } from "../middleware/production-e2e-gate";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { jsonData, jsonError } from "../lib/response";
import {
	applyRevenueCatWebhookEvent,
	createRevenueCatWebhookDatabase,
	parseRevenueCatWebhookBody,
	timingSafeEqualText,
	type RevenueCatWebhookDatabase,
	type RevenueCatWebhookRpcClient,
	normalizeRevenueCatWebhookEvent,
	verifyRevenueCatWebhookSignature,
} from "../services/revenuecat-webhook";

export type RevenueCatWebhookRouteOptions = {
	/** Injectable wall clock for replay-window and cancellation tests. */
	nowMs?: () => number;
	/** Injectable WebCrypto surface for deterministic unit tests. */
	cryptoApi?: Pick<Crypto, "subtle">;
	/** Injectable adapter; production uses the service-role Supabase client. */
	database?: RevenueCatWebhookDatabase;
	getDatabase?: (bindings: Env["Bindings"]) => RevenueCatWebhookDatabase;
};

const CONFIG_ERROR_MESSAGE = "RevenueCat webhook is not configured";
const UNAUTHORIZED_MESSAGE = "Invalid RevenueCat webhook authentication";
const INVALID_PAYLOAD_MESSAGE = "Invalid RevenueCat webhook payload";
const PROCESSING_ERROR_MESSAGE = "Failed to process RevenueCat webhook";

function isConfigured(value: string | undefined): value is string {
	return value !== undefined && value.trim() !== "";
}

function defaultDatabase(bindings: Env["Bindings"]): RevenueCatWebhookDatabase {
	const client = getSupabaseClient(bindings);
	// Keep the production client behind the one literal RPC operation that this
	// route is allowed to invoke. The generated Database type supplies the
	// function name and argument shape; no whole-client type assertion is needed.
	const rpcClient: RevenueCatWebhookRpcClient = {
		rpc: async (functionName, args) => {
			const response = await client.rpc(functionName, args);
			return { data: response.data, error: response.error };
		},
	};
	return createRevenueCatWebhookDatabase(rpcClient);
}

function decodeUtf8(rawBody: Uint8Array): string | null {
	try {
		return new TextDecoder("utf-8", { fatal: true }).decode(rawBody);
	} catch {
		return null;
	}
}

/**
 * Create the public webhook route. The app integration owns mounting this
 * router at `/api/webhooks/revenuecat`.
 */
export function createRevenueCatWebhookRoute(options: RevenueCatWebhookRouteOptions = {}) {
	const route = new Hono<Env>();
	const nowMs = options.nowMs ?? (() => Date.now());

	route.post("/", async (c) => {
		let rawBody: Uint8Array;
		try {
			// This is deliberately the only body read. Signature verification must
			// receive the exact bytes RevenueCat sent, including whitespace.
			rawBody = new Uint8Array(await c.req.raw.arrayBuffer());
		} catch {
			return jsonError(c, "BAD_REQUEST", INVALID_PAYLOAD_MESSAGE);
		}

		const bindings = c.env;
		const configuredSecret = bindings.REVENUECAT_WEBHOOK_SECRET;
		const configuredAuthorization = bindings.REVENUECAT_WEBHOOK_AUTHORIZATION;
		if (!isConfigured(configuredSecret) || !isConfigured(configuredAuthorization)) {
			return jsonError(c, "INTERNAL_ERROR", CONFIG_ERROR_MESSAGE, 503);
		}

		const presentedAuthorization = c.req.header("Authorization") ?? "";
		if (!timingSafeEqualText(presentedAuthorization, configuredAuthorization)) {
			return jsonError(c, "UNAUTHORIZED", UNAUTHORIZED_MESSAGE);
		}

		let currentTimeMs: number;
		try {
			currentTimeMs = nowMs();
		} catch {
			return jsonError(c, "UNAUTHORIZED", UNAUTHORIZED_MESSAGE);
		}

		const signatureValid = await verifyRevenueCatWebhookSignature(
			rawBody,
			c.req.header("X-RevenueCat-Webhook-Signature"),
			configuredSecret,
			currentTimeMs,
			options.cryptoApi,
		);
		if (!signatureValid) {
			return jsonError(c, "UNAUTHORIZED", UNAUTHORIZED_MESSAGE);
		}

		const bodyText = decodeUtf8(rawBody);
		if (bodyText === null) {
			return jsonError(c, "BAD_REQUEST", INVALID_PAYLOAD_MESSAGE);
		}

		let event;
		try {
			event = parseRevenueCatWebhookBody(bodyText);
		} catch {
			return jsonError(c, "BAD_REQUEST", INVALID_PAYLOAD_MESSAGE);
		}

    const judgeScope = readJudgeAccessConfig(bindings);
    if (judgeScope.kind !== "absent") {
      if (judgeScope.kind !== "active" || event.environment !== "SANDBOX") {
        return jsonError(c, "FORBIDDEN", "Webhook outside review scope", 403);
      }
      if (event.type === "TEST") return jsonData(c, { received: true });
      if (event.store !== "TEST_STORE" || typeof event.app_user_id !== "string"
        || !await readJudgeWebhookAccess(judgeRpcClient(getSupabaseClient(bindings)), judgeScope.config, event.app_user_id)) {
        return jsonError(c, "FORBIDDEN", "Webhook outside review scope", 403);
      }
    }
    const testScope = judgeScope.kind === "absent" ? readProductionE2EConfig(bindings) : {kind: "absent" as const};
    if (testScope.kind !== "absent") {
      if (testScope.kind !== "active" || testScope.readOnly || Date.now() >= testScope.expiresAtMs) {
        return jsonError(c, "FORBIDDEN", "Webhook test scope unavailable", 403);
      }
      if (event.environment !== "SANDBOX") return jsonError(c, "FORBIDDEN", "Webhook outside test scope", 403);
      // Dashboard connectivity tests never grant an entitlement or write a row.
      if (event.type === "TEST") return jsonData(c, { received: true });
      if (event.store !== "TEST_STORE" || typeof event.app_user_id !== "string") {
        return jsonError(c, "FORBIDDEN", "Webhook outside test scope", 403);
      }
      try {
        const { data, error } = await getSupabaseClient(bindings).from("user_profiles")
          .select("id").eq("auth_user_id", event.app_user_id).maybeSingle();
        if (error || !data || !testScope.profileIds.includes(data.id) || Date.now() >= testScope.expiresAtMs) {
          return jsonError(c, "FORBIDDEN", "Webhook outside test scope", 403);
        }
      } catch { return jsonError(c, "FORBIDDEN", "Webhook outside test scope", 403); }
    }
		let database: RevenueCatWebhookDatabase;
		try {
			database = options.database ?? options.getDatabase?.(bindings) ?? defaultDatabase(bindings);
			const normalized = normalizeRevenueCatWebhookEvent(event, currentTimeMs);
			await applyRevenueCatWebhookEvent(database, normalized);
		} catch {
			return jsonError(c, "INTERNAL_ERROR", PROCESSING_ERROR_MESSAGE);
		}

		return jsonData(c, { received: true });
	});

	return route;
}

const revenuecatWebhook = createRevenueCatWebhookRoute();

export { revenuecatWebhook };
export default revenuecatWebhook;
