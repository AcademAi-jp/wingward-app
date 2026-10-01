import { Hono } from "hono";
import type { Context } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { jsonData, jsonError } from "../lib/response";
import { isAtLeast18, getUtcToday, parseBirthDate } from "../lib/age-verification";
import {
	cleanupStoredOwnerPhoto,
	createSupabaseProfilePhotoProfileStore,
	renewOwnerProfilePhotoReadUrl,
} from "../lib/profile-photo";
import { requireAuth } from "../middleware/auth";
import { z } from "zod";
import {
	ONBOARDING_SETTINGS_COLUMNS,
	getOnboardingOptions,
	getProfilePhotoAdapter,
	isSupportedPhotoInput,
	onboardingSettingsSchema,
	readBoundedRequestBody,
	readCompletedOnboardingSettings,
	saveProfilePhoto,
	MAX_PROFILE_PHOTO_BYTES,
} from "../services/onboarding-settings";

const auth = new Hono<Env>();

const onboardingOptionsQuerySchema = z
	.object({ dating_market: z.enum(["JP", "US"]), ui_locale: z.enum(["ja", "en"]) })
	.strict();
const onboardingSettingsErrorMessage = "Invalid onboarding settings";

function hasOnlyOnboardingOptionQueryKeys(c: { req: { url: string } }): boolean {
	const allowed = new Set(["dating_market", "ui_locale"]);
	for (const key of new URL(c.req.url).searchParams.keys()) {
		if (!allowed.has(key)) return false;
	}
	return true;
}

function rowAsRecord(row: unknown): Record<string, unknown> {
	return row && typeof row === "object" ? (row as Record<string, unknown>) : {};
}

/** GET /api/auth/me - current user profile including onboarding_status */
auth.get("/me", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const { data, error } = await supabase
		.from("user_profiles")
		.select(
			"id, nickname, gender, birth_year, language, onboarding_status, avatar_url, avatar_storage_path, notification_seen_at, age_verified_at, age_verification_method",
		)
		.eq("id", userId)
		.single();
	if (error || !data) {
		return jsonError(c, "NOT_FOUND", "User profile not found");
	}
	let avatarUrl = data.avatar_url;
	if (data.avatar_storage_path) {
		const adapter = getProfilePhotoAdapter(c.env);
		if (!adapter) {
			// A canonical path without an active provider must not expose a
			// previously issued URL whose expiry and authorization are unknown.
			avatarUrl = null;
		} else {
			try {
				avatarUrl = await renewOwnerProfilePhotoReadUrl(adapter, userId, data.avatar_storage_path);
			} catch {
				console.error("[auth/photo] profile photo read URL renewal failed");
				avatarUrl = null;
			}
		}
	}
	const { age_verified_at, age_verification_method, avatar_storage_path: _avatarStoragePath, avatar_url: _storedAvatarUrl, ...profile } = data;
	return jsonData(c, {
		...profile,
		avatar_url: avatarUrl,
		age_verified: Boolean(age_verified_at),
		age_verification_method,
	});
});

/**
 * GET /api/auth/me/onboarding-settings
 *
 * The completion marker is server-owned and deliberately not part of the
 * response.  Legacy rows therefore look like `{ data: null }` until the
 * owner completes one successful full settings save.
 */
auth.get("/me/onboarding-settings", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const { data: row, error } = await supabase
		.from("user_profiles")
		.select(ONBOARDING_SETTINGS_COLUMNS)
		.eq("id", userId)
		.maybeSingle();
	if (error) {
		console.error("[auth/onboarding-settings] settings lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to load onboarding settings");
	}
	if (!row) return jsonError(c, "NOT_FOUND", "Onboarding settings unavailable");
	const rowRecord = rowAsRecord(row);
	if (rowRecord.onboarding_settings_completed_at === null || rowRecord.onboarding_settings_completed_at === undefined) {
		return jsonData(c, null);
	}
	const settings = readCompletedOnboardingSettings(rowRecord);
	if (!settings) {
		console.error("[auth/onboarding-settings] stored settings are invalid");
		return jsonError(c, "INTERNAL_ERROR", "Onboarding settings are unavailable");
	}
	return jsonData(c, settings);
});

/** GET /api/auth/me/onboarding-options - owner-facing offline fixture catalog */
auth.get("/me/onboarding-options", requireAuth, async (c) => {
	if (!hasOnlyOnboardingOptionQueryKeys(c)) {
		return jsonError(c, "BAD_REQUEST", "Invalid onboarding options");
	}
	const parsed = onboardingOptionsQuerySchema.safeParse({
		dating_market: c.req.query("dating_market"),
		ui_locale: c.req.query("ui_locale"),
	});
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", "Invalid onboarding options");
	return jsonData(c, getOnboardingOptions(parsed.data.dating_market, parsed.data.ui_locale));
});

/**
 * PUT /api/auth/me/onboarding-settings
 *
 * This is intentionally a closed full-object update.  It synchronizes the
 * legacy language/region aliases only after all validation succeeds and marks
 * completion in the same service-role update.
 */
auth.put("/me/onboarding-settings", requireAuth, async (c) => {
	const body = await c.req.json().catch(() => null);
	const parsed = onboardingSettingsSchema.safeParse(body);
	if (!parsed.success) return jsonError(c, "BAD_REQUEST", onboardingSettingsErrorMessage);

	const userId = c.get("user_id");
	const now = new Date().toISOString();
	const supabase = getSupabaseClient(c.env);
	const { data: row, error } = await supabase
		.from("user_profiles")
		.update({
			...parsed.data,
			// Keep legacy aliases synchronized only for this explicit settings save.
			language: parsed.data.ui_locale,
			region: parsed.data.dating_market,
			onboarding_settings_completed_at: now,
			updated_at: now,
		})
		.eq("id", userId)
		.select(ONBOARDING_SETTINGS_COLUMNS)
		.single();
	if (error || !row) {
		console.error("[auth/onboarding-settings] settings update failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to save onboarding settings");
	}
	const settings = readCompletedOnboardingSettings(rowAsRecord(row));
	if (!settings) {
		console.error("[auth/onboarding-settings] saved settings are invalid");
		return jsonError(c, "INTERNAL_ERROR", "Failed to save onboarding settings");
	}
	return jsonData(c, settings);
});

/**
 * POST /api/auth/me/photo
 *
 * The default adapter is disabled until a reviewed decoder/re-encoder and a
 * private storage provider are injected.  Input MIME, size, and magic bytes
 * are checked before that adapter is called, so no raw original can reach a
 * future persistence boundary.
 */
auth.post("/me/photo", requireAuth, async (c) => {
	const declaredContentType = (c.req.header("content-type") ?? "").split(";", 1)[0]?.trim().toLowerCase() ?? "";
	const contentLength = c.req.header("content-length");
	if (contentLength !== undefined) {
		const parsedLength = Number(contentLength);
		if (!Number.isSafeInteger(parsedLength) || parsedLength < 1 || parsedLength > MAX_PROFILE_PHOTO_BYTES) {
			return jsonError(c, "BAD_REQUEST", "Invalid profile photo");
		}
	}

	const bytes = await readBoundedRequestBody(c.req.raw, MAX_PROFILE_PHOTO_BYTES);
	if (!bytes) return jsonError(c, "BAD_REQUEST", "Invalid profile photo");
	if (!isSupportedPhotoInput(bytes, declaredContentType)) {
		return jsonError(c, "BAD_REQUEST", "Invalid profile photo");
	}

	const adapter = getProfilePhotoAdapter(c.env);
	if (!adapter) return jsonError(c, "INTERNAL_ERROR", "Profile photo upload is unavailable", 503);

	let savedObjectKey: string | null = null;
	try {
		const supabase = getSupabaseClient(c.env);
		const profileStore = createSupabaseProfilePhotoProfileStore(supabase);
		const current = await profileStore.readOwnerPhotoState(c.get("user_id"));
		if (!current) return jsonError(c, "NOT_FOUND", "User profile not found");
		const result = await saveProfilePhoto(
			c.get("user_id"),
			bytes,
			declaredContentType,
			adapter,
		);
		if (result.kind === "unavailable") {
			return jsonError(c, "INTERNAL_ERROR", "Profile photo upload is unavailable", 503);
		}
		if (result.kind !== "saved") return jsonError(c, "BAD_REQUEST", "Invalid profile photo");
		savedObjectKey = result.objectKey;
		const committed = await profileStore.compareAndSetOwnerPhoto(
			c.get("user_id"),
			current.avatar_storage_path,
			result.objectKey,
			result.readUrl,
		);
		if (!committed) {
			await cleanupStoredOwnerPhoto(adapter, c.get("user_id"), result.objectKey);
			return jsonError(c, "CONFLICT", "Profile photo changed; retry");
		}
		if (current.avatar_storage_path && current.avatar_storage_path !== result.objectKey) {
			const cleaned = await cleanupStoredOwnerPhoto(adapter, c.get("user_id"), current.avatar_storage_path);
			if (!cleaned) console.error("[auth/photo] previous profile photo cleanup failed");
		}
		return jsonData(c, { avatar_url: result.readUrl });
	} catch {
		if (savedObjectKey) await cleanupStoredOwnerPhoto(adapter, c.get("user_id"), savedObjectKey);
		console.error("[auth/photo] profile photo operation failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to save profile photo");
	}
});

const ageVerificationSchema = z.object({ birth_date: z.string() }).strict();

/** PUT /api/auth/me/age-verification - verify an authenticated user's age */
auth.put("/me/age-verification", requireAuth, async (c) => {
	const body = await c.req.json().catch(() => null);
	const parsed = ageVerificationSchema.safeParse(body);
	if (!parsed.success) {
		return jsonError(c, "BAD_REQUEST", "birth_date must be a YYYY-MM-DD date");
	}

	const today = getUtcToday();
	const birthDate = parseBirthDate(parsed.data.birth_date, today);
	if (!birthDate) {
		return jsonError(c, "BAD_REQUEST", "birth_date must be a valid date from 1900-01-01 through today");
	}
	if (!isAtLeast18(birthDate, today)) {
		return jsonError(c, "FORBIDDEN", "Age verification requires the user to be at least 18");
	}

	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const now = new Date().toISOString();
	const { data: updated, error: updateError } = await supabase
		.from("user_profiles")
		.update({
			birth_date: birthDate,
			age_verified_at: now,
			age_verification_method: "self_declared",
		})
		.eq("id", userId)
		.is("age_verified_at", null)
		.select("birth_date, age_verified_at, age_verification_method")
		.maybeSingle();

	if (updateError) {
		console.error("[auth] age verification update failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify age");
	}
	if (updated) {
		return jsonData(c, {
			age_verified: true,
			age_verification_method: updated.age_verification_method,
		});
	}

	// The conditional update lost a race or the profile is missing. Re-read
	// only to distinguish the idempotent and conflict outcomes; never echo DOB.
	const { data: current, error: currentError } = await supabase
		.from("user_profiles")
		.select("birth_date, age_verified_at, age_verification_method")
		.eq("id", userId)
		.maybeSingle();
	if (currentError || !current) {
		console.error("[auth] age verification state lookup failed");
		return jsonError(c, "INTERNAL_ERROR", "Failed to verify age");
	}
	if (current.age_verified_at) {
		if (current.birth_date === birthDate) {
			return jsonData(c, {
				age_verified: true,
				age_verification_method: current.age_verification_method,
			});
		}
		return jsonError(c, "CONFLICT", "Age verification already completed");
	}

	return jsonError(c, "INTERNAL_ERROR", "Failed to verify age");
});

const updateMeSchema = z.object({
	nickname: z.string().min(1).max(100).optional(),
	gender: z.enum(["male", "female", "other", "undisclosed"]).optional(),
	birth_year: z.number().int().min(1900).max(2100).nullable().optional(),
	language: z.enum(["ja", "en"]).optional(),
});

/** PUT /api/auth/me - update current user profile (nickname, gender, birth_year, language) */
auth.put("/me", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const parsed = updateMeSchema.safeParse(await c.req.json());
	if (!parsed.success) {
		return jsonError(c, "BAD_REQUEST", parsed.error.message);
	}
	const supabase = getSupabaseClient(c.env);
	const updates: Record<string, unknown> = { updated_at: new Date().toISOString() };
	if (parsed.data.nickname !== undefined) updates.nickname = parsed.data.nickname;
	if (parsed.data.gender !== undefined) updates.gender = parsed.data.gender;
	if (parsed.data.birth_year !== undefined) updates.birth_year = parsed.data.birth_year;
	if (parsed.data.language !== undefined) {
		updates.language = parsed.data.language;
		// The legacy language alias updates the UI locale only.  In particular,
		// it must not overwrite the independently saved conversation language.
		updates.ui_locale = parsed.data.language;
	}
	const { data, error } = await supabase
		.from("user_profiles")
		.update(updates)
		.eq("id", userId)
		.select(
			"id, nickname, gender, birth_year, language, onboarding_status, avatar_url, notification_seen_at",
		)
		.single();
	if (error) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to update profile");
	}
	return jsonData(c, data);
});

/** POST /api/auth/me/notification-seen - mark notification dropdown as seen (updates notification_seen_at) */
auth.post("/me/notification-seen", requireAuth, async (c) => {
	const userId = c.get("user_id");
	const supabase = getSupabaseClient(c.env);
	const now = new Date().toISOString();
	const { data, error } = await supabase
		.from("user_profiles")
		.update({ notification_seen_at: now })
		.eq("id", userId)
		.select("id, notification_seen_at")
		.single();
	if (error) {
		return jsonError(c, "INTERNAL_ERROR", "Failed to update notification seen");
	}
	return jsonData(c, { notification_seen_at: data?.notification_seen_at ?? now });
});

const deletionReceiptHeader = "X-Account-Deletion-Receipt";
const deletionReceiptSchema = z.string().regex(
	/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[A-Za-z0-9_-]{43}$/,
);
const deletionOperationRowSchema = z.object({
	operation_id: z.string().uuid(),
	owner_profile_id: z.string().uuid(),
	auth_user_id: z.string().uuid(),
	receipt_hash: z.string().regex(/^[0-9a-f]{64}$/),
	status: z.enum(["pending", "deleting", "deleted"]),
	expires_at: z.string().refine((value) => Number.isFinite(Date.parse(value))),
	delete_lease_until: z.string().nullable(),
}).strict();
const deletionRPCRowSchema = z.object({
	result: z.string(),
	status: z.string().nullable().optional(),
	expires_at: z.string().nullable().optional(),
	lease_until: z.string().nullable().optional(),
}).passthrough();

type DeletionOperation = z.infer<typeof deletionOperationRowSchema>;
type AuthUserState = { kind: "exists" } | { kind: "missing" } | { kind: "unavailable" };
type ReceiptLookup = { kind: "ok"; operation: DeletionOperation } | { kind: "missing" } | { kind: "unavailable" };

function isMissingAuthUserError(error: unknown): boolean {
	if (!error || typeof error !== "object") return false;
	return (error as { code?: unknown }).code === "user_not_found";
}

function readDeletionReceipt(c: Context<Env>): { value: string; operationId: string } | null {
	const parsed = deletionReceiptSchema.safeParse(c.req.header(deletionReceiptHeader));
	if (!parsed.success) return null;
	const [operationId] = parsed.data.split(".");
	return { value: parsed.data, operationId };
}

async function sha256Hex(value: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
	return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Compare the fixed-width digest without returning early on the first mismatch. */
function constantTimeHashMatch(candidate: string, stored: string): boolean {
	if (!/^[0-9a-f]{64}$/.test(candidate) || !/^[0-9a-f]{64}$/.test(stored)) return false;
	let difference = 0;
	for (let index = 0; index < 64; index += 1) {
		difference |= candidate.charCodeAt(index) ^ stored.charCodeAt(index);
	}
	return difference === 0;
}

async function readDeletionOperation(supabase: ReturnType<typeof getSupabaseClient>, operationId: string): Promise<ReceiptLookup> {
	try {
		const { data, error } = await supabase.rpc("read_account_deletion_operation", { p_operation_id: operationId });
		if (error || !Array.isArray(data) || data.length > 1) return { kind: "unavailable" };
		if (data.length === 0) return { kind: "missing" };
		const parsed = deletionOperationRowSchema.safeParse(data[0]);
		return parsed.success ? { kind: "ok", operation: parsed.data } : { kind: "unavailable" };
	} catch {
		return { kind: "unavailable" };
	}
}

async function matchDeletionReceipt(
	supabase: ReturnType<typeof getSupabaseClient>,
	operationId: string,
	receipt: string,
): Promise<ReceiptLookup> {
	const result = await readDeletionOperation(supabase, operationId);
	if (result.kind !== "ok") return result;
	const candidateHash = await sha256Hex(receipt);
	if (!constantTimeHashMatch(candidateHash, result.operation.receipt_hash)) return { kind: "missing" };
	return result;
}

function accountDeletionUnavailable(c: Context<Env>, message = "Account deletion is temporarily unavailable"): Response {
	return jsonError(c, "INTERNAL_ERROR", message, 503);
}

function accountDeletionNotFound(c: Context<Env>): Response {
	// Every unknown, mismatched, expired, or owner-mismatched receipt has the same response.
	return jsonError(c, "NOT_FOUND", "Deletion request is unavailable", 404);
}

async function readAuthUserState(supabase: ReturnType<typeof getSupabaseClient>, authUserId: string): Promise<AuthUserState> {
	try {
		const { data, error } = await supabase.auth.admin.getUserById(authUserId);
		if (error) return isMissingAuthUserError(error) ? { kind: "missing" } : { kind: "unavailable" };
		if (!data.user) return { kind: "missing" };
		return data.user.id === authUserId ? { kind: "exists" } : { kind: "unavailable" };
	} catch {
		return { kind: "unavailable" };
	}
}

async function readOwnerDeletionProfile(
	supabase: ReturnType<typeof getSupabaseClient>,
	ownerProfileId: string,
): Promise<{ kind: "ok"; profile: { id: string; auth_user_id: string; avatar_storage_path: string | null } | null } | { kind: "unavailable" }> {
	try {
		const { data, error } = await supabase
			.from("user_profiles")
			.select("id, auth_user_id, avatar_storage_path")
			.eq("id", ownerProfileId)
			.maybeSingle();
		if (error) return { kind: "unavailable" };
		return { kind: "ok", profile: data };
	} catch {
		return { kind: "unavailable" };
	}
}

async function callDeletionRPC(
	supabase: ReturnType<typeof getSupabaseClient>,
	name:
		| "register_account_deletion_intent"
		| "claim_account_deletion_operation"
		| "release_account_deletion_operation"
		| "mark_account_deletion_operation_deleted"
		| "consume_account_deletion_status_rate_limit",
	args: Record<string, unknown>,
): Promise<{ data: unknown; error: unknown }> {
	try {
		return await supabase.rpc(name, args as never);
	} catch (error) {
		return { data: null, error };
	}
}

async function releaseDeletionClaim(
	supabase: ReturnType<typeof getSupabaseClient>,
	operationId: string,
	receiptHash: string,
	claimToken: string,
): Promise<void> {
	await callDeletionRPC(supabase, "release_account_deletion_operation", {
		p_operation_id: operationId,
		p_receipt_hash: receiptHash,
		p_claim_token: claimToken,
	});
}

async function markDeletionComplete(
	supabase: ReturnType<typeof getSupabaseClient>,
	operation: DeletionOperation,
): Promise<boolean> {
	const result = await callDeletionRPC(supabase, "mark_account_deletion_operation_deleted", {
		p_operation_id: operation.operation_id,
		p_owner_profile_id: operation.owner_profile_id,
		p_auth_user_id: operation.auth_user_id,
		p_receipt_hash: operation.receipt_hash,
	});
	return !result.error && result.data === true;
}

async function reconcileDeletingOperation(
	supabase: ReturnType<typeof getSupabaseClient>,
	operation: DeletionOperation,
): Promise<"pending" | "deleted" | "unavailable"> {
	const authState = await readAuthUserState(supabase, operation.auth_user_id);
	if (authState.kind === "unavailable") return "unavailable";
	const profileState = await readOwnerDeletionProfile(supabase, operation.owner_profile_id);
	if (profileState.kind === "unavailable") return "unavailable";
	if (authState.kind !== "missing" || profileState.profile) return "pending";
	return (await markDeletionComplete(supabase, operation)) ? "deleted" : "unavailable";
}

/**
 * Register a deletion receipt before the irreversible Auth call. The receipt
 * is created and persisted by the client; this endpoint stores only its hash.
 */
auth.post("/me/deletion-intent", requireAuth, async (c) => {
	const receipt = readDeletionReceipt(c);
	if (!receipt) return jsonError(c, "BAD_REQUEST", "Invalid deletion receipt");
	const ownerProfileId = c.get("user_id");
	const authUserId = c.get("auth_user_id");
	if (!ownerProfileId || !authUserId) return jsonError(c, "UNAUTHORIZED", "Current account is unavailable");

	const supabase = getSupabaseClient(c.env);
	const profileState = await readOwnerDeletionProfile(supabase, ownerProfileId);
	if (profileState.kind === "unavailable") return accountDeletionUnavailable(c, "Failed to verify current account");
	if (!profileState.profile || profileState.profile.id !== ownerProfileId || profileState.profile.auth_user_id !== authUserId) {
		return accountDeletionNotFound(c);
	}
	const authState = await readAuthUserState(supabase, authUserId);
	if (authState.kind === "unavailable") return accountDeletionUnavailable(c, "Failed to verify current account");
	if (authState.kind !== "exists") return accountDeletionNotFound(c);

	const receiptHash = await sha256Hex(receipt.value);
	const result = await callDeletionRPC(supabase, "register_account_deletion_intent", {
		p_operation_id: receipt.operationId,
		p_owner_profile_id: ownerProfileId,
		p_auth_user_id: authUserId,
		p_receipt_hash: receiptHash,
	});
	if (result.error || !Array.isArray(result.data) || result.data.length !== 1) {
		return accountDeletionUnavailable(c, "Failed to register account deletion");
	}
	const parsed = deletionRPCRowSchema.safeParse(result.data[0]);
	if (!parsed.success) return accountDeletionUnavailable(c, "Failed to register account deletion");
	switch (parsed.data.result) {
		case "created":
		case "existing":
			if (!parsed.data.status || !parsed.data.expires_at) return accountDeletionUnavailable(c, "Failed to register account deletion");
			return jsonData(c, { status: parsed.data.status, expires_at: parsed.data.expires_at });
		case "conflict":
			return jsonError(c, "CONFLICT", "A deletion request is already active", 409);
		case "rate_limited":
			return jsonError(c, "RATE_LIMITED", "Too many deletion requests", 429);
		case "owner_missing":
			return accountDeletionNotFound(c);
		default:
			return jsonError(c, "BAD_REQUEST", "Invalid deletion receipt");
	}
});

/** Status is a bearer-receipt lookup and never returns owner or Auth IDs. */
auth.get("/deletion-status", async (c) => {
	c.header("Cache-Control", "no-store");
	c.header("Pragma", "no-cache");
	c.header("Referrer-Policy", "no-referrer");
	const receipt = readDeletionReceipt(c);
	if (!receipt) return accountDeletionNotFound(c);
	const supabase = getSupabaseClient(c.env);
	const match = await matchDeletionReceipt(supabase, receipt.operationId, receipt.value);
	if (match.kind === "unavailable") return accountDeletionUnavailable(c, "Deletion status is unavailable");
	if (match.kind !== "ok") return accountDeletionNotFound(c);
	if (Date.parse(match.operation.expires_at) <= Date.now()) return accountDeletionNotFound(c);

	// Hash comparison is constant-time and happens before this atomic limiter.
	const rateResult = await callDeletionRPC(supabase, "consume_account_deletion_status_rate_limit", {
		p_operation_id: match.operation.operation_id,
		p_receipt_hash: match.operation.receipt_hash,
	});
	if (rateResult.error || typeof rateResult.data !== "boolean") {
		return accountDeletionUnavailable(c, "Deletion status is unavailable");
	}
	if (!rateResult.data) return jsonError(c, "RATE_LIMITED", "Please wait before checking deletion status", 429);
	if (match.operation.status === "deleted") return jsonData(c, { status: "deleted" });
	if (match.operation.status === "pending") return jsonData(c, { status: "pending" });

	const recovered = await reconcileDeletingOperation(supabase, match.operation);
	if (recovered === "unavailable") return accountDeletionUnavailable(c, "Deletion status is unavailable");
	return jsonData(c, { status: recovered });
});

type AccountDeletionResult = { deleted: boolean } | { response: Response };

/**
 * Delete only the current owner after an active, owner-bound receipt has been
 * claimed. Storage cleanup is required before the irreversible Auth removal.
 */
async function deleteCurrentAccount(c: Context<Env>): Promise<AccountDeletionResult> {
	const receipt = readDeletionReceipt(c);
	if (!receipt) return { response: jsonError(c, "BAD_REQUEST", "Invalid deletion receipt") };
	const authUserId = c.get("auth_user_id");
	const ownerProfileId = c.get("user_id");
	if (!authUserId || !ownerProfileId) {
		return { response: jsonError(c, "UNAUTHORIZED", "Current account is unavailable") };
	}

	const supabase = getSupabaseClient(c.env);
	const match = await matchDeletionReceipt(supabase, receipt.operationId, receipt.value);
	if (match.kind === "unavailable") return { response: accountDeletionUnavailable(c) };
	if (match.kind !== "ok" || Date.parse(match.operation.expires_at) <= Date.now()) {
		return { response: accountDeletionNotFound(c) };
	}
	const operation = match.operation;
	if (operation.owner_profile_id !== ownerProfileId || operation.auth_user_id !== authUserId) {
		return { response: accountDeletionNotFound(c) };
	}
	if (operation.status === "deleted") return { deleted: true };

	const claimToken = crypto.randomUUID();
	const claimResult = await callDeletionRPC(supabase, "claim_account_deletion_operation", {
		p_operation_id: operation.operation_id,
		p_owner_profile_id: ownerProfileId,
		p_auth_user_id: authUserId,
		p_receipt_hash: operation.receipt_hash,
		p_claim_token: claimToken,
	});
	if (claimResult.error || !Array.isArray(claimResult.data) || claimResult.data.length !== 1) {
		return { response: accountDeletionUnavailable(c) };
	}
	const claim = deletionRPCRowSchema.safeParse(claimResult.data[0]);
	if (!claim.success) return { response: accountDeletionUnavailable(c) };
	switch (claim.data.result) {
		case "deleted": return { deleted: true };
		case "in_progress": return { deleted: false };
		case "rate_limited": return { response: jsonError(c, "RATE_LIMITED", "Please wait before retrying deletion", 429) };
		case "not_found":
		case "expired": return { response: accountDeletionNotFound(c) };
		case "claimed": break;
		default: return { response: accountDeletionUnavailable(c) };
	}

	const profileState = await readOwnerDeletionProfile(supabase, ownerProfileId);
	if (profileState.kind === "unavailable") {
		await releaseDeletionClaim(supabase, operation.operation_id, operation.receipt_hash, claimToken);
		return { response: accountDeletionUnavailable(c, "Failed to verify current account") };
	}
	const currentProfile = profileState.profile;
	if (!currentProfile) {
		const authState = await readAuthUserState(supabase, authUserId);
		if (authState.kind === "unavailable") return { response: accountDeletionUnavailable(c, "Failed to verify current account") };
		if (authState.kind === "missing" && await markDeletionComplete(supabase, operation)) return { deleted: true };
		return { response: accountDeletionNotFound(c) };
	}
	if (currentProfile.id !== ownerProfileId || currentProfile.auth_user_id !== authUserId) {
		await releaseDeletionClaim(supabase, operation.operation_id, operation.receipt_hash, claimToken);
		return { response: accountDeletionNotFound(c) };
	}

	const authState = await readAuthUserState(supabase, authUserId);
	if (authState.kind === "unavailable") {
		await releaseDeletionClaim(supabase, operation.operation_id, operation.receipt_hash, claimToken);
		return { response: accountDeletionUnavailable(c, "Failed to verify current account") };
	}
	if (authState.kind === "missing") {
		await releaseDeletionClaim(supabase, operation.operation_id, operation.receipt_hash, claimToken);
		return { response: accountDeletionUnavailable(c, "Current account could not be verified") };
	}

	if (currentProfile.avatar_storage_path) {
		const photoAdapter = getProfilePhotoAdapter(c.env);
		if (!photoAdapter) {
			await releaseDeletionClaim(supabase, operation.operation_id, operation.receipt_hash, claimToken);
			console.error("[auth] account photo cleanup failed");
			return { response: jsonError(c, "INTERNAL_ERROR", "Failed to delete account data", 503) };
		}
		let cleaned = false;
		try {
			cleaned = await cleanupStoredOwnerPhoto(photoAdapter, ownerProfileId, currentProfile.avatar_storage_path);
		} catch {
			cleaned = false;
		}
		if (!cleaned) {
			await releaseDeletionClaim(supabase, operation.operation_id, operation.receipt_hash, claimToken);
			console.error("[auth] account photo cleanup failed");
			return { response: jsonError(c, "INTERNAL_ERROR", "Failed to delete account data", 503) };
		}
	}

	try {
		const { error: deleteError } = await supabase.auth.admin.deleteUser(authUserId);
		if (deleteError && !isMissingAuthUserError(deleteError)) {
			// A provider 5xx can follow a committed delete. Keep the deleting state
			// so the public receipt status can verify Auth and the profile cascade.
			console.error("[auth] account deletion failed");
			return { response: accountDeletionUnavailable(c, "Failed to delete account") };
		}

		const verifiedAuth = await readAuthUserState(supabase, authUserId);
		if (verifiedAuth.kind === "unavailable") {
			console.error("[auth] account deletion verification failed");
			return { response: accountDeletionUnavailable(c, "Failed to verify account deletion") };
		}
		if (verifiedAuth.kind !== "missing") {
			console.error("[auth] account deletion was not durable");
			return { deleted: false };
		}

		const remainingProfileState = await readOwnerDeletionProfile(supabase, ownerProfileId);
		if (remainingProfileState.kind === "unavailable") {
			console.error("[auth] account deletion verification failed");
			return { response: accountDeletionUnavailable(c, "Failed to verify account deletion") };
		}
		if (remainingProfileState.profile) {
			console.error("[auth] account deletion was not durable");
			return { deleted: false };
		}

		if (!await markDeletionComplete(supabase, operation)) {
			console.error("[auth] account deletion receipt update failed");
			return { response: accountDeletionUnavailable(c, "Failed to verify account deletion") };
		}
		return { deleted: true };
	} catch {
		console.error("[auth] account deletion failed");
		return { response: accountDeletionUnavailable(c, "Failed to delete account") };
	}
}

/** DELETE /api/auth/me - delete only after receipt-bound durable verification. */
auth.delete("/me", requireAuth, async (c) => {
	const result = await deleteCurrentAccount(c);
	if ("response" in result) return result.response;
	return jsonData(c, { deleted: result.deleted });
});

/** Legacy alias retained with the same receipt and proof requirements. */
auth.delete("/account", requireAuth, async (c) => {
	const result = await deleteCurrentAccount(c);
	if ("response" in result) return result.response;
	return result.deleted
		? jsonData(c, { message: "Account deleted" })
		: jsonError(c, "CONFLICT", "Account deletion is still in progress", 409);
});

export default auth;
