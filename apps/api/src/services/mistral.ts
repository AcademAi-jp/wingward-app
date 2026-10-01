import { Mistral } from "@mistralai/mistralai";
import { z } from "zod";

// Model IDs are pinned to dated versions, never to a `-latest` alias. An alias
// changes what it points at without warning, so a model swap arrives as a
// silent behaviour change; a pinned ID that gets retired fails loudly instead,
// which is the failure we can actually notice and fix. Same reasoning as
// pinning GitHub Actions to commit SHAs.
//
// Verified against GET /v1/models on 2026-08-12. Note that the API names differ
// from the ones in Mistral's model documentation (the docs say
// `ministral-3-8b-2512`; the API only accepts `ministral-8b-2512`), so confirm
// any replacement against /v1/models rather than the docs.
//
// Re-check when a model is deprecated: https://docs.mistral.ai/models/overview
const DEFAULT_MODEL = "ministral-8b-2512";
/** $0.50/$1.50 per 1M tokens. Low-volume, quality-sensitive calls. */
export const MISTRAL_LARGE = "mistral-large-2512";
/** $0.15/$0.15 per 1M tokens. High-volume calls, chiefly fox conversations. */
export const MISTRAL_LIGHT = "ministral-8b-2512";

const clientCache = new Map<string, Mistral>();

export function getMistralClient(apiKey: string) {
	const existing = clientCache.get(apiKey);
	if (existing) return existing;
	const client = new Mistral({
		apiKey,
		retryConfig: {
			strategy: "backoff",
			backoff: {
				initialInterval: 1000,
				maxInterval: 15000,
				exponent: 1.5,
				maxElapsedTime: 20000,
			},
			retryConnectionErrors: true,
		},
	});
	clientCache.set(apiKey, client);
	return client;
}

export type ChatMessage = { role: "user" | "assistant" | "system"; content: string };

/** JSON mode を有効にすると、LM の出力が常に有効な JSON オブジェクトになる（ストラクチャードアウトプット） */
export type ChatCompleteOptions = {
	model?: string;
	maxTokens?: number;
	temperature?: number;
	/** 会話スコアなど構造化出力が必要なときに指定 */
	responseFormat?: { type: "json_object" };
};

export async function chatComplete(
	apiKey: string | undefined,
	messages: ChatMessage[],
	options?: ChatCompleteOptions,
): Promise<string> {
	if (!apiKey?.trim()) {
		throw new Error("MISTRAL_API_KEY is not set or empty. Set it in .mise.local.toml or apps/api/.env");
	}
	// Ensure every message has string content (Mistral rejects null/undefined; SDK may send invalid JSON otherwise)
	const normalizedMessages = messages.map((m) => ({
		role: m.role,
		content: typeof m.content === "string" ? m.content : "",
	}));
	const request: Parameters<Mistral["chat"]["complete"]>[0] = {
		model: options?.model ?? DEFAULT_MODEL,
		messages: normalizedMessages,
		maxTokens: options?.maxTokens ?? 1024,
		stream: false,
	};
	if (options?.temperature != null) request.temperature = options.temperature;
	if (options?.responseFormat) request.responseFormat = options.responseFormat;

	const client = getMistralClient(apiKey);
	const response = await client.chat.complete(request);
	const choice = response.choices?.[0];
	if (choice?.finishReason === "length") {
		console.warn(`[chatComplete] finish_reason=length: output may be truncated (maxTokens=${options?.maxTokens ?? 1024})`);
	}
	const content = choice?.message?.content;
	if (!content) {
		console.warn("[chatComplete] Empty response from model");
	}
	return typeof content === "string" ? content : "";
}

export type TokenUsage = {
	inputTokens: number;
	outputTokens: number;
	/**
	 * `null` means "not measured" (the field was absent or malformed), which is
	 * distinct from a measured 0 cached tokens. Never coerce this to 0 — that
	 * would make an untested code path look like a confirmed cache miss.
	 */
	cachedTokens: number | null;
};

// The raw HTTP response shape from POST /v1/chat/completions, validated
// because this is external input. `prompt_tokens_details.cached_tokens` is
// intentionally left as `z.unknown()` here and checked separately below: it
// is optional and its absence/malformation must produce `null`, not fail the
// whole response.
const finiteNonNegativeInt = z.number().int().nonnegative().finite();
const ChatCompletionResponseSchema = z.object({
	// `content` is deliberately NOT `z.string()`. Mistral's own types allow a
	// content-chunk array, and `finish_reason` can arrive as null. `chatComplete`
	// degrades to "" in that case rather than throwing, and this path must not
	// be stricter: a benign response shape turning into a thrown error would
	// fail the whole conversation after the call was already billed.
	choices: z
		.array(
			z.object({
				message: z.object({ content: z.unknown() }),
				finish_reason: z.string().nullish(),
			}),
		)
		.min(1),
	usage: z.object({
		prompt_tokens: finiteNonNegativeInt,
		completion_tokens: finiteNonNegativeInt,
		prompt_tokens_details: z.unknown().optional(),
	}),
});

/**
 * Same call as {@link chatComplete}, plus token usage, via a raw `fetch`
 * instead of the `@mistralai/mistralai` SDK.
 *
 * The SDK (pinned at 1.14.1) cannot send `prompt_cache_key` in a request and
 * has no `prompt_tokens_details` in its response types, so there is no way to
 * get usage/caching data through it. This function talks to the HTTP API
 * directly with snake_case wire field names instead.
 *
 * Deliberately has NO retry logic. The only caller (fox-conversation.ts)
 * already retries failed calls up to 3 times with 429 detection and backoff;
 * adding retries here would multiply that to effectively 9 attempts per call
 * and make Mistral rate limiting worse, not better. This also means the
 * SDK client's connection-retry budget (`maxElapsedTime` 20s in
 * `getMistralClient`) does not apply on this path — a single attempt either
 * succeeds within the abort timeout below or the caller's retry loop handles
 * it.
 */
export async function chatCompleteWithUsage(
	apiKey: string | undefined,
	messages: ChatMessage[],
	options?: ChatCompleteOptions & { promptCacheKey?: string },
): Promise<{ content: string; usage: TokenUsage }> {
	if (!apiKey?.trim()) {
		throw new Error("MISTRAL_API_KEY is not set or empty. Set it in .mise.local.toml or apps/api/.env");
	}
	const normalizedMessages = messages.map((m) => ({
		role: m.role,
		content: typeof m.content === "string" ? m.content : "",
	}));
	const body: Record<string, unknown> = {
		model: options?.model ?? DEFAULT_MODEL,
		messages: normalizedMessages,
		max_tokens: options?.maxTokens ?? 1024,
		stream: false,
	};
	if (options?.temperature != null) body.temperature = options.temperature;
	if (options?.responseFormat) body.response_format = options.responseFormat;
	if (options?.promptCacheKey) body.prompt_cache_key = options.promptCacheKey;

	const response = await fetch("https://api.mistral.ai/v1/chat/completions", {
		method: "POST",
		headers: {
			Authorization: `Bearer ${apiKey}`,
			"Content-Type": "application/json",
		},
		body: JSON.stringify(body),
		// A bare fetch has no timeout of its own; the SDK path relied on the
		// client's retryConfig.backoff.maxElapsedTime (20s) for that, which does
		// not apply here since this path makes no SDK calls at all.
		signal: AbortSignal.timeout(30_000),
	});

	if (!response.ok) {
		// Never include the response body in the error message: Mistral error
		// bodies can echo back the request, which includes persona/user text.
		// At most surface a `type`/`code` field if the body happens to parse as
		// JSON with one.
		let detail = "";
		try {
			const errBody: unknown = await response.json();
			if (errBody && typeof errBody === "object") {
				const rec = errBody as Record<string, unknown>;
				const parts = [rec.type, rec.code].filter((v): v is string => typeof v === "string");
				if (parts.length) detail = ` (${parts.join(", ")})`;
			}
		} catch {
			// Body wasn't JSON (or reading it failed) — omit detail entirely
			// rather than risk echoing raw response text.
		}
		throw new Error(`Mistral API request failed: HTTP ${response.status}${detail}`);
	}

	const json: unknown = await response.json();
	const parsed = ChatCompletionResponseSchema.parse(json);
	const choice = parsed.choices[0];
	if (choice.finish_reason === "length") {
		console.warn(`[chatCompleteWithUsage] finish_reason=length: output may be truncated (maxTokens=${options?.maxTokens ?? 1024})`);
	}

	let cachedTokens: number | null = null;
	const details = parsed.usage.prompt_tokens_details;
	if (details && typeof details === "object") {
		const rawCached = (details as Record<string, unknown>).cached_tokens;
		const check = finiteNonNegativeInt.safeParse(rawCached);
		if (check.success) cachedTokens = check.data;
	}

	const content = choice.message.content;
	if (typeof content !== "string") {
		console.warn("[chatCompleteWithUsage] Non-string response content; treating as empty");
	}
	return {
		content: typeof content === "string" ? content : "",
		usage: {
			inputTokens: parsed.usage.prompt_tokens,
			outputTokens: parsed.usage.completion_tokens,
			cachedTokens,
		},
	};
}

/**
 * A single, byte-bounded Mistral request for one-shot owner profile revisions.
 * This deliberately bypasses the SDK retry policy and refuses truncated or
 * oversized responses so a failed paid attempt cannot silently be replayed.
 */
export type BoundedChatCompleteOptions = ChatCompleteOptions & Readonly<{
	maxRequestBytes: number;
	maxResponseBytes: number;
	/** Reserved input+output token units; UTF-8 bytes conservatively bound input. */
	maxTotalTokenUnits?: number;
	promptCacheKey?: string;
}>;

export const MISTRAL_REQUEST_TOKEN_OVERHEAD = 1024;

export async function chatCompleteOnceBounded(
	apiKey: string | undefined,
	messages: ChatMessage[],
	options: BoundedChatCompleteOptions,
): Promise<{ content: string; finishReason: string | null; inputTokens: number; outputTokens: number }> {
	if (!apiKey?.trim()) throw new Error("Mistral API key unavailable");
	if (!Number.isSafeInteger(options.maxRequestBytes) || options.maxRequestBytes < 1
		|| !Number.isSafeInteger(options.maxResponseBytes) || options.maxResponseBytes < 1) {
		throw new Error("Invalid bounded Mistral request limits");
	}
	const maxTokens = options.maxTokens ?? 1024;
	if (!Number.isSafeInteger(maxTokens) || maxTokens < 1 || maxTokens > 32_768
		|| (options.maxTotalTokenUnits !== undefined
			&& (!Number.isSafeInteger(options.maxTotalTokenUnits) || options.maxTotalTokenUnits < 1))) {
		throw new Error("Invalid bounded Mistral token limits");
	}
	const body: Record<string, unknown> = {
		model: options.model ?? DEFAULT_MODEL,
		messages: messages.map((message) => ({
			role: message.role,
			content: typeof message.content === "string" ? message.content : "",
		})),
		max_tokens: maxTokens,
		stream: false,
	};
	if (options.temperature != null) body.temperature = options.temperature;
	if (options.responseFormat) body.response_format = options.responseFormat;
	if (options.promptCacheKey) body.prompt_cache_key = options.promptCacheKey;
	const serialized = JSON.stringify(body);
	const requestBytes = new TextEncoder().encode(serialized).byteLength;
	if (requestBytes > options.maxRequestBytes) {
		throw new Error("Mistral request exceeds the configured byte limit");
	}
	if (options.maxTotalTokenUnits !== undefined
		&& requestBytes + MISTRAL_REQUEST_TOKEN_OVERHEAD + maxTokens > options.maxTotalTokenUnits) {
		throw new Error("Mistral request exceeds the reserved token limit");
	}

	const response = await fetch("https://api.mistral.ai/v1/chat/completions", {
		method: "POST",
		redirect: "manual",
		headers: {
			Authorization: `Bearer ${apiKey}`,
			"Content-Type": "application/json",
		},
		body: serialized,
		signal: AbortSignal.timeout(30_000),
	});
	if (!response.ok) {
		// Workerd supports manual redirects; never follow or disclose an error body.
		await response.body?.cancel();
		throw new Error(`Mistral API request failed: HTTP ${response.status}`);
	}
	const responseBytes = await readResponseBytesAtMost(response, options.maxResponseBytes);
	let responseValue: unknown;
	try {
		responseValue = JSON.parse(new TextDecoder().decode(responseBytes));
	} catch {
		throw new Error("Mistral API returned invalid JSON");
	}
	const parsed = ChatCompletionResponseSchema.safeParse(responseValue);
	if (!parsed.success) throw new Error("Mistral API returned an invalid response");
	if (options.maxTotalTokenUnits !== undefined
		&& (parsed.data.usage.prompt_tokens + parsed.data.usage.completion_tokens > options.maxTotalTokenUnits
			|| parsed.data.usage.completion_tokens > maxTokens)) {
		throw new Error("Mistral API returned usage exceeding the reserved token limit");
	}
	const choice = parsed.data.choices[0];
	if (choice.finish_reason === "length") throw new Error("Mistral API response was truncated");
	if (typeof choice.message.content !== "string" || choice.message.content.trim().length === 0) {
		throw new Error("Mistral API returned an empty response");
	}
	return {
		content: choice.message.content,
		finishReason: choice.finish_reason ?? null,
		inputTokens: parsed.data.usage.prompt_tokens,
		outputTokens: parsed.data.usage.completion_tokens,
	};
}

async function readResponseBytesAtMost(response: Response, maxBytes: number): Promise<Uint8Array> {
	const reader = response.body?.getReader();
	if (!reader) throw new Error("Mistral API response body is unavailable");
	const chunks: Uint8Array[] = [];
	let total = 0;
	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) break;
			if (!value) continue;
			total += value.byteLength;
			if (total > maxBytes) {
				await reader.cancel();
				throw new Error("Mistral API response exceeds the configured byte limit");
			}
			chunks.push(value);
		}
	} finally {
		reader.releaseLock();
	}
	const result = new Uint8Array(total);
	let offset = 0;
	for (const chunk of chunks) {
		result.set(chunk, offset);
		offset += chunk.byteLength;
	}
	return result;
}
