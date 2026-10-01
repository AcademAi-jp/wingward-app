import { isJudgeAccessActive, type JudgeAccess } from "./judge-access";

type RpcClient = { rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: unknown }> };
export type JudgeSimulatedAdmission = Readonly<{ access: JudgeAccess; roomId?: string; meetupId?: string }>;
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const OPERATIONS = new Set(["apply_chat_meetup_action", "claim_meetup_arrangement", "publish_chat_meetup_times", "get_meetup_reflection_state", "confirm_meetup_reflection"]);

/** Registry context comes from authenticated middleware; SQL proves the current exact fictional pair. */
export async function checkJudgeSimulatedAdmission(client: RpcClient, access: JudgeAccess | undefined, userId: string, scope: { roomId?: string; meetupId?: string }): Promise<JudgeSimulatedAdmission | null> {
  if (!isJudgeAccessActive(access) || access.actorId !== userId || (!scope.roomId && !scope.meetupId)
    || (scope.roomId && !ID.test(scope.roomId)) || (scope.meetupId && !ID.test(scope.meetupId))) return null;
  try {
    const result = await client.rpc("check_judge_simulated_admission", { p_judge_actor_id: access.actorId,
      p_user_id: userId, p_room_id: scope.roomId ?? null, p_meetup_id: scope.meetupId ?? null });
    const row = Array.isArray(result.data) && result.data.length === 1 ? result.data[0] : result.data;
    return !result.error && typeof row === "object" && row !== null && !Array.isArray(row)
      && (row as Record<string, unknown>).admitted === true && isJudgeAccessActive(access)
      ? Object.freeze({ access, ...scope }) : null;
  } catch { return null; }
}

export async function judgeSimulatedRpc(client: RpcClient, name: string, args: Record<string, unknown>, admission: JudgeSimulatedAdmission): Promise<{ data: unknown; error: unknown }> {
  if (!OPERATIONS.has(name) || !isJudgeAccessActive(admission.access) || args.p_user_id !== admission.access.actorId
    || (admission.roomId && args.p_room_id !== undefined && args.p_room_id !== admission.roomId)
    || (admission.meetupId && args.p_meetup_id !== undefined && args.p_meetup_id !== admission.meetupId))
    return { data: null, error: "Judge simulation unavailable" };
  const result = await client.rpc(`judge_simulated_${name}`, { ...args, p_judge_actor_id: admission.access.actorId });
  return isJudgeAccessActive(admission.access) ? result : { data: null, error: "Judge simulation unavailable" };
}
