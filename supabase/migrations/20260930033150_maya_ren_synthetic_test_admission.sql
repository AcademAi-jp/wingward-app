-- PROPOSED LOCAL-ONLY synthetic test admission. Not identity verification.
-- No row is armed by this migration. Cloud deployment/permit insertion needs separate owner approval.
-- Normal public RPCs, quota limits and all user_profiles identity fields remain unchanged.
CREATE TABLE wingward_private.synthetic_recording_admissions (
 admission_id uuid PRIMARY KEY,
 singleton boolean NOT NULL DEFAULT true UNIQUE CHECK(singleton),
 user_a_id uuid NOT NULL DEFAULT '9d836fee-7b93-41ce-b577-34a63006aaea' CHECK(user_a_id='9d836fee-7b93-41ce-b577-34a63006aaea'),
 user_b_id uuid NOT NULL DEFAULT 'a88a89e2-5421-5ce9-a33b-76d512898c37' CHECK(user_b_id='a88a89e2-5421-5ce9-a33b-76d512898c37'),
 issued_at timestamptz NOT NULL,
 expires_at timestamptz NOT NULL,
 match_id uuid UNIQUE REFERENCES public.matches(id),
 room_id uuid UNIQUE REFERENCES public.direct_chat_rooms(id),
 meetup_id uuid UNIQUE REFERENCES public.meetups(id),
 CHECK(pg_catalog.isfinite(issued_at) AND pg_catalog.isfinite(expires_at)
       AND expires_at>issued_at AND expires_at<=issued_at+interval '2 hours'),
 CHECK((match_id IS NULL)=(room_id IS NULL)),
 CHECK(meetup_id IS NULL OR room_id IS NOT NULL)
);
ALTER TABLE wingward_private.synthetic_recording_admissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE wingward_private.synthetic_recording_admissions FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON TABLE wingward_private.synthetic_recording_admissions IS 'Explicit synthetic test admission only; never implies genuine identity verification. Initially empty; at most one max-two-hour Maya/Ren permit and one bound context.';

CREATE FUNCTION wingward_private.resolve_synthetic_recording_admission(
 p_admission_id uuid,p_user_id uuid,p_room_id uuid,p_meetup_id uuid,
 p_issued_at timestamptz,p_expires_at timestamptz,p_bind boolean
)
RETURNS TABLE(outcome text,admission_id uuid,user_a_id uuid,user_b_id uuid,match_id uuid,room_id uuid,meetup_id uuid,issued_at timestamptz,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $resolve$
DECLARE a wingward_private.synthetic_recording_admissions; m public.matches; r public.direct_chat_rooms;
 v_room_id uuid; v_meetup_id uuid; v_match_id uuid; s public.chat_meetup_sessions;
BEGIN
 SELECT * INTO a FROM wingward_private.synthetic_recording_admissions WHERE synthetic_recording_admissions.admission_id=p_admission_id;
 IF NOT FOUND OR p_user_id IS NULL OR p_user_id NOT IN (a.user_a_id,a.user_b_id)
   OR p_issued_at IS DISTINCT FROM a.issued_at OR p_expires_at IS DISTINCT FROM a.expires_at
   OR pg_catalog.clock_timestamp()<a.issued_at OR pg_catalog.clock_timestamp()>=a.expires_at
   OR (p_room_id IS NULL AND p_meetup_id IS NULL) THEN
  RETURN QUERY SELECT 'not_found'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid,NULL::timestamptz,NULL::timestamptz; RETURN;
 END IF;
 v_room_id:=p_room_id;
 IF p_meetup_id IS NOT NULL THEN
  SELECT mt.match_id INTO v_match_id FROM public.meetups mt WHERE mt.id=p_meetup_id;
  SELECT room.id INTO v_room_id FROM public.direct_chat_rooms room WHERE room.match_id=v_match_id;
  IF p_room_id IS NOT NULL AND p_room_id IS DISTINCT FROM v_room_id THEN v_room_id:=NULL; END IF;
 END IF;
 SELECT * INTO r FROM public.direct_chat_rooms WHERE id=v_room_id;
 SELECT * INTO m FROM public.matches WHERE id=r.match_id;
 IF m.id IS NULL OR m.user_a_id IS DISTINCT FROM a.user_a_id OR m.user_b_id IS DISTINCT FROM a.user_b_id
   OR m.status IS DISTINCT FROM 'direct_chat_active' OR r.status IS DISTINCT FROM 'active'
   OR EXISTS(SELECT 1 FROM public.blocks WHERE (blocker_id=a.user_a_id AND blocked_id=a.user_b_id) OR (blocker_id=a.user_b_id AND blocked_id=a.user_a_id))
   OR (SELECT count(*) FROM public.user_profiles p WHERE p.id IN(a.user_a_id,a.user_b_id)
       AND p.identity_verification_status='none' AND p.identity_verified_at IS NULL AND p.identity_subject_hash IS NULL)<>2
   OR NOT COALESCE((SELECT wingward_private.is_mutually_eligible(pa,pb) FROM public.user_profiles pa CROSS JOIN public.user_profiles pb WHERE pa.id=a.user_a_id AND pb.id=a.user_b_id),false) THEN
  RETURN QUERY SELECT 'not_found'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid,NULL::timestamptz,NULL::timestamptz; RETURN;
 END IF;
 IF p_bind THEN
  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(a.user_a_id,a.user_b_id),false) THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
  SELECT * INTO m FROM public.matches WHERE id=m.id FOR UPDATE NOWAIT;
  SELECT * INTO r FROM public.direct_chat_rooms WHERE id=r.id FOR UPDATE NOWAIT;
  SELECT * INTO a FROM wingward_private.synthetic_recording_admissions WHERE synthetic_recording_admissions.admission_id=p_admission_id FOR UPDATE;
 END IF;
 SELECT mt.id INTO v_meetup_id FROM public.meetups mt WHERE mt.match_id=m.id ORDER BY mt.created_at DESC,mt.id DESC LIMIT 1;
 SELECT * INTO s FROM public.chat_meetup_sessions WHERE chat_meetup_sessions.room_id=r.id ORDER BY created_at DESC,chat_meetup_sessions.meetup_id DESC LIMIT 1;
 IF p_user_id IS NULL OR p_user_id NOT IN(a.user_a_id,a.user_b_id)
  OR p_issued_at IS DISTINCT FROM a.issued_at OR p_expires_at IS DISTINCT FROM a.expires_at
  OR pg_catalog.clock_timestamp()<a.issued_at
  OR m.user_a_id IS DISTINCT FROM a.user_a_id OR m.user_b_id IS DISTINCT FROM a.user_b_id
  OR m.status IS DISTINCT FROM 'direct_chat_active' OR r.status IS DISTINCT FROM 'active'
  OR EXISTS(SELECT 1 FROM public.blocks WHERE (blocker_id=a.user_a_id AND blocked_id=a.user_b_id) OR (blocker_id=a.user_b_id AND blocked_id=a.user_a_id))
  OR (SELECT count(*) FROM public.user_profiles p WHERE p.id IN(a.user_a_id,a.user_b_id) AND p.identity_verification_status='none' AND p.identity_verified_at IS NULL AND p.identity_subject_hash IS NULL)<>2
  OR (p_meetup_id IS NOT NULL AND p_meetup_id IS DISTINCT FROM v_meetup_id)
  OR (s.meetup_id IS NOT NULL AND s.meetup_id IS DISTINCT FROM v_meetup_id)
  OR (a.match_id IS NOT NULL AND a.match_id IS DISTINCT FROM m.id)
  OR (a.room_id IS NOT NULL AND a.room_id IS DISTINCT FROM r.id)
  OR (a.meetup_id IS NOT NULL AND a.meetup_id IS DISTINCT FROM v_meetup_id)
  OR (SELECT count(*) FROM public.meetups mt WHERE mt.match_id=m.id)>1
  OR (s.confirmed_starts_at IS NOT NULL AND (s.confirmed_ends_at-s.confirmed_starts_at<>interval '60 minutes' OR s.confirmed_starts_at<a.issued_at OR s.confirmed_ends_at>a.expires_at))
  OR EXISTS(SELECT 1 FROM pg_catalog.jsonb_array_elements(COALESCE(s.time_candidates,'[]'::jsonb)) c
       WHERE (c->>'ends_at')::timestamptz-(c->>'starts_at')::timestamptz<>interval '60 minutes'
         OR (c->>'starts_at')::timestamptz<a.issued_at OR (c->>'ends_at')::timestamptz>a.expires_at)
  OR pg_catalog.clock_timestamp()>=a.expires_at THEN
  RETURN QUERY SELECT 'not_found'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid,NULL::uuid,NULL::timestamptz,NULL::timestamptz; RETURN;
 END IF;
 IF p_bind THEN
  UPDATE wingward_private.synthetic_recording_admissions SET match_id=m.id,room_id=r.id,meetup_id=COALESCE(synthetic_recording_admissions.meetup_id,v_meetup_id) WHERE synthetic_recording_admissions.admission_id=a.admission_id;
 END IF;
 RETURN QUERY SELECT 'admitted'::text,a.admission_id,a.user_a_id,a.user_b_id,m.id,r.id,v_meetup_id,a.issued_at,a.expires_at;
EXCEPTION WHEN lock_not_available THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501';
END $resolve$;
REVOKE ALL ON FUNCTION wingward_private.resolve_synthetic_recording_admission(uuid,uuid,uuid,uuid,timestamptz,timestamptz,boolean) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.check_synthetic_recording_admission(p_admission_id uuid,p_user_id uuid,p_room_id uuid,p_meetup_id uuid,p_issued_at timestamptz,p_expires_at timestamptz)
RETURNS TABLE(outcome text,admission_id uuid,user_a_id uuid,user_b_id uuid,match_id uuid,room_id uuid,meetup_id uuid,issued_at timestamptz,expires_at timestamptz)
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT * FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,p_meetup_id,p_issued_at,p_expires_at,false)
$$;
REVOKE ALL ON FUNCTION public.check_synthetic_recording_admission(uuid,uuid,uuid,uuid,timestamptz,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.check_synthetic_recording_admission(uuid,uuid,uuid,uuid,timestamptz,timestamptz) TO service_role;

-- Fail migration on unexpected normal-RPC drift; these original bodies remain unchanged.
DO $$ BEGIN IF (SELECT md5(prosrc) FROM pg_catalog.pg_proc WHERE oid='public.claim_meetup_arrangement(uuid,uuid,boolean,text)'::regprocedure)<>'2a0f822aa585b1bd0f90dbb14f06d3e4' THEN RAISE EXCEPTION 'Original RPC source drift: claim_meetup_arrangement'; END IF; END $$;
CREATE FUNCTION wingward_private.demo_recording_core_claim_meetup_arrangement(p_synthetic_admitted boolean,
  p_meetup_id uuid,
  p_user_id uuid,
  p_is_retry boolean,
  p_operation_key text
)
RETURNS TABLE (
  meetup_id uuid,
  match_id uuid,
  outcome text,
  status text,
  attempt_number integer,
  billing_source text,
  transitioned boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $core$
DECLARE
  v_meetup public.meetups%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_claim public.meetup_arrangement_claims%ROWTYPE;
  v_entitled boolean := false;
  v_credit_consumed boolean := false;
  v_quota_used integer;
  v_period_start date;
  v_period_end date;
  v_timezone text;
  v_initial_meetup_match_id uuid;
  v_now timestamptz := pg_catalog.now();
  v_attempt integer;
  v_billing_source text;
  v_mutual_eligible boolean;
BEGIN
  IF p_meetup_id IS NULL OR p_user_id IS NULL OR p_is_retry IS NULL
     OR p_operation_key IS NULL
     OR pg_catalog.char_length(p_operation_key) < 1
     OR pg_catalog.char_length(p_operation_key) > 128
     OR p_operation_key !~ '^[\x21-\x7e]+$' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'invalid_input'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Resolve the relationship without locking it.  Every caller then takes
  -- the same match -> room -> meetup lock order before reading state.
  SELECT initial_meetup.match_id
    INTO v_initial_meetup_match_id
    FROM public.meetups AS initial_meetup
   WHERE initial_meetup.id = p_meetup_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Lock the relationship first and validate the caller against its fresh
  -- participant list.  This keeps an idempotency replay from disclosing a
  -- claim to an outsider, even when the operation key is already present.
  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_initial_meetup_match_id
   FOR UPDATE;
  IF NOT FOUND
     OR (p_user_id <> v_match.user_a_id AND p_user_id <> v_match.user_b_id) THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Arrangement is only available inside the same active direct-chat safety
  -- boundary as meetup intent.  The caller's participant id is server-owned.
  IF v_match.status IS DISTINCT FROM 'direct_chat_active' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;
  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- The meetup is the final lock in this order.  Revalidate both foreign-key
  -- relationships after taking it so a stale initial lookup cannot authorize
  -- state from a different match or room.
  SELECT locked_meetup.* INTO v_meetup
    FROM public.meetups AS locked_meetup
   WHERE locked_meetup.id = p_meetup_id
     AND locked_meetup.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND
     OR v_meetup.match_id IS DISTINCT FROM v_match.id
     OR v_room.match_id IS DISTINCT FROM v_meetup.match_id
     OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.blocks
     WHERE (blocker_id = v_match.user_a_id AND blocked_id = v_match.user_b_id)
        OR (blocker_id = v_match.user_b_id AND blocked_id = v_match.user_a_id)
  ) THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'blocked'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Lock and validate current profiles before identity reads, idempotency
  -- replay, quota/credit use, or the arrangement transition.
  v_mutual_eligible := wingward_private.lock_and_check_mutual_eligibility(
    v_match.user_a_id,
    v_match.user_b_id
  );
  IF NOT COALESCE(v_mutual_eligible, false) THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Both status and timestamp are required.  No development/test bypass is
  -- permitted on this server-owned transition.
  IF (
    SELECT count(*)
      FROM public.user_profiles
     WHERE id IN (v_match.user_a_id, v_match.user_b_id)
       AND age_verified_at IS NOT NULL
       AND (p_synthetic_admitted OR identity_verification_status = 'verified')
       AND (p_synthetic_admitted OR identity_verified_at IS NOT NULL)
  ) <> 2 THEN
    RETURN QUERY SELECT p_meetup_id, v_match.id, 'identity_verification_required'::text,
      v_meetup.status, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Idempotency is checked only after relationship and safety validation.  A
  -- key cannot be replayed by a different participant or operation kind, and
  -- no replay result discloses meetup state to an outsider.
  SELECT claim_row.* INTO v_claim
    FROM public.meetup_arrangement_claims AS claim_row
   WHERE claim_row.meetup_id = p_meetup_id
     AND claim_row.operation_key = p_operation_key;
  IF FOUND THEN
    IF v_claim.user_id <> p_user_id OR v_claim.is_retry IS DISTINCT FROM p_is_retry THEN
      RETURN QUERY SELECT p_meetup_id, v_match.id, 'not_found'::text,
        NULL::text, NULL::integer, NULL::text, false;
      RETURN;
    END IF;
    RETURN QUERY SELECT p_meetup_id, v_match.id, 'already_claimed'::text,
      v_meetup.status, v_claim.attempt_number, v_claim.billing_source, false;
    RETURN;
  END IF;

  SELECT COALESCE(public.entitlements.is_active, false), public.user_profiles.timezone
    INTO v_entitled, v_timezone
    FROM public.user_profiles
    LEFT JOIN public.entitlements
      ON public.entitlements.user_id = public.user_profiles.id
   WHERE public.user_profiles.id = p_user_id;
  IF v_timezone IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = v_timezone
     ) THEN
    -- A malformed profile timezone is an internal fail-closed condition.  It
    -- must never fall back to UTC or another user's calendar month.
    RETURN QUERY SELECT p_meetup_id, v_match.id, 'invalid_input'::text,
      v_meetup.status, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  IF p_is_retry THEN
    IF v_meetup.status NOT IN ('proposed', 'arrange_failed')
       OR v_meetup.arrange_attempt_count < 1 THEN
      IF v_meetup.status = 'arranging' THEN
        RETURN QUERY SELECT p_meetup_id, v_match.id, 'already_arranging'::text,
          'arranging'::text, v_meetup.arrange_attempt_count, NULL::text, false;
      ELSE
        RETURN QUERY SELECT p_meetup_id, v_match.id, 'invalid_state'::text,
          v_meetup.status, NULL::integer, NULL::text, false;
      END IF;
      RETURN;
    END IF;

    v_attempt := v_meetup.arrange_attempt_count + 1;
    -- The first retry is a per-meetup free retry.  `arrange_retry` is kept as
    -- the billing source so analytics cannot confuse it with meet intent or
    -- the initial monthly `meetup_arrange` allowance.  There is no free path
    -- after this attempt: entitlement or one purchased credit is required.
    IF v_meetup.arrange_attempt_count = 1 THEN
      v_billing_source := 'arrange_retry';
    ELSIF v_entitled THEN
      v_billing_source := 'entitlement';
    ELSE
      v_credit_consumed := public.consume_consumable_credit(
        p_user_id,
        pg_catalog.left('meetup:' || p_meetup_id::text || ':retry:' || p_operation_key, 128)
      );
      IF NOT v_credit_consumed THEN
        RETURN QUERY SELECT p_meetup_id, v_match.id, 'quota_exhausted'::text,
          v_meetup.status, NULL::integer, NULL::text, false;
        RETURN;
      END IF;
      v_billing_source := 'credit';
    END IF;
  ELSE
    IF v_meetup.status = 'arranging' THEN
      RETURN QUERY SELECT p_meetup_id, v_match.id, 'already_arranging'::text,
        'arranging'::text, v_meetup.arrange_attempt_count, NULL::text, false;
      RETURN;
    END IF;
    IF v_meetup.status IS DISTINCT FROM 'verifying' THEN
      RETURN QUERY SELECT p_meetup_id, v_match.id, 'invalid_state'::text,
        v_meetup.status, NULL::integer, NULL::text, false;
      RETURN;
    END IF;

    v_attempt := v_meetup.arrange_attempt_count + 1;
    IF v_entitled THEN
      v_billing_source := 'entitlement';
    ELSE
      -- The free monthly period is computed in the caller's configured IANA
      -- timezone, not in the database/session timezone.
      v_period_start := pg_catalog.date_trunc(
        'month', v_now AT TIME ZONE v_timezone
      )::date;
      v_period_end := (v_period_start + pg_catalog.interval '1 month - 1 day')::date;
      v_quota_used := NULL;
      INSERT INTO public.usage_counters
        (user_id, quota_key, period_start, period_end, used_count)
      VALUES
        (p_user_id, 'meetup_arrange', v_period_start, v_period_end, 1)
      ON CONFLICT (user_id, quota_key, period_start)
      DO UPDATE SET
        used_count = public.usage_counters.used_count + 1,
        period_end = EXCLUDED.period_end,
        updated_at = v_now
      WHERE public.usage_counters.used_count < 1
      RETURNING used_count INTO v_quota_used;

      IF v_quota_used IS NULL THEN
        v_credit_consumed := public.consume_consumable_credit(
          p_user_id,
          pg_catalog.left('meetup:' || p_meetup_id::text || ':arrange:' || p_operation_key, 128)
        );
        IF NOT v_credit_consumed THEN
          RETURN QUERY SELECT p_meetup_id, v_match.id, 'quota_exhausted'::text,
            v_meetup.status, NULL::integer, NULL::text, false;
          RETURN;
        END IF;
        v_billing_source := 'credit';
      ELSE
        v_billing_source := 'meetup_arrange';
      END IF;
    END IF;
  END IF;

  UPDATE public.meetups AS meetup_row
     SET status = 'arranging',
         arrange_attempt_count = v_attempt,
         proposal_expires_at = NULL,
         updated_at = v_now
   WHERE meetup_row.id = p_meetup_id
     AND meetup_row.status = CASE WHEN p_is_retry THEN v_meetup.status ELSE 'verifying' END;

  INSERT INTO public.meetup_arrangement_claims
    (meetup_id, user_id, operation_key, is_retry, attempt_number, billing_source, period_start)
  VALUES
    (p_meetup_id, p_user_id, p_operation_key, p_is_retry, v_attempt, v_billing_source, v_period_start);

  RETURN QUERY SELECT p_meetup_id, v_match.id, 'claimed'::text,
    'arranging'::text, v_attempt, v_billing_source, true;
END;
$core$;
REVOKE ALL ON FUNCTION wingward_private.demo_recording_core_claim_meetup_arrangement(boolean,uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.demo_recording_claim_meetup_arrangement(p_admission_id uuid, p_issued_at timestamptz, p_expires_at timestamptz,
  p_meetup_id uuid,
  p_user_id uuid,
  p_is_retry boolean,
  p_operation_key text
)
RETURNS TABLE (
  meetup_id uuid,
  match_id uuid,
  outcome text,
  status text,
  attempt_number integer,
  billing_source text,
  transitioned boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $wrapper$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,NULL::uuid,p_meetup_id,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_claim_meetup_arrangement(true,p_meetup_id,p_user_id,p_is_retry,p_operation_key);
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,NULL::uuid,p_meetup_id,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.demo_recording_claim_meetup_arrangement(uuid,timestamptz,timestamptz,uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.demo_recording_claim_meetup_arrangement(uuid,timestamptz,timestamptz,uuid,uuid,boolean,text) TO service_role;

-- Fail migration on unexpected normal-RPC drift; these original bodies remain unchanged.
DO $$ BEGIN IF (SELECT md5(prosrc) FROM pg_catalog.pg_proc WHERE oid='public.apply_chat_meetup_action(uuid,uuid,integer,integer,uuid,text,jsonb)'::regprocedure)<>'c4dbd5ecb3e9ed5371cc88a73dc10860' THEN RAISE EXCEPTION 'Original RPC source drift: apply_chat_meetup_action'; END IF; END $$;
CREATE FUNCTION wingward_private.demo_recording_core_apply_chat_meetup_action(p_synthetic_admitted boolean,
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
  v_now timestamptz := pg_catalog.now();
  v_revision integer := 0;
  v_own_revision integer := 0;
  v_session_exists boolean := false;
  v_session_created boolean := false;
  v_completed_count integer := 0;
  v_operation_key text;
  v_time_candidate jsonb;
  v_cafe_candidate jsonb;
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
             SET status = 'awaiting_location',
                 selected_time_candidate_id = v_actor_choice,
                 cafe_candidates = '[]'::jsonb,
                 unavailable_reason = NULL,
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now,
                 expires_at = v_now + pg_catalog.interval '30 minutes'
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:time-approved:' || v_revision::text, 'system',
            'You both chose the same time. Share a starting area only if you want help finding a cafe.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        END IF;
      ELSIF v_action_type = 'location.submit' THEN
        IF v_session.status <> 'awaiting_location'
           OR pg_catalog.jsonb_typeof(p_action -> 'location') IS DISTINCT FROM 'object' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        INSERT INTO public.chat_meetup_locations
          (meetup_id, user_id, method, origin, consented_at, expires_at)
        VALUES (
          v_meetup_id, p_user_id,
          CASE WHEN p_action -> 'location' ->> 'kind' = 'coordinates' THEN 'current' ELSE 'station' END,
          p_action -> 'location', v_now, v_now + pg_catalog.interval '30 minutes'
        )
        ON CONFLICT ON CONSTRAINT chat_meetup_locations_pkey DO UPDATE
          SET method = EXCLUDED.method,
              origin = EXCLUDED.origin,
              consented_at = EXCLUDED.consented_at,
              expires_at = EXCLUDED.expires_at;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
      ELSIF v_action_type = 'location.clear' THEN
        IF v_session.status <> 'awaiting_location' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        DELETE FROM public.chat_meetup_locations AS location
         WHERE location.meetup_id = v_meetup_id AND user_id = p_user_id;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
      ELSIF v_action_type = 'cafe.approve' THEN
        IF v_session.status <> 'cafe_proposed'
           OR pg_catalog.jsonb_typeof(v_session.cafe_candidates) IS DISTINCT FROM 'array'
           OR NOT EXISTS (
             SELECT 1 FROM pg_catalog.jsonb_array_elements(v_session.cafe_candidates) AS candidate
              WHERE candidate ->> 'id' = p_action ->> 'candidate_id'
           ) THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        v_actor_choice := p_action ->> 'candidate_id';
        SELECT candidate INTO v_cafe_candidate
          FROM pg_catalog.jsonb_array_elements(v_session.cafe_candidates) AS candidate
         WHERE candidate ->> 'id' = v_actor_choice;
        SELECT candidate INTO v_time_candidate
          FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
         WHERE candidate ->> 'id' = v_session.selected_time_candidate_id;
        IF v_cafe_candidate IS NULL OR v_time_candidate IS NULL
           OR (v_cafe_candidate ->> 'verified_at') IS NULL
           OR (v_cafe_candidate ->> 'verified_at')::timestamptz > v_now + pg_catalog.interval '5 minutes'
           OR (v_cafe_candidate ->> 'verified_at')::timestamptz < v_now - pg_catalog.interval '6 hours'
           OR (v_time_candidate ->> 'starts_at')::timestamptz <= pg_catalog.clock_timestamp()
           OR (v_time_candidate ->> 'ends_at')::timestamptz <= (v_time_candidate ->> 'starts_at')::timestamptz
           OR (v_cafe_candidate ->> 'starts_at') IS NULL
           OR (v_cafe_candidate ->> 'ends_at') IS NULL
           OR (v_cafe_candidate ->> 'starts_at')::timestamptz > (v_time_candidate ->> 'starts_at')::timestamptz
           OR (v_cafe_candidate ->> 'ends_at')::timestamptz < (v_time_candidate ->> 'ends_at')::timestamptz THEN
          RETURN QUERY SELECT 'expired_candidate'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
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
                 cafe_candidates = jsonb_build_array(v_cafe_candidate),
                 unavailable_reason = NULL,
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now,
                 expires_at = NULL
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          UPDATE public.meetups AS meetup_row
             SET status = 'confirmed',
                 confirmed_start_at = v_session.confirmed_starts_at,
                 confirmed_timezone = 'UTC',
                 area = v_cafe_candidate ->> 'area',
                 format = 'cafe',
                 proposal_expires_at = NULL,
                 updated_at = v_now
           WHERE meetup_row.id = v_meetup_id
             AND meetup_row.status IN ('verifying', 'arranging', 'proposed');
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:confirmed:' || v_revision::text, 'system',
            'You both chose this cafe. Your meetup is confirmed.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        END IF;
      ELSIF v_action_type = 'cafe.decline' THEN
        IF v_session.status <> 'cafe_proposed'
           OR NOT EXISTS (
             SELECT 1 FROM pg_catalog.jsonb_array_elements(v_session.cafe_candidates) AS candidate
              WHERE candidate ->> 'id' = p_action ->> 'candidate_id'
           ) THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        UPDATE public.chat_meetup_private_decisions
           SET cafe_choice_id = NULL,
               private_revision = private_revision + 1,
               updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
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
           OR v_session.confirmed_ends_at > v_now THEN
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
REVOKE ALL ON FUNCTION wingward_private.demo_recording_core_apply_chat_meetup_action(boolean,uuid,uuid,integer,integer,uuid,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.demo_recording_apply_chat_meetup_action(p_admission_id uuid, p_issued_at timestamptz, p_expires_at timestamptz,
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
AS $wrapper$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_apply_chat_meetup_action(true,p_room_id,p_user_id,p_expected_revision,p_expected_own_revision,p_idempotency_key,p_request_digest,p_action);
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.demo_recording_apply_chat_meetup_action(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.demo_recording_apply_chat_meetup_action(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,uuid,text,jsonb) TO service_role;

-- Fail migration on unexpected normal-RPC drift; these original bodies remain unchanged.
DO $$ BEGIN IF (SELECT md5(prosrc) FROM pg_catalog.pg_proc WHERE oid='public.publish_chat_meetup_times(uuid,uuid,integer,integer,integer,jsonb,text)'::regprocedure)<>'b76203671c9fe4eab5cf963364269c1f' THEN RAISE EXCEPTION 'Original RPC source drift: publish_chat_meetup_times'; END IF; END $$;
CREATE FUNCTION wingward_private.demo_recording_core_publish_chat_meetup_times(p_synthetic_admitted boolean,
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_first_private_revision integer,
  p_second_private_revision integer,
  p_candidates jsonb,
  p_unavailable_reason text DEFAULT NULL
)
RETURNS TABLE (outcome text, meetup_id uuid, status text, revision integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $core$
DECLARE
  v_first_private_revision integer;
  v_second_private_revision integer;
  v_match_id uuid;
  v_a_id uuid;
  v_b_id uuid;
  v_match_status text;
  v_room_status text;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_reason text := p_unavailable_reason;
  v_now timestamptz := pg_catalog.now();
BEGIN
  SELECT room.match_id INTO v_match_id FROM public.direct_chat_rooms AS room WHERE room.id = p_room_id;
  IF NOT FOUND THEN RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN; END IF;
  SELECT m.user_a_id, m.user_b_id INTO v_a_id, v_b_id FROM public.matches AS m WHERE m.id = v_match_id;
  IF NOT FOUND OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT m.status INTO v_match_status FROM public.matches AS m WHERE m.id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_match_status <> 'direct_chat_active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT room.status INTO v_room_status FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_room_status <> 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT s.* INTO v_session FROM public.chat_meetup_sessions AS s
   WHERE s.room_id = p_room_id
   ORDER BY s.created_at DESC, s.meetup_id DESC
   LIMIT 1
   FOR UPDATE;
  IF NOT FOUND OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF v_session.revision <> p_expected_revision OR v_session.status <> 'awaiting_availability' THEN
    RETURN QUERY SELECT 'stale_revision'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF p_first_private_revision IS NULL OR p_second_private_revision IS NULL THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
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
       SELECT 1 FROM public.chat_meetup_availability AS availability
        WHERE availability.meetup_id = v_session.meetup_id
          AND availability.user_id IN (v_a_id, v_b_id)
          AND availability.expires_at > v_now
       GROUP BY availability.meetup_id
       HAVING count(*) = 2
     ) THEN
    RETURN QUERY SELECT 'stale_private_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF pg_catalog.jsonb_typeof(p_candidates) IS DISTINCT FROM 'array' THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF pg_catalog.jsonb_array_length(p_candidates) > 3
     OR (v_reason IS NOT NULL AND v_reason NOT IN ('no_shared_time', 'calendar_unavailable'))
     OR (v_reason IS NULL AND pg_catalog.jsonb_array_length(p_candidates) = 0)
     OR (v_reason IS NOT NULL AND pg_catalog.jsonb_array_length(p_candidates) > 0) THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF (
    SELECT count(*) FROM public.user_profiles AS profile
     WHERE profile.id IN (v_a_id, v_b_id)
       AND (p_synthetic_admitted OR profile.identity_verification_status = 'verified')
       AND (p_synthetic_admitted OR profile.identity_verified_at IS NOT NULL)
  ) <> 2 THEN
    RETURN QUERY SELECT 'identity_verification_required'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  -- Dedicated synthetic admission requires live future starts after all locks.
  IF v_reason IS NULL AND EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(p_candidates) AS candidate
    WHERE candidate->>'starts_at' IS NULL OR candidate->>'ends_at' IS NULL
       OR NOT pg_catalog.isfinite((candidate->>'starts_at')::timestamptz)
       OR NOT pg_catalog.isfinite((candidate->>'ends_at')::timestamptz)
       OR (candidate->>'starts_at')::timestamptz <= pg_catalog.clock_timestamp()
       OR (candidate->>'ends_at')::timestamptz-(candidate->>'starts_at')::timestamptz <> interval '60 minutes'
  ) THEN
    RETURN QUERY SELECT 'invalid_input'::text,v_session.meetup_id,v_session.status,v_session.revision; RETURN;
  END IF;
  UPDATE public.chat_meetup_sessions
     SET status = CASE WHEN v_reason IS NULL THEN 'time_proposed' ELSE 'unavailable' END,
         time_candidates = p_candidates,
         cafe_candidates = '[]'::jsonb,
         selected_time_candidate_id = NULL,
         unavailable_reason = v_reason,
         revision = chat_meetup_sessions.revision + 1,
         updated_at = v_now,
         expires_at = v_now + pg_catalog.interval '7 days'
   WHERE chat_meetup_sessions.meetup_id = v_session.meetup_id
   RETURNING * INTO v_session;
  DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_session.meetup_id;
  DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_session.meetup_id;
  UPDATE public.meetups AS legacy
     SET status = 'verifying', updated_at = v_now
   WHERE legacy.id = v_session.meetup_id AND legacy.status = 'arranging';
  INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
  VALUES (v_session.meetup_id, v_session.revision, 'state:times:' || v_session.revision::text, 'system',
    CASE WHEN v_reason IS NULL
      THEN 'A few times work for both of you. Choose the same time to continue.'
      ELSE 'We could not confirm a shared time yet. You can try another availability window.'
    END)
  ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
  RETURN QUERY SELECT 'ok'::text, v_session.meetup_id, v_session.status, v_session.revision;
END;
$core$;
REVOKE ALL ON FUNCTION wingward_private.demo_recording_core_publish_chat_meetup_times(boolean,uuid,uuid,integer,integer,integer,jsonb,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.demo_recording_publish_chat_meetup_times(p_admission_id uuid, p_issued_at timestamptz, p_expires_at timestamptz,
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_first_private_revision integer,
  p_second_private_revision integer,
  p_candidates jsonb,
  p_unavailable_reason text DEFAULT NULL
)
RETURNS TABLE (outcome text, meetup_id uuid, status text, revision integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $wrapper$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_publish_chat_meetup_times(true,p_room_id,p_user_id,p_expected_revision,p_first_private_revision,p_second_private_revision,p_candidates,p_unavailable_reason);
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.demo_recording_publish_chat_meetup_times(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,integer,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.demo_recording_publish_chat_meetup_times(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,integer,jsonb,text) TO service_role;

-- Fail migration on unexpected normal-RPC drift; these original bodies remain unchanged.
DO $$ BEGIN IF (SELECT md5(prosrc) FROM pg_catalog.pg_proc WHERE oid='public.publish_chat_meetup_cafes(uuid,uuid,integer,integer,integer,jsonb,text)'::regprocedure)<>'43d10d6b87b51a81ed8042008967d34a' THEN RAISE EXCEPTION 'Original RPC source drift: publish_chat_meetup_cafes'; END IF; END $$;
CREATE FUNCTION wingward_private.demo_recording_core_publish_chat_meetup_cafes(p_synthetic_admitted boolean,
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_first_private_revision integer,
  p_second_private_revision integer,
  p_candidates jsonb,
  p_unavailable_reason text DEFAULT NULL
)
RETURNS TABLE (outcome text, meetup_id uuid, status text, revision integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $core$
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
  v_reason text := p_unavailable_reason;
  v_expiry timestamptz;
  v_now timestamptz := pg_catalog.now();
BEGIN
  SELECT room.match_id INTO v_match_id FROM public.direct_chat_rooms AS room WHERE room.id = p_room_id;
  IF NOT FOUND THEN RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN; END IF;
  SELECT m.user_a_id, m.user_b_id INTO v_a_id, v_b_id FROM public.matches AS m WHERE m.id = v_match_id;
  IF NOT FOUND OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT m.status INTO v_match_status FROM public.matches AS m WHERE m.id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_match_status <> 'direct_chat_active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT room.status INTO v_room_status FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_room_status <> 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT s.* INTO v_session FROM public.chat_meetup_sessions AS s
   WHERE s.room_id = p_room_id
   ORDER BY s.created_at DESC, s.meetup_id DESC
   LIMIT 1
   FOR UPDATE;
  IF NOT FOUND OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF v_session.revision <> p_expected_revision OR v_session.status <> 'awaiting_location' THEN
    RETURN QUERY SELECT 'stale_revision'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF p_first_private_revision IS NULL OR p_second_private_revision IS NULL THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
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
       GROUP BY location.meetup_id
       HAVING count(*) = 2
     ) THEN
    RETURN QUERY SELECT 'stale_private_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF pg_catalog.jsonb_typeof(p_candidates) IS DISTINCT FROM 'array' THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF pg_catalog.jsonb_array_length(p_candidates) > 3
     OR (v_reason IS NOT NULL AND v_reason NOT IN ('cafe_unavailable', 'no_cafe'))
     OR (v_reason IS NULL AND pg_catalog.jsonb_array_length(p_candidates) = 0)
     OR (v_reason IS NOT NULL AND pg_catalog.jsonb_array_length(p_candidates) > 0) THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF v_reason IS NULL THEN
    SELECT candidate INTO v_time_candidate
      FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
     WHERE candidate ->> 'id' = v_session.selected_time_candidate_id;
    IF v_time_candidate IS NULL
       OR (v_time_candidate ->> 'starts_at')::timestamptz <= pg_catalog.clock_timestamp()
       OR (v_time_candidate ->> 'ends_at')::timestamptz <= (v_time_candidate ->> 'starts_at')::timestamptz
       OR EXISTS (
         SELECT 1 FROM pg_catalog.jsonb_array_elements(p_candidates) AS candidate
          WHERE pg_catalog.jsonb_typeof(candidate) IS DISTINCT FROM 'object'
             OR NOT (candidate ?& ARRAY['id','name','address','starts_at','ends_at','travel_minutes_first','travel_minutes_second','verified_at'])
             OR candidate - ARRAY['id','name','address','area','starts_at','ends_at','travel_minutes_first','travel_minutes_second','verified_at'] <> '{}'::jsonb
             OR pg_catalog.jsonb_typeof(candidate -> 'id') IS DISTINCT FROM 'string'
             OR pg_catalog.char_length(candidate ->> 'id') NOT BETWEEN 1 AND 256
             OR pg_catalog.jsonb_typeof(candidate -> 'name') IS DISTINCT FROM 'string'
             OR pg_catalog.char_length(candidate ->> 'name') NOT BETWEEN 1 AND 120
             OR pg_catalog.jsonb_typeof(candidate -> 'address') IS DISTINCT FROM 'string'
             OR pg_catalog.char_length(candidate ->> 'address') NOT BETWEEN 1 AND 300
             OR pg_catalog.jsonb_typeof(candidate -> 'starts_at') IS DISTINCT FROM 'string'
             OR pg_catalog.jsonb_typeof(candidate -> 'ends_at') IS DISTINCT FROM 'string'
             OR pg_catalog.jsonb_typeof(candidate -> 'verified_at') IS DISTINCT FROM 'string'
             OR pg_catalog.jsonb_typeof(candidate -> 'travel_minutes_first') IS DISTINCT FROM 'number'
             OR (candidate ->> 'travel_minutes_first')::numeric < 0
             OR (candidate ->> 'travel_minutes_first')::numeric > 120
             OR pg_catalog.jsonb_typeof(candidate -> 'travel_minutes_second') IS DISTINCT FROM 'number'
             OR (candidate ->> 'travel_minutes_second')::numeric < 0
             OR (candidate ->> 'travel_minutes_second')::numeric > 120
             OR (candidate ->> 'starts_at')::timestamptz > (v_time_candidate ->> 'starts_at')::timestamptz
             OR (candidate ->> 'ends_at')::timestamptz < (v_time_candidate ->> 'ends_at')::timestamptz
             OR (candidate ->> 'ends_at')::timestamptz <= (candidate ->> 'starts_at')::timestamptz
             OR (candidate ->> 'verified_at')::timestamptz > v_now + pg_catalog.interval '5 minutes'
             OR (candidate ->> 'verified_at')::timestamptz < v_now - pg_catalog.interval '6 hours'
       )
    THEN
      RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
    END IF;
    SELECT LEAST(
             v_now + pg_catalog.interval '7 days',
             pg_catalog.min((candidate ->> 'verified_at')::timestamptz + pg_catalog.interval '6 hours')
           )
      INTO v_expiry
      FROM pg_catalog.jsonb_array_elements(p_candidates) AS candidate;
    IF v_expiry IS NULL OR v_expiry <= v_now THEN
      RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
    END IF;
  ELSE
    v_expiry := v_now + pg_catalog.interval '7 days';
  END IF;
  IF (
    SELECT count(*) FROM public.user_profiles AS profile
     WHERE profile.id IN (v_a_id, v_b_id)
       AND (p_synthetic_admitted OR profile.identity_verification_status = 'verified')
       AND (p_synthetic_admitted OR profile.identity_verified_at IS NOT NULL)
  ) <> 2 THEN
    RETURN QUERY SELECT 'identity_verification_required'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_meetup_locations AS location
     WHERE location.meetup_id = v_session.meetup_id
       AND location.user_id IN (v_a_id, v_b_id)
       AND location.expires_at > v_now
    GROUP BY location.meetup_id
    HAVING count(*) = 2
  ) THEN
    RETURN QUERY SELECT 'missing_consent'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  UPDATE public.chat_meetup_sessions
     SET status = CASE WHEN v_reason IS NULL THEN 'cafe_proposed' ELSE 'unavailable' END,
         cafe_candidates = p_candidates,
         unavailable_reason = v_reason,
         revision = chat_meetup_sessions.revision + 1,
         updated_at = v_now,
         expires_at = v_expiry
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
$core$;
REVOKE ALL ON FUNCTION wingward_private.demo_recording_core_publish_chat_meetup_cafes(boolean,uuid,uuid,integer,integer,integer,jsonb,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.demo_recording_publish_chat_meetup_cafes(p_admission_id uuid, p_issued_at timestamptz, p_expires_at timestamptz,
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_first_private_revision integer,
  p_second_private_revision integer,
  p_candidates jsonb,
  p_unavailable_reason text DEFAULT NULL
)
RETURNS TABLE (outcome text, meetup_id uuid, status text, revision integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $wrapper$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_publish_chat_meetup_cafes(true,p_room_id,p_user_id,p_expected_revision,p_first_private_revision,p_second_private_revision,p_candidates,p_unavailable_reason);
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.demo_recording_publish_chat_meetup_cafes(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,integer,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.demo_recording_publish_chat_meetup_cafes(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,integer,jsonb,text) TO service_role;

-- Fail migration on unexpected normal-RPC drift; these original bodies remain unchanged.
DO $$ BEGIN IF (SELECT md5(prosrc) FROM pg_catalog.pg_proc WHERE oid='public.get_meetup_reflection_state(uuid,uuid)'::regprocedure)<>'451f3292059590eb5156fda9dc814f24' THEN RAISE EXCEPTION 'Original RPC source drift: get_meetup_reflection_state'; END IF; END $$;
CREATE FUNCTION wingward_private.demo_recording_core_get_meetup_reflection_state(p_synthetic_admitted boolean,
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
AS $core$
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
          AND (p_synthetic_admitted OR profile_row.identity_verification_status = 'verified')
          AND (p_synthetic_admitted OR profile_row.identity_verified_at IS NOT NULL)
          AND (p_synthetic_admitted OR pg_catalog.isfinite(profile_row.identity_verified_at))
          AND (p_synthetic_admitted OR profile_row.identity_verified_at <= v_now)
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
$core$;
REVOKE ALL ON FUNCTION wingward_private.demo_recording_core_get_meetup_reflection_state(boolean,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.demo_recording_get_meetup_reflection_state(p_admission_id uuid, p_issued_at timestamptz, p_expires_at timestamptz,
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
AS $wrapper$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,NULL::uuid,p_meetup_id,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_get_meetup_reflection_state(true,p_meetup_id,p_user_id);
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,NULL::uuid,p_meetup_id,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.demo_recording_get_meetup_reflection_state(uuid,timestamptz,timestamptz,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.demo_recording_get_meetup_reflection_state(uuid,timestamptz,timestamptz,uuid,uuid) TO service_role;

-- Fail migration on unexpected normal-RPC drift; these original bodies remain unchanged.
DO $$ BEGIN IF (SELECT md5(prosrc) FROM pg_catalog.pg_proc WHERE oid='public.confirm_meetup_reflection(uuid,uuid,uuid,integer,jsonb)'::regprocedure)<>'bb5d90034ad0755be5432010f0a9f9ec' THEN RAISE EXCEPTION 'Original RPC source drift: confirm_meetup_reflection'; END IF; END $$;
CREATE FUNCTION wingward_private.demo_recording_core_confirm_meetup_reflection(p_synthetic_admitted boolean,
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
$core$;
REVOKE ALL ON FUNCTION wingward_private.demo_recording_core_confirm_meetup_reflection(boolean,uuid,uuid,uuid,integer,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.demo_recording_confirm_meetup_reflection(p_admission_id uuid, p_issued_at timestamptz, p_expires_at timestamptz,
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
AS $wrapper$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,NULL::uuid,p_meetup_id,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_confirm_meetup_reflection(true,p_meetup_id,p_user_id,p_idempotency_key,p_expected_version,p_traits);
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,NULL::uuid,p_meetup_id,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.demo_recording_confirm_meetup_reflection(uuid,timestamptz,timestamptz,uuid,uuid,uuid,integer,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.demo_recording_confirm_meetup_reflection(uuid,timestamptz,timestamptz,uuid,uuid,uuid,integer,jsonb) TO service_role;

-- Fail migration on unexpected normal-RPC drift; these original bodies remain unchanged.
DO $$ BEGIN IF (SELECT md5(prosrc) FROM pg_catalog.pg_proc WHERE oid='public.publish_chat_meetup_google_cafes(uuid,uuid,integer,integer,integer,text[],text)'::regprocedure)<>'6dac69c699288ea98acabc1c3662ae55' THEN RAISE EXCEPTION 'Original RPC source drift: publish_chat_meetup_google_cafes'; END IF; END $$;
CREATE FUNCTION wingward_private.demo_recording_core_publish_chat_meetup_google_cafes(p_synthetic_admitted boolean,
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
AS $core$
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
       AND (p_synthetic_admitted OR profile.identity_verification_status = 'verified')
       AND (p_synthetic_admitted OR profile.identity_verified_at IS NOT NULL)
       AND (p_synthetic_admitted OR profile.identity_verified_at <= v_now)
  ) <> 2 THEN
    RETURN QUERY SELECT 'identity_verification_required'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  SELECT candidate INTO v_time_candidate
    FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
   WHERE candidate ->> 'id' = v_session.selected_time_candidate_id;
  IF v_time_candidate IS NULL
     OR (v_time_candidate ->> 'starts_at')::timestamptz <= pg_catalog.clock_timestamp()
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
$core$;
REVOKE ALL ON FUNCTION wingward_private.demo_recording_core_publish_chat_meetup_google_cafes(boolean,uuid,uuid,integer,integer,integer,text[],text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.demo_recording_publish_chat_meetup_google_cafes(p_admission_id uuid, p_issued_at timestamptz, p_expires_at timestamptz,
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
AS $wrapper$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_publish_chat_meetup_google_cafes(true,p_room_id,p_user_id,p_expected_revision,p_first_private_revision,p_second_private_revision,p_place_ids,p_unavailable_reason);
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.demo_recording_publish_chat_meetup_google_cafes(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,integer,text[],text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.demo_recording_publish_chat_meetup_google_cafes(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,integer,text[],text) TO service_role;

-- Fail migration on unexpected normal-RPC drift; these original bodies remain unchanged.
DO $$ BEGIN IF (SELECT md5(prosrc) FROM pg_catalog.pg_proc WHERE oid='public.apply_chat_meetup_google_cafe_action(uuid,uuid,integer,integer,uuid,text,text,text)'::regprocedure)<>'d30a39350a7f47fc6b5b80a1a74ee87d' THEN RAISE EXCEPTION 'Original RPC source drift: apply_chat_meetup_google_cafe_action'; END IF; END $$;
CREATE FUNCTION wingward_private.demo_recording_core_apply_chat_meetup_google_cafe_action(p_synthetic_admitted boolean,
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
                AND (p_synthetic_admitted OR profile.identity_verification_status = 'verified')
                AND (p_synthetic_admitted OR profile.identity_verified_at IS NOT NULL)
                AND (p_synthetic_admitted OR profile.identity_verified_at <= v_now)) = 2 THEN
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
     OR (v_time_candidate ->> 'starts_at')::timestamptz <= pg_catalog.clock_timestamp()
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
$core$;
REVOKE ALL ON FUNCTION wingward_private.demo_recording_core_apply_chat_meetup_google_cafe_action(boolean,uuid,uuid,integer,integer,uuid,text,text,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.demo_recording_apply_chat_meetup_google_cafe_action(p_admission_id uuid, p_issued_at timestamptz, p_expires_at timestamptz,
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
AS $wrapper$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_apply_chat_meetup_google_cafe_action(true,p_room_id,p_user_id,p_expected_revision,p_expected_own_revision,p_idempotency_key,p_request_digest,p_action_type,p_candidate_id);
 IF NOT EXISTS(SELECT 1 FROM wingward_private.resolve_synthetic_recording_admission(p_admission_id,p_user_id,p_room_id,NULL::uuid,p_issued_at,p_expires_at,true) AS permit WHERE permit.outcome='admitted') THEN RAISE EXCEPTION 'Synthetic admission unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.demo_recording_apply_chat_meetup_google_cafe_action(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,uuid,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.demo_recording_apply_chat_meetup_google_cafe_action(uuid,timestamptz,timestamptz,uuid,uuid,integer,integer,uuid,text,text,text) TO service_role;
