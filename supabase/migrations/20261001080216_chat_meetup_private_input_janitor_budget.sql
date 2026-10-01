-- Additive replacement: hard 125-session / 500-private-input budget per call.
-- Applied migration 20260926070000 remains unchanged.
CREATE OR REPLACE FUNCTION public.prune_chat_meetup_private_inputs()
RETURNS TABLE (pruned integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted integer := 0;
  v_expired_session record;
  v_session_revision integer := 0;
  v_added integer := 0;
  v_now timestamptz := pg_catalog.now();
BEGIN
  -- Terminalize at most 125 elapsed active plans per pass. The service-facing
  -- return value remains only the private-input row count.
  FOR v_expired_session IN
    SELECT session_row.meetup_id
      FROM public.chat_meetup_sessions AS session_row
     WHERE session_row.expires_at <= v_now
       AND session_row.status NOT IN ('completed', 'cancelled', 'expired')
     ORDER BY session_row.expires_at, session_row.meetup_id
     LIMIT 125
     FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.chat_meetup_sessions
       SET status = 'expired', expires_at = NULL,
           time_candidates = '[]'::jsonb, cafe_candidates = '[]'::jsonb,
           time_choice_a = NULL, time_choice_b = NULL,
           selected_time_candidate_id = NULL, cafe_choice_a = NULL, cafe_choice_b = NULL,
           unavailable_reason = NULL,
           revision = chat_meetup_sessions.revision + 1, updated_at = v_now
     WHERE chat_meetup_sessions.meetup_id = v_expired_session.meetup_id
     RETURNING revision INTO v_session_revision;
    UPDATE public.meetups AS legacy
       SET status = 'expired', intent_expires_at = NULL,
           proposal_expires_at = NULL, updated_at = v_now
     WHERE legacy.id = v_expired_session.meetup_id
       AND legacy.status IN ('verifying', 'arranging', 'proposed');
    -- Count every DELETE against the same hard budget, including terminalized
    -- sessions. The tables' PKs do not structurally limit rows to two people.
    -- Any excess remains eligible for the next bounded pass; no input is read
    -- or returned, and the shared expiry event is still emitted only once.
    WITH doomed AS (
      SELECT availability.meetup_id, availability.user_id
        FROM public.chat_meetup_availability AS availability
       WHERE availability.meetup_id = v_expired_session.meetup_id
       ORDER BY availability.user_id
       LIMIT (500 - v_deleted)
       FOR UPDATE SKIP LOCKED
    )
    DELETE FROM public.chat_meetup_availability AS availability USING doomed
     WHERE availability.meetup_id = doomed.meetup_id
       AND availability.user_id = doomed.user_id;
    GET DIAGNOSTICS v_added = ROW_COUNT;
    v_deleted := v_deleted + v_added;
    WITH doomed AS (
      SELECT location.meetup_id, location.user_id
        FROM public.chat_meetup_locations AS location
       WHERE location.meetup_id = v_expired_session.meetup_id
       ORDER BY location.user_id
       LIMIT (500 - v_deleted)
       FOR UPDATE SKIP LOCKED
    )
    DELETE FROM public.chat_meetup_locations AS location USING doomed
     WHERE location.meetup_id = doomed.meetup_id
       AND location.user_id = doomed.user_id;
    GET DIAGNOSTICS v_added = ROW_COUNT;
    v_deleted := v_deleted + v_added;
    INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
    VALUES (v_expired_session.meetup_id, v_session_revision,
            'state:expired:' || v_session_revision::text, 'system',
            'This meetup plan expired. You can start another plan.')
    ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
  END LOOP;

  IF v_deleted < 500 THEN
  WITH expired AS (
    SELECT availability.meetup_id, availability.user_id
      FROM public.chat_meetup_availability AS availability
     WHERE availability.expires_at <= v_now
        OR EXISTS (
          SELECT 1 FROM public.chat_meetup_sessions AS session_row
           WHERE session_row.meetup_id = availability.meetup_id
             AND session_row.status <> 'awaiting_availability'
        )
     ORDER BY availability.expires_at, availability.meetup_id, availability.user_id
     LIMIT (500 - v_deleted)
     FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.chat_meetup_availability AS availability
   USING expired
   WHERE availability.meetup_id = expired.meetup_id
     AND availability.user_id = expired.user_id;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  v_deleted := v_deleted + v_added;

  IF v_deleted < 500 THEN
    WITH expired AS (
      SELECT location.meetup_id, location.user_id
        FROM public.chat_meetup_locations AS location
       WHERE location.expires_at <= v_now
          OR EXISTS (
            SELECT 1 FROM public.chat_meetup_sessions AS session_row
             WHERE session_row.meetup_id = location.meetup_id
               AND session_row.status <> 'awaiting_location'
          )
       ORDER BY location.expires_at, location.meetup_id, location.user_id
       LIMIT (500 - v_deleted)
       FOR UPDATE SKIP LOCKED
    )
    DELETE FROM public.chat_meetup_locations AS location
     USING expired
     WHERE location.meetup_id = expired.meetup_id
       AND location.user_id = expired.user_id;
    GET DIAGNOSTICS v_added = ROW_COUNT;
    v_deleted := v_deleted + v_added;
  END IF;
  END IF;

  RETURN QUERY SELECT v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_chat_meetup_private_inputs()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_chat_meetup_private_inputs()
  TO service_role;
