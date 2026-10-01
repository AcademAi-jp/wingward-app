-- Acceptance criterion #7: user A can write/read their own meetup_feedback row; user B's row
-- for the SAME meetup (both are participants) stays invisible to A.
-- docs/spec/impl/step-01-migrations-rls.md §7 item 7

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000a4', 'wingward-test-a4@example.invalid'),
  ('00000000-0000-0000-0000-0000000000b4', 'wingward-test-b4@example.invalid');

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000a4', nickname = 'Test A4',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared',
    gender_identity = 'woman', preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected', dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a4';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b4', nickname = 'Test B4',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared',
    gender_identity = 'woman', preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected', dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b4';

INSERT INTO public.matches (id, user_a_id, user_b_id, status) VALUES
  ('20000000-0000-0000-0000-0000000000ef',
   '10000000-0000-0000-0000-0000000000a4',
   '10000000-0000-0000-0000-0000000000b4',
   'pending');

INSERT INTO public.meetups (id, match_id, initiator_id, status) VALUES
  ('30000000-0000-0000-0000-0000000000d5',
   '20000000-0000-0000-0000-0000000000ef',
   '10000000-0000-0000-0000-0000000000a4',
   'completed');

-- User B submits their feedback first (seeded directly, as if via the API).
INSERT INTO public.meetup_feedback (meetup_id, user_id, want_to_meet_again) VALUES
  ('30000000-0000-0000-0000-0000000000d5', '10000000-0000-0000-0000-0000000000b4', true);

-- --- User A writes and reads their OWN feedback row ---
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a4"}';

INSERT INTO public.meetup_feedback (meetup_id, user_id, want_to_meet_again) VALUES
  ('30000000-0000-0000-0000-0000000000d5', '10000000-0000-0000-0000-0000000000a4', true);

DO $$
DECLARE
  visible_count integer;
BEGIN
  SELECT count(*) INTO visible_count FROM public.meetup_feedback WHERE meetup_id = '30000000-0000-0000-0000-0000000000d5';
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL #7: user A saw % feedback row(s) for the meetup (expected exactly 1: their own)', visible_count;
  END IF;
  RAISE NOTICE 'PASS #7: user A sees only their own meetup_feedback row (not B''s, though both are participants)';
END $$;

RESET role;
RESET request.jwt.claims;

ROLLBACK;
