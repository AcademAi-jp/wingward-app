import { Hono } from "hono";
import type { Env } from "../env";
import { getAgeVerificationStatus, resolveAuthUser } from "../middleware/auth";
import { getSupabaseClient } from "../db/client";
import { checkFoxConversationParticipant, type ParticipantCheckResult } from "../services/fox-conversation-access";

const foxSearchWs = new Hono<Env>();

/**
 * Subprotocol carrying the Supabase JWT (RFC 6455 §4.1's `Sec-WebSocket-Protocol`).
 * See docs/spec/impl/step-03-lazy-generation.md §4-C-2 for why this is the
 * chosen mechanism over a `?token=` query string (long-lived JWT in access
 * logs) or a short-lived ticket (needs a new secret).
 */
const JWT_PROTOCOL_PREFIX = "wingward.jwt.";

/**
 * G4 (step-3 §4-C-1): the web client reconnects on every rejection. Without
 * this cache, a client stuck in a reconnect loop (e.g. a stale/expired token
 * it keeps retrying, or hammering another user's conversation id) would hit
 * Supabase on every attempt. 60s, keyed by conversationId+userId so it can
 * never leak across users.
 *
 * F2 (step-3c review): `conversationId` is arbitrary client input and
 * negative results are cached too (intentionally — that's what protects
 * G4), so without a bound any authenticated caller could grow this
 * module-global Map without limit by varying conversationId across
 * requests. `PARTICIPANT_CACHE_MAX_ENTRIES` caps it; `evictForInsert` first
 * reclaims anything already expired, then falls back to evicting the
 * oldest insertions (Map preserves insertion order) if expired entries
 * alone weren't enough room. This is a bound, not a true LRU — sufficient
 * to turn "unbounded" into "capped", which is what the finding asked for.
 *
 * (`authCache` in middleware/auth.ts has a similar unbounded-Map shape;
 * left untouched here as a follow-up, per the requested scope for this PR.)
 */
const PARTICIPANT_CACHE_TTL_MS = 60_000;
const PARTICIPANT_CACHE_MAX_ENTRIES = 1000;
const participantCache = new Map<string, { result: ParticipantCheckResult; expiresAt: number }>();

function evictForInsert(): void {
	if (participantCache.size < PARTICIPANT_CACHE_MAX_ENTRIES) return;

	const now = Date.now();
	for (const [key, entry] of participantCache) {
		if (entry.expiresAt <= now) participantCache.delete(key);
	}

	while (participantCache.size >= PARTICIPANT_CACHE_MAX_ENTRIES) {
		const oldestKey = participantCache.keys().next().value;
		if (oldestKey === undefined) break;
		participantCache.delete(oldestKey);
	}
}

function extractJwtFromProtocolHeader(header: string | undefined | null): string | null {
	if (!header) return null;
	// Sec-WebSocket-Protocol may list multiple comma-separated candidate
	// values; the client only ever offers one.
	for (const raw of header.split(",")) {
		const value = raw.trim();
		if (value.startsWith(JWT_PROTOCOL_PREFIX)) {
			const token = value.slice(JWT_PROTOCOL_PREFIX.length);
			if (token.length > 0) return token;
		}
	}
	return null;
}

async function checkParticipantCached(
	supabase: ReturnType<typeof getSupabaseClient>,
	conversationId: string,
	userId: string,
): Promise<ParticipantCheckResult> {
	const cacheKey = `${conversationId}:${userId}`;
	const cached = participantCache.get(cacheKey);
	if (cached) {
		// A successful entry must be re-read: counterpart age verification can
		// be revoked while a socket is reconnecting. Negative entries remain
		// cached to protect the edge from invalid-id hammering.
		if (cached.expiresAt > Date.now() && !cached.result.ok) return cached.result;
		participantCache.delete(cacheKey); // reclaim eagerly instead of only on eviction
	}

	const result = await checkFoxConversationParticipant(supabase, conversationId, userId);
	evictForInsert();
	participantCache.set(cacheKey, { result, expiresAt: Date.now() + PARTICIPANT_CACHE_TTL_MS });
	return result;
}

/**
 * GET /api/fox-search/ws/:conversationId — WebSocket upgrade, proxied to DO.
 *
 * Authenticates and authorizes BEFORE calling `idFromName` — that ordering
 * is the entire point of gap G2 (step-3 §4-C-1): calling `idFromName` for an
 * unauthenticated request lets anyone spin up unlimited Durable Object
 * instances (a Cloudflare billing concern), and no amount of in-band
 * authentication afterward undoes that the DO is already running.
 */
foxSearchWs.get("/ws/:conversationId", async (c) => {
	const upgradeHeader = c.req.header("Upgrade");
	if (upgradeHeader?.toLowerCase() !== "websocket") {
		return c.text("Expected WebSocket Upgrade", 426);
	}

	const protocolHeader = c.req.header("Sec-WebSocket-Protocol");
	const token = extractJwtFromProtocolHeader(protocolHeader);
	if (!token) {
		return c.text("Unauthorized", 401);
	}
	// The exact single value we're about to select out of the client's
	// (possibly multi-valued) offer. RFC 6455 §4.1 requires the server to
	// echo exactly one of the offered values; forwarding this precomputed
	// value to the DO means it only ever echoes what the edge selected,
	// never the raw (possibly comma-joined) header (see F1, step-3c review).
	const selectedProtocol = `${JWT_PROTOCOL_PREFIX}${token}`;

	const authResult = await resolveAuthUser(c, token);
	if (!authResult) {
		return c.text("Unauthorized", 401);
	}
	const userId = authResult.userId;
	const ageStatus = await getAgeVerificationStatus(c, userId);
	if (ageStatus === "error") {
		return c.text("Internal server error", 500);
	}
	if (ageStatus === "unverified") {
		return c.text("Age verification required", 403);
	}

	const conversationId = c.req.param("conversationId");
	const supabase = getSupabaseClient(c.env);
	const access = await checkParticipantCached(supabase, conversationId, userId);
	if (access.ok === false) {
		// Generic body only — no internal state (§5).
		return access.reason === "not_found" ? c.text("Not found", 404) : c.text("Forbidden", 403);
	}

	const doNs = c.env.FOX_CONVERSATION;
	if (!doNs) {
		return c.text("Durable Objects not available", 503);
	}

	const doId = doNs.idFromName(conversationId);
	const stub = doNs.get(doId);

	// Forward the WebSocket upgrade request to the DO, plus the verified
	// user id. The DO is only reachable through this Worker (not directly
	// addressable by a client), so this internal header can be trusted by
	// the DO without re-verifying the JWT itself.
	const forwardHeaders = new Headers(c.req.raw.headers);
	forwardHeaders.set("X-Verified-User-Id", userId);
	forwardHeaders.set("X-Verified-Ws-Protocol", selectedProtocol);

	return stub.fetch(
		new Request("https://do/ws", {
			headers: forwardHeaders,
		}),
	);
});

export default foxSearchWs;

/** Test-only visibility into the module-private participant cache (F2 coverage). */
export const __testing = {
	PARTICIPANT_CACHE_MAX_ENTRIES,
	participantCacheSize: () => participantCache.size,
};
