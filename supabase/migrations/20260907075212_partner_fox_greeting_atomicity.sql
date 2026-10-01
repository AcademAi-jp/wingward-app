-- B2 partner-Fox greeting recovery.
--
-- The API may spend time outside the database while it asks the provider for
-- the initial greeting.  This service-role-only RPC is the single atomic
-- boundary that persists the winner and advances the match state.  A chat row
-- may therefore remain empty after a provider failure and be safely retried;
-- no retry deletes a chat or another request's message.

CREATE OR REPLACE FUNCTION public.persist_partner_fox_greeting(
  p_chat_id uuid,
  p_match_id uuid,
  p_user_id uuid,
  p_partner_user_id uuid,
  p_content text
)
RETURNS TABLE (
  chat_id uuid,
  match_id uuid,
  user_id uuid,
  partner_user_id uuid,
  message_id uuid,
  message_role text,
  message_content text,
  message_created_at timestamptz,
  outcome text,
  match_status text,
  transitioned boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_chat public.partner_fox_chats%ROWTYPE;
  v_compatibility public.fox_conversations%ROWTYPE;
  v_existing public.partner_fox_messages%ROWTYPE;
  v_has_message boolean := false;
  v_eligible boolean := false;
  v_now timestamptz := pg_catalog.now();
  v_message_id uuid;
  v_message_created_at timestamptz;
  v_transitioned boolean := false;
BEGIN
  -- The greeting is provider output, but it is still untrusted input at this
  -- boundary. Keep the stored result bounded and reject whitespace-only text.
  IF p_chat_id IS NULL OR p_match_id IS NULL OR p_user_id IS NULL
     OR p_partner_user_id IS NULL OR p_user_id = p_partner_user_id
     OR p_content IS NULL
     OR p_content ~ '^[[:space:]]*$'
     OR pg_catalog.char_length(p_content) > 2000 THEN
    RETURN QUERY SELECT p_chat_id, p_match_id, p_user_id, p_partner_user_id,
      NULL::uuid, NULL::text, NULL::text, NULL::timestamptz,
      'invalid_input'::text, NULL::text, false;
    RETURN;
  END IF;

  -- All callers for one relationship take match -> room -> chat ->
  -- compatibility conversation -> sorted profiles. The match lock also makes
  -- the status transition below a single writer.
  SELECT match_row.*
    INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = p_match_id
   FOR UPDATE;
  IF NOT FOUND
     OR (p_user_id <> v_match.user_a_id AND p_user_id <> v_match.user_b_id)
     OR (p_partner_user_id <> v_match.user_a_id AND p_partner_user_id <> v_match.user_b_id)
     OR p_user_id = p_partner_user_id THEN
    RETURN QUERY SELECT p_chat_id, p_match_id, p_user_id, p_partner_user_id,
      NULL::uuid, NULL::text, NULL::text, NULL::timestamptz,
      'not_found'::text, NULL::text, false;
    RETURN;
  END IF;

  IF v_match.status NOT IN (
    'fox_conversation_completed', 'partner_chat_started',
    'direct_chat_requested', 'direct_chat_active', 'meetup_intent',
    'meetup_confirmed'
  ) THEN
    RETURN QUERY SELECT p_chat_id, p_match_id, p_user_id, p_partner_user_id,
      NULL::uuid, NULL::text, NULL::text, NULL::timestamptz,
      'not_found'::text, v_match.status, false;
    RETURN;
  END IF;

  -- Lock an existing room before the chat, and fail closed for a closed room
  -- even in an earlier contact state; active-room states also require a row.
  SELECT room_row.*
    INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.match_id = v_match.id
   FOR SHARE;
  IF FOUND AND v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT p_chat_id, p_match_id, p_user_id, p_partner_user_id,
      NULL::uuid, NULL::text, NULL::text, NULL::timestamptz,
      'not_found'::text, v_match.status, false;
    RETURN;
  END IF;

  IF v_match.status IN ('direct_chat_active', 'meetup_intent', 'meetup_confirmed')
     AND v_room.id IS NULL THEN
    RETURN QUERY SELECT p_chat_id, p_match_id, p_user_id, p_partner_user_id,
      NULL::uuid, NULL::text, NULL::text, NULL::timestamptz,
      'not_found'::text, v_match.status, false;
    RETURN;
  END IF;

  SELECT chat_row.*
    INTO v_chat
    FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = p_chat_id
   FOR UPDATE;
  IF NOT FOUND
     OR v_chat.match_id IS DISTINCT FROM v_match.id
     OR v_chat.user_id IS DISTINCT FROM p_user_id
     OR v_chat.partner_user_id IS DISTINCT FROM p_partner_user_id THEN
    RETURN QUERY SELECT p_chat_id, p_match_id, p_user_id, p_partner_user_id,
      NULL::uuid, NULL::text, NULL::text, NULL::timestamptz,
      'not_found'::text, v_match.status, false;
    RETURN;
  END IF;

  -- Lock and inspect the exact completed compatibility conversation after the
  -- chat lock and before the sorted profiles. A concurrent completion/failure
  -- cannot pass a stale pre-lock read into the greeting write.
  SELECT conversation_row.*
    INTO v_compatibility
    FROM public.fox_conversations AS conversation_row
   WHERE conversation_row.match_id = v_match.id
     AND conversation_row.purpose = 'compatibility'
   FOR SHARE;
  IF NOT FOUND OR v_compatibility.status IS DISTINCT FROM 'completed' THEN
    RETURN QUERY SELECT p_chat_id, p_match_id, p_user_id, p_partner_user_id,
      NULL::uuid, NULL::text, NULL::text, NULL::timestamptz,
      'not_found'::text, v_match.status, false;
    RETURN;
  END IF;

  -- This helper takes the sorted current profile FOR SHARE locks, then checks
  -- both block directions and the strict current matching predicate.  It is
  -- deliberately after the match and chat locks to match the message guard.
  v_eligible := wingward_private.lock_and_check_mutual_eligibility(
    v_match.user_a_id,
    v_match.user_b_id
  );
  IF NOT COALESCE(v_eligible, false) THEN
    RETURN QUERY SELECT p_chat_id, p_match_id, p_user_id, p_partner_user_id,
      NULL::uuid, NULL::text, NULL::text, NULL::timestamptz,
      'not_found'::text, v_match.status, false;
    RETURN;
  END IF;

  -- Message triggers take chat FOR KEY SHARE before they take profile locks.
  -- With this RPC's chat FOR UPDATE, a concurrent user message either
  -- commits before this SELECT or waits and is observed on its fresh snapshot.
  SELECT message_row.*
    INTO v_existing
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.chat_id = v_chat.id
   ORDER BY message_row.created_at, message_row.id
   LIMIT 1;
  v_has_message := FOUND;

  IF v_has_message THEN
    IF v_existing.role = 'fox' THEN
      RETURN QUERY SELECT v_chat.id, v_chat.match_id, v_chat.user_id,
        v_chat.partner_user_id, v_existing.id, v_existing.role,
        v_existing.content, v_existing.created_at, 'already_started'::text,
        v_match.status, false;
      RETURN;
    END IF;

    -- A user message is the first row, so it won the empty-chat race. Do not
    -- replace it, even if malformed legacy data contains a later fox row, and
    -- do not disclose its content to an initial-greeting caller.
    RETURN QUERY SELECT v_chat.id, v_chat.match_id, v_chat.user_id,
      v_chat.partner_user_id, NULL::uuid, NULL::text, NULL::text,
      NULL::timestamptz, 'message_present'::text, v_match.status, false;
    RETURN;
  END IF;

  INSERT INTO public.partner_fox_messages (chat_id, role, content)
  VALUES (v_chat.id, 'fox', p_content)
  RETURNING id, created_at INTO v_message_id, v_message_created_at;

  IF v_match.status = 'fox_conversation_completed' THEN
    UPDATE public.matches AS match_row
       SET status = 'partner_chat_started',
           updated_at = v_now
     WHERE match_row.id = v_match.id
       AND match_row.status = 'fox_conversation_completed';
    IF NOT FOUND THEN
      -- The match row is already locked, so this is an internal consistency
      -- failure. Raising rolls back the greeting together with the CAS.
      RAISE EXCEPTION 'partner fox greeting status transition failed'
        USING ERRCODE = 'serialization_failure';
    END IF;
    v_transitioned := true;
    v_match.status := 'partner_chat_started';
  END IF;

  RETURN QUERY SELECT v_chat.id, v_chat.match_id, v_chat.user_id,
    v_chat.partner_user_id, v_message_id, 'fox'::text, p_content,
    v_message_created_at, 'inserted'::text, v_match.status, v_transitioned;
END;
$$;

COMMENT ON FUNCTION public.persist_partner_fox_greeting(uuid, uuid, uuid, uuid, text) IS
  'Service-role-only atomic partner-Fox greeting persistence. Locks match -> chat -> sorted profiles, preserves an existing winner, and advances only fox_conversation_completed -> partner_chat_started.';

REVOKE ALL ON FUNCTION public.persist_partner_fox_greeting(uuid, uuid, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.persist_partner_fox_greeting(uuid, uuid, uuid, uuid, text)
  TO service_role;

-- Keep the ordinary message trigger in the same lock order as the RPC.  The
-- initial non-locking lookup obtains the match id; both relationship rows are
-- then locked match -> chat before the sorted profile helper.  This prevents
-- the former profile-first/message-vs-chat deadlock while preserving actor,
-- lineage, and exact-no-op checks.
CREATE OR REPLACE FUNCTION wingward_private.guard_partner_fox_message_mutual_eligibility()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_match_id uuid; v_match_a uuid; v_match_b uuid; v_chat_user_id uuid; v_chat_partner_id uuid;
  v_auth_user_id uuid; v_enforce_actor boolean;
BEGIN
 IF TG_OP = 'UPDATE' AND NEW.chat_id IS DISTINCT FROM OLD.chat_id THEN
  RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;

 -- Resolve the exact chat lineage without a lock, then validate the actor
 -- before taking either relationship lock. The locked lookups below repeat
 -- the lineage checks so a concurrent relabel/deletion still fails closed.
 SELECT chat_row.match_id, chat_row.user_id, chat_row.partner_user_id
   INTO v_match_id, v_chat_user_id, v_chat_partner_id
   FROM public.partner_fox_chats AS chat_row
  WHERE chat_row.id = NEW.chat_id;
 IF NOT FOUND THEN
  RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;

 SELECT match_row.user_a_id, match_row.user_b_id
   INTO v_match_a, v_match_b
   FROM public.matches AS match_row
  WHERE match_row.id = v_match_id
    AND ((v_chat_user_id = match_row.user_a_id AND v_chat_partner_id = match_row.user_b_id)
      OR (v_chat_user_id = match_row.user_b_id AND v_chat_partner_id = match_row.user_a_id));
 IF NOT FOUND THEN
  RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;

 v_auth_user_id := (SELECT auth.uid());
 v_enforce_actor := COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated'
   OR (COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none' AND session_user = 'authenticated');
 IF v_enforce_actor AND (v_auth_user_id IS NULL OR NOT EXISTS (
   SELECT 1 FROM public.user_profiles AS actor_profile
    WHERE actor_profile.id = v_chat_user_id
      AND actor_profile.auth_user_id = v_auth_user_id
 )) THEN
  RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;

 -- Relationship locks are deliberately acquired in the same order as the
 -- greeting RPC. Re-read the exact rows after waiting for those locks.
 SELECT match_row.user_a_id, match_row.user_b_id
   INTO v_match_a, v_match_b
   FROM public.matches AS match_row
  WHERE match_row.id = v_match_id
  FOR KEY SHARE;
 IF NOT FOUND THEN
  RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;

 SELECT chat_row.match_id, chat_row.user_id, chat_row.partner_user_id
   INTO v_match_id, v_chat_user_id, v_chat_partner_id
   FROM public.partner_fox_chats AS chat_row
  WHERE chat_row.id = NEW.chat_id
    AND chat_row.match_id = v_match_id
  FOR KEY SHARE;
 IF NOT FOUND OR v_chat_user_id IS NULL OR v_chat_partner_id IS NULL
    OR v_chat_user_id = v_chat_partner_id
    OR NOT ((v_chat_user_id = v_match_a AND v_chat_partner_id = v_match_b)
         OR (v_chat_user_id = v_match_b AND v_chat_partner_id = v_match_a)) THEN
  RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;

 IF wingward_private.lock_and_check_mutual_eligibility(v_match_a, v_match_b) THEN
  RETURN NEW;
 END IF;
 IF TG_OP = 'UPDATE' AND pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN
  RETURN NEW;
 END IF;
 RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
END;
$$;

REVOKE ALL ON FUNCTION wingward_private.guard_partner_fox_message_mutual_eligibility()
  FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.guard_partner_fox_message_mutual_eligibility() IS
  'Private partner-Fox-message INSERT/UPDATE backstop. Locks match -> chat with KEY SHARE before sorted current profiles, validates exact chat lineage and actor ownership, and permits only exact no-ops after revocation.';

DROP TRIGGER IF EXISTS partner_fox_messages_guard_mutual_eligibility ON public.partner_fox_messages;
CREATE TRIGGER partner_fox_messages_guard_mutual_eligibility
  BEFORE INSERT OR UPDATE ON public.partner_fox_messages
  FOR EACH ROW
  EXECUTE FUNCTION wingward_private.guard_partner_fox_message_mutual_eligibility();
