-- Covers 20260904080000_meetup_notification_lifetime_dedup.sql.
--
-- The 24-hour notification deduplication window is intentionally not enough
-- for meetup intent retries. This test proves the partial unique index is
-- present and rejects the same N-04 delivery for the same participant and
-- meetup even when its deduplication timestamps are more than a day apart.
-- It also checks the negative controls: N-07, another participant, another
-- meetup, and an unrelated scenario remain independent notification keys.

BEGIN;

DO $$
DECLARE
  index_is_unique boolean;
  index_predicate text;
  index_definition text;
BEGIN
  SELECT i.indisunique,
         pg_catalog.pg_get_expr(i.indpred, i.indrelid),
         pg_catalog.pg_get_indexdef(i.indexrelid)
    INTO index_is_unique, index_predicate, index_definition
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_index AS i ON i.indexrelid = c.oid
   WHERE n.nspname = 'public'
     AND c.relname = 'notifications_meetup_lifetime_scenario_user_key';

  IF NOT COALESCE(index_is_unique, false)
     OR index_definition NOT LIKE '%(scenario_id, user_id, meetup_id)%'
     OR COALESCE(index_predicate, '') NOT LIKE '%meetup_id IS NOT NULL%'
     OR COALESCE(index_predicate, '') NOT LIKE '%N-04%'
     OR COALESCE(index_predicate, '') NOT LIKE '%N-07%' THEN
    RAISE EXCEPTION 'FAIL 15a: meetup notification lifetime index is missing or has the wrong key/predicate';
  END IF;
  RAISE NOTICE 'PASS 15a: meetup notification lifetime partial unique index is wired';
END $$;

INSERT INTO auth.users (id, email)
VALUES
  ('00000000-0000-0000-0000-000000001501', 'wingward-test-1501@example.invalid'),
  ('00000000-0000-0000-0000-000000001502', 'wingward-test-1502@example.invalid');

UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-000000001501',
       nickname = 'Test 1501',
       birth_date = '1990-01-01',
       age_verified_at = '2026-08-24T00:00:00Z',
       age_verification_method = 'self_declared',
       gender_identity = 'woman',
       preferred_genders = ARRAY['woman']::text[],
       preference_mode = 'selected',
       dating_market = 'JP',
       onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
 WHERE auth_user_id = '00000000-0000-0000-0000-000000001501';

UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-000000001502',
       nickname = 'Test 1502',
       birth_date = '1990-01-01',
       age_verified_at = '2026-08-24T00:00:00Z',
       age_verification_method = 'self_declared',
       gender_identity = 'woman',
       preferred_genders = ARRAY['woman']::text[],
       preference_mode = 'selected',
       dating_market = 'JP',
       onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
 WHERE auth_user_id = '00000000-0000-0000-0000-000000001502';

INSERT INTO public.matches (id, user_a_id, user_b_id, status)
VALUES (
  '20000000-0000-0000-0000-000000001501',
  '10000000-0000-0000-0000-000000001501',
  '10000000-0000-0000-0000-000000001502',
  'direct_chat_active'
);

INSERT INTO public.meetups (id, match_id, initiator_id, status)
VALUES
  (
    '30000000-0000-0000-0000-000000001501',
    '20000000-0000-0000-0000-000000001501',
    '10000000-0000-0000-0000-000000001501',
    'verifying'
  ),
  (
    '30000000-0000-0000-0000-000000001502',
    '20000000-0000-0000-0000-000000001501',
    '10000000-0000-0000-0000-000000001501',
    'expired'
  );

SET LOCAL role = 'service_role';

INSERT INTO public.notifications
  (scenario_id, user_id, match_id, meetup_id, dedup_window_start)
VALUES (
  'N-04',
  '10000000-0000-0000-0000-000000001501',
  '20000000-0000-0000-0000-000000001501',
  '30000000-0000-0000-0000-000000001501',
  pg_catalog.now() - pg_catalog.interval '2 days'
);

DO $$
BEGIN
  BEGIN
    INSERT INTO public.notifications
      (scenario_id, user_id, match_id, meetup_id, dedup_window_start)
    VALUES (
      'N-04',
      '10000000-0000-0000-0000-000000001501',
      '20000000-0000-0000-0000-000000001501',
      '30000000-0000-0000-0000-000000001501',
      pg_catalog.now()
    );
    RAISE EXCEPTION 'FAIL 15b: duplicate N-04 delivery was accepted';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS 15b: duplicate N-04 delivery is rejected for the meetup lifetime';
  END;
END $$;

-- Scenario and recipient are part of the key, so N-07 and the other
-- participant each retain one independent delivery for the same meetup.
INSERT INTO public.notifications
  (scenario_id, user_id, match_id, meetup_id, dedup_window_start)
VALUES
  (
    'N-07',
    '10000000-0000-0000-0000-000000001501',
    '20000000-0000-0000-0000-000000001501',
    '30000000-0000-0000-0000-000000001501',
    pg_catalog.now()
  ),
  (
    'N-04',
    '10000000-0000-0000-0000-000000001502',
    '20000000-0000-0000-0000-000000001501',
    '30000000-0000-0000-0000-000000001501',
    pg_catalog.now()
  ),
  (
    'N-04',
    '10000000-0000-0000-0000-000000001501',
    '20000000-0000-0000-0000-000000001501',
    '30000000-0000-0000-0000-000000001502',
    pg_catalog.now()
  ),
  (
    'N-05',
    '10000000-0000-0000-0000-000000001501',
    '20000000-0000-0000-0000-000000001501',
    '30000000-0000-0000-0000-000000001501',
    pg_catalog.now()
  );

DO $$
DECLARE
  notification_count integer;
BEGIN
  SELECT count(*) INTO notification_count
    FROM public.notifications
   WHERE meetup_id IN (
     '30000000-0000-0000-0000-000000001501',
     '30000000-0000-0000-0000-000000001502'
   );
  IF notification_count <> 5 THEN
    RAISE EXCEPTION 'FAIL 15c: independent meetup notification keys were not preserved (got %)', notification_count;
  END IF;
  RAISE NOTICE 'PASS 15c: scenario, recipient, and meetup boundaries remain independent';
END $$;

RESET role;
ROLLBACK;
