import type { Context } from "hono";

/**
 * Runs `work` without holding up the response, when the runtime allows it.
 *
 * On Workers, a promise left floating after the handler returns is cancelled,
 * so "fire and forget" silently does not run — `waitUntil` is what keeps it
 * alive. Outside Workers (the local `tsx` dev server in `src/node.ts`) there
 * is no execution context and nothing cancels the promise, so starting it is
 * enough.
 *
 * Neither branch is awaited by the caller, so a route test cannot observe the
 * work finishing. That is why the trigger functions are tested directly, and
 * the route's use of them is pinned by a source-wiring test instead — the same
 * split as lazy-fox-conversation-wiring.test.ts.
 *
 * `work` must contain its own errors. A rejection here has nowhere to go —
 * inside `waitUntil` it becomes an unhandled rejection in the Worker, and the
 * caller has already returned. The catch below is a backstop for that, not a
 * substitute for the callee handling its own failures.
 */
export function notifyInBackground(c: Context, work: () => Promise<void>): void {
	const run = async () => {
		try {
			await work();
		} catch (e) {
			console.error("[background] task threw:", e);
		}
	};

	// `executionCtx` throws rather than returning undefined when Hono has no
	// underlying Workers context, which is why this is a try/catch and not a
	// truthiness check.
	try {
		c.executionCtx.waitUntil(run());
	} catch {
		void run();
	}
}
