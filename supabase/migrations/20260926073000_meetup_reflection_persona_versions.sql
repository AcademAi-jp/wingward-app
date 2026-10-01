-- Private post-meetup reflection state and cumulative, owner-confirmed persona
-- snapshots. Raw audio/transcripts and AI draft candidates are never written.

CREATE OR REPLACE FUNCTION wingward_private.is_valid_persona_traits(p_traits jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_entry record;
  v_value text;
  v_count integer := 0;
BEGIN
  IF pg_catalog.jsonb_typeof(p_traits) IS DISTINCT FROM 'object' THEN
    RETURN false;
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
    FROM pg_catalog.jsonb_object_keys(p_traits);
  IF v_count < 1 OR v_count > 9 THEN
    RETURN false;
  END IF;

  FOR v_entry IN SELECT key, value FROM pg_catalog.jsonb_each(p_traits) LOOP
    IF pg_catalog.jsonb_typeof(v_entry.value) IS DISTINCT FROM 'string' THEN
      RETURN false;
    END IF;
    v_value := v_entry.value #>> '{}';
    IF NOT (CASE v_entry.key
      WHEN 'social_energy' THEN v_value IN ('introverted', 'ambiverted', 'extroverted')
      WHEN 'planning_style' THEN v_value IN ('planned', 'mixed', 'spontaneous')
      WHEN 'decision_style' THEN v_value IN ('analytical', 'balanced', 'emotional')
      WHEN 'attachment_tendency' THEN v_value IN ('secure', 'anxious', 'avoidant')
      WHEN 'conflict_style' THEN v_value IN ('dialogue', 'yields', 'maintains', 'avoids')
      WHEN 'rhythm_preference' THEN v_value IN ('slow', 'moderate', 'fast')
      WHEN 'communication_preference' THEN v_value IN ('concise', 'balanced', 'detailed')
      WHEN 'priority_value' THEN v_value IN ('family', 'friendship', 'independence', 'creativity', 'learning', 'stability', 'community')
      WHEN 'favorite_activity' THEN v_value IN ('arts', 'music', 'reading', 'outdoors', 'food', 'technology', 'sports')
      ELSE false
    END) THEN
      RETURN false;
    END IF;
  END LOOP;
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION wingward_private.is_valid_persona_traits(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.is_valid_persona_traits(jsonb) IS
  'Private validator for the closed, bounded enum-only persona preference map; it never accepts transcript or free-text fields.';


CREATE TABLE public.user_persona_versions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  version integer NOT NULL CHECK (version >= 1),
  based_on_version integer NOT NULL CHECK (based_on_version >= 0 AND version = based_on_version + 1),
  source_meetup_id uuid REFERENCES public.chat_meetup_sessions(meetup_id) ON DELETE SET NULL,
  traits jsonb NOT NULL,
  confirmed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, version),
  CHECK (wingward_private.is_valid_persona_traits(traits))
);
CREATE INDEX user_persona_versions_latest_idx
  ON public.user_persona_versions (user_id, version DESC);

-- Store only a digest and the resulting immutable version for safe retries.
-- No transcript, candidate evidence, or request text enters this ledger.
CREATE TABLE public.user_persona_confirmation_operations (
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  idempotency_key uuid NOT NULL,
  request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
  source_meetup_id uuid NOT NULL,
  persona_version integer NOT NULL CHECK (persona_version >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, idempotency_key),
  FOREIGN KEY (user_id, persona_version)
    REFERENCES public.user_persona_versions(user_id, version) ON DELETE CASCADE
);

ALTER TABLE public.user_persona_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_persona_confirmation_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_persona_versions,
  public.user_persona_confirmation_operations FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.user_persona_versions TO service_role;
-- No direct grants on the idempotency ledger. Both tables are accessed only
-- inside the SECURITY DEFINER RPC below.


CREATE OR REPLACE FUNCTION public.get_meetup_reflection_state(
  p_meetup_id uuid,
  p_user_id uuid
)
RETURNS TABLE (
  outcome text,
  current_version integer,
  traits jsonb,
  confirmed_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_initial public.chat_meetup_sessions%ROWTYPE;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_meetup public.meetups%ROWTYPE;
  v_now timestamptz := pg_catalog.now();
  v_current_version integer := 0;
  v_traits jsonb := '{}'::jsonb;
  v_confirmed_at timestamptz;
  v_mutual_eligible boolean;
BEGIN
  IF p_meetup_id IS NULL OR p_user_id IS NULL THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::jsonb, NULL::timestamptz;
    RETURN;
  END IF;

  -- Resolve participant IDs without locking so every transition first locks
  -- the current profile pair in UUID order, then match -> room/meetup -> session.
  SELECT session_row.* INTO v_initial
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.meetup_id = p_meetup_id;
  IF NOT FOUND
     OR (p_user_id <> v_initial.user_a_id AND p_user_id <> v_initial.user_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::jsonb, NULL::timestamptz;
    RETURN;
  END IF;

  v_mutual_eligible := wingward_private.lock_and_check_mutual_eligibility(
    v_initial.user_a_id, v_initial.user_b_id
  );
  IF NOT COALESCE(v_mutual_eligible, false)
     OR (
       SELECT pg_catalog.count(*) FROM public.user_profiles AS profile_row
        WHERE profile_row.id IN (v_initial.user_a_id, v_initial.user_b_id)
          AND profile_row.identity_verification_status = 'verified'
          AND profile_row.identity_verified_at IS NOT NULL
          AND pg_catalog.isfinite(profile_row.identity_verified_at)
          AND profile_row.identity_verified_at <= v_now
     ) <> 2 THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::jsonb, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_initial.match_id
   FOR UPDATE;
  IF NOT FOUND
     OR v_match.status IS DISTINCT FROM 'direct_chat_active'
     OR v_match.user_a_id IS DISTINCT FROM v_initial.user_a_id
     OR v_match.user_b_id IS DISTINCT FROM v_initial.user_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::jsonb, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.id = v_initial.room_id
     AND room_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::jsonb, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT meetup_row.* INTO v_meetup
    FROM public.meetups AS meetup_row
   WHERE meetup_row.id = p_meetup_id
     AND meetup_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::jsonb, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT session_row.* INTO v_session
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.meetup_id = p_meetup_id
   FOR UPDATE;
  IF NOT FOUND
     OR v_session.match_id IS DISTINCT FROM v_match.id
     OR v_session.room_id IS DISTINCT FROM v_room.id
     OR v_session.user_a_id IS DISTINCT FROM v_match.user_a_id
     OR v_session.user_b_id IS DISTINCT FROM v_match.user_b_id
     OR v_session.status NOT IN ('confirmed', 'completed')
     OR v_session.confirmed_ends_at IS NULL
     OR v_session.confirmed_ends_at > v_now
     OR (CASE WHEN p_user_id = v_session.user_a_id
         THEN v_session.completed_a_at IS NULL
         ELSE v_session.completed_b_at IS NULL
       END) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::jsonb, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT version_row.version, version_row.traits, version_row.confirmed_at
    INTO v_current_version, v_traits, v_confirmed_at
    FROM public.user_persona_versions AS version_row
   WHERE version_row.user_id = p_user_id
   ORDER BY version_row.version DESC
   LIMIT 1;
  IF NOT FOUND THEN
    v_current_version := 0;
    v_traits := '{}'::jsonb;
    v_confirmed_at := NULL;
  END IF;

  RETURN QUERY SELECT 'ok'::text, v_current_version, v_traits, v_confirmed_at;
END;
$$;
REVOKE ALL ON FUNCTION public.get_meetup_reflection_state(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_meetup_reflection_state(uuid, uuid) TO service_role;
COMMENT ON FUNCTION public.get_meetup_reflection_state(uuid, uuid) IS
  'Owner-scoped reflection state. Requires the caller to be a completed participant in an ended confirmed chat meetup and rechecks current mutual eligibility, identity, room, and block state.';

CREATE OR REPLACE FUNCTION public.confirm_meetup_reflection(
  p_meetup_id uuid,
  p_user_id uuid,
  p_idempotency_key uuid,
  p_expected_version integer,
  p_traits jsonb
)
RETURNS TABLE (
  outcome text,
  version integer,
  confirmed_at timestamptz,
  traits jsonb
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_initial public.chat_meetup_sessions%ROWTYPE;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_meetup public.meetups%ROWTYPE;
  v_now timestamptz := pg_catalog.now();
  v_mutual_eligible boolean;
  v_digest text;
  v_existing public.user_persona_confirmation_operations%ROWTYPE;
  v_previous_version integer := 0;
  v_previous_traits jsonb := '{}'::jsonb;
  v_new_version integer;
  v_new_traits jsonb;
  v_new_confirmed_at timestamptz;
BEGIN
  IF p_meetup_id IS NULL OR p_user_id IS NULL OR p_idempotency_key IS NULL
     OR p_expected_version IS NULL OR p_expected_version < 0 OR p_expected_version >= 2000000000
     OR NOT wingward_private.is_valid_persona_traits(p_traits) THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
    RETURN;
  END IF;

  SELECT session_row.* INTO v_initial
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.meetup_id = p_meetup_id;
  IF NOT FOUND
     OR (p_user_id <> v_initial.user_a_id AND p_user_id <> v_initial.user_b_id) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
    RETURN;
  END IF;

  v_mutual_eligible := wingward_private.lock_and_check_mutual_eligibility(
    v_initial.user_a_id, v_initial.user_b_id
  );
  IF NOT COALESCE(v_mutual_eligible, false)
     OR (
       SELECT pg_catalog.count(*) FROM public.user_profiles AS profile_row
        WHERE profile_row.id IN (v_initial.user_a_id, v_initial.user_b_id)
          AND profile_row.identity_verification_status = 'verified'
          AND profile_row.identity_verified_at IS NOT NULL
          AND pg_catalog.isfinite(profile_row.identity_verified_at)
          AND profile_row.identity_verified_at <= v_now
     ) <> 2 THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
    RETURN;
  END IF;

  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_initial.match_id
   FOR UPDATE;
  IF NOT FOUND
     OR v_match.status IS DISTINCT FROM 'direct_chat_active'
     OR v_match.user_a_id IS DISTINCT FROM v_initial.user_a_id
     OR v_match.user_b_id IS DISTINCT FROM v_initial.user_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
    RETURN;
  END IF;

  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.id = v_initial.room_id
     AND room_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
    RETURN;
  END IF;

  SELECT meetup_row.* INTO v_meetup
    FROM public.meetups AS meetup_row
   WHERE meetup_row.id = p_meetup_id
     AND meetup_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
    RETURN;
  END IF;

  SELECT session_row.* INTO v_session
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.meetup_id = p_meetup_id
   FOR UPDATE;
  IF NOT FOUND
     OR v_session.match_id IS DISTINCT FROM v_match.id
     OR v_session.room_id IS DISTINCT FROM v_room.id
     OR v_session.user_a_id IS DISTINCT FROM v_match.user_a_id
     OR v_session.user_b_id IS DISTINCT FROM v_match.user_b_id
     OR v_session.status NOT IN ('confirmed', 'completed')
     OR v_session.confirmed_ends_at IS NULL
     OR v_session.confirmed_ends_at > v_now
     OR (CASE WHEN p_user_id = v_session.user_a_id
         THEN v_session.completed_a_at IS NULL
         ELSE v_session.completed_b_at IS NULL
       END) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
    RETURN;
  END IF;

  -- Serialize all new persona versions for one owner after the canonical
  -- participant/profile/match/room/meetup/session lock sequence.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('wingward-persona:' || p_user_id::text, 0)
  );
  v_digest := pg_catalog.encode(
    pg_catalog.sha256(pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'meetup_id', p_meetup_id,
        'expected_version', p_expected_version,
        'traits', p_traits
      )::text,
      'UTF8'
    )),
    'hex'
  );

  SELECT operation_row.* INTO v_existing
    FROM public.user_persona_confirmation_operations AS operation_row
   WHERE operation_row.user_id = p_user_id
     AND operation_row.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_existing.request_sha256 IS DISTINCT FROM v_digest
       OR v_existing.source_meetup_id IS DISTINCT FROM p_meetup_id THEN
      RETURN QUERY SELECT 'key_reused'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
      RETURN;
    END IF;
    RETURN QUERY
      SELECT 'replayed'::text, version_row.version, version_row.confirmed_at, version_row.traits
        FROM public.user_persona_versions AS version_row
       WHERE version_row.user_id = p_user_id
         AND version_row.version = v_existing.persona_version;
    IF NOT FOUND THEN
      RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
    END IF;
    RETURN;
  END IF;

  SELECT version_row.version, version_row.traits
    INTO v_previous_version, v_previous_traits
    FROM public.user_persona_versions AS version_row
   WHERE version_row.user_id = p_user_id
   ORDER BY version_row.version DESC
   LIMIT 1;
  IF NOT FOUND THEN
    v_previous_version := 0;
    v_previous_traits := '{}'::jsonb;
  END IF;

  IF v_previous_version IS DISTINCT FROM p_expected_version THEN
    RETURN QUERY SELECT 'version_conflict'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
    RETURN;
  END IF;

  v_new_version := v_previous_version + 1;
  v_new_traits := v_previous_traits || p_traits;
  v_new_confirmed_at := v_now;
  INSERT INTO public.user_persona_versions (
    user_id, version, based_on_version, source_meetup_id, traits, confirmed_at, created_at
  ) VALUES (
    p_user_id, v_new_version, v_previous_version, p_meetup_id, v_new_traits, v_new_confirmed_at, v_now
  );
  INSERT INTO public.user_persona_confirmation_operations (
    user_id, idempotency_key, request_sha256, source_meetup_id, persona_version, created_at
  ) VALUES (
    p_user_id, p_idempotency_key, v_digest, p_meetup_id, v_new_version, v_now
  );
  RETURN QUERY SELECT 'confirmed'::text, v_new_version, v_new_confirmed_at, v_new_traits;
END;
$$;
REVOKE ALL ON FUNCTION public.confirm_meetup_reflection(uuid, uuid, uuid, integer, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_meetup_reflection(uuid, uuid, uuid, integer, jsonb)
  TO service_role;
COMMENT ON FUNCTION public.confirm_meetup_reflection(uuid, uuid, uuid, integer, jsonb) IS
  'Service-only atomic owner confirmation with completed-meetup authorization, current eligibility recheck, cumulative version CAS, and idempotent replay. Persists only validated enum traits.';
