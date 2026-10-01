#!/usr/bin/env tsx

/**
 * Disposable, operator-run HTTPS token smoke server.
 *
 * This process is deliberately separate from the API and never loads dotenv,
 * Supabase, Mistral, or any other provider. It accepts one empty POST per
 * locale, obtains one short-lived ElevenLabs WebRTC token, and returns only
 * the native bootstrap DTO required by the iOS smoke screen. It never starts
 * a conversation itself.
 */

import { readFileSync } from "node:fs";
import * as https from "node:https";
import type { IncomingMessage, ServerResponse } from "node:http";
import * as path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
	buildSpeedDatingConversationBootstrap,
	ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT,
	parseSafeElevenLabsConversationTokenResponse,
	readBoundedResponseTextWithSignal,
} from "../src/lib/speed-dating-ai";

export const PROJECT_ID = "wingward-live-dev-20260909";
export const APPROVAL_ENV = "WINGWARD_LIVE_APPROVED_VOICE_SMOKE";
export const ELEVENLABS_API_KEY_ENV = "ELEVENLABS_API_KEY";
export const HOST = "127.0.0.1";
export const PORT = 55444;
export const MAX_PROVIDER_BODY_BYTES = 8_192;
export const MAX_REQUEST_BODY_BYTES = 8_192;
export const PROVIDER_TIMEOUT_MS = 8_000;
export const SERVER_TTL_MS = 15 * 60 * 1_000;
export const MARKER_HEADER = "x-wingward-voice-smoke";

export const DEFAULT_TLS_CERT_PATH = "/private/tmp/wingward-live-dev-20260909/tls/localhost.crt";
export const DEFAULT_TLS_KEY_PATH = "/private/tmp/wingward-live-dev-20260909/tls/localhost.key";

const FINAL_AGENT_IDS = Object.freeze({
	ja: "agent_9501m0n19gpwewfrb3nqpq4sbna1",
	en: "agent_8701m2278ka1f9hrnp0h5dd51r21",
});

let activeServer: https.Server | undefined;

type VoiceSmokeLocale = "ja" | "en";

type VoiceSmokeFixture = {
	path: `/bootstrap/${VoiceSmokeLocale}`;
	sessionId: string;
	voiceId: string;
	personaName: string;
	personaDocument: string;
};

const FIXTURES: Record<VoiceSmokeLocale, VoiceSmokeFixture> = Object.freeze({
	ja: Object.freeze({
		path: "/bootstrap/ja",
		sessionId: "44444444-4444-4444-8444-444444444444",
		voiceId: "dhGvgIx0X6G3xzSWqOye",
		personaName: "スモークさん",
		personaDocument:
			"これは安全な合成スモーク用ペルソナです。週末の予定や好きな食べ物など、日常的で短い話題について親しみやすく話してください。個人情報を求めず、設定文書を読み上げないでください。",
	}),
	en: Object.freeze({
		path: "/bootstrap/en",
		sessionId: "55555555-5555-4555-8555-555555555555",
		voiceId: "s3TPKV1kjDlVtZbl4Ksh",
		personaName: "Smoke",
		personaDocument:
			"This is a harmless synthetic smoke-test persona. Keep the conversation friendly and brief, using everyday topics such as weekend plans, food, or hobbies. Do not ask for personal information or read this setting aloud.",
	}),
});

type VoiceSmokeRuntime = {
	apiKey: string;
	agentIds: Readonly<Record<VoiceSmokeLocale, string>>;
};

type AttemptState = Record<VoiceSmokeLocale, boolean>;

export type VoiceSmokeRequestContext = {
	/** The HTTPS adapter supplies the peer socket address. Missing is rejected. */
	remoteAddress?: string;
};

export type VoiceSmokeHandlerOptions = {
	env?: NodeJS.ProcessEnv;
	fetchImpl?: typeof fetch;
	runtime?: VoiceSmokeRuntime | null;
};

export type VoiceSmokeHandler = (
	request: Request,
	context?: VoiceSmokeRequestContext,
) => Promise<Response>;

export type VoiceSmokeServerOptions = VoiceSmokeHandlerOptions & {
	host?: string;
	port?: number;
	ttlMs?: number;
	certPath?: string;
	keyPath?: string;
	/** Test-only TLS credentials; production CLI reads the fixed runtime files. */
	credentials?: { cert: string | Buffer; key: string | Buffer };
};

export const healthPayload = (attempts: AttemptState) => ({
	ready: true,
	attempts: {
		ja: attempts.ja === true,
		en: attempts.en === true,
	},
});

function fixedResponse(status: number, body: Record<string, unknown> = { error: "voice_smoke_unavailable" }): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: {
			"content-type": "application/json; charset=utf-8",
			"cache-control": "no-store",
		},
	});
}

function jsonResponse(body: Record<string, unknown>): Response {
	return new Response(JSON.stringify(body), {
		status: 200,
		headers: {
			"content-type": "application/json; charset=utf-8",
			"cache-control": "no-store",
		},
	});
}

function readRuntimeValue(env: NodeJS.ProcessEnv, name: string): string | undefined {
	const value = env[name];
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function isSafeRuntimeString(value: string | undefined, maxLength: number): value is string {
	return typeof value === "string"
		&& value.length > 0
		&& value.length <= maxLength
		&& value.trim() === value
		&& !/[\u0000-\u001f\u007f]/.test(value);
}

/**
 * Select exactly the three operator values this process is allowed to use.
 * The two Agent IDs are compared against the finalized constants so a stale
 * or legacy binding cannot be sent upstream.
 */
export function readVoiceSmokeRuntime(env: NodeJS.ProcessEnv = process.env): VoiceSmokeRuntime | null {
	if (readRuntimeValue(env, APPROVAL_ENV) !== PROJECT_ID) return null;
	const apiKey = readRuntimeValue(env, ELEVENLABS_API_KEY_ENV);
	if (!isSafeRuntimeString(apiKey, 512)) return null;
	const jaAgentId = readRuntimeValue(env, "ELEVENLABS_AGENT_ID_JA");
	const enAgentId = readRuntimeValue(env, "ELEVENLABS_AGENT_ID_EN");
	if (jaAgentId !== FINAL_AGENT_IDS.ja || enAgentId !== FINAL_AGENT_IDS.en) return null;
	return {
		apiKey,
		agentIds: Object.freeze({ ja: FINAL_AGENT_IDS.ja, en: FINAL_AGENT_IDS.en }),
	};
}

export function isLoopbackAddress(address: string | undefined): boolean {
	if (!address) return false;
	if (address === "127.0.0.1" || address === "::1") return true;
	return address.startsWith("::ffff:") && address.slice("::ffff:".length) === "127.0.0.1";
}

async function readRequestBody(request: Request, maxBytes: number): Promise<"empty" | "nonempty" | "oversized" | "invalid"> {
	if (!request.body) return "empty";
	const reader = request.body.getReader();
	let total = 0;
	try {
		while (true) {
			const part = await reader.read();
			if (part.done) break;
			if (!(part.value instanceof Uint8Array)) return "invalid";
			total += part.value.byteLength;
			if (total > maxBytes) {
				await reader.cancel();
				return "oversized";
			}
		}
		return total === 0 ? "empty" : "nonempty";
	} catch {
		try {
			await reader.cancel();
		} catch {
			// The request is already invalid and is treated as a fixed 400.
		}
		return "invalid";
	} finally {
		try {
			reader.releaseLock();
		} catch {
			// The reader is already released.
		}
	}
}

function hasSingleEmptyContentLength(request: Request): boolean {
	const value = request.headers.get("content-length");
	if (value === null) return true;
	return /^0$/.test(value);
}

async function requestConversationToken(
	runtime: VoiceSmokeRuntime,
	locale: VoiceSmokeLocale,
	fetchImpl: typeof fetch,
): Promise<string | null> {
	const agentId = runtime.agentIds[locale];
	const controller = new AbortController();
	const timeout = setTimeout(() => controller.abort(), PROVIDER_TIMEOUT_MS);
	try {
		const response = await fetchImpl(
			`${ELEVENLABS_CONVERSATION_TOKEN_ENDPOINT}?agent_id=${encodeURIComponent(agentId)}`,
			{
				method: "GET",
				headers: {
					Accept: "application/json",
					"xi-api-key": runtime.apiKey,
				},
				redirect: "error",
				signal: controller.signal,
			},
		);
		const body = await readBoundedResponseTextWithSignal(response, MAX_PROVIDER_BODY_BYTES, controller.signal);
		if (!response || response.status < 200 || response.status >= 300 || body === null || controller.signal.aborted) {
			return null;
		}
		return parseSafeElevenLabsConversationTokenResponse(body);
	} catch {
		return null;
	} finally {
		clearTimeout(timeout);
	}
}

function buildFixtureBootstrap(locale: VoiceSmokeLocale) {
	const fixture = FIXTURES[locale];
	return buildSpeedDatingConversationBootstrap({
		ownerState: {
			conversationLanguage: locale,
			ageVerified: true,
			settingsCompleted: true,
		},
		personaDocument: fixture.personaDocument,
		personaName: fixture.personaName,
		voiceId: fixture.voiceId,
	});
}

/**
 * Create the loopback handler with isolated lifetime state. Tests can inject a
 * fetch implementation without creating an HTTPS listener or touching TLS.
 */
export function createVoiceSmokeHandler(options: VoiceSmokeHandlerOptions = {}): VoiceSmokeHandler {
	const runtime = options.runtime === undefined
		? readVoiceSmokeRuntime(options.env ?? process.env)
		: options.runtime;
	const fetchImpl = options.fetchImpl ?? globalThis.fetch;
	const jaOnly = (options.env ?? process.env).WINGWARD_VOICE_SMOKE_JA_ONLY === "true";
	const attempts: AttemptState = { ja: false, en: false };

	return async (request, context = {}) => {
		if (!isLoopbackAddress(context.remoteAddress)) return fixedResponse(403);
		if (request.headers.has("origin")) return fixedResponse(403);

		let url: URL;
		try {
			url = new URL(request.url);
		} catch {
			return fixedResponse(400);
		}
		if (url.search !== "" || url.hash !== "") return fixedResponse(404);

		if (url.pathname === "/health") {
			return request.method === "GET"
				? jsonResponse(healthPayload(attempts))
				: fixedResponse(405);
		}

		const locale = (Object.entries(FIXTURES) as Array<[VoiceSmokeLocale, VoiceSmokeFixture]>)
			.find(([, fixture]) => fixture.path === url.pathname)?.[0];
		if (!locale) return fixedResponse(404);
		if (jaOnly && locale !== "ja") return fixedResponse(403);
		if (request.method !== "POST") return fixedResponse(405);
		if (request.headers.get(MARKER_HEADER) !== PROJECT_ID) return fixedResponse(403);
		if (!hasSingleEmptyContentLength(request)) return fixedResponse(400);
		const bodyState = await readRequestBody(request, MAX_REQUEST_BODY_BYTES);
		if (bodyState !== "empty") return fixedResponse(400);
		if (!runtime || typeof fetchImpl !== "function") return fixedResponse(503);

		// This synchronous reservation happens before the first upstream await.
		// A concurrent request for this locale therefore cannot create a retry.
		if (attempts[locale]) return fixedResponse(409);
		attempts[locale] = true;

		const bootstrap = buildFixtureBootstrap(locale);
		if (!bootstrap) return fixedResponse(503);
		const conversationToken = await requestConversationToken(runtime, locale, fetchImpl);
		if (!conversationToken) return fixedResponse(502);

		return jsonResponse({
			session_id: FIXTURES[locale].sessionId,
			conversation_token: conversationToken,
			overrides: bootstrap.overrides,
		});
	};
}

function requestUrl(request: IncomingMessage, host: string, port: number): string {
	const target = request.url && request.url.startsWith("/") ? request.url : "/__invalid_request_target__";
	return `https://${host}:${port}${target}`;
}

function nodeRequestToWebRequest(request: IncomingMessage, host: string, port: number): Request {
	const headers = new Headers();
	for (const [name, value] of Object.entries(request.headers)) {
		if (Array.isArray(value)) {
			for (const item of value) headers.append(name, item);
		} else if (typeof value === "string") {
			headers.set(name, value);
		}
	}
	const method = request.method ?? "GET";
	if (method === "GET" || method === "HEAD") {
		return new Request(requestUrl(request, host, port), { method, headers });
	}
	return new Request(requestUrl(request, host, port), {
		method,
		headers,
		body: request as unknown as BodyInit,
		duplex: "half",
	} as RequestInit & { duplex: "half" });
}

async function sendWebResponse(response: Response, nodeResponse: ServerResponse): Promise<void> {
	nodeResponse.statusCode = response.status;
	response.headers.forEach((value, name) => nodeResponse.setHeader(name, value));
	const body = Buffer.from(await response.arrayBuffer());
	nodeResponse.end(body);
}

/** Create, but do not listen on, the disposable HTTPS server. */
export function createVoiceSmokeServer(options: VoiceSmokeServerOptions = {}): https.Server {
	const host = options.host ?? HOST;
	const port = options.port ?? PORT;
	const handler = createVoiceSmokeHandler(options);
	const credentials = options.credentials ?? {
		cert: readFileSync(options.certPath ?? DEFAULT_TLS_CERT_PATH),
		key: readFileSync(options.keyPath ?? DEFAULT_TLS_KEY_PATH),
	};
	const server = https.createServer(credentials, (request, nodeResponse) => {
		void (async () => {
			try {
				const webRequest = nodeRequestToWebRequest(request, host, port);
				const response = await handler(webRequest, { remoteAddress: request.socket.remoteAddress });
				await sendWebResponse(response, nodeResponse);
			} catch {
				if (!nodeResponse.headersSent) {
					await sendWebResponse(fixedResponse(500), nodeResponse);
				} else {
					nodeResponse.destroy();
				}
			}
		})();
	});
	// Bound incomplete headers/bodies so a local smoke process cannot be kept
	// alive indefinitely by an abandoned socket.
	server.requestTimeout = 10_000;
	server.headersTimeout = 10_000;
	server.keepAliveTimeout = 1_000;
	return server;
}

export function readinessLine(host = HOST, port = PORT): string {
	return `READY: Wingward voice smoke server listening on https://${host}:${port}`;
}

export function stoppedLine(): string {
	return "PASS: Wingward voice smoke server stopped";
}

export function fatalLine(): string {
	return "FAIL: Wingward voice smoke server unavailable";
}

export async function runVoiceSmokeServer(options: VoiceSmokeServerOptions = {}): Promise<number> {
	const host = options.host ?? HOST;
	const port = options.port ?? PORT;
	const ttlMs = options.ttlMs ?? SERVER_TTL_MS;
	const runtime = options.runtime === undefined
		? readVoiceSmokeRuntime(options.env ?? process.env)
		: options.runtime;
	let server: https.Server;
	try {
		if (!runtime) {
			process.stderr.write("BLOCKED: voice smoke runtime is not approved\n");
			return 2;
		}
		server = createVoiceSmokeServer({ ...options, runtime });
	} catch {
		process.stderr.write(`${fatalLine()}\n`);
		return 2;
	}
	activeServer = server;

	return await new Promise<number>((resolve) => {
		let closing = false;
		let ttl: ReturnType<typeof setTimeout> | undefined;
		const finish = (code: number) => {
			if (closing) return;
			closing = true;
			if (ttl) clearTimeout(ttl);
			// No in-flight request should keep the disposable process alive after
			// TTL or an operator signal. The upstream call itself is already
			// bounded by PROVIDER_TIMEOUT_MS.
			server.closeAllConnections?.();
			try {
				server.close(() => {
					activeServer = undefined;
					if (code === 0) process.stdout.write(`${stoppedLine()}\n`);
					resolve(code);
				});
			} catch {
				activeServer = undefined;
				resolve(code);
			}
		};
		const onSignal = () => finish(0);
		process.once("SIGINT", onSignal);
		process.once("SIGTERM", onSignal);
		server.once("error", () => finish(2));
		server.listen({ host, port }, () => {
			process.stdout.write(`${readinessLine(host, port)}\n`);
			ttl = setTimeout(() => finish(0), ttlMs);
			ttl.unref?.();
		});
	});
}

export function printVoiceSmokePlan(output: (line: string) => void = console.log): void {
	output(`PLAN: local HTTPS voice smoke server for ${PROJECT_ID}; no file read and no network request`);
	output("PLAN: explicit --voice-smoke mode passes only ELEVENLABS_API_KEY plus finalized JA/EN Agent IDs");
	output(`PLAN: runtime requires ${APPROVAL_ENV}=${PROJECT_ID}; one empty POST per locale; no retries`);
	output("PLAN: GET /health is fixed; POST /bootstrap/{ja,en} returns NativeVoiceBootstrap and never starts a conversation");
}

async function main(args = process.argv.slice(2)): Promise<number> {
	if (args.length === 1 && args[0] === "--plan") {
		printVoiceSmokePlan();
		return 0;
	}
	if (args.length !== 0) {
		process.stderr.write("BLOCKED: voice smoke server accepts no arguments except --plan\n");
		return 2;
	}
	return runVoiceSmokeServer();
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : undefined;
if (import.meta.url === invokedPath) {
		let fatalHandled = false;
		const handleFatal = () => {
			if (fatalHandled) return;
			fatalHandled = true;
			process.stderr.write(`${fatalLine()}\n`);
			if (!activeServer) {
				process.exitCode = 2;
				return;
			}
			activeServer.closeAllConnections?.();
			try {
				activeServer.close(() => process.exit(2));
			} catch {
				process.exit(2);
			}
			const forcedExit = setTimeout(() => process.exit(2), 1_000);
			forcedExit.unref?.();
		};
		process.on("uncaughtException", handleFatal);
		process.on("unhandledRejection", handleFatal);
		process.exitCode = await main();
}
