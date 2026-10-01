-- Server-side idempotency for chat writes.
-- Direct messages persist the key and message in one transaction. Partner
-- Ward calls persist a claim before provider work and only replay completed
-- rows. A claim that outlives its lease is UNKNOWN; it is never regenerated.

CREATE TABLE public.direct_chat_message_idempotency (
  idempotency_key uuid PRIMARY KEY,
  room_id uuid NOT NULL REFERENCES public.direct_chat_rooms(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
  message_id uuid REFERENCES public.direct_chat_messages(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

COMMENT ON TABLE public.direct_chat_message_idempotency IS
  'Private direct-message idempotency ledger. SHA-256 is supplied by the trusted service-role API; only the service-role-only atomic RPC can read or write this table.';

ALTER TABLE public.direct_chat_message_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.direct_chat_message_idempotency FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.persist_direct_chat_message(
  p_room_id uuid,
  p_sender_id uuid,
  p_idempotency_key uuid,
  p_content text,
  p_content_sha256 text
)
RETURNS TABLE (
  room_id uuid,
  sender_id uuid,
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
  v_claim_inserted boolean := false;
  v_message public.direct_chat_messages%ROWTYPE;
BEGIN
  IF p_room_id IS NULL OR p_sender_id IS NULL OR p_idempotency_key IS NULL
     OR p_content IS NULL OR pg_catalog.char_length(p_content) < 1
     OR pg_catalog.char_length(p_content) > 1000
     OR p_content_sha256 IS NULL OR p_content_sha256 !~ '^[0-9a-f]{64}$' THEN
    RETURN QUERY SELECT p_room_id, p_sender_id, 'invalid_input'::text,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  -- Keep the direct-chat trigger lock order: active room, then sorted profiles.
  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.id = p_room_id
   FOR UPDATE;
  IF NOT FOUND OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT p_room_id, p_sender_id, 'not_found'::text,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_room.match_id;
  IF NOT FOUND OR (p_sender_id <> v_match.user_a_id AND p_sender_id <> v_match.user_b_id) THEN
    RETURN QUERY SELECT p_room_id, p_sender_id, 'not_found'::text,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF NOT wingward_private.lock_and_check_mutual_eligibility(v_match.user_a_id, v_match.user_b_id) THEN
    RETURN QUERY SELECT p_room_id, p_sender_id, 'ineligible'::text,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  INSERT INTO public.direct_chat_message_idempotency AS claim_row
    (idempotency_key, room_id, sender_id, content_sha256)
  VALUES (p_idempotency_key, p_room_id, p_sender_id, p_content_sha256)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING claim_row.* INTO v_claim;
  v_claim_inserted := FOUND;

  IF NOT v_claim_inserted THEN
    SELECT claim_row.* INTO v_claim
      FROM public.direct_chat_message_idempotency AS claim_row
     WHERE claim_row.idempotency_key = p_idempotency_key
     FOR UPDATE;
    IF NOT FOUND OR v_claim.room_id IS DISTINCT FROM p_room_id
       OR v_claim.sender_id IS DISTINCT FROM p_sender_id
       OR v_claim.content_sha256 IS DISTINCT FROM p_content_sha256 THEN
      RETURN QUERY SELECT p_room_id, p_sender_id, 'conflict'::text,
        NULL::uuid, NULL::text, NULL::timestamptz;
      RETURN;
    END IF;
    IF v_claim.message_id IS NULL THEN
      RETURN QUERY SELECT p_room_id, p_sender_id, 'missing'::text,
        NULL::uuid, NULL::text, NULL::timestamptz;
      RETURN;
    END IF;
    SELECT message_row.* INTO v_message
      FROM public.direct_chat_messages AS message_row
     WHERE message_row.id = v_claim.message_id
       AND message_row.room_id = p_room_id
       AND message_row.sender_id = p_sender_id;
    IF NOT FOUND THEN
      RETURN QUERY SELECT p_room_id, p_sender_id, 'missing'::text,
        NULL::uuid, NULL::text, NULL::timestamptz;
      RETURN;
    END IF;
    IF v_message.content IS DISTINCT FROM p_content THEN
      RETURN QUERY SELECT p_room_id, p_sender_id, 'conflict'::text,
        NULL::uuid, NULL::text, NULL::timestamptz;
      RETURN;
    END IF;
    RETURN QUERY SELECT p_room_id, p_sender_id, 'replayed'::text,
      v_message.id, v_message.content, v_message.created_at;
    RETURN;
  END IF;

  INSERT INTO public.direct_chat_messages (room_id, sender_id, content)
  VALUES (p_room_id, p_sender_id, p_content)
  RETURNING * INTO v_message;
  UPDATE public.direct_chat_message_idempotency AS claim_row
     SET message_id = v_message.id
   WHERE claim_row.idempotency_key = p_idempotency_key;
  RETURN QUERY SELECT p_room_id, p_sender_id, 'inserted'::text,
    v_message.id, v_message.content, v_message.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.persist_direct_chat_message(uuid, uuid, uuid, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.persist_direct_chat_message(uuid, uuid, uuid, text, text)
  TO service_role;
COMMENT ON FUNCTION public.persist_direct_chat_message(uuid, uuid, uuid, text, text) IS
  'Service-role-only atomic direct-message insert/replay. SECURITY DEFINER keeps the private eligibility lock helper and idempotency ledger inaccessible to API roles while the empty search_path and explicit grants limit the RPC surface.';

CREATE TABLE public.partner_fox_message_sends (
  idempotency_key uuid PRIMARY KEY,
  chat_id uuid NOT NULL REFERENCES public.partner_fox_chats(id) ON DELETE CASCADE,
  owner_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[0-9a-f]{64}$'),
  send_sequence bigint NOT NULL CHECK (send_sequence >= 1),
  status text NOT NULL CHECK (status IN ('processing', 'completed', 'failed', 'unknown')),
  claim_token uuid,
  lease_expires_at timestamptz,
  user_message_id uuid REFERENCES public.partner_fox_messages(id) ON DELETE SET NULL,
  fox_message_id uuid REFERENCES public.partner_fox_messages(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  UNIQUE (chat_id, send_sequence)
);

CREATE INDEX partner_fox_message_sends_chat_sequence_idx
  ON public.partner_fox_message_sends (chat_id, send_sequence DESC);
CREATE UNIQUE INDEX partner_fox_message_sends_one_processing_per_chat_idx
  ON public.partner_fox_message_sends (chat_id)
  WHERE status = 'processing';

ALTER TABLE public.partner_fox_message_sends ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.partner_fox_message_sends FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE public.partner_fox_message_sends IS
  'Private Partner Ward send ledger. SHA-256 is supplied by the trusted service-role API; unknown provider outcomes are terminal and cannot be regenerated by a retry.';

CREATE OR REPLACE FUNCTION public.claim_partner_fox_message_send(
  p_chat_id uuid,
  p_owner_id uuid,
  p_idempotency_key uuid,
  p_content text,
  p_content_sha256 text
)
RETURNS TABLE (
  outcome text,
  user_message_id uuid,
  user_content text,
  user_created_at timestamptz,
  fox_message_id uuid,
  fox_content text,
  fox_created_at timestamptz,
  claim_token uuid
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
  v_inserted boolean := false;
  v_next_sequence bigint;
  v_token uuid;
  v_now timestamptz := pg_catalog.now();
BEGIN
  IF p_chat_id IS NULL OR p_owner_id IS NULL OR p_idempotency_key IS NULL
     OR p_content IS NULL OR pg_catalog.char_length(p_content) < 1
     OR pg_catalog.char_length(p_content) > 2000
     OR p_content_sha256 IS NULL OR p_content_sha256 !~ '^[0-9a-f]{64}$' THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;

  SELECT chat_row.match_id INTO v_initial_match_id
    FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = p_chat_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  -- Preserve the shared Partner Ward order: match -> chat -> sorted profiles.
  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_initial_match_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
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
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  IF NOT wingward_private.lock_and_check_mutual_eligibility(v_match.user_a_id, v_match.user_b_id) THEN
    RETURN QUERY SELECT 'ineligible'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;

  -- Expired work may have reached the provider before its worker disappeared.
  -- Seal it as unknown before admitting a later key; the old claim token can
  -- never complete and no second provider generation can start for that key.
  UPDATE public.partner_fox_message_sends AS expired_send
     SET status = 'unknown', claim_token = NULL, lease_expires_at = NULL, updated_at = v_now
   WHERE expired_send.chat_id = p_chat_id
     AND expired_send.status = 'processing'
     AND (expired_send.lease_expires_at IS NULL OR expired_send.lease_expires_at <= v_now);

  SELECT send_row.* INTO v_send
    FROM public.partner_fox_message_sends AS send_row
   WHERE send_row.idempotency_key = p_idempotency_key
   FOR UPDATE;
  IF FOUND THEN
    IF v_send.chat_id IS DISTINCT FROM p_chat_id
       OR v_send.owner_id IS DISTINCT FROM p_owner_id
       OR v_send.content_sha256 IS DISTINCT FROM p_content_sha256 THEN
      RETURN QUERY SELECT 'conflict'::text, NULL::uuid, NULL::text, NULL::timestamptz,
        NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
      RETURN;
    END IF;
    IF v_send.status = 'completed' THEN
      SELECT message_row.* INTO v_user_message FROM public.partner_fox_messages AS message_row
       WHERE message_row.id = v_send.user_message_id AND message_row.chat_id = p_chat_id AND message_row.role = 'user';
      SELECT message_row.* INTO v_fox_message FROM public.partner_fox_messages AS message_row
       WHERE message_row.id = v_send.fox_message_id AND message_row.chat_id = p_chat_id AND message_row.role = 'fox';
      IF v_user_message.id IS NULL OR v_fox_message.id IS NULL THEN
        RETURN QUERY SELECT 'missing'::text, NULL::uuid, NULL::text, NULL::timestamptz,
          NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      IF v_user_message.content IS DISTINCT FROM p_content THEN
        RETURN QUERY SELECT 'conflict'::text, NULL::uuid, NULL::text, NULL::timestamptz,
          NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      RETURN QUERY SELECT 'replayed'::text, v_user_message.id, v_user_message.content, v_user_message.created_at,
        v_fox_message.id, v_fox_message.content, v_fox_message.created_at, NULL::uuid;
      RETURN;
    ELSIF v_send.status = 'unknown' THEN
      RETURN QUERY SELECT 'unknown'::text, v_send.user_message_id, NULL::text, NULL::timestamptz,
        NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
      RETURN;
    ELSIF v_send.status = 'processing' THEN
      IF v_send.lease_expires_at > v_now THEN
        RETURN QUERY SELECT 'processing'::text, v_send.user_message_id, NULL::text, NULL::timestamptz,
          NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
        RETURN;
      END IF;
      UPDATE public.partner_fox_message_sends AS send_row
         SET status = 'unknown', claim_token = NULL, lease_expires_at = NULL, updated_at = v_now
       WHERE send_row.idempotency_key = p_idempotency_key;
      RETURN QUERY SELECT 'unknown'::text, v_send.user_message_id, NULL::text, NULL::timestamptz,
        NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
      RETURN;
    END IF;

    -- A definite pre-provider rejection is retryable only while this is still
    -- the newest send. Never let an old failed attempt overtake later chat.
    SELECT pg_catalog.max(send_row.send_sequence) INTO v_next_sequence
      FROM public.partner_fox_message_sends AS send_row
     WHERE send_row.chat_id = p_chat_id;
    IF v_send.send_sequence IS DISTINCT FROM v_next_sequence THEN
      RETURN QUERY SELECT 'stale'::text, NULL::uuid, NULL::text, NULL::timestamptz,
        NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
      RETURN;
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.partner_fox_message_sends AS other_send
       WHERE other_send.chat_id = p_chat_id AND other_send.status = 'processing'
    ) THEN
      RETURN QUERY SELECT 'busy'::text, NULL::uuid, NULL::text, NULL::timestamptz,
        NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
      RETURN;
    END IF;
    v_token := pg_catalog.gen_random_uuid();
    INSERT INTO public.partner_fox_messages (chat_id, role, content)
      VALUES (p_chat_id, 'user', p_content)
      RETURNING * INTO v_user_message;
    UPDATE public.partner_fox_message_sends AS send_row
       SET status = 'processing', claim_token = v_token,
           lease_expires_at = v_now + interval '3 minutes',
           user_message_id = v_user_message.id, fox_message_id = NULL, updated_at = v_now
     WHERE send_row.idempotency_key = p_idempotency_key;
    RETURN QUERY SELECT 'claimed'::text, v_user_message.id, v_user_message.content, v_user_message.created_at,
      NULL::uuid, NULL::text, NULL::timestamptz, v_token;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.partner_fox_message_sends AS other_send
     WHERE other_send.chat_id = p_chat_id AND other_send.status = 'processing'
  ) THEN
    RETURN QUERY SELECT 'busy'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT COALESCE(pg_catalog.max(send_row.send_sequence), 0) + 1 INTO v_next_sequence
    FROM public.partner_fox_message_sends AS send_row
   WHERE send_row.chat_id = p_chat_id;
  v_token := pg_catalog.gen_random_uuid();
  INSERT INTO public.partner_fox_message_sends (
    idempotency_key, chat_id, owner_id, content_sha256, send_sequence,
    status, claim_token, lease_expires_at
  ) VALUES (
    p_idempotency_key, p_chat_id, p_owner_id, p_content_sha256, v_next_sequence,
    'processing', v_token, v_now + interval '3 minutes'
  ) ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING * INTO v_send;
  v_inserted := FOUND;
  IF NOT v_inserted THEN
    -- A global key may race across two separately locked chats. Do not let the
    -- losing request fall through to provider work or disclose the other row.
    RETURN QUERY SELECT 'conflict'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  INSERT INTO public.partner_fox_messages (chat_id, role, content)
    VALUES (p_chat_id, 'user', p_content)
    RETURNING * INTO v_user_message;
  UPDATE public.partner_fox_message_sends AS send_row
     SET user_message_id = v_user_message.id, updated_at = v_now
   WHERE send_row.idempotency_key = p_idempotency_key;
  RETURN QUERY SELECT 'claimed'::text, v_user_message.id, v_user_message.content, v_user_message.created_at,
    NULL::uuid, NULL::text, NULL::timestamptz, v_token;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_partner_fox_message_send(
  p_idempotency_key uuid,
  p_claim_token uuid,
  p_fox_content text
)
RETURNS TABLE (
  outcome text,
  user_message_id uuid,
  user_content text,
  user_created_at timestamptz,
  fox_message_id uuid,
  fox_content text,
  fox_created_at timestamptz,
  claim_token uuid
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_initial public.partner_fox_message_sends%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_chat public.partner_fox_chats%ROWTYPE;
  v_send public.partner_fox_message_sends%ROWTYPE;
  v_user_message public.partner_fox_messages%ROWTYPE;
  v_fox_message public.partner_fox_messages%ROWTYPE;
  v_now timestamptz := pg_catalog.now();
BEGIN
  IF p_idempotency_key IS NULL OR p_claim_token IS NULL OR p_fox_content IS NULL
     OR p_fox_content ~ '^[[:space:]]*$' OR pg_catalog.char_length(p_fox_content) > 2000 THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT send_row.* INTO v_initial FROM public.partner_fox_message_sends AS send_row
   WHERE send_row.idempotency_key = p_idempotency_key;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT match_row.* INTO v_match FROM public.matches AS match_row
   JOIN public.partner_fox_chats AS chat_row ON chat_row.match_id = match_row.id
   WHERE chat_row.id = v_initial.chat_id FOR UPDATE OF match_row;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT chat_row.* INTO v_chat FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = v_initial.chat_id AND chat_row.match_id = v_match.id FOR UPDATE;
  IF NOT FOUND OR v_chat.user_id IS DISTINCT FROM v_initial.owner_id
     OR NOT ((v_chat.user_id = v_match.user_a_id AND v_chat.partner_user_id = v_match.user_b_id)
          OR (v_chat.user_id = v_match.user_b_id AND v_chat.partner_user_id = v_match.user_a_id))
     OR v_match.status NOT IN ('fox_conversation_completed', 'partner_chat_started',
          'direct_chat_requested', 'direct_chat_active', 'meetup_intent', 'meetup_confirmed') THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  IF NOT wingward_private.lock_and_check_mutual_eligibility(v_match.user_a_id, v_match.user_b_id) THEN
    RETURN QUERY SELECT 'ineligible'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT send_row.* INTO v_send FROM public.partner_fox_message_sends AS send_row
   WHERE send_row.idempotency_key = p_idempotency_key FOR UPDATE;
  IF NOT FOUND OR v_send.status IS DISTINCT FROM 'processing'
     OR v_send.claim_token IS DISTINCT FROM p_claim_token
     OR v_send.lease_expires_at IS NULL OR v_send.lease_expires_at <= v_now THEN
    RETURN QUERY SELECT 'stale'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT message_row.* INTO v_user_message FROM public.partner_fox_messages AS message_row
   WHERE message_row.id = v_send.user_message_id AND message_row.chat_id = v_chat.id AND message_row.role = 'user';
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'missing'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  INSERT INTO public.partner_fox_messages (chat_id, role, content)
    VALUES (v_chat.id, 'fox', p_fox_content)
    RETURNING * INTO v_fox_message;
  UPDATE public.partner_fox_message_sends AS send_row
     SET status = 'completed', claim_token = NULL, lease_expires_at = NULL,
         fox_message_id = v_fox_message.id, updated_at = v_now
   WHERE send_row.idempotency_key = p_idempotency_key;
  RETURN QUERY SELECT 'completed'::text, v_user_message.id, v_user_message.content, v_user_message.created_at,
    v_fox_message.id, v_fox_message.content, v_fox_message.created_at, NULL::uuid;
END;
$$;

CREATE OR REPLACE FUNCTION public.finish_partner_fox_message_send(
  p_idempotency_key uuid,
  p_claim_token uuid,
  p_outcome text
)
RETURNS TABLE (
  outcome text,
  user_message_id uuid,
  user_content text,
  user_created_at timestamptz,
  fox_message_id uuid,
  fox_content text,
  fox_created_at timestamptz,
  claim_token uuid
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_initial public.partner_fox_message_sends%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_chat public.partner_fox_chats%ROWTYPE;
  v_send public.partner_fox_message_sends%ROWTYPE;
  v_user_message public.partner_fox_messages%ROWTYPE;
  v_now timestamptz := pg_catalog.now();
BEGIN
  IF p_idempotency_key IS NULL OR p_claim_token IS NULL OR p_outcome IS NULL
     OR p_outcome NOT IN ('failed', 'unknown') THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT send_row.* INTO v_initial FROM public.partner_fox_message_sends AS send_row
   WHERE send_row.idempotency_key = p_idempotency_key;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT match_row.* INTO v_match FROM public.matches AS match_row
   JOIN public.partner_fox_chats AS chat_row ON chat_row.match_id = match_row.id
   WHERE chat_row.id = v_initial.chat_id FOR UPDATE OF match_row;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT chat_row.* INTO v_chat FROM public.partner_fox_chats AS chat_row
   WHERE chat_row.id = v_initial.chat_id AND chat_row.match_id = v_match.id FOR UPDATE;
  IF NOT FOUND OR v_chat.user_id IS DISTINCT FROM v_initial.owner_id
     OR NOT ((v_chat.user_id = v_match.user_a_id AND v_chat.partner_user_id = v_match.user_b_id)
          OR (v_chat.user_id = v_match.user_b_id AND v_chat.partner_user_id = v_match.user_a_id))
     OR v_match.status NOT IN ('fox_conversation_completed', 'partner_chat_started',
          'direct_chat_requested', 'direct_chat_active', 'meetup_intent', 'meetup_confirmed') THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  IF NOT wingward_private.lock_and_check_mutual_eligibility(v_match.user_a_id, v_match.user_b_id) THEN
    RETURN QUERY SELECT 'ineligible'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT send_row.* INTO v_send FROM public.partner_fox_message_sends AS send_row
   WHERE send_row.idempotency_key = p_idempotency_key FOR UPDATE;
  IF NOT FOUND OR v_send.status IS DISTINCT FROM 'processing'
     OR v_send.claim_token IS DISTINCT FROM p_claim_token THEN
    RETURN QUERY SELECT 'stale'::text, NULL::uuid, NULL::text, NULL::timestamptz,
      NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
    RETURN;
  END IF;
  SELECT message_row.* INTO v_user_message FROM public.partner_fox_messages AS message_row
   WHERE message_row.id = v_send.user_message_id AND message_row.chat_id = v_chat.id AND message_row.role = 'user';
  IF p_outcome = 'failed' AND FOUND THEN
    DELETE FROM public.partner_fox_messages AS message_row WHERE message_row.id = v_user_message.id;
  END IF;
  UPDATE public.partner_fox_message_sends AS send_row
     SET status = p_outcome, claim_token = NULL, lease_expires_at = NULL,
         user_message_id = CASE WHEN p_outcome = 'failed' THEN NULL ELSE send_row.user_message_id END,
         updated_at = v_now
   WHERE send_row.idempotency_key = p_idempotency_key;
  RETURN QUERY SELECT p_outcome, CASE WHEN p_outcome = 'failed' THEN NULL::uuid ELSE v_send.user_message_id END,
    CASE WHEN p_outcome = 'failed' THEN NULL::text ELSE v_user_message.content END,
    CASE WHEN p_outcome = 'failed' THEN NULL::timestamptz ELSE v_user_message.created_at END,
    NULL::uuid, NULL::text, NULL::timestamptz, NULL::uuid;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_partner_fox_message_send(uuid, uuid, uuid, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_partner_fox_message_send(uuid, uuid, uuid, text, text)
  TO service_role;
REVOKE ALL ON FUNCTION public.complete_partner_fox_message_send(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_partner_fox_message_send(uuid, uuid, text)
  TO service_role;
REVOKE ALL ON FUNCTION public.finish_partner_fox_message_send(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finish_partner_fox_message_send(uuid, uuid, text)
  TO service_role;

COMMENT ON FUNCTION public.claim_partner_fox_message_send(uuid, uuid, uuid, text, text) IS
  'Service-role-only Partner Ward claim. Locks match -> chat -> sorted profiles; replays completed rows, retries only the newest definitely failed key, and turns expired provider leases into terminal unknown without regeneration.';
COMMENT ON FUNCTION public.complete_partner_fox_message_send(uuid, uuid, text) IS
  'Service-role-only Partner Ward completion. Atomically inserts the Fox row and marks one live claim completed; retries return the same user/Fox message pair.';
COMMENT ON FUNCTION public.finish_partner_fox_message_send(uuid, uuid, text) IS
  'Service-role-only Partner Ward failure boundary. Definite pre-provider rejection removes the provisional user row and permits a same-key retry; uncertain provider outcomes remain terminal unknown.';
