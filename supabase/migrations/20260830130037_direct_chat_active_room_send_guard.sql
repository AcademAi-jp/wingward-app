-- Reject direct-chat messages for rooms that are no longer active.
--
-- The API checks `status = 'active'` before it writes, but that check is only
-- an early, non-disclosing response.  A moderator can close the room after
-- that read and before the INSERT or read-receipt UPDATE.  This trigger is
-- the database invariant that closes that application-check/write gap.
--
-- Both this trigger and the moderation UPDATE take a row lock on the same
-- `direct_chat_rooms` row.  If the close obtains the lock first, the trigger
-- waits and then sees `closed`, so the INSERT is rejected.  If the trigger
-- obtains it first, the message is inserted while the room is active and the
-- close waits; the send therefore linearizes before the close.  PostgreSQL
-- holds the row lock until the surrounding statement transaction ends.

CREATE OR REPLACE FUNCTION public.reject_non_active_direct_chat_room()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  room_id_value uuid;
  room_status text;
BEGIN
  room_id_value := to_jsonb(NEW) ->> TG_ARGV[0];

  IF room_id_value IS NULL THEN
    RETURN NEW;
  END IF;

  -- Lock the room row before inspecting status.  The room UPDATE used by the
  -- block/moderation path obtains a conflicting row lock, giving close vs.
  -- send one serializable order without broad table locking.  A missing room
  -- is left to the existing foreign key constraint to reject.
  SELECT status INTO room_status
  FROM public.direct_chat_rooms
  WHERE id = room_id_value
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF room_status IS DISTINCT FROM 'active' THEN
    -- Keep the database error generic too: callers must not learn room state
    -- or an identifier from this invariant.  The API maps this to its generic
    -- send failure for the rare close-after-precheck race.
    RAISE EXCEPTION 'direct chat room is not active'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

-- The function is meaningful only as a trigger.  Do not expose it as a
-- callable SECURITY DEFINER helper to an untrusted database role.
REVOKE ALL ON FUNCTION public.reject_non_active_direct_chat_room() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER direct_chat_messages_reject_non_active_room
  BEFORE INSERT OR UPDATE ON public.direct_chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.reject_non_active_direct_chat_room('room_id');

-- Keep direct PostgREST and Realtime reads behind the same revocation rule as
-- the API.  This helper is SECURITY DEFINER because a blocked participant
-- cannot see the other party's `blocks` row under the table's own RLS policy;
-- evaluating with invoker privileges would therefore fail open for blockees.
CREATE OR REPLACE FUNCTION public.can_read_active_direct_chat_room(p_room_id uuid)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.direct_chat_rooms AS room
    JOIN public.matches AS chat_match ON chat_match.id = room.match_id
    WHERE room.id = p_room_id
      AND room.status = 'active'
      AND public.get_user_profile_id() IN (chat_match.user_a_id, chat_match.user_b_id)
      AND public.are_match_participants_age_verified(chat_match.id)
      AND NOT EXISTS (
        SELECT 1
        FROM public.blocks AS block_row
        WHERE (block_row.blocker_id = chat_match.user_a_id AND block_row.blocked_id = chat_match.user_b_id)
           OR (block_row.blocker_id = chat_match.user_b_id AND block_row.blocked_id = chat_match.user_a_id)
      )
  )
$$;

-- The boolean result reveals neither whether a room exists nor why it is
-- unavailable.  Only authenticated callers need it for RLS evaluation.
REVOKE ALL ON FUNCTION public.can_read_active_direct_chat_room(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_read_active_direct_chat_room(uuid) TO authenticated, service_role;

DROP POLICY IF EXISTS direct_chat_rooms_select ON public.direct_chat_rooms;
CREATE POLICY direct_chat_rooms_select ON public.direct_chat_rooms FOR SELECT
  USING (public.can_read_active_direct_chat_room(id));

DROP POLICY IF EXISTS direct_chat_messages_select ON public.direct_chat_messages;
CREATE POLICY direct_chat_messages_select ON public.direct_chat_messages FOR SELECT
  USING (public.can_read_active_direct_chat_room(room_id));
