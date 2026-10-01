import type {Context,Next} from "hono";
import type {Env} from "../env";
import {getSupabaseClient} from "../db/client";
import {jsonError} from "../lib/response";
import {resolveAuthUser} from "./auth";
import {consumeJudgeRequest,isJudgeAccessActive,readJudgeAccess,readJudgeAccessConfig,type JudgeRpcClient} from "../services/judge-access";

const ID="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const READS=new Set(["/api/judge/readiness/voice","/api/judge/readiness/provider","/api/auth/me","/api/auth/me/onboarding-settings","/api/auth/me/onboarding-options","/api/quiz/questions","/api/quiz/answers","/api/profiles/me","/api/profiles/me/generation-state","/api/personas","/api/personas/section-definitions","/api/speed-dating/personas","/api/matching/results","/api/matching/daily-results","/api/demo-judge/matching/results","/api/billing/identity","/api/billing/status","/api/chat-requests","/api/direct-chats"]);
const POSTS=new Set(["/api/judge/readiness/voice-recheck","/api/judge/readiness/voice-recheck/stop","/api/judge/readiness/voice","/api/judge/readiness/voice/stop","/api/judge/readiness","/api/quiz/answers","/api/speed-dating/personas","/api/speed-dating/sessions","/api/profiles/generate","/api/personas/wingfox/generate","/api/profiles/me/confirm","/api/demo-judge/matching/preview","/api/demo-judge/matching/start","/api/partner-fox-chats","/api/chat-requests","/api/judge/counterpart/advance"]);
export function matchesJudgeAccessRoute(method:string,path:string):boolean {
 if(method==="GET")return READS.has(path)||new RegExp(`^/api/(?:personas/${ID}|speed-dating/sessions/${ID}|matching/results/${ID}|fox-conversations/${ID}(?:/messages)?|partner-fox-chats/${ID}(?:/messages)?|chat-requests/by-match/${ID}|direct-chats/${ID}/messages|chat-meetups/rooms/${ID}|meetup-reflections/${ID})$`).test(path);
 if(method==="POST")return POSTS.has(path)||new RegExp(`^/api/(?:speed-dating/sessions/${ID}/(?:realtime-bootstrap|realtime-call|realtime-stop|complete)|matches/${ID}/fox-conversation|partner-fox-chats/${ID}/messages|direct-chats/${ID}/messages(?:/send-recovery)?|chat-requests/${ID}/(?:accept|decline)|chat-meetups/rooms/${ID}/actions|meetup-reflections/${ID}/(?:bootstrap|realtime-call|realtime-stop|drafts|confirm))$`).test(path);
 return method==="PUT" && (["/api/auth/me","/api/auth/me/age-verification","/api/auth/me/onboarding-settings","/api/profiles/me"].includes(path)||new RegExp(`^/api/(?:direct-chats/${ID}/messages/${ID}/read|chat-requests/${ID})$`).test(path));
}
export async function judgeAccessGate(c:Context<Env>,next:Next){
 const scope=readJudgeAccessConfig(c.env);
 if(scope.kind==="absent")return next();
 if(scope.kind!=="active")return jsonError(c,"INTERNAL_ERROR","WingWard review access is unavailable",503);
 const path=new URL(c.req.url).pathname;
 // The vendor endpoint retains its own independent HMAC/Authorization validation.
 if(c.req.method==="POST" && path==="/api/webhooks/revenuecat"){c.set("judge_vendor_active",true);return next();}
 if(!matchesJudgeAccessRoute(c.req.method,path))return jsonError(c,"FORBIDDEN","This action is not available for WingWard review");
 const authorization=c.req.header("Authorization"),bearer=authorization?.startsWith("Bearer ")?authorization.slice(7):"";
 if(!bearer||bearer.trim()!==bearer)return jsonError(c,"UNAUTHORIZED","Sign in with your WingWard review account");
 let resolved:Awaited<ReturnType<typeof resolveAuthUser>>=null;
 try{resolved=await resolveAuthUser(c,bearer);}catch{resolved=null;}
 if(!resolved)return jsonError(c,"UNAUTHORIZED","Sign in with your WingWard review account");
 const client=getSupabaseClient(c.env) as unknown as JudgeRpcClient;
 const access=await readJudgeAccess(client,scope.config,resolved.userId);
 if(!access){
  // Preserve only the previously approved saved-profile reads for the completed recording pair.
  if(c.req.method==="GET" && ["/api/auth/me","/api/profiles/me"].includes(path) && ["9d836fee-7b93-41ce-b577-34a63006aaea","a88a89e2-5421-5ce9-a33b-76d512898c37"].includes(resolved.userId))return next();
  return jsonError(c,"FORBIDDEN","This account is not enabled for WingWard review");
 }
 if(!await consumeJudgeRequest(client,access,crypto.randomUUID()))return jsonError(c,"RATE_LIMITED","WingWard review request limit reached");
 c.set("auth_user_id",resolved.authUserId);c.set("user_id",resolved.userId);c.set("judge_access",access);
 c.set("demo_judge",Object.freeze({kind:"demo-judge",issuedAt:new Date(scope.config.issuedAtMs).toISOString(),issuedAtMs:scope.config.issuedAtMs,expiresAt:new Date(access.expiresAtMs).toISOString(),expiresAtMs:access.expiresAtMs,profileIds:Object.freeze([access.actorId,access.counterpartId])}));
 if(c.req.method==="GET" && path==="/api/profiles/me")c.set("production_e2e_read_only",true);
 await next();
 if(!isJudgeAccessActive(access)){c.res=jsonError(c,"INTERNAL_ERROR","WingWard review access expired",503);return c.res;}
}
