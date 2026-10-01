import { Hono } from "hono";
import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const testAuth = vi.hoisted(() => ({ userId: "profile-1", authUserId: "auth-1" }));
const DELETION_OWNER_ID = "10000000-0000-4000-8000-000000000001";
const DELETION_AUTH_USER_ID = "00000000-0000-4000-8000-000000000001";
const OTHER_DELETION_OWNER_ID = "10000000-0000-4000-8000-000000000002";
const OTHER_DELETION_AUTH_USER_ID = "00000000-0000-4000-8000-000000000002";
const DELETION_OPERATION_ID = "20000000-0000-4000-8000-000000000001";
const TEST_DELETION_RECEIPT = `${DELETION_OPERATION_ID}.${"A".repeat(43)}`;
const TEST_DELETION_HASH = createHash("sha256").update(TEST_DELETION_RECEIPT).digest("hex");
const deletionReceiptHeader = "X-Account-Deletion-Receipt";

function useDeletionOwner(ownerID = DELETION_OWNER_ID, authUserID = DELETION_AUTH_USER_ID): void {
	testAuth.userId = ownerID;
	testAuth.authUserId = authUserID;
}

function deletionHeaders(receipt = TEST_DELETION_RECEIPT): Record<string, string> {
	return { [deletionReceiptHeader]: receipt };
}

vi.mock("../middleware/auth", () => ({
	requireAuth: async (c: import("hono").Context, next: () => Promise<void>) => {
		c.set("user_id", testAuth.userId);
		c.set("auth_user_id", testAuth.authUserId);
		await next();
	},
}));
vi.mock("../db/client", () => ({ getSupabaseClient: vi.fn() }));

import { getSupabaseClient } from "../db/client";
import auth from "./auth";

const mockedGetSupabaseClient = vi.mocked(getSupabaseClient);

type ProfileState = {
	birth_date: string | null;
	age_verified_at: string | null;
	age_verification_method: string | null;
};

interface FakeOptions {
	me?: Record<string, unknown>;
	updateResult?: { data: ProfileState | null; error: { message: string } | null };
	currentResult?: { data: ProfileState | null; error: { message: string } | null };
}

type DeletionProfile = { id: string; auth_user_id: string; avatar_storage_path?: string | null };
type DeletionAuthError = { message: string; status?: number; code?: string };

interface DeletionFakeOptions {
	currentProfile?: DeletionProfile | null;
	profileLookupError?: DeletionAuthError | null;
	deleteError?: DeletionAuthError | null;
	remainingProfile?: { id: string } | null;
	verificationError?: DeletionAuthError | null;
	authUser?: { id: string } | null;
	authLookupError?: DeletionAuthError | null;
	operationOwnerID?: string;
	operationAuthUserID?: string;
	operationID?: string;
	operationReceiptHash?: string;
	operationStatus?: "pending" | "deleting" | "deleted";
	operationExpiresAt?: string;
	operationMissing?: boolean;
	registerResult?: string;
	claimResult?: string;
	statusRateAllowed?: boolean;
	markDeleted?: boolean;
}

function makeSupabase(options: FakeOptions = {}) {
	const updateRow = vi.fn();
	const updateEq = vi.fn();
	const updateIs = vi.fn();
	return {
		updateRow,
		updateEq,
		updateIs,
		from(table: string) {
			if (table !== "user_profiles") throw new Error(`unexpected table: ${table}`);
			return {
				select: () => ({
					eq: () => ({
						single: async () => ({
							data: options.me ?? {
								id: "profile-1",
								nickname: "User",
								gender: null,
								birth_year: 1990,
								language: "en",
								onboarding_status: "not_started",
								avatar_url: null,
								notification_seen_at: null,
								age_verified_at: null,
								age_verification_method: null,
							},
							error: null,
						}),
					maybeSingle: async () => options.currentResult ?? { data: null, error: null },
				}),
				}),
				update: (row: Record<string, unknown>) => {
					updateRow(row);
					return {
						eq: (column: string, value: unknown) => {
							updateEq(column, value);
							return {
								is: (isColumn: string, isValue: unknown) => {
									updateIs(isColumn, isValue);
									return {
										select: () => ({
											maybeSingle: async () => options.updateResult ?? {
												data: {
													birth_date: row.birth_date,
													age_verified_at: row.age_verified_at,
													age_verification_method: row.age_verification_method,
												},
												error: null,
											},
										}),
									};
								},
							};
						},
					};
				},
				};
			},
		};
}

function makeDeletionSupabase(options: DeletionFakeOptions = {}) {
	let authDeleted = false;
	const deleteUser = vi.fn(async () => {
		if (!options.deleteError || options.deleteError.code === "user_not_found") authDeleted = true;
		return { data: { user: null }, error: options.deleteError ?? null };
	});
	const getUserById = vi.fn(async () => {
		if (options.authLookupError) return { data: { user: null }, error: options.authLookupError };
		if (authDeleted || options.authUser === null) return { data: { user: null }, error: null };
		return {
			data: { user: options.authUser === undefined ? { id: testAuth.authUserId } : options.authUser },
			error: null,
		};
	});
	const selectCalls = vi.fn();
	const rpcCalls = vi.fn();
	let selectCall = 0;
	const op = {
		operation_id: options.operationID ?? DELETION_OPERATION_ID,
		owner_profile_id: options.operationOwnerID ?? DELETION_OWNER_ID,
		auth_user_id: options.operationAuthUserID ?? DELETION_AUTH_USER_ID,
		receipt_hash: options.operationReceiptHash ?? TEST_DELETION_HASH,
		status: options.operationStatus ?? "pending",
		expires_at: options.operationExpiresAt ?? "2026-08-31T12:00:00.000Z",
		delete_lease_until: null,
	};
	return {
		deleteUser,
		getUserById,
		selectCalls,
		rpcCalls,
		rpc: vi.fn(async (name: string, args: Record<string, unknown>) => {
			rpcCalls(name, args);
			switch (name) {
				case "read_account_deletion_operation":
					return { data: options.operationMissing ? [] : [op], error: null };
				case "register_account_deletion_intent":
					return {
						data: [{ result: options.registerResult ?? "created", status: "pending", expires_at: "2026-08-31T12:00:00.000Z" }],
						error: null,
					};
				case "claim_account_deletion_operation":
					return { data: [{ result: options.claimResult ?? (op.status === "deleted" ? "deleted" : "claimed"), status: "deleting", lease_until: "2026-08-24T12:00:30.000Z" }], error: null };
				case "consume_account_deletion_status_rate_limit":
					return { data: options.statusRateAllowed ?? true, error: null };
				case "release_account_deletion_operation":
					return { data: true, error: null };
				case "mark_account_deletion_operation_deleted":
					return { data: options.markDeleted ?? true, error: null };
				default:
					return { data: null, error: { message: "unexpected rpc" } };
			}
		}),
		from(table: string) {
			if (table !== "user_profiles") throw new Error(`unexpected table: ${table}`);
			return {
				select: () => {
					const result =
						selectCall++ === 0
							? { data: options.currentProfile === undefined ? { id: testAuth.userId, auth_user_id: testAuth.authUserId, avatar_storage_path: null } : options.currentProfile, error: options.profileLookupError ?? null }
							: { data: options.remainingProfile ?? null, error: options.verificationError ?? null };
					return {
						eq: (column: string, value: unknown) => {
							selectCalls(column, value);
							return { maybeSingle: async () => result };
						},
					};
				},
			};
		},
		auth: { admin: { deleteUser, getUserById } },
	};
}

function makeApp() {
	const app = new Hono();
	app.route("/api/auth", auth);
	return app;
}

beforeEach(() => {
	vi.restoreAllMocks();
	testAuth.userId = "profile-1";
	testAuth.authUserId = "auth-1";
	vi.useFakeTimers();
	vi.setSystemTime(new Date("2026-08-24T12:00:00.000Z"));
});

afterEach(() => {
	vi.useRealTimers();
});

describe("GET /api/auth/me", () => {
	it("returns verification state without DOB or verification timestamp", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase({
			me: {
				id: "profile-1",
				nickname: "User",
				gender: null,
				birth_year: 1990,
				language: "en",
				onboarding_status: "not_started",
				avatar_url: null,
				notification_seen_at: null,
				age_verified_at: "2026-08-24T00:00:00Z",
				age_verification_method: "self_declared",
			},
		}) as never);

		const res = await makeApp().request("/api/auth/me");
		const body = (await res.json()) as { data: Record<string, unknown> };
		expect(res.status).toBe(200);
		expect(body.data).toMatchObject({ age_verified: true, age_verification_method: "self_declared", birth_year: 1990 });
		expect(body.data).not.toHaveProperty("birth_date");
		expect(body.data).not.toHaveProperty("age_verified_at");
	});
});

describe("PUT /api/auth/me/age-verification", () => {
	it.each([
		["bad shape", { birth_date: "2000-1-01" }],
		["impossible date", { birth_date: "2001-02-29" }],
		["before lower bound", { birth_date: "1899-12-31" }],
		["future date", { birth_date: "2099-01-01" }],
	])("rejects %s without writing", async (_label, payload) => {
		const fake = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);
		const res = await makeApp().request("/api/auth/me/age-verification", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(payload),
		});
		expect(res.status).toBe(400);
		expect(fake.updateRow).not.toHaveBeenCalled();
	});

	it("rejects a DOB one day before the 18th birthday without changing verification state", async () => {
		const fake = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);
		const res = await makeApp().request("/api/auth/me/age-verification", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ birth_date: "2008-08-25" }),
		});
		expect(res.status).toBe(403);
		expect(fake.updateRow).not.toHaveBeenCalled();
	});

	it("accepts the DOB on the 18th birthday", async () => {
		const fake = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);
		const res = await makeApp().request("/api/auth/me/age-verification", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ birth_date: "2008-08-24" }),
		});
		expect(res.status).toBe(200);
		expect(fake.updateRow).toHaveBeenCalledTimes(1);
	});

	it("atomically writes a valid DOB and does not return it", async () => {
		const fake = makeSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);
		const res = await makeApp().request("/api/auth/me/age-verification", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ birth_date: "2000-08-24" }),
		});
		const body = (await res.json()) as { data: Record<string, unknown> };
		expect(res.status).toBe(200);
		expect(fake.updateRow).toHaveBeenCalledWith({
			birth_date: "2000-08-24",
			age_verified_at: expect.any(String),
			age_verification_method: "self_declared",
		});
		expect(fake.updateEq).toHaveBeenCalledWith("id", "profile-1");
		expect(fake.updateIs).toHaveBeenCalledWith("age_verified_at", null);
		expect(body.data).toEqual({ age_verified: true, age_verification_method: "self_declared" });
		expect(JSON.stringify(body)).not.toContain("2000-08-24");
	});

	it("returns idempotent success for the same already-verified DOB", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase({
			updateResult: { data: null, error: null },
			currentResult: {
				data: {
					birth_date: "2000-08-24",
					age_verified_at: "2026-08-24T00:00:00Z",
					age_verification_method: "self_declared",
				},
				error: null,
			},
		}) as never);
		const res = await makeApp().request("/api/auth/me/age-verification", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ birth_date: "2000-08-24" }),
		});
		expect(res.status).toBe(200);
	});

	it("returns conflict for an already-verified different DOB", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase({
			updateResult: { data: null, error: null },
			currentResult: {
				data: {
					birth_date: "1999-08-24",
					age_verified_at: "2026-08-24T00:00:00Z",
					age_verification_method: "self_declared",
				},
				error: null,
			},
		}) as never);
		const res = await makeApp().request("/api/auth/me/age-verification", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ birth_date: "2000-08-24" }),
		});
		expect(res.status).toBe(409);
	});

	it.each([
		[
			"an unverified row",
			{
				data: {
					birth_date: null,
					age_verified_at: null,
					age_verification_method: null,
				},
				error: null,
			},
		],
		["a missing row", { data: null, error: null }],
	])("returns 500 when a zero-row update is followed by %s", async (_label, currentResult) => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase({
			updateResult: { data: null, error: null },
			currentResult,
		}) as never);
		const res = await makeApp().request("/api/auth/me/age-verification", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ birth_date: "2000-08-24" }),
		});
		expect(res.status).toBe(500);
	});

	it("does not turn an update/query failure into success", async () => {
		mockedGetSupabaseClient.mockReturnValue(makeSupabase({
			updateResult: { data: null, error: { message: "db failure" } },
		}) as never);
		const res = await makeApp().request("/api/auth/me/age-verification", {
			method: "PUT",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ birth_date: "2000-08-24" }),
		});
		expect(res.status).toBe(500);
	});
});

describe("DELETE /api/auth/me", () => {
	it("returns the frozen deleted DTO only after current-owner deletion and cascade verification", async () => {
		useDeletionOwner();
		const fake = makeDeletionSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const res = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders() });
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ data: { deleted: true } });
		expect(fake.deleteUser).toHaveBeenCalledWith(DELETION_AUTH_USER_ID);
		expect(fake.selectCalls).toHaveBeenNthCalledWith(1, "id", DELETION_OWNER_ID);
		expect(fake.selectCalls).toHaveBeenNthCalledWith(2, "id", DELETION_OWNER_ID);
		expect(fake.rpcCalls).toHaveBeenCalledWith("mark_account_deletion_operation_deleted", expect.objectContaining({ p_receipt_hash: TEST_DELETION_HASH }));
	});

	it("keeps a provider 5xx unconfirmed and never reports deleted", async () => {
		useDeletionOwner();
		const fake = makeDeletionSupabase({ deleteError: { message: "private provider detail", status: 503, code: "server_error" } });
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const res = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders() });
		const body = await res.json();
		expect(res.status).toBe(503);
		expect(body).toEqual({ error: { code: "INTERNAL_ERROR", message: "Failed to delete account" } });
		expect(JSON.stringify(body)).not.toContain("private provider detail");
		expect(consoleErrorSpy).toHaveBeenCalledWith("[auth] account deletion failed");
		expect(fake.rpcCalls).not.toHaveBeenCalledWith("mark_account_deletion_operation_deleted", expect.anything());
	});

	it("does not delete an auth user when the current profile is missing", async () => {
		useDeletionOwner();
		const fake = makeDeletionSupabase({ currentProfile: null, authUser: { id: DELETION_AUTH_USER_ID } });
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const res = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders() });
		expect(res.status).toBe(404);
		expect(await res.json()).toEqual({ error: { code: "NOT_FOUND", message: "Deletion request is unavailable" } });
		expect(fake.deleteUser).not.toHaveBeenCalled();
		expect(fake.getUserById).toHaveBeenCalledWith(DELETION_AUTH_USER_ID);
	});

	it("rejects a profile whose auth owner differs from the current token", async () => {
		useDeletionOwner();
		const fake = makeDeletionSupabase({ currentProfile: { id: DELETION_OWNER_ID, auth_user_id: "00000000-0000-0000-0000-000000000099" } });
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const res = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders() });
		expect(res.status).toBe(404);
		expect(await res.json()).toEqual({ error: { code: "NOT_FOUND", message: "Deletion request is unavailable" } });
		expect(fake.deleteUser).not.toHaveBeenCalled();
		expect(fake.getUserById).not.toHaveBeenCalled();
	});

	it("does not acknowledge deletion while the profile row still exists", async () => {
		useDeletionOwner();
		const fake = makeDeletionSupabase({ remainingProfile: { id: DELETION_OWNER_ID } });
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const res = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders() });
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ data: { deleted: false } });
		expect(consoleErrorSpy).toHaveBeenCalledWith("[auth] account deletion was not durable");
		expect(fake.rpcCalls).not.toHaveBeenCalledWith("mark_account_deletion_operation_deleted", expect.anything());
	});

	it("treats a replay after both auth and profile removal as idempotent success", async () => {
		useDeletionOwner();
		const first = makeDeletionSupabase();
		const replay = makeDeletionSupabase({ currentProfile: null, authLookupError: { message: "not found", status: 404, code: "user_not_found" } });
		mockedGetSupabaseClient.mockReturnValueOnce(first as never).mockReturnValueOnce(replay as never);

		const firstResponse = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders() });
		const replayResponse = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders() });
		expect(firstResponse.status).toBe(200);
		expect(replayResponse.status).toBe(200);
		expect(await replayResponse.json()).toEqual({ data: { deleted: true } });
		expect(replay.deleteUser).not.toHaveBeenCalled();
	});

	it("deletes a later registered account using only its own auth/profile pair", async () => {
		useDeletionOwner();
		const first = makeDeletionSupabase({ operationOwnerID: DELETION_OWNER_ID, operationAuthUserID: DELETION_AUTH_USER_ID });
		const secondOperationID = "20000000-0000-4000-8000-000000000002";
		const secondReceipt = `${secondOperationID}.${"B".repeat(43)}`;
		const second = makeDeletionSupabase({
			currentProfile: { id: OTHER_DELETION_OWNER_ID, auth_user_id: OTHER_DELETION_AUTH_USER_ID },
			operationOwnerID: OTHER_DELETION_OWNER_ID,
			operationAuthUserID: OTHER_DELETION_AUTH_USER_ID,
			operationID: secondOperationID,
			operationReceiptHash: createHash("sha256").update(secondReceipt).digest("hex"),
		});
		mockedGetSupabaseClient.mockReturnValueOnce(first as never).mockReturnValueOnce(second as never);

		const firstResponse = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders() });
		useDeletionOwner(OTHER_DELETION_OWNER_ID, OTHER_DELETION_AUTH_USER_ID);
		const secondResponse = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders(secondReceipt) });
		expect(firstResponse.status).toBe(200);
		expect(secondResponse.status).toBe(200);
		expect(first.deleteUser).toHaveBeenCalledWith(DELETION_AUTH_USER_ID);
		expect(second.deleteUser).toHaveBeenCalledWith(OTHER_DELETION_AUTH_USER_ID);
	});

	it("keeps the legacy account path and response while using the same safe contract", async () => {
		useDeletionOwner();
		const fake = makeDeletionSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const res = await makeApp().request("/api/auth/account", { method: "DELETE", headers: deletionHeaders() });
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ data: { message: "Account deleted" } });
	});

	it("requires photo cleanup before deleting Auth and leaves the account retryable when the adapter is unavailable", async () => {
		useDeletionOwner();
		const fake = makeDeletionSupabase({ currentProfile: { id: DELETION_OWNER_ID, auth_user_id: DELETION_AUTH_USER_ID, avatar_storage_path: "photos/synthetic.webp" } });
		const consoleErrorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		mockedGetSupabaseClient.mockReturnValue(fake as never);

		const res = await makeApp().request("/api/auth/me", { method: "DELETE", headers: deletionHeaders() });
		expect(res.status).toBe(503);
		expect(await res.json()).toEqual({ error: { code: "INTERNAL_ERROR", message: "Failed to delete account data" } });
		expect(fake.deleteUser).not.toHaveBeenCalled();
		expect(fake.rpcCalls).toHaveBeenCalledWith("release_account_deletion_operation", expect.anything());
		expect(consoleErrorSpy).toHaveBeenCalledWith("[auth] account photo cleanup failed");
	});
});

describe("account deletion receipt endpoints", () => {
	it("registers one owner-bound intent and stores only the receipt digest", async () => {
		useDeletionOwner();
		const fake = makeDeletionSupabase();
		mockedGetSupabaseClient.mockReturnValue(fake as never);
		const res = await makeApp().request("/api/auth/me/deletion-intent", { method: "POST", headers: deletionHeaders() });
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ data: { status: "pending", expires_at: "2026-08-31T12:00:00.000Z" } });
		expect(fake.rpcCalls).toHaveBeenCalledWith("register_account_deletion_intent", expect.objectContaining({
			p_operation_id: DELETION_OPERATION_ID,
			p_owner_profile_id: DELETION_OWNER_ID,
			p_auth_user_id: DELETION_AUTH_USER_ID,
			p_receipt_hash: TEST_DELETION_HASH,
		}));
		expect(JSON.stringify(fake.rpcCalls.mock.calls)).not.toContain(TEST_DELETION_RECEIPT);
	});

	it("returns only pending/deleted state and applies no-store headers", async () => {
		const fake = makeDeletionSupabase({ operationStatus: "deleted" });
		mockedGetSupabaseClient.mockReturnValue(fake as never);
		const res = await makeApp().request("/api/auth/deletion-status", { headers: deletionHeaders() });
		expect(res.status).toBe(200);
		const body = await res.json();
		expect(body).toEqual({ data: { status: "deleted" } });
		expect(res.headers.get("Cache-Control")).toBe("no-store");
		expect(res.headers.get("Pragma")).toBe("no-cache");
		expect(JSON.stringify(body)).not.toContain(DELETION_OWNER_ID);
	});

	it("generalizes missing, mismatched, and expired receipts and does not spend status quota on mismatches", async () => {
		const mismatched = makeDeletionSupabase({ operationReceiptHash: "b".repeat(64) });
		mockedGetSupabaseClient.mockReturnValueOnce(mismatched as never);
		const mismatchResponse = await makeApp().request("/api/auth/deletion-status", { headers: deletionHeaders() });
		const absentResponse = await makeApp().request("/api/auth/deletion-status");
		expect(mismatchResponse.status).toBe(404);
		expect(await mismatchResponse.json()).toEqual(await absentResponse.json());
		expect(mismatched.rpcCalls).not.toHaveBeenCalledWith("consume_account_deletion_status_rate_limit", expect.anything());

		const expired = makeDeletionSupabase({ operationExpiresAt: "2026-08-23T12:00:00.000Z" });
		mockedGetSupabaseClient.mockReturnValueOnce(expired as never);
		const expiredResponse = await makeApp().request("/api/auth/deletion-status", { headers: deletionHeaders() });
		expect(expiredResponse.status).toBe(404);
		expect(expired.rpcCalls).not.toHaveBeenCalledWith("consume_account_deletion_status_rate_limit", expect.anything());
	});

	it("fails closed on provider lookup errors instead of inventing pending or deleted", async () => {
		const fake = makeDeletionSupabase({ operationStatus: "deleting", authLookupError: { message: "provider unavailable", status: 503, code: "server_error" } });
		mockedGetSupabaseClient.mockReturnValue(fake as never);
		const res = await makeApp().request("/api/auth/deletion-status", { headers: deletionHeaders() });
		expect(res.status).toBe(503);
		expect(await res.json()).toEqual({ error: { code: "INTERNAL_ERROR", message: "Deletion status is unavailable" } });
	});

	it("recovers a lost delete response only after Auth and profile removal are both confirmed", async () => {
		const fake = makeDeletionSupabase({
			operationStatus: "deleting",
			currentProfile: null,
			authLookupError: { message: "not found", status: 404, code: "user_not_found" },
		});
		mockedGetSupabaseClient.mockReturnValue(fake as never);
		const res = await makeApp().request("/api/auth/deletion-status", { headers: deletionHeaders() });
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ data: { status: "deleted" } });
		expect(fake.rpcCalls).toHaveBeenCalledWith("mark_account_deletion_operation_deleted", expect.anything());
	});

	it("rate-limits valid receipt checks atomically after digest matching", async () => {
		const fake = makeDeletionSupabase({ statusRateAllowed: false });
		mockedGetSupabaseClient.mockReturnValue(fake as never);
		const res = await makeApp().request("/api/auth/deletion-status", { headers: deletionHeaders() });
		expect(res.status).toBe(429);
		expect(fake.rpcCalls).toHaveBeenCalledWith("consume_account_deletion_status_rate_limit", expect.objectContaining({ p_receipt_hash: TEST_DELETION_HASH }));
	});
});

describe("removed auth callback", () => {
	it("returns 404 for the old unsigned callback endpoint", async () => {
		const res = await makeApp().request("/api/auth/callback", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: "{}",
		});
		expect(res.status).toBe(404);
	});
});
