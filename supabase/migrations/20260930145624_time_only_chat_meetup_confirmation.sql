-- Time-only meetup: matching future approvals confirm the true UTC interval.
-- CREATE OR REPLACE preserves existing owners, ACLs, wrappers and admission gates.
-- No profile, admission, quota, room or historical meetup data is rewritten.

DO $guard$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid='public.apply_chat_meetup_action(uuid,uuid,integer,integer,uuid,text,jsonb)'::regprocedure AND md5(prosrc) IN ('c4dbd5ecb3e9ed5371cc88a73dc10860','45dd93c8a7d9dfae55652c62a90a738b')) THEN RAISE EXCEPTION 'Time-only RPC source drift: public.apply_chat_meetup_action'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid='wingward_private.demo_recording_core_apply_chat_meetup_action(boolean,uuid,uuid,integer,integer,uuid,text,jsonb)'::regprocedure AND md5(prosrc) IN ('e451ade264be280f787213186a925e87','13acd9d2e48479b9399685c16816e9b8')) THEN RAISE EXCEPTION 'Time-only RPC source drift: wingward_private.demo_recording_core_apply_chat_meetup_action'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid='public.apply_chat_meetup_google_cafe_action(uuid,uuid,integer,integer,uuid,text,text,text)'::regprocedure AND md5(prosrc) IN ('d30a39350a7f47fc6b5b80a1a74ee87d','7df3517350be1fdc1df94a4ef4c3cc58')) THEN RAISE EXCEPTION 'Time-only RPC source drift: public.apply_chat_meetup_google_cafe_action'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid='wingward_private.demo_recording_core_apply_chat_meetup_google_cafe_action(boolean,uuid,uuid,integer,integer,uuid,text,text,text)'::regprocedure AND md5(prosrc) IN ('70e5fa20e0ceb271cc97cb60b5fc8097','37dff7c0b05c56df998155976aac970f')) THEN RAISE EXCEPTION 'Time-only RPC source drift: wingward_private.demo_recording_core_apply_chat_meetup_google_cafe_action'; END IF;
END;
$guard$;
CREATE OR REPLACE FUNCTION public.apply_chat_meetup_action(
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_expected_own_revision integer,
  p_idempotency_key uuid,
  p_request_digest text,
  p_action jsonb
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
  v_room_status text;
  v_meetup public.meetups%ROWTYPE;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_decision public.chat_meetup_private_decisions%ROWTYPE;
  v_other_decision public.chat_meetup_private_decisions%ROWTYPE;
  v_operation public.chat_meetup_operations%ROWTYPE;
  v_actor_choice text;
  v_other_choice text;
  v_action_type text;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_revision integer := 0;
  v_own_revision integer := 0;
  v_session_exists boolean := false;
  v_session_created boolean := false;
  v_completed_count integer := 0;
  v_operation_key text;
  v_time_candidate jsonb;
  v_meetup_id uuid;
  v_previous_meetup_id uuid;
  v_previous_revision integer;
BEGIN
  IF p_room_id IS NULL OR p_user_id IS NULL
     OR p_expected_revision IS NULL OR p_expected_revision < 0
     OR p_expected_own_revision IS NULL OR p_expected_own_revision < 0
     OR p_idempotency_key IS NULL
     OR p_request_digest IS NULL OR p_request_digest !~ '^[0-9a-f]{64}$'
     OR pg_catalog.jsonb_typeof(p_action) IS DISTINCT FROM 'object' THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT room.match_id INTO v_match_id
    FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT match_row.user_a_id, match_row.user_b_id
    INTO v_a_id, v_b_id
    FROM public.matches AS match_row
   WHERE match_row.id = v_match_id;
  IF NOT FOUND OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT match_row.user_a_id, match_row.user_b_id, match_row.status
    INTO v_a_id, v_b_id, v_room_status
    FROM public.matches AS match_row
   WHERE match_row.id = v_match_id
   FOR UPDATE;
  IF NOT FOUND OR v_room_status IS DISTINCT FROM 'direct_chat_active'
     OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT room.status INTO v_room_status
    FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id
   FOR UPDATE;
  IF NOT FOUND OR v_room_status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT session_row.* INTO v_session
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.room_id = p_room_id
   ORDER BY session_row.created_at DESC, session_row.meetup_id DESC
   LIMIT 1
   FOR UPDATE;
  v_session_exists := FOUND;
  IF v_session_exists THEN
    IF v_session.match_id <> v_match_id
       OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
      RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
      RETURN;
    END IF;
    v_meetup_id := v_session.meetup_id;
    v_previous_meetup_id := v_session.meetup_id;
    v_revision := v_session.revision;
    v_previous_revision := v_session.revision;
    IF v_session.status IN ('completed', 'cancelled')
       OR (v_session.status = 'expired' AND p_action ->> 'type' <> 'replan') THEN
      v_session_exists := false;
      v_meetup_id := NULL;
    END IF;
  END IF;

  IF p_action ->> 'type' IN ('location.submit', 'location.clear', 'cafe.approve', 'cafe.decline') THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT operation_row.* INTO v_operation
    FROM public.chat_meetup_operations AS operation_row
   WHERE operation_row.room_id = p_room_id
     AND operation_row.user_id = p_user_id
     AND operation_row.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_operation.request_digest IS DISTINCT FROM p_request_digest THEN
      RETURN QUERY SELECT 'idempotency_conflict'::text, NULL::uuid, NULL::text, 0, 0;
      RETURN;
    END IF;
    SELECT COALESCE(decision.private_revision, 0) INTO v_own_revision
      FROM public.chat_meetup_private_decisions AS decision
     WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
    RETURN QUERY SELECT 'replayed'::text,
      CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
      CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
      v_revision, COALESCE(v_own_revision, 0);
    RETURN;
  END IF;

  INSERT INTO public.chat_meetup_private_decisions
    (match_id, room_id, meetup_id, user_id)
  VALUES (v_match_id, p_room_id, CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END, p_user_id)
  ON CONFLICT (match_id, user_id) DO NOTHING;

  SELECT decision.* INTO v_decision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id
   FOR UPDATE;
  v_own_revision := v_decision.private_revision;
  IF v_revision <> p_expected_revision OR v_own_revision <> p_expected_own_revision THEN
    RETURN QUERY SELECT 'stale_revision'::text,
      CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
      CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
      v_revision, v_own_revision;
    RETURN;
  END IF;

  v_action_type := p_action ->> 'type';

  IF v_action_type = 'intent' THEN
    IF v_session_exists OR p_action ->> 'value' IS NULL OR p_action ->> 'value' NOT IN ('yes', 'withdraw') THEN
      RETURN QUERY SELECT 'invalid_state'::text, NULL::uuid, NULL::text, v_revision, v_own_revision;
      RETURN;
    END IF;

    IF p_action ->> 'value' = 'withdraw' THEN
      UPDATE public.chat_meetup_private_decisions
         SET intent_value = NULL,
             private_revision = private_revision + 1,
             updated_at = v_now
       WHERE match_id = v_match_id AND user_id = p_user_id
       RETURNING private_revision INTO v_own_revision;

      UPDATE public.meetups AS meetup_row
         SET status = 'declined',
             intent_expires_at = NULL,
             updated_at = v_now
       WHERE meetup_row.match_id = v_match_id
         AND meetup_row.status = 'intent_pending'
         AND meetup_row.initiator_id = p_user_id;
    ELSE
      IF v_previous_meetup_id IS NOT NULL AND v_session.status IN ('expired', 'cancelled') THEN
        UPDATE public.meetups AS old_meetup
           SET status = CASE WHEN v_session.status = 'expired' THEN 'expired' ELSE 'cancelled' END,
               intent_expires_at = NULL, proposal_expires_at = NULL, updated_at = v_now
         WHERE old_meetup.id = v_previous_meetup_id
           AND old_meetup.status IN ('intent_pending', 'intent_matched', 'verifying', 'arranging', 'proposed');
      END IF;
      SELECT meetup_row.* INTO v_meetup
        FROM public.meetups AS meetup_row
       WHERE meetup_row.match_id = v_match_id
         AND meetup_row.status IN ('intent_pending', 'intent_matched', 'verifying')
       ORDER BY meetup_row.created_at DESC
       LIMIT 1
       FOR UPDATE;

      IF FOUND AND v_meetup.status = 'intent_pending'
         AND v_meetup.intent_expires_at IS NOT NULL
         AND v_meetup.intent_expires_at <= v_now THEN
        UPDATE public.meetups AS meetup_row
           SET status = 'expired', intent_expires_at = NULL, updated_at = v_now
         WHERE meetup_row.id = v_meetup.id;
        v_meetup := NULL;
      END IF;

      IF v_meetup.id IS NULL THEN
        INSERT INTO public.meetups
          (match_id, initiator_id, status, intent_a_at, intent_b_at, intent_expires_at, created_at, updated_at)
        VALUES
          (v_match_id, p_user_id, 'intent_pending',
           CASE WHEN p_user_id = v_a_id THEN v_now ELSE NULL END,
           CASE WHEN p_user_id = v_b_id THEN v_now ELSE NULL END,
           v_now + pg_catalog.interval '7 days', v_now, v_now)
        RETURNING * INTO v_meetup;
      ELSIF v_meetup.status = 'intent_pending'
            AND v_meetup.initiator_id <> p_user_id THEN
        UPDATE public.meetups AS meetup_row
           SET intent_a_at = CASE WHEN p_user_id = v_a_id THEN v_now ELSE meetup_row.intent_a_at END,
               intent_b_at = CASE WHEN p_user_id = v_b_id THEN v_now ELSE meetup_row.intent_b_at END,
               intent_expires_at = NULL,
               status = 'intent_matched',
               updated_at = v_now
         WHERE meetup_row.id = v_meetup.id
         RETURNING * INTO v_meetup;
      END IF;

      v_meetup_id := v_meetup.id;
      UPDATE public.chat_meetup_private_decisions
         SET meetup_id = NULL,
             intent_value = true,
             private_revision = private_revision + 1,
             updated_at = v_now
       WHERE match_id = v_match_id AND user_id = p_user_id
       RETURNING private_revision INTO v_own_revision;

      IF v_meetup.status IN ('intent_matched', 'verifying')
         AND v_meetup.intent_a_at IS NOT NULL AND v_meetup.intent_b_at IS NOT NULL THEN
        UPDATE public.meetups AS meetup_row
           SET status = 'verifying', updated_at = v_now
         WHERE meetup_row.id = v_meetup.id
           AND meetup_row.status = 'intent_matched';

        -- The caller-private rows below reference the session. Create that
        -- durable FK target first, within this same transaction.
        INSERT INTO public.chat_meetup_sessions
          (meetup_id, match_id, room_id, user_a_id, user_b_id, status, revision, expires_at)
        VALUES (v_meetup.id, v_match_id, p_room_id, v_a_id, v_b_id,
          'awaiting_availability', v_revision + 1, v_now + pg_catalog.interval '7 days')
        ON CONFLICT ON CONSTRAINT chat_meetup_sessions_pkey DO NOTHING;

        SELECT session_row.* INTO v_session
          FROM public.chat_meetup_sessions AS session_row
         WHERE session_row.meetup_id = v_meetup.id
         FOR UPDATE;
        v_session_exists := FOUND;
        v_meetup_id := v_meetup.id;
        v_revision := v_session.revision;
        v_session_created := true;

        INSERT INTO public.chat_meetup_private_decisions
          (match_id, room_id, meetup_id, user_id, intent_value)
        VALUES (v_match_id, p_room_id, v_meetup.id,
          CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END, true)
        ON CONFLICT (match_id, user_id) DO UPDATE
          SET meetup_id = EXCLUDED.meetup_id,
              intent_value = true,
              time_choice_id = NULL,
              cafe_choice_id = NULL,
              completed_at = NULL;

        INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
        VALUES (v_meetup.id, v_revision, 'state:mutual-intent', 'system',
          'You both want to meet. Choose a time together.')
        ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;

        UPDATE public.chat_meetup_private_decisions
           SET meetup_id = v_meetup.id
         WHERE match_id = v_match_id AND user_id = p_user_id;
        UPDATE public.chat_meetup_private_decisions
           SET time_choice_id = NULL, cafe_choice_id = NULL, completed_at = NULL
         WHERE match_id = v_match_id
           AND user_id = CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END;
      END IF;
    END IF;
  ELSE
    IF NOT v_session_exists OR (v_session.expires_at IS NOT NULL AND v_session.expires_at <= v_now AND v_session.status <> 'expired') THEN
      RETURN QUERY SELECT 'invalid_state'::text,
        CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
        CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
        v_revision, v_own_revision;
      RETURN;
    END IF;

    IF v_session.status NOT IN ('cancelled', 'expired', 'completed') OR (v_action_type = 'replan' AND v_session.status = 'expired') THEN
      IF (
        SELECT count(*) FROM public.user_profiles AS profile
         WHERE profile.id IN (v_a_id, v_b_id)
           AND profile.identity_verification_status = 'verified'
           AND profile.identity_verified_at IS NOT NULL
      ) <> 2
      AND v_action_type IN (
        'availability.submit', 'time.approve', 'location.submit',
        'cafe.approve', 'cafe.decline', 'replan'
      ) THEN
        RETURN QUERY SELECT 'identity_verification_required'::text, v_meetup_id,
          v_session.status, v_revision, v_own_revision;
        RETURN;
      END IF;

      IF v_action_type = 'availability.submit' THEN
        IF v_session.status <> 'awaiting_availability' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        IF p_action ->> 'source' IS NULL OR p_action ->> 'source' NOT IN ('calendar', 'manual')
           OR pg_catalog.jsonb_typeof(p_action -> 'window') IS DISTINCT FROM 'object'
           OR pg_catalog.jsonb_typeof(COALESCE(p_action -> 'busy', p_action -> 'available')) IS DISTINCT FROM 'array'
           OR pg_catalog.jsonb_array_length(COALESCE(p_action -> 'busy', p_action -> 'available')) > 128 THEN
          RETURN QUERY SELECT 'invalid_input'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        INSERT INTO public.chat_meetup_availability
          (meetup_id, user_id, source, window_starts_at, window_ends_at, intervals, expires_at, created_at)
        VALUES (
          v_meetup_id, p_user_id, p_action ->> 'source',
          (p_action -> 'window' ->> 'starts_at')::timestamptz,
          (p_action -> 'window' ->> 'ends_at')::timestamptz,
          COALESCE(p_action -> 'busy', p_action -> 'available'),
          v_now + pg_catalog.interval '30 minutes', v_now
        )
        ON CONFLICT ON CONSTRAINT chat_meetup_availability_pkey DO UPDATE
          SET source = EXCLUDED.source,
              window_starts_at = EXCLUDED.window_starts_at,
              window_ends_at = EXCLUDED.window_ends_at,
              intervals = EXCLUDED.intervals,
              expires_at = EXCLUDED.expires_at,
              created_at = EXCLUDED.created_at;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;

        IF v_session.quota_claim_owner_id IS NULL
           AND 2 = (
             SELECT count(*) FROM public.chat_meetup_availability AS availability
              WHERE availability.meetup_id = v_meetup_id
                AND availability.expires_at > v_now
           ) THEN
          UPDATE public.chat_meetup_sessions
             SET quota_claim_owner_id = p_user_id,
                 quota_operation_key = 'chat-meetup:' || v_meetup_id::text
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id;
        END IF;
      ELSIF v_action_type = 'availability.clear' THEN
        IF v_session.status <> 'awaiting_availability' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        DELETE FROM public.chat_meetup_availability AS availability
         WHERE availability.meetup_id = v_meetup_id AND user_id = p_user_id;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
      ELSIF v_action_type = 'time.approve' THEN
        IF v_session.status <> 'time_proposed'
           OR NOT EXISTS (
             SELECT 1 FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
              WHERE candidate ->> 'id' = p_action ->> 'candidate_id'
           ) THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        SELECT candidate INTO v_time_candidate
          FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
         WHERE candidate ->> 'id' = p_action ->> 'candidate_id';
        IF v_time_candidate IS NULL
           OR (v_time_candidate ->> 'starts_at')::timestamptz <= pg_catalog.clock_timestamp()
           OR (v_time_candidate ->> 'ends_at')::timestamptz <= (v_time_candidate ->> 'starts_at')::timestamptz THEN
          RETURN QUERY SELECT 'expired_candidate'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        v_actor_choice := p_action ->> 'candidate_id';
        UPDATE public.chat_meetup_private_decisions
           SET time_choice_id = v_actor_choice,
               private_revision = private_revision + 1,
               updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
        SELECT decision.* INTO v_other_decision
          FROM public.chat_meetup_private_decisions AS decision
         WHERE decision.match_id = v_match_id
           AND decision.user_id = CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END;
        IF FOUND AND v_other_decision.time_choice_id = v_actor_choice THEN
          UPDATE public.chat_meetup_sessions
             SET status = 'confirmed',
                 selected_time_candidate_id = v_actor_choice,
                 confirmed_starts_at = (v_time_candidate ->> 'starts_at')::timestamptz,
                 confirmed_ends_at = (v_time_candidate ->> 'ends_at')::timestamptz,
                 confirmed_timezone = 'UTC',
                 cafe_candidates = '[]'::jsonb,
                 cafe_choice_a = NULL,
                 cafe_choice_b = NULL,
                 unavailable_reason = NULL,
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now,
                 expires_at = NULL
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          UPDATE public.chat_meetup_private_decisions
             SET cafe_choice_id = NULL
           WHERE match_id = v_match_id;
          UPDATE public.meetups AS meetup_row
             SET status = 'confirmed',
                 confirmed_start_at = v_session.confirmed_starts_at,
                 confirmed_timezone = 'UTC',
                 area = NULL,
                 format = NULL,
                 proposal_expires_at = NULL,
                 updated_at = v_now
           WHERE meetup_row.id = v_meetup_id
             AND meetup_row.status IN ('verifying', 'arranging', 'proposed');
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:confirmed:' || v_revision::text, 'system',
            'You both chose the same time. Your meetup is confirmed. Use Chat to agree on a place.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        END IF;
      ELSIF v_action_type = 'replan' THEN
        IF v_session.status = 'confirmed' THEN
          IF v_session.confirmed_ends_at IS NULL OR v_session.confirmed_ends_at <= v_now THEN
            RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
            RETURN;
          END IF;
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          UPDATE public.chat_meetup_sessions
             SET status = 'cancelled', expires_at = NULL,
                 revision = chat_meetup_sessions.revision + 1, updated_at = v_now
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          UPDATE public.meetups AS old_meetup
             SET status = 'cancelled', updated_at = v_now
           WHERE old_meetup.id = v_meetup_id AND old_meetup.status = 'confirmed';
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replaced:' || v_revision::text, 'system',
            'The confirmed plan was replaced with a new planning round.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
          v_previous_meetup_id := v_meetup_id;
          v_previous_revision := v_revision;
          INSERT INTO public.meetups
            (match_id, initiator_id, status, intent_a_at, intent_b_at, created_at, updated_at)
          VALUES (v_match_id, p_user_id, 'verifying', v_now, v_now, v_now, v_now)
          RETURNING * INTO v_meetup;
          INSERT INTO public.chat_meetup_sessions
            (meetup_id, match_id, room_id, user_a_id, user_b_id, status, revision, expires_at)
          VALUES (v_meetup.id, v_match_id, p_room_id, v_a_id, v_b_id,
            'awaiting_availability', v_revision + 1, v_now + pg_catalog.interval '7 days')
          RETURNING * INTO v_session;
          v_meetup_id := v_meetup.id;
          v_revision := v_session.revision;
          UPDATE public.chat_meetup_private_decisions
             SET meetup_id = v_meetup_id, time_choice_id = NULL,
                 cafe_choice_id = NULL, completed_at = NULL,
                 private_revision = private_revision + 1, updated_at = v_now
           WHERE match_id = v_match_id;
          SELECT decision.private_revision INTO v_own_revision
            FROM public.chat_meetup_private_decisions AS decision
           WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replan:' || v_revision::text, 'system',
            'A new plan is ready. Suggest availability to choose another time.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        ELSIF v_session.status = 'expired' THEN
          UPDATE public.meetups AS old_meetup
             SET status = 'expired', intent_expires_at = NULL,
                 proposal_expires_at = NULL, updated_at = v_now
           WHERE old_meetup.id = v_meetup_id
             AND old_meetup.status IN ('verifying', 'arranging', 'proposed');
          INSERT INTO public.meetups
            (match_id, initiator_id, status, intent_a_at, intent_b_at, created_at, updated_at)
          VALUES (v_match_id, p_user_id, 'verifying', v_now, v_now, v_now, v_now)
          RETURNING * INTO v_meetup;
          INSERT INTO public.chat_meetup_sessions
            (meetup_id, match_id, room_id, user_a_id, user_b_id, status, revision, expires_at)
          VALUES (v_meetup.id, v_match_id, p_room_id, v_a_id, v_b_id,
            'awaiting_availability', v_revision + 1, v_now + pg_catalog.interval '7 days')
          RETURNING * INTO v_session;
          v_meetup_id := v_meetup.id;
          v_revision := v_session.revision;
          UPDATE public.chat_meetup_private_decisions
             SET meetup_id = v_meetup_id, time_choice_id = NULL,
                 cafe_choice_id = NULL, completed_at = NULL,
                 private_revision = private_revision + 1, updated_at = v_now
           WHERE match_id = v_match_id;
          SELECT decision.private_revision INTO v_own_revision
            FROM public.chat_meetup_private_decisions AS decision
           WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replan:' || v_revision::text, 'system',
            'A new plan is ready. Suggest availability to choose another time.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        ELSIF v_session.status IN ('time_proposed', 'awaiting_location', 'cafe_proposed', 'unavailable') THEN
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          UPDATE public.chat_meetup_private_decisions
             SET time_choice_id = NULL, cafe_choice_id = NULL,
                 private_revision = private_revision + 1, updated_at = v_now
           WHERE match_id = v_match_id;
          UPDATE public.chat_meetup_sessions
             SET status = 'awaiting_availability',
                 time_candidates = '[]'::jsonb,
                 cafe_candidates = '[]'::jsonb,
                 time_choice_a = NULL, time_choice_b = NULL,
                 selected_time_candidate_id = NULL,
                 cafe_choice_a = NULL, cafe_choice_b = NULL,
                 confirmed_starts_at = NULL, confirmed_ends_at = NULL,
                 confirmed_timezone = NULL,
                 unavailable_reason = NULL,
                 expires_at = v_now + pg_catalog.interval '7 days',
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          UPDATE public.meetups AS meetup_row
             SET status = 'verifying', updated_at = v_now
           WHERE meetup_row.id = v_meetup_id
             AND meetup_row.status = 'arranging';
          SELECT decision.private_revision INTO v_own_revision
            FROM public.chat_meetup_private_decisions AS decision
           WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replan:' || v_revision::text, 'system',
            'You can suggest new availability and try again.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        ELSE
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
      ELSIF v_action_type = 'cancel' THEN
        IF v_session.status IN ('cancelled', 'expired', 'completed') THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
        DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
        UPDATE public.chat_meetup_sessions
           SET status = 'cancelled', expires_at = NULL,
               time_candidates = '[]'::jsonb, cafe_candidates = '[]'::jsonb,
               revision = chat_meetup_sessions.revision + 1, updated_at = v_now
         WHERE chat_meetup_sessions.meetup_id = v_meetup_id
         RETURNING * INTO v_session;
        v_revision := v_session.revision;
        UPDATE public.chat_meetup_private_decisions
           SET time_choice_id = NULL, cafe_choice_id = NULL
         WHERE match_id = v_match_id;
        UPDATE public.meetups AS meetup_row
           SET status = 'cancelled', intent_expires_at = NULL,
               proposal_expires_at = NULL, updated_at = v_now
         WHERE meetup_row.id = v_meetup_id
           AND meetup_row.status NOT IN ('completed', 'no_show', 'declined', 'expired', 'cancelled');
        INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
        VALUES (v_meetup_id, v_revision, 'state:cancelled:' || v_revision::text, 'system',
          'This meetup plan was cancelled.')
        ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
      ELSIF v_action_type = 'meeting.complete' THEN
        IF v_session.status <> 'confirmed'
           OR v_session.confirmed_ends_at IS NULL
           OR v_session.confirmed_ends_at > pg_catalog.clock_timestamp() THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        UPDATE public.chat_meetup_private_decisions
           SET completed_at = COALESCE(completed_at, v_now),
               private_revision = private_revision + 1,
               updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
        IF p_user_id = v_a_id THEN
          UPDATE public.chat_meetup_sessions AS session_row
             SET completed_a_at = COALESCE(session_row.completed_a_at, v_now)
           WHERE session_row.meetup_id = v_meetup_id;
        ELSE
          UPDATE public.chat_meetup_sessions AS session_row
             SET completed_b_at = COALESCE(session_row.completed_b_at, v_now)
           WHERE session_row.meetup_id = v_meetup_id;
        END IF;
        SELECT session_row.* INTO v_session
          FROM public.chat_meetup_sessions AS session_row
         WHERE session_row.meetup_id = v_meetup_id;
        IF v_session.completed_a_at IS NOT NULL AND v_session.completed_b_at IS NOT NULL THEN
          UPDATE public.chat_meetup_sessions
             SET status = 'completed',
                 completed_a_at = (SELECT decision.completed_at FROM public.chat_meetup_private_decisions AS decision WHERE decision.match_id = v_match_id AND decision.user_id = v_a_id),
                 completed_b_at = (SELECT decision.completed_at FROM public.chat_meetup_private_decisions AS decision WHERE decision.match_id = v_match_id AND decision.user_id = v_b_id),
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          UPDATE public.meetups AS meetup_row
             SET status = 'completed', updated_at = v_now
           WHERE meetup_row.id = v_meetup_id AND meetup_row.status = 'confirmed';
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:completed:' || v_revision::text, 'system',
            'You both marked this meetup complete.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        END IF;
      ELSE
        RETURN QUERY SELECT 'invalid_input'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
        RETURN;
      END IF;
    ELSE
      RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
      RETURN;
    END IF;
  END IF;

  -- Record only a digest and safe outcome metadata. Replays are access-checked
  -- above and the HTTP service returns the fresh caller-scoped projection.
  INSERT INTO public.chat_meetup_operations
    (room_id, user_id, idempotency_key, meetup_id, request_digest, outcome, result_status, result_revision)
  VALUES (
    p_room_id, p_user_id, p_idempotency_key,
    CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
    p_request_digest, 'ok',
    CASE WHEN v_session_exists THEN v_session.status ELSE COALESCE(v_meetup.status, 'idle') END,
    v_revision
  );

  RETURN QUERY SELECT 'ok'::text,
    CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
    CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
    v_revision, v_own_revision;
END;
$$;

CREATE OR REPLACE FUNCTION wingward_private.demo_recording_core_apply_chat_meetup_action(p_synthetic_admitted boolean,
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_expected_own_revision integer,
  p_idempotency_key uuid,
  p_request_digest text,
  p_action jsonb
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
AS $core$
DECLARE
  v_match_id uuid;
  v_a_id uuid;
  v_b_id uuid;
  v_room_status text;
  v_meetup public.meetups%ROWTYPE;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_decision public.chat_meetup_private_decisions%ROWTYPE;
  v_other_decision public.chat_meetup_private_decisions%ROWTYPE;
  v_operation public.chat_meetup_operations%ROWTYPE;
  v_actor_choice text;
  v_other_choice text;
  v_action_type text;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_revision integer := 0;
  v_own_revision integer := 0;
  v_session_exists boolean := false;
  v_session_created boolean := false;
  v_completed_count integer := 0;
  v_operation_key text;
  v_time_candidate jsonb;
  v_meetup_id uuid;
  v_previous_meetup_id uuid;
  v_previous_revision integer;
BEGIN
  IF p_room_id IS NULL OR p_user_id IS NULL
     OR p_expected_revision IS NULL OR p_expected_revision < 0
     OR p_expected_own_revision IS NULL OR p_expected_own_revision < 0
     OR p_idempotency_key IS NULL
     OR p_request_digest IS NULL OR p_request_digest !~ '^[0-9a-f]{64}$'
     OR pg_catalog.jsonb_typeof(p_action) IS DISTINCT FROM 'object' THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT room.match_id INTO v_match_id
    FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT match_row.user_a_id, match_row.user_b_id
    INTO v_a_id, v_b_id
    FROM public.matches AS match_row
   WHERE match_row.id = v_match_id;
  IF NOT FOUND OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT match_row.user_a_id, match_row.user_b_id, match_row.status
    INTO v_a_id, v_b_id, v_room_status
    FROM public.matches AS match_row
   WHERE match_row.id = v_match_id
   FOR UPDATE;
  IF NOT FOUND OR v_room_status IS DISTINCT FROM 'direct_chat_active'
     OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT room.status INTO v_room_status
    FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id
   FOR UPDATE;
  IF NOT FOUND OR v_room_status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT session_row.* INTO v_session
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.room_id = p_room_id
   ORDER BY session_row.created_at DESC, session_row.meetup_id DESC
   LIMIT 1
   FOR UPDATE;
  v_session_exists := FOUND;
  IF v_session_exists THEN
    IF v_session.match_id <> v_match_id
       OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
      RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
      RETURN;
    END IF;
    v_meetup_id := v_session.meetup_id;
    v_previous_meetup_id := v_session.meetup_id;
    v_revision := v_session.revision;
    v_previous_revision := v_session.revision;
    IF v_session.status IN ('completed', 'cancelled')
       OR (v_session.status = 'expired' AND p_action ->> 'type' <> 'replan') THEN
      v_session_exists := false;
      v_meetup_id := NULL;
    END IF;
  END IF;

  IF p_action ->> 'type' IN ('location.submit', 'location.clear', 'cafe.approve', 'cafe.decline') THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT operation_row.* INTO v_operation
    FROM public.chat_meetup_operations AS operation_row
   WHERE operation_row.room_id = p_room_id
     AND operation_row.user_id = p_user_id
     AND operation_row.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_operation.request_digest IS DISTINCT FROM p_request_digest THEN
      RETURN QUERY SELECT 'idempotency_conflict'::text, NULL::uuid, NULL::text, 0, 0;
      RETURN;
    END IF;
    SELECT COALESCE(decision.private_revision, 0) INTO v_own_revision
      FROM public.chat_meetup_private_decisions AS decision
     WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
    RETURN QUERY SELECT 'replayed'::text,
      CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
      CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
      v_revision, COALESCE(v_own_revision, 0);
    RETURN;
  END IF;

  INSERT INTO public.chat_meetup_private_decisions
    (match_id, room_id, meetup_id, user_id)
  VALUES (v_match_id, p_room_id, CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END, p_user_id)
  ON CONFLICT (match_id, user_id) DO NOTHING;

  SELECT decision.* INTO v_decision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id
   FOR UPDATE;
  v_own_revision := v_decision.private_revision;
  IF v_revision <> p_expected_revision OR v_own_revision <> p_expected_own_revision THEN
    RETURN QUERY SELECT 'stale_revision'::text,
      CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
      CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
      v_revision, v_own_revision;
    RETURN;
  END IF;

  v_action_type := p_action ->> 'type';

  IF v_action_type = 'intent' THEN
    IF v_session_exists OR p_action ->> 'value' IS NULL OR p_action ->> 'value' NOT IN ('yes', 'withdraw') THEN
      RETURN QUERY SELECT 'invalid_state'::text, NULL::uuid, NULL::text, v_revision, v_own_revision;
      RETURN;
    END IF;

    IF p_action ->> 'value' = 'withdraw' THEN
      UPDATE public.chat_meetup_private_decisions
         SET intent_value = NULL,
             private_revision = private_revision + 1,
             updated_at = v_now
       WHERE match_id = v_match_id AND user_id = p_user_id
       RETURNING private_revision INTO v_own_revision;

      UPDATE public.meetups AS meetup_row
         SET status = 'declined',
             intent_expires_at = NULL,
             updated_at = v_now
       WHERE meetup_row.match_id = v_match_id
         AND meetup_row.status = 'intent_pending'
         AND meetup_row.initiator_id = p_user_id;
    ELSE
      IF v_previous_meetup_id IS NOT NULL AND v_session.status IN ('expired', 'cancelled') THEN
        UPDATE public.meetups AS old_meetup
           SET status = CASE WHEN v_session.status = 'expired' THEN 'expired' ELSE 'cancelled' END,
               intent_expires_at = NULL, proposal_expires_at = NULL, updated_at = v_now
         WHERE old_meetup.id = v_previous_meetup_id
           AND old_meetup.status IN ('intent_pending', 'intent_matched', 'verifying', 'arranging', 'proposed');
      END IF;
      SELECT meetup_row.* INTO v_meetup
        FROM public.meetups AS meetup_row
       WHERE meetup_row.match_id = v_match_id
         AND meetup_row.status IN ('intent_pending', 'intent_matched', 'verifying')
       ORDER BY meetup_row.created_at DESC
       LIMIT 1
       FOR UPDATE;

      IF FOUND AND v_meetup.status = 'intent_pending'
         AND v_meetup.intent_expires_at IS NOT NULL
         AND v_meetup.intent_expires_at <= v_now THEN
        UPDATE public.meetups AS meetup_row
           SET status = 'expired', intent_expires_at = NULL, updated_at = v_now
         WHERE meetup_row.id = v_meetup.id;
        v_meetup := NULL;
      END IF;

      IF v_meetup.id IS NULL THEN
        INSERT INTO public.meetups
          (match_id, initiator_id, status, intent_a_at, intent_b_at, intent_expires_at, created_at, updated_at)
        VALUES
          (v_match_id, p_user_id, 'intent_pending',
           CASE WHEN p_user_id = v_a_id THEN v_now ELSE NULL END,
           CASE WHEN p_user_id = v_b_id THEN v_now ELSE NULL END,
           v_now + pg_catalog.interval '7 days', v_now, v_now)
        RETURNING * INTO v_meetup;
      ELSIF v_meetup.status = 'intent_pending'
            AND v_meetup.initiator_id <> p_user_id THEN
        UPDATE public.meetups AS meetup_row
           SET intent_a_at = CASE WHEN p_user_id = v_a_id THEN v_now ELSE meetup_row.intent_a_at END,
               intent_b_at = CASE WHEN p_user_id = v_b_id THEN v_now ELSE meetup_row.intent_b_at END,
               intent_expires_at = NULL,
               status = 'intent_matched',
               updated_at = v_now
         WHERE meetup_row.id = v_meetup.id
         RETURNING * INTO v_meetup;
      END IF;

      v_meetup_id := v_meetup.id;
      UPDATE public.chat_meetup_private_decisions
         SET meetup_id = NULL,
             intent_value = true,
             private_revision = private_revision + 1,
             updated_at = v_now
       WHERE match_id = v_match_id AND user_id = p_user_id
       RETURNING private_revision INTO v_own_revision;

      IF v_meetup.status IN ('intent_matched', 'verifying')
         AND v_meetup.intent_a_at IS NOT NULL AND v_meetup.intent_b_at IS NOT NULL THEN
        UPDATE public.meetups AS meetup_row
           SET status = 'verifying', updated_at = v_now
         WHERE meetup_row.id = v_meetup.id
           AND meetup_row.status = 'intent_matched';

        -- The caller-private rows below reference the session. Create that
        -- durable FK target first, within this same transaction.
        INSERT INTO public.chat_meetup_sessions
          (meetup_id, match_id, room_id, user_a_id, user_b_id, status, revision, expires_at)
        VALUES (v_meetup.id, v_match_id, p_room_id, v_a_id, v_b_id,
          'awaiting_availability', v_revision + 1, v_now + pg_catalog.interval '7 days')
        ON CONFLICT ON CONSTRAINT chat_meetup_sessions_pkey DO NOTHING;

        SELECT session_row.* INTO v_session
          FROM public.chat_meetup_sessions AS session_row
         WHERE session_row.meetup_id = v_meetup.id
         FOR UPDATE;
        v_session_exists := FOUND;
        v_meetup_id := v_meetup.id;
        v_revision := v_session.revision;
        v_session_created := true;

        INSERT INTO public.chat_meetup_private_decisions
          (match_id, room_id, meetup_id, user_id, intent_value)
        VALUES (v_match_id, p_room_id, v_meetup.id,
          CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END, true)
        ON CONFLICT (match_id, user_id) DO UPDATE
          SET meetup_id = EXCLUDED.meetup_id,
              intent_value = true,
              time_choice_id = NULL,
              cafe_choice_id = NULL,
              completed_at = NULL;

        INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
        VALUES (v_meetup.id, v_revision, 'state:mutual-intent', 'system',
          'You both want to meet. Choose a time together.')
        ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;

        UPDATE public.chat_meetup_private_decisions
           SET meetup_id = v_meetup.id
         WHERE match_id = v_match_id AND user_id = p_user_id;
        UPDATE public.chat_meetup_private_decisions
           SET time_choice_id = NULL, cafe_choice_id = NULL, completed_at = NULL
         WHERE match_id = v_match_id
           AND user_id = CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END;
      END IF;
    END IF;
  ELSE
    IF NOT v_session_exists OR (v_session.expires_at IS NOT NULL AND v_session.expires_at <= v_now AND v_session.status <> 'expired') THEN
      RETURN QUERY SELECT 'invalid_state'::text,
        CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
        CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
        v_revision, v_own_revision;
      RETURN;
    END IF;

    IF v_session.status NOT IN ('cancelled', 'expired', 'completed') OR (v_action_type = 'replan' AND v_session.status = 'expired') THEN
      IF (
        SELECT count(*) FROM public.user_profiles AS profile
         WHERE profile.id IN (v_a_id, v_b_id)
           AND (p_synthetic_admitted OR profile.identity_verification_status = 'verified')
           AND (p_synthetic_admitted OR profile.identity_verified_at IS NOT NULL)
      ) <> 2
      AND v_action_type IN (
        'availability.submit', 'time.approve', 'location.submit',
        'cafe.approve', 'cafe.decline', 'replan'
      ) THEN
        RETURN QUERY SELECT 'identity_verification_required'::text, v_meetup_id,
          v_session.status, v_revision, v_own_revision;
        RETURN;
      END IF;

      IF v_action_type = 'availability.submit' THEN
        IF v_session.status <> 'awaiting_availability' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        IF p_action ->> 'source' IS NULL OR p_action ->> 'source' NOT IN ('calendar', 'manual')
           OR pg_catalog.jsonb_typeof(p_action -> 'window') IS DISTINCT FROM 'object'
           OR pg_catalog.jsonb_typeof(COALESCE(p_action -> 'busy', p_action -> 'available')) IS DISTINCT FROM 'array'
           OR pg_catalog.jsonb_array_length(COALESCE(p_action -> 'busy', p_action -> 'available')) > 128 THEN
          RETURN QUERY SELECT 'invalid_input'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        INSERT INTO public.chat_meetup_availability
          (meetup_id, user_id, source, window_starts_at, window_ends_at, intervals, expires_at, created_at)
        VALUES (
          v_meetup_id, p_user_id, p_action ->> 'source',
          (p_action -> 'window' ->> 'starts_at')::timestamptz,
          (p_action -> 'window' ->> 'ends_at')::timestamptz,
          COALESCE(p_action -> 'busy', p_action -> 'available'),
          v_now + pg_catalog.interval '30 minutes', v_now
        )
        ON CONFLICT ON CONSTRAINT chat_meetup_availability_pkey DO UPDATE
          SET source = EXCLUDED.source,
              window_starts_at = EXCLUDED.window_starts_at,
              window_ends_at = EXCLUDED.window_ends_at,
              intervals = EXCLUDED.intervals,
              expires_at = EXCLUDED.expires_at,
              created_at = EXCLUDED.created_at;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;

        IF v_session.quota_claim_owner_id IS NULL
           AND 2 = (
             SELECT count(*) FROM public.chat_meetup_availability AS availability
              WHERE availability.meetup_id = v_meetup_id
                AND availability.expires_at > v_now
           ) THEN
          UPDATE public.chat_meetup_sessions
             SET quota_claim_owner_id = p_user_id,
                 quota_operation_key = 'chat-meetup:' || v_meetup_id::text
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id;
        END IF;
      ELSIF v_action_type = 'availability.clear' THEN
        IF v_session.status <> 'awaiting_availability' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        DELETE FROM public.chat_meetup_availability AS availability
         WHERE availability.meetup_id = v_meetup_id AND user_id = p_user_id;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
      ELSIF v_action_type = 'time.approve' THEN
        IF v_session.status <> 'time_proposed'
           OR NOT EXISTS (
             SELECT 1 FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
              WHERE candidate ->> 'id' = p_action ->> 'candidate_id'
           ) THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        SELECT candidate INTO v_time_candidate
          FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
         WHERE candidate ->> 'id' = p_action ->> 'candidate_id';
        IF v_time_candidate IS NULL
           OR (v_time_candidate ->> 'starts_at')::timestamptz <= pg_catalog.clock_timestamp()
           OR (v_time_candidate ->> 'ends_at')::timestamptz <= (v_time_candidate ->> 'starts_at')::timestamptz THEN
          RETURN QUERY SELECT 'expired_candidate'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        v_actor_choice := p_action ->> 'candidate_id';
        UPDATE public.chat_meetup_private_decisions
           SET time_choice_id = v_actor_choice,
               private_revision = private_revision + 1,
               updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
        SELECT decision.* INTO v_other_decision
          FROM public.chat_meetup_private_decisions AS decision
         WHERE decision.match_id = v_match_id
           AND decision.user_id = CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END;
        IF FOUND AND v_other_decision.time_choice_id = v_actor_choice THEN
          UPDATE public.chat_meetup_sessions
             SET status = 'confirmed',
                 selected_time_candidate_id = v_actor_choice,
                 confirmed_starts_at = (v_time_candidate ->> 'starts_at')::timestamptz,
                 confirmed_ends_at = (v_time_candidate ->> 'ends_at')::timestamptz,
                 confirmed_timezone = 'UTC',
                 cafe_candidates = '[]'::jsonb,
                 cafe_choice_a = NULL,
                 cafe_choice_b = NULL,
                 unavailable_reason = NULL,
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now,
                 expires_at = NULL
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          UPDATE public.chat_meetup_private_decisions
             SET cafe_choice_id = NULL
           WHERE match_id = v_match_id;
          UPDATE public.meetups AS meetup_row
             SET status = 'confirmed',
                 confirmed_start_at = v_session.confirmed_starts_at,
                 confirmed_timezone = 'UTC',
                 area = NULL,
                 format = NULL,
                 proposal_expires_at = NULL,
                 updated_at = v_now
           WHERE meetup_row.id = v_meetup_id
             AND meetup_row.status IN ('verifying', 'arranging', 'proposed');
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:confirmed:' || v_revision::text, 'system',
            'You both chose the same time. Your meetup is confirmed. Use Chat to agree on a place.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        END IF;
      ELSIF v_action_type = 'replan' THEN
        IF v_session.status = 'confirmed' THEN
          IF v_session.confirmed_ends_at IS NULL OR v_session.confirmed_ends_at <= v_now THEN
            RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
            RETURN;
          END IF;
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          UPDATE public.chat_meetup_sessions
             SET status = 'cancelled', expires_at = NULL,
                 revision = chat_meetup_sessions.revision + 1, updated_at = v_now
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          UPDATE public.meetups AS old_meetup
             SET status = 'cancelled', updated_at = v_now
           WHERE old_meetup.id = v_meetup_id AND old_meetup.status = 'confirmed';
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replaced:' || v_revision::text, 'system',
            'The confirmed plan was replaced with a new planning round.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
          v_previous_meetup_id := v_meetup_id;
          v_previous_revision := v_revision;
          INSERT INTO public.meetups
            (match_id, initiator_id, status, intent_a_at, intent_b_at, created_at, updated_at)
          VALUES (v_match_id, p_user_id, 'verifying', v_now, v_now, v_now, v_now)
          RETURNING * INTO v_meetup;
          INSERT INTO public.chat_meetup_sessions
            (meetup_id, match_id, room_id, user_a_id, user_b_id, status, revision, expires_at)
          VALUES (v_meetup.id, v_match_id, p_room_id, v_a_id, v_b_id,
            'awaiting_availability', v_revision + 1, v_now + pg_catalog.interval '7 days')
          RETURNING * INTO v_session;
          v_meetup_id := v_meetup.id;
          v_revision := v_session.revision;
          UPDATE public.chat_meetup_private_decisions
             SET meetup_id = v_meetup_id, time_choice_id = NULL,
                 cafe_choice_id = NULL, completed_at = NULL,
                 private_revision = private_revision + 1, updated_at = v_now
           WHERE match_id = v_match_id;
          SELECT decision.private_revision INTO v_own_revision
            FROM public.chat_meetup_private_decisions AS decision
           WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replan:' || v_revision::text, 'system',
            'A new plan is ready. Suggest availability to choose another time.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        ELSIF v_session.status = 'expired' THEN
          UPDATE public.meetups AS old_meetup
             SET status = 'expired', intent_expires_at = NULL,
                 proposal_expires_at = NULL, updated_at = v_now
           WHERE old_meetup.id = v_meetup_id
             AND old_meetup.status IN ('verifying', 'arranging', 'proposed');
          INSERT INTO public.meetups
            (match_id, initiator_id, status, intent_a_at, intent_b_at, created_at, updated_at)
          VALUES (v_match_id, p_user_id, 'verifying', v_now, v_now, v_now, v_now)
          RETURNING * INTO v_meetup;
          INSERT INTO public.chat_meetup_sessions
            (meetup_id, match_id, room_id, user_a_id, user_b_id, status, revision, expires_at)
          VALUES (v_meetup.id, v_match_id, p_room_id, v_a_id, v_b_id,
            'awaiting_availability', v_revision + 1, v_now + pg_catalog.interval '7 days')
          RETURNING * INTO v_session;
          v_meetup_id := v_meetup.id;
          v_revision := v_session.revision;
          UPDATE public.chat_meetup_private_decisions
             SET meetup_id = v_meetup_id, time_choice_id = NULL,
                 cafe_choice_id = NULL, completed_at = NULL,
                 private_revision = private_revision + 1, updated_at = v_now
           WHERE match_id = v_match_id;
          SELECT decision.private_revision INTO v_own_revision
            FROM public.chat_meetup_private_decisions AS decision
           WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replan:' || v_revision::text, 'system',
            'A new plan is ready. Suggest availability to choose another time.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        ELSIF v_session.status IN ('time_proposed', 'awaiting_location', 'cafe_proposed', 'unavailable') THEN
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          UPDATE public.chat_meetup_private_decisions
             SET time_choice_id = NULL, cafe_choice_id = NULL,
                 private_revision = private_revision + 1, updated_at = v_now
           WHERE match_id = v_match_id;
          UPDATE public.chat_meetup_sessions
             SET status = 'awaiting_availability',
                 time_candidates = '[]'::jsonb,
                 cafe_candidates = '[]'::jsonb,
                 time_choice_a = NULL, time_choice_b = NULL,
                 selected_time_candidate_id = NULL,
                 cafe_choice_a = NULL, cafe_choice_b = NULL,
                 confirmed_starts_at = NULL, confirmed_ends_at = NULL,
                 confirmed_timezone = NULL,
                 unavailable_reason = NULL,
                 expires_at = v_now + pg_catalog.interval '7 days',
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          UPDATE public.meetups AS meetup_row
             SET status = 'verifying', updated_at = v_now
           WHERE meetup_row.id = v_meetup_id
             AND meetup_row.status = 'arranging';
          SELECT decision.private_revision INTO v_own_revision
            FROM public.chat_meetup_private_decisions AS decision
           WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replan:' || v_revision::text, 'system',
            'You can suggest new availability and try again.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        ELSE
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
      ELSIF v_action_type = 'cancel' THEN
        IF v_session.status IN ('cancelled', 'expired', 'completed') THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
        DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
        UPDATE public.chat_meetup_sessions
           SET status = 'cancelled', expires_at = NULL,
               time_candidates = '[]'::jsonb, cafe_candidates = '[]'::jsonb,
               revision = chat_meetup_sessions.revision + 1, updated_at = v_now
         WHERE chat_meetup_sessions.meetup_id = v_meetup_id
         RETURNING * INTO v_session;
        v_revision := v_session.revision;
        UPDATE public.chat_meetup_private_decisions
           SET time_choice_id = NULL, cafe_choice_id = NULL
         WHERE match_id = v_match_id;
        UPDATE public.meetups AS meetup_row
           SET status = 'cancelled', intent_expires_at = NULL,
               proposal_expires_at = NULL, updated_at = v_now
         WHERE meetup_row.id = v_meetup_id
           AND meetup_row.status NOT IN ('completed', 'no_show', 'declined', 'expired', 'cancelled');
        INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
        VALUES (v_meetup_id, v_revision, 'state:cancelled:' || v_revision::text, 'system',
          'This meetup plan was cancelled.')
        ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
      ELSIF v_action_type = 'meeting.complete' THEN
        IF v_session.status <> 'confirmed'
           OR v_session.confirmed_ends_at IS NULL
           OR v_session.confirmed_ends_at > pg_catalog.clock_timestamp() THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        UPDATE public.chat_meetup_private_decisions
           SET completed_at = COALESCE(completed_at, v_now),
               private_revision = private_revision + 1,
               updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
        IF p_user_id = v_a_id THEN
          UPDATE public.chat_meetup_sessions AS session_row
             SET completed_a_at = COALESCE(session_row.completed_a_at, v_now)
           WHERE session_row.meetup_id = v_meetup_id;
        ELSE
          UPDATE public.chat_meetup_sessions AS session_row
             SET completed_b_at = COALESCE(session_row.completed_b_at, v_now)
           WHERE session_row.meetup_id = v_meetup_id;
        END IF;
        SELECT session_row.* INTO v_session
          FROM public.chat_meetup_sessions AS session_row
         WHERE session_row.meetup_id = v_meetup_id;
        IF v_session.completed_a_at IS NOT NULL AND v_session.completed_b_at IS NOT NULL THEN
          UPDATE public.chat_meetup_sessions
             SET status = 'completed',
                 completed_a_at = (SELECT decision.completed_at FROM public.chat_meetup_private_decisions AS decision WHERE decision.match_id = v_match_id AND decision.user_id = v_a_id),
                 completed_b_at = (SELECT decision.completed_at FROM public.chat_meetup_private_decisions AS decision WHERE decision.match_id = v_match_id AND decision.user_id = v_b_id),
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          UPDATE public.meetups AS meetup_row
             SET status = 'completed', updated_at = v_now
           WHERE meetup_row.id = v_meetup_id AND meetup_row.status = 'confirmed';
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:completed:' || v_revision::text, 'system',
            'You both marked this meetup complete.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        END IF;
      ELSE
        RETURN QUERY SELECT 'invalid_input'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
        RETURN;
      END IF;
    ELSE
      RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
      RETURN;
    END IF;
  END IF;

  -- Record only a digest and safe outcome metadata. Replays are access-checked
  -- above and the HTTP service returns the fresh caller-scoped projection.
  INSERT INTO public.chat_meetup_operations
    (room_id, user_id, idempotency_key, meetup_id, request_digest, outcome, result_status, result_revision)
  VALUES (
    p_room_id, p_user_id, p_idempotency_key,
    CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
    p_request_digest, 'ok',
    CASE WHEN v_session_exists THEN v_session.status ELSE COALESCE(v_meetup.status, 'idle') END,
    v_revision
  );

  RETURN QUERY SELECT 'ok'::text,
    CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
    CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
    v_revision, v_own_revision;
END;
$core$;

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
BEGIN
  IF p_action_type IS NULL OR p_action_type NOT IN ('cafe.approve', 'cafe.decline') THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;
  RETURN QUERY SELECT * FROM public.apply_chat_meetup_action(p_room_id,p_user_id,p_expected_revision,p_expected_own_revision,p_idempotency_key,p_request_digest,pg_catalog.jsonb_build_object('type',p_action_type,'candidate_id',p_candidate_id));
END;
$$;

CREATE OR REPLACE FUNCTION wingward_private.demo_recording_core_apply_chat_meetup_google_cafe_action(p_synthetic_admitted boolean,
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
AS $core$
BEGIN
  IF p_action_type IS NULL OR p_action_type NOT IN ('cafe.approve', 'cafe.decline') THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;
  RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_apply_chat_meetup_action(p_synthetic_admitted,p_room_id,p_user_id,p_expected_revision,p_expected_own_revision,p_idempotency_key,p_request_digest,pg_catalog.jsonb_build_object('type',p_action_type,'candidate_id',p_candidate_id));
END;
$core$;
