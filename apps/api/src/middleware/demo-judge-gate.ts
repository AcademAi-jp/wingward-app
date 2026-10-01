import type { Context, Next } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { resolveAuthUser } from "./auth";
import { jsonError } from "../lib/response";
import { readDemoJudgeConfig, isDemoJudgeActive, isDemoJudgePair } from "../services/demo-judge-window";
const ID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
export function matchesDemoJudgeRoute(method: string, path: string): boolean {
 const reads = ["/api/auth/me","/api/auth/me/onboarding-settings","/api/auth/me/onboarding-options","/api/profiles/me","/api/profiles/me/generation-state","/api/billing/status","/api/billing/identity","/api/demo-judge/matching/results"];
 if (method === "GET") return reads.includes(path) || new RegExp(`^/api/(?:matching/results/${ID}|fox-conversations/${ID}(?:/messages)?)$`).test(path);
 if (method === "POST") return ["/api/demo-judge/matching/preview","/api/demo-judge/matching/start"].includes(path) || new RegExp(`^/api/(?:matches/${ID}/fox-conversation)$`).test(path);
 return method === "PUT" && path === "/api/auth/me/onboarding-settings";
}
export async function demoJudgeGate(c: Context<Env>, next: Next) {
 const result = readDemoJudgeConfig(c.env);
 if (result.kind !== "active") return jsonError(c,"INTERNAL_ERROR","Service unavailable",503);
 const config=result.config;
 if (!matchesDemoJudgeRoute(c.req.method,new URL(c.req.url).pathname)) return jsonError(c,"FORBIDDEN","Forbidden");
 const auth=c.req.header("Authorization"); const bearer=auth?.startsWith("Bearer ") ? auth.slice(7) : "";
 if (!bearer || bearer.trim()!==bearer) return jsonError(c,"UNAUTHORIZED","Unauthorized");
 let resolved: Awaited<ReturnType<typeof resolveAuthUser>> = null;
 try { resolved=await resolveAuthUser(c,bearer); } catch { resolved=null; }
 if (!isDemoJudgeActive(config)) return jsonError(c,"INTERNAL_ERROR","Service unavailable",503);
 if (!resolved) return jsonError(c,"UNAUTHORIZED","Unauthorized");
 if (!(config.profileIds as readonly string[]).includes(resolved.userId)) return jsonError(c,"FORBIDDEN","Forbidden");
 const pathname = new URL(c.req.url).pathname;
 const detail = new RegExp(`^/api/matching/results/(${ID})$`).exec(pathname);
 const fox = new RegExp(`^/api/fox-conversations/(${ID})(?:/messages)?$`).exec(pathname);
 if (detail || fox) {
  const db = getSupabaseClient(c.env);
  let matchId = detail?.[1];
  try {
   if (fox) {
    const conversation = await db.from("fox_conversations").select("match_id,purpose").eq("id",fox[1]).maybeSingle();
    if (!isDemoJudgeActive(config) || conversation.error || conversation.data?.purpose !== "compatibility") return jsonError(c,"NOT_FOUND","Match not found");
    matchId = conversation.data.match_id;
   }
   const match = await db.from("matches").select("user_a_id,user_b_id").eq("id",matchId!).maybeSingle();
   if (!isDemoJudgeActive(config)) return jsonError(c,"INTERNAL_ERROR","Service unavailable",503);
   if (match.error || !match.data || ![match.data.user_a_id,match.data.user_b_id].includes(resolved.userId)
    || !isDemoJudgePair(config,match.data.user_a_id,match.data.user_b_id)) return jsonError(c,"NOT_FOUND","Match not found");
  } catch { return jsonError(c,"INTERNAL_ERROR","Service unavailable",503); }
 }
 c.set("auth_user_id",resolved.authUserId);c.set("user_id",resolved.userId);c.set("demo_judge",config);
 if (c.req.method === "GET" && new URL(c.req.url).pathname === "/api/profiles/me") c.set("production_e2e_read_only",true);
 await next();
 // Never release a response after the permit elapsed during downstream awaits.
 if (!isDemoJudgeActive(config)) {
  c.res = jsonError(c,"INTERNAL_ERROR","Service unavailable",503);
  return c.res;
 }
}
