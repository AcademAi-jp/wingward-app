import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * C1 (step-3c review, Codex P1): the auth cache must not outlive the
 * token's own `exp`. A flat 5-minute TTL means a token cached one second
 * before expiry keeps authenticating for nearly five more minutes, past the
 * point `supabase.auth.getUser()` would reject it — and this cache now also
 * gates the WebSocket handshake (routes/fox-search-ws.ts), not just
 * `requireAuth`.
 */

vi.mock("../db/client", () => ({
	getSupabaseAuthClient: vi.fn(),
	getSupabaseClient: vi.fn(),
}));

import { getSupabaseAuthClient, getSupabaseClient } from "../db/client";
import { __testing, resolveAuthUser } from "./auth";

const mockedGetSupabaseAuthClient = vi.mocked(getSupabaseAuthClient);
const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

function base64url(obj: unknown): string {
	const json = JSON.stringify(obj);
	const base64 = btoa(json);
	return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A JWT-shaped string (unsigned test double) carrying only the claims resolveAuthUser reads out of it. */
function fakeJwt(payload: Record<string, unknown>): string {
	const header = base64url({ alg: "none", typ: "JWT" });
	const body = base64url(payload);
	return `${header}.${body}.fake-signature`;
}

function fakeContext() {
	return { env: {} } as never;
}

function mockSupabaseClients(getUserSpy: ReturnType<typeof vi.fn>) {
	let queriedAuthUserId = "auth-1";
	const profileQuery: Record<string, unknown> = {};
	profileQuery.select = () => profileQuery;
	profileQuery.eq = (column: string, value: unknown) => {
		if (column === "auth_user_id" && typeof value === "string") queriedAuthUserId = value;
		return profileQuery;
	};
	profileQuery.single = async () => ({ data: { id: "profile-1" }, error: null });
	profileQuery.maybeSingle = async () => ({ data: { id: "profile-1", auth_user_id: queriedAuthUserId }, error: null });
	mockedGetSupabaseAuthClient.mockReturnValue({
		auth: { getUser: getUserSpy },
	} as never);
	mockedGetSupabaseClient.mockReturnValue({
		from: () => profileQuery,
	} as never);
	return { profileQuery };
}

beforeEach(() => {
	vi.useFakeTimers();
	__testing.clearAuthCache();
	mockedGetSupabaseAuthClient.mockReset();
	mockedGetSupabaseClient.mockReset();
});

afterEach(() => {
	__testing.clearAuthCache();
	vi.useRealTimers();
});

describe("resolveAuthUser: cache deadline bounded by the token's exp", () => {
	it("C1: a token whose exp is sooner than the flat TTL is re-validated after exp, not served from cache", async () => {
		const now = Date.now();
		const expSeconds = Math.floor(now / 1000) + 2; // expires in 2s, well under the 5-minute TTL
		const token = fakeJwt({ sub: "auth-1", exp: expSeconds });

		const getUserSpy = vi.fn(async () => ({ data: { user: { id: "auth-1", email: "a@example.com" } }, error: null }));
		mockSupabaseClients(getUserSpy);

		const first = await resolveAuthUser(fakeContext(), token);
		expect(first).toEqual({ authUserId: "auth-1", userId: "profile-1" });
		expect(getUserSpy).toHaveBeenCalledTimes(1);

		// Immediately after: still cached (well within both exp and the TTL).
		const second = await resolveAuthUser(fakeContext(), token);
		expect(second).toEqual({ authUserId: "auth-1", userId: "profile-1" });
		expect(getUserSpy).toHaveBeenCalledTimes(1);

		// Advance past exp (3s) but nowhere near the 5-minute flat TTL.
		vi.setSystemTime(now + 3_000);

		const third = await resolveAuthUser(fakeContext(), token);
		expect(third).toEqual({ authUserId: "auth-1", userId: "profile-1" });
		// Re-validated — this is the assertion that fails without the C1 fix.
		expect(getUserSpy).toHaveBeenCalledTimes(2);
	});

	it("a token with no exp claim falls back to the flat TTL (still cached at +3s, still bounded by the 5-minute TTL)", async () => {
		const token = fakeJwt({ sub: "auth-2" }); // no exp

		const getUserSpy = vi.fn(async () => ({ data: { user: { id: "auth-2", email: "b@example.com" } }, error: null }));
		mockSupabaseClients(getUserSpy);

		await resolveAuthUser(fakeContext(), token);
		expect(getUserSpy).toHaveBeenCalledTimes(1);

		vi.setSystemTime(Date.now() + 3_000);
		await resolveAuthUser(fakeContext(), token);
		expect(getUserSpy).toHaveBeenCalledTimes(1); // still cached — fallback never shortened below a sane floor nor extended

		vi.setSystemTime(Date.now() + 6 * 60_000); // past the 5-minute TTL
		await resolveAuthUser(fakeContext(), token);
		expect(getUserSpy).toHaveBeenCalledTimes(2);
	});

	it("a garbage exp claim (non-numeric) falls back to the flat TTL rather than caching forever", async () => {
		const token = fakeJwt({ sub: "auth-3", exp: "not-a-number" });

		const getUserSpy = vi.fn(async () => ({ data: { user: { id: "auth-3", email: "c@example.com" } }, error: null }));
		mockSupabaseClients(getUserSpy);

		await resolveAuthUser(fakeContext(), token);
		vi.setSystemTime(Date.now() + 6 * 60_000);
		await resolveAuthUser(fakeContext(), token);
		expect(getUserSpy).toHaveBeenCalledTimes(2);
	});
});

describe("resolveAuthUser: cached identity requires a live owner profile", () => {
	it("rejects a cached token after its profile is deleted without re-running Auth getUser", async () => {
		const authUserId = "auth-live-delete";
		const token = fakeJwt({ sub: authUserId, exp: Math.floor(Date.now() / 1000) + 60 });
		const getUserSpy = vi.fn(async () => ({ data: { user: { id: authUserId } }, error: null }));
		const { profileQuery } = mockSupabaseClients(getUserSpy);

		await resolveAuthUser(fakeContext(), token);
		expect(__testing.authCacheSize()).toBe(1);
		profileQuery.maybeSingle = async () => ({ data: null, error: null });

		expect(await resolveAuthUser(fakeContext(), token)).toBeNull();
		expect(getUserSpy).toHaveBeenCalledTimes(1);
		expect(__testing.authCacheSize()).toBe(0);
	});

	it("rejects a cached token when the live row points to another auth user", async () => {
		const authUserId = "auth-live-mismatch";
		const token = fakeJwt({ sub: authUserId, exp: Math.floor(Date.now() / 1000) + 60 });
		const getUserSpy = vi.fn(async () => ({ data: { user: { id: authUserId } }, error: null }));
		const { profileQuery } = mockSupabaseClients(getUserSpy);

		await resolveAuthUser(fakeContext(), token);
		profileQuery.maybeSingle = async () => ({ data: { id: "profile-1", auth_user_id: "auth-other" }, error: null });

		expect(await resolveAuthUser(fakeContext(), token)).toBeNull();
		expect(getUserSpy).toHaveBeenCalledTimes(1);
		expect(__testing.authCacheSize()).toBe(0);
	});

	it("fails closed when the cached profile liveness lookup errors", async () => {
		const authUserId = "auth-live-error";
		const token = fakeJwt({ sub: authUserId, exp: Math.floor(Date.now() / 1000) + 60 });
		const getUserSpy = vi.fn(async () => ({ data: { user: { id: authUserId } }, error: null }));
		const { profileQuery } = mockSupabaseClients(getUserSpy);

		await resolveAuthUser(fakeContext(), token);
		profileQuery.maybeSingle = async () => ({ data: null, error: { message: "synthetic profile lookup failure" } });

		expect(await resolveAuthUser(fakeContext(), token)).toBeNull();
		expect(getUserSpy).toHaveBeenCalledTimes(1);
		expect(__testing.authCacheSize()).toBe(0);
	});

	it("rejects a cache hit whose live-profile lookup crosses the token expiry deadline", async () => {
		const now = Date.now();
		const authUserId = "auth-live-expiry-during-lookup";
		const token = fakeJwt({ sub: authUserId, exp: Math.floor(now / 1000) + 2 });
		const getUserSpy = vi.fn(async () => ({ data: { user: { id: authUserId } }, error: null }));
		const { profileQuery } = mockSupabaseClients(getUserSpy);

		await resolveAuthUser(fakeContext(), token);
		let release!: (result: { data: unknown; error: unknown }) => void;
		profileQuery.maybeSingle = () => new Promise((resolve) => {
			release = resolve;
		});

		const pending = resolveAuthUser(fakeContext(), token);
		await Promise.resolve();
		vi.setSystemTime(now + 3_000);
		release({ data: { id: "profile-1", auth_user_id: authUserId }, error: null });

		expect(await pending).toBeNull();
		expect(getUserSpy).toHaveBeenCalledTimes(1);
		expect(__testing.authCacheSize()).toBe(0);
	});
});

describe("resolveAuthUser: bounded cache and expired-entry reclamation", () => {
	it("removes expired entries when a different token is inserted", async () => {
		const getUserSpy = vi.fn(async () => ({
			data: { user: { id: "auth-cache-user", email: "cache@example.invalid" } },
			error: null,
		}));
		mockSupabaseClients(getUserSpy);

		await resolveAuthUser(fakeContext(), fakeJwt({ sub: "expired-entry" }));
		expect(__testing.authCacheSize()).toBe(1);

		vi.setSystemTime(Date.now() + 6 * 60_000);
		await resolveAuthUser(fakeContext(), fakeJwt({ sub: "replacement-entry" }));

		expect(__testing.authCacheSize()).toBe(1);
	});

	it("caps the cache and re-validates the oldest evicted token", async () => {
		const getUserSpy = vi.fn(async () => ({
			data: { user: { id: "auth-cache-user", email: "cache@example.invalid" } },
			error: null,
		}));
		mockSupabaseClients(getUserSpy);

		const tokens = Array.from({ length: __testing.AUTH_CACHE_MAX_ENTRIES + 1 }, (_, index) =>
			fakeJwt({ sub: `bounded-cache-${index}` }),
		);
		for (const token of tokens) {
			await resolveAuthUser(fakeContext(), token);
		}

		expect(__testing.authCacheSize()).toBe(__testing.AUTH_CACHE_MAX_ENTRIES);
		expect(getUserSpy).toHaveBeenCalledTimes(tokens.length);

		// The newest token remains cached, while the oldest one was evicted and
		// must be verified again. Either outcome remains authorization-safe.
		await resolveAuthUser(fakeContext(), tokens.at(-1)!);
		expect(getUserSpy).toHaveBeenCalledTimes(tokens.length);
		await resolveAuthUser(fakeContext(), tokens[0]);
		expect(getUserSpy).toHaveBeenCalledTimes(tokens.length + 1);
		expect(__testing.authCacheSize()).toBe(__testing.AUTH_CACHE_MAX_ENTRIES);
	});
});

describe("resolveAuthUser: the database trigger owns profile creation", () => {
	it("returns null for a missing profile without attempting an insert or upsert", async () => {
		const authUserId = "auth-missing-profile-no-write-unique";
		const token = fakeJwt({ sub: authUserId, exp: Math.floor(Date.now() / 1000) + 60 });
		const getUserSpy = vi.fn(async () => ({
			data: { user: { id: authUserId, email: "missing-profile@example.invalid" } },
			error: null,
		}));
		mockedGetSupabaseAuthClient.mockReturnValue({ auth: { getUser: getUserSpy } } as never);

		const from = vi.fn(() => ({
			select: () => ({
				eq: () => ({
					single: async () => ({ data: null, error: null }),
				}),
			}),
		}));
		// Deliberately omit insert/upsert: a lazy profile write would fail this test.
		mockedGetSupabaseClient.mockReturnValue({ from } as never);

		expect(await resolveAuthUser(fakeContext(), token)).toBeNull();
		expect(from).toHaveBeenCalledTimes(1);
	});

	it("returns null for a profile lookup error without attempting an insert or upsert", async () => {
		const authUserId = "auth-error-profile-no-write-unique";
		const token = fakeJwt({ sub: authUserId, exp: Math.floor(Date.now() / 1000) + 60 });
		const getUserSpy = vi.fn(async () => ({
			data: { user: { id: authUserId, email: "error-profile@example.invalid" } },
			error: null,
		}));
		mockedGetSupabaseAuthClient.mockReturnValue({ auth: { getUser: getUserSpy } } as never);

		const from = vi.fn(() => ({
			select: () => ({
				eq: () => ({
					single: async () => ({ data: null, error: { message: "profile lookup failed" } }),
				}),
			}),
		}));
		// Deliberately omit insert/upsert: a lazy profile write would fail this test.
		mockedGetSupabaseClient.mockReturnValue({ from } as never);

		expect(await resolveAuthUser(fakeContext(), token)).toBeNull();
		expect(from).toHaveBeenCalledTimes(1);
	});
});
