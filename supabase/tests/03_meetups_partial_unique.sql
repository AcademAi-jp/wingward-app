-- Acceptance criterion #9: cannot create a second non-terminal meetup for the same match.
-- docs/spec/impl/step-01-migrations-rls.md §7 item 9

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000a2', 'wingward-test-a2@example.invalid'),
  ('00000000-0000-0000-0000-0000000000b2', 'wingward-test-b2@example.invalid');

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000a2', nickname = 'Test A2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared',
    gender_identity = 'woman', preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected', dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a2';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b2', nickname = 'Test B2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared',
    gender_identity = 'woman', preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected', dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b2';

INSERT INTO public.matches (id, user_a_id, user_b_id, status) VALUES
  ('20000000-0000-0000-0000-0000000000cd',
   '10000000-0000-0000-0000-0000000000a2',
   '10000000-0000-0000-0000-0000000000b2',
   'pending');

INSERT INTO public.meetups (id, match_id, initiator_id, status) VALUES
  ('30000000-0000-0000-0000-0000000000d2',
   '20000000-0000-0000-0000-0000000000cd',
   '10000000-0000-0000-0000-0000000000a2',
   'intent_pending');

-- A second non-terminal meetup for the same match must be rejected by meetups_match_id_active_key.
DO $$
BEGIN
  BEGIN
    INSERT INTO public.meetups (id, match_id, initiator_id, status) VALUES
      ('30000000-0000-0000-0000-0000000000d3',
       '20000000-0000-0000-0000-0000000000cd',
       '10000000-0000-0000-0000-0000000000b2',
       'intent_pending');
    RAISE EXCEPTION 'FAIL #9: a second non-terminal meetup for the same match was allowed';
  EXCEPTION
    WHEN unique_violation THEN
      RAISE NOTICE 'PASS #9: second non-terminal meetup for the same match was rejected (unique_violation)';
  END;
END $$;

-- A retry meetup after the first one reaches a terminal status must be allowed.
UPDATE public.meetups SET status = 'expired' WHERE id = '30000000-0000-0000-0000-0000000000d2';

DO $$
BEGIN
  INSERT INTO public.meetups (id, match_id, initiator_id, status) VALUES
    ('30000000-0000-0000-0000-0000000000d4',
     '20000000-0000-0000-0000-0000000000cd',
     '10000000-0000-0000-0000-0000000000b2',
     'intent_pending');
  RAISE NOTICE 'PASS: a retry meetup is allowed once the prior one is terminal (expired)';
END $$;

ROLLBACK;
