-- Phase 2 S2: atomic meetup state transitions, safety gates, and grants.
--
-- This is a plain SQL acceptance script (not pgTAP).  It is intentionally
-- self-contained and rolls back all fixtures at the end.  Run it after all
-- migrations with psql -v ON_ERROR_STOP=1.

BEGIN;

-- N-14 is a distinct failure scenario; N-05 must not be reused for it.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.notification_scenarios
    WHERE scenario_id = 'N-14'
      AND title = 'Meetup scheduling needs attention'
  ) THEN
    RAISE EXCEPTION 'FAIL S2: N-14 notification scenario is missing';
  END IF;
  RAISE NOTICE 'PASS S2: N-14 notification scenario is seeded';
END $$;

-- SECURITY DEFINER transition RPCs are not a client-facing API.  Naming all
-- three roles is important on hosted Supabase, where revoking PUBLIC alone
-- does not remove a role-specific default EXECUTE grant.
DO $$
BEGIN
  IF has_function_privilege('anon', 'public.create_or_match_meetup_intent(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL S2: anon can execute create_or_match_meetup_intent';
  END IF;
  IF has_function_privilege('authenticated', 'public.create_or_match_meetup_intent(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL S2: authenticated can execute create_or_match_meetup_intent';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.create_or_match_meetup_intent(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL S2: service_role cannot execute create_or_match_meetup_intent';
  END IF;
  IF has_function_privilege('anon', 'public.record_meetup_proposal_response(uuid,uuid,uuid,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL S2: anon can execute record_meetup_proposal_response';
  END IF;
  IF has_function_privilege('authenticated', 'public.record_meetup_proposal_response(uuid,uuid,uuid,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL S2: authenticated can execute record_meetup_proposal_response';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.record_meetup_proposal_response(uuid,uuid,uuid,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL S2: service_role cannot execute record_meetup_proposal_response';
  END IF;
  IF to_regprocedure('public.can_read_unblocked_meetup_match(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL S2: public meetup visibility helper must not exist';
  END IF;
  IF to_regprocedure('wingward_private.can_read_unblocked_meetup_match(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL S2: private meetup visibility helper is missing';
  END IF;
  IF has_function_privilege('anon', 'wingward_private.can_read_unblocked_meetup_match(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL S2: anon can execute private meetup visibility helper';
  END IF;
  IF NOT has_function_privilege('authenticated', 'wingward_private.can_read_unblocked_meetup_match(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL S2: authenticated cannot execute private meetup visibility helper for RLS';
  END IF;
  IF NOT has_function_privilege('service_role', 'wingward_private.can_read_unblocked_meetup_match(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL S2: service_role cannot execute private meetup visibility helper';
  END IF;
  IF has_schema_privilege('anon', 'wingward_private', 'USAGE')
     OR has_schema_privilege('authenticated', 'wingward_private', 'USAGE')
     OR has_schema_privilege('anon', 'wingward_private', 'CREATE')
     OR has_schema_privilege('authenticated', 'wingward_private', 'CREATE') THEN
    RAISE EXCEPTION 'FAIL S2: API role can use the private meetup helper schema';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_namespace AS schema_row
    CROSS JOIN LATERAL pg_catalog.aclexplode(
      COALESCE(schema_row.nspacl, ARRAY[]::aclitem[])
    ) AS schema_acl
    WHERE schema_row.nspname = 'wingward_private'
      AND schema_acl.grantee = 0
      AND schema_acl.privilege_type IN ('USAGE', 'CREATE')
  ) THEN
    RAISE EXCEPTION 'FAIL S2: PUBLIC can use the private meetup helper schema';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'meetups'
      AND cmd = 'INSERT'
  ) THEN
    RAISE EXCEPTION 'FAIL S2: authenticated direct meetup INSERT policy still exists';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'meetup_proposal_responses'
      AND cmd = 'INSERT'
  ) THEN
    RAISE EXCEPTION 'FAIL S2: authenticated direct proposal-response INSERT policy still exists';
  END IF;
  RAISE NOTICE 'PASS S2: transition RPC grants are service_role-only';
END $$;

-- Fixture users are created through the signup trigger, then moved to stable
-- profile IDs exactly like the existing SQL acceptance scripts.
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000a4', 'wingward-test-a4@example.invalid'),
  ('00000000-0000-0000-0000-0000000000b4', 'wingward-test-b4@example.invalid'),
  ('00000000-0000-0000-0000-0000000000c4', 'wingward-test-c4@example.invalid'),
  ('00000000-0000-0000-0000-0000000000d4', 'wingward-test-d4@example.invalid');

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000a4',
    nickname = 'Test A4',
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
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a4';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b4',
    nickname = 'Test B4',
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
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b4';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000c4',
    nickname = 'Test C4',
    birth_date = '1990-01-01',
    age_verified_at = '2026-08-24T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c4';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000d4',
    nickname = 'Test D4',
    birth_date = '1990-01-01',
    age_verified_at = '2026-08-24T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000d4';

INSERT INTO public.matches (id, user_a_id, user_b_id, status) VALUES
  ('20000000-0000-0000-0000-0000000000a4',
   '10000000-0000-0000-0000-0000000000a4',
   '10000000-0000-0000-0000-0000000000b4',
   'direct_chat_active'),
  ('20000000-0000-0000-0000-0000000000c4',
   '10000000-0000-0000-0000-0000000000c4',
   '10000000-0000-0000-0000-0000000000d4',
   'direct_chat_active');

INSERT INTO public.direct_chat_rooms (id, match_id, status) VALUES
  ('40000000-0000-0000-0000-0000000000a4',
   '20000000-0000-0000-0000-0000000000a4',
   'active'),
  ('40000000-0000-0000-0000-0000000000c4',
   '20000000-0000-0000-0000-0000000000c4',
   'active');

-- The first intent creates one pending row and exposes no counterpart state.
SET LOCAL role = 'service_role';

-- Intent is unavailable unless both the match and its room are actively in
-- direct chat. Identity verification deliberately is not an intent gate.
UPDATE public.matches
SET status = 'pending'
WHERE id = '20000000-0000-0000-0000-0000000000c4';
DO $$
DECLARE
  result record;
BEGIN
  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF result.outcome <> 'not_found' THEN
    RAISE EXCEPTION 'FAIL S2: intent was accepted outside direct_chat_active match state';
  END IF;
  RAISE NOTICE 'PASS S2: inactive match rejects meetup intent';
END $$;

UPDATE public.matches
SET status = 'direct_chat_active'
WHERE id = '20000000-0000-0000-0000-0000000000c4';
UPDATE public.direct_chat_rooms
SET status = 'closed'
WHERE match_id = '20000000-0000-0000-0000-0000000000c4';
DO $$
DECLARE
  result record;
BEGIN
  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF result.outcome <> 'not_found' THEN
    RAISE EXCEPTION 'FAIL S2: intent was accepted with a closed direct chat room';
  END IF;
  RAISE NOTICE 'PASS S2: closed direct chat room rejects meetup intent';
END $$;

UPDATE public.direct_chat_rooms
SET status = 'active'
WHERE match_id = '20000000-0000-0000-0000-0000000000c4';
DO $$
DECLARE
  result record;
BEGIN
  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF result.outcome <> 'created' OR result.status <> 'intent_pending' THEN
    RAISE EXCEPTION 'FAIL S2: unverified identity incorrectly blocked free meetup intent';
  END IF;
  DELETE FROM public.meetups WHERE id = result.meetup_id;
  RAISE NOTICE 'PASS S2: identity verification is not required for meetup intent';
END $$;

-- An expired one-sided intent must not be reused as the counterpart's
-- consent. Expire once at the exact boundary and once in the past, and verify
-- that both the counterpart and the original initiator receive a fresh
-- one-sided row in the same call. The retry is idempotent, and only the fresh
-- row can later become mutual.
SAVEPOINT expired_intent_probe;
DO $$
DECLARE
  first_intent record;
  counterpart_renewal record;
  counterpart_repeat record;
  counterpart_match record;
  initiator_first record;
  initiator_renewal record;
  initiator_repeat record;
  initiator_match record;
  old_status text;
  old_initiator_id uuid;
  old_intent_a_at timestamptz;
  old_intent_b_at timestamptz;
  new_status text;
  new_initiator_id uuid;
  new_intent_a_at timestamptz;
  new_intent_b_at timestamptz;
BEGIN
  SELECT * INTO first_intent
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF first_intent.outcome IS DISTINCT FROM 'created'
     OR first_intent.status IS DISTINCT FROM 'intent_pending'
     OR first_intent.matched IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL S2: expiry probe did not create a one-sided intent';
  END IF;

  UPDATE public.meetups
  SET intent_expires_at = pg_catalog.now()
  WHERE id = first_intent.meetup_id;
  SELECT * INTO counterpart_renewal
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000d4'
  );
  SELECT status, initiator_id, intent_a_at, intent_b_at
    INTO old_status, old_initiator_id, old_intent_a_at, old_intent_b_at
  FROM public.meetups
  WHERE id = first_intent.meetup_id;
  SELECT status, initiator_id, intent_a_at, intent_b_at
    INTO new_status, new_initiator_id, new_intent_a_at, new_intent_b_at
  FROM public.meetups
  WHERE id = counterpart_renewal.meetup_id;
  IF counterpart_renewal.outcome IS DISTINCT FROM 'created'
     OR counterpart_renewal.status IS DISTINCT FROM 'intent_pending'
     OR counterpart_renewal.meetup_id IS NOT DISTINCT FROM first_intent.meetup_id
     OR counterpart_renewal.initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000d4'::uuid
     OR counterpart_renewal.matched IS DISTINCT FROM false
     OR old_status IS DISTINCT FROM 'expired'
     OR old_initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000c4'::uuid
     OR old_intent_a_at IS NULL
     OR old_intent_b_at IS NOT NULL
     OR new_status IS DISTINCT FROM 'intent_pending'
     OR new_initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000d4'::uuid
     OR new_intent_a_at IS NOT NULL
     OR new_intent_b_at IS NULL THEN
    RAISE EXCEPTION 'FAIL S2: exact-boundary expiry did not create a fresh counterpart-only intent';
  END IF;

  SELECT * INTO counterpart_repeat
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000d4'
  );
  IF counterpart_repeat.outcome IS DISTINCT FROM 'already_active'
     OR counterpart_repeat.meetup_id IS DISTINCT FROM counterpart_renewal.meetup_id
     OR counterpart_repeat.status IS DISTINCT FROM 'intent_pending'
     OR counterpart_repeat.initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000d4'::uuid
     OR counterpart_repeat.matched IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL S2: counterpart retry was not idempotent on the fresh intent';
  END IF;

  SELECT * INTO counterpart_match
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  SELECT status, intent_a_at, intent_b_at
    INTO new_status, new_intent_a_at, new_intent_b_at
  FROM public.meetups
  WHERE id = counterpart_renewal.meetup_id;
  IF counterpart_match.outcome IS DISTINCT FROM 'matched'
     OR counterpart_match.status IS DISTINCT FROM 'intent_matched'
     OR counterpart_match.meetup_id IS DISTINCT FROM counterpart_renewal.meetup_id
     OR counterpart_match.initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000d4'::uuid
     OR counterpart_match.matched IS DISTINCT FROM true
     OR new_status IS DISTINCT FROM 'intent_matched'
     OR new_intent_a_at IS NULL
     OR new_intent_b_at IS NULL
     OR EXISTS (
       SELECT 1
       FROM public.meetups
       WHERE id = first_intent.meetup_id
         AND status = 'intent_matched'
     ) THEN
    RAISE EXCEPTION 'FAIL S2: reciprocal intent matched the expired row or lost fresh-row timestamps';
  END IF;

  -- End the first synthetic lifecycle so the same C/D fixture can cover an
  -- expired intent renewed by its original initiator.
  UPDATE public.meetups
  SET status = 'cancelled', updated_at = pg_catalog.now()
  WHERE id = counterpart_renewal.meetup_id;

  SELECT * INTO initiator_first
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF initiator_first.outcome IS DISTINCT FROM 'created'
     OR initiator_first.status IS DISTINCT FROM 'intent_pending'
     OR initiator_first.matched IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL S2: original-initiator expiry probe did not create a pending intent';
  END IF;
  UPDATE public.meetups
  SET intent_expires_at = pg_catalog.now() - pg_catalog.interval '1 second'
  WHERE id = initiator_first.meetup_id;
  SELECT * INTO initiator_renewal
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  SELECT status, initiator_id, intent_a_at, intent_b_at
    INTO old_status, old_initiator_id, old_intent_a_at, old_intent_b_at
  FROM public.meetups
  WHERE id = initiator_first.meetup_id;
  SELECT status, initiator_id, intent_a_at, intent_b_at
    INTO new_status, new_initiator_id, new_intent_a_at, new_intent_b_at
  FROM public.meetups
  WHERE id = initiator_renewal.meetup_id;
  IF initiator_renewal.outcome IS DISTINCT FROM 'created'
     OR initiator_renewal.status IS DISTINCT FROM 'intent_pending'
     OR initiator_renewal.meetup_id IS NOT DISTINCT FROM initiator_first.meetup_id
     OR initiator_renewal.initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000c4'::uuid
     OR initiator_renewal.matched IS DISTINCT FROM false
     OR old_status IS DISTINCT FROM 'expired'
     OR old_initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000c4'::uuid
     OR old_intent_a_at IS NULL
     OR old_intent_b_at IS NOT NULL
     OR new_status IS DISTINCT FROM 'intent_pending'
     OR new_initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000c4'::uuid
     OR new_intent_a_at IS NULL
     OR new_intent_b_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL S2: past expiry did not create a fresh initiator-only intent';
  END IF;

  SELECT * INTO initiator_repeat
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF initiator_repeat.outcome IS DISTINCT FROM 'already_active'
     OR initiator_repeat.meetup_id IS DISTINCT FROM initiator_renewal.meetup_id
     OR initiator_repeat.status IS DISTINCT FROM 'intent_pending'
     OR initiator_repeat.initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000c4'::uuid
     OR initiator_repeat.matched IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL S2: original-initiator retry was not idempotent on the fresh intent';
  END IF;

  SELECT * INTO initiator_match
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000d4'
  );
  SELECT status, intent_a_at, intent_b_at
    INTO new_status, new_intent_a_at, new_intent_b_at
  FROM public.meetups
  WHERE id = initiator_renewal.meetup_id;
  IF initiator_match.outcome IS DISTINCT FROM 'matched'
     OR initiator_match.status IS DISTINCT FROM 'intent_matched'
     OR initiator_match.meetup_id IS DISTINCT FROM initiator_renewal.meetup_id
     OR initiator_match.initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000c4'::uuid
     OR initiator_match.matched IS DISTINCT FROM true
     OR new_status IS DISTINCT FROM 'intent_matched'
     OR new_intent_a_at IS NULL
     OR new_intent_b_at IS NULL
     OR EXISTS (
       SELECT 1
       FROM public.meetups
       WHERE id = initiator_first.meetup_id
         AND status = 'intent_matched'
     ) THEN
    RAISE EXCEPTION 'FAIL S2: reciprocal intent matched the expired original-initiator row';
  END IF;
  RAISE NOTICE 'PASS S2: expired intents renew for each caller, retries are idempotent, and only fresh rows match';
END $$;
ROLLBACK TO SAVEPOINT expired_intent_probe;

DO $$
DECLARE
  result record;
  pending_count integer;
BEGIN
  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4'
  );
  IF result.outcome <> 'created' OR result.status <> 'intent_pending' OR result.matched THEN
    RAISE EXCEPTION 'FAIL S2: first intent did not create intent_pending';
  END IF;
  SELECT count(*) INTO pending_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4'
    AND status = 'intent_pending';
  IF pending_count <> 1 THEN
    RAISE EXCEPTION 'FAIL S2: expected one active pending meetup, got %', pending_count;
  END IF;
  RAISE NOTICE 'PASS S2: first intent is idempotently created';
END $$;

-- The additive preference checks reject unknown enum values while leaving the
-- existing self-only RLS model intact.
DO $$
BEGIN
  BEGIN
    INSERT INTO public.meetup_preferences (user_id, budget_band)
    VALUES ('10000000-0000-0000-0000-0000000000a4', 'enterprise');
    RAISE EXCEPTION 'FAIL S2: invalid budget band was accepted';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS S2: preference budget enum is constrained';
  END;
  BEGIN
    INSERT INTO public.meetup_preferences (user_id, formats)
    VALUES ('10000000-0000-0000-0000-0000000000a4', ARRAY['cafe', 'unknown']);
    RAISE EXCEPTION 'FAIL S2: invalid preference format was accepted';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS S2: preference format enum is constrained';
  END;
END $$;

-- The non-initiator must not see the one-sided row through RLS.
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000b4"}';
DO $$
DECLARE
  visible_count integer;
BEGIN
  SELECT count(*) INTO visible_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: counterpart saw one-sided meetup (% row(s))', visible_count;
  END IF;
  RAISE NOTICE 'PASS S2: one-sided intent remains hidden';
END $$;

RESET request.jwt.claims;
SET LOCAL role = 'service_role';
DO $$
DECLARE
  result record;
  repeated record;
  matched_count integer;
  pending_expiry timestamptz;
BEGIN
  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4'
  );
  IF result.outcome <> 'matched' OR result.status <> 'intent_matched' OR NOT result.matched THEN
    RAISE EXCEPTION 'FAIL S2: second intent did not atomically match';
  END IF;
  SELECT count(*) INTO matched_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4'
    AND status = 'intent_matched';
  IF matched_count <> 1 THEN
    RAISE EXCEPTION 'FAIL S2: expected one intent_matched meetup, got %', matched_count;
  END IF;
  SELECT intent_expires_at INTO pending_expiry
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  IF pending_expiry IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL S2: matched meetup retained pending intent expiry';
  END IF;

  SELECT * INTO repeated
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4'
  );
  IF repeated.outcome <> 'already_active' OR repeated.status <> 'intent_matched' THEN
    RAISE EXCEPTION 'FAIL S2: repeated intent was not idempotent';
  END IF;
  RAISE NOTICE 'PASS S2: second intent is atomic and repeated intent is idempotent';
END $$;

-- Clients cannot bypass the atomic intent function with a direct table write.
RESET role;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000c4"}';
DO $$
BEGIN
  BEGIN
    INSERT INTO public.meetups (match_id, initiator_id, status)
    VALUES (
      '20000000-0000-0000-0000-0000000000c4',
      '10000000-0000-0000-0000-0000000000c4',
      'intent_pending'
    );
    RAISE EXCEPTION 'FAIL S2: authenticated bypassed the atomic intent RPC';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS S2: authenticated direct meetup INSERT is denied';
  END;
END $$;

RESET request.jwt.claims;
SET LOCAL role = 'service_role';

-- A block in either direction is a hard stop, even when the match exists.
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-0000000000d4', '10000000-0000-0000-0000-0000000000c4');
DO $$
DECLARE
  result record;
  meetup_count integer;
BEGIN
  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF result.outcome <> 'blocked' THEN
    RAISE EXCEPTION 'FAIL S2: blocked pair intent was accepted';
  END IF;
  SELECT count(*) INTO meetup_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000c4';
  IF meetup_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: blocked pair created a meetup row';
  END IF;
  RAISE NOTICE 'PASS S2: blocked pair is rejected in either direction';
END $$;

-- Turn the matched fixture into a proposal and exercise the response/confirm
-- transition. All candidates use only the fields allowed to leave the API.
INSERT INTO public.meetup_proposals (
  id, meetup_id, attempt_number, candidates, expires_at
)
VALUES (
  '30000000-0000-0000-0000-0000000000a4',
  (SELECT id FROM public.meetups WHERE match_id = '20000000-0000-0000-0000-0000000000a4'),
  1,
  pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '2 days') AT TIME ZONE 'Asia/Tokyo',
        'YYYY-MM-DD"T"HH24:MI:SS'
      ) || '+09:00',
      'timezone', 'Asia/Tokyo', 'area', 'Tokyo/Chiyoda', 'format', 'cafe', 'rationale', 'A calm public option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '3 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS'
      ) || 'Z',
      'timezone', 'UTC', 'area', 'Tokyo/Chiyoda', 'format', 'meal', 'rationale', 'A convenient public option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '4 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS'
      ) || 'Z',
      'timezone', 'UTC', 'area', 'Tokyo/Chiyoda', 'format', 'online', 'rationale', 'A low-friction option.'
    )
  ),
  pg_catalog.now() + pg_catalog.interval '2 days'
);
UPDATE public.meetups
SET status = 'proposed', proposal_expires_at = pg_catalog.now() + pg_catalog.interval '2 days'
WHERE match_id = '20000000-0000-0000-0000-0000000000a4';

-- The candidate-count constraint is independent of the response RPC, so
-- exercise the direct-write backstop against a real meetup row as well.
DO $$
DECLARE
  meetup_id_value uuid;
BEGIN
  SELECT id INTO meetup_id_value
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  BEGIN
    INSERT INTO public.meetup_proposals (meetup_id, attempt_number, candidates)
    VALUES (meetup_id_value, 2, '[]'::jsonb);
    RAISE EXCEPTION 'FAIL S2: a proposal with fewer than three candidates was accepted';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS S2: proposal candidate-count constraint rejects short arrays';
  END;
END $$;

-- Identity status and timestamp are both required before even the first
-- proposal response is persisted. Test each half of the compound gate.
UPDATE public.user_profiles
SET identity_verification_status = 'pending'
WHERE id = '10000000-0000-0000-0000-0000000000b4';
DO $$
DECLARE
  meetup_id_value uuid;
  result record;
  response_count integer;
BEGIN
  SELECT id INTO meetup_id_value
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4',
    0
  );
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  IF result.outcome <> 'invalid_state' OR response_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: non-verified identity status allowed a proposal response';
  END IF;
  RAISE NOTICE 'PASS S2: non-verified identity status rejects proposal response';
END $$;

UPDATE public.user_profiles
SET identity_verification_status = 'verified', identity_verified_at = NULL
WHERE id = '10000000-0000-0000-0000-0000000000b4';
DO $$
DECLARE
  meetup_id_value uuid;
  result record;
  response_count integer;
BEGIN
  SELECT id INTO meetup_id_value
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4',
    0
  );
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  IF result.outcome <> 'invalid_state' OR response_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: missing identity_verified_at allowed a proposal response';
  END IF;
  RAISE NOTICE 'PASS S2: missing identity_verified_at rejects proposal response';
END $$;

UPDATE public.user_profiles
SET identity_verified_at = '2026-08-24T00:00:00Z'
WHERE id = '10000000-0000-0000-0000-0000000000b4';

-- An offsetless candidate must be rejected even when the session timezone
-- would make its direct timestamptz cast look valid. Keep the fixture rows
-- unchanged so this covers the no-write failure boundary as well.
SAVEPOINT offsetless_starts_at_probe;
SET LOCAL timezone = 'America/Los_Angeles';
DO $$
DECLARE
  meetup_id_value uuid;
  result record;
  before_status text;
  stored_status text;
  before_response_count integer;
  response_count integer;
  offsetless_starts_at text;
BEGIN
  SELECT id, status INTO meetup_id_value, before_status
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO before_response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';

  offsetless_starts_at := pg_catalog.to_char(
    (pg_catalog.now() + pg_catalog.interval '2 days') AT TIME ZONE 'Asia/Tokyo',
    'YYYY-MM-DD"T"HH24:MI:SS'
  );
  UPDATE public.meetup_proposals
  SET candidates = pg_catalog.jsonb_set(
    pg_catalog.jsonb_set(
      candidates,
      ARRAY['0', 'starts_at'],
      pg_catalog.to_jsonb(offsetless_starts_at),
      false
    ),
    ARRAY['0', 'timezone'],
    pg_catalog.to_jsonb('Asia/Tokyo'::text),
    false
  )
  WHERE id = '30000000-0000-0000-0000-0000000000a4';

  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4',
    0
  );
  SELECT status INTO stored_status
  FROM public.meetups
  WHERE id = meetup_id_value;
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';

  IF result.outcome IS DISTINCT FROM 'invalid_input'
     OR stored_status IS DISTINCT FROM before_status
     OR response_count IS DISTINCT FROM before_response_count THEN
    RAISE EXCEPTION 'FAIL S2: offsetless candidate was accepted or changed rows';
  END IF;
  RAISE NOTICE 'PASS S2: offsetless candidate is rejected in non-UTC session without mutation';
END $$;
ROLLBACK TO SAVEPOINT offsetless_starts_at_probe;
SET LOCAL timezone = 'UTC';

-- A discarded proposal cannot confirm OR expire the current attempt. Restore
-- the original fixture afterwards so the happy path still tests attempt 1.
SAVEPOINT stale_proposal_probe;
DO $$
DECLARE
  meetup_id_value uuid;
  result record;
  stored_status text;
  response_count integer;
BEGIN
  SELECT id INTO meetup_id_value FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  PERFORM public.record_meetup_proposal_response(
    meetup_id_value, '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4', 0
  );
  INSERT INTO public.meetup_proposals (id, meetup_id, attempt_number, candidates, expires_at)
  SELECT '30000000-0000-0000-0000-0000000000b4', meetup_id, 2, candidates,
    pg_catalog.now() + pg_catalog.interval '2 days'
  FROM public.meetup_proposals WHERE id = '30000000-0000-0000-0000-0000000000a4';
  UPDATE public.meetups SET arrange_attempt_count = 2 WHERE id = meetup_id_value;
  UPDATE public.meetup_proposals SET expires_at = NULL
  WHERE id = '30000000-0000-0000-0000-0000000000a4';

  SELECT * INTO result FROM public.record_meetup_proposal_response(
    meetup_id_value, '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4', 0
  );
  SELECT status INTO stored_status FROM public.meetups WHERE id = meetup_id_value;
  SELECT count(*) INTO response_count FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  IF result.outcome IS DISTINCT FROM 'not_found'
     OR stored_status IS DISTINCT FROM 'proposed' OR response_count <> 1 THEN
    RAISE EXCEPTION 'FAIL S2: superseded proposal confirmed or rewrote responses';
  END IF;

  UPDATE public.meetup_proposals SET expires_at = pg_catalog.now() - pg_catalog.interval '1 day'
  WHERE id = '30000000-0000-0000-0000-0000000000a4';
  SELECT * INTO result FROM public.record_meetup_proposal_response(
    meetup_id_value, '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4', 0
  );
  SELECT status INTO stored_status FROM public.meetups WHERE id = meetup_id_value;
  IF result.outcome IS DISTINCT FROM 'not_found' OR stored_status IS DISTINCT FROM 'proposed' THEN
    RAISE EXCEPTION 'FAIL S2: stale expired proposal expired the live meetup';
  END IF;
  RAISE NOTICE 'PASS S2: superseded proposals cannot confirm or expire live attempts';
END $$;
ROLLBACK TO SAVEPOINT stale_proposal_probe;

-- A live latest proposal expires at the boundary when expires_at equals now.
-- This is separate from the stale-attempt guard above and must not write a
-- response or confirmation while transitioning the meetup to expired.
SAVEPOINT live_proposal_expiry_probe;
DO $$
DECLARE
  meetup_id_value uuid;
  result record;
  stored_status text;
  stored_proposal_expiry timestamptz;
  confirmed_start timestamptz;
  response_count integer;
BEGIN
  SELECT id INTO meetup_id_value
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  UPDATE public.meetup_proposals
  SET expires_at = pg_catalog.now()
  WHERE id = '30000000-0000-0000-0000-0000000000a4';
  UPDATE public.meetups
  SET proposal_expires_at = pg_catalog.now()
  WHERE id = meetup_id_value;

  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4',
    0
  );
  SELECT status, proposal_expires_at, confirmed_start_at
    INTO stored_status, stored_proposal_expiry, confirmed_start
  FROM public.meetups
  WHERE id = meetup_id_value;
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';

  IF result.outcome IS DISTINCT FROM 'expired'
     OR result.status IS DISTINCT FROM 'expired'
     OR stored_status IS DISTINCT FROM 'expired'
     OR stored_proposal_expiry IS NOT NULL
     OR confirmed_start IS NOT NULL
     OR response_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL S2: live proposal expiry boundary allowed response or confirmation';
  END IF;
  RAISE NOTICE 'PASS S2: live proposal expires at boundary without response or confirmation';
END $$;
ROLLBACK TO SAVEPOINT live_proposal_expiry_probe;

-- The no-block/closed-room state persists after unblocking and must not allow
-- a remaining participant response to confirm an in-person meeting.
SAVEPOINT closed_response_probe;
DO $$
DECLARE
  meetup_id_value uuid;
  result record;
  stored_status text;
  response_count integer;
BEGIN
  SELECT id INTO meetup_id_value FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  PERFORM public.record_meetup_proposal_response(
    meetup_id_value, '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4', 0
  );
  UPDATE public.direct_chat_rooms SET status = 'closed'
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  SELECT * INTO result FROM public.record_meetup_proposal_response(
    meetup_id_value, '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4', 0
  );
  SELECT status INTO stored_status FROM public.meetups WHERE id = meetup_id_value;
  SELECT count(*) INTO response_count FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  IF result.outcome IS DISTINCT FROM 'not_found'
     OR stored_status IS DISTINCT FROM 'proposed' OR response_count <> 1 THEN
    RAISE EXCEPTION 'FAIL S2: closed room allowed a response or confirmation';
  END IF;
  RAISE NOTICE 'PASS S2: closed room rejects proposal responses without changing state';
END $$;
ROLLBACK TO SAVEPOINT closed_response_probe;

-- A block added after one participant responds must stop the counterpart in
-- either direction without removing the original response or confirming the
-- meetup. Keep the room active so this isolates the block gate.
-- The post-lock mutual helper now returns the generic not_found before the legacy block outcome.
SAVEPOINT blocked_response_probe;
DO $$
DECLARE
  meetup_id_value uuid;
  result record;
  original_indexes integer[];
  selected_indexes integer[];
  original_response text;
  stored_response text;
  stored_status text;
  room_status text;
  confirmed_start timestamptz;
  response_count integer;
BEGIN
  SELECT id INTO meetup_id_value
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';

  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4',
    0
  );
  SELECT selected_candidate_indexes, response
    INTO original_indexes, original_response
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4'
    AND user_id = '10000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  IF result.outcome IS DISTINCT FROM 'accepted'
     OR result.status IS DISTINCT FROM 'proposed'
     OR original_indexes IS DISTINCT FROM ARRAY[0]
     OR original_response IS DISTINCT FROM 'selected'
     OR response_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL S2: block probe could not create the first response';
  END IF;

  INSERT INTO public.blocks (blocker_id, blocked_id)
  VALUES (
    '10000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4'
  );
  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4',
    0
  );
  SELECT status, confirmed_start_at
    INTO stored_status, confirmed_start
  FROM public.meetups
  WHERE id = meetup_id_value;
  SELECT status INTO room_status
  FROM public.direct_chat_rooms
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  SELECT selected_candidate_indexes, response
    INTO selected_indexes, stored_response
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4'
    AND user_id = '10000000-0000-0000-0000-0000000000a4';
  IF result.outcome IS DISTINCT FROM 'not_found'
     OR result.status IS NOT NULL
     OR stored_status IS DISTINCT FROM 'proposed'
     OR room_status IS DISTINCT FROM 'active'
     OR confirmed_start IS NOT NULL
     OR response_count IS DISTINCT FROM 1
     OR selected_indexes IS DISTINCT FROM original_indexes
     OR stored_response IS DISTINCT FROM original_response THEN
    RAISE EXCEPTION 'FAIL S2: A->B block allowed response mutation or confirmation';
  END IF;
  DELETE FROM public.blocks
  WHERE blocker_id = '10000000-0000-0000-0000-0000000000a4'
    AND blocked_id = '10000000-0000-0000-0000-0000000000b4';

  INSERT INTO public.blocks (blocker_id, blocked_id)
  VALUES (
    '10000000-0000-0000-0000-0000000000b4',
    '10000000-0000-0000-0000-0000000000a4'
  );
  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4',
    0
  );
  SELECT status, confirmed_start_at
    INTO stored_status, confirmed_start
  FROM public.meetups
  WHERE id = meetup_id_value;
  SELECT status INTO room_status
  FROM public.direct_chat_rooms
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  SELECT selected_candidate_indexes, response
    INTO selected_indexes, stored_response
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4'
    AND user_id = '10000000-0000-0000-0000-0000000000a4';
  IF result.outcome IS DISTINCT FROM 'not_found'
     OR result.status IS NOT NULL
     OR stored_status IS DISTINCT FROM 'proposed'
     OR room_status IS DISTINCT FROM 'active'
     OR confirmed_start IS NOT NULL
     OR response_count IS DISTINCT FROM 1
     OR selected_indexes IS DISTINCT FROM original_indexes
     OR stored_response IS DISTINCT FROM original_response THEN
    RAISE EXCEPTION 'FAIL S2: B->A block allowed response mutation or confirmation';
  END IF;
  RAISE NOTICE 'PASS S2: both block directions preserve the first response and proposed state';
END $$;
ROLLBACK TO SAVEPOINT blocked_response_probe;

-- Clients cannot bypass the identity/state/locking checks with a direct row.
RESET role;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a4"}';
DO $$
BEGIN
  BEGIN
    INSERT INTO public.meetup_proposal_responses (
      proposal_id, user_id, selected_candidate_indexes, response
    ) VALUES (
      '30000000-0000-0000-0000-0000000000a4',
      '10000000-0000-0000-0000-0000000000a4',
      ARRAY[0],
      'selected'
    );
    RAISE EXCEPTION 'FAIL S2: authenticated bypassed the atomic response RPC';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS S2: authenticated direct proposal-response INSERT is denied';
  END;
END $$;

RESET request.jwt.claims;
SET LOCAL role = 'service_role';

-- One-sided visibility is based on the two intent timestamps, not the
-- current status. Exercise a real lazy-expiry transition, an explicit
-- cancellation, and a mutual row, then attach dependent rows to each state.
-- The whole probe rolls back so the earlier blocked-pair fixture is restored.
SAVEPOINT terminal_one_sided_visibility_probe;
DO $$
DECLARE
  expired_meetup_id uuid;
  fresh_meetup_id uuid;
  cancelled_meetup_id uuid;
  mutual_meetup_id uuid;
  result record;
BEGIN
  -- The earlier blocked-pair fixture is still inside this transaction.  This
  -- savepoint-local delete lets the synthetic visibility rows exercise the
  -- same C/D pair; rollback below restores the block fixture unchanged.
  DELETE FROM public.blocks
  WHERE (blocker_id = '10000000-0000-0000-0000-0000000000c4'
         AND blocked_id = '10000000-0000-0000-0000-0000000000d4')
     OR (blocker_id = '10000000-0000-0000-0000-0000000000d4'
         AND blocked_id = '10000000-0000-0000-0000-0000000000c4');

  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF result.outcome IS DISTINCT FROM 'created'
     OR result.status IS DISTINCT FROM 'intent_pending' THEN
    RAISE EXCEPTION 'FAIL S2: lazy-expiry visibility probe did not create a pending intent';
  END IF;
  expired_meetup_id := result.meetup_id;

  UPDATE public.meetups
  SET intent_expires_at = pg_catalog.now()
  WHERE id = expired_meetup_id;
  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000d4'
  );
  IF result.outcome IS DISTINCT FROM 'created'
     OR result.status IS DISTINCT FROM 'intent_pending'
     OR result.meetup_id IS NOT DISTINCT FROM expired_meetup_id
     OR result.initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000d4'::uuid
     OR result.matched IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL S2: lazy-expiry visibility probe did not create a fresh counterpart-only intent';
  END IF;
  fresh_meetup_id := result.meetup_id;
  IF NOT EXISTS (
    SELECT 1
    FROM public.meetups
    WHERE id = fresh_meetup_id
      AND status = 'intent_pending'
      AND initiator_id = '10000000-0000-0000-0000-0000000000d4'::uuid
      AND intent_a_at IS NULL
      AND intent_b_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL S2: fresh counterpart intent did not retain only its own timestamp';
  END IF;

  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000d4'
  );
  IF result.outcome IS DISTINCT FROM 'already_active'
     OR result.meetup_id IS DISTINCT FROM fresh_meetup_id
     OR result.status IS DISTINCT FROM 'intent_pending'
     OR result.initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000d4'::uuid
     OR result.matched IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL S2: fresh counterpart intent retry was not idempotent';
  END IF;

  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF result.outcome IS DISTINCT FROM 'matched'
     OR result.meetup_id IS DISTINCT FROM fresh_meetup_id
     OR result.status IS DISTINCT FROM 'intent_matched'
     OR result.initiator_id IS DISTINCT FROM '10000000-0000-0000-0000-0000000000d4'::uuid
     OR result.matched IS DISTINCT FROM true
     OR EXISTS (
       SELECT 1
       FROM public.meetups
       WHERE id = expired_meetup_id
         AND status = 'intent_matched'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM public.meetups
       WHERE id = fresh_meetup_id
         AND status = 'intent_matched'
         AND intent_a_at IS NOT NULL
         AND intent_b_at IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'FAIL S2: reciprocal intent did not match only the fresh row';
  END IF;

  -- The fresh lifecycle above is asserted before this visibility-only probe
  -- creates its fixed terminal/mutual rows. Delete that unreferenced synthetic
  -- row so the final RLS counts contain exactly one expired, one cancelled,
  -- and one mutual meetup for this pair.
  DELETE FROM public.meetups
  WHERE id = fresh_meetup_id;

  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF result.outcome IS DISTINCT FROM 'created'
     OR result.status IS DISTINCT FROM 'intent_pending' THEN
    RAISE EXCEPTION 'FAIL S2: cancellation visibility probe did not create a pending intent';
  END IF;
  cancelled_meetup_id := result.meetup_id;
  UPDATE public.meetups
  SET status = 'cancelled',
      intent_expires_at = NULL,
      updated_at = pg_catalog.now()
  WHERE id = cancelled_meetup_id;

  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000c4'
  );
  IF result.outcome IS DISTINCT FROM 'created'
     OR result.status IS DISTINCT FROM 'intent_pending' THEN
    RAISE EXCEPTION 'FAIL S2: mutual visibility probe did not create the first intent';
  END IF;
  mutual_meetup_id := result.meetup_id;
  SELECT * INTO result
  FROM public.create_or_match_meetup_intent(
    '20000000-0000-0000-0000-0000000000c4',
    '10000000-0000-0000-0000-0000000000d4'
  );
  IF result.outcome IS DISTINCT FROM 'matched'
     OR result.status IS DISTINCT FROM 'intent_matched' THEN
    RAISE EXCEPTION 'FAIL S2: both intent timestamps did not produce a mutual meetup';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.meetups
    WHERE id = expired_meetup_id
      AND status = 'expired'
      AND intent_a_at IS NOT NULL
      AND intent_b_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL S2: lazy-expired row is not terminal one-sided state';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.meetups
    WHERE id = cancelled_meetup_id
      AND status = 'cancelled'
      AND intent_a_at IS NOT NULL
      AND intent_b_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL S2: cancelled row is not terminal one-sided state';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.meetups
    WHERE id = mutual_meetup_id
      AND status = 'intent_matched'
      AND intent_a_at IS NOT NULL
      AND intent_b_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL S2: mutual row does not carry both intent timestamps';
  END IF;

  INSERT INTO public.meetup_proposals (id, meetup_id, attempt_number, candidates)
  VALUES
    (
      '30000000-0000-0000-0000-0000000000e4',
      expired_meetup_id,
      1,
      '[{}, {}, {}]'::jsonb
    ),
    (
      '30000000-0000-0000-0000-0000000000f4',
      cancelled_meetup_id,
      1,
      '[{}, {}, {}]'::jsonb
    ),
    (
      '30000000-0000-0000-0000-0000000000e5',
      mutual_meetup_id,
      1,
      '[{}, {}, {}]'::jsonb
    );
  INSERT INTO public.meetup_proposal_responses (
    id, proposal_id, user_id, selected_candidate_indexes, response
  )
  VALUES
    (
      '50000000-0000-0000-0000-0000000000e4',
      '30000000-0000-0000-0000-0000000000e4',
      '10000000-0000-0000-0000-0000000000c4',
      ARRAY[0],
      'selected'
    ),
    (
      '50000000-0000-0000-0000-0000000000f4',
      '30000000-0000-0000-0000-0000000000f4',
      '10000000-0000-0000-0000-0000000000c4',
      ARRAY[0],
      'selected'
    ),
    (
      '50000000-0000-0000-0000-0000000000e5',
      '30000000-0000-0000-0000-0000000000e5',
      '10000000-0000-0000-0000-0000000000c4',
      ARRAY[0],
      'selected'
    );
  INSERT INTO public.venue_checkins (id, meetup_id, user_id, method)
  VALUES
    (
      '60000000-0000-0000-0000-0000000000e4',
      expired_meetup_id,
      '10000000-0000-0000-0000-0000000000c4',
      'geofence'
    ),
    (
      '60000000-0000-0000-0000-0000000000f4',
      cancelled_meetup_id,
      '10000000-0000-0000-0000-0000000000c4',
      'geofence'
    ),
    (
      '60000000-0000-0000-0000-0000000000e5',
      mutual_meetup_id,
      '10000000-0000-0000-0000-0000000000c4',
      'geofence'
    );
END $$;

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000d4"}';
DO $$
DECLARE
  terminal_meetup_count integer;
  mutual_meetup_count integer;
  terminal_proposal_count integer;
  mutual_proposal_count integer;
  terminal_response_count integer;
  mutual_response_count integer;
  terminal_checkin_count integer;
  mutual_checkin_count integer;
BEGIN
  SELECT count(*) INTO terminal_meetup_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000c4'
    AND status IN ('expired', 'cancelled');
  SELECT count(*) INTO mutual_meetup_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000c4'
    AND status = 'intent_matched';
  SELECT count(*) INTO terminal_proposal_count
  FROM public.meetup_proposals
  WHERE id IN (
    '30000000-0000-0000-0000-0000000000e4',
    '30000000-0000-0000-0000-0000000000f4'
  );
  SELECT count(*) INTO mutual_proposal_count
  FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000e5';
  SELECT count(*) INTO terminal_response_count
  FROM public.meetup_proposal_responses
  WHERE id IN (
    '50000000-0000-0000-0000-0000000000e4',
    '50000000-0000-0000-0000-0000000000f4'
  );
  SELECT count(*) INTO mutual_response_count
  FROM public.meetup_proposal_responses
  WHERE id = '50000000-0000-0000-0000-0000000000e5';
  SELECT count(*) INTO terminal_checkin_count
  FROM public.venue_checkins
  WHERE id IN (
    '60000000-0000-0000-0000-0000000000e4',
    '60000000-0000-0000-0000-0000000000f4'
  );
  SELECT count(*) INTO mutual_checkin_count
  FROM public.venue_checkins
  WHERE id = '60000000-0000-0000-0000-0000000000e5';

  IF terminal_meetup_count <> 0
     OR mutual_meetup_count <> 1
     OR terminal_proposal_count <> 0
     OR mutual_proposal_count <> 1
     OR terminal_response_count <> 0
     OR mutual_response_count <> 1
     OR terminal_checkin_count <> 0
     OR mutual_checkin_count <> 1 THEN
    RAISE EXCEPTION 'FAIL S2: counterpart saw terminal one-sided meetup or dependent row';
  END IF;
  RAISE NOTICE 'PASS S2: counterpart is denied expired/cancelled one-sided rows and can see mutual rows';
END $$;

RESET request.jwt.claims;
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a4"}';
DO $$
DECLARE
  outsider_meetup_count integer;
  outsider_proposal_count integer;
  outsider_response_count integer;
  outsider_checkin_count integer;
BEGIN
  SELECT count(*) INTO outsider_meetup_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000c4';
  SELECT count(*) INTO outsider_proposal_count
  FROM public.meetup_proposals
  WHERE id IN (
    '30000000-0000-0000-0000-0000000000e4',
    '30000000-0000-0000-0000-0000000000f4',
    '30000000-0000-0000-0000-0000000000e5'
  );
  SELECT count(*) INTO outsider_response_count
  FROM public.meetup_proposal_responses
  WHERE id IN (
    '50000000-0000-0000-0000-0000000000e4',
    '50000000-0000-0000-0000-0000000000f4',
    '50000000-0000-0000-0000-0000000000e5'
  );
  SELECT count(*) INTO outsider_checkin_count
  FROM public.venue_checkins
  WHERE id IN (
    '60000000-0000-0000-0000-0000000000e4',
    '60000000-0000-0000-0000-0000000000f4',
    '60000000-0000-0000-0000-0000000000e5'
  );
  IF outsider_meetup_count <> 0
     OR outsider_proposal_count <> 0
     OR outsider_response_count <> 0
     OR outsider_checkin_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: outsider saw C/D meetup state or dependent row';
  END IF;
  RAISE NOTICE 'PASS S2: outsider is denied C/D meetup state and dependent rows';
END $$;

RESET request.jwt.claims;
SET LOCAL role = 'service_role';
UPDATE public.user_profiles
SET age_verified_at = NULL
WHERE id = '10000000-0000-0000-0000-0000000000c4';
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000d4"}';
DO $$
DECLARE
  revoked_age_meetup_count integer;
  revoked_age_proposal_count integer;
  revoked_age_response_count integer;
  revoked_age_checkin_count integer;
BEGIN
  SELECT count(*) INTO revoked_age_meetup_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000c4';
  SELECT count(*) INTO revoked_age_proposal_count
  FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000e5';
  SELECT count(*) INTO revoked_age_response_count
  FROM public.meetup_proposal_responses
  WHERE id = '50000000-0000-0000-0000-0000000000e5';
  SELECT count(*) INTO revoked_age_checkin_count
  FROM public.venue_checkins
  WHERE id = '60000000-0000-0000-0000-0000000000e5';
  IF revoked_age_meetup_count <> 0
     OR revoked_age_proposal_count <> 0
     OR revoked_age_response_count <> 0
     OR revoked_age_checkin_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: revoked-age participant saw C/D meetup state or dependent row';
  END IF;
  RAISE NOTICE 'PASS S2: revoking one participant age verification hides mutual meetup state';
END $$;

RESET request.jwt.claims;
SET LOCAL role = 'service_role';
UPDATE public.user_profiles
SET age_verified_at = '2026-08-24T00:00:00Z'
WHERE id = '10000000-0000-0000-0000-0000000000c4';

RESET request.jwt.claims;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000c4"}';
DO $$
DECLARE
  terminal_meetup_count integer;
  mutual_meetup_count integer;
  terminal_proposal_count integer;
  mutual_proposal_count integer;
  terminal_response_count integer;
  mutual_response_count integer;
  terminal_checkin_count integer;
  mutual_checkin_count integer;
BEGIN
  SELECT count(*) INTO terminal_meetup_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000c4'
    AND status IN ('expired', 'cancelled');
  SELECT count(*) INTO mutual_meetup_count
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000c4'
    AND status = 'intent_matched';
  SELECT count(*) INTO terminal_proposal_count
  FROM public.meetup_proposals
  WHERE id IN (
    '30000000-0000-0000-0000-0000000000e4',
    '30000000-0000-0000-0000-0000000000f4'
  );
  SELECT count(*) INTO mutual_proposal_count
  FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000e5';
  SELECT count(*) INTO terminal_response_count
  FROM public.meetup_proposal_responses
  WHERE id IN (
    '50000000-0000-0000-0000-0000000000e4',
    '50000000-0000-0000-0000-0000000000f4'
  );
  SELECT count(*) INTO mutual_response_count
  FROM public.meetup_proposal_responses
  WHERE id = '50000000-0000-0000-0000-0000000000e5';
  SELECT count(*) INTO terminal_checkin_count
  FROM public.venue_checkins
  WHERE id IN (
    '60000000-0000-0000-0000-0000000000e4',
    '60000000-0000-0000-0000-0000000000f4'
  );
  SELECT count(*) INTO mutual_checkin_count
  FROM public.venue_checkins
  WHERE id = '60000000-0000-0000-0000-0000000000e5';

  IF terminal_meetup_count <> 2
     OR mutual_meetup_count <> 1
     OR terminal_proposal_count <> 2
     OR mutual_proposal_count <> 1
     OR terminal_response_count <> 2
     OR mutual_response_count <> 1
     OR terminal_checkin_count <> 2
     OR mutual_checkin_count <> 1 THEN
    RAISE EXCEPTION 'FAIL S2: initiator could not see own terminal or mutual meetup rows and dependent rows';
  END IF;
  RAISE NOTICE 'PASS S2: initiator retains visibility for expired/cancelled one-sided and mutual rows';
END $$;

RESET request.jwt.claims;
SET LOCAL role = 'service_role';
ROLLBACK TO SAVEPOINT terminal_one_sided_visibility_probe;

DO $$
DECLARE
  meetup_id_value uuid;
  result record;
  expected_start timestamptz;
  stored_start timestamptz;
  stored_timezone text;
BEGIN
  SELECT id INTO meetup_id_value
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';

  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4',
    0
  );
  IF result.outcome <> 'accepted' OR result.status <> 'proposed' THEN
    RAISE EXCEPTION 'FAIL S2: first proposal response did not stay proposed';
  END IF;

  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4',
    0
  );
  IF result.outcome <> 'confirmed'
     OR result.status <> 'confirmed'
     OR result.confirmed_candidate_index <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: matching proposal responses did not confirm';
  END IF;

  SELECT (candidates -> 0 ->> 'starts_at')::timestamptz INTO expected_start
  FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000a4';
  SELECT confirmed_start_at, confirmed_timezone
    INTO stored_start, stored_timezone
  FROM public.meetups
  WHERE id = meetup_id_value;
  IF stored_start IS DISTINCT FROM expected_start
     OR stored_timezone IS DISTINCT FROM 'Asia/Tokyo' THEN
    RAISE EXCEPTION 'FAIL S2: explicit +09:00 candidate instant or timezone was not preserved';
  END IF;
  RAISE NOTICE 'PASS S2: matching responses confirm and preserve explicit +09:00 candidate instant';
END $$;

-- A confirmed meetup and its dependent rows must disappear for both sides of
-- a block. The blockee cannot see the blocker-owned row through blocks RLS, so
-- each direction is tested in a separate savepoint with both caller claims.
SAVEPOINT blocked_meetup_visibility_probe;
RESET request.jwt.claims;
RESET role;
SET LOCAL role = 'service_role';
DO $$
DECLARE
  meetup_id_value uuid;
  meetup_status text;
  confirmed_start timestamptz;
  confirmed_area text;
  confirmed_timezone text;
BEGIN
  SELECT id, status, confirmed_start_at, area, public.meetups.confirmed_timezone
    INTO meetup_id_value, meetup_status, confirmed_start, confirmed_area, confirmed_timezone
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  IF meetup_id_value IS NULL
     OR meetup_status IS DISTINCT FROM 'confirmed'
     OR confirmed_start IS NULL
     OR confirmed_area IS NULL
     OR confirmed_timezone IS NULL THEN
    RAISE EXCEPTION 'FAIL S2: block visibility fixture is not a confirmed meetup with place/time';
  END IF;

  PERFORM pg_catalog.set_config('test.confirmed_meetup_id', meetup_id_value::text, true);
  INSERT INTO public.venue_checkins (id, meetup_id, user_id, method)
  VALUES (
    '60000000-0000-0000-0000-0000000000a4',
    meetup_id_value,
    '10000000-0000-0000-0000-0000000000a4',
    'geofence'
  );
  -- Moderation closes the chat room after confirmation; the historical meetup
  -- remains readable when no block exists, so this fixture also guards that
  -- the meetup helper is not an active-room gate in disguise.
  UPDATE public.direct_chat_rooms
  SET status = 'closed'
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
END $$;

SAVEPOINT blocked_meetup_a_to_b;
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES (
  '10000000-0000-0000-0000-0000000000a4',
  '10000000-0000-0000-0000-0000000000b4'
);
RESET role;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a4"}';
DO $$
DECLARE
  meetup_id_value uuid := pg_catalog.current_setting('test.confirmed_meetup_id')::uuid;
  helper_error_state text;
  own_block_count integer;
  meetup_count integer;
  proposal_count integer;
  response_count integer;
  checkin_count integer;
BEGIN
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('20000000-0000-0000-0000-0000000000a4');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS helper_error_state = RETURNED_SQLSTATE;
  END;
  SELECT count(*) INTO own_block_count
  FROM public.blocks
  WHERE blocker_id = '10000000-0000-0000-0000-0000000000a4'
    AND blocked_id = '10000000-0000-0000-0000-0000000000b4';
  SELECT count(*) INTO meetup_count
  FROM public.meetups
  WHERE id = meetup_id_value;
  SELECT count(*) INTO proposal_count
  FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO checkin_count
  FROM public.venue_checkins
  WHERE id = '60000000-0000-0000-0000-0000000000a4';
  IF own_block_count <> 1
     OR helper_error_state IS DISTINCT FROM '42501'
     OR meetup_count <> 0
     OR proposal_count <> 0
     OR response_count <> 0
     OR checkin_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: A blocker could still read blocked confirmed meetup state';
  END IF;
END $$;

RESET request.jwt.claims;
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000b4"}';
DO $$
DECLARE
  meetup_id_value uuid := pg_catalog.current_setting('test.confirmed_meetup_id')::uuid;
  helper_error_state text;
  hidden_block_count integer;
  meetup_count integer;
  proposal_count integer;
  response_count integer;
  checkin_count integer;
BEGIN
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('20000000-0000-0000-0000-0000000000a4');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS helper_error_state = RETURNED_SQLSTATE;
  END;
  SELECT count(*) INTO hidden_block_count
  FROM public.blocks
  WHERE blocker_id = '10000000-0000-0000-0000-0000000000a4'
    AND blocked_id = '10000000-0000-0000-0000-0000000000b4';
  SELECT count(*) INTO meetup_count
  FROM public.meetups
  WHERE id = meetup_id_value;
  SELECT count(*) INTO proposal_count
  FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO checkin_count
  FROM public.venue_checkins
  WHERE id = '60000000-0000-0000-0000-0000000000a4';
  IF hidden_block_count <> 0
     OR helper_error_state IS DISTINCT FROM '42501'
     OR meetup_count <> 0
     OR proposal_count <> 0
     OR response_count <> 0
     OR checkin_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: B blockee could still read blocked confirmed meetup state';
  END IF;
END $$;
ROLLBACK TO SAVEPOINT blocked_meetup_a_to_b;

RESET request.jwt.claims;
RESET role;
SET LOCAL role = 'service_role';
SAVEPOINT blocked_meetup_b_to_a;
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES (
  '10000000-0000-0000-0000-0000000000b4',
  '10000000-0000-0000-0000-0000000000a4'
);
RESET role;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000b4"}';
DO $$
DECLARE
  meetup_id_value uuid := pg_catalog.current_setting('test.confirmed_meetup_id')::uuid;
  helper_error_state text;
  own_block_count integer;
  meetup_count integer;
  proposal_count integer;
  response_count integer;
  checkin_count integer;
BEGIN
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('20000000-0000-0000-0000-0000000000a4');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS helper_error_state = RETURNED_SQLSTATE;
  END;
  SELECT count(*) INTO own_block_count
  FROM public.blocks
  WHERE blocker_id = '10000000-0000-0000-0000-0000000000b4'
    AND blocked_id = '10000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO meetup_count
  FROM public.meetups
  WHERE id = meetup_id_value;
  SELECT count(*) INTO proposal_count
  FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO checkin_count
  FROM public.venue_checkins
  WHERE id = '60000000-0000-0000-0000-0000000000a4';
  IF own_block_count <> 1
     OR helper_error_state IS DISTINCT FROM '42501'
     OR meetup_count <> 0
     OR proposal_count <> 0
     OR response_count <> 0
     OR checkin_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: B blocker could still read blocked confirmed meetup state';
  END IF;
END $$;

RESET request.jwt.claims;
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a4"}';
DO $$
DECLARE
  meetup_id_value uuid := pg_catalog.current_setting('test.confirmed_meetup_id')::uuid;
  helper_error_state text;
  hidden_block_count integer;
  meetup_count integer;
  proposal_count integer;
  response_count integer;
  checkin_count integer;
BEGIN
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('20000000-0000-0000-0000-0000000000a4');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS helper_error_state = RETURNED_SQLSTATE;
  END;
  SELECT count(*) INTO hidden_block_count
  FROM public.blocks
  WHERE blocker_id = '10000000-0000-0000-0000-0000000000b4'
    AND blocked_id = '10000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO meetup_count
  FROM public.meetups
  WHERE id = meetup_id_value;
  SELECT count(*) INTO proposal_count
  FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO checkin_count
  FROM public.venue_checkins
  WHERE id = '60000000-0000-0000-0000-0000000000a4';
  IF hidden_block_count <> 0
     OR helper_error_state IS DISTINCT FROM '42501'
     OR meetup_count <> 0
     OR proposal_count <> 0
     OR response_count <> 0
     OR checkin_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: A blockee could still read blocked confirmed meetup state';
  END IF;
END $$;
ROLLBACK TO SAVEPOINT blocked_meetup_b_to_a;

-- Removing the block restores both participants' reads. A previously observed
-- meetup ID may still change from visible to hidden when access is revoked;
-- the private helper adds no separate direct visibility bit. It is callable by
-- stored RLS policies only, so direct API-role calls fail with
-- insufficient_privilege for blocked, unblocked, unrelated, and missing IDs.
RESET request.jwt.claims;
RESET role;
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a4"}';
DO $$
DECLARE
  meetup_id_value uuid := pg_catalog.current_setting('test.confirmed_meetup_id')::uuid;
  helper_error_state text;
  meetup_count integer;
  proposal_count integer;
  response_count integer;
  checkin_count integer;
  confirmed_start timestamptz;
  confirmed_area text;
  confirmed_timezone text;
BEGIN
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('20000000-0000-0000-0000-0000000000a4');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS helper_error_state = RETURNED_SQLSTATE;
  END;
  SELECT count(*) INTO meetup_count FROM public.meetups WHERE id = meetup_id_value;
  SELECT confirmed_start_at, area, public.meetups.confirmed_timezone
    INTO confirmed_start, confirmed_area, confirmed_timezone
  FROM public.meetups
  WHERE id = meetup_id_value;
  SELECT count(*) INTO proposal_count FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO response_count FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO checkin_count FROM public.venue_checkins
  WHERE id = '60000000-0000-0000-0000-0000000000a4';
  IF helper_error_state IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 'FAIL S2: A could invoke private meetup visibility helper directly; SQLSTATE %', helper_error_state;
  END IF;
  IF meetup_count <> 1 OR proposal_count <> 1
     OR response_count <> 2 OR checkin_count <> 1
     OR confirmed_start IS NULL OR confirmed_area IS NULL
     OR confirmed_timezone IS DISTINCT FROM 'Asia/Tokyo' THEN
    RAISE EXCEPTION 'FAIL S2: A lost unblocked confirmed meetup visibility';
  END IF;
END $$;

RESET request.jwt.claims;
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000b4"}';
DO $$
DECLARE
  meetup_id_value uuid := pg_catalog.current_setting('test.confirmed_meetup_id')::uuid;
  helper_error_state text;
  meetup_count integer;
  proposal_count integer;
  response_count integer;
  checkin_count integer;
BEGIN
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('20000000-0000-0000-0000-0000000000a4');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS helper_error_state = RETURNED_SQLSTATE;
  END;
  SELECT count(*) INTO meetup_count FROM public.meetups WHERE id = meetup_id_value;
  SELECT count(*) INTO proposal_count FROM public.meetup_proposals
  WHERE id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO response_count FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  SELECT count(*) INTO checkin_count FROM public.venue_checkins
  WHERE id = '60000000-0000-0000-0000-0000000000a4';
  IF helper_error_state IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 'FAIL S2: B could invoke private meetup visibility helper directly; SQLSTATE %', helper_error_state;
  END IF;
  IF meetup_count <> 1 OR proposal_count <> 1
     OR response_count <> 2 OR checkin_count <> 1 THEN
    RAISE EXCEPTION 'FAIL S2: B lost unblocked confirmed meetup visibility';
  END IF;
END $$;

RESET request.jwt.claims;
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000c4"}';
DO $$
DECLARE
  meetup_id_value uuid := pg_catalog.current_setting('test.confirmed_meetup_id')::uuid;
  known_id_error_state text;
  missing_id_error_state text;
  null_id_error_state text;
  meetup_count integer;
BEGIN
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('20000000-0000-0000-0000-0000000000a4');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS known_id_error_state = RETURNED_SQLSTATE;
  END;
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('ffffffff-ffff-ffff-ffff-ffffffffffff');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS missing_id_error_state = RETURNED_SQLSTATE;
  END;
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match(NULL);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS null_id_error_state = RETURNED_SQLSTATE;
  END;
  SELECT count(*) INTO meetup_count FROM public.meetups WHERE id = meetup_id_value;
  IF known_id_error_state IS DISTINCT FROM '42501'
     OR missing_id_error_state IS DISTINCT FROM '42501'
     OR null_id_error_state IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 'FAIL S2: outsider could invoke private meetup visibility helper directly (% / % / %)',
      known_id_error_state, missing_id_error_state, null_id_error_state;
  END IF;
  IF meetup_count <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: outsider could probe or read another match meetup';
  END IF;
END $$;

RESET request.jwt.claims;
DO $$
DECLARE
  helper_error_state text;
BEGIN
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('20000000-0000-0000-0000-0000000000a4');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS helper_error_state = RETURNED_SQLSTATE;
  END;
  IF helper_error_state IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 'FAIL S2: authless caller could execute private meetup visibility helper; SQLSTATE %', helper_error_state;
  END IF;
END $$;

SET LOCAL request.jwt.claims = '{}';
DO $$
DECLARE
  helper_error_state text;
BEGIN
  BEGIN
    PERFORM wingward_private.can_read_unblocked_meetup_match('20000000-0000-0000-0000-0000000000a4');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS helper_error_state = RETURNED_SQLSTATE;
  END;
  IF helper_error_state IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 'FAIL S2: empty claims could execute private meetup visibility helper; SQLSTATE %', helper_error_state;
  END IF;
END $$;

RESET request.jwt.claims;
RESET role;
SET LOCAL role = 'service_role';
ROLLBACK TO SAVEPOINT blocked_meetup_visibility_probe;

-- Confirmation is idempotent for the same choice, but cannot be rewritten by
-- a different candidate index.
DO $$
DECLARE
  meetup_id_value uuid;
  repeated record;
  changed record;
  response_count integer;
BEGIN
  SELECT id INTO meetup_id_value
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  SELECT * INTO repeated
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4',
    0
  );
  IF repeated.outcome <> 'confirmed' OR repeated.confirmed_candidate_index <> 0 THEN
    RAISE EXCEPTION 'FAIL S2: repeated confirmation was not idempotent';
  END IF;
  SELECT * INTO changed
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000b4',
    1
  );
  IF changed.outcome <> 'invalid_state' OR changed.status <> 'confirmed' THEN
    RAISE EXCEPTION 'FAIL S2: confirmed candidate could be rewritten';
  END IF;
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  IF response_count <> 2 THEN
    RAISE EXCEPTION 'FAIL S2: expected one response per participant, got %', response_count;
  END IF;
  RAISE NOTICE 'PASS S2: confirmation is idempotent and participant-owned';
END $$;

-- Invalid indices and cross-meetup/cross-participant responses do not write.
DO $$
DECLARE
  meetup_id_value uuid;
  result record;
  response_count integer;
BEGIN
  SELECT id INTO meetup_id_value
  FROM public.meetups
  WHERE match_id = '20000000-0000-0000-0000-0000000000a4';
  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000a4',
    3
  );
  IF result.outcome <> 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL S2: candidate index 3 was accepted';
  END IF;
  SELECT * INTO result
  FROM public.record_meetup_proposal_response(
    meetup_id_value,
    '30000000-0000-0000-0000-0000000000a4',
    '10000000-0000-0000-0000-0000000000c4',
    0
  );
  IF result.outcome <> 'not_found' THEN
    RAISE EXCEPTION 'FAIL S2: non-participant could respond';
  END IF;
  SELECT count(*) INTO response_count
  FROM public.meetup_proposal_responses
  WHERE proposal_id = '30000000-0000-0000-0000-0000000000a4';
  IF response_count <> 2 THEN
    RAISE EXCEPTION 'FAIL S2: invalid responses changed persisted rows';
  END IF;
  RAISE NOTICE 'PASS S2: invalid index and non-participant responses are rejected';
END $$;

-- Direct response writes cannot store an out-of-range index either.
DO $$
BEGIN
  BEGIN
    INSERT INTO public.meetup_proposal_responses (
      proposal_id, user_id, selected_candidate_indexes, response
    ) VALUES (
      '30000000-0000-0000-0000-0000000000a4',
      '10000000-0000-0000-0000-0000000000c4',
      ARRAY[3],
      'selected'
    );
    RAISE EXCEPTION 'FAIL S2: direct response with index 3 was accepted';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS S2: response index constraint rejects 3';
  END;
  BEGIN
    INSERT INTO public.meetup_proposal_responses (
      proposal_id, user_id, selected_candidate_indexes, response
    ) VALUES (
      '30000000-0000-0000-0000-0000000000a4',
      '10000000-0000-0000-0000-0000000000c4',
      '[0:0]={1}'::integer[],
      'selected'
    );
    RAISE EXCEPTION 'FAIL S2: non-1-based single-element array bypassed the response constraint';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS S2: response index constraint rejects non-1-based arrays';
  END;
  BEGIN
    INSERT INTO public.meetup_proposal_responses (
      proposal_id, user_id, selected_candidate_indexes, response
    ) VALUES (
      '30000000-0000-0000-0000-0000000000a4',
      '10000000-0000-0000-0000-0000000000c4',
      ARRAY[NULL]::integer[],
      'selected'
    );
    RAISE EXCEPTION 'FAIL S2: NULL candidate index bypassed the response constraint';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS S2: response index constraint rejects NULL elements';
  END;
END $$;

-- Locking is part of the concurrency contract.  Keep a mechanical guard in
-- this SQL suite so a future edit cannot silently remove the row locks while
-- leaving the happy-path tests green.
DO $$
DECLARE
  intent_definition text;
  response_definition text;
BEGIN
  SELECT pg_get_functiondef('public.create_or_match_meetup_intent(uuid,uuid)'::regprocedure)
    INTO intent_definition;
  SELECT pg_get_functiondef('public.record_meetup_proposal_response(uuid,uuid,uuid,integer)'::regprocedure)
    INTO response_definition;
  IF position('FOR UPDATE' IN intent_definition) = 0
     OR position('FOR UPDATE' IN response_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL S2: transition RPC lost its row lock';
  END IF;
  IF position('FROM public.direct_chat_rooms' IN intent_definition) = 0
     OR position('v_room.status IS DISTINCT FROM ''active''' IN intent_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL S2: intent RPC lost its active direct-chat room guard';
  END IF;
  RAISE NOTICE 'PASS S2: transition RPCs retain row-lock concurrency guard';
END $$;

-- A client role reaching the RPC must fail at the privilege boundary, not
-- merely receive a state result.
RESET role;
SET LOCAL role = 'authenticated';
DO $$
BEGIN
  BEGIN
    PERFORM public.create_or_match_meetup_intent(
      '20000000-0000-0000-0000-0000000000a4',
      '10000000-0000-0000-0000-0000000000a4'
    );
    RAISE EXCEPTION 'FAIL S2: authenticated executed a service-only RPC';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS S2: authenticated RPC execution is denied';
  END;
END $$;

ROLLBACK;
