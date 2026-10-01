import { Hono } from "hono";
import type { Env } from "../env";
import { getSupabaseClient } from "../db/client";
import { requireAuth, requireAgeVerified } from "../middleware/auth";
import { jsonError } from "../lib/response";
import { isDemoJudgeActive } from "../services/demo-judge-window";
import { executeMatching } from "../services/matching";
import { readMatchingCurrentSnapshot } from "../services/matching-current-access";
const route = new Hono<Env>();
route.use("*", async (c,next) => { c.header("Cache-Control","private, no-store"); await next(); });
for (const mode of ["preview","start"] as const) {
 route.post(`/matching/${mode}`,requireAuth,requireAgeVerified,async c => {
  const config=c.get("demo_judge"), actor=c.get("user_id");
  if (!isDemoJudgeActive(config) || !(config.profileIds as readonly string[]).includes(actor)) return jsonError(c,"INTERNAL_ERROR","Discovery unavailable",503);
  try {
   const count=await executeMatching(getSupabaseClient(c.env),10,undefined,{profileIds:config.profileIds,actorId:actor,mode,canWrite:()=>isDemoJudgeActive(config)});
   if (!isDemoJudgeActive(config)) return jsonError(c,"INTERNAL_ERROR","Discovery unavailable",503);
   return c.json({data:{source:"ordinary-discovery",outcome:mode==="preview"?"eligible":"started",count}});
  } catch { return jsonError(c,"INTERNAL_ERROR","Discovery unavailable",503); }
 });
}
route.get("/matching/results",requireAuth,requireAgeVerified,async c => {
 const config=c.get("demo_judge"), actor=c.get("user_id");
 if (!isDemoJudgeActive(config) || !(config.profileIds as readonly string[]).includes(actor)) return jsonError(c,"INTERNAL_ERROR","Discovery unavailable",503);
 const db=getSupabaseClient(c.env);
 try {
  const result=await db.from("matches").select("id,user_a_id,user_b_id").in("user_a_id",[...config.profileIds]).in("user_b_id",[...config.profileIds]).or(`user_a_id.eq.${actor},user_b_id.eq.${actor}`).order("profile_score",{ascending:false}).limit(20);
  if (!isDemoJudgeActive(config) || result.error || !Array.isArray(result.data) || result.data.some(row=>row.user_a_id!==actor&&row.user_b_id!==actor || !(config.profileIds as readonly string[]).includes(row.user_a_id) || !(config.profileIds as readonly string[]).includes(row.user_b_id))) return jsonError(c,"INTERNAL_ERROR","Discovery unavailable",503);
  const snapshot=await readMatchingCurrentSnapshot(db,result.data.map(row=>({matchId:row.id,ownerId:actor,participantIds:[row.user_a_id,row.user_b_id] as const})));
  if (!isDemoJudgeActive(config) || !snapshot.ok) return jsonError(c,"INTERNAL_ERROR","Discovery unavailable",503);
  const matches=[...snapshot.rows.values()].map(row=>{
   const partnerId=row.user_a_id===actor?row.user_b_id:row.user_a_id;
   const partner=row.user_a_id===actor?row.profile_b:row.profile_a;
   return {id:row.id,partner_id:partnerId,partner:{nickname:partner.nickname,avatar_url:null,persona_icon_url:null},status:row.status,profile_score:row.profile_score,final_score:row.final_score,conversation_score:row.conversation_score,score_details:row.score_details,fox_conversation_id:row.compatibilityConversation?.id??null};
  });
  return c.json({data:{source:"ordinary-discovery",matches,total_matches:matches.length}});
 } catch { return jsonError(c,"INTERNAL_ERROR","Discovery unavailable",503); }
});
export default route;
