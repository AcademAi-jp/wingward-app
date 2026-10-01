-- One owner-operated regeneration of Sora's draft from exactly three distinct
-- completed interviews. The old row is copied before the new draft is saved.
-- No client role can read the snapshot or call the service-only RPCs.

CREATE TABLE public.sora_profile_revision_runs (
  user_id uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  rehearsal_expires_at timestamptz NOT NULL,
  source_profile_id uuid NOT NULL REFERENCES public.profiles(id),
  source_version integer NOT NULL CHECK (source_version > 0),
  session_ids uuid[] NOT NULL CHECK (COALESCE(pg_catalog.array_length(session_ids, 1), 0) = 3),
  source_snapshot jsonb NOT NULL CHECK (pg_catalog.pg_column_size(source_snapshot) <= 100000),
  claimed_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  completed_at timestamptz,
  target_version integer,
  CHECK ((completed_at IS NULL) = (target_version IS NULL)),
  CHECK (target_version IS NULL OR target_version = source_version + 1)
);

ALTER TABLE public.sora_profile_revision_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sora_profile_revision_runs FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.read_sora_three_interview_profile_revision_state(
  p_user_id uuid,
  p_rehearsal_expires_at timestamptz
)
RETURNS TABLE (outcome text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sora_id constant uuid := 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f';
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_run public.sora_profile_revision_runs%ROWTYPE;
  v_onboarding_status text;
  v_profile public.profiles%ROWTYPE;
  v_session_count integer;
  v_distinct_personas integer;
  v_distinct_types integer;
  v_valid_personas integer;
  v_completed_timestamps integer;
BEGIN
  IF p_user_id IS DISTINCT FROM v_sora_id THEN
    RETURN QUERY SELECT 'unavailable'::text;
    RETURN;
  END IF;

  SELECT run_row.* INTO v_run
    FROM public.sora_profile_revision_runs AS run_row
   WHERE run_row.user_id = p_user_id;
  IF FOUND THEN
    RETURN QUERY SELECT CASE WHEN v_run.completed_at IS NULL THEN 'claimed' ELSE 'completed' END;
    RETURN;
  END IF;

  IF p_rehearsal_expires_at IS NULL
     OR p_rehearsal_expires_at <= v_now
     OR p_rehearsal_expires_at > v_now + INTERVAL '2 hours 5 minutes' THEN
    RETURN QUERY SELECT 'unavailable'::text;
    RETURN;
  END IF;

  SELECT owner_row.onboarding_status INTO v_onboarding_status
    FROM public.user_profiles AS owner_row
   WHERE owner_row.id = p_user_id;
  IF NOT FOUND OR v_onboarding_status IS DISTINCT FROM 'speed_dating_completed' THEN
    RETURN QUERY SELECT 'unavailable'::text;
    RETURN;
  END IF;

  SELECT profile_row.* INTO v_profile
    FROM public.profiles AS profile_row
   WHERE profile_row.user_id = p_user_id;
  IF NOT FOUND OR v_profile.status IS DISTINCT FROM 'draft' OR v_profile.version < 1
     OR pg_catalog.pg_column_size(pg_catalog.to_jsonb(v_profile)) > 100000 THEN
    RETURN QUERY SELECT 'unavailable'::text;
    RETURN;
  END IF;

  SELECT pg_catalog.count(session_row.id)::integer,
         pg_catalog.count(DISTINCT session_row.persona_id)::integer,
         pg_catalog.count(DISTINCT persona_row.persona_type)::integer,
         pg_catalog.count(session_row.completed_at)::integer,
         pg_catalog.count(*) FILTER (
           WHERE persona_row.id IS NOT NULL
             AND persona_row.user_id = session_row.user_id
             AND persona_row.persona_type IN ('virtual_similar', 'virtual_complementary', 'virtual_discovery')
         )::integer
    INTO v_session_count, v_distinct_personas, v_distinct_types, v_completed_timestamps, v_valid_personas
    FROM public.speed_dating_sessions AS session_row
    LEFT JOIN public.personas AS persona_row ON persona_row.id = session_row.persona_id
   WHERE session_row.user_id = p_user_id AND session_row.status = 'completed';
  IF v_session_count IS DISTINCT FROM 3 OR v_distinct_personas IS DISTINCT FROM 3
     OR v_distinct_types IS DISTINCT FROM 3 OR v_completed_timestamps IS DISTINCT FROM 3
     OR v_valid_personas IS DISTINCT FROM 3 THEN
    RETURN QUERY SELECT 'unavailable'::text;
    RETURN;
  END IF;

  RETURN QUERY SELECT 'available'::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_sora_three_interview_profile_revision(
  p_user_id uuid,
  p_rehearsal_expires_at timestamptz
)
RETURNS TABLE (
  outcome text,
  source_profile_id uuid,
  source_version integer,
  session_ids uuid[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sora_id constant uuid := 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f';
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_onboarding_status text;
  v_profile public.profiles%ROWTYPE;
  v_existing public.sora_profile_revision_runs%ROWTYPE;
  v_session_count integer;
  v_distinct_personas integer;
  v_distinct_types integer;
  v_valid_personas integer;
  v_completed_timestamps integer;
  v_session_ids uuid[];
BEGIN
  IF p_user_id IS DISTINCT FROM v_sora_id
     OR p_rehearsal_expires_at IS NULL
     OR p_rehearsal_expires_at <= v_now
     OR p_rehearsal_expires_at > v_now + INTERVAL '2 hours 5 minutes' THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::uuid, NULL::integer, NULL::uuid[];
    RETURN;
  END IF;

  SELECT profile_row.onboarding_status INTO v_onboarding_status
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = p_user_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::uuid, NULL::integer, NULL::uuid[];
    RETURN;
  END IF;

  SELECT run_row.* INTO v_existing
    FROM public.sora_profile_revision_runs AS run_row
   WHERE run_row.user_id = p_user_id
   FOR UPDATE;
  IF FOUND THEN
    RETURN QUERY SELECT
      CASE WHEN v_existing.completed_at IS NULL THEN 'already_claimed' ELSE 'already_completed' END,
      v_existing.source_profile_id, v_existing.source_version, v_existing.session_ids;
    RETURN;
  END IF;
  IF v_onboarding_status IS DISTINCT FROM 'speed_dating_completed' THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::uuid, NULL::integer, NULL::uuid[];
    RETURN;
  END IF;

  SELECT profile_row.* INTO v_profile
    FROM public.profiles AS profile_row
   WHERE profile_row.user_id = p_user_id
   FOR UPDATE;
  IF NOT FOUND OR v_profile.status IS DISTINCT FROM 'draft' OR v_profile.version < 1
     OR pg_catalog.pg_column_size(pg_catalog.to_jsonb(v_profile)) > 100000 THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::uuid, NULL::integer, NULL::uuid[];
    RETURN;
  END IF;

  -- Locks may have waited beyond the owner's rehearsal expiry. Re-evaluate the
  -- wall clock at the final write boundary, not only before acquiring locks.
  v_now := pg_catalog.clock_timestamp();
  IF p_rehearsal_expires_at <= v_now
     OR p_rehearsal_expires_at > v_now + INTERVAL '2 hours 5 minutes' THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::uuid, NULL::integer, NULL::uuid[];
    RETURN;
  END IF;

  SELECT pg_catalog.count(session_row.id)::integer,
         pg_catalog.count(DISTINCT session_row.persona_id)::integer,
         pg_catalog.count(DISTINCT persona_row.persona_type)::integer,
         pg_catalog.count(session_row.completed_at)::integer,
         pg_catalog.count(*) FILTER (
           WHERE persona_row.id IS NOT NULL
             AND persona_row.user_id = session_row.user_id
             AND persona_row.persona_type IN ('virtual_similar', 'virtual_complementary', 'virtual_discovery')
         )::integer,
         pg_catalog.array_agg(session_row.id ORDER BY session_row.completed_at DESC, session_row.id DESC)
         FILTER (WHERE persona_row.id IS NOT NULL
                   AND persona_row.user_id = session_row.user_id
                   AND persona_row.persona_type IN ('virtual_similar', 'virtual_complementary', 'virtual_discovery'))
    INTO v_session_count, v_distinct_personas, v_distinct_types, v_completed_timestamps, v_valid_personas, v_session_ids
    FROM public.speed_dating_sessions AS session_row
    LEFT JOIN public.personas AS persona_row ON persona_row.id = session_row.persona_id
   WHERE session_row.user_id = p_user_id AND session_row.status = 'completed';
  IF v_session_count IS DISTINCT FROM 3 OR v_distinct_personas IS DISTINCT FROM 3
     OR v_distinct_types IS DISTINCT FROM 3 OR v_completed_timestamps IS DISTINCT FROM 3
     OR v_valid_personas IS DISTINCT FROM 3
     OR pg_catalog.cardinality(v_session_ids) IS DISTINCT FROM 3 THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::uuid, NULL::integer, NULL::uuid[];
    RETURN;
  END IF;

  v_now := pg_catalog.clock_timestamp();
  IF p_rehearsal_expires_at <= v_now
     OR p_rehearsal_expires_at > v_now + INTERVAL '2 hours 5 minutes' THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::uuid, NULL::integer, NULL::uuid[];
    RETURN;
  END IF;

  INSERT INTO public.sora_profile_revision_runs (
    user_id, rehearsal_expires_at, source_profile_id, source_version,
    session_ids, source_snapshot, claimed_at
  ) VALUES (
    p_user_id, p_rehearsal_expires_at, v_profile.id, v_profile.version,
    v_session_ids, pg_catalog.to_jsonb(v_profile), v_now
  );
  RETURN QUERY SELECT 'claimed'::text, v_profile.id, v_profile.version, v_session_ids;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_sora_three_interview_profile_revision(
  p_user_id uuid,
  p_rehearsal_expires_at timestamptz,
  p_source_profile_id uuid,
  p_source_version integer,
  p_candidate jsonb
)
RETURNS TABLE (outcome text, target_version integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sora_id constant uuid := 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f';
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_onboarding_status text;
  v_profile public.profiles%ROWTYPE;
  v_run public.sora_profile_revision_runs%ROWTYPE;
  v_session_count integer;
  v_distinct_personas integer;
  v_distinct_types integer;
  v_valid_personas integer;
  v_completed_timestamps integer;
  v_session_ids uuid[];
BEGIN
  IF p_user_id IS DISTINCT FROM v_sora_id
     OR p_rehearsal_expires_at IS NULL
     OR p_rehearsal_expires_at <= v_now
     OR p_rehearsal_expires_at > v_now + INTERVAL '2 hours 5 minutes'
     OR p_source_profile_id IS NULL
     OR p_source_version IS NULL
     OR p_candidate IS NULL
     OR pg_catalog.jsonb_typeof(p_candidate) IS DISTINCT FROM 'object'
     OR pg_catalog.pg_column_size(p_candidate) > 60000
     OR pg_catalog.jsonb_typeof(p_candidate->'basic_info') IS DISTINCT FROM 'object'
     OR pg_catalog.jsonb_typeof(p_candidate->'personality_tags') IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_typeof(p_candidate->'personality_analysis') IS DISTINCT FROM 'object'
     OR pg_catalog.jsonb_typeof(p_candidate->'interaction_style') IS DISTINCT FROM 'object'
     OR pg_catalog.jsonb_typeof(p_candidate->'interests') IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_typeof(p_candidate->'values') IS DISTINCT FROM 'object'
     OR pg_catalog.jsonb_typeof(p_candidate->'romance_style') IS DISTINCT FROM 'object'
     OR pg_catalog.jsonb_typeof(p_candidate->'communication_style') IS DISTINCT FROM 'object'
     OR pg_catalog.jsonb_typeof(p_candidate->'lifestyle') IS DISTINCT FROM 'object' THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::integer;
    RETURN;
  END IF;

  SELECT profile_row.onboarding_status INTO v_onboarding_status
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = p_user_id
   FOR UPDATE;
  SELECT profile_row.* INTO v_profile
    FROM public.profiles AS profile_row
   WHERE profile_row.user_id = p_user_id
   FOR UPDATE;
  SELECT run_row.* INTO v_run
    FROM public.sora_profile_revision_runs AS run_row
   WHERE run_row.user_id = p_user_id
   FOR UPDATE;
  IF NOT FOUND OR v_run.rehearsal_expires_at IS DISTINCT FROM p_rehearsal_expires_at
     OR v_run.source_profile_id IS DISTINCT FROM p_source_profile_id
     OR v_run.source_version IS DISTINCT FROM p_source_version THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::integer;
    RETURN;
  END IF;
  v_now := pg_catalog.clock_timestamp();
  IF p_rehearsal_expires_at <= v_now
     OR p_rehearsal_expires_at > v_now + INTERVAL '2 hours 5 minutes' THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::integer;
    RETURN;
  END IF;
  IF v_run.completed_at IS NOT NULL THEN
    RETURN QUERY SELECT 'already_completed'::text, v_run.target_version;
    RETURN;
  END IF;
  IF v_onboarding_status IS DISTINCT FROM 'speed_dating_completed'
     OR v_profile.id IS DISTINCT FROM p_source_profile_id
     OR v_profile.version IS DISTINCT FROM p_source_version
     OR v_profile.status IS DISTINCT FROM 'draft'
     OR pg_catalog.to_jsonb(v_profile) IS DISTINCT FROM v_run.source_snapshot
     OR v_run.claimed_at + INTERVAL '15 minutes' <= v_now THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::integer;
    RETURN;
  END IF;

  SELECT pg_catalog.count(session_row.id)::integer,
         pg_catalog.count(DISTINCT session_row.persona_id)::integer,
         pg_catalog.count(DISTINCT persona_row.persona_type)::integer,
         pg_catalog.count(session_row.completed_at)::integer,
         pg_catalog.count(*) FILTER (
           WHERE persona_row.id IS NOT NULL
             AND persona_row.user_id = session_row.user_id
             AND persona_row.persona_type IN ('virtual_similar', 'virtual_complementary', 'virtual_discovery')
         )::integer,
         pg_catalog.array_agg(session_row.id ORDER BY session_row.completed_at DESC, session_row.id DESC)
    INTO v_session_count, v_distinct_personas, v_distinct_types, v_completed_timestamps, v_valid_personas, v_session_ids
    FROM public.speed_dating_sessions AS session_row
    LEFT JOIN public.personas AS persona_row ON persona_row.id = session_row.persona_id
   WHERE session_row.user_id = p_user_id AND session_row.status = 'completed';
  IF v_session_count IS DISTINCT FROM 3 OR v_distinct_personas IS DISTINCT FROM 3
     OR v_distinct_types IS DISTINCT FROM 3 OR v_completed_timestamps IS DISTINCT FROM 3
     OR v_valid_personas IS DISTINCT FROM 3
     OR v_session_ids IS DISTINCT FROM v_run.session_ids THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::integer;
    RETURN;
  END IF;

  v_now := pg_catalog.clock_timestamp();
  IF p_rehearsal_expires_at <= v_now
     OR p_rehearsal_expires_at > v_now + INTERVAL '2 hours 5 minutes'
     OR v_run.claimed_at + INTERVAL '15 minutes' <= v_now THEN
    RETURN QUERY SELECT 'not_eligible'::text, NULL::integer;
    RETURN;
  END IF;

  UPDATE public.profiles AS profile_row
     SET basic_info = p_candidate->'basic_info',
         personality_tags = p_candidate->'personality_tags',
         personality_analysis = p_candidate->'personality_analysis',
         interaction_style = p_candidate->'interaction_style',
         interests = p_candidate->'interests',
         values = p_candidate->'values',
         romance_style = p_candidate->'romance_style',
         communication_style = p_candidate->'communication_style',
         lifestyle = p_candidate->'lifestyle',
         status = 'draft', confirmed_at = NULL,
         version = v_run.source_version + 1,
         updated_at = v_now
   WHERE profile_row.id = p_source_profile_id
     AND profile_row.user_id = p_user_id
     AND profile_row.version = p_source_version
     AND profile_row.status = 'draft';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sora profile changed while saving the new draft';
  END IF;

  UPDATE public.user_profiles AS profile_row
     SET onboarding_status = 'profile_generated', updated_at = v_now
   WHERE profile_row.id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sora owner state changed while saving the new draft';
  END IF;
  UPDATE public.sora_profile_revision_runs AS run_row
     SET completed_at = v_now, target_version = v_run.source_version + 1
   WHERE run_row.user_id = p_user_id AND run_row.completed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Sora revision claim changed while saving the new draft';
  END IF;
  RETURN QUERY SELECT 'saved'::text, v_run.source_version + 1;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_sora_three_interview_profile_revision(uuid,timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_sora_three_interview_profile_revision(uuid,timestamptz)
  TO service_role;
REVOKE ALL ON FUNCTION public.read_sora_three_interview_profile_revision_state(uuid,timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.read_sora_three_interview_profile_revision_state(uuid,timestamptz)
  TO service_role;
REVOKE ALL ON FUNCTION public.complete_sora_three_interview_profile_revision(uuid,timestamptz,uuid,integer,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_sora_three_interview_profile_revision(uuid,timestamptz,uuid,integer,jsonb)
  TO service_role;
