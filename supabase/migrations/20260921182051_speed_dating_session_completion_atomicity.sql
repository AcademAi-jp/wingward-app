-- Keep the speed-dating completion boundary in one transaction.
--
-- The API uses the service-role client, so this RPC is deliberately restricted
-- to service_role. It locks the owner-bound session, validates the existing
-- transcript or the submitted bounded transcript, and then commits the
-- message rows, count, completion status, and onboarding transition together.
-- A completed session is never rewritten: a replay must match its stored
-- transcript (or omit a transcript and accept the stored body), otherwise the
-- caller receives a conflict.

CREATE OR REPLACE FUNCTION public.complete_speed_dating_session(
  p_session_id uuid,
  p_user_id uuid,
  p_transcript jsonb DEFAULT NULL
)
RETURNS TABLE (
  session_id uuid,
  status text,
  message_count integer,
  all_sessions_completed boolean,
  outcome text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_session public.speed_dating_sessions%ROWTYPE;
  v_now timestamptz := pg_catalog.now();
  v_existing_count integer := 0;
  v_invalid_count integer := 0;
  v_expected_count integer := 0;
  v_completed_count integer := 0;
  v_final_count integer := 0;
  v_existing_transcript jsonb;
  v_transcript_is_present boolean := p_transcript IS NOT NULL;
  v_transcript_matches boolean := false;
  v_all_done boolean := false;
  v_owner_profile_id uuid;
  v_entry jsonb;
  v_ordinal integer := 0;
BEGIN
  IF p_session_id IS NULL OR p_user_id IS NULL THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_input'::text;
    RETURN;
  END IF;

  -- Validate the request again inside the privileged boundary. The route also
  -- validates this shape, but RPC callers and future server code must not be
  -- able to bypass the transcript limits.
  IF v_transcript_is_present THEN
    IF pg_catalog.jsonb_typeof(p_transcript) IS DISTINCT FROM 'array' THEN
      RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_input'::text;
      RETURN;
    END IF;

    IF pg_catalog.jsonb_array_length(p_transcript) < 1
       OR pg_catalog.jsonb_array_length(p_transcript) > 200 THEN
      RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_input'::text;
      RETURN;
    END IF;

    v_expected_count := pg_catalog.jsonb_array_length(p_transcript);
    FOR v_entry IN SELECT value FROM pg_catalog.jsonb_array_elements(p_transcript) AS item(value)
    LOOP
      IF pg_catalog.jsonb_typeof(v_entry) IS DISTINCT FROM 'object'
         OR pg_catalog.jsonb_typeof(v_entry -> 'source') IS DISTINCT FROM 'string'
         OR pg_catalog.jsonb_typeof(v_entry -> 'message') IS DISTINCT FROM 'string'
         OR COALESCE((v_entry ->> 'source') IN ('user', 'ai'), false) IS NOT TRUE
         OR COALESCE(pg_catalog.btrim(v_entry ->> 'message') = '', true) IS NOT FALSE
         OR pg_catalog.char_length(v_entry ->> 'message') > 2000 THEN
        RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_input'::text;
        RETURN;
      END IF;
    END LOOP;
  END IF;

  -- Lock before checking ownership. An unowned or missing session has the
  -- same safe outcome at the HTTP boundary. The owner row is locked first so
  -- concurrent completions for two sessions of the same owner acquire a
  -- stable common lock before taking session locks.
  SELECT profile_row.id
    INTO v_owner_profile_id
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = p_user_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'not_found'::text;
    RETURN;
  END IF;

  SELECT session_row.*
    INTO v_session
    FROM public.speed_dating_sessions AS session_row
   WHERE session_row.id = p_session_id
     AND session_row.user_id = p_user_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'not_found'::text;
    RETURN;
  END IF;

  -- Validate all stored rows in the same snapshot. This keeps the no-body web
  -- completion path compatible with incremental messages while preventing an
  -- invalid legacy row from being silently certified as a completed session.
  SELECT
    pg_catalog.count(*)::integer,
    pg_catalog.count(*) FILTER (
      WHERE message_row.role NOT IN ('user', 'persona')
         OR message_row.content IS NULL
         OR pg_catalog.btrim(message_row.content) = ''
         OR pg_catalog.char_length(message_row.content) > 2000
    )::integer,
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'source', CASE message_row.role WHEN 'user' THEN 'user' ELSE 'ai' END,
        'message', message_row.content
      )
      ORDER BY message_row.created_at, message_row.id
    )
    INTO v_existing_count, v_invalid_count, v_existing_transcript
    FROM public.speed_dating_messages AS message_row
   WHERE message_row.session_id = p_session_id;

  IF v_invalid_count > 0 OR v_session.message_count <> v_existing_count THEN
    RETURN QUERY SELECT v_session.id, v_session.status, v_existing_count, false, 'invalid_state'::text;
    RETURN;
  END IF;

  IF NOT v_transcript_is_present AND v_existing_count < 1 THEN
    -- An omitted body denotes the incremental web transcript. An empty stored
    -- body is not a transcript and must not be certified as complete.
    RETURN QUERY SELECT v_session.id, v_session.status, v_existing_count, false, 'invalid_state'::text;
    RETURN;
  END IF;

  IF v_transcript_is_present THEN
    v_transcript_matches := COALESCE(v_existing_transcript, '[]'::jsonb) = p_transcript;
    IF v_session.status = 'completed' THEN
      -- Completed rows are immutable. A replay is safe only when it describes
      -- exactly the already-persisted transcript.
      IF NOT v_transcript_matches THEN
        RETURN QUERY SELECT v_session.id, v_session.status, v_existing_count, false, 'conflict'::text;
        RETURN;
      END IF;
      v_final_count := v_existing_count;
    ELSIF v_existing_count > 0 AND NOT v_transcript_matches THEN
      -- Do not append a second transcript to an active session whose stored
      -- body differs from this retry.
      RETURN QUERY SELECT v_session.id, v_session.status, v_existing_count, false, 'conflict'::text;
      RETURN;
    ELSE
      v_final_count := v_expected_count;
      IF v_existing_count = 0 THEN
        -- A deterministic microsecond offset preserves the caller's order for
        -- the existing created_at,id transcript projection used by GET and by
        -- replay comparison. The whole insert is still one transaction.
        FOR v_entry IN
          SELECT value
            FROM pg_catalog.jsonb_array_elements(p_transcript) WITH ORDINALITY AS item(value, ordinal)
           ORDER BY item.ordinal
        LOOP
          v_ordinal := v_ordinal + 1;
          INSERT INTO public.speed_dating_messages (session_id, role, content, created_at)
          VALUES (
            v_session.id,
            CASE v_entry ->> 'source' WHEN 'user' THEN 'user' ELSE 'persona' END,
            v_entry ->> 'message',
            v_now + (v_ordinal * pg_catalog.interval '1 microsecond')
          );
        END LOOP;
      END IF;
    END IF;
  ELSE
    -- The incremental web client omits the body. Its already-saved rows are
    -- the transcript and are certified only after the same row/count checks.
    v_final_count := v_existing_count;
  END IF;

  IF v_session.status = 'completed' THEN
    -- No UPDATE/INSERT occurs on a completed row, including idempotent replay.
    NULL;
  ELSE
    UPDATE public.speed_dating_sessions AS session_row
       SET status = 'completed',
           completed_at = v_now,
           message_count = v_final_count
     WHERE session_row.id = v_session.id
       AND session_row.user_id = p_user_id
       AND session_row.status = 'active';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'speed dating completion transition failed'
        USING ERRCODE = 'serialization_failure';
    END IF;
  END IF;

  -- Lock all sessions for this owner in a stable order before counting so two
  -- concurrent completions cannot return contradictory all-done results.
  PERFORM 1
    FROM public.speed_dating_sessions AS owner_session
   WHERE owner_session.user_id = p_user_id
   ORDER BY owner_session.id
   FOR UPDATE;

  SELECT pg_catalog.count(*)::integer
    INTO v_completed_count
    FROM public.speed_dating_sessions AS owner_session
   WHERE owner_session.user_id = p_user_id
     AND owner_session.status = 'completed';
  v_all_done := v_completed_count >= 3;

  IF v_all_done THEN
    UPDATE public.user_profiles
       SET onboarding_status = 'speed_dating_completed',
           updated_at = v_now
     WHERE id = p_user_id
       AND onboarding_status IS DISTINCT FROM 'confirmed';
  END IF;

  RETURN QUERY SELECT
    v_session.id,
    'completed'::text,
    v_final_count,
    v_all_done,
    CASE WHEN v_session.status = 'completed' THEN 'already_completed' ELSE 'stored' END;
END;
$$;

COMMENT ON FUNCTION public.complete_speed_dating_session(uuid, uuid, jsonb) IS
  'Service-role-only atomic and idempotent speed-dating session completion. Validates owner and transcript, preserves completed rows, and commits messages/count/status together.';

REVOKE ALL ON FUNCTION public.complete_speed_dating_session(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_speed_dating_session(uuid, uuid, jsonb)
  TO service_role;
