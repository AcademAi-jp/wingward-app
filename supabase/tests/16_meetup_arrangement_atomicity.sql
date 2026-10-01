-- Phase 2 S2 arrangement acceptance checks.
--
-- Plain SQL, run with psql -v ON_ERROR_STOP=1 after all migrations.  This
-- script is intentionally transaction-scoped.  Runtime execution is not
-- performed in the feature worktree when Supabase/Postgres is unavailable.

BEGIN;

DO $$
DECLARE
  index_predicate text;
BEGIN
  SELECT pg_catalog.pg_get_expr(i.indpred, i.indrelid)
    INTO index_predicate
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_index AS i ON i.indexrelid = c.oid
   WHERE n.nspname = 'public'
     AND c.relname = 'notifications_meetup_lifetime_scenario_user_key'
     AND i.indisunique;
  IF COALESCE(index_predicate, '') NOT LIKE '%N-14%' THEN
    RAISE EXCEPTION 'FAIL 16n: N-14 is not lifetime-deduplicated per participant and meetup';
  END IF;
END $$;

DO $$
DECLARE
  function_name text;
  function_oid oid;
  function_def text;
  expected text[] := ARRAY[
    'claim_meetup_arrangement(uuid,uuid,boolean,text)',
    'persist_meetup_proposal(uuid,uuid,integer,jsonb)',
    'claim_expired_meetups(timestamptz)'
  ];
BEGIN
  FOREACH function_name IN ARRAY expected LOOP
    function_oid := to_regprocedure('public.' || function_name);
    IF function_oid IS NULL THEN
      RAISE EXCEPTION 'FAIL 16a: missing public.%', function_name;
    END IF;
    SELECT pg_catalog.pg_get_functiondef(function_oid) INTO function_def;
    IF NOT EXISTS (
      SELECT 1
        FROM pg_catalog.pg_proc AS proc
       WHERE proc.oid = function_oid
         AND proc.prosecdef IS TRUE
         AND proc.proconfig @> ARRAY['search_path=""']::text[]
    ) THEN
      RAISE EXCEPTION 'FAIL 16a: public.% is not a locked-down SECURITY DEFINER', function_name;
    END IF;
    IF has_function_privilege('anon', function_oid, 'EXECUTE')
       OR has_function_privilege('authenticated', function_oid, 'EXECUTE')
       OR NOT has_function_privilege('service_role', function_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL 16a: public.% grants are not service_role-only', function_name;
    END IF;
  END LOOP;
  SELECT pg_catalog.pg_get_functiondef(to_regprocedure('public.claim_meetup_arrangement(uuid,uuid,boolean,text)'))
    INTO function_def;
  IF function_def NOT LIKE '%FOR UPDATE%'
     OR function_def NOT LIKE '%identity_verification_status%'
     OR function_def NOT LIKE '%age_verified_at IS NOT NULL%'
     OR function_def NOT LIKE '%consume_consumable_credit%'
     OR function_def NOT LIKE '%entitlements.user_id = public.user_profiles.id%'
     OR function_def NOT LIKE '%meetup_arrange%' THEN
    RAISE EXCEPTION 'FAIL 16b: arrangement claim does not contain lock, identity, and billing guards';
  END IF;
  SELECT pg_catalog.pg_get_functiondef(to_regprocedure('public.persist_meetup_proposal(uuid,uuid,integer,jsonb)'))
    INTO function_def;
  IF function_def NOT LIKE '%jsonb_array_length%3%'
     OR function_def NOT LIKE '%arrange_failed%'
     OR function_def NOT LIKE '%pg_timezone_names%' THEN
    RAISE EXCEPTION 'FAIL 16c: proposal persistence does not contain strict output/failure guards';
  END IF;
  SELECT pg_catalog.pg_get_functiondef(to_regprocedure('public.claim_expired_meetups(timestamptz)'))
    INTO function_def;
  IF function_def NOT LIKE '%FOR UPDATE SKIP LOCKED%'
     OR function_def NOT LIKE '%<= COALESCE(p_now%'
     OR function_def NOT LIKE '%RETURNING%' THEN
    RAISE EXCEPTION 'FAIL 16d: expiry claim is not conditional and returned-row based';
  END IF;
  RAISE NOTICE 'PASS 16: arrangement atomicity RPCs are locked down and boundary checks are present';
END $$;

-- The runtime lock order is match -> room -> meetup.  This structural check
-- guards the intended order; a multi-session probe belongs to the root test
-- run because one transaction cannot prove a concurrent interleaving.
DO $$
DECLARE
  claim_definition text;
  proposal_definition text;
  claim_match_pos integer;
  claim_room_pos integer;
  claim_meetup_pos integer;
  proposal_match_pos integer;
  proposal_room_pos integer;
  proposal_meetup_pos integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    to_regprocedure('public.claim_meetup_arrangement(uuid,uuid,boolean,text)')
  ) INTO claim_definition;
  SELECT pg_catalog.pg_get_functiondef(
    to_regprocedure('public.persist_meetup_proposal(uuid,uuid,integer,jsonb)')
  ) INTO proposal_definition;

  claim_match_pos := pg_catalog.strpos(claim_definition, 'FROM public.matches AS match_row');
  claim_room_pos := pg_catalog.strpos(claim_definition, 'FROM public.direct_chat_rooms AS room_row');
  claim_meetup_pos := pg_catalog.strpos(claim_definition, 'FROM public.meetups AS locked_meetup');
  proposal_match_pos := pg_catalog.strpos(proposal_definition, 'FROM public.matches AS match_row');
  proposal_room_pos := pg_catalog.strpos(proposal_definition, 'FROM public.direct_chat_rooms AS room_row');
  proposal_meetup_pos := pg_catalog.strpos(proposal_definition, 'FROM public.meetups AS locked_meetup');

  IF claim_match_pos < 1 OR claim_room_pos <= claim_match_pos OR claim_meetup_pos <= claim_room_pos
     OR proposal_match_pos < 1 OR proposal_room_pos <= proposal_match_pos
     OR proposal_meetup_pos <= proposal_room_pos THEN
    RAISE EXCEPTION 'FAIL 16f: arrangement RPCs do not preserve match -> room -> meetup lock order';
  END IF;
  IF claim_definition NOT LIKE '%claim_row.meetup_id%'
     OR proposal_definition NOT LIKE '%proposal_row.meetup_id%'
     OR claim_definition NOT LIKE '%locked_meetup.match_id = v_match.id%'
     OR proposal_definition NOT LIKE '%locked_meetup.match_id = v_match.id%' THEN
    RAISE EXCEPTION 'FAIL 16f: arrangement RPCs do not revalidate relationship identity after the meetup lock';
  END IF;
  RAISE NOTICE 'PASS 16f: arrangement RPCs use explicit relationship aliases and lock order';
END $$;

DO $$
BEGIN
  IF (SELECT relrowsecurity FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = 'meetup_arrangement_claims') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL 16e: arrangement claims table does not have RLS enabled';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
     WHERE schemaname = 'public' AND tablename = 'meetup_arrangement_claims'
  ) THEN
    RAISE EXCEPTION 'FAIL 16e: client policy exists on arrangement claims table';
  END IF;
  RAISE NOTICE 'PASS 16e: arrangement claim ledger is deny-by-default';
END $$;

-- Synthetic fixtures exercise the RPC branches in one transaction.  They use
-- no seeded application rows and are rolled back below.
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000a6', 'wingward-test-a6@example.invalid'),
  ('00000000-0000-0000-0000-0000000000b6', 'wingward-test-b6@example.invalid'),
  ('00000000-0000-0000-0000-0000000000c6', 'wingward-test-c6@example.invalid');

UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-0000000000a6',
       nickname = 'Arrangement A6',
       timezone = 'UTC',
       birth_date = '1990-01-01',
       age_verified_at = '2026-08-24T00:00:00Z',
       age_verification_method = 'self_declared',
       gender_identity = 'woman',
       preferred_genders = ARRAY['woman']::text[],
       preference_mode = 'selected',
       dating_market = 'JP',
       onboarding_settings_completed_at = '2026-08-24T00:00:00Z',
       identity_verification_status = 'verified',
       identity_verified_at = '2026-08-24T00:00:00Z'
 WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a6';
UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-0000000000b6',
       nickname = 'Arrangement B6',
       timezone = 'UTC',
       birth_date = '1990-01-01',
       age_verified_at = '2026-08-24T00:00:00Z',
       age_verification_method = 'self_declared',
       gender_identity = 'woman',
       preferred_genders = ARRAY['woman']::text[],
       preference_mode = 'selected',
       dating_market = 'JP',
       onboarding_settings_completed_at = '2026-08-24T00:00:00Z',
       identity_verification_status = 'verified',
       identity_verified_at = '2026-08-24T00:00:00Z'
 WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b6';
UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-0000000000c6',
       nickname = 'Arrangement C6',
       timezone = 'UTC',
       birth_date = '1990-01-01',
       age_verified_at = '2026-08-24T00:00:00Z',
       age_verification_method = 'self_declared',
       gender_identity = 'woman',
       preferred_genders = ARRAY['woman']::text[],
       preference_mode = 'selected',
       dating_market = 'JP',
       onboarding_settings_completed_at = '2026-08-24T00:00:00Z',
       identity_verification_status = 'verified',
       identity_verified_at = '2026-08-24T00:00:00Z'
 WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c6';

INSERT INTO public.matches (id, user_a_id, user_b_id, status)
VALUES (
  '20000000-0000-0000-0000-0000000000a6',
  '10000000-0000-0000-0000-0000000000a6',
  '10000000-0000-0000-0000-0000000000b6',
  'direct_chat_active'
);

INSERT INTO public.direct_chat_rooms (id, match_id, status)
VALUES (
  '40000000-0000-0000-0000-0000000000a6',
  '20000000-0000-0000-0000-0000000000a6',
  'active'
);

INSERT INTO public.meetups (id, match_id, initiator_id, status)
VALUES (
  '50000000-0000-0000-0000-0000000000a6',
  '20000000-0000-0000-0000-0000000000a6',
  '10000000-0000-0000-0000-0000000000a6',
  'verifying'
);

SET LOCAL role = 'service_role';

-- A first claim consumes the free monthly quota.  The owner can replay the
-- exact key, while a different caller or retry kind cannot reuse it.
DO $$
DECLARE
  initial_claim record;
  replay record;
  wrong_caller record;
  wrong_retry record;
  quota_used integer;
  attempt_value integer;
BEGIN
  SELECT * INTO initial_claim
  FROM public.claim_meetup_arrangement(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    false,
    'arrange-key-a6'
  );
  IF initial_claim.outcome IS DISTINCT FROM 'claimed'
     OR initial_claim.status IS DISTINCT FROM 'arranging'
     OR initial_claim.attempt_number IS DISTINCT FROM 1
     OR initial_claim.billing_source IS DISTINCT FROM 'meetup_arrange'
     OR initial_claim.transitioned IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL 16g: initial arrangement claim did not consume the free quota';
  END IF;

  SELECT * INTO replay
  FROM public.claim_meetup_arrangement(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    false,
    'arrange-key-a6'
  );
  IF replay.outcome IS DISTINCT FROM 'already_claimed'
     OR replay.status IS DISTINCT FROM 'arranging'
     OR replay.attempt_number IS DISTINCT FROM 1
     OR replay.billing_source IS DISTINCT FROM 'meetup_arrange'
     OR replay.transitioned IS TRUE THEN
    RAISE EXCEPTION 'FAIL 16g: same operation key was not an idempotent replay';
  END IF;

  SELECT * INTO wrong_caller
  FROM public.claim_meetup_arrangement(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000b6',
    false,
    'arrange-key-a6'
  );
  IF wrong_caller.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL 16g: another participant reused the operation key';
  END IF;

  SELECT * INTO wrong_retry
  FROM public.claim_meetup_arrangement(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    true,
    'arrange-key-a6'
  );
  IF wrong_retry.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL 16g: the operation key was reused for a retry';
  END IF;

  SELECT COALESCE(sum(counters.used_count), 0)::integer
    INTO quota_used
    FROM public.usage_counters AS counters
   WHERE counters.user_id = '10000000-0000-0000-0000-0000000000a6'
     AND counters.quota_key = 'meetup_arrange';
  SELECT meetup_row.arrange_attempt_count
    INTO attempt_value
    FROM public.meetups AS meetup_row
   WHERE meetup_row.id = '50000000-0000-0000-0000-0000000000a6';
  IF quota_used IS DISTINCT FROM 1 OR attempt_value IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL 16g: replay or rejected key changed quota/attempt counts';
  END IF;
  RAISE NOTICE 'PASS 16g: initial claim, replay, owner binding, and retry binding are atomic';
END $$;

-- The claim ledger is intentionally denied even to service_role; only the
-- SECURITY DEFINER RPC can write it. Inspect its row count as the test owner.
RESET role;
DO $$
DECLARE
  claim_count integer;
BEGIN
  SELECT count(*)::integer
    INTO claim_count
    FROM public.meetup_arrangement_claims AS claims
   WHERE claims.meetup_id = '50000000-0000-0000-0000-0000000000a6';
  IF claim_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL 16g: expected one claim ledger row, got %', claim_count;
  END IF;
END $$;
SET LOCAL role = 'service_role';

-- Persist exactly three valid candidates, replay the same attempt, and reject
-- a stale attempt without adding a proposal row.
DO $$
DECLARE
  candidates jsonb;
  initial_result record;
  replay_result record;
  stale_result record;
  first_proposal_id uuid;
  proposal_count integer;
BEGIN
  candidates := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '2 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Chiyoda', 'format', 'cafe',
      'rationale', 'A calm public option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '3 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Shibuya', 'format', 'meal',
      'rationale', 'A convenient public option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '4 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Minato', 'format', 'online',
      'rationale', 'A low-friction option.'
    )
  );

  SELECT * INTO initial_result
  FROM public.persist_meetup_proposal(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    1,
    candidates
  );
  IF initial_result.outcome IS DISTINCT FROM 'proposed'
     OR initial_result.status IS DISTINCT FROM 'proposed'
     OR initial_result.transitioned IS NOT TRUE
     OR initial_result.proposal_id IS NULL THEN
    RAISE EXCEPTION 'FAIL 16h: valid three-candidate proposal was not persisted';
  END IF;
  first_proposal_id := initial_result.proposal_id;

  SELECT count(*)::integer
    INTO proposal_count
    FROM public.meetup_proposals AS proposals
   WHERE proposals.meetup_id = '50000000-0000-0000-0000-0000000000a6';
  IF proposal_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL 16h: valid proposal created % rows', proposal_count;
  END IF;

  SELECT * INTO replay_result
  FROM public.persist_meetup_proposal(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    1,
    candidates
  );
  IF replay_result.outcome IS DISTINCT FROM 'already_proposed'
     OR replay_result.proposal_id IS DISTINCT FROM first_proposal_id
     OR replay_result.transitioned IS TRUE THEN
    RAISE EXCEPTION 'FAIL 16h: valid proposal replay was not idempotent';
  END IF;

  SELECT * INTO stale_result
  FROM public.persist_meetup_proposal(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    2,
    candidates
  );
  IF stale_result.outcome IS DISTINCT FROM 'invalid_state' OR stale_result.transitioned IS TRUE THEN
    RAISE EXCEPTION 'FAIL 16h: stale proposal attempt changed state';
  END IF;

  SELECT count(*)::integer
    INTO proposal_count
    FROM public.meetup_proposals AS proposals
   WHERE proposals.meetup_id = '50000000-0000-0000-0000-0000000000a6';
  IF proposal_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL 16h: stale proposal attempt changed proposal count';
  END IF;
  RAISE NOTICE 'PASS 16h: valid proposal, replay, and stale-attempt fence are atomic';
END $$;

-- Newline-bearing rationale text fails closed for both LF and CR, leaving the
-- existing proposal history intact and persisting no malformed proposal.
DO $$
DECLARE
  base_candidates jsonb;
  lf_candidates jsonb;
  cr_candidates jsonb;
  lf_result record;
  cr_result record;
  proposal_count integer;
BEGIN
  base_candidates := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '5 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Chiyoda', 'format', 'cafe',
      'rationale', 'A calm public option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '6 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Shibuya', 'format', 'meal',
      'rationale', 'A convenient public option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '7 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Minato', 'format', 'online',
      'rationale', 'A low-friction option.'
    )
  );
  lf_candidates := pg_catalog.jsonb_set(
    base_candidates,
    ARRAY['0', 'rationale'],
    pg_catalog.to_jsonb('LF line one'::text || pg_catalog.chr(10) || 'LF line two'::text),
    false
  );
  cr_candidates := pg_catalog.jsonb_set(
    base_candidates,
    ARRAY['0', 'rationale'],
    pg_catalog.to_jsonb('CR line one'::text || pg_catalog.chr(13) || 'CR line two'::text),
    false
  );

  UPDATE public.meetups AS meetup_row
     SET status = 'arranging', arrange_attempt_count = 2, proposal_expires_at = NULL
   WHERE meetup_row.id = '50000000-0000-0000-0000-0000000000a6';
  SELECT * INTO lf_result
  FROM public.persist_meetup_proposal(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    2,
    lf_candidates
  );
  IF lf_result.outcome IS DISTINCT FROM 'arrange_failed'
     OR lf_result.status IS DISTINCT FROM 'arrange_failed'
     OR lf_result.proposal_id IS NOT NULL
     OR lf_result.transitioned IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL 16i: LF rationale was not rejected fail-closed';
  END IF;

  SELECT count(*)::integer
    INTO proposal_count
    FROM public.meetup_proposals AS proposals
   WHERE proposals.meetup_id = '50000000-0000-0000-0000-0000000000a6';
  IF proposal_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL 16i: LF rationale created a malformed proposal';
  END IF;

  UPDATE public.meetups AS meetup_row
     SET status = 'arranging', arrange_attempt_count = 3, proposal_expires_at = NULL
   WHERE meetup_row.id = '50000000-0000-0000-0000-0000000000a6';
  SELECT * INTO cr_result
  FROM public.persist_meetup_proposal(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    3,
    cr_candidates
  );
  IF cr_result.outcome IS DISTINCT FROM 'arrange_failed'
     OR cr_result.status IS DISTINCT FROM 'arrange_failed'
     OR cr_result.proposal_id IS NOT NULL
     OR cr_result.transitioned IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL 16i: CR rationale was not rejected fail-closed';
  END IF;

  SELECT count(*)::integer
    INTO proposal_count
    FROM public.meetup_proposals AS proposals
   WHERE proposals.meetup_id = '50000000-0000-0000-0000-0000000000a6';
  IF proposal_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL 16i: CR rationale created a malformed proposal';
  END IF;
  RAISE NOTICE 'PASS 16i: LF and CR rationale inputs fail closed without proposal rows';
END $$;

-- Outsiders, blocked pairs, inactive matches, and closed rooms cannot mutate
-- claims, quotas, attempts, or proposals after relationship authorization.
DO $$
DECLARE
  candidates jsonb;
  outsider_proposal record;
  outsider_claim record;
  blocked_proposal record;
  blocked_claim record;
  inactive_proposal record;
  inactive_claim record;
  closed_proposal record;
  closed_claim record;
  proposal_before integer;
  quota_before integer;
  proposal_after integer;
  quota_after integer;
  status_before text;
  status_after text;
  attempt_before integer;
  attempt_after integer;
BEGIN
  candidates := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '8 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Chiyoda', 'format', 'cafe',
      'rationale', 'A calm public option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '9 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Shibuya', 'format', 'meal',
      'rationale', 'A convenient public option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '10 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Minato', 'format', 'online',
      'rationale', 'A low-friction option.'
    )
  );

  UPDATE public.meetups AS meetup_row
     SET status = 'arranging', arrange_attempt_count = 4, proposal_expires_at = NULL
   WHERE meetup_row.id = '50000000-0000-0000-0000-0000000000a6';
  SELECT meetup_row.status, meetup_row.arrange_attempt_count
    INTO status_before, attempt_before
    FROM public.meetups AS meetup_row
   WHERE meetup_row.id = '50000000-0000-0000-0000-0000000000a6';
  SELECT count(*)::integer INTO proposal_before
    FROM public.meetup_proposals AS proposals
   WHERE proposals.meetup_id = '50000000-0000-0000-0000-0000000000a6';
  SELECT COALESCE(sum(counters.used_count), 0)::integer INTO quota_before
    FROM public.usage_counters AS counters
   WHERE counters.user_id = '10000000-0000-0000-0000-0000000000a6'
     AND counters.quota_key = 'meetup_arrange';

  SELECT * INTO outsider_proposal
  FROM public.persist_meetup_proposal(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000c6',
    4,
    candidates
  );
  IF outsider_proposal.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL 16j: outsider persisted a proposal';
  END IF;
  SELECT * INTO outsider_claim
  FROM public.claim_meetup_arrangement(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000c6',
    false,
    'outsider-key-a6'
  );
  IF outsider_claim.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL 16j: outsider claimed arrangement';
  END IF;

  INSERT INTO public.blocks (blocker_id, blocked_id)
  VALUES (
    '10000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000b6'
  );
  SELECT * INTO blocked_proposal
  FROM public.persist_meetup_proposal(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    4,
    candidates
  );
  IF blocked_proposal.outcome IS DISTINCT FROM 'blocked' THEN
    RAISE EXCEPTION 'FAIL 16j: blocked pair persisted a proposal';
  END IF;
  SELECT * INTO blocked_claim
  FROM public.claim_meetup_arrangement(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    false,
    'blocked-key-a6'
  );
  IF blocked_claim.outcome IS DISTINCT FROM 'blocked' THEN
    RAISE EXCEPTION 'FAIL 16j: blocked pair claimed arrangement';
  END IF;

  -- Isolate the next rejection cause; blocked pairs cannot be reopened.
  DELETE FROM public.blocks
   WHERE blocker_id = '10000000-0000-0000-0000-0000000000a6'
     AND blocked_id = '10000000-0000-0000-0000-0000000000b6';

  UPDATE public.matches AS match_row
     SET status = 'pending'
   WHERE match_row.id = '20000000-0000-0000-0000-0000000000a6';
  SELECT * INTO inactive_proposal
  FROM public.persist_meetup_proposal(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    4,
    candidates
  );
  IF inactive_proposal.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL 16j: inactive match persisted a proposal';
  END IF;
  SELECT * INTO inactive_claim
  FROM public.claim_meetup_arrangement(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    false,
    'inactive-key-a6'
  );
  IF inactive_claim.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL 16j: inactive match claimed arrangement';
  END IF;

  UPDATE public.matches AS match_row
     SET status = 'direct_chat_active'
   WHERE match_row.id = '20000000-0000-0000-0000-0000000000a6';
  UPDATE public.direct_chat_rooms AS room_row
     SET status = 'closed'
   WHERE room_row.match_id = '20000000-0000-0000-0000-0000000000a6';
  SELECT * INTO closed_proposal
  FROM public.persist_meetup_proposal(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    4,
    candidates
  );
  IF closed_proposal.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL 16j: closed room persisted a proposal';
  END IF;
  SELECT * INTO closed_claim
  FROM public.claim_meetup_arrangement(
    '50000000-0000-0000-0000-0000000000a6',
    '10000000-0000-0000-0000-0000000000a6',
    false,
    'closed-room-key-a6'
  );
  IF closed_claim.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL 16j: closed room claimed arrangement';
  END IF;

  SELECT meetup_row.status, meetup_row.arrange_attempt_count
    INTO status_after, attempt_after
    FROM public.meetups AS meetup_row
   WHERE meetup_row.id = '50000000-0000-0000-0000-0000000000a6';
  SELECT count(*)::integer INTO proposal_after
    FROM public.meetup_proposals AS proposals
   WHERE proposals.meetup_id = '50000000-0000-0000-0000-0000000000a6';
  SELECT COALESCE(sum(counters.used_count), 0)::integer INTO quota_after
    FROM public.usage_counters AS counters
   WHERE counters.user_id = '10000000-0000-0000-0000-0000000000a6'
     AND counters.quota_key = 'meetup_arrange';
  IF status_before IS DISTINCT FROM status_after
     OR attempt_before IS DISTINCT FROM attempt_after
     OR proposal_before IS DISTINCT FROM proposal_after
     OR quota_before IS DISTINCT FROM quota_after THEN
    RAISE EXCEPTION 'FAIL 16j: rejected relationship calls mutated arrangement state';
  END IF;
  RAISE NOTICE 'PASS 16j: outsider, block, inactive match, and closed room fail closed without mutation';
END $$;

RESET role;
DO $$
DECLARE
  claim_count integer;
BEGIN
  SELECT count(*)::integer
    INTO claim_count
    FROM public.meetup_arrangement_claims AS claims
   WHERE claims.meetup_id = '50000000-0000-0000-0000-0000000000a6';
  IF claim_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL 16j: rejected relationship calls changed the claim ledger';
  END IF;
END $$;

RESET role;
ROLLBACK;
