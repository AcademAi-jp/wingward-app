-- Reserve exactly one new third-interview session for the registered Sora
-- account during a short, owner-issued sora-ren rehearsal subwindow. Existing
-- active sessions are neither selected nor updated by this path.

CREATE TABLE public.sora_recording_interview_admissions (
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  rehearsal_expires_at timestamptz NOT NULL,
  admission_issued_at timestamptz NOT NULL,
  admission_expires_at timestamptz NOT NULL,
  session_id uuid NOT NULL UNIQUE REFERENCES public.speed_dating_sessions(id) ON DELETE CASCADE,
  persona_id uuid NOT NULL REFERENCES public.personas(id) ON DELETE CASCADE,
  reserved_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  bootstrap_issued_at timestamptz,
  completed_at timestamptz,
  PRIMARY KEY (user_id, rehearsal_expires_at),
  CHECK (admission_expires_at > admission_issued_at),
  CHECK (admission_expires_at <= rehearsal_expires_at)
);

ALTER TABLE public.sora_recording_interview_admissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sora_recording_interview_admissions FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.reserve_sora_recording_interview(
  p_user_id uuid,
  p_persona_id uuid,
  p_rehearsal_expires_at timestamptz,
  p_admission_issued_at timestamptz,
  p_admission_expires_at timestamptz
)
RETURNS TABLE (
  session_id uuid,
  persona_id uuid,
  outcome text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sora_id constant uuid := 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f';
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_onboarding_status text;
  v_persona_count integer;
  v_persona_type_count integer;
  v_completed_count integer;
  v_completed_persona_count integer;
  v_target_completed boolean;
  v_existing public.sora_recording_interview_admissions%ROWTYPE;
  v_new_session_id uuid;
BEGIN
  IF p_user_id IS DISTINCT FROM v_sora_id
     OR p_persona_id IS NULL
     OR p_rehearsal_expires_at IS NULL
     OR p_admission_issued_at IS NULL
     OR p_admission_expires_at IS NULL
     OR p_rehearsal_expires_at <= v_now
     OR p_rehearsal_expires_at > v_now + pg_catalog.interval '2 hours 5 minutes'
     OR p_admission_issued_at > v_now
     OR p_admission_expires_at <= v_now
     OR p_admission_expires_at <= p_admission_issued_at
     OR p_admission_expires_at - p_admission_issued_at > pg_catalog.interval '30 minutes'
     OR p_admission_expires_at > p_rehearsal_expires_at THEN
    RETURN QUERY SELECT NULL::uuid, p_persona_id, 'not_eligible'::text;
    RETURN;
  END IF;

  -- Serialize the count checks, reservation, and new session creation against
  -- completion RPCs, which take the same owner row lock.
  SELECT profile_row.onboarding_status
    INTO v_onboarding_status
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = p_user_id
   FOR UPDATE;
  IF NOT FOUND OR v_onboarding_status IS DISTINCT FROM 'quiz_completed' THEN
    RETURN QUERY SELECT NULL::uuid, p_persona_id, 'not_eligible'::text;
    RETURN;
  END IF;

  -- A retry of the same start request returns the already-created session.
  -- A different target or any consumed/expired reservation cannot be retried.
  SELECT admission_row.*
    INTO v_existing
    FROM public.sora_recording_interview_admissions AS admission_row
   WHERE admission_row.user_id = p_user_id
     AND admission_row.rehearsal_expires_at = p_rehearsal_expires_at
   FOR UPDATE;
  IF FOUND THEN
    IF v_existing.persona_id = p_persona_id
       AND v_existing.admission_issued_at = p_admission_issued_at
       AND v_existing.admission_expires_at = p_admission_expires_at
       AND v_now < v_existing.admission_expires_at
       AND v_existing.completed_at IS NULL
       AND EXISTS (
         SELECT 1
           FROM public.speed_dating_sessions AS session_row
          WHERE session_row.id = v_existing.session_id
            AND session_row.user_id = p_user_id
            AND session_row.persona_id = p_persona_id
            AND session_row.status = 'active'
       ) THEN
      RETURN QUERY SELECT v_existing.session_id, v_existing.persona_id, 'already_reserved'::text;
    ELSE
      RETURN QUERY SELECT NULL::uuid, p_persona_id, 'conflict'::text;
    END IF;
    RETURN;
  END IF;

  SELECT pg_catalog.count(*)::integer,
         pg_catalog.count(DISTINCT persona_row.persona_type)::integer
    INTO v_persona_count, v_persona_type_count
    FROM public.personas AS persona_row
   WHERE persona_row.user_id = p_user_id
     AND persona_row.persona_type IN ('virtual_similar', 'virtual_complementary', 'virtual_discovery');
  IF v_persona_count <> 3 OR v_persona_type_count <> 3 OR NOT EXISTS (
    SELECT 1
      FROM public.personas AS persona_row
     WHERE persona_row.id = p_persona_id
       AND persona_row.user_id = p_user_id
       AND persona_row.persona_type IN ('virtual_similar', 'virtual_complementary', 'virtual_discovery')
  ) THEN
    RETURN QUERY SELECT NULL::uuid, p_persona_id, 'not_eligible'::text;
    RETURN;
  END IF;

  SELECT pg_catalog.count(*)::integer,
         pg_catalog.count(DISTINCT session_row.persona_id)::integer
    INTO v_completed_count, v_completed_persona_count
    FROM public.speed_dating_sessions AS session_row
    JOIN public.personas AS persona_row
      ON persona_row.id = session_row.persona_id
     AND persona_row.user_id = session_row.user_id
   WHERE session_row.user_id = p_user_id
     AND session_row.status = 'completed'
     AND persona_row.persona_type IN ('virtual_similar', 'virtual_complementary', 'virtual_discovery');
  IF v_completed_count <> 2 OR v_completed_persona_count <> 2 THEN
    RETURN QUERY SELECT NULL::uuid, p_persona_id, 'not_eligible'::text;
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
      FROM public.speed_dating_sessions AS session_row
     WHERE session_row.user_id = p_user_id
       AND session_row.persona_id = p_persona_id
       AND session_row.status = 'completed'
  )
    INTO v_target_completed;
  IF v_target_completed THEN
    RETURN QUERY SELECT NULL::uuid, p_persona_id, 'not_eligible'::text;
    RETURN;
  END IF;

  -- The pre-existing incomplete sessions are left untouched. This transaction
  -- creates one separate session for the still-missing persona and binds only
  -- that new session ID to the one-per-window admission row.
  INSERT INTO public.speed_dating_sessions (user_id, persona_id)
  VALUES (p_user_id, p_persona_id)
  RETURNING id INTO v_new_session_id;

  INSERT INTO public.sora_recording_interview_admissions (
    user_id,
    rehearsal_expires_at,
    admission_issued_at,
    admission_expires_at,
    session_id,
    persona_id
  ) VALUES (
    p_user_id,
    p_rehearsal_expires_at,
    p_admission_issued_at,
    p_admission_expires_at,
    v_new_session_id,
    p_persona_id
  );

  RETURN QUERY SELECT v_new_session_id, p_persona_id, 'reserved'::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.issue_sora_recording_interview_token(
  p_user_id uuid,
  p_session_id uuid,
  p_rehearsal_expires_at timestamptz,
  p_admission_issued_at timestamptz,
  p_admission_expires_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_updated integer := 0;
BEGIN
  IF p_user_id IS DISTINCT FROM 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'::uuid
     OR p_session_id IS NULL
     OR p_rehearsal_expires_at IS NULL
     OR p_admission_issued_at IS NULL
     OR p_admission_expires_at IS NULL
     OR v_now >= p_rehearsal_expires_at
     OR v_now >= p_admission_expires_at
     OR p_rehearsal_expires_at - v_now < pg_catalog.interval '6 minutes'
     OR p_admission_expires_at - v_now < pg_catalog.interval '6 minutes' THEN
    RETURN false;
  END IF;

  UPDATE public.sora_recording_interview_admissions AS admission_row
     SET bootstrap_issued_at = v_now
   WHERE admission_row.user_id = p_user_id
     AND admission_row.session_id = p_session_id
     AND admission_row.rehearsal_expires_at = p_rehearsal_expires_at
     AND admission_row.admission_issued_at = p_admission_issued_at
     AND admission_row.admission_expires_at = p_admission_expires_at
     AND admission_row.bootstrap_issued_at IS NULL
     AND admission_row.completed_at IS NULL
     AND v_now < admission_row.rehearsal_expires_at
     AND v_now < admission_row.admission_expires_at
     AND EXISTS (
       SELECT 1
         FROM public.speed_dating_sessions AS session_row
        WHERE session_row.id = admission_row.session_id
          AND session_row.user_id = p_user_id
          AND session_row.persona_id = admission_row.persona_id
          AND session_row.status = 'active'
     );
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_sora_recording_interview(
  p_session_id uuid,
  p_user_id uuid,
  p_rehearsal_expires_at timestamptz,
  p_admission_issued_at timestamptz,
  p_admission_expires_at timestamptz,
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
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_owner_id uuid;
  v_admission public.sora_recording_interview_admissions%ROWTYPE;
  v_completion record;
  v_session_status text;
  v_entry jsonb;
  v_has_user boolean := false;
  v_has_ai boolean := false;
BEGIN
  IF p_user_id IS DISTINCT FROM 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'::uuid
     OR p_session_id IS NULL
     OR p_rehearsal_expires_at IS NULL
     OR p_admission_issued_at IS NULL
     OR p_admission_expires_at IS NULL
     OR v_now >= p_rehearsal_expires_at
     OR v_now >= p_admission_expires_at THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_state'::text;
    RETURN;
  END IF;

  -- The native voice path must prove that both speakers produced a usable
  -- transcript before it can certify this interview as complete. Validate at
  -- this privileged boundary even though the HTTP route applies the same rule.
  IF p_transcript IS NULL OR pg_catalog.jsonb_typeof(p_transcript) IS DISTINCT FROM 'array' THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_input'::text;
    RETURN;
  END IF;
  IF pg_catalog.jsonb_array_length(p_transcript) < 2
     OR pg_catalog.jsonb_array_length(p_transcript) > 200 THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_input'::text;
    RETURN;
  END IF;

  FOR v_entry IN SELECT value FROM pg_catalog.jsonb_array_elements(p_transcript) AS item(value)
  LOOP
    IF pg_catalog.jsonb_typeof(v_entry) IS DISTINCT FROM 'object'
    THEN
      RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_input'::text;
      RETURN;
    END IF;
    IF (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(v_entry)) <> 2
       OR pg_catalog.jsonb_typeof(v_entry -> 'source') IS DISTINCT FROM 'string'
       OR pg_catalog.jsonb_typeof(v_entry -> 'message') IS DISTINCT FROM 'string'
       OR COALESCE((v_entry ->> 'source') IN ('user', 'ai'), false) IS NOT TRUE
       OR COALESCE(pg_catalog.btrim(v_entry ->> 'message') = '', true) IS NOT FALSE
       OR pg_catalog.char_length(v_entry ->> 'message') > 2000 THEN
      RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_input'::text;
      RETURN;
    END IF;
    v_has_user := v_has_user OR v_entry ->> 'source' = 'user';
    v_has_ai := v_has_ai OR v_entry ->> 'source' = 'ai';
  END LOOP;
  IF NOT v_has_user OR NOT v_has_ai THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_input'::text;
    RETURN;
  END IF;

  SELECT profile_row.id
    INTO v_owner_id
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = p_user_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'not_found'::text;
    RETURN;
  END IF;

  SELECT admission_row.*
    INTO v_admission
    FROM public.sora_recording_interview_admissions AS admission_row
   WHERE admission_row.user_id = p_user_id
     AND admission_row.session_id = p_session_id
     AND admission_row.rehearsal_expires_at = p_rehearsal_expires_at
     AND admission_row.admission_issued_at = p_admission_issued_at
     AND admission_row.admission_expires_at = p_admission_expires_at
   FOR UPDATE;
  -- A completed replay is allowed only for the same reserved session that
  -- actually received its one bootstrap claim.
  IF NOT FOUND OR v_admission.bootstrap_issued_at IS NULL THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_state'::text;
    RETURN;
  END IF;

  SELECT session_row.status
    INTO v_session_status
    FROM public.speed_dating_sessions AS session_row
   WHERE session_row.id = p_session_id
     AND session_row.user_id = p_user_id
     AND session_row.persona_id = v_admission.persona_id
   FOR UPDATE;
  IF NOT FOUND OR (v_admission.completed_at IS NOT NULL AND v_session_status IS DISTINCT FROM 'completed') THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_state'::text;
    RETURN;
  END IF;

  SELECT completion_row.*
    INTO v_completion
    FROM public.complete_speed_dating_session(p_session_id, p_user_id, p_transcript) AS completion_row;
  IF v_admission.completed_at IS NOT NULL AND v_completion.outcome NOT IN ('already_completed', 'conflict') THEN
    RETURN QUERY SELECT p_session_id, NULL::text, NULL::integer, false, 'invalid_state'::text;
    RETURN;
  END IF;
  IF v_admission.completed_at IS NULL AND v_completion.outcome IN ('stored', 'already_completed') THEN
    UPDATE public.sora_recording_interview_admissions AS admission_row
       SET completed_at = COALESCE(admission_row.completed_at, v_now)
     WHERE admission_row.user_id = p_user_id
       AND admission_row.session_id = p_session_id
       AND admission_row.rehearsal_expires_at = p_rehearsal_expires_at;
  END IF;

  RETURN QUERY SELECT
    v_completion.session_id,
    v_completion.status,
    v_completion.message_count,
    v_completion.all_sessions_completed,
    v_completion.outcome;
END;
$$;

REVOKE ALL ON FUNCTION public.reserve_sora_recording_interview(uuid, uuid, timestamptz, timestamptz, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.issue_sora_recording_interview_token(uuid, uuid, timestamptz, timestamptz, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.complete_sora_recording_interview(uuid, uuid, timestamptz, timestamptz, timestamptz, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reserve_sora_recording_interview(uuid, uuid, timestamptz, timestamptz, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.issue_sora_recording_interview_token(uuid, uuid, timestamptz, timestamptz, timestamptz)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_sora_recording_interview(uuid, uuid, timestamptz, timestamptz, timestamptz, jsonb)
  TO service_role;

COMMENT ON TABLE public.sora_recording_interview_admissions IS
  'Internal one-reservation record for the fixed Sora third-interview recording rehearsal. Client roles have no access.';
COMMENT ON FUNCTION public.reserve_sora_recording_interview(uuid, uuid, timestamptz, timestamptz, timestamptz) IS
  'Service-role-only atomic reservation. Requires the fixed Sora account, quiz_completed stage, two distinct completed virtual personas, and the one missing virtual persona; creates one new session without touching older incomplete sessions.';
COMMENT ON FUNCTION public.issue_sora_recording_interview_token(uuid, uuid, timestamptz, timestamptz, timestamptz) IS
  'Service-role-only atomic one-time OpenAI Realtime token issuance claim for the single reserved Sora session.';
COMMENT ON FUNCTION public.complete_sora_recording_interview(uuid, uuid, timestamptz, timestamptz, timestamptz, jsonb) IS
  'Service-role-only completion wrapper bound to the single Sora reservation and issued token; delegates transcript atomicity to complete_speed_dating_session.';
