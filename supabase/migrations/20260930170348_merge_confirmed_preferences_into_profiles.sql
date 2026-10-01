DO $guard$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_proc WHERE oid='public.confirm_meetup_reflection(uuid,uuid,uuid,integer,jsonb)'::regprocedure AND md5(prosrc) IN ('bb5d90034ad0755be5432010f0a9f9ec','de3f3be23e7fcb470ae8e19e9407b5be')) THEN RAISE EXCEPTION 'Canonical confirmation RPC drift'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_proc WHERE oid='wingward_private.demo_recording_core_confirm_meetup_reflection(boolean,uuid,uuid,uuid,integer,jsonb)'::regprocedure AND md5(prosrc) IN ('9daa36d77ff9d4cf0fff2d36804808a0','a387c5ceb8b9e19ac164d25552859cfb')) THEN RAISE EXCEPTION 'Canonical confirmation RPC drift'; END IF;
END;
$guard$;

-- Owner-confirmed preferences live in the existing canonical profile.
-- No AI generation, tag inference, analysis rewrite or automatic historical backfill.
ALTER TABLE public.profiles
 ADD COLUMN IF NOT EXISTS confirmed_preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
 ADD COLUMN IF NOT EXISTS merged_persona_version integer NOT NULL DEFAULT 0;
DO $constraints$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid='public.profiles'::regclass AND conname='profiles_confirmed_preferences_closed') THEN
  ALTER TABLE public.profiles ADD CONSTRAINT profiles_confirmed_preferences_closed CHECK (
pg_catalog.jsonb_typeof(confirmed_preferences) = 'object'
 AND confirmed_preferences - ARRAY['social_energy', 'planning_style', 'decision_style', 'attachment_tendency', 'conflict_style', 'rhythm_preference', 'communication_preference', 'priority_value', 'favorite_activity']::text[] = '{}'::jsonb
 AND (NOT (confirmed_preferences ? 'social_energy') OR (pg_catalog.jsonb_typeof(confirmed_preferences -> 'social_energy') = 'string' AND confirmed_preferences ->> 'social_energy' IN ('introverted', 'ambiverted', 'extroverted')))
 AND (NOT (confirmed_preferences ? 'planning_style') OR (pg_catalog.jsonb_typeof(confirmed_preferences -> 'planning_style') = 'string' AND confirmed_preferences ->> 'planning_style' IN ('planned', 'mixed', 'spontaneous')))
 AND (NOT (confirmed_preferences ? 'decision_style') OR (pg_catalog.jsonb_typeof(confirmed_preferences -> 'decision_style') = 'string' AND confirmed_preferences ->> 'decision_style' IN ('analytical', 'balanced', 'emotional')))
 AND (NOT (confirmed_preferences ? 'attachment_tendency') OR (pg_catalog.jsonb_typeof(confirmed_preferences -> 'attachment_tendency') = 'string' AND confirmed_preferences ->> 'attachment_tendency' IN ('secure', 'anxious', 'avoidant')))
 AND (NOT (confirmed_preferences ? 'conflict_style') OR (pg_catalog.jsonb_typeof(confirmed_preferences -> 'conflict_style') = 'string' AND confirmed_preferences ->> 'conflict_style' IN ('dialogue', 'yields', 'maintains', 'avoids')))
 AND (NOT (confirmed_preferences ? 'rhythm_preference') OR (pg_catalog.jsonb_typeof(confirmed_preferences -> 'rhythm_preference') = 'string' AND confirmed_preferences ->> 'rhythm_preference' IN ('slow', 'moderate', 'fast')))
 AND (NOT (confirmed_preferences ? 'communication_preference') OR (pg_catalog.jsonb_typeof(confirmed_preferences -> 'communication_preference') = 'string' AND confirmed_preferences ->> 'communication_preference' IN ('concise', 'balanced', 'detailed')))
 AND (NOT (confirmed_preferences ? 'priority_value') OR (pg_catalog.jsonb_typeof(confirmed_preferences -> 'priority_value') = 'string' AND confirmed_preferences ->> 'priority_value' IN ('family', 'friendship', 'independence', 'creativity', 'learning', 'stability', 'community')))
 AND (NOT (confirmed_preferences ? 'favorite_activity') OR (pg_catalog.jsonb_typeof(confirmed_preferences -> 'favorite_activity') = 'string' AND confirmed_preferences ->> 'favorite_activity' IN ('arts', 'music', 'reading', 'outdoors', 'food', 'technology', 'sports'))));
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_constraint WHERE conrelid='public.profiles'::regclass AND conname='profiles_merged_persona_version_consistent') THEN
  ALTER TABLE public.profiles ADD CONSTRAINT profiles_merged_persona_version_consistent CHECK (
    merged_persona_version BETWEEN 0 AND 2000000000
    AND ((merged_persona_version=0 AND confirmed_preferences='{}'::jsonb)
      OR (merged_persona_version>0 AND confirmed_preferences<>'{}'::jsonb)));
 END IF;
END;
$constraints$;

-- Preserve every pre-existing authenticated profile-update column; the two
-- authoritative confirmation fields must only be written by trusted SQL.
REVOKE UPDATE ON TABLE public.profiles FROM authenticated;
DO $columns$
DECLARE columns text;
BEGIN
 SELECT pg_catalog.string_agg(pg_catalog.quote_ident(attname),', ' ORDER BY attnum)
 INTO columns FROM pg_catalog.pg_attribute
 WHERE attrelid='public.profiles'::regclass AND attnum>0 AND NOT attisdropped
 AND attname NOT IN('confirmed_preferences','merged_persona_version');
 EXECUTE 'GRANT UPDATE ('||columns||') ON TABLE public.profiles TO authenticated';
END;
$columns$;
COMMENT ON COLUMN public.profiles.confirmed_preferences IS 'Cumulative closed enum preferences explicitly confirmed by this owner; copied atomically from authoritative user_persona_versions, preserving original profile analysis.';
COMMENT ON COLUMN public.profiles.merged_persona_version IS 'Authoritative owner persona version already merged into this canonical profile; zero means no merge has occurred.';

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
  v_profile public.profiles%ROWTYPE;
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

  -- Canonical saved profile is the same owner, not an inferred replacement.
  -- Existing historical versions may be unmerged; their closed cumulative
  -- traits remain authoritative for this newly confirmed version.
  SELECT profile_row.* INTO v_profile
    FROM public.profiles AS profile_row
   WHERE profile_row.user_id = p_user_id
   FOR UPDATE;
  IF NOT FOUND OR v_profile.status IS DISTINCT FROM 'confirmed'
     OR v_profile.confirmed_at IS NULL
     OR NOT pg_catalog.isfinite(v_profile.confirmed_at)
     OR v_profile.confirmed_at > pg_catalog.clock_timestamp()
     OR v_profile.version < 1 OR v_profile.version >= 2000000000
     OR v_profile.merged_persona_version > v_previous_version
     OR (v_profile.merged_persona_version = 0 AND v_profile.confirmed_preferences <> '{}'::jsonb)
     OR (v_profile.merged_persona_version > 0 AND NOT EXISTS (
       SELECT 1 FROM public.user_persona_versions AS merged_row
        WHERE merged_row.user_id = p_user_id
          AND merged_row.version = v_profile.merged_persona_version
          AND merged_row.traits = v_profile.confirmed_preferences
     )) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
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
  -- This update and the persona/version ledger insert commit or roll back
  -- together. Original profile columns, status and confirmation are untouched.
  UPDATE public.profiles AS profile_row
     SET confirmed_preferences = v_new_traits,
         merged_persona_version = v_new_version,
         version = profile_row.version + 1,
         updated_at = pg_catalog.clock_timestamp()
   WHERE profile_row.id = v_profile.id AND profile_row.user_id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Canonical owner profile unavailable' USING ERRCODE='40001';
  END IF;
  RETURN QUERY SELECT 'confirmed'::text, v_new_version, v_new_confirmed_at, v_new_traits;
END;
$$;

CREATE OR REPLACE FUNCTION wingward_private.demo_recording_core_confirm_meetup_reflection(p_synthetic_admitted boolean,
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
AS $core$
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
  v_profile public.profiles%ROWTYPE;
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
          AND (p_synthetic_admitted OR profile_row.identity_verification_status = 'verified')
          AND (p_synthetic_admitted OR profile_row.identity_verified_at IS NOT NULL)
          AND (p_synthetic_admitted OR pg_catalog.isfinite(profile_row.identity_verified_at))
          AND (p_synthetic_admitted OR profile_row.identity_verified_at <= v_now)
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

  -- Canonical saved profile is the same owner, not an inferred replacement.
  -- Existing historical versions may be unmerged; their closed cumulative
  -- traits remain authoritative for this newly confirmed version.
  SELECT profile_row.* INTO v_profile
    FROM public.profiles AS profile_row
   WHERE profile_row.user_id = p_user_id
   FOR UPDATE;
  IF NOT FOUND OR v_profile.status IS DISTINCT FROM 'confirmed'
     OR v_profile.confirmed_at IS NULL
     OR NOT pg_catalog.isfinite(v_profile.confirmed_at)
     OR v_profile.confirmed_at > pg_catalog.clock_timestamp()
     OR v_profile.version < 1 OR v_profile.version >= 2000000000
     OR v_profile.merged_persona_version > v_previous_version
     OR (v_profile.merged_persona_version = 0 AND v_profile.confirmed_preferences <> '{}'::jsonb)
     OR (v_profile.merged_persona_version > 0 AND NOT EXISTS (
       SELECT 1 FROM public.user_persona_versions AS merged_row
        WHERE merged_row.user_id = p_user_id
          AND merged_row.version = v_profile.merged_persona_version
          AND merged_row.traits = v_profile.confirmed_preferences
     )) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::integer, NULL::timestamptz, NULL::jsonb;
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
  -- This update and the persona/version ledger insert commit or roll back
  -- together. Original profile columns, status and confirmation are untouched.
  UPDATE public.profiles AS profile_row
     SET confirmed_preferences = v_new_traits,
         merged_persona_version = v_new_version,
         version = profile_row.version + 1,
         updated_at = pg_catalog.clock_timestamp()
   WHERE profile_row.id = v_profile.id AND profile_row.user_id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Canonical owner profile unavailable' USING ERRCODE='40001';
  END IF;
  RETURN QUERY SELECT 'confirmed'::text, v_new_version, v_new_confirmed_at, v_new_traits;
END;
$core$;
