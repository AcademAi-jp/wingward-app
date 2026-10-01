import { Hono } from "hono";
import { productionE2EGate } from "../middleware/production-e2e-gate";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
	createRevenueCatWebhookRoute,
	type RevenueCatWebhookRouteOptions,
} from "./revenuecat-webhook";
import type { RevenueCatWebhookDatabase } from "../services/revenuecat-webhook";

const testOwnerLookup = vi.hoisted(() => ({ result: { data: { id: "11111111-1111-4111-8111-111111111111" }, error: null } as { data: { id: string } | null; error: unknown } }));
vi.mock("../db/client", () => ({ getSupabaseClient: () => ({ from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => testOwnerLookup.result }) }) }) }) }));

const NOW_MS = Date.parse("2026-09-04T08:00:00.000Z");
const TIMESTAMP_SECONDS = Math.floor(NOW_MS / 1000);
const SECRET = "webhook-test-secret";
const AUTHORIZATION = "Bearer webhook-test-authorization";

function makePayload(change: Record<string, unknown> = {}) {
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
			...change,
		},
	});
}

async function sign(body: string, timestampSeconds = TIMESTAMP_SECONDS) {
	const raw = new TextEncoder().encode(body);
	const key = await crypto.subtle.importKey(
		"raw",
		new TextEncoder().encode(SECRET),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign"],
	);
	const prefix = new TextEncoder().encode(`${timestampSeconds}.`);
	const input = new Uint8Array(prefix.length + raw.length);
	input.set(prefix);
	input.set(raw, prefix.length);
	const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, input));
	const hex = [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
	return `t=${timestampSeconds},v1=${hex}`;
}

function makeDatabase(result: { data: unknown; error?: unknown | null } = {
	data: [
		{
			result_status: "processed",
			resolved_user_id: "profile-1",
			entitlement_was_applied: true,
			credit_was_granted: false,
		},
	],
	error: null,
}) {
	return {
		rpc: vi.fn<RevenueCatWebhookDatabase["rpc"]>(async () => result),
	};
}

function makeApp(
	database: RevenueCatWebhookDatabase,
	options: Omit<RevenueCatWebhookRouteOptions, "database" | "nowMs"> = {},
	bindings: Record<string, unknown> = {},
) {
	const app = new Hono();
	if (bindings.RECORDING_REHEARSAL_BILLING_ONLY !== undefined) app.use("*", productionE2EGate);
	app.route(
		"/api/webhooks/revenuecat",
		createRevenueCatWebhookRoute({
			...options,
			database,
			nowMs: () => NOW_MS,
		}),
	);
	return { app, bindings: { REVENUECAT_WEBHOOK_SECRET: SECRET, REVENUECAT_WEBHOOK_AUTHORIZATION: AUTHORIZATION, ...bindings } };
}

async function post(
	app: Hono,
	bindings: Record<string, unknown>,
	body = makePayload(),
	headerOverrides: Record<string, string> = {},
) {
	const signature = await sign(body);
	return app.request(
		"/api/webhooks/revenuecat",
		{
			method: "POST",
			headers: {
				Authorization: AUTHORIZATION,
				"X-RevenueCat-Webhook-Signature": signature,
				...headerOverrides,
			},
			body,
		},
		bindings,
	);
}

beforeEach(() => {
	vi.restoreAllMocks();
});

describe("POST /api/webhooks/revenuecat configuration and authentication", () => {
	it("returns 503 when either server-only webhook setting is missing", async () => {
		const database = makeDatabase();
		const { app } = makeApp(database, {}, { REVENUECAT_WEBHOOK_SECRET: undefined });
		const response = await post(app, { REVENUECAT_WEBHOOK_AUTHORIZATION: AUTHORIZATION });
		expect(response.status).toBe(503);
		expect(database.rpc).not.toHaveBeenCalled();
	});

	it("uses one uniform 401 response for missing, wrong, and invalid signatures", async () => {
		const responseBodies: string[] = [];
		for (const headerOverrides of [
			{ Authorization: "" },
			{ Authorization: "Bearer wrong" },
			{ "X-RevenueCat-Webhook-Signature": "t=1,v1=bad" },
		] as Array<Record<string, string>>) {
			const database = makeDatabase();
			const { app, bindings } = makeApp(database);
			const response = await post(app, bindings, makePayload(), headerOverrides);
			responseBodies.push(await response.text());
			expect(response.status).toBe(401);
			expect(database.rpc).not.toHaveBeenCalled();
		}

		expect(responseBodies[0]).toBe(responseBodies[1]);
		expect(responseBodies[1]).toBe(responseBodies[2]);
	});

	it("does not allow a configured Authorization value to be trimmed or normalised", async () => {
		const database = makeDatabase();
		const { app, bindings } = makeApp(database, {}, {
			REVENUECAT_WEBHOOK_AUTHORIZATION: "Bearer  webhook-test-authorization",
		});
		const response = await post(app, bindings, makePayload());
		expect(response.status).toBe(401);
		expect(database.rpc).not.toHaveBeenCalled();
	});
});

describe("POST /api/webhooks/revenuecat payload and persistence", () => {
	it("returns the minimal successful acknowledgement after one atomic RPC", async () => {
		const database = makeDatabase();
		const { app, bindings } = makeApp(database);
		const body = '{"event":{"id":"event-1","type":"INITIAL_PURCHASE","app_user_id":"00000000-0000-0000-0000-000000000001","product_id":"wingward_premium_monthly","entitlement_ids":["premium"],"event_timestamp_ms":1725436800000,"expiration_at_ms":1728028800000,"store":"APP_STORE"}}';
		const response = await post(app, bindings, body);
		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ data: { received: true } });
		expect(database.rpc).toHaveBeenCalledTimes(1);
		expect(database.rpc.mock.calls[0]?.[0]).toBe("apply_revenuecat_webhook_event");
	});

	it("acknowledges a signed ignored event with null identity through the RPC", async () => {
		const database = makeDatabase({
			data: [
				{
					result_status: "ignored",
					resolved_user_id: null,
					entitlement_was_applied: false,
					credit_was_granted: false,
				},
			],
			error: null,
		});
		const { app, bindings } = makeApp(database);
		const response = await post(
			app,
			bindings,
			makePayload({ id: "transfer-1", type: "TRANSFER", app_user_id: null }),
		);
		expect(response.status).toBe(200);
		expect(database.rpc).toHaveBeenCalledTimes(1);
		expect(database.rpc.mock.calls[0]?.[1]).toMatchObject({
			p_action: "ignored",
			p_rc_app_user_id: null,
			p_credit_amount: 0,
		});
	});

	it.each([
		"not-json",
		JSON.stringify({ event: { id: "event-1", type: "INITIAL_PURCHASE" } }),
	])("returns 400 for a signed but invalid payload without a DB call", async (body) => {
		const database = makeDatabase();
		const { app, bindings } = makeApp(database);
		const response = await post(app, bindings, body);
		expect(response.status).toBe(400);
		expect(database.rpc).not.toHaveBeenCalled();
	});

	it("returns one fixed 500 message for RPC errors and invalid result cardinality", async () => {
		const bodies: string[] = [];
		for (const result of [
			{ data: null, error: { message: "canary" } },
			{ data: [], error: null },
		]) {
			const database = makeDatabase(result);
			const { app, bindings } = makeApp(database);
			const response = await post(app, bindings);
			expect(response.status).toBe(500);
			bodies.push(await response.text());
			expect(bodies.at(-1)).not.toContain("canary");
		}
		expect(bodies[0]).toBe(bodies[1]);
	});
});


describe("bounded Test Store webhook scope", () => {
  const scope = { PRODUCTION_E2E_PROFILE_IDS: "11111111-1111-4111-8111-111111111111", PRODUCTION_E2E_EXPIRES_AT: "2099-01-01T00:00:00Z" };
  it.each([
    { environment: "PRODUCTION", store: "TEST_STORE" },
    { environment: "SANDBOX", store: "APP_STORE" },
    { store: "TEST_STORE" },
  ])("rejects out-of-scope event %j without database mutation", async fields => {
    const database = makeDatabase();
    const { app, bindings } = makeApp(database, {}, scope);
    expect((await post(app, bindings, makePayload(fields))).status).toBe(403);
    expect(database.rpc).not.toHaveBeenCalled();
  });
  it("accepts a signed sandbox diagnostic without writing billing data", async () => {
    const database = makeDatabase();
    const { app, bindings } = makeApp(database, {}, scope);
    expect((await post(app, bindings, makePayload({ type: "TEST", environment: "SANDBOX" }))).status).toBe(200);
    expect(database.rpc).not.toHaveBeenCalled();
  });
  it("accepts only the owner in the profile allowlist", async () => {
    testOwnerLookup.result = { data: { id: scope.PRODUCTION_E2E_PROFILE_IDS }, error: null };
    const database = makeDatabase();
    const { app, bindings } = makeApp(database, {}, scope);
    expect((await post(app, bindings, makePayload({ environment: "SANDBOX", store: "TEST_STORE" }))).status).toBe(200);
    expect(database.rpc).toHaveBeenCalledTimes(1);
    testOwnerLookup.result = { data: { id: "22222222-2222-4222-8222-222222222222" }, error: null };
    expect((await post(app, bindings, makePayload({ environment: "SANDBOX", store: "TEST_STORE" }))).status).toBe(403);
    expect(database.rpc).toHaveBeenCalledTimes(1);
  });
  it.each([{ PRODUCTION_E2E_READ_ONLY: "true" }, { PRODUCTION_E2E_EXPIRES_AT: "2020-01-01T00:00:00Z" }])("closes disabled test scope %j", async change => {
    const database = makeDatabase();
    const { app, bindings } = makeApp(database, {}, { ...scope, ...change });
    expect((await post(app, bindings, makePayload({ environment: "SANDBOX", store: "TEST_STORE" }))).status).toBe(403);
    expect(database.rpc).not.toHaveBeenCalled();
  });
});


describe("billing-only signed vendor webhook through global gate", () => {
 const ren="9d836fee-7b93-41ce-b577-34a63006aaea";
 const scope={RECORDING_REHEARSAL_ENABLED:"enabled",RECORDING_REHEARSAL_PAIR:"demo-maya-ren",RECORDING_REHEARSAL_ISSUED_AT:"2026-09-04T07:00:00Z",RECORDING_REHEARSAL_EXPIRES_AT:"2026-09-04T09:00:00Z",RECORDING_REHEARSAL_BILLING_ONLY:"enabled"};
 it("requires existing HMAC and Authorization and admits only signed same-owner Test Store sandbox",async()=>{
  vi.spyOn(Date,"now").mockReturnValue(NOW_MS);testOwnerLookup.result={data:{id:ren},error:null};const database=makeDatabase();const {app,bindings}=makeApp(database,{},scope);const body=makePayload({environment:"SANDBOX",store:"TEST_STORE"});
  expect((await post(app,bindings,body,{Authorization:"Bearer wrong"})).status).toBe(401);
  expect((await post(app,bindings,body,{"X-RevenueCat-Webhook-Signature":"invalid"})).status).toBe(401);expect(database.rpc).not.toHaveBeenCalled();
  expect((await post(app,bindings,body)).status).toBe(200);expect(database.rpc).toHaveBeenCalledTimes(1);
  testOwnerLookup.result={data:{id:"11111111-1111-4111-8111-111111111111"},error:null};expect((await post(app,bindings,body)).status).toBe(403);expect(database.rpc).toHaveBeenCalledTimes(1);
 });
 it.each([{environment:"PRODUCTION",store:"TEST_STORE"},{environment:"SANDBOX",store:"APP_STORE"},{store:"TEST_STORE"}])("closes non sandbox Test Store events %j",async fields=>{vi.spyOn(Date,"now").mockReturnValue(NOW_MS);testOwnerLookup.result={data:{id:ren},error:null};const database=makeDatabase();const {app,bindings}=makeApp(database,{},scope);expect((await post(app,bindings,makePayload(fields))).status).toBe(403);expect(database.rpc).not.toHaveBeenCalled();});
 it("diagnostic event remains nonwriting and expiry closes vendor callback",async()=>{vi.spyOn(Date,"now").mockReturnValue(NOW_MS);const database=makeDatabase();const {app,bindings}=makeApp(database,{},scope);expect((await post(app,bindings,makePayload({type:"TEST",environment:"SANDBOX"}))).status).toBe(200);expect(database.rpc).not.toHaveBeenCalled();vi.spyOn(Date,"now").mockReturnValue(Date.parse(scope.RECORDING_REHEARSAL_EXPIRES_AT));expect((await post(app,bindings)).status).toBe(503);expect(database.rpc).not.toHaveBeenCalled();});
});
