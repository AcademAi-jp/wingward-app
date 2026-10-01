-- Acceptance criteria #4, #5: a meetup is invisible to the non-initiator while intent_pending,
-- and becomes visible to both parties once intent_matched.
-- docs/spec/impl/step-01-migrations-rls.md §7 items 4, 5

BEGIN;

-- Fixtures: two auth users + user_profiles + a match between them.
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'wingward-test-a1@example.invalid'),
  ('00000000-0000-0000-0000-0000000000b1', 'wingward-test-b1@example.invalid');

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000a1', nickname = 'Test A',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared',
    gender_identity = 'woman', preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected', dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a1';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b1', nickname = 'Test B',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared',
    gender_identity = 'woman', preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected', dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b1';

INSERT INTO public.matches (id, user_a_id, user_b_id, status) VALUES
  ('20000000-0000-0000-0000-0000000000ab',
   '10000000-0000-0000-0000-0000000000a1',
   '10000000-0000-0000-0000-0000000000b1',
   'pending');

-- User A (the initiator) creates an intent_pending meetup, as service_role would on their
-- behalf via the API. We insert directly here as postgres/table owner to seed the fixture
-- (RLS INSERT-path itself is exercised by the app; this test focuses on SELECT visibility).
INSERT INTO public.meetups (id, match_id, initiator_id, status) VALUES
  ('30000000-0000-0000-0000-0000000000d1',
   '20000000-0000-0000-0000-0000000000ab',
   '10000000-0000-0000-0000-0000000000a1',
   'intent_pending');

-- --- Criterion #4: while intent_pending, user B (non-initiator) must see 0 rows ---
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000b1"}';

DO $$
DECLARE
  visible_count integer;
BEGIN
  SELECT count(*) INTO visible_count FROM public.meetups WHERE id = '30000000-0000-0000-0000-0000000000d1';
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL #4: non-initiator B saw % row(s) of an intent_pending meetup (expected 0)', visible_count;
  END IF;
  RAISE NOTICE 'PASS #4: non-initiator cannot see intent_pending meetup';
END $$;

RESET role;
RESET request.jwt.claims;

-- Also confirm the initiator CAN see their own intent_pending meetup.
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a1"}';

DO $$
DECLARE
  visible_count integer;
BEGIN
  SELECT count(*) INTO visible_count FROM public.meetups WHERE id = '30000000-0000-0000-0000-0000000000d1';
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: initiator A saw % row(s) of their own intent_pending meetup (expected 1)', visible_count;
  END IF;
  RAISE NOTICE 'PASS: initiator can see their own intent_pending meetup';
END $$;

RESET role;
RESET request.jwt.claims;

-- --- Criterion #5: after transitioning to intent_matched, both parties see it ---
RESET role;
-- Mutual consent carries both timestamps; status alone must not grant access.
UPDATE public.meetups
SET status = 'intent_matched', intent_a_at = pg_catalog.now(), intent_b_at = pg_catalog.now()
WHERE id = '30000000-0000-0000-0000-0000000000d1';

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000b1"}';

DO $$
DECLARE
  visible_count integer;
BEGIN
  SELECT count(*) INTO visible_count FROM public.meetups WHERE id = '30000000-0000-0000-0000-0000000000d1';
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL #5: non-initiator B saw % row(s) after intent_matched (expected 1)', visible_count;
  END IF;
  RAISE NOTICE 'PASS #5: non-initiator can see meetup after intent_matched';
END $$;

RESET role;
RESET request.jwt.claims;

ROLLBACK;
