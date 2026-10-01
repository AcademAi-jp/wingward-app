-- Durable single-provider claim for the initial Partner Ward greeting.
-- The greeting body is stored only in partner_fox_messages; this private
-- ledger stores state and the authoritative message id, never a body copy.

CREATE TABLE public.partner_fox_greeting_claims (
  chat_id uuid PRIMARY KEY REFERENCES public.partner_fox_chats(id) ON DELETE CASCADE,
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  owner_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  partner_user_id uuid NOT NULL REFERENCES public.user_profiles(id),
  status text NOT NULL CHECK (status IN ('processing', 'retryable', 'completed', 'unknown')),
  claim_token uuid,
  lease_expires_at timestamptz,
  message_id uuid REFERENCES public.partner_fox_messages(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  CHECK (
    (status = 'processing' AND claim_token IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR (status <> 'processing' AND claim_token IS NULL AND lease_expires_at IS NULL)
  ),
  CHECK (
    status = 'completed' OR message_id IS NULL
  )
);

ALTER TABLE public.partner_fox_greeting_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.partner_fox_greeting_claims FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE public.partner_fox_greeting_claims IS
  'Private initial Partner Ward greeting claim ledger. It stores no greeting body; only service-role RPCs can read or write it.';

CREATE OR REPLACE FUNCTION public.claim_partner_fox_greeting(
  p_chat_id uuid,
  p_match_id uuid,
  p_user_id uuid,
  p_partner_user_id uuid
)
RETURNS TABLE (
  outcome text,
  claim_token uuid,
  message_id uuid,
  message_role text,
  message_content text,
  message_created_at timestamptz,
  match_status text,
  transitioned boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_initial_match_id uuid;
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_chat public.partner_fox_chats%ROWTYPE;
  v_compatibility public.fox_conversations%ROWTYPE;
  v_claim public.partner_fox_greeting_claims%ROWTYPE;
  v_message public.partner_fox_messages%ROWTYPE;
  v_token uuid;
  v_now timestamptz;
BEGIN
  IF p_chat_id IS NULL OR p_match_id IS NULL OR p_user_id IS NULL
     OR p_partner_user_id IS NULL OR p_user_id = p_partner_user_id THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT chat_row.match_id INTO v_initial_match_id
    FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = p_chat_id;
  IF NOT FOUND OR v_initial_match_id IS DISTINCT FROM p_match_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  -- Preserve greeting/message trigger order: match -> room -> chat ->
  -- compatibility conversation -> sorted current profiles -> claim row.
  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = p_match_id
   FOR UPDATE;
  IF NOT FOUND
     OR (p_user_id <> v_match.user_a_id AND p_user_id <> v_match.user_b_id)
     OR (p_partner_user_id <> v_match.user_a_id AND p_partner_user_id <> v_match.user_b_id)
     OR v_match.status NOT IN (
       'fox_conversation_completed', 'partner_chat_started', 'direct_chat_requested',
       'direct_chat_active', 'meetup_intent', 'meetup_confirmed'
     ) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.match_id = v_match.id
   FOR SHARE;
  IF FOUND AND v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;
  IF v_match.status IN ('direct_chat_active', 'meetup_intent', 'meetup_confirmed')
     AND v_room.id IS NULL THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT chat_row.* INTO v_chat
    FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = p_chat_id
     AND chat_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND OR v_chat.user_id IS DISTINCT FROM p_user_id
     OR v_chat.partner_user_id IS DISTINCT FROM p_partner_user_id
     OR NOT ((v_chat.user_id = v_match.user_a_id AND v_chat.partner_user_id = v_match.user_b_id)
          OR (v_chat.user_id = v_match.user_b_id AND v_chat.partner_user_id = v_match.user_a_id)) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT conversation_row.* INTO v_compatibility
    FROM public.fox_conversations AS conversation_row
   WHERE conversation_row.match_id = v_match.id
     AND conversation_row.purpose = 'compatibility'
   FOR SHARE;
  IF NOT FOUND OR v_compatibility.status IS DISTINCT FROM 'completed' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;
  IF NOT wingward_private.lock_and_check_mutual_eligibility(v_match.user_a_id, v_match.user_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT claim_row.* INTO v_claim
    FROM public.partner_fox_greeting_claims AS claim_row
   WHERE claim_row.chat_id = p_chat_id
   FOR UPDATE;
  v_now := pg_catalog.clock_timestamp();
  IF FOUND THEN
    IF v_claim.match_id IS DISTINCT FROM p_match_id
       OR v_claim.owner_id IS DISTINCT FROM p_user_id
       OR v_claim.partner_user_id IS DISTINCT FROM p_partner_user_id THEN
      RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
        NULL::text, NULL::timestamptz, NULL::text, false;
      RETURN;
    END IF;

    IF v_claim.status = 'completed' THEN
      SELECT message_row.* INTO v_message
        FROM public.partner_fox_messages AS message_row
       WHERE message_row.id = v_claim.message_id
         AND message_row.chat_id = p_chat_id
         AND message_row.role = 'fox';
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'missing'::text, NULL::uuid, NULL::uuid, NULL::text,
          NULL::text, NULL::timestamptz, v_match.status, false;
        RETURN;
      END IF;
      RETURN QUERY SELECT 'completed'::text, NULL::uuid, v_message.id, v_message.role,
        v_message.content, v_message.created_at, v_match.status, false;
      RETURN;
    ELSIF v_claim.status = 'unknown' THEN
      RETURN QUERY SELECT 'unknown'::text, NULL::uuid, NULL::uuid, NULL::text,
        NULL::text, NULL::timestamptz, v_match.status, false;
      RETURN;
    ELSIF v_claim.status = 'processing' THEN
      IF v_claim.lease_expires_at > v_now THEN
        RETURN QUERY SELECT 'busy'::text, NULL::uuid, NULL::uuid, NULL::text,
          NULL::text, NULL::timestamptz, v_match.status, false;
        RETURN;
      END IF;
      UPDATE public.partner_fox_greeting_claims AS claim_row
         SET status = 'unknown', claim_token = NULL, lease_expires_at = NULL, updated_at = v_now
       WHERE claim_row.chat_id = p_chat_id;
      RETURN QUERY SELECT 'unknown'::text, NULL::uuid, NULL::uuid, NULL::text,
        NULL::text, NULL::timestamptz, v_match.status, false;
      RETURN;
    END IF;

    -- Only the explicit pre-provider failure RPC can create retryable state.
    -- Recheck that no message appeared outside the claim path before issuing a
    -- new token; any such row makes the old provider outcome unsafe to repeat.
    SELECT message_row.* INTO v_message
      FROM public.partner_fox_messages AS message_row
     WHERE message_row.chat_id = p_chat_id
     ORDER BY message_row.created_at, message_row.id
     LIMIT 1;
    IF FOUND THEN
      IF v_message.role = 'fox' THEN
        UPDATE public.partner_fox_greeting_claims AS claim_row
           SET status = 'completed', claim_token = NULL, lease_expires_at = NULL,
               message_id = v_message.id, updated_at = v_now
         WHERE claim_row.chat_id = p_chat_id;
        RETURN QUERY SELECT 'completed'::text, NULL::uuid, v_message.id, v_message.role,
          v_message.content, v_message.created_at, v_match.status, false;
      ELSE
        UPDATE public.partner_fox_greeting_claims AS claim_row
           SET status = 'unknown', claim_token = NULL, lease_expires_at = NULL, updated_at = v_now
         WHERE claim_row.chat_id = p_chat_id;
        RETURN QUERY SELECT 'message_present'::text, NULL::uuid, NULL::uuid, NULL::text,
          NULL::text, NULL::timestamptz, v_match.status, false;
      END IF;
      RETURN;
    END IF;

    v_token := pg_catalog.gen_random_uuid();
    UPDATE public.partner_fox_greeting_claims AS claim_row
       SET status = 'processing', claim_token = v_token,
           lease_expires_at = v_now + interval '3 minutes', updated_at = v_now
     WHERE claim_row.chat_id = p_chat_id;
    RETURN QUERY SELECT 'claimed'::text, v_token, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, v_match.status, false;
    RETURN;
  END IF;

  -- Adopt an already-persisted legacy greeting as authoritative. A user-first
  -- chat is never overwritten by the initial greeting path.
  SELECT message_row.* INTO v_message
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.chat_id = p_chat_id
   ORDER BY message_row.created_at, message_row.id
   LIMIT 1;
  IF FOUND THEN
    IF v_message.role <> 'fox' THEN
      RETURN QUERY SELECT 'message_present'::text, NULL::uuid, NULL::uuid, NULL::text,
        NULL::text, NULL::timestamptz, v_match.status, false;
      RETURN;
    END IF;
    INSERT INTO public.partner_fox_greeting_claims (
      chat_id, match_id, owner_id, partner_user_id, status, message_id
    ) VALUES (
      p_chat_id, p_match_id, p_user_id, p_partner_user_id, 'completed', v_message.id
    );
    RETURN QUERY SELECT 'completed'::text, NULL::uuid, v_message.id, v_message.role,
      v_message.content, v_message.created_at, v_match.status, false;
    RETURN;
  END IF;

  v_token := pg_catalog.gen_random_uuid();
  v_now := pg_catalog.clock_timestamp();
  INSERT INTO public.partner_fox_greeting_claims (
    chat_id, match_id, owner_id, partner_user_id, status, claim_token, lease_expires_at
  ) VALUES (
    p_chat_id, p_match_id, p_user_id, p_partner_user_id,
    'processing', v_token, v_now + interval '3 minutes'
  );
  RETURN QUERY SELECT 'claimed'::text, v_token, NULL::uuid, NULL::text,
    NULL::text, NULL::timestamptz, v_match.status, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_partner_fox_greeting(
  p_chat_id uuid,
  p_claim_token uuid,
  p_content text
)
RETURNS TABLE (
  outcome text,
  claim_token uuid,
  message_id uuid,
  message_role text,
  message_content text,
  message_created_at timestamptz,
  match_status text,
  transitioned boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_initial public.partner_fox_greeting_claims%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_chat public.partner_fox_chats%ROWTYPE;
  v_compatibility public.fox_conversations%ROWTYPE;
  v_claim public.partner_fox_greeting_claims%ROWTYPE;
  v_message public.partner_fox_messages%ROWTYPE;
  v_now timestamptz;
  v_transitioned boolean := false;
BEGIN
  IF p_chat_id IS NULL OR p_claim_token IS NULL OR p_content IS NULL
     OR p_content ~ '^[[:space:]]*$' OR pg_catalog.char_length(p_content) > 2000 THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT claim_row.* INTO v_initial
    FROM public.partner_fox_greeting_claims AS claim_row
   WHERE claim_row.chat_id = p_chat_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;
  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_initial.match_id
   FOR UPDATE;
  IF NOT FOUND OR v_match.status NOT IN (
    'fox_conversation_completed', 'partner_chat_started', 'direct_chat_requested',
    'direct_chat_active', 'meetup_intent', 'meetup_confirmed'
  ) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.match_id = v_match.id
   FOR SHARE;
  IF FOUND AND v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;
  IF v_match.status IN ('direct_chat_active', 'meetup_intent', 'meetup_confirmed')
     AND v_room.id IS NULL THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT chat_row.* INTO v_chat
    FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = p_chat_id
     AND chat_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND OR v_chat.user_id IS DISTINCT FROM v_initial.owner_id
     OR v_chat.partner_user_id IS DISTINCT FROM v_initial.partner_user_id
     OR v_initial.match_id IS DISTINCT FROM v_match.id
     OR NOT ((v_chat.user_id = v_match.user_a_id AND v_chat.partner_user_id = v_match.user_b_id)
          OR (v_chat.user_id = v_match.user_b_id AND v_chat.partner_user_id = v_match.user_a_id)) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT conversation_row.* INTO v_compatibility
    FROM public.fox_conversations AS conversation_row
   WHERE conversation_row.match_id = v_match.id
     AND conversation_row.purpose = 'compatibility'
   FOR SHARE;
  IF NOT FOUND OR v_compatibility.status IS DISTINCT FROM 'completed'
     OR NOT wingward_private.lock_and_check_mutual_eligibility(v_match.user_a_id, v_match.user_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, NULL::text, false;
    RETURN;
  END IF;

  SELECT claim_row.* INTO v_claim
    FROM public.partner_fox_greeting_claims AS claim_row
   WHERE claim_row.chat_id = p_chat_id
   FOR UPDATE;
  v_now := pg_catalog.clock_timestamp();
  IF NOT FOUND OR v_claim.status = 'unknown' THEN
    RETURN QUERY SELECT 'unknown'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, v_match.status, false;
    RETURN;
  END IF;
  IF v_claim.status = 'completed' THEN
    SELECT message_row.* INTO v_message
      FROM public.partner_fox_messages AS message_row
     WHERE message_row.id = v_claim.message_id
       AND message_row.chat_id = p_chat_id
       AND message_row.role = 'fox';
    IF NOT FOUND THEN
      RETURN QUERY SELECT 'missing'::text, NULL::uuid, NULL::uuid, NULL::text,
        NULL::text, NULL::timestamptz, v_match.status, false;
      RETURN;
    END IF;
    RETURN QUERY SELECT 'completed'::text, NULL::uuid, v_message.id, v_message.role,
      v_message.content, v_message.created_at, v_match.status, false;
    RETURN;
  END IF;
  IF v_claim.status IS DISTINCT FROM 'processing'
     OR v_claim.claim_token IS DISTINCT FROM p_claim_token THEN
    RETURN QUERY SELECT 'stale'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, v_match.status, false;
    RETURN;
  END IF;
  IF v_claim.lease_expires_at IS NULL OR v_claim.lease_expires_at <= v_now THEN
    UPDATE public.partner_fox_greeting_claims AS claim_row
       SET status = 'unknown', claim_token = NULL, lease_expires_at = NULL, updated_at = v_now
     WHERE claim_row.chat_id = p_chat_id;
    RETURN QUERY SELECT 'unknown'::text, NULL::uuid, NULL::uuid, NULL::text,
      NULL::text, NULL::timestamptz, v_match.status, false;
    RETURN;
  END IF;

  SELECT message_row.* INTO v_message
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.chat_id = p_chat_id
   ORDER BY message_row.created_at, message_row.id
   LIMIT 1;
  IF FOUND THEN
    IF v_message.role = 'fox' THEN
      UPDATE public.partner_fox_greeting_claims AS claim_row
         SET status = 'completed', claim_token = NULL, lease_expires_at = NULL,
             message_id = v_message.id, updated_at = v_now
       WHERE claim_row.chat_id = p_chat_id;
      RETURN QUERY SELECT 'completed'::text, NULL::uuid, v_message.id, v_message.role,
        v_message.content, v_message.created_at, v_match.status, false;
    ELSE
      UPDATE public.partner_fox_greeting_claims AS claim_row
         SET status = 'unknown', claim_token = NULL, lease_expires_at = NULL, updated_at = v_now
       WHERE claim_row.chat_id = p_chat_id;
      RETURN QUERY SELECT 'message_present'::text, NULL::uuid, NULL::uuid, NULL::text,
        NULL::text, NULL::timestamptz, v_match.status, false;
    END IF;
    RETURN;
  END IF;

  INSERT INTO public.partner_fox_messages (chat_id, role, content)
  VALUES (v_chat.id, 'fox', p_content)
  RETURNING * INTO v_message;

  IF v_match.status = 'fox_conversation_completed' THEN
    UPDATE public.matches AS match_row
       SET status = 'partner_chat_started', updated_at = v_now
     WHERE match_row.id = v_match.id
       AND match_row.status = 'fox_conversation_completed';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'partner fox greeting status transition failed'
        USING ERRCODE = 'serialization_failure';
    END IF;
    v_transitioned := true;
    v_match.status := 'partner_chat_started';
  END IF;

  UPDATE public.partner_fox_greeting_claims AS claim_row
     SET status = 'completed', claim_token = NULL, lease_expires_at = NULL,
         message_id = v_message.id, updated_at = v_now
   WHERE claim_row.chat_id = p_chat_id;
  RETURN QUERY SELECT 'completed'::text, NULL::uuid, v_message.id, v_message.role,
    v_message.content, v_message.created_at, v_match.status, v_transitioned;
END;
$$;

CREATE OR REPLACE FUNCTION public.retry_partner_fox_greeting_before_provider(
  p_chat_id uuid,
  p_claim_token uuid
)
RETURNS TABLE (outcome text, claim_token uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_initial public.partner_fox_greeting_claims%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_chat public.partner_fox_chats%ROWTYPE;
  v_compatibility public.fox_conversations%ROWTYPE;
  v_claim public.partner_fox_greeting_claims%ROWTYPE;
  v_message public.partner_fox_messages%ROWTYPE;
  v_now timestamptz;
BEGIN
  IF p_chat_id IS NULL OR p_claim_token IS NULL THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid;
    RETURN;
  END IF;
  SELECT claim_row.* INTO v_initial
    FROM public.partner_fox_greeting_claims AS claim_row
   WHERE claim_row.chat_id = p_chat_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
    RETURN;
  END IF;
  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_initial.match_id
   FOR UPDATE;
  IF NOT FOUND OR v_match.status NOT IN (
    'fox_conversation_completed', 'partner_chat_started', 'direct_chat_requested',
    'direct_chat_active', 'meetup_intent', 'meetup_confirmed'
  ) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
    RETURN;
  END IF;
  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.match_id = v_match.id
   FOR SHARE;
  IF (FOUND AND v_room.status IS DISTINCT FROM 'active')
     OR (v_match.status IN ('direct_chat_active', 'meetup_intent', 'meetup_confirmed') AND v_room.id IS NULL) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
    RETURN;
  END IF;
  SELECT chat_row.* INTO v_chat
    FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = p_chat_id
     AND chat_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND OR v_chat.user_id IS DISTINCT FROM v_initial.owner_id
     OR v_chat.partner_user_id IS DISTINCT FROM v_initial.partner_user_id
     OR NOT ((v_chat.user_id = v_match.user_a_id AND v_chat.partner_user_id = v_match.user_b_id)
          OR (v_chat.user_id = v_match.user_b_id AND v_chat.partner_user_id = v_match.user_a_id)) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
    RETURN;
  END IF;
  SELECT conversation_row.* INTO v_compatibility
    FROM public.fox_conversations AS conversation_row
   WHERE conversation_row.match_id = v_match.id
     AND conversation_row.purpose = 'compatibility'
   FOR SHARE;
  IF NOT FOUND OR v_compatibility.status IS DISTINCT FROM 'completed'
     OR NOT wingward_private.lock_and_check_mutual_eligibility(v_match.user_a_id, v_match.user_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid;
    RETURN;
  END IF;

  SELECT claim_row.* INTO v_claim
    FROM public.partner_fox_greeting_claims AS claim_row
   WHERE claim_row.chat_id = p_chat_id
   FOR UPDATE;
  v_now := pg_catalog.clock_timestamp();
  IF NOT FOUND OR v_claim.status IS DISTINCT FROM 'processing'
     OR v_claim.claim_token IS DISTINCT FROM p_claim_token THEN
    RETURN QUERY SELECT 'stale'::text, NULL::uuid;
    RETURN;
  END IF;
  IF v_claim.lease_expires_at IS NULL OR v_claim.lease_expires_at <= v_now THEN
    UPDATE public.partner_fox_greeting_claims AS claim_row
       SET status = 'unknown', claim_token = NULL, lease_expires_at = NULL, updated_at = v_now
     WHERE claim_row.chat_id = p_chat_id;
    RETURN QUERY SELECT 'unknown'::text, NULL::uuid;
    RETURN;
  END IF;
  SELECT message_row.* INTO v_message
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.chat_id = p_chat_id
   ORDER BY message_row.created_at, message_row.id
   LIMIT 1;
  IF FOUND THEN
    UPDATE public.partner_fox_greeting_claims AS claim_row
       SET status = 'unknown', claim_token = NULL, lease_expires_at = NULL,
           message_id = NULL, updated_at = v_now
     WHERE claim_row.chat_id = p_chat_id;
    RETURN QUERY SELECT 'message_present'::text, NULL::uuid;
    RETURN;
  END IF;
  UPDATE public.partner_fox_greeting_claims AS claim_row
     SET status = 'retryable', claim_token = NULL, lease_expires_at = NULL, updated_at = v_now
   WHERE claim_row.chat_id = p_chat_id;
  RETURN QUERY SELECT 'retryable'::text, NULL::uuid;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_partner_fox_greeting(uuid, uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_partner_fox_greeting(uuid, uuid, uuid, uuid)
  TO service_role;
REVOKE ALL ON FUNCTION public.complete_partner_fox_greeting(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_partner_fox_greeting(uuid, uuid, text)
  TO service_role;
REVOKE ALL ON FUNCTION public.retry_partner_fox_greeting_before_provider(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.retry_partner_fox_greeting_before_provider(uuid, uuid)
  TO service_role;

COMMENT ON FUNCTION public.claim_partner_fox_greeting(uuid, uuid, uuid, uuid) IS
  'Service-role-only initial greeting claim. Locks match -> room -> chat -> completed compatibility conversation -> current profiles, returns busy during a live lease, replays only the stored greeting, and seals expired provider work as unknown.';
COMMENT ON FUNCTION public.complete_partner_fox_greeting(uuid, uuid, text) IS
  'Service-role-only initial greeting completion. A live matching claim token atomically inserts one Fox greeting, advances only fox_conversation_completed, and records its message id; stale tokens cannot write.';
COMMENT ON FUNCTION public.retry_partner_fox_greeting_before_provider(uuid, uuid) IS
  'Service-role-only retry release for a claim whose provider was definitely not started. Only the matching live processing token with an empty chat becomes retryable.';
