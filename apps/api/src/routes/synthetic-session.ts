import { Hono } from "hono";
import { z } from "zod";
import type { Env } from "../env";
import { getSupabaseAuthClient } from "../db/client";
import { readProductionE2EConfig } from "../middleware/production-e2e-gate";
import { SYNTHETIC_MATCHING_PROFILE_IDS } from "../services/synthetic-matching-cohort";
import { readBoundedRequestBody } from "../services/onboarding-settings";
import { jsonError } from "../lib/response";

const schema = z.object({ profile_id: z.enum(SYNTHETIC_MATCHING_PROFILE_IDS), password: z.string().min(20).max(128) }).strict();
const emails = ["wingward-synthetic-aoi-20260922@example.invalid", "wingward-synthetic-ren-20260922@example.invalid", "wingward-synthetic-sora-20260922@example.invalid"];
const route = new Hono<Env>();

function enabled(env: Env["Bindings"]): boolean {
  const config = readProductionE2EConfig(env);
  return config.kind === "active" && !config.readOnly && config.syntheticProfileIds.length === 3 && Date.now() < config.expiresAtMs;
}

/** Bounded password login, not an admin token or authentication bypass.
 * Only disposable users are reachable; runtime consumes existing Auth bindings.
 * Neither passwords, provider configuration, nor session responses are logged.
 */
route.post("/synthetic-session", async c => {
  c.header("Cache-Control", "no-store");
  if (!enabled(c.env)) return jsonError(c, "FORBIDDEN", "Forbidden");
  const bytes = await readBoundedRequestBody(c.req.raw, 1024);
  if (!bytes) return jsonError(c, "BAD_REQUEST", "Invalid request");
  let body: unknown;
  try { body = JSON.parse(new TextDecoder().decode(bytes)); } catch { return jsonError(c, "BAD_REQUEST", "Invalid request"); }
  const parsed = schema.safeParse(body);
  if (!parsed.success) return jsonError(c, "BAD_REQUEST", "Invalid request");
  const email = emails[SYNTHETIC_MATCHING_PROFILE_IDS.indexOf(parsed.data.profile_id)];
  try {
    const auth = getSupabaseAuthClient(c.env);
    const { data, error } = await auth.auth.signInWithPassword({ email, password: parsed.data.password });
    if (error || !data.session || data.user?.id !== parsed.data.profile_id || !enabled(c.env)) {
      return jsonError(c, "UNAUTHORIZED", "Unauthorized");
    }
    return c.json({ data: { access_token: data.session.access_token } });
  } catch {
    return jsonError(c, "UNAUTHORIZED", "Unauthorized");
  }
});

export default route;
