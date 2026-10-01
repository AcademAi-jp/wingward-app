import { DurableObject } from "cloudflare:workers";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { runConversationLoop } from "../services/fox-conversation-engine";
import {
	checkFoxConversationCurrentAccess,
	isFoxConversationAccessError,
	FoxConversationAccessError,
	type FoxConversationAccessExpectation,
} from "../services/fox-conversation-access";
import { notifyFoxConversationCompleted } from "../services/notification-triggers";
import { resolveFoxConversationGenerationWindow, isFoxConversationGenerationAllowed } from "../services/fox-conversation-recording-window";
import type { DemoJudgeBindings } from "../services/demo-judge-window";
import type { RecordingRehearsalBindings } from "../services/recording-rehearsal";
import type {
	ServerMessage,
	ClientMessage,
	WsStateMessage,
	WsRoundMessage,
} from "./types";

/**
 * Production entry point for a fox conversation. Scheduling, WebSocket
 * broadcast, and start/failure bookkeeping only — the conversation loop
 * itself (round generation, scoring, 3-layer compatibility, token
 * accounting) lives in ../services/fox-conversation-engine.ts, the single
 * implementation shared with the local-dev fallback (../services/
 * fox-conversation.ts). See docs/spec/impl/step-03d-unify-conversation-loop.md.
 */

/**
 * Rounds advanced per `alarm()` invocation. Workers Free plan caps subrequests
 * at 50 per invocation. The current-access gate uses one PostgREST resource
 * embedding read with the existing foreign-key hints: `fox_conversations` ->
 * `matches!fox_conversations_match_id_fkey!inner` -> the required
 * `user_profiles` rows and left-embedded `blocks!blocks_blocker_id_fkey` rows.
 *
 * The focused Durable Object fake, using the real Supabase JS client and
 * `fetch`, measures 22 Supabase HTTP dispatches plus one model attempt for a
 * one-round rounds-only invocation, and 29 dispatches plus one model attempt
 * for a scoring-only invocation (the fake deliberately exercises simple-score
 * fallback). A four-round conversation therefore advances over four separate
 * rounds-only alarms before a scoring alarm; the per-invocation measurements
 * and the no-duplicate-round assertions are recorded in
 * `fox-conversation-transport-budget.test.ts`. Retries add attempts and
 * dispatches, and notification has its own alarm invocation.
 *
 * `MAX_ROUNDS_PER_ALARM` is a work-shaping bound. These Node test-double
 * measurements do not prove the Cloudflare Worker runtime's actual
 * subrequest enforcement or account-plan behavior; production Worker evidence
 * remains an explicit gap. The fail-closed access rechecks remain required for
 * output and cleanup safety.
 */
const MAX_ROUNDS_PER_ALARM = 1;

interface DOState {
	conversationId: string;
	matchId: string;
	userA: string;
	userB: string;
	// `notifying` is a terminal-but-one state: the conversation is finished
	// and every DB write for it is done; all that remains is N-01, which gets
	// its own alarm invocation so it never shares the loop's subrequest
	// budget. See alarm().
	status: "in_progress" | "notifying" | "completed" | "failed";
}

type FoxConversationFailureExpectation = Pick<DOState, "conversationId" | "matchId" | "userA" | "userB">;

/**
 * Best-effort terminal cleanup scoped to the exact conversation/match pair.
 * The status predicates are the important backstop: a stale alarm must not
 * overwrite a row that has already moved to a newer terminal state or been
 * reassigned. This remains a conditional write, not a claim of SQL-level
 * serialization; callers still perform a fresh access check immediately
 * before invoking it.
 */
async function markConversationFailureIfActive(
	supabase: SupabaseClient<Database>,
	expected: FoxConversationFailureExpectation,
): Promise<void> {
	const [{ error: conversationFailureError }, { error: matchFailureError }] = await Promise.all([
		supabase
			.from("fox_conversations")
			.update({ status: "failed" })
			.eq("id", expected.conversationId)
			.eq("match_id", expected.matchId)
			.in("status", ["pending", "in_progress"]),
		supabase
			.from("matches")
			.update({ status: "fox_conversation_failed" })
			.eq("id", expected.matchId)
			.eq("user_a_id", expected.userA)
			.eq("user_b_id", expected.userB)
			.eq("status", "fox_conversation_in_progress"),
	]);

	if (conversationFailureError || matchFailureError) {
		console.error("[FoxConversationDO:fail] Failed to persist failure state");
		throw new Error("Failed to persist conversation failure state");
	}
}

interface DOEnv extends RecordingRehearsalBindings, DemoJudgeBindings {
	JUDGE_ACCESS_ENABLED?: string;
	JUDGE_ACCESS_COHORT?: string;
	JUDGE_ACCESS_ISSUED_AT?: string;
	JUDGE_ACCESS_EXPIRES_AT?: string;
	JUDGE_ACCESS_AI_EXPIRES_AT?: string;
	SUPABASE_URL: string;
	SUPABASE_SERVICE_ROLE_KEY: string;
	MISTRAL_API_KEY?: string;
	// Needed for N-01 on the completion path. Optional like the others: an
	// unconfigured OneSignal makes sendNotification return not_configured,
	// which the trigger logs and moves on from, rather than failing the
	// conversation that just succeeded.
	ONESIGNAL_APP_ID?: string;
	ONESIGNAL_API_KEY?: string;
}

export class FoxConversationDO extends DurableObject<DOEnv> {
	private getSupabase(): SupabaseClient<Database> {
		return createClient<Database>(
			this.env.SUPABASE_URL,
			this.env.SUPABASE_SERVICE_ROLE_KEY,
			{ auth: { persistSession: false } },
		);
	}

	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);
		console.log(`[FoxConversationDO:fetch] ${request.method} ${url.pathname}`);

		if (request.method === "POST" && url.pathname === "/init") {
			return this.handleInit(request);
		}

		if (url.pathname === "/ws") {
			return this.handleWebSocketUpgrade(request);
		}

		return new Response("Not Found", { status: 404 });
	}

	// ── /init: Validate match/personas, save state, and schedule the alarm ──

	private async handleInit(request: Request): Promise<Response> {
		const { conversationId, matchId, staggerDelayMs } = (await request.json()) as {
			conversationId: string;
			matchId: string;
			staggerDelayMs?: number;
		};

		console.log(`[FoxConversationDO:init] START conversationId=${conversationId} matchId=${matchId}`);

		const supabase = this.getSupabase();

		// Load match participants
		const { data: match, error: matchError } = await supabase
			.from("matches")
			.select("id, user_a_id, user_b_id, status")
			.eq("id", matchId)
			.single();
		if (matchError || !match) {
			console.error("[FoxConversationDO:init] Match lookup failed");
			return new Response("Match not found", { status: 404 });
		}
		console.log("[FoxConversationDO:init] Match loaded");

		const generationWindow = await resolveFoxConversationGenerationWindow(
			supabase,
			this.env,
			match.user_a_id,
			match.user_b_id,
		);
		const accessExpectation: FoxConversationAccessExpectation = {
			conversationId,
			matchId,
			userA: match.user_a_id,
			userB: match.user_b_id,
			generationWindow,
		};
		const currentAccess = await checkFoxConversationCurrentAccess(supabase, accessExpectation, "active");
		if (currentAccess.ok === false) {
			console.error("[FoxConversationDO:init] Current conversation access denied");
			const status = currentAccess.reason === "error" ? 500 : 404;
			return new Response(status === 500 ? "Failed to verify conversation" : "Match not found", {
				status,
			});
		}

		// Validate personas exist up front so /init can return a synchronous
		// 400 instead of only discovering this later inside the alarm (the
		// engine performs this same check again when it actually runs, since
		// it is the single owner of "what does the loop need to start" — this
		// is a fast-fail duplicate, not the source of truth).
		const [{ data: personaA, error: personaAError }, { data: personaB, error: personaBError }] = await Promise.all([
			supabase
				.from("personas")
				.select("compiled_document")
				.eq("user_id", match.user_a_id)
				.eq("persona_type", "wingfox")
				.single(),
			supabase
				.from("personas")
				.select("compiled_document")
				.eq("user_id", match.user_b_id)
				.eq("persona_type", "wingfox")
				.single(),
		]);

		if (personaAError || personaBError || !personaA?.compiled_document || !personaB?.compiled_document) {
			console.error("[FoxConversationDO:init] Persona lookup failed");
			const latestAccess = await checkFoxConversationCurrentAccess(supabase, accessExpectation, "active");
			if (latestAccess.ok) {
				try {
					await markConversationFailureIfActive(supabase, accessExpectation);
				} catch {
					console.error("[FoxConversationDO:init] Failed to persist persona failure state");
					return new Response("Failed to persist failure state", { status: 500 });
				}
			}
			return new Response("Persona not found", { status: 400 });
		}
		console.log(`[FoxConversationDO:init] Personas loaded conversationId=${conversationId}`);
		const beforeStartAccess = await checkFoxConversationCurrentAccess(supabase, accessExpectation, "active");
		if (beforeStartAccess.ok === false) {
			console.error("[FoxConversationDO:init] Current conversation access denied before start write");
			const status = beforeStartAccess.reason === "error" ? 500 : 404;
			return new Response(status === 500 ? "Failed to verify conversation" : "Match not found", { status });
		}

		// Update conversation status
		const { error: inProgressError } = await supabase
			.from("fox_conversations")
			.update({ status: "in_progress", started_at: new Date().toISOString() })
			.eq("id", conversationId)
			.eq("match_id", matchId)
			.in("status", ["pending", "in_progress"])
			.select("id")
			.single();
		if (inProgressError) {
			console.error("[FoxConversationDO:init] Failed to persist conversation start");
			return new Response("Failed to start conversation", { status: 500 });
		}

		// Save state to durable storage
		const state: DOState = {
			conversationId,
			matchId,
			userA: match.user_a_id,
			userB: match.user_b_id,
			status: "in_progress",
		};
		await this.ctx.storage.put("state", state);

		// Start alarm with optional stagger delay
		const delay = staggerDelayMs ?? 0;
		await this.ctx.storage.setAlarm(Date.now() + delay);
		console.log(`[FoxConversationDO:init] DONE state saved, alarm set delay=${delay}ms conversationId=${conversationId}`);

		return new Response("OK", { status: 200 });
	}

	// ── Alarm: run the whole conversation loop once, via the shared engine ──

	async alarm(): Promise<void> {
		const state = await this.ctx.storage.get<DOState>("state");

		// N-01 runs in its OWN invocation, never sharing one with the
		// conversation loop. Keep N-01 in its own invocation because its lookup,
		// per-participant notification work, retries, and provider behavior are
		// separate from the scoring path. The transport test's 29-dispatch
		// scoring measurement covers only the synthetic no-credentials fallback;
		// it does not prove the Cloudflare Worker cap or the configured
		// OneSignal send path. This is the same rule step 3-D established for
		// scoring versus round generation: isolate the expensive work instead of
		// relying on a combined test-double arithmetic claim.
		//
		// The status is advanced to `completed` BEFORE notifying, so a failure
		// inside the notify path cannot leave this DO rescheduling forever.
		// Losing the notification is the correct trade against looping.
		if (state?.status === "notifying") {
			state.status = "completed";
			await this.ctx.storage.put("state", state);
			await notifyFoxConversationCompleted(
				{ supabase: this.getSupabase(), env: this.env },
				{ conversationId: state.conversationId, matchId: state.matchId },
			);
			console.log(`[FoxConversationDO:alarm] NOTIFIED conversationId=${state.conversationId}`);
			return;
		}

		if (!state || state.status !== "in_progress") {
			console.log(`[FoxConversationDO:alarm] SKIP state=${state?.status ?? "no state"}`);
			return;
		}

		const supabase = this.getSupabase();

		const apiKey = this.env.MISTRAL_API_KEY;
		if (!apiKey) {
			console.error(`[FoxConversationDO:alarm] MISTRAL_API_KEY not configured conversationId=${state.conversationId}`);
			await this.failConversation(supabase, state, "Conversation unavailable");
			return;
		}

		const generationWindow = await resolveFoxConversationGenerationWindow(supabase, this.env, state.userA, state.userB);
		const accessExpectation: FoxConversationAccessExpectation = {
			conversationId: state.conversationId,
			matchId: state.matchId,
			userA: state.userA,
			userB: state.userB,
			generationWindow,
		};

		console.log(`[FoxConversationDO:alarm] START conversationId=${state.conversationId}`);
		try {
			// The registered path's engine rechecks the exact conversation tuple
			// and SQL registry before doing any paid work. Avoid a duplicate
			// embedding read here so its full scoring alarm stays within budget.
			if (generationWindow.kind !== "registered-judge") {
				const beforeLoopAccess = await checkFoxConversationCurrentAccess(supabase, accessExpectation, "active");
				if (beforeLoopAccess.ok === false) throw new FoxConversationAccessError();
			}

			const result = await runConversationLoop({
				supabase,
				apiKey,
				conversationId: state.conversationId,
				generationWindow,
				maxRoundsPerRun: MAX_ROUNDS_PER_ALARM,
				onRound: async (round, speaker, content) => {
					const currentAccess = await checkFoxConversationCurrentAccess(supabase, accessExpectation, "active");
					if (!currentAccess.ok) throw new FoxConversationAccessError();
					const roundMsg: WsRoundMessage = {
						type: "round_message",
						round_number: round,
						speaker,
						content,
					};
					this.broadcast(roundMsg);
				},
			});

			if (result.incomplete) {
				// Budget for this invocation is spent but rounds remain. The
				// engine has already persisted the token spend accumulated so
				// far and has NOT touched fox_conversations/matches' terminal
				// status, so the DO's job here is scheduling only: leave state
				// as in_progress and reschedule another alarm to resume. Same
				// delay window as the engine's own inter-round sleep.
				console.log(`[FoxConversationDO:alarm] INCOMPLETE (budget spent, rescheduling) conversationId=${state.conversationId}`);
				await this.ctx.storage.setAlarm(Date.now() + (generationWindow.kind === "registered-judge" ? 1000 : 500) + Math.floor(Math.random() * 500));
				return;
			}

			if (result.failedBeforeStart) {
				// The engine already decided this conversation cannot run at all
				// (e.g. persona missing) and, per its own contract, has already
				// written whatever failure state it owns. Route it through
				// failConversation anyway so the DO's local state, the matches
				// row, and the WebSocket error broadcast all still happen —
				// this is the same "single place that fails things" as a thrown
				// error, just reached via a non-throwing result.
				await this.failConversation(supabase, state, "Conversation could not start (see engine logs)");
				return;
			}

			// `notifying`, not `completed`: the conversation is finished and every
			// database write for it is done, but N-01 still has to go out and it
			// gets its own alarm invocation (see the top of alarm()). The DO's
			// own WebSocket clients are told below, right now, exactly as before
			// — this state only governs which alarm branch runs next.
			state.status = "notifying";
			await this.ctx.storage.put("state", state);

			const outputWindow = generationWindow.kind === "registered-judge"
				? await resolveFoxConversationGenerationWindow(supabase, this.env, state.userA, state.userB)
				: generationWindow;
			const completedAccess = await checkFoxConversationCurrentAccess(supabase, { ...accessExpectation, generationWindow: outputWindow }, "completed");
			if (!result.outputSuppressed && completedAccess.ok
				&& (generationWindow.kind !== "registered-judge" || isFoxConversationGenerationAllowed(outputWindow, state.userA, state.userB))) {
				this.broadcast({
					type: "completed",
					scores: { conversation_score: result.conversationScore, final_score: result.finalScore },
					analysis: result.analysis,
				});
			} else {
				console.warn(`[FoxConversationDO:alarm] Completed output suppressed conversationId=${state.conversationId}`);
			}

			// N-01's trigger is exactly this moment — the conversation reached a
			// terminal completed state — but the send itself is handed to a
			// fresh invocation via the `notifying` status above, so it never
			// shares this one's subrequest budget. The WebSocket client has
			// already been told at the same instant it always was; only the
			// push is deferred, by well under a second.
			//
			// There is deliberately no equivalent in failConversation: no
			// scenario covers "your Fox found nothing", and inventing one here
			// would ship a push no spec describes.
			//
			// Its own try/catch, NOT the outer one (Codex P1, review round 2).
			// By this line the conversation is already persisted as completed
			// and the clients have already been told so. If this scheduling
			// call rejected inside the generic catch below, failConversation
			// would overwrite both database statuses to failed and broadcast an
			// error — reversing a conversation that genuinely succeeded, and
			// contradicting a broadcast the clients already acted on. Losing
			// the push is the only acceptable cost of a scheduling failure.
			try {
				await this.ctx.storage.setAlarm(Date.now());
			} catch {
				console.error(`[FoxConversationDO:alarm] could not schedule the N-01 notify invocation; completed conversationId=${state.conversationId}`);
			}

			console.log(`[FoxConversationDO:alarm] DONE conversationId=${state.conversationId} finalScore=${result.finalScore}`);
		} catch (err) {
			console.error(
				`[FoxConversationDO:alarm] ERROR conversationId=${state.conversationId}${isFoxConversationAccessError(err) ? " current access denied" : ""}`,
			);
			await this.failConversation(supabase, state, "Conversation unavailable");
		}
	}

	private async failConversation(
		supabase: SupabaseClient<Database>,
		state: DOState,
		_reason: string,
	): Promise<void> {
		console.error(`[FoxConversationDO:fail] conversationId=${state.conversationId} matchId=${state.matchId}`);
		const failureAccess = await checkFoxConversationCurrentAccess(
			supabase,
			{
				conversationId: state.conversationId,
				matchId: state.matchId,
				userA: state.userA,
				userB: state.userB,
				generationWindow: await resolveFoxConversationGenerationWindow(supabase, this.env, state.userA, state.userB),
			},
			"active",
		);
		if (failureAccess.ok) {
			this.broadcast({ type: "error", message: "Conversation unavailable" });

			// Token columns are deliberately NOT touched here. The engine persists
			// whatever it accumulated onto fox_conversations' input_tokens/
			// output_tokens/cache_hit_tokens before it ever throws or returns
			// failedBeforeStart (see fox-conversation-engine.ts's outer try/catch),
			// so this only has to record the terminal status. A denied or unreadable
			// current-access check leaves the rows alone; it cannot safely distinguish
			// a revocation from a newer terminal/reassigned attempt.
			await markConversationFailureIfActive(supabase, {
				conversationId: state.conversationId,
				matchId: state.matchId,
				userA: state.userA,
				userB: state.userB,
			});
		}
		state.status = "failed";
		await this.ctx.storage.put("state", state);
	}

	// ── WebSocket Hibernation API ──
	//
	// Authentication happens entirely at the edge (routes/fox-search-ws.ts)
	// before this DO is ever reached — there is no in-band `auth` message.
	// The edge passes the verified `user_profiles.id` via the
	// `X-Verified-User-Id` header on the forwarded upgrade request; this DO
	// is only reachable through that Worker, so the header can be trusted.
	//
	// `resolveWsAccess` is kept separate from `handleWebSocketUpgrade` so it
	// can be unit-tested without `WebSocketPair`, which isn't available
	// under plain vitest (see fox-conversation-do-wiring.test.ts).

	/**
	 * Gap G1 (step-3 §4-C-1), fixed fail-closed: reject whenever `state` is
	 * missing, not just when it contradicts the verified user. The previous
	 * shape (`if (state && A && B)`) skipped the whole check — and therefore
	 * granted access — for any DO that never got a `state` written (e.g.
	 * `/init` returning early on a missing persona). This check stays even
	 * though the edge now authorizes first, as defense in depth (§4-C-3-2).
	 *
	 * C2 (step-3c review, Codex P2): this used to also build the catch-up
	 * snapshot, which meant that work (two Supabase queries) happened BEFORE
	 * `acceptWebSocket()`. `alarm()`'s `broadcast()` doesn't hold the DO's
	 * input gate, so a round could broadcast during those queries; since the
	 * socket wasn't registered yet, `broadcast()` silently skipped it, and
	 * the snapshot already read predated the event — the round was lost
	 * permanently (worse than the pre-step-3c in-band-auth code, where the
	 * socket was already accepted before catch-up was read, so the same race
	 * only ever produced a recoverable duplicate). This function now only
	 * makes the authorization decision; `handleWebSocketUpgrade` builds and
	 * sends catch-up AFTER `acceptWebSocket()`, reintroducing the possible
	 * duplicate on purpose — the client dedupes on `round_number` instead
	 * (useFoxSearchWebSocket.ts).
	 */
	private async resolveWsAccess(
		verifiedUserId: string | null,
	): Promise<{ authorized: false } | { authorized: true; userId: string; state: DOState }> {
		if (!verifiedUserId) {
			return { authorized: false };
		}

		const state = await this.ctx.storage.get<DOState>("state");
		if (!state || (verifiedUserId !== state.userA && verifiedUserId !== state.userB)) {
			console.warn(`[FoxConversationDO:ws] Access denied hasState=${!!state}`);
			return { authorized: false };
		}

		const generationWindow = await resolveFoxConversationGenerationWindow(this.getSupabase(), this.env, state.userA, state.userB);
		const expectation: FoxConversationAccessExpectation = {
			conversationId: state.conversationId,
			matchId: state.matchId,
			userA: state.userA,
			userB: state.userB,
			generationWindow,
		};
		const mode = state.status === "notifying" || state.status === "completed" ? "completed" : "active";
		const currentAccess = await checkFoxConversationCurrentAccess(this.getSupabase(), expectation, mode);
		if (!currentAccess.ok) {
			console.warn("[FoxConversationDO:ws] Current conversation access denied");
			return { authorized: false };
		}

		return { authorized: true, userId: verifiedUserId, state };
	}

	/**
	 * Catch-up state. DOState no longer carries message history or
	 * round/total counts (step-03d removed the DO-side duplicate of the
	 * conversation record) — `fox_conversation_messages` and
	 * `fox_conversations.total_rounds` are the single source of truth, the
	 * same one the engine itself reads from.
	 */
	private async buildCatchUpMessage(state: DOState): Promise<WsStateMessage> {
		const supabase = this.getSupabase();
		const [{ data: messages, error: messagesError }, { data: convRow, error: convError }] = await Promise.all([
			supabase
				.from("fox_conversation_messages")
				.select("speaker_user_id, content, round_number")
				.eq("conversation_id", state.conversationId)
				.order("round_number"),
			supabase
				.from("fox_conversations")
				.select("total_rounds")
				.eq("id", state.conversationId)
				.single(),
		]);
		if (messagesError) {
			console.error(`[FoxConversationDO:ws] Failed to load messages for catch-up conversationId=${state.conversationId}`);
		}
		if (convError) {
			console.error(`[FoxConversationDO:ws] Failed to load total_rounds for catch-up conversationId=${state.conversationId}`);
		}

		return {
			type: "state",
			// `notifying` is internal scheduling state — the conversation is
			// finished and every write for it is done; only N-01 is still
			// pending. A client reconnecting in that window must see the same
			// thing it would have a moment later, so it is reported as
			// `completed` rather than added to the wire protocol.
			status: state.status === "notifying" ? "completed" : state.status,
			current_round: messages?.length ?? 0,
			total_rounds: convRow?.total_rounds ?? 0,
			messages: (messages ?? []).map((m) => ({
				round_number: m.round_number,
				speaker: (m.speaker_user_id === state.userA ? "A" : "B") as "A" | "B",
				content: m.content ?? "",
			})),
		};
	}

	private async handleWebSocketUpgrade(request: Request): Promise<Response> {
		const verifiedUserId = request.headers.get("X-Verified-User-Id");
		// The edge has already parsed the client's (possibly multi-valued)
		// Sec-WebSocket-Protocol offer and picked the single value it selected
		// (routes/fox-search-ws.ts). We echo exactly that value and nothing
		// else — RFC 6455 §4.1 requires the server to select exactly ONE of
		// the offered values, and echoing the raw (possibly comma-joined)
		// header back would violate that and fail the handshake in the
		// browser the moment a client ever offers more than one value (F1,
		// step-3c review). Do not re-derive this from the raw header here.
		const selectedProtocol = request.headers.get("X-Verified-Ws-Protocol");

		const access = await this.resolveWsAccess(verifiedUserId);
		if (!access.authorized) {
			return new Response("Forbidden", { status: 403 });
		}

		const pair = new WebSocketPair();
		const [client, server] = [pair[0], pair[1]];
		server.serializeAttachment({ authenticated: true, userId: access.userId });
		this.ctx.acceptWebSocket(server);

		// C2: catch-up is built and sent AFTER acceptWebSocket(), not before —
		// see resolveWsAccess's doc comment for why. Any round that broadcasts
		// during this read now safely reaches this socket (it's registered
		// already) and may ALSO land in the snapshot below; that possible
		// duplicate is deliberate and handled by the client's round_number
		// dedupe (useFoxSearchWebSocket.ts), not avoided here.
		const accessExpectation: FoxConversationAccessExpectation = {
			conversationId: access.state.conversationId,
			matchId: access.state.matchId,
			userA: access.state.userA,
			userB: access.state.userB,
			generationWindow: await resolveFoxConversationGenerationWindow(this.getSupabase(), this.env, access.state.userA, access.state.userB),
		};
		const accessMode = access.state.status === "notifying" || access.state.status === "completed" ? "completed" : "active";
		const beforeCatchUpAccess = await checkFoxConversationCurrentAccess(this.getSupabase(), accessExpectation, accessMode);
		if (!beforeCatchUpAccess.ok) {
			server.close(4003, "Forbidden");
			return new Response("Forbidden", { status: 403 });
		}
		const catchUp = await this.buildCatchUpMessage(access.state);
		const afterCatchUpAccess = await checkFoxConversationCurrentAccess(this.getSupabase(), accessExpectation, accessMode);
		if (!afterCatchUpAccess.ok) {
			server.close(4003, "Forbidden");
			return new Response("Forbidden", { status: 403 });
		}
		server.send(JSON.stringify(catchUp));

		// Echo the selected subprotocol back on the 101 response — browsers
		// abort the connection if it isn't. Verified empirically against
		// workerd (`wrangler dev`) that a 101 built this way carries the
		// header through (step-3 §4-C-2).
		return new Response(null, {
			status: 101,
			webSocket: client,
			headers: selectedProtocol ? { "Sec-WebSocket-Protocol": selectedProtocol } : {},
		});
	}

	async webSocketMessage(
		ws: WebSocket,
		message: string | ArrayBuffer,
	): Promise<void> {
		if (typeof message !== "string") return;

		let parsed: ClientMessage;
		try {
			parsed = JSON.parse(message);
		} catch {
			ws.send(JSON.stringify({ type: "error", message: "Invalid JSON" }));
			return;
		}

		if (parsed.type === "ping") {
			// Every socket that reaches this point was already authorized in
			// handleWebSocketUpgrade, so this is belt-and-suspenders rather
			// than a real gate — but it stays explicit per §4-C-3-2.
			const attachment = ws.deserializeAttachment() as { authenticated?: boolean } | null;
			if (attachment?.authenticated) {
				ws.send(JSON.stringify({ type: "pong" }));
			}
			return;
		}
	}

	async webSocketClose(
		_ws: WebSocket,
		_code: number,
		_reason: string,
		_wasClean: boolean,
	): Promise<void> {
		// Hibernation API handles cleanup automatically.
		// The DO stays alive and alarm continues.
	}

	private broadcast(msg: ServerMessage): void {
		const data = JSON.stringify(msg);
		for (const ws of this.ctx.getWebSockets()) {
			try {
				const attachment = ws.deserializeAttachment() as {
					authenticated?: boolean;
				} | null;
				if (attachment?.authenticated) {
					ws.send(data);
				}
			} catch {
				// Socket may be closing
			}
		}
	}
}
