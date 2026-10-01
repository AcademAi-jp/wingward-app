import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { chatComplete, chatCompleteOnceBounded, chatCompleteWithUsage } from "./mistral";

/**
 * `chatCompleteWithUsage` talks to the Mistral HTTP API directly with a raw
 * `fetch` (the SDK can neither send `prompt_cache_key` nor read
 * `prompt_tokens_details`), so every guard here protects a real accounting or
 * safety property that a naive implementation gets wrong:
 *
 * - Multi-call summing: fox-conversation.ts accumulates usage across ~16
 *   calls per conversation; a summing bug either double-bills or silently
 *   loses tokens from the cost record.
 * - `cachedTokens: null` vs `0`: "not measured" and "measured zero cache
 *   hits" are different facts. Coercing the former to the latter would make
 *   an untested/broken caching path look like a confirmed cache miss forever.
 * - Rejecting malformed `usage` fields: a NaN/negative/fractional token count
 *   silently corrupts the cost ledger instead of failing loudly.
 * - Error messages must never contain the raw response body: Mistral error
 *   bodies can echo the request, which contains persona/user text (repo rule
 *   P0-4, no secrets/PII in error messages).
 * - `prompt_cache_key` shape: wrong key shape silently defeats caching
 *   (either no reuse, or cross-conversation prompt pollution) without ever
 *   throwing, so it has to be asserted on the wire request.
 * - `AbortSignal` presence: without it a stuck TCP connection hangs a fox
 *   conversation round forever (the SDK's own retry timeout doesn't apply on
 *   this path).
 * - `chatComplete` (the pre-existing SDK-based function) must be provably
 *   untouched by this change; its 8 existing call sites depend on it still
 *   returning a bare string.
 */

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json" },
	});
}

function validBody(overrides: Record<string, unknown> = {}) {
	return {
		choices: [{ message: { content: "hello" }, finish_reason: "stop" }],
		usage: { prompt_tokens: 100, completion_tokens: 20 },
		...overrides,
	};
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
	fetchMock = vi.fn();
	vi.stubGlobal("fetch", fetchMock);
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe("chatCompleteWithUsage", () => {
	it("sums input_tokens/output_tokens correctly across multiple calls", async () => {
		fetchMock
			.mockResolvedValueOnce(jsonResponse(validBody({ usage: { prompt_tokens: 100, completion_tokens: 20 } })))
			.mockResolvedValueOnce(jsonResponse(validBody({ usage: { prompt_tokens: 150, completion_tokens: 30 } })));

		const r1 = await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }]);
		const r2 = await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }]);

		let totalIn = 0;
		let totalOut = 0;
		for (const r of [r1, r2]) {
			totalIn += r.usage.inputTokens;
			totalOut += r.usage.outputTokens;
		}
		expect(totalIn).toBe(250);
		expect(totalOut).toBe(50);
	});

	it("returns cachedTokens: null (not 0) when prompt_tokens_details is entirely absent", async () => {
		fetchMock.mockResolvedValueOnce(
			jsonResponse(validBody({ usage: { prompt_tokens: 100, completion_tokens: 20 } })),
		);
		const result = await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }]);
		expect(result.usage.cachedTokens).toBeNull();
		// Negative control for this guard lives in the report; deliberately not
		// `.toBe(0)` here — 0 is the wrong value we are guarding against.
	});

	it("sums cached_tokens correctly when present", async () => {
		fetchMock.mockResolvedValueOnce(
			jsonResponse(
				validBody({
					usage: {
						prompt_tokens: 1852,
						completion_tokens: 16,
						prompt_tokens_details: { cached_tokens: 1792 },
					},
				}),
			),
		);
		const result = await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }]);
		expect(result.usage.cachedTokens).toBe(1792);
	});

	it.each([
		["non-numeric prompt_tokens", { prompt_tokens: "100", completion_tokens: 20 }],
		["negative completion_tokens", { prompt_tokens: 100, completion_tokens: -1 }],
		["non-integer prompt_tokens", { prompt_tokens: 100.5, completion_tokens: 20 }],
		["non-finite prompt_tokens", { prompt_tokens: Number.POSITIVE_INFINITY, completion_tokens: 20 }],
	])("rejects a response with %s", async (_label, usage) => {
		fetchMock.mockResolvedValueOnce(jsonResponse(validBody({ usage })));
		await expect(chatCompleteWithUsage("key", [{ role: "user", content: "hi" }])).rejects.toThrow();
	});

	it("does not leak the response body into the thrown error on a non-2xx response", async () => {
		const secretMarker = "PERSONA_SECRET_MARKER_should_not_leak";
		fetchMock.mockResolvedValueOnce(
			jsonResponse({ message: `Bad request, echoing your persona: ${secretMarker}`, type: "invalid_request_error" }, 400),
		);
		expect.assertions(3);
		try {
			await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }]);
		} catch (e) {
			expect(e).toBeInstanceOf(Error);
			expect((e as Error).message).not.toContain(secretMarker);
			expect((e as Error).message).toContain("400");
		}
	});

	it("sends prompt_cache_key with the exact value passed by the caller", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(validBody()));
		await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }], {
			promptCacheKey: "conv-123:A",
		});
		const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		const sentBody = JSON.parse(init.body as string);
		expect(sentBody.prompt_cache_key).toBe("conv-123:A");
	});

	it("omits prompt_cache_key entirely when not passed (scoring call shape)", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(validBody()));
		await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }], {
			maxTokens: 2048,
			responseFormat: { type: "json_object" },
		});
		const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		const sentBody = JSON.parse(init.body as string);
		expect(sentBody).not.toHaveProperty("prompt_cache_key");
		expect(sentBody.max_tokens).toBe(2048);
		expect(sentBody.response_format).toEqual({ type: "json_object" });
	});

	it("sets an AbortSignal on the request", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(validBody()));
		await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }]);
		const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		expect(init.signal).toBeInstanceOf(AbortSignal);
	});
});

describe("chatCompleteOnceBounded", () => {
	it.each([0, -1, 1.5, 32_769, Infinity])("rejects invalid output token cap %s before fetch", async maxTokens => {
		await expect(chatCompleteOnceBounded("key", [{ role: "user", content: "synthetic" }], {
			maxTokens, maxRequestBytes: 26_000, maxResponseBytes: 64_000, maxTotalTokenUnits: 20_000,
		})).rejects.toThrow(/token limits/);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("counts the full UTF-8 wire body, output and framing against reserved units before fetch", async () => {
		const options = { maxTokens: 200, maxRequestBytes: 8192, maxResponseBytes: 32_768, promptCacheKey: "synthetic-cache" };
		const messages = [{ role: "user" as const, content: "日".repeat(300) }];
		const wire = JSON.stringify({ model: "ministral-8b-2512", messages, max_tokens: 200, stream: false, prompt_cache_key: "synthetic-cache" });
		const exactUnits = new TextEncoder().encode(wire).byteLength + 1024 + 200;
		await expect(chatCompleteOnceBounded("key", messages, { ...options, maxTotalTokenUnits: exactUnits - 1 })).rejects.toThrow(/reserved token limit/);
		expect(fetchMock).not.toHaveBeenCalled();
		fetchMock.mockResolvedValueOnce(jsonResponse(validBody()));
		await chatCompleteOnceBounded("key", messages, { ...options, maxTotalTokenUnits: exactUnits });
		expect(fetchMock).toHaveBeenCalledTimes(1);
		expect(fetchMock.mock.calls[0][1].body).toBe(wire);
	});

	it("rejects provider usage above the requested output cap without a second fetch", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(validBody({ usage: { prompt_tokens: 100, completion_tokens: 201 } })));
		await expect(chatCompleteOnceBounded("key", [{ role: "user", content: "synthetic" }], {
			maxTokens: 200, maxRequestBytes: 8192, maxResponseBytes: 32_768, maxTotalTokenUnits: 20_000,
		})).rejects.toThrow(/usage exceeding/);
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

	it("makes one redirect-blocked request and returns measured usage", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(validBody()));
		const result = await chatCompleteOnceBounded("key", [{ role: "user", content: "synthetic prompt" }], {
			model: "mistral-large-test",
			maxTokens: 1500,
			responseFormat: { type: "json_object" },
			maxRequestBytes: 26_000,
			maxResponseBytes: 64_000,
		});
		const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
		expect(fetchMock).toHaveBeenCalledTimes(1);
		expect(init.redirect).toBe("manual");
		expect(init.signal).toBeInstanceOf(AbortSignal);
		expect(result).toMatchObject({ content: "hello", finishReason: "stop", inputTokens: 100, outputTokens: 20 });
	});

	it.each([301, 302, 303, 307, 308])("rejects HTTP %s without following Location or exposing vendor data", async status => {
		const cancel = vi.fn();
		const stream = new ReadableStream({ cancel });
		fetchMock.mockResolvedValueOnce(new Response(stream, { status, headers: { Location: "https://untrusted.invalid/SYNTHETIC_SECRET" } }));
		await expect(chatCompleteOnceBounded("key", [{ role: "user", content: "synthetic" }], {
			maxRequestBytes: 8192, maxResponseBytes: 4096,
		})).rejects.toThrow(`Mistral API request failed: HTTP ${status}`);
		expect(fetchMock).toHaveBeenCalledTimes(1);
		expect(fetchMock.mock.calls[0][0]).toBe("https://api.mistral.ai/v1/chat/completions");
		expect(fetchMock.mock.calls[0][1].redirect).toBe("manual");
		expect(cancel).toHaveBeenCalledOnce();
	});

	it("rejects an oversized request before fetch", async () => {
		await expect(chatCompleteOnceBounded("key", [{ role: "user", content: "あ".repeat(100) }], {
			maxRequestBytes: 100,
			maxResponseBytes: 64_000,
		})).rejects.toThrow(/byte limit/);
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("rejects an oversized response and does not retry", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(validBody({ choices: [{ message: { content: "x".repeat(500) }, finish_reason: "stop" }] })));
		await expect(chatCompleteOnceBounded("key", [{ role: "user", content: "synthetic" }], {
			maxRequestBytes: 26_000,
			maxResponseBytes: 100,
		})).rejects.toThrow(/response exceeds/);
		expect(fetchMock).toHaveBeenCalledTimes(1);
	});

	it("does not retry provider failures or expose an echoed input body", async () => {
		const marker = "SYNTHETIC_TRANSCRIPT_MARKER";
		fetchMock.mockResolvedValueOnce(jsonResponse({ message: marker }, 429));
		const request = chatCompleteOnceBounded("key", [{ role: "user", content: marker }], {
			maxRequestBytes: 26_000,
			maxResponseBytes: 64_000,
		});
		let thrown: unknown;
		try {
			await request;
		} catch (error) {
			thrown = error;
		}
		expect(fetchMock).toHaveBeenCalledTimes(1);
		expect(thrown).toBeInstanceOf(Error);
		expect((thrown as Error).message).toContain("429");
		expect((thrown as Error).message).not.toContain(marker);
	});

	it("rejects truncated model output", async () => {
		fetchMock.mockResolvedValueOnce(jsonResponse(validBody({ choices: [{ message: { content: "{}" }, finish_reason: "length" }] })));
		await expect(chatCompleteOnceBounded("key", [{ role: "user", content: "synthetic" }], {
			maxRequestBytes: 26_000,
			maxResponseBytes: 64_000,
		})).rejects.toThrow(/truncated/);
	});
});

describe("chatComplete (unchanged SDK path)", () => {
	it("still returns a bare string and does not call fetch", async () => {
		// chatComplete goes through the @mistralai/mistralai SDK client, not
		// fetch, so a fetch stub must never be hit by it. We only assert the
		// contract that matters to its 8 call sites: no API key -> throws
		// before any network path is touched, string in, string out otherwise.
		await expect(chatComplete(undefined, [{ role: "user", content: "hi" }])).rejects.toThrow(
			/MISTRAL_API_KEY/,
		);
		expect(fetchMock).not.toHaveBeenCalled();
	});
});

describe("benign response variants must not throw after the call is already billed", () => {
	/**
	 * A first implementation validated `content` as z.string() and
	 * `finish_reason` as an optional string. Mistral's own types allow a
	 * content-chunk array, and finish_reason can arrive as null — either would
	 * have thrown on a successful, already-billed 200 response, which the
	 * caller's retry loop turns into a failed conversation. `chatComplete`
	 * degrades to "" instead, and this path must not be stricter than the one
	 * it mirrors.
	 */
	it("accepts a null finish_reason", async () => {
		fetchMock.mockResolvedValueOnce(
			jsonResponse({
				choices: [{ message: { content: "hi" }, finish_reason: null }],
				usage: { prompt_tokens: 10, completion_tokens: 2 },
			}),
		);
		const result = await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }]);
		expect(result.content).toBe("hi");
		expect(result.usage.inputTokens).toBe(10);
	});

	it("degrades non-string content to an empty string instead of throwing, and still records usage", async () => {
		fetchMock.mockResolvedValueOnce(
			jsonResponse({
				choices: [{ message: { content: [{ type: "text", text: "hi" }] }, finish_reason: "stop" }],
				usage: { prompt_tokens: 10, completion_tokens: 2 },
			}),
		);
		const result = await chatCompleteWithUsage("key", [{ role: "user", content: "hi" }]);
		expect(result.content).toBe("");
		// The tokens were still spent, so they must still be accounted for.
		expect(result.usage).toEqual({ inputTokens: 10, outputTokens: 2, cachedTokens: null });
	});
});
