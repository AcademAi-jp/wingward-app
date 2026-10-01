import test from "node:test";
import assert from "node:assert/strict";
import {
	createVoiceSmokeHandler,
	healthPayload,
	MAX_PROVIDER_BODY_BYTES,
	MARKER_HEADER,
	PROJECT_ID,
	readVoiceSmokeRuntime,
} from "./voice-smoke-server";

const API_KEY = "synthetic-elevenlabs-api-key";
const JA_AGENT_ID = "agent_9501m0n19gpwewfrb3nqpq4sbna1";
const EN_AGENT_ID = "agent_8701m2278ka1f9hrnp0h5dd51r21";
const TOKEN = "synthetic-conversation-token";

test("Japanese retry mode blocks English and allows only one Japanese issuance", async () => {
	let calls = 0;
	const handler = createVoiceSmokeHandler({ runtime,
		env: { WINGWARD_VOICE_SMOKE_JA_ONLY: "true" },
		fetchImpl: async () => { calls += 1; return tokenResponse(); },
	});
	const context = { remoteAddress: "127.0.0.1" };
	assert.equal((await handler(request("/bootstrap/en"), context)).status, 403);
	assert.equal(calls, 0);
	assert.equal((await handler(request("/bootstrap/ja"), context)).status, 200);
	assert.equal((await handler(request("/bootstrap/ja"), context)).status, 409);
	assert.equal(calls, 1);
});

const runtime = {
	apiKey: API_KEY,
	agentIds: { ja: JA_AGENT_ID, en: EN_AGENT_ID },
} as const;

function request(path: string, init: RequestInit = {}): Request {
	const headers = new Headers(init.headers);
	if (path.startsWith("/bootstrap/")) headers.set(MARKER_HEADER, PROJECT_ID);
	const method = init.method ?? (path.startsWith("/bootstrap/") ? "POST" : "GET");
	return new Request(`https://127.0.0.1:55444${path}`, { ...init, method, headers });
}

function tokenResponse(token = TOKEN, status = 200): Response {
	return new Response(JSON.stringify({ token, conversation_id: "conv_synthetic" }), {
		status,
		headers: { "content-type": "application/json" },
	});
}

async function json(response: Response): Promise<Record<string, any>> {
	return await response.json() as Record<string, any>;
}

test("runtime gate accepts only the fixed marker, key, and finalized Agent IDs", () => {
	assert.deepEqual(readVoiceSmokeRuntime({
		WINGWARD_LIVE_APPROVED_VOICE_SMOKE: PROJECT_ID,
		ELEVENLABS_API_KEY: API_KEY,
		ELEVENLABS_AGENT_ID_JA: JA_AGENT_ID,
		ELEVENLABS_AGENT_ID_EN: EN_AGENT_ID,
		MISTRAL_API_KEY: "must-not-be-selected",
	}), runtime);
	for (const overrides of [
		{ WINGWARD_LIVE_APPROVED_VOICE_SMOKE: undefined },
		{ ELEVENLABS_API_KEY: undefined },
		{ ELEVENLABS_AGENT_ID_JA: "agent_legacy" },
		{ ELEVENLABS_AGENT_ID_EN: "agent_legacy" },
	]) {
		assert.equal(readVoiceSmokeRuntime({
			WINGWARD_LIVE_APPROVED_VOICE_SMOKE: PROJECT_ID,
			ELEVENLABS_API_KEY: API_KEY,
			ELEVENLABS_AGENT_ID_JA: JA_AGENT_ID,
			ELEVENLABS_AGENT_ID_EN: EN_AGENT_ID,
			...overrides,
		}), null);
	}
});

test("health is fixed and a successful bootstrap returns the exact native DTO", async () => {
	const calls: Array<{ url: string; options: RequestInit }> = [];
	const handler = createVoiceSmokeHandler({
		runtime,
		fetchImpl: async (url, options) => {
			calls.push({ url: String(url), options });
			return tokenResponse();
		},
	});

	const initialHealth = await handler(request("/health"), { remoteAddress: "127.0.0.1" });
	assert.equal(initialHealth.status, 200);
	assert.deepEqual(await json(initialHealth), healthPayload({ ja: false, en: false }));

	const bootstrapResponse = await handler(request("/bootstrap/ja"), { remoteAddress: "127.0.0.1" });
	assert.equal(bootstrapResponse.status, 200);
	const bootstrap = await json(bootstrapResponse);
	assert.deepEqual(Object.keys(bootstrap).sort(), ["conversation_token", "overrides", "session_id"]);
	assert.equal(bootstrap.session_id, "44444444-4444-4444-8444-444444444444");
	assert.equal(bootstrap.conversation_token, TOKEN);
	assert.deepEqual(Object.keys(bootstrap.overrides).sort(), ["agent", "tts"]);
	assert.equal(bootstrap.overrides.agent.language, "ja");
	assert.equal(bootstrap.overrides.tts.voiceId, "dhGvgIx0X6G3xzSWqOye");
	assert.match(bootstrap.overrides.agent.firstMessage, /スモークさん/);
	assert.equal(typeof bootstrap.overrides.agent.prompt.prompt, "string");

	assert.equal(calls.length, 1);
	assert.equal(calls[0].url, "https://api.elevenlabs.io/v1/convai/conversation/token?agent_id=" + JA_AGENT_ID);
	assert.equal(calls[0].options.method, "GET");
	assert.equal(calls[0].options.redirect, "error");
	assert.deepEqual(calls[0].options.headers, {
		Accept: "application/json",
		"xi-api-key": API_KEY,
	});

	const afterHealth = await handler(request("/health"), { remoteAddress: "127.0.0.1" });
	assert.deepEqual(await json(afterHealth), healthPayload({ ja: true, en: false }));
});

test("a locale is reserved before await and cannot be retried concurrently", async () => {
	let calls = 0;
	let release: (() => void) | undefined;
	const blocked = new Promise<void>((resolve) => { release = resolve; });
	const handler = createVoiceSmokeHandler({
		runtime,
		fetchImpl: async () => {
			calls += 1;
			await blocked;
			return tokenResponse();
		},
	});

	const first = handler(request("/bootstrap/en"), { remoteAddress: "127.0.0.1" });
	await new Promise<void>((resolve) => setImmediate(resolve));
	const healthWhilePending = await handler(request("/health"), { remoteAddress: "127.0.0.1" });
	assert.deepEqual(await json(healthWhilePending), healthPayload({ ja: false, en: true }));

	const second = await handler(request("/bootstrap/en"), { remoteAddress: "127.0.0.1" });
	assert.equal(second.status, 409);
	assert.equal(calls, 1);
	release?.();
	assert.equal((await first).status, 200);
});

test("loopback, origin, marker, body, path, and method boundaries fail before provider access", async () => {
	let calls = 0;
	const handler = createVoiceSmokeHandler({
		runtime,
		fetchImpl: async () => {
			calls += 1;
			return tokenResponse();
		},
	});

	const denied = [
		[request("/bootstrap/ja"), { remoteAddress: "192.0.2.20" }, 403],
		[request("/bootstrap/ja", { headers: { Origin: "https://example.test" } }), { remoteAddress: "127.0.0.1" }, 403],
		[new Request("https://127.0.0.1:55444/bootstrap/ja", { method: "POST" }), { remoteAddress: "127.0.0.1" }, 403],
		[request("/bootstrap/ja", { method: "POST", body: "unexpected" }), { remoteAddress: "127.0.0.1" }, 400],
		[request("/bootstrap/ja?extra=1"), { remoteAddress: "127.0.0.1" }, 404],
		[request("/bootstrap/ja", { method: "GET" }), { remoteAddress: "127.0.0.1" }, 405],
		[request("/other"), { remoteAddress: "127.0.0.1" }, 404],
	] as const;
	for (const [input, context, status] of denied) assert.equal((await handler(input, context)).status, status);
	assert.equal(calls, 0);
});

test("oversized or malformed provider responses fail once and remain reserved", async () => {
	let calls = 0;
	const oversized = new Uint8Array(MAX_PROVIDER_BODY_BYTES + 1);
	oversized.fill(120);
	const handler = createVoiceSmokeHandler({
		runtime,
		fetchImpl: async () => {
			calls += 1;
			return new Response(oversized, { status: 200 });
		},
	});
	const first = await handler(request("/bootstrap/ja"), { remoteAddress: "127.0.0.1" });
	assert.equal(first.status, 502);
	const second = await handler(request("/bootstrap/ja"), { remoteAddress: "127.0.0.1" });
	assert.equal(second.status, 409);
	assert.equal(calls, 1);
});
