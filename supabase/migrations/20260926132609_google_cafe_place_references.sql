-- Google Places persistence is limited to exempt place IDs plus database-authored
-- operation times. Place names, addresses, hours, attribution, route estimates,
-- Maps URIs, and provider response bodies remain request-scoped only.

CREATE OR REPLACE FUNCTION public.chat_meetup_google_references_valid(p_value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_item jsonb;
  v_count integer;
  v_distinct_count integer;
BEGIN
  IF pg_catalog.jsonb_typeof(p_value) IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_value) > 3 THEN
    RETURN false;
  END IF;
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_value) AS item(value) LOOP
    IF pg_catalog.jsonb_typeof(v_item) IS DISTINCT FROM 'object'
       OR NOT (v_item ?& ARRAY['place_id', 'proposed_at'])
       OR v_item - ARRAY['place_id', 'proposed_at'] <> '{}'::jsonb
       OR pg_catalog.jsonb_typeof(v_item -> 'place_id') IS DISTINCT FROM 'string'
       OR (v_item ->> 'place_id') !~ '^[A-Za-z0-9_-]{1,220}$'
       OR pg_catalog.jsonb_typeof(v_item -> 'proposed_at') IS DISTINCT FROM 'string'
       OR (v_item ->> 'proposed_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$' THEN
      RETURN false;
    END IF;
  END LOOP;
  SELECT pg_catalog.count(*), pg_catalog.count(DISTINCT item.value ->> 'place_id')
    INTO v_count, v_distinct_count
    FROM pg_catalog.jsonb_array_elements(p_value) AS item(value);
  RETURN v_count = v_distinct_count;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_meetup_google_references_valid(jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chat_meetup_google_references_valid(jsonb)
  TO service_role;

ALTER TABLE public.chat_meetup_sessions
  ADD COLUMN google_cafe_references jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD CONSTRAINT chat_meetup_sessions_google_cafe_references_check
    CHECK (public.chat_meetup_google_references_valid(google_cafe_references));

CREATE OR REPLACE FUNCTION public.clear_stale_google_cafe_references()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'cafe_proposed' AND OLD.status = 'awaiting_location' THEN
    -- The dedicated Google publication RPC is the only writer that may set
    -- references at this transition; legacy publication supplies an empty list.
    RETURN NEW;
  END IF;

  IF NEW.status = 'confirmed' AND OLD.status = 'cafe_proposed' THEN
    IF pg_catalog.jsonb_typeof(NEW.google_cafe_references) IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_array_length(NEW.google_cafe_references) <> 1
       OR NOT (OLD.google_cafe_references @> NEW.google_cafe_references) THEN
      NEW.google_cafe_references := '[]'::jsonb;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status NOT IN ('cafe_proposed', 'confirmed')
     OR NEW.selected_time_candidate_id IS DISTINCT FROM OLD.selected_time_candidate_id
     OR NEW.time_candidates IS DISTINCT FROM OLD.time_candidates THEN
    NEW.google_cafe_references := '[]'::jsonb;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_stale_google_cafe_references()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER chat_meetup_sessions_clear_stale_google_cafe_references
  BEFORE UPDATE ON public.chat_meetup_sessions
  FOR EACH ROW EXECUTE FUNCTION public.clear_stale_google_cafe_references();

CREATE OR REPLACE FUNCTION public.publish_chat_meetup_google_cafes(
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_first_private_revision integer,
  p_second_private_revision integer,
  p_place_ids text[],
  p_unavailable_reason text DEFAULT NULL
)
RETURNS TABLE (outcome text, meetup_id uuid, status text, revision integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_first_private_revision integer;
  v_second_private_revision integer;
  v_match_id uuid;
  v_a_id uuid;
  v_b_id uuid;
  v_match_status text;
  v_room_status text;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_time_candidate jsonb;
  v_references jsonb := '[]'::jsonb;
  v_reason text := p_unavailable_reason;
  v_now timestamptz := pg_catalog.now();
  v_place_id text;
BEGIN
  IF p_room_id IS NULL OR p_user_id IS NULL OR p_expected_revision IS NULL
     OR p_expected_revision < 0 OR p_first_private_revision IS NULL
     OR p_second_private_revision IS NULL OR p_place_ids IS NULL
     OR pg_catalog.cardinality(p_place_ids) > 3
     OR (v_reason IS NOT NULL AND v_reason NOT IN ('cafe_unavailable', 'no_cafe'))
     OR (v_reason IS NULL AND pg_catalog.cardinality(p_place_ids) = 0)
     OR (v_reason IS NOT NULL AND pg_catalog.cardinality(p_place_ids) > 0)
     OR EXISTS (
       SELECT 1 FROM pg_catalog.unnest(p_place_ids) AS ids(place_id)
        WHERE place_id IS NULL OR place_id !~ '^[A-Za-z0-9_-]{1,220}$'
     )
     OR (SELECT pg_catalog.count(*) <> pg_catalog.count(DISTINCT place_id)
           FROM pg_catalog.unnest(p_place_ids) AS ids(place_id)) THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0;
    RETURN;
  END IF;

  SELECT room.match_id INTO v_match_id
    FROM public.direct_chat_rooms AS room WHERE room.id = p_room_id;
  IF NOT FOUND THEN RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN; END IF;
  SELECT match_row.user_a_id, match_row.user_b_id
    INTO v_a_id, v_b_id FROM public.matches AS match_row WHERE match_row.id = v_match_id;
  IF NOT FOUND OR (p_user_id <> v_a_id AND p_user_id <> v_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT match_row.user_a_id, match_row.user_b_id, match_row.status
    INTO v_a_id, v_b_id, v_match_status
    FROM public.matches AS match_row WHERE match_row.id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_match_status <> 'direct_chat_active'
     OR (p_user_id <> v_a_id AND p_user_id <> v_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT room.status INTO v_room_status
    FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_room_status <> 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT session_row.* INTO v_session
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.room_id = p_room_id
   ORDER BY session_row.created_at DESC, session_row.meetup_id DESC
   LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR v_session.match_id <> v_match_id
     OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF v_session.revision <> p_expected_revision OR v_session.status <> 'awaiting_location' THEN
    RETURN QUERY SELECT 'stale_revision'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;

  SELECT decision.private_revision INTO v_first_private_revision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = v_a_id;
  SELECT decision.private_revision INTO v_second_private_revision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = v_b_id;
  IF v_first_private_revision IS DISTINCT FROM p_first_private_revision
     OR v_second_private_revision IS DISTINCT FROM p_second_private_revision
     OR NOT EXISTS (
       SELECT 1 FROM public.chat_meetup_locations AS location
        WHERE location.meetup_id = v_session.meetup_id
          AND location.user_id IN (v_a_id, v_b_id)
          AND location.expires_at > v_now
       GROUP BY location.meetup_id HAVING pg_catalog.count(*) = 2
     ) THEN
    RETURN QUERY SELECT 'stale_private_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF (
    SELECT pg_catalog.count(*) FROM public.user_profiles AS profile
     WHERE profile.id IN (v_a_id, v_b_id)
       AND profile.identity_verification_status = 'verified'
       AND profile.identity_verified_at IS NOT NULL
       AND profile.identity_verified_at <= v_now
  ) <> 2 THEN
    RETURN QUERY SELECT 'identity_verification_required'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  SELECT candidate INTO v_time_candidate
    FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
   WHERE candidate ->> 'id' = v_session.selected_time_candidate_id;
  IF v_time_candidate IS NULL
     OR (v_time_candidate ->> 'starts_at')::timestamptz <= v_now
     OR (v_time_candidate ->> 'ends_at')::timestamptz <= (v_time_candidate ->> 'starts_at')::timestamptz THEN
    RETURN QUERY SELECT 'expired_candidate'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;

  IF v_reason IS NULL THEN
    SELECT COALESCE(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'place_id', item.place_id,
          'proposed_at', pg_catalog.to_char(v_now AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
        ) ORDER BY item.ordinality
      ),
      '[]'::jsonb
    ) INTO v_references
      FROM pg_catalog.unnest(p_place_ids) WITH ORDINALITY AS item(place_id, ordinality);
  END IF;

  UPDATE public.chat_meetup_sessions
     SET status = CASE WHEN v_reason IS NULL THEN 'cafe_proposed' ELSE 'unavailable' END,
         cafe_candidates = '[]'::jsonb,
         google_cafe_references = v_references,
         unavailable_reason = v_reason,
         revision = chat_meetup_sessions.revision + 1,
         updated_at = v_now,
         expires_at = v_now + pg_catalog.interval '7 days'
   WHERE chat_meetup_sessions.meetup_id = v_session.meetup_id
   RETURNING * INTO v_session;
  DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_session.meetup_id;
  INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
  VALUES (v_session.meetup_id, v_session.revision, 'state:cafes:' || v_session.revision::text, 'system',
    CASE WHEN v_reason IS NULL
      THEN 'Cafe options are ready. Choose the same cafe to confirm.'
      ELSE 'We could not verify cafe options. You can try again later.'
    END)
  ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
  RETURN QUERY SELECT 'ok'::text, v_session.meetup_id, v_session.status, v_session.revision;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_chat_meetup_google_cafes(uuid, uuid, integer, integer, integer, text[], text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_chat_meetup_google_cafes(uuid, uuid, integer, integer, integer, text[], text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.apply_chat_meetup_google_cafe_action(
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_expected_own_revision integer,
  p_idempotency_key uuid,
  p_request_digest text,
  p_action_type text,
  p_candidate_id text
)
RETURNS TABLE (
  outcome text,
  meetup_id uuid,
  status text,
  revision integer,
  own_revision integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_match_id uuid;
  v_a_id uuid;
  v_b_id uuid;
  v_match_status text;
  v_room_status text;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_decision public.chat_meetup_private_decisions%ROWTYPE;
  v_other_decision public.chat_meetup_private_decisions%ROWTYPE;
  v_operation public.chat_meetup_operations%ROWTYPE;
  v_time_candidate jsonb;
  v_reference jsonb;
  v_place_id text;
  v_own_revision integer := 0;
  v_revision integer := 0;
  v_actor_choice text;
  v_now timestamptz := pg_catalog.now();
BEGIN
  IF p_room_id IS NULL OR p_user_id IS NULL OR p_expected_revision IS NULL
     OR p_expected_revision < 0 OR p_expected_own_revision IS NULL OR p_expected_own_revision < 0
     OR p_idempotency_key IS NULL OR p_request_digest IS NULL
     OR p_request_digest !~ '^[0-9a-f]{64}$'
     OR p_action_type NOT IN ('cafe.approve', 'cafe.decline')
     OR p_candidate_id IS NULL OR p_candidate_id !~ '^google:[A-Za-z0-9_-]{1,220}$' THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;
  v_place_id := pg_catalog.substring(p_candidate_id, 8);

  SELECT room.match_id INTO v_match_id
    FROM public.direct_chat_rooms AS room WHERE room.id = p_room_id;
  IF NOT FOUND THEN RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0; RETURN; END IF;
  SELECT match_row.user_a_id, match_row.user_b_id
    INTO v_a_id, v_b_id FROM public.matches AS match_row WHERE match_row.id = v_match_id;
  IF NOT FOUND OR (p_user_id <> v_a_id AND p_user_id <> v_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0; RETURN;
  END IF;
  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0; RETURN;
  END IF;
  SELECT match_row.user_a_id, match_row.user_b_id, match_row.status
    INTO v_a_id, v_b_id, v_match_status
    FROM public.matches AS match_row WHERE match_row.id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_match_status <> 'direct_chat_active'
     OR (p_user_id <> v_a_id AND p_user_id <> v_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0; RETURN;
  END IF;
  SELECT room.status INTO v_room_status
    FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_room_status <> 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0; RETURN;
  END IF;
  SELECT session_row.* INTO v_session
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.room_id = p_room_id
   ORDER BY session_row.created_at DESC, session_row.meetup_id DESC
   LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR v_session.match_id <> v_match_id
     OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0; RETURN;
  END IF;
  v_revision := v_session.revision;

  SELECT operation_row.* INTO v_operation
    FROM public.chat_meetup_operations AS operation_row
   WHERE operation_row.room_id = p_room_id
     AND operation_row.user_id = p_user_id
     AND operation_row.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_operation.request_digest IS DISTINCT FROM p_request_digest THEN
      RETURN QUERY SELECT 'idempotency_conflict'::text, NULL::uuid, NULL::text, 0, 0; RETURN;
    END IF;
    SELECT COALESCE(decision.private_revision, 0) INTO v_own_revision
      FROM public.chat_meetup_private_decisions AS decision
     WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
    RETURN QUERY SELECT 'replayed'::text, v_session.meetup_id, v_session.status, v_revision, COALESCE(v_own_revision, 0);
    RETURN;
  END IF;

  INSERT INTO public.chat_meetup_private_decisions
    (match_id, room_id, meetup_id, user_id)
  VALUES (v_match_id, p_room_id, v_session.meetup_id, p_user_id)
  ON CONFLICT (match_id, user_id) DO NOTHING;
  SELECT decision.* INTO v_decision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id FOR UPDATE;
  v_own_revision := v_decision.private_revision;
  IF v_session.revision <> p_expected_revision OR v_own_revision <> p_expected_own_revision THEN
    RETURN QUERY SELECT 'stale_revision'::text, v_session.meetup_id, v_session.status, v_session.revision, v_own_revision; RETURN;
  END IF;
  IF v_session.status <> 'cafe_proposed'
     OR (v_session.expires_at IS NOT NULL AND v_session.expires_at <= v_now)
     OR NOT (SELECT pg_catalog.count(*) FROM public.user_profiles AS profile
              WHERE profile.id IN (v_a_id, v_b_id)
                AND profile.identity_verification_status = 'verified'
                AND profile.identity_verified_at IS NOT NULL
                AND profile.identity_verified_at <= v_now) = 2 THEN
    RETURN QUERY SELECT 'invalid_state'::text, v_session.meetup_id, v_session.status, v_session.revision, v_own_revision; RETURN;
  END IF;

  SELECT reference.value INTO v_reference
    FROM pg_catalog.jsonb_array_elements(v_session.google_cafe_references) AS reference(value)
   WHERE reference.value ->> 'place_id' = v_place_id;
  IF v_reference IS NULL THEN
    RETURN QUERY SELECT 'invalid_state'::text, v_session.meetup_id, v_session.status, v_session.revision, v_own_revision; RETURN;
  END IF;
  SELECT candidate INTO v_time_candidate
    FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
   WHERE candidate ->> 'id' = v_session.selected_time_candidate_id;
  IF v_time_candidate IS NULL
     OR (v_time_candidate ->> 'starts_at')::timestamptz <= v_now
     OR (v_time_candidate ->> 'ends_at')::timestamptz <= (v_time_candidate ->> 'starts_at')::timestamptz THEN
    RETURN QUERY SELECT 'expired_candidate'::text, v_session.meetup_id, v_session.status, v_session.revision, v_own_revision; RETURN;
  END IF;

  IF p_action_type = 'cafe.approve' THEN
    v_actor_choice := p_candidate_id;
    UPDATE public.chat_meetup_private_decisions
       SET cafe_choice_id = v_actor_choice,
           private_revision = private_revision + 1,
           updated_at = v_now
     WHERE match_id = v_match_id AND user_id = p_user_id
     RETURNING private_revision INTO v_own_revision;
    SELECT decision.* INTO v_other_decision
      FROM public.chat_meetup_private_decisions AS decision
     WHERE decision.match_id = v_match_id
       AND decision.user_id = CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END;
    IF FOUND AND v_other_decision.cafe_choice_id = v_actor_choice THEN
      UPDATE public.chat_meetup_sessions
         SET status = 'confirmed',
             confirmed_starts_at = (v_time_candidate ->> 'starts_at')::timestamptz,
             confirmed_ends_at = (v_time_candidate ->> 'ends_at')::timestamptz,
             confirmed_timezone = 'UTC',
             cafe_candidates = '[]'::jsonb,
             google_cafe_references = pg_catalog.jsonb_build_array(v_reference),
             unavailable_reason = NULL,
             revision = chat_meetup_sessions.revision + 1,
             updated_at = v_now,
             expires_at = NULL
       WHERE chat_meetup_sessions.meetup_id = v_session.meetup_id
       RETURNING * INTO v_session;
      v_revision := v_session.revision;
      DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_session.meetup_id;
      DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_session.meetup_id;
      UPDATE public.meetups AS meetup_row
         SET status = 'confirmed',
             confirmed_start_at = v_session.confirmed_starts_at,
             confirmed_timezone = 'UTC',
             format = 'cafe',
             proposal_expires_at = NULL,
             updated_at = v_now
       WHERE meetup_row.id = v_session.meetup_id
         AND meetup_row.status IN ('verifying', 'arranging', 'proposed');
      INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
      VALUES (v_session.meetup_id, v_revision, 'state:confirmed:' || v_revision::text, 'system',
        'You both chose this cafe. Your meetup is confirmed.')
      ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
    END IF;
  ELSE
    UPDATE public.chat_meetup_private_decisions
       SET cafe_choice_id = NULL,
           private_revision = private_revision + 1,
           updated_at = v_now
     WHERE match_id = v_match_id AND user_id = p_user_id
     RETURNING private_revision INTO v_own_revision;
  END IF;

  INSERT INTO public.chat_meetup_operations
    (room_id, user_id, idempotency_key, meetup_id, request_digest, outcome, result_status, result_revision)
  VALUES (p_room_id, p_user_id, p_idempotency_key, v_session.meetup_id,
    p_request_digest, 'ok', v_session.status, v_revision);
  RETURN QUERY SELECT 'ok'::text, v_session.meetup_id, v_session.status, v_revision, v_own_revision;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_chat_meetup_google_cafe_action(uuid, uuid, integer, integer, uuid, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_chat_meetup_google_cafe_action(uuid, uuid, integer, integer, uuid, text, text, text)
  TO service_role;
