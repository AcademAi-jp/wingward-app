-- Owner-bound recovery reads for client-held message-send receipts.
-- Clients persist only owner/conversation/key/content-hash metadata; these
-- RPCs return a committed message or pair after current eligibility checks.

CREATE OR REPLACE FUNCTION public.recover_direct_chat_message_send(
  p_room_id uuid,
  p_sender_id uuid,
  p_idempotency_key uuid,
  p_content_sha256 text
)
RETURNS TABLE (
  outcome text,
  message_id uuid,
  message_content text,
  message_created_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_room public.direct_chat_rooms%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_claim public.direct_chat_message_idempotency%ROWTYPE;
  v_message public.direct_chat_messages%ROWTYPE;
BEGIN
  IF p_room_id IS NULL OR p_sender_id IS NULL OR p_idempotency_key IS NULL
     OR p_content_sha256 IS NULL OR p_content_sha256 !~ '^[0-9a-f]{64}$' THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  -- Match the direct-send lock order so a recovery read waits for an in-flight
  -- atomic insert before deciding that no committed row exists.
  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.id = p_room_id
   FOR UPDATE;
  IF NOT FOUND OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_room.match_id;
  IF NOT FOUND OR (p_sender_id <> v_match.user_a_id AND p_sender_id <> v_match.user_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF NOT wingward_private.lock_and_check_mutual_eligibility(v_match.user_a_id, v_match.user_b_id) THEN
    RETURN QUERY SELECT 'ineligible'::text, NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT claim_row.* INTO v_claim
    FROM public.direct_chat_message_idempotency AS claim_row
   WHERE claim_row.idempotency_key = p_idempotency_key
   FOR UPDATE;
  IF NOT FOUND OR v_claim.room_id IS DISTINCT FROM p_room_id
     OR v_claim.sender_id IS DISTINCT FROM p_sender_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF v_claim.content_sha256 IS DISTINCT FROM p_content_sha256 THEN
    RETURN QUERY SELECT 'conflict'::text, NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF v_claim.message_id IS NULL THEN
    RETURN QUERY SELECT 'missing'::text, NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT message_row.* INTO v_message
    FROM public.direct_chat_messages AS message_row
   WHERE message_row.id = v_claim.message_id
     AND message_row.room_id = p_room_id
     AND message_row.sender_id = p_sender_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'missing'::text, NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_message.content, 'UTF8')), 'hex')
     IS DISTINCT FROM p_content_sha256 THEN
    RETURN QUERY SELECT 'conflict'::text, NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  RETURN QUERY SELECT 'found'::text, v_message.id, v_message.content, v_message.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.recover_direct_chat_message_send(uuid, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.recover_direct_chat_message_send(uuid, uuid, uuid, text)
  TO service_role;
COMMENT ON FUNCTION public.recover_direct_chat_message_send(uuid, uuid, uuid, text) IS
  'Service-role-only, owner-bound lookup for a client retry receipt. It returns only a committed message in the active room after membership and mutual eligibility checks; SECURITY DEFINER keeps the private ledger inaccessible to API roles.';

CREATE OR REPLACE FUNCTION public.recover_partner_fox_message_send(
  p_chat_id uuid,
  p_owner_id uuid,
  p_idempotency_key uuid,
  p_content_sha256 text
)
RETURNS TABLE (
  outcome text,
  user_message_id uuid,
  user_content text,
  user_created_at timestamptz,
  fox_message_id uuid,
  fox_content text,
  fox_created_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_initial_match_id uuid;
  v_match public.matches%ROWTYPE;
  v_chat public.partner_fox_chats%ROWTYPE;
  v_send public.partner_fox_message_sends%ROWTYPE;
  v_user_message public.partner_fox_messages%ROWTYPE;
  v_fox_message public.partner_fox_messages%ROWTYPE;
  v_now timestamptz := pg_catalog.now();
BEGIN
  IF p_chat_id IS NULL OR p_owner_id IS NULL OR p_idempotency_key IS NULL
     OR p_content_sha256 IS NULL OR p_content_sha256 !~ '^[0-9a-f]{64}$' THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT chat_row.match_id INTO v_initial_match_id
    FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = p_chat_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  -- Keep the shared Partner Ward order: match -> chat -> sorted profiles -> ledger.
  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_initial_match_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT chat_row.* INTO v_chat
    FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = p_chat_id
     AND chat_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND OR v_chat.user_id IS DISTINCT FROM p_owner_id
     OR NOT ((v_chat.user_id = v_match.user_a_id AND v_chat.partner_user_id = v_match.user_b_id)
          OR (v_chat.user_id = v_match.user_b_id AND v_chat.partner_user_id = v_match.user_a_id))
     OR v_match.status NOT IN ('fox_conversation_completed', 'partner_chat_started',
          'direct_chat_requested', 'direct_chat_active', 'meetup_intent', 'meetup_confirmed') THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF NOT wingward_private.lock_and_check_mutual_eligibility(v_match.user_a_id, v_match.user_b_id) THEN
    RETURN QUERY SELECT 'ineligible'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  -- Recovery is also a safe place to close an expired provider lease. Once
  -- expired, the result stays unknown and its old token can never complete.
  UPDATE public.partner_fox_message_sends AS expired_send
     SET status = 'unknown', claim_token = NULL, lease_expires_at = NULL, updated_at = v_now
   WHERE expired_send.chat_id = p_chat_id
     AND expired_send.status = 'processing'
     AND (expired_send.lease_expires_at IS NULL OR expired_send.lease_expires_at <= v_now);

  SELECT send_row.* INTO v_send
    FROM public.partner_fox_message_sends AS send_row
   WHERE send_row.idempotency_key = p_idempotency_key
   FOR UPDATE;
  IF NOT FOUND OR v_send.chat_id IS DISTINCT FROM p_chat_id
     OR v_send.owner_id IS DISTINCT FROM p_owner_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF v_send.content_sha256 IS DISTINCT FROM p_content_sha256 THEN
    RETURN QUERY SELECT 'conflict'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF v_send.status IS DISTINCT FROM 'completed' THEN
    RETURN QUERY SELECT v_send.status, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT message_row.* INTO v_user_message
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.id = v_send.user_message_id
     AND message_row.chat_id = p_chat_id
     AND message_row.role = 'user';
  SELECT message_row.* INTO v_fox_message
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.id = v_send.fox_message_id
     AND message_row.chat_id = p_chat_id
     AND message_row.role = 'fox';
  IF v_user_message.id IS NULL OR v_fox_message.id IS NULL THEN
    RETURN QUERY SELECT 'missing'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_user_message.content, 'UTF8')), 'hex')
     IS DISTINCT FROM p_content_sha256 THEN
    RETURN QUERY SELECT 'conflict'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  RETURN QUERY SELECT 'completed'::text, v_user_message.id, v_user_message.content,
    v_user_message.created_at, v_fox_message.id, v_fox_message.content, v_fox_message.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.recover_partner_fox_message_send(uuid, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.recover_partner_fox_message_send(uuid, uuid, uuid, text)
  TO service_role;
COMMENT ON FUNCTION public.recover_partner_fox_message_send(uuid, uuid, uuid, text) IS
  'Service-role-only, owner-bound lookup for a client retry receipt. Completed sends replay their committed pair; expired processing sends become terminal unknown. SECURITY DEFINER keeps the private ledger inaccessible to API roles.';
