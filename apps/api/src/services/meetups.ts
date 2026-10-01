import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { Database } from "../db/types";
import { assertValidTimeZone } from "../lib/date";
import { checkVerifiedPair } from "./match-age-access";
import { MATCHING_ELIGIBILITY_COLUMNS, areMutuallyEligible } from "./matching-eligibility";
import { createMeetupProposalGenerator } from "./meetup-proposal-generator";

/**
 * The generated database types intentionally lag this feature until the
 * integration branch regenerates them. Keep the API surface narrow here and
 * cast the already service-role client once at the boundary.
 */
type QueryResult = { data: unknown; error: unknown };

interface MeetupQuery {
	select(columns?: string): MeetupQuery;
	eq(column: string, value: unknown): MeetupQuery;
	or(filters: string): MeetupQuery;
	order(column: string, options?: { ascending?: boolean }): MeetupQuery;
	limit(count: number): MeetupQuery;
	update(values: Record<string, unknown>): MeetupQuery;
	upsert(values: Record<string, unknown>, options?: { onConflict?: string }): MeetupQuery;
	maybeSingle?: () => Promise<QueryResult>;
	single?: () => Promise<QueryResult>;
	then?: PromiseLike<QueryResult>["then"];
}

interface MeetupClient {
	from(table: string): MeetupQuery;
	rpc(functionName: string, args: Record<string, unknown>): Promise<QueryResult>;
}

const storedMeetupStatuses = [
	"intent_pending",
	"intent_matched",
	"verifying",
	"arranging",
	"proposed",
	"confirmed",
	"checked_in",
	"completed",
	"no_show",
	"declined",
	"arrange_failed",
	"expired",
	"cancelled",
] as const;

const publicMeetupStatuses = [
	"intent_pending",
	"verifying",
	"arranging",
	"proposed",
	"confirmed",
	"arrange_failed",
	"expired",
	"cancelled",
] as const;

const meetupFormatValues = ["cafe", "meal", "activity", "online"] as const;
const terminalMeetupStatuses = new Set([
	"confirmed",
	"checked_in",
	"completed",
	"no_show",
	"cancelled",
	"declined",
	"expired",
]);

const RFC3339_WITH_OFFSET =
	/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-](\d{2}):(\d{2}))$/;

function isRfc3339WithOffset(value: string): boolean {
	const match = RFC3339_WITH_OFFSET.exec(value);
	if (!match) return false;
	const year = Number(match[1]);
	const month = Number(match[2]);
	const day = Number(match[3]);
	const hour = Number(match[4]);
	const minute = Number(match[5]);
	const second = Number(match[6]);
	if (month < 1 || month > 12 || day < 1 || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) return false;
	if (hour > 23 || minute > 59 || second > 59) return false;
	if (match[7] !== "Z" && (Number(match[8]) > 23 || Number(match[9]) > 59)) return false;
	const parsed = Date.parse(value);
	return Number.isFinite(parsed);
}

const rfc3339WithOffsetSchema = z.string().refine(isRfc3339WithOffset);

const availabilityEntrySchema = z
	.object({
		starts_at: rfc3339WithOffsetSchema,
		ends_at: rfc3339WithOffsetSchema,
	})
	.strict()
	.refine((entry) => Date.parse(entry.starts_at) < Date.parse(entry.ends_at));

const availabilitySchema = z
	.array(availabilityEntrySchema)
	.max(32)
	.superRefine((entries, context) => {
		const seen = new Set<string>();
		for (const [index, entry] of entries.entries()) {
			const key = `${entry.starts_at}\u0000${entry.ends_at}`;
			if (seen.has(key)) {
				context.addIssue({ code: z.ZodIssueCode.custom, path: [index] });
			}
			seen.add(key);
		}
	});

const areaSchema = z.string().refine((value) => {
	return (
		value === value.trim() &&
		value.length >= 1 &&
		value.length <= 160 &&
		!/[\r\n\u2028\u2029]/u.test(value)
	);
});

const areasSchema = z
	.array(areaSchema)
	.max(8)
	.superRefine((areas, context) => {
		const seen = new Set<string>();
		for (const [index, area] of areas.entries()) {
			if (seen.has(area)) context.addIssue({ code: z.ZodIssueCode.custom, path: [index] });
			seen.add(area);
		}
	});

const formatsSchema = z
	.array(z.enum(meetupFormatValues))
	.max(4)
	.superRefine((formats, context) => {
		const seen = new Set<string>();
		for (const [index, format] of formats.entries()) {
			if (seen.has(format)) context.addIssue({ code: z.ZodIssueCode.custom, path: [index] });
			seen.add(format);
		}
	});

function isPlainJsonObject(value: unknown): value is Record<string, unknown> {
	if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
	const prototype = Object.getPrototypeOf(value);
	return prototype === Object.prototype || prototype === null;
}

function utf8ByteLength(value: string): number {
	return new TextEncoder().encode(value).byteLength;
}

function isJsonValue(value: unknown, seen = new WeakSet<object>()): boolean {
	if (value === null || typeof value === "string" || typeof value === "boolean") return true;
	if (typeof value === "number") return Number.isFinite(value);
	if (typeof value !== "object") return false;
	if (seen.has(value)) return false;
	seen.add(value);
	let valid = true;
	if (Array.isArray(value)) {
		valid = value.every((item) => isJsonValue(item, seen));
	} else if (isPlainJsonObject(value)) {
		valid = Object.entries(value).every(([key, item]) => typeof key === "string" && isJsonValue(item, seen));
	} else {
		valid = false;
	}
	seen.delete(value);
	return valid;
}

const constraintsSchema = z.custom<Record<string, unknown>>((value) => {
	if (!isJsonValue(value) || !isPlainJsonObject(value)) return false;
	try {
		const encoded = JSON.stringify(value);
		return typeof encoded === "string" && utf8ByteLength(encoded) <= 2000;
	} catch {
		return false;
	}
});

/** Public request schema; `.strict()` rejects caller-controlled extra fields. */
export const meetupPreferencesSchema = z
	.object({
		availability: availabilitySchema,
		areas: areasSchema,
		budget_band: z.enum(["low", "medium", "high"]),
		formats: formatsSchema,
		constraints: constraintsSchema,
	})
	.strict();

export type MeetupPreferences = z.infer<typeof meetupPreferencesSchema>;

export type MeetupServiceError = "not_found" | "invalid_state" | "internal";

export type MeetupNotificationContext = {
	meetupId: string;
	matchId: string;
};

export type IntentServiceResult =
	| {
			ok: true;
			transition: "mutual_intent" | null;
			notificationContext?: MeetupNotificationContext;
	  }
	| { ok: false; reason: MeetupServiceError };

export type MeetupCandidate = {
	starts_at: string;
	timezone: string;
	area: string;
	format: (typeof meetupFormatValues)[number];
	rationale: string;
};

export type MeetupDetail = {
	id: string;
	match_id: string;
	status: (typeof publicMeetupStatuses)[number];
	proposal: {
		id: string;
		candidates: [MeetupCandidate, MeetupCandidate, MeetupCandidate];
		expires_at: string | null;
	} | null;
	confirmed_candidate: {
		starts_at: string;
		timezone: string;
		area: string;
		format: (typeof meetupFormatValues)[number];
	} | null;
	expires_at: string | null;
};

export type MeetupDetailResult =
	| { ok: true; data: MeetupDetail }
	| { ok: false; reason: MeetupServiceError };

export type SavePreferencesResult =
	| { ok: true }
	| { ok: false; reason: MeetupServiceError | "bad_request" };

/**
 * The only data a scheduling model may receive.  `first` and `second` are
 * positional labels rather than user identifiers; the service deliberately
 * strips all ids, names, chat content, and exact location data before it
 * constructs this value.
 */
export type ProposalGeneratorInput = {
	preferences: {
		first: SchedulingPreferences;
		second: SchedulingPreferences;
	};
	interaction_dna: InteractionDnaField[];
};

export type SchedulingPreferences = {
	availability: Array<{ starts_at: string; ends_at: string }>;
	areas: string[];
	budget_band: "low" | "medium" | "high" | null;
	formats: Array<(typeof meetupFormatValues)[number]>;
	constraints: Record<string, unknown>;
};

/** Only aggregate compatibility signals are allowlisted for scheduling. */
export type InteractionDnaField = {
	feature_id: number;
	normalized_score: number;
	confidence: number;
	source_phase: "quiz" | "speed_dating" | "fox_conversation" | "partner_fox_chat" | "direct_chat";
};

export interface ProposalGenerator {
	generate(input: ProposalGeneratorInput): Promise<unknown>;
}

/**
 * A focused notifier boundary.  The integration branch can adapt these
 * contexts to the shared notification pipeline without making this leaf call
 * OneSignal or import shared trigger wiring.
 */
export type MeetupArrangementNotificationContext = {
	scenarioId: "N-05" | "N-06" | "N-14";
	meetupId: string;
	matchId: string;
	proposalId?: string;
	recipientIds: [string, string];
};

export interface MeetupArrangementNotifier {
	notify(context: MeetupArrangementNotificationContext): Promise<void>;
}

export const noopMeetupArrangementNotifier: MeetupArrangementNotifier = Object.freeze({
	async notify(): Promise<void> {
		// Delivery is intentionally owned by the integration branch.
	},
});

export type ArrangementBillingSource = "meetup_arrange" | "arrange_retry" | "entitlement" | "credit" | "free_retry" | null;

export type MeetupArrangeResult =
	| {
			ok: true;
			status: "arranging" | "proposed" | "arrange_failed";
			billingSource: ArrangementBillingSource;
			notificationContexts?: MeetupArrangementNotificationContext[];
		}
	| {
			ok: false;
			reason:
				| MeetupServiceError
				| "bad_request"
				| "identity_verification_required"
				| "quota_exhausted";
		};

export type MeetupProposalResponseResult =
	| {
			ok: true;
			status: "proposed" | "confirmed";
			notificationContexts?: MeetupArrangementNotificationContext[];
		}
	| {
			ok: false;
			reason:
				| MeetupServiceError
				| "bad_request"
				| "identity_verification_required";
		};

export type ArrangementOptions = {
	now?: Date;
	idempotencyKey?: string;
};

export type MeetupExpiryRow = {
	meetupId: string;
	matchId: string;
	previousStatus: "intent_pending" | "proposed" | "confirmed";
	status: "expired";
};

const notFoundReason = { ok: false, reason: "not_found" } as const;
const internalReason = { ok: false, reason: "internal" } as const;

function asMeetupClient(client: SupabaseClient<Database>): MeetupClient {
	return client as unknown as MeetupClient;
}

function hasErrorCode(error: unknown, code: string): boolean {
	return typeof error === "object" && error !== null && "code" in error && (error as { code?: unknown }).code === code;
}

function isObject(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isQueryResult(value: unknown): value is QueryResult {
	return isObject(value) && "data" in value && "error" in value;
}

async function resolveSingle(query: MeetupQuery): Promise<QueryResult> {
	if (typeof query.maybeSingle === "function") return query.maybeSingle();
	if (typeof query.single === "function") return query.single();
	if (typeof query.then === "function") return query as unknown as Promise<QueryResult>;
	throw new Error("query did not provide a result resolver");
}

const intentRpcRowSchema = z
	.object({
		meetup_id: z.string().uuid().nullable(),
		outcome: z.enum(["created", "matched", "already_active", "blocked", "not_found"]),
		status: z.enum([
			"intent_pending",
			"intent_matched",
			"verifying",
			"arranging",
			"proposed",
			"confirmed",
			"checked_in",
			"completed",
			"no_show",
			"cancelled",
			"declined",
			"expired",
			"arrange_failed",
		]).nullable(),
		initiator_id: z.string().uuid().nullable(),
		matched: z.boolean(),
	})
	.strict();

function isConsistentIntentRow(row: z.infer<typeof intentRpcRowSchema>): boolean {
	if (row.outcome === "blocked" || row.outcome === "not_found") {
		return row.meetup_id === null && row.status === null && row.initiator_id === null && row.matched === false;
	}
	if (row.meetup_id === null || row.initiator_id === null) return false;
	if (row.outcome === "created") {
		return row.status === "intent_pending" && row.matched === false;
	}
	if (row.outcome === "matched") {
		return row.status === "intent_matched" && row.matched === true;
	}
	if (row.status === null) return false;
	return row.matched === (row.status !== "intent_pending");
}

function isArrangementClaimRowConsistent(
	row: z.infer<typeof arrangementClaimRpcRowSchema>,
	meetupId: string,
	matchId: string,
): boolean {
	// Every SQL branch echoes the requested meetup id. A different id would
	// make the result unsafe to associate with the caller's request.
	if (row.meetup_id !== meetupId || row.transitioned !== (row.outcome === "claimed")) return false;

	// Relationship failures deliberately return a null match id in the RPC.
	// The idempotency-conflict `not_found` branch has already loaded the match
	// from the meetup row, so it may echo the expected id. Either form is safe
	// only when it cannot name a different match.
	if (row.outcome === "not_found" || row.outcome === "blocked") {
		return (
			(row.match_id === null || row.match_id === matchId) &&
			row.status === null &&
			row.attempt_number === null &&
			row.billing_source === null
		);
	}
	if (row.outcome === "invalid_input") {
		// The parameter-validation branch returns a null relationship/status,
		// while the malformed-profile-timezone branch has already loaded the
		// exact match and meetup. Both are intentional, non-transitioning RPC
		// outcomes and must remain valid at this boundary.
		const nullInputShape = row.match_id === null && row.status === null;
		const timezoneShape = row.match_id === matchId && row.status !== null;
		return (nullInputShape || timezoneShape) && row.attempt_number === null && row.billing_source === null;
	}

	if (row.match_id !== matchId) return false;
	if (row.outcome === "claimed") {
		return row.status === "arranging" && row.attempt_number !== null && row.billing_source !== null;
	}
	if (row.outcome === "already_claimed") {
		return row.status !== null && row.attempt_number !== null && row.billing_source !== null;
	}
	if (row.outcome === "already_arranging") {
		return row.status === "arranging" && row.attempt_number !== null && row.billing_source === null;
	}
	if (row.outcome === "identity_verification_required" || row.outcome === "quota_exhausted") {
		return row.status !== null && row.attempt_number === null && row.billing_source === null;
	}
	if (row.outcome === "invalid_state") {
		return row.status !== null && row.attempt_number === null && row.billing_source === null;
	}
	return false;
}

function isArrangementPersistenceRowConsistent(
	row: z.infer<typeof arrangementPersistenceRpcRowSchema>,
	meetupId: string,
	matchId: string,
	attemptNumber: number,
): boolean {
	if (row.meetup_id !== meetupId || row.attempt_number !== attemptNumber || row.transitioned !== (row.outcome === "proposed" || row.outcome === "arrange_failed")) {
		return false;
	}
	if (row.outcome === "not_found" || row.outcome === "blocked" || row.outcome === "invalid_input") {
		return row.match_id === null && row.proposal_id === null && row.status === null;
	}
	if (row.match_id !== matchId) return false;
	if (row.outcome === "proposed" || row.outcome === "already_proposed") {
		return row.status === "proposed" && row.proposal_id !== null && (row.outcome === "proposed" ? row.transitioned : !row.transitioned);
	}
	if (row.outcome === "arrange_failed" || row.outcome === "already_failed") {
		return row.status === "arrange_failed" && row.proposal_id === null && (row.outcome === "arrange_failed" ? row.transitioned : !row.transitioned);
	}
	if (row.outcome === "identity_verification_required") {
		return row.status !== null && row.proposal_id === null && !row.transitioned;
	}
	if (row.outcome === "invalid_state") {
		return row.status !== null && row.proposal_id === null && !row.transitioned;
	}
	return false;
}

const meetupRowSchema = z
	.object({
		id: z.string().uuid(),
		match_id: z.string().uuid(),
		initiator_id: z.string().uuid(),
		status: z.enum(storedMeetupStatuses),
		confirmed_start_at: rfc3339WithOffsetSchema.nullable(),
		confirmed_timezone: z.string().nullable(),
		area: z.string().nullable(),
		format: z.enum(meetupFormatValues).nullable(),
		intent_expires_at: rfc3339WithOffsetSchema.nullable(),
		proposal_expires_at: rfc3339WithOffsetSchema.nullable(),
	})
	.passthrough();

const matchRowSchema = z
	.object({
		id: z.string().uuid(),
		user_a_id: z.string().uuid(),
		user_b_id: z.string().uuid(),
		status: z.string(),
	})
	.passthrough();

const currentMeetupAccessProfileSelect = `${MATCHING_ELIGIBILITY_COLUMNS},blocks_sent:blocks!blocks_blocker_id_fkey(id,blocker_id,blocked_id)`;

// Keep this current-state read in one PostgREST request. Explicit foreign-key
// hints bind the embedding to the relationships used by the authorization
// contract, while the caller's captured ordered participants are checked
// again after the response is parsed.
const CURRENT_MEETUP_ACCESS_SELECT = [
	"id,match_id,initiator_id,status",
	`match:matches!meetups_match_id_fkey!inner(id,user_a_id,user_b_id,status,profile_a:user_profiles!matches_user_a_id_fkey!inner(${currentMeetupAccessProfileSelect}),profile_b:user_profiles!matches_user_b_id_fkey!inner(${currentMeetupAccessProfileSelect}),direct_room:direct_chat_rooms!direct_chat_rooms_match_id_fkey(id,match_id,status))`,
].join(",");

const currentMeetupAccessRowSchema = z
	.object({
		id: z.string().uuid(),
		match_id: z.string().uuid(),
		initiator_id: z.string().uuid(),
		status: z.enum(storedMeetupStatuses),
		match: z
			.object({
				id: z.string().uuid(),
				user_a_id: z.string().uuid(),
				user_b_id: z.string().uuid(),
				status: z.string(),
				profile_a: z.unknown(),
				profile_b: z.unknown(),
				direct_room: z.unknown().nullable(),
			})
			.passthrough(),
	})
	.passthrough();

const roomRowSchema = z.object({ id: z.string().uuid(), status: z.literal("active") }).passthrough();

const proposalRowSchema = z
	.object({
		id: z.string().uuid(),
		candidates: z.unknown(),
		expires_at: rfc3339WithOffsetSchema.nullable(),
	})
	.passthrough();

const candidateSchema = z
	.object({
		starts_at: rfc3339WithOffsetSchema,
		timezone: z.string().min(1),
		area: areaSchema,
		format: z.enum(meetupFormatValues),
		rationale: z.string().max(500),
	})
	.passthrough();

/*
 * Generated areas are intentionally coarser than a venue.  Requiring one
 * city/ward separator makes a precise address, station, latitude, or free
 * form place name fail closed at the API boundary.  The database migration
 * repeats this check because the service-role write bypasses RLS.
 */
const cityWardAreaPattern = /^[^/\r\n]{1,80}\/[^/\r\n]{1,80}$/u;

function isCityWardArea(value: string): boolean {
	return (
		areaSchema.safeParse(value).success &&
		cityWardAreaPattern.test(value) &&
		!/[,;]|\u0000|[\u0001-\u001f\u007f]/u.test(value)
	);
}

const generatedCandidateSchema = z
	.object({
		starts_at: rfc3339WithOffsetSchema,
		timezone: z.string().min(1),
		area: z.string().refine(isCityWardArea),
		format: z.enum(meetupFormatValues),
		rationale: z
			.string()
			.min(1)
			.max(500)
			.refine((value) => !/[\r\n\u2028\u2029\u0000-\u001f\u007f]/u.test(value)),
	})
	.strict();

export type ValidatedMeetupCandidates = [MeetupCandidate, MeetupCandidate, MeetupCandidate];

/**
 * Re-validates untrusted ProposalGenerator output at the last boundary
 * before persistence.  `now` is injected so the 21-day edge is deterministic
 * in tests and never depends on a wall-clock race.
 */
export function validateGeneratedCandidates(value: unknown, now: Date = new Date()): ValidatedMeetupCandidates | null {
	if (!Number.isFinite(now.getTime()) || !Array.isArray(value) || value.length !== 3) return null;
	const parsed = value.map((candidate) => generatedCandidateSchema.safeParse(candidate));
	if (parsed.some((result) => result.success === false)) return null;
	const candidates = parsed.map((result) => {
		if (result.success === false) return null;
		return {
			starts_at: result.data.starts_at,
			timezone: result.data.timezone,
			area: result.data.area,
			format: result.data.format,
			rationale: result.data.rationale,
		};
	});
	if (!candidates.every((candidate): candidate is MeetupCandidate => candidate !== null)) return null;
	const latestAllowed = now.getTime() + 21 * 24 * 60 * 60 * 1000;
	for (const candidate of candidates) {
		if (!validateTimezone(candidate.timezone)) return null;
		const timestamp = Date.parse(candidate.starts_at);
		if (!Number.isFinite(timestamp) || timestamp <= now.getTime() || timestamp > latestAllowed) return null;
	}
	// Three choices that are byte-for-byte identical do not give the user a
	// real choice and commonly indicate a model fallback bug.
	const distinct = new Set(candidates.map((candidate) => JSON.stringify(candidate)));
	if (distinct.size !== 3) return null;
	return candidates as ValidatedMeetupCandidates;
}

const identityStatusSchema = z.object({
	id: z.string().uuid(),
	identity_verification_status: z.string(),
	identity_verified_at: rfc3339WithOffsetSchema.nullable(),
});

const dnaFieldSchema = z.object({
	feature_id: z.number().int().min(1).max(14),
	normalized_score: z.number().finite().min(0).max(1),
	confidence: z.number().finite().min(0).max(1),
	source_phase: z.enum(["quiz", "speed_dating", "fox_conversation", "partner_fox_chat", "direct_chat"]),
});

const arrangementClaimRpcRowSchema = z
	.object({
		meetup_id: z.string().uuid().nullable(),
		match_id: z.string().uuid().nullable(),
		outcome: z.enum([
			"claimed",
			"already_claimed",
			"already_arranging",
			"not_found",
			"blocked",
			"invalid_state",
			"identity_verification_required",
			"quota_exhausted",
			"invalid_input",
		]),
		status: z.enum(storedMeetupStatuses).nullable(),
		attempt_number: z.number().int().min(1).nullable(),
		billing_source: z.enum(["meetup_arrange", "arrange_retry", "entitlement", "credit", "free_retry"]).nullable(),
		transitioned: z.boolean(),
	})
	.strict();

const arrangementPersistenceRpcRowSchema = z
	.object({
		meetup_id: z.string().uuid(),
		match_id: z.string().uuid().nullable(),
		proposal_id: z.string().uuid().nullable(),
		attempt_number: z.number().int().min(1),
		outcome: z.enum(["proposed", "already_proposed", "arrange_failed", "already_failed", "invalid_state", "not_found", "blocked", "identity_verification_required", "invalid_input"]),
		status: z.enum(storedMeetupStatuses).nullable(),
		transitioned: z.boolean(),
	})
	.strict();

const proposalResponseRpcRowSchema = z
	.object({
		meetup_id: z.string().uuid(),
		proposal_id: z.string().uuid(),
		outcome: z.enum(["accepted", "confirmed", "blocked", "not_found", "expired", "invalid_input", "invalid_state", "identity_verification_required"]),
		status: z.enum(storedMeetupStatuses).nullable(),
		confirmed_candidate_index: z.number().int().min(0).max(2).nullable(),
	})
	.strict();

const noopProposalGenerator: ProposalGenerator = Object.freeze({
	async generate(): Promise<unknown> {
		// Explicit test/local overrides may still opt into a no-op. Returning
		// invalid output keeps that override fail-closed as arrange_failed.
		return null;
	},
});

let configuredProposalGenerator: ProposalGenerator | null = null;

export function setMeetupProposalGenerator(generator: ProposalGenerator | null | undefined): void {
	configuredProposalGenerator = generator ?? noopProposalGenerator;
}

export function getMeetupProposalGenerator(apiKey?: string): ProposalGenerator {
	// A test/local job can install an explicit fake through the setter. Normal
	// requests receive a per-request Mistral adapter so a missing Worker secret
	// fails closed and one request cannot change another request's provider state.
	return configuredProposalGenerator ?? createMeetupProposalGenerator(apiKey);
}

function validateTimezone(value: string): boolean {
	try {
		assertValidTimeZone(value);
		return true;
	} catch {
		return false;
	}
}

function parseCandidates(value: unknown): [MeetupCandidate, MeetupCandidate, MeetupCandidate] | null {
	if (!Array.isArray(value) || value.length !== 3) return null;
	const parsed = value.map((candidate) => candidateSchema.safeParse(candidate));
	if (parsed.some((result) => result.success === false)) return null;
	const candidates = parsed.map((result) => {
		if (result.success === false) return null;
		return {
			starts_at: result.data.starts_at,
			timezone: result.data.timezone,
			area: result.data.area,
			format: result.data.format,
			rationale: result.data.rationale,
		};
	});
	if (!candidates.every((candidate): candidate is MeetupCandidate => candidate !== null)) return null;
	if (candidates.some((candidate) => !validateTimezone(candidate.timezone))) return null;
	return candidates as [MeetupCandidate, MeetupCandidate, MeetupCandidate];
}

function parseConfirmedCandidate(row: z.infer<typeof meetupRowSchema>): MeetupDetail["confirmed_candidate"] | undefined {
	const fields = [row.confirmed_start_at, row.confirmed_timezone, row.area, row.format];
	if (fields.every((value) => value === null)) {
		return ["confirmed", "checked_in", "completed"].includes(row.status) ? undefined : null;
	}
	if (
		row.confirmed_start_at === null ||
		row.confirmed_timezone === null ||
		row.area === null ||
		row.format === null ||
		!areaSchema.safeParse(row.area).success ||
		!validateTimezone(row.confirmed_timezone)
	) {
		return undefined;
	}
	return {
		starts_at: row.confirmed_start_at,
		timezone: row.confirmed_timezone,
		area: row.area,
		format: row.format,
	};
}

type AuthorizedMeetup = {
	meetup: z.infer<typeof meetupRowSchema>;
	match: z.infer<typeof matchRowSchema>;
};

/**
 * Immutable identity for one arrangement invocation. Keep the database
 * relationship and participant order together so a later read cannot be
 * accidentally paired with a reassigned meetup or a different caller.
 */
type MeetupAccessBinding = {
	meetupId: string;
	matchId: string;
	participantIds: [string, string];
	initiatorId: string;
	callerId: string;
};

function bindingFromAuthorized(authorized: AuthorizedMeetup, meetupId: string, callerId: string): MeetupAccessBinding {
	return {
		meetupId,
		matchId: authorized.match.id,
		participantIds: [authorized.match.user_a_id, authorized.match.user_b_id],
		initiatorId: authorized.meetup.initiator_id,
		callerId,
	};
}

function sameParticipantOrder(first: [string, string], second: [string, string]): boolean {
	return first[0] === second[0] && first[1] === second[1];
}

function validateCurrentMeetupBlockRows(
	value: unknown,
	blockerId: string,
	blockedId: string,
): { ok: true; blocked: boolean } | { ok: false } {
	if (!Array.isArray(value)) return { ok: false };
	for (const row of value) {
		if (
			!isObject(row) ||
			!z.string().uuid().safeParse(row.id).success ||
			row.blocker_id !== blockerId ||
			row.blocked_id !== blockedId
		) {
			return { ok: false };
		}
	}
	return { ok: true, blocked: value.length > 0 };
}

type CurrentMeetupAccess = {
	meetup: Pick<z.infer<typeof currentMeetupAccessRowSchema>, "id" | "match_id" | "initiator_id" | "status">;
	match: z.infer<typeof currentMeetupAccessRowSchema>["match"];
};

function validateCurrentMeetupAccess(
	value: unknown,
	binding: MeetupAccessBinding,
): { ok: true; value: CurrentMeetupAccess } | { ok: false; reason: MeetupServiceError } {
	const parsed = currentMeetupAccessRowSchema.safeParse(value);
	if (parsed.success === false) {
		return value === null || value === undefined ? { ok: false, reason: "not_found" } : internalReason;
	}

	const current = parsed.data;
	const match = current.match;
	if (
		current.id !== binding.meetupId ||
		current.match_id !== binding.matchId ||
		(match.user_a_id !== binding.participantIds[0] || match.user_b_id !== binding.participantIds[1]) ||
		match.id !== binding.matchId ||
		match.user_a_id >= match.user_b_id ||
		current.initiator_id !== binding.initiatorId ||
		(binding.callerId !== binding.participantIds[0] && binding.callerId !== binding.participantIds[1])
	) {
		return { ok: false, reason: "not_found" };
	}
	if (match.status !== "direct_chat_active") return { ok: false, reason: "not_found" };

	if (!isObject(match.profile_a) || !isObject(match.profile_b)) return internalReason;
	if (match.profile_a.id !== binding.participantIds[0] || match.profile_b.id !== binding.participantIds[1]) {
		return { ok: false, reason: "not_found" };
	}
	const blocksFromA = validateCurrentMeetupBlockRows(
		match.profile_a.blocks_sent,
		binding.participantIds[0],
		binding.participantIds[1],
	);
	const blocksFromB = validateCurrentMeetupBlockRows(
		match.profile_b.blocks_sent,
		binding.participantIds[1],
		binding.participantIds[0],
	);
	if (!blocksFromA.ok || !blocksFromB.ok) return internalReason;
	if (blocksFromA.blocked || blocksFromB.blocked) return { ok: false, reason: "not_found" };
	if (!areMutuallyEligible(match.profile_a, match.profile_b)) return { ok: false, reason: "not_found" };

	if (current.match.direct_room === null) return { ok: false, reason: "not_found" };
	if (!isObject(current.match.direct_room)) return internalReason;
	if (!z.string().uuid().safeParse(current.match.direct_room.id).success) return internalReason;
	if (current.match.direct_room.match_id !== binding.matchId) return { ok: false, reason: "not_found" };
	if (current.match.direct_room.status !== "active") return { ok: false, reason: "not_found" };

	return {
		ok: true,
		value: {
			meetup: {
				id: current.id,
				match_id: current.match_id,
				initiator_id: current.initiator_id,
				status: current.status,
			},
			match,
		},
	};
}

/** Re-reads one narrow, exact current-access snapshot for this binding. */
async function revalidateMeetupAccess(
	client: SupabaseClient<Database>,
	binding: MeetupAccessBinding,
): Promise<{ ok: true; value: CurrentMeetupAccess } | { ok: false; reason: MeetupServiceError }> {
	const db = asMeetupClient(client);
	let result: QueryResult;
	try {
		const query = db
			.from("meetups")
			.select(CURRENT_MEETUP_ACCESS_SELECT)
			.eq("id", binding.meetupId)
			.eq("match_id", binding.matchId)
			.eq("match.id", binding.matchId)
			.eq("match.user_a_id", binding.participantIds[0])
			.eq("match.user_b_id", binding.participantIds[1])
			// These filters are deliberately keyed to match.user_a/user_b order,
			// never to whichever participant initiated this request.
			.eq("match.profile_a.blocks_sent.blocked_id", binding.participantIds[1])
			.eq("match.profile_b.blocks_sent.blocked_id", binding.participantIds[0]);
		result = await resolveSingle(query);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(result)) return internalReason;
	if (result.error) return hasErrorCode(result.error, "PGRST116") ? notFoundReason : internalReason;
	return validateCurrentMeetupAccess(result.data, binding);
}

function isArrangementWorkingStatus(status: string): status is "arranging" | "proposed" | "arrange_failed" {
	return status === "arranging" || status === "proposed" || status === "arrange_failed";
}

/**
 * Proves every relationship needed by a meetup read/write. The API always
 * uses the service-role client, so this check is the application-side RLS
 * equivalent and must not be replaced by a client-provided participant flag.
 */
async function authorizeMeetup(
	client: SupabaseClient<Database>,
	meetupId: string,
	userId: string,
): Promise<{ ok: true; value: AuthorizedMeetup } | { ok: false; reason: MeetupServiceError }> {
	const db = asMeetupClient(client);
	let meetupResult: QueryResult;
	try {
		const meetupQuery = db
			.from("meetups")
			.select(
				"id, match_id, initiator_id, status, confirmed_start_at, confirmed_timezone, area, format, intent_expires_at, proposal_expires_at",
			)
			.eq("id", meetupId);
		meetupResult = await resolveSingle(meetupQuery);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(meetupResult)) return internalReason;
	if (meetupResult.error) {
		return hasErrorCode(meetupResult.error, "PGRST116") ? notFoundReason : internalReason;
	}
	const parsedMeetup = meetupRowSchema.safeParse(meetupResult.data);
	if (parsedMeetup.success === false) {
		return meetupResult.data === null || meetupResult.data === undefined ? notFoundReason : internalReason;
	}
	if (parsedMeetup.data.id !== meetupId) return internalReason;

	let matchResult: QueryResult;
	try {
		const matchQuery = db
			.from("matches")
			.select("id, user_a_id, user_b_id, status")
			.eq("id", parsedMeetup.data.match_id);
		matchResult = await resolveSingle(matchQuery);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(matchResult)) return internalReason;
	if (matchResult.error) {
		return hasErrorCode(matchResult.error, "PGRST116") ? notFoundReason : internalReason;
	}
	const parsedMatch = matchRowSchema.safeParse(matchResult.data);
	if (parsedMatch.success === false) {
		if (matchResult.data === null || matchResult.data === undefined) return notFoundReason;
		return internalReason;
	}
	if (parsedMatch.data.id !== parsedMeetup.data.match_id) return internalReason;
	if (parsedMatch.data.user_a_id === parsedMatch.data.user_b_id) return internalReason;
	if (parsedMatch.data.user_a_id >= parsedMatch.data.user_b_id) return internalReason;
	if (parsedMatch.data.user_a_id !== userId && parsedMatch.data.user_b_id !== userId) return notFoundReason;
	if (parsedMeetup.data.initiator_id !== parsedMatch.data.user_a_id && parsedMeetup.data.initiator_id !== parsedMatch.data.user_b_id) {
		return internalReason;
	}
	if (parsedMatch.data.status !== "direct_chat_active") return notFoundReason;
	if (parsedMeetup.data.status === "intent_pending" && parsedMeetup.data.initiator_id !== userId) {
		return notFoundReason;
	}

	let agePair: Awaited<ReturnType<typeof checkVerifiedPair>>;
	try {
		agePair = await checkVerifiedPair(client, parsedMatch.data.user_a_id, parsedMatch.data.user_b_id);
	} catch {
		return internalReason;
	}
	if (agePair.ok === false) return agePair.reason === "unverified" ? notFoundReason : internalReason;

	let roomResult: QueryResult;
	try {
		const roomQuery = db
			.from("direct_chat_rooms")
			.select("id, status")
			.eq("match_id", parsedMatch.data.id)
			.eq("status", "active");
		roomResult = await resolveSingle(roomQuery);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(roomResult)) return internalReason;
	if (roomResult.error) {
		return hasErrorCode(roomResult.error, "PGRST116") ? notFoundReason : internalReason;
	}
	if (roomResult.data === null || roomResult.data === undefined) return notFoundReason;
	if (Array.isArray(roomResult.data) && roomResult.data.length === 0) return notFoundReason;
	if (roomRowSchema.safeParse(roomResult.data).success === false) {
		// A stale/closed row should be indistinguishable from an absent active
		// room. Other malformed room data remains a fixed internal failure.
		if (isObject(roomResult.data) && roomResult.data.status !== "active") return notFoundReason;
		return internalReason;
	}

	let blockResult: QueryResult;
	try {
		const blockQuery = db
			.from("blocks")
			.select("id")
			.or(
				`and(blocker_id.eq.${parsedMatch.data.user_a_id},blocked_id.eq.${parsedMatch.data.user_b_id}),and(blocker_id.eq.${parsedMatch.data.user_b_id},blocked_id.eq.${parsedMatch.data.user_a_id})`,
			)
			.limit(1);
		blockResult = await resolveSingle(blockQuery);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(blockResult)) return internalReason;
	if (blockResult.error) {
		// `single()` fallback uses PGRST116 for no matching block; absence is
		// the authorized case, while any other lookup failure fails closed.
		if (hasErrorCode(blockResult.error, "PGRST116")) {
			return { ok: true, value: { meetup: parsedMeetup.data, match: parsedMatch.data } };
		}
		return internalReason;
	}
	if (Array.isArray(blockResult.data) && blockResult.data.length === 0) return { ok: true, value: { meetup: parsedMeetup.data, match: parsedMatch.data } };
	if (blockResult.data !== null && blockResult.data !== undefined) return notFoundReason;

	return { ok: true, value: { meetup: parsedMeetup.data, match: parsedMatch.data } };
}

/**
 * Creates or acknowledges one intent. The RPC is the first database call:
 * there is deliberately no route-level select-before-RPC race window.
 */
export async function createMeetupIntent(
	client: SupabaseClient<Database>,
	userId: string,
	matchId: string,
): Promise<IntentServiceResult> {
	const db = asMeetupClient(client);
	let rpcResult: QueryResult;
	try {
		rpcResult = await db.rpc("create_or_match_meetup_intent", {
			p_match_id: matchId,
			p_user_id: userId,
		});
	} catch {
		return internalReason;
	}
	if (!isQueryResult(rpcResult)) return internalReason;
	if (rpcResult.error || !Array.isArray(rpcResult.data) || rpcResult.data.length !== 1) return internalReason;
	const parsed = intentRpcRowSchema.safeParse(rpcResult.data[0]);
	if (parsed.success === false) return internalReason;
	if (!isConsistentIntentRow(parsed.data)) return internalReason;
	// The RPC intentionally folds relationship failures into safe outcomes.
	// They are valid, syntactically correct requests, so exposing a 404 here
	// would recreate the block/missing-match oracle at the HTTP boundary.
	if (parsed.data.outcome === "blocked" || parsed.data.outcome === "not_found") {
		return { ok: true, transition: null };
	}
	if (parsed.data.meetup_id === null) return internalReason;

	if (parsed.data.status !== "intent_matched") {
		// A retry after another caller has already won the conditional
		// intent_matched -> verifying update must re-run the notification
		// trigger. The trigger's own lifetime uniqueness boundary makes this
		// safe even when the first notification attempt failed part-way through.
		if (parsed.data.outcome === "already_active" && parsed.data.status === "verifying") {
			return {
				ok: true,
				transition: null,
				notificationContext: { meetupId: parsed.data.meetup_id, matchId },
			};
		}
		return { ok: true, transition: null };
	}

	// This conditional update is the idempotent recovery path. Exactly one
	// caller can win the expected-state predicate and therefore own the event.
	let transitionResult: QueryResult;
	try {
		const transitionQuery = db
			.from("meetups")
			.update({ status: "verifying" })
			.eq("id", parsed.data.meetup_id)
			.eq("status", "intent_matched")
			.select("id");
		transitionResult = await resolveSingle(transitionQuery);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(transitionResult)) return internalReason;
	if (transitionResult.error) {
		if (hasErrorCode(transitionResult.error, "PGRST116")) return { ok: true, transition: null };
		return internalReason;
	}
	if (
		transitionResult.data === null ||
		transitionResult.data === undefined ||
		(Array.isArray(transitionResult.data) && transitionResult.data.length === 0)
	) {
		return { ok: true, transition: null };
	}
	if (!isObject(transitionResult.data) || transitionResult.data.id !== parsed.data.meetup_id) return internalReason;
	return {
		ok: true,
		transition: "mutual_intent",
		notificationContext: { meetupId: parsed.data.meetup_id, matchId },
	};
}

export async function getMeetupDetail(
	client: SupabaseClient<Database>,
	userId: string,
	meetupId: string,
): Promise<MeetupDetailResult> {
	const authorized = await authorizeMeetup(client, meetupId, userId);
	if (authorized.ok === false) return authorized;
	const { meetup } = authorized.value;
	if (!(publicMeetupStatuses as readonly string[]).includes(meetup.status)) return internalReason;

	let confirmedCandidate: MeetupDetail["confirmed_candidate"] | undefined;
	try {
		confirmedCandidate = parseConfirmedCandidate(meetup);
	} catch {
		return internalReason;
	}
	if (confirmedCandidate === undefined) return internalReason;

	let proposal: MeetupDetail["proposal"] = null;
	if (meetup.status === "proposed") {
		const db = asMeetupClient(client);
		let proposalResult: QueryResult;
		try {
			const proposalQuery = db
				.from("meetup_proposals")
				.select("id, candidates, expires_at")
				.eq("meetup_id", meetup.id)
				.order("attempt_number", { ascending: false })
				.limit(1);
			proposalResult = await resolveSingle(proposalQuery);
		} catch {
			return internalReason;
		}
		if (!isQueryResult(proposalResult)) return internalReason;
		if (proposalResult.error || proposalResult.data === null || proposalResult.data === undefined) return internalReason;
		const parsedProposal = proposalRowSchema.safeParse(proposalResult.data);
		if (parsedProposal.success === false) return internalReason;
		const candidates = parseCandidates(parsedProposal.data.candidates);
		if (!candidates) return internalReason;
		proposal = {
			id: parsedProposal.data.id,
			candidates,
			expires_at: parsedProposal.data.expires_at ?? meetup.proposal_expires_at,
		};
	}

	return {
		ok: true,
		data: {
			id: meetup.id,
			match_id: meetup.match_id,
			status: meetup.status as (typeof publicMeetupStatuses)[number],
			proposal,
			confirmed_candidate: confirmedCandidate,
			expires_at:
				meetup.status === "intent_pending"
					? meetup.intent_expires_at
					: meetup.status === "proposed"
						? meetup.proposal_expires_at
						: null,
		},
	};
}

/**
 * Resolves the caller's current meetup for a match without exposing whether
 * the other participant has acted. The follow-up detail read remains the
 * owner/participant, age, block, room, and state authority.
 */
export async function getMeetupDetailByMatch(
	client: SupabaseClient<Database>,
	userId: string,
	matchId: string,
): Promise<MeetupDetailResult> {
	const db = asMeetupClient(client);
	let result: QueryResult;
	try {
		const lookup = db
			.from("meetups")
			.select("id")
			.eq("match_id", matchId)
			// A match-bound lookup is a mutual-intent recovery surface. An
			// intent_pending row belongs to the initiator's local state only and
			// must remain indistinguishable from an absent row for both callers.
			.or("status.eq.verifying,status.eq.arranging,status.eq.proposed,status.eq.confirmed,status.eq.arrange_failed")
			.order("updated_at", { ascending: false })
			.limit(1);
		result = await resolveSingle(lookup);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(result)) return internalReason;
	if (result.error) {
		return hasErrorCode(result.error, "PGRST116") ? notFoundReason : internalReason;
	}
	const row = firstRow(result.data);
	if (row === null) return notFoundReason;
	const parsed = z.object({ id: z.string().uuid() }).safeParse(row);
	if (parsed.success === false) return internalReason;
	const detail = await getMeetupDetail(client, userId, parsed.data.id);
	if (detail.ok === false) return detail;
	// Re-check the binding after the follow-up authorization read. This keeps
	// a stale lookup or malformed response from naming a different match, and
	// preserves the non-disclosing pending state even if the first query races
	// with a status change.
	if (detail.data.match_id !== matchId || detail.data.status === "intent_pending") return notFoundReason;
	return detail;
}

export async function saveMeetupPreferences(
	client: SupabaseClient<Database>,
	userId: string,
	meetupId: string,
	payload: unknown,
): Promise<SavePreferencesResult> {
	const authorized = await authorizeMeetup(client, meetupId, userId);
	if (authorized.ok === false) return authorized;
	let parsed: ReturnType<typeof meetupPreferencesSchema.safeParse>;
	try {
		parsed = meetupPreferencesSchema.safeParse(payload);
	} catch {
		return { ok: false, reason: "bad_request" };
	}
	if (parsed.success === false) return { ok: false, reason: "bad_request" };
	if (terminalMeetupStatuses.has(authorized.value.meetup.status)) {
		return { ok: false, reason: "invalid_state" };
	}

	const db = asMeetupClient(client);
	let writeResult: QueryResult;
	try {
		const writeQuery = db.from("meetup_preferences").upsert(
			{
				user_id: userId,
				availability: parsed.data.availability,
				areas: parsed.data.areas,
				budget_band: parsed.data.budget_band,
				formats: parsed.data.formats,
				constraints: parsed.data.constraints,
			},
			{ onConflict: "user_id" },
		).select("user_id");
		writeResult = await resolveSingle(writeQuery);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(writeResult)) return internalReason;
	if (writeResult.error) return internalReason;
	return { ok: true };
}

type ArrangementQuery = MeetupQuery & {
	in?: (column: string, values: unknown[]) => ArrangementQuery;
};

type RpcRowResult = { data: unknown; error: unknown };

function asArrangementQuery(query: MeetupQuery): ArrangementQuery {
	return query as ArrangementQuery;
}

async function resolveMany(query: MeetupQuery): Promise<QueryResult> {
	if (typeof query.then === "function") return await (query as PromiseLike<QueryResult>);
	return resolveSingle(query);
}

function rowsFrom(value: unknown): unknown[] {
	if (Array.isArray(value)) return value;
	if (value === null || value === undefined) return [];
	return [value];
}

function firstRow(value: unknown): unknown {
	if (Array.isArray(value)) return value.length === 1 ? value[0] : null;
	return value ?? null;
}

function safeOperationKey(value: string | undefined, fallbackPrefix: string, meetupId: string): string | null {
	if (value !== undefined) {
		if (!/^[\x21-\x7e]{1,128}$/u.test(value)) return null;
		return value;
	}
	try {
		return `${fallbackPrefix}:${meetupId}:${crypto.randomUUID()}`.slice(0, 128);
	} catch {
		// Cloudflare Workers and supported Node runtimes both expose
		// crypto.randomUUID.  A deterministic fallback is still bounded and is
		// only used when the host lacks that API.
		return `${fallbackPrefix}:${meetupId}`.slice(0, 128);
	}
}

function emptySchedulingPreferences(): SchedulingPreferences {
	return {
		availability: [],
		areas: [],
		budget_band: null,
		formats: [],
		constraints: {},
	};
}

function toSchedulingPreferences(row: unknown): SchedulingPreferences {
	if (!isObject(row)) return emptySchedulingPreferences();
	const candidate = {
		availability: row.availability,
		areas: row.areas,
		budget_band: row.budget_band ?? "low",
		formats: row.formats,
		constraints: row.constraints,
	};
	const parsed = meetupPreferencesSchema.safeParse(candidate);
	if (!parsed.success) return emptySchedulingPreferences();
	return {
		availability: parsed.data.availability.map(({ starts_at, ends_at }) => ({ starts_at, ends_at })),
		areas: parsed.data.areas.filter(isCityWardArea),
		budget_band: row.budget_band === null ? null : parsed.data.budget_band,
		formats: [...parsed.data.formats],
		// `constraints` is intentionally withheld until its free-form values have
		// a separately frozen closed schema. Passing arbitrary strings here could
		// leak a name, copied chat text, or a precise address to the generator.
		constraints: {},
	};
}

function toInteractionDna(value: unknown): InteractionDnaField[] {
	const fields: InteractionDnaField[] = [];
	for (const row of rowsFrom(value)) {
		if (!isObject(row)) continue;
		const parsed = dnaFieldSchema.safeParse({
			feature_id: typeof row.feature_id === "number" ? row.feature_id : Number(row.feature_id),
			normalized_score: typeof row.normalized_score === "number" ? row.normalized_score : Number(row.normalized_score),
			confidence: typeof row.confidence === "number" ? row.confidence : Number(row.confidence),
			source_phase: row.source_phase,
		});
		if (parsed.success) {
			fields.push({
				feature_id: parsed.data.feature_id,
				normalized_score: parsed.data.normalized_score,
				confidence: parsed.data.confidence,
				source_phase: parsed.data.source_phase,
			});
		}
	}
	return fields;
}

type SchedulingContext = {
	matchId: string;
	participantIds: [string, string];
	input: ProposalGeneratorInput;
};

/**
 * Loads only the scheduling allow-list after the atomic claim.  In
 * particular, this never selects names, ids for model input, direct-chat
 * messages, profiles, personas, or venues.
 */
async function loadSchedulingContext(
	client: SupabaseClient<Database>,
	meetupId: string,
	callerId: string,
): Promise<{ ok: true; value: SchedulingContext } | { ok: false; reason: MeetupServiceError }> {
	const db = asMeetupClient(client);
	let meetupResult: QueryResult;
	try {
		meetupResult = await resolveSingle(db.from("meetups").select("id, match_id").eq("id", meetupId));
	} catch {
		return internalReason;
	}
	if (!isQueryResult(meetupResult) || meetupResult.error) return internalReason;
	const meetup = firstRow(meetupResult.data);
	if (!isObject(meetup) || meetup.id !== meetupId || typeof meetup.match_id !== "string") return internalReason;

	let matchResult: QueryResult;
	try {
		matchResult = await resolveSingle(
			db.from("matches").select("id, user_a_id, user_b_id, status").eq("id", meetup.match_id),
		);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(matchResult) || matchResult.error) return internalReason;
	const parsedMatch = matchRowSchema.safeParse(firstRow(matchResult.data));
	if (parsedMatch.success === false) return internalReason;
	if (parsedMatch.data.id !== meetup.match_id) return internalReason;
	if (parsedMatch.data.user_a_id === parsedMatch.data.user_b_id) return internalReason;
	if (parsedMatch.data.user_a_id !== callerId && parsedMatch.data.user_b_id !== callerId) return notFoundReason;
	const participantIds = [parsedMatch.data.user_a_id, parsedMatch.data.user_b_id] as [string, string];

	let preferencesResult: QueryResult;
	try {
		const preferencesQuery = db
			.from("meetup_preferences")
			.select("user_id, availability, areas, budget_band, formats, constraints") as MeetupQuery;
		const withIn = asArrangementQuery(preferencesQuery);
		if (typeof withIn.in !== "function") return internalReason;
		preferencesResult = await resolveMany(withIn.in("user_id", participantIds));
	} catch {
		return internalReason;
	}
	if (!isQueryResult(preferencesResult) || preferencesResult.error) return internalReason;
	const preferenceRows = rowsFrom(preferencesResult.data);
	const firstPreferences = preferenceRows.find((row) => isObject(row) && row.user_id === participantIds[0]) ?? null;
	const secondPreferences = preferenceRows.find((row) => isObject(row) && row.user_id === participantIds[1]) ?? null;

	let dnaResult: QueryResult;
	try {
		dnaResult = await resolveMany(
			db.from("interaction_dna_scores").select("feature_id, normalized_score, confidence, source_phase").eq("match_id", parsedMatch.data.id),
		);
	} catch {
		return internalReason;
	}
	if (!isQueryResult(dnaResult) || dnaResult.error) return internalReason;

	return {
		ok: true,
		value: {
			matchId: parsedMatch.data.id,
			participantIds,
			input: {
				preferences: {
					first: toSchedulingPreferences(firstPreferences),
					second: toSchedulingPreferences(secondPreferences),
				},
				interaction_dna: toInteractionDna(dnaResult.data),
			},
		},
	};
}

async function checkIdentityForMatch(
	client: SupabaseClient<Database>,
	participantIds: [string, string],
): Promise<"verified" | "unverified" | "internal"> {
	const db = asMeetupClient(client);
	let result: QueryResult;
	try {
		const profileQuery = db.from("user_profiles").select("id, identity_verification_status, identity_verified_at") as MeetupQuery;
		const withIn = asArrangementQuery(profileQuery);
		if (typeof withIn.in !== "function") return "internal";
		result = await resolveMany(withIn.in("id", participantIds));
	} catch {
		return "internal";
	}
	if (!isQueryResult(result) || result.error) return "internal";
	const parsed = rowsFrom(result.data).map((row) => identityStatusSchema.safeParse(row));
	if (parsed.some((item) => item.success === false)) return "internal";
	const verified = new Set(
		parsed.flatMap((item) => (item.success && item.data.identity_verification_status === "verified" && item.data.identity_verified_at ? [item.data.id] : [])),
	);
	return verified.has(participantIds[0]) && verified.has(participantIds[1]) ? "verified" : "unverified";
}

type ClaimResult = z.infer<typeof arrangementClaimRpcRowSchema>;

async function claimArrangement(
	client: SupabaseClient<Database>,
	userId: string,
	meetupId: string,
	isRetry: boolean,
	operationKey: string,
): Promise<ClaimResult | null> {
	let result: RpcRowResult;
	try {
		result = await asMeetupClient(client).rpc("claim_meetup_arrangement", {
			p_meetup_id: meetupId,
			p_user_id: userId,
			p_is_retry: isRetry,
			p_operation_key: operationKey,
		});
	} catch {
		return null;
	}
	if (!isQueryResult(result) || result.error || !Array.isArray(result.data) || result.data.length !== 1) return null;
	const parsed = arrangementClaimRpcRowSchema.safeParse(result.data[0]);
	return parsed.success ? parsed.data : null;
}

type PersistenceResult = z.infer<typeof arrangementPersistenceRpcRowSchema>;

async function persistArrangement(
	client: SupabaseClient<Database>,
	userId: string,
	meetupId: string,
	attemptNumber: number,
	candidates: unknown,
): Promise<PersistenceResult | null> {
	let result: RpcRowResult;
	try {
		result = await asMeetupClient(client).rpc("persist_meetup_proposal", {
			p_meetup_id: meetupId,
			p_user_id: userId,
			p_attempt_number: attemptNumber,
			p_candidates: candidates,
		});
	} catch {
		return null;
	}
	if (!isQueryResult(result) || result.error || !Array.isArray(result.data) || result.data.length !== 1) return null;
	const parsed = arrangementPersistenceRpcRowSchema.safeParse(result.data[0]);
	return parsed.success ? parsed.data : null;
}

function arrangementContext(
	scenarioId: "N-05" | "N-14",
	context: SchedulingContext,
	meetupId: string,
	proposalId?: string,
): MeetupArrangementNotificationContext {
	return {
		scenarioId,
		meetupId,
		matchId: context.matchId,
		...(proposalId ? { proposalId } : {}),
		recipientIds: context.participantIds,
	};
}

type NormalizedArrangeArgs = { generator: ProposalGenerator; options: ArrangementOptions };

function normalizeArrangeArgs(
	generatorOrOptions: ProposalGenerator | ArrangementOptions | undefined,
	options: ArrangementOptions | undefined,
): NormalizedArrangeArgs {
	if (generatorOrOptions && "generate" in generatorOrOptions && typeof generatorOrOptions.generate === "function") {
		return { generator: generatorOrOptions, options: options ?? {} };
	}
	if (generatorOrOptions && ("generator" in generatorOrOptions || "now" in generatorOrOptions || "idempotencyKey" in generatorOrOptions)) {
		const dependencyOptions = generatorOrOptions as ArrangementOptions & { generator?: ProposalGenerator };
		return { generator: dependencyOptions.generator ?? getMeetupProposalGenerator(), options: dependencyOptions };
	}
	return { generator: getMeetupProposalGenerator(), options: options ?? {} };
}

async function arrangeMeetupInternal(
	client: SupabaseClient<Database>,
	userId: string,
	meetupId: string,
	isRetry: boolean,
	generatorOrOptions?: ProposalGenerator | ArrangementOptions,
	options?: ArrangementOptions,
): Promise<MeetupArrangeResult> {
	const dependencies = normalizeArrangeArgs(generatorOrOptions, options);
	const now = dependencies.options.now ?? new Date();
	if (!(now instanceof Date) || !Number.isFinite(now.getTime())) return { ok: false, reason: "bad_request" };
	const operationKey = safeOperationKey(dependencies.options.idempotencyKey, isRetry ? "retry" : "arrange", meetupId);
	if (!operationKey) return { ok: false, reason: "bad_request" };

	// Establish the relationship before any billing/state transition. The
	// immediate snapshot is a narrow application-level revalidation; it does
	// not serialize external/database races, so the RPC remains the atomic
	// quota/write boundary.
	const initiallyAuthorized = await authorizeMeetup(client, meetupId, userId);
	if (initiallyAuthorized.ok === false) return initiallyAuthorized;
	const binding = bindingFromAuthorized(initiallyAuthorized.value, meetupId, userId);
	const beforeClaim = await revalidateMeetupAccess(client, binding);
	if (beforeClaim.ok === false) return beforeClaim;

	const claim = await claimArrangement(client, userId, meetupId, isRetry, operationKey);
	if (!claim) return internalReason;
	if (!isArrangementClaimRowConsistent(claim, binding.meetupId, binding.matchId)) return internalReason;
	if (claim.outcome === "not_found" || claim.outcome === "blocked") return notFoundReason;
	if (claim.outcome === "identity_verification_required") return { ok: false, reason: "identity_verification_required" };
	if (claim.outcome === "quota_exhausted") return { ok: false, reason: "quota_exhausted" };
	if (claim.outcome === "invalid_state") return { ok: false, reason: "invalid_state" };
	if (claim.outcome === "invalid_input") return { ok: false, reason: "bad_request" };
	if (!claim.meetup_id || !claim.attempt_number || !claim.status) return internalReason;

	// A competing request has already claimed this meetup. It must not invoke
	// the generator a second time or consume another billing unit. Re-read the
	// exact relationship before exposing even this replay status.
	if (claim.outcome !== "claimed") {
		if (!isArrangementWorkingStatus(claim.status)) return { ok: false, reason: "invalid_state" };
		const replayAccess = await revalidateMeetupAccess(client, binding);
		if (replayAccess.ok === false) return replayAccess;
		if (replayAccess.value.meetup.status !== claim.status) return { ok: false, reason: "invalid_state" };
		return {
			ok: true,
			status: claim.status,
			billingSource: claim.billing_source,
		};
	}

	// The successful claim must still point to the same exact relationship
	// before allow-listed scheduling data is read or a model is invoked.
	const afterClaim = await revalidateMeetupAccess(client, binding);
	if (afterClaim.ok === false) return afterClaim;
	if (afterClaim.value.meetup.status !== "arranging") return { ok: false, reason: "invalid_state" };

	const scheduling = await loadSchedulingContext(client, meetupId, userId);
	if (scheduling.ok === false) {
		// Keep the claim's state machine truthful if the allow-listed read path
		// cannot be completed, but only after another current-access check. Passing
		// null asks the persistence RPC to make the one expected arranging ->
		// arrange_failed transition; it never carries proposal content.
		const beforeContextFailure = await revalidateMeetupAccess(client, binding);
		if (beforeContextFailure.ok === false) return beforeContextFailure;
		if (beforeContextFailure.value.meetup.status !== "arranging") return { ok: false, reason: "invalid_state" };
		const failed = await persistArrangement(client, userId, meetupId, claim.attempt_number, null);
		if (!failed) return internalReason;
		if (!isArrangementPersistenceRowConsistent(failed, binding.meetupId, binding.matchId, claim.attempt_number)) return internalReason;
		const afterFailurePersist = await revalidateMeetupAccess(client, binding);
		if (afterFailurePersist.ok === false) return afterFailurePersist;
		if (failed.outcome === "arrange_failed" && afterFailurePersist.value.meetup.status !== "arrange_failed") return { ok: false, reason: "invalid_state" };
		if (failed.outcome === "already_failed" && afterFailurePersist.value.meetup.status !== "arrange_failed") return { ok: false, reason: "invalid_state" };
		if (failed.outcome === "proposed" || failed.outcome === "already_proposed") return internalReason;
		if (failed.outcome === "not_found" || failed.outcome === "blocked") return notFoundReason;
		if (failed.outcome === "identity_verification_required") return { ok: false, reason: "identity_verification_required" };
		if (failed.outcome === "invalid_state") return { ok: false, reason: "invalid_state" };
		if (failed.outcome === "invalid_input") return { ok: false, reason: "bad_request" };
		if (failed.outcome !== "arrange_failed" && failed.outcome !== "already_failed") return internalReason;
		return {
			ok: true,
			status: failed.status === "arrange_failed" ? "arrange_failed" : "arranging",
			billingSource: claim.billing_source,
		};
	}

	// The allow-listed context is assembled through several awaits. Revalidate
	// immediately before handing it to the provider, and require that its
	// relationship still matches the original binding.
	const beforeProvider = await revalidateMeetupAccess(client, binding);
	if (beforeProvider.ok === false) return beforeProvider;
	if (beforeProvider.value.meetup.status !== "arranging") return { ok: false, reason: "invalid_state" };
	if (
		scheduling.value.matchId !== binding.matchId ||
		!sameParticipantOrder(scheduling.value.participantIds, binding.participantIds)
	) {
		return notFoundReason;
	}

	let generated: unknown = null;
	try {
		generated = await dependencies.generator.generate(scheduling.value.input);
	} catch {
		generated = null;
	}

	// A provider result, including a thrown/empty result, is usable only if the
	// same relationship is still authorized after the await.
	const afterGenerator = await revalidateMeetupAccess(client, binding);
	if (afterGenerator.ok === false) return afterGenerator;
	if (afterGenerator.value.meetup.status !== "arranging") return { ok: false, reason: "invalid_state" };
	if (
		scheduling.value.matchId !== binding.matchId ||
		!sameParticipantOrder(scheduling.value.participantIds, binding.participantIds)
	) {
		return notFoundReason;
	}

	const validated = validateGeneratedCandidates(generated, now);
	// Keep this read immediately adjacent to persistence. It catches a
	// revocation that happens while validation runs and prevents a valid model
	// result from becoming a proposal after access has ended.
	const beforePersist = await revalidateMeetupAccess(client, binding);
	if (beforePersist.ok === false) return beforePersist;
	if (beforePersist.value.meetup.status !== "arranging") return { ok: false, reason: "invalid_state" };
	const persisted = await persistArrangement(client, userId, meetupId, claim.attempt_number, validated);
	if (!persisted) return internalReason;
	if (!isArrangementPersistenceRowConsistent(persisted, binding.meetupId, binding.matchId, claim.attempt_number)) return internalReason;
	if (validated === null && persisted.outcome === "proposed") return internalReason;

	// Persistence is a separate await and can race with a block, preference,
	// room, or match change. Suppress both the result and its notification
	// context if the final access check fails.
	const afterPersist = await revalidateMeetupAccess(client, binding);
	if (afterPersist.ok === false) return afterPersist;

	if (persisted.outcome === "proposed") {
		if (!persisted.proposal_id) return internalReason;
		if (afterPersist.value.meetup.status !== "proposed") return { ok: false, reason: "invalid_state" };
		return {
			ok: true,
			status: "proposed",
			billingSource: claim.billing_source,
			notificationContexts: [
				arrangementContext("N-05", scheduling.value, meetupId, persisted.proposal_id),
			],
		};
	}
	if (persisted.outcome === "already_proposed") {
		if (afterPersist.value.meetup.status !== "proposed") return { ok: false, reason: "invalid_state" };
		return { ok: true, status: "proposed", billingSource: claim.billing_source };
	}
	if (persisted.outcome === "arrange_failed") {
		if (afterPersist.value.meetup.status !== "arrange_failed") return { ok: false, reason: "invalid_state" };
		return {
			ok: true,
			status: "arrange_failed",
			billingSource: claim.billing_source,
			notificationContexts: [arrangementContext("N-14", scheduling.value, meetupId)],
		};
	}
	if (persisted.outcome === "already_failed") {
		if (afterPersist.value.meetup.status !== "arrange_failed") return { ok: false, reason: "invalid_state" };
		return { ok: true, status: "arrange_failed", billingSource: claim.billing_source };
	}
	if (persisted.outcome === "identity_verification_required") return { ok: false, reason: "identity_verification_required" };
	if (persisted.outcome === "not_found" || persisted.outcome === "blocked") return notFoundReason;
	if (persisted.outcome === "invalid_state") return { ok: false, reason: "invalid_state" };
	return internalReason;
}

export async function arrangeMeetup(
	client: SupabaseClient<Database>,
	userId: string,
	meetupId: string,
	generatorOrOptions?: ProposalGenerator | ArrangementOptions,
	options?: ArrangementOptions,
): Promise<MeetupArrangeResult> {
	return arrangeMeetupInternal(client, userId, meetupId, false, generatorOrOptions, options);
}

export async function retryMeetupArrangement(
	client: SupabaseClient<Database>,
	userId: string,
	meetupId: string,
	generatorOrOptions?: ProposalGenerator | ArrangementOptions,
	options?: ArrangementOptions,
): Promise<MeetupArrangeResult> {
	return arrangeMeetupInternal(client, userId, meetupId, true, generatorOrOptions, options);
}

/** Alias retained for callers that use the endpoint name as the service name. */
export const retryMeetup = retryMeetupArrangement;

type ResponseRpcResult = z.infer<typeof proposalResponseRpcRowSchema>;

export async function recordMeetupProposalResponse(
	client: SupabaseClient<Database>,
	userId: string,
	meetupId: string,
	proposalId: string,
	selectedCandidateIndex: number,
): Promise<MeetupProposalResponseResult> {
	if (
		!uuidSchemaLike(meetupId) ||
		!uuidSchemaLike(proposalId) ||
		!Number.isInteger(selectedCandidateIndex) ||
		selectedCandidateIndex < 0 ||
		selectedCandidateIndex > 2
	) {
		return { ok: false, reason: "bad_request" };
	}

	const authorized = await authorizeMeetup(client, meetupId, userId);
	if (authorized.ok === false) return authorized;
	const identity = await checkIdentityForMatch(client, [authorized.value.match.user_a_id, authorized.value.match.user_b_id]);
	if (identity === "internal") return internalReason;
	if (identity === "unverified") return { ok: false, reason: "identity_verification_required" };

	let result: RpcRowResult;
	try {
		result = await asMeetupClient(client).rpc("record_meetup_proposal_response", {
			p_meetup_id: meetupId,
			p_proposal_id: proposalId,
			p_user_id: userId,
			p_candidate_index: selectedCandidateIndex,
		});
	} catch {
		return internalReason;
	}
	if (!isQueryResult(result) || result.error || !Array.isArray(result.data) || result.data.length !== 1) return internalReason;
	const parsed = proposalResponseRpcRowSchema.safeParse(result.data[0]);
	if (parsed.success === false) return internalReason;
	const response: ResponseRpcResult = parsed.data;
	if (response.meetup_id !== meetupId || response.proposal_id !== proposalId) return internalReason;

	if (response.outcome === "accepted") return { ok: true, status: "proposed" };
	if (response.outcome === "confirmed") {
		if (response.confirmed_candidate_index === null) return internalReason;
		return {
			ok: true,
			status: "confirmed",
			notificationContexts: [
				{
					scenarioId: "N-06",
					meetupId,
					matchId: authorized.value.match.id,
					recipientIds: [authorized.value.match.user_a_id, authorized.value.match.user_b_id],
				},
			],
		};
	}
	if (response.outcome === "identity_verification_required") return { ok: false, reason: "identity_verification_required" };
	if (response.outcome === "blocked" || response.outcome === "not_found") return notFoundReason;
	if (response.outcome === "expired" || response.outcome === "invalid_state") return { ok: false, reason: "invalid_state" };
	if (response.outcome === "invalid_input") return { ok: false, reason: "bad_request" };
	return internalReason;
}

function uuidSchemaLike(value: string): boolean {
	return z.string().uuid().safeParse(value).success;
}
