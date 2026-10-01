import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../db/types";
import { runConversationLoop } from "./fox-conversation-engine";
import type { FoxConversationRecordingWindow } from "./fox-conversation-recording-window";

/**
 * Local-dev / no-DO-binding fallback path. Runs the conversation loop
 * (services/fox-conversation-engine.ts) inline, with no `onRound` broadcast
 * and the engine's default `setTimeout`-based `sleep`.
 *
 * Signature is unchanged by step-3d's unification on purpose: it is called
 * from routes/internal.ts (x3), services/daily-batch.ts, routes/fox-search.ts,
 * and services/fox-conversation-request.ts's dynamic import, none of which
 * were touched by this change.
 */
export async function runFoxConversation(
	supabase: SupabaseClient<Database>,
	mistralApiKey: string,
	conversationId: string,
	generationWindow?: FoxConversationRecordingWindow,
): Promise<void> {
	await runConversationLoop({ supabase, apiKey: mistralApiKey, conversationId, generationWindow });
}
