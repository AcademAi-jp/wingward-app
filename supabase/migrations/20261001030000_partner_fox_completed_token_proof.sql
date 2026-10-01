-- Authenticate completed greeting retries without retaining raw claim tokens.
-- Existing completed rows have no proof and fail closed through completion;
-- the existing owner-bound claim RPC remains their authoritative recovery path.
ALTER TABLE public.partner_fox_greeting_claims
  ADD COLUMN completed_claim_token_hash text,
  ADD CONSTRAINT partner_fox_completed_token_hash_check CHECK (
    completed_claim_token_hash IS NULL OR
    (status = 'completed' AND completed_claim_token_hash ~ '^[0-9a-f]{64}$')
  );
COMMENT ON COLUMN public.partner_fox_greeting_claims.completed_claim_token_hash IS
  'Private SHA-256 proof of the validated completion token; no raw token or greeting body.';

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
  -- Authenticate completion replay before reading the stored greeting body.
  IF v_claim.status = 'completed' AND (
    v_claim.completed_claim_token_hash IS NULL
    OR v_claim.completed_claim_token_hash IS DISTINCT FROM
       pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p_claim_token::text, 'UTF8')), 'hex')
  ) THEN
    RETURN QUERY SELECT 'stale'::text, NULL::uuid, NULL::uuid, NULL::text,
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
             completed_claim_token_hash = pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_claim.claim_token::text, 'UTF8')), 'hex'),
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
             completed_claim_token_hash = pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_claim.claim_token::text, 'UTF8')), 'hex'),
         message_id = v_message.id, updated_at = v_now
   WHERE claim_row.chat_id = p_chat_id;
  RETURN QUERY SELECT 'completed'::text, NULL::uuid, v_message.id, v_message.role,
    v_message.content, v_message.created_at, v_match.status, v_transitioned;
END;
$$;
