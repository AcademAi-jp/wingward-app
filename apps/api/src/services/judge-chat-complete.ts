import type { Context } from "hono";
import type { Env } from "../env";
import { chatComplete, chatCompleteOnceBounded, MISTRAL_REQUEST_TOKEN_OVERHEAD, type ChatMessage, type ChatCompleteOptions } from "./mistral";
import { hasJudgeAccessConfig, isJudgeAccessActive, judgeRpcClient, readJudgeAccess, readJudgeAccessConfig, reserveJudgeProviderOperation, type JudgeProviderOperation } from "./judge-access";

/** One paid request per durable reservation. Failed requests retain their reserved ceiling. */
export async function judgeChatComplete(c: Context<Env>, client: unknown, operation: JudgeProviderOperation,
 apiKey: string | undefined, messages: ChatMessage[], options: ChatCompleteOptions = {}): Promise<string> {
 const access=c.get("judge_access");
 if(!access) {
  if(hasJudgeAccessConfig(c.env))throw new Error("AI review access unavailable");
  return chatComplete(apiKey,messages,options);
 }
 const config=readJudgeAccessConfig(c.env);
 if(config.kind!=="active" || !isJudgeAccessActive(access) || access.actorId!==c.get("user_id")) throw new Error("AI review access unavailable");
 const rpc=judgeRpcClient(client);
 const fresh=await readJudgeAccess(rpc,config.config,access.actorId);
 if(!fresh || fresh.counterpartId!==access.counterpartId)throw new Error("AI review access unavailable");
 // The DB independently rejects races; this pacing supports multi-call generation.
 await new Promise<void>(resolve=>setTimeout(resolve,1100));
 const reservation=await reserveJudgeProviderOperation(rpc,fresh,operation,crypto.randomUUID());
 if(!reservation)throw new Error("AI review budget unavailable");
 const maxTokens=options.maxTokens??1024;
 const maxRequestBytes=Math.min(32768,reservation.maxUnits-maxTokens-MISTRAL_REQUEST_TOKEN_OVERHEAD);
 if(maxRequestBytes<1 || !isJudgeAccessActive(fresh))throw new Error("AI review request exceeds budget");
 const result=await chatCompleteOnceBounded(apiKey,messages,{...options,maxTokens,maxRequestBytes,maxResponseBytes:32768,maxTotalTokenUnits:reservation.maxUnits});
 const after=await readJudgeAccess(rpc,config.config,access.actorId);
 if(!after || after.counterpartId!==fresh.counterpartId || !isJudgeAccessActive(after))throw new Error("AI review access expired");
 return result.content;
}
