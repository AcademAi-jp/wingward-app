-- B1-A: profile creation, age-gated RLS helper, and direct-write lockdown.

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000a0', 'wingward-age-a@example.invalid'),
  ('00000000-0000-0000-0000-0000000000b0', 'wingward-age-b@example.invalid'),
  ('00000000-0000-0000-0000-0000000000c0', 'wingward-age-c@example.invalid');

-- The signup trigger owns row creation. Fixtures only move the generated rows
-- to stable IDs and explicitly mark the verified fixture used by RLS checks.
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000a0',
    nickname = 'Verified A',
    birth_date = '1990-01-01',
    age_verified_at = '2026-08-24T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a0';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b0',
    nickname = 'Unverified B',
    birth_date = '1990-02-02',
    age_verified_at = '2026-08-24T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b0';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000c0'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c0';

DO $$
DECLARE
  profile_count integer;
  generated_nickname text;
BEGIN
  SELECT count(*), max(nickname)
  INTO profile_count, generated_nickname
  FROM public.user_profiles
  WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c0';
  IF profile_count <> 1 OR generated_nickname <> 'User' THEN
    RAISE EXCEPTION 'FAIL B1-A: auth.users trigger did not create exactly one profile';
  END IF;
  RAISE NOTICE 'PASS B1-A: auth.users trigger creates one user_profiles row';
END $$;

DO $$
DECLARE
  write_policy_count integer;
  public_execute boolean;
BEGIN
  SELECT count(*)
  INTO write_policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'user_profiles'
    AND policyname IN ('user_profiles_insert', 'user_profiles_update');
  IF write_policy_count <> 0 THEN
    RAISE EXCEPTION 'FAIL B1-A: direct user_profiles write policies still exist';
  END IF;

  IF has_table_privilege('authenticated', 'public.user_profiles', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL B1-A: authenticated still has user_profiles INSERT privilege';
  END IF;
  IF has_table_privilege('authenticated', 'public.user_profiles', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL B1-A: authenticated still has user_profiles UPDATE privilege';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM pg_proc AS p
    CROSS JOIN LATERAL aclexplode(
      COALESCE(p.proacl, acldefault('f', p.proowner))
    ) AS privilege
    WHERE p.oid = 'public.handle_new_user_profile()'::regprocedure
      AND privilege.grantee = 0
      AND privilege.privilege_type = 'EXECUTE'
  )
  INTO public_execute;
  IF public_execute THEN
    RAISE EXCEPTION 'FAIL B1-A: PUBLIC still has handle_new_user_profile EXECUTE privilege';
  END IF;
  IF has_function_privilege('anon', 'public.handle_new_user_profile()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL B1-A: anon still has handle_new_user_profile EXECUTE privilege';
  END IF;
  IF has_function_privilege('authenticated', 'public.handle_new_user_profile()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL B1-A: authenticated still has handle_new_user_profile EXECUTE privilege';
  END IF;

  IF has_function_privilege('anon', 'public.are_match_participants_age_verified(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL B1-A: anon can call the match participant age helper';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.are_match_participants_age_verified(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL B1-A: authenticated cannot evaluate the match participant age helper for RLS';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.are_match_participants_age_verified(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL B1-A: service_role cannot evaluate the match participant age helper';
  END IF;

  RAISE NOTICE 'PASS B1-A: profile write policies, privileges, and trigger EXECUTE grants are locked down';
END $$;

INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES (
  '20000000-0000-0000-0000-0000000000a0',
  '10000000-0000-0000-0000-0000000000a0',
  '10000000-0000-0000-0000-0000000000b0'
);

-- Derived rows intentionally remain after the profile reset.  The age gate
-- must close these as well as the parent match.
INSERT INTO public.fox_conversations (id, match_id)
VALUES (
  '30000000-0000-0000-0000-0000000000a0',
  '20000000-0000-0000-0000-0000000000a0'
);

INSERT INTO public.interaction_dna_scores (
  id, match_id, feature_id, feature_name, raw_score, normalized_score,
  confidence, source_phase
)
VALUES (
  '40000000-0000-0000-0000-0000000000a0',
  '20000000-0000-0000-0000-0000000000a0',
  1, 'communication', 0.8, 0.8, 0.9, 'quiz'
);

-- A notification and its event intentionally survive while the counterpart is
-- unverified.  Their RLS policies must follow the same parent-match gate as
-- the other derived rows, including the event's parent-notification lookup.
INSERT INTO public.notifications (id, scenario_id, user_id, match_id)
VALUES (
  '50000000-0000-0000-0000-0000000000a0',
  'N-01',
  '10000000-0000-0000-0000-0000000000a0',
  '20000000-0000-0000-0000-0000000000a0'
);

INSERT INTO public.notification_events (id, notification_id, user_id, event_type, occurred_at)
VALUES (
  '60000000-0000-0000-0000-0000000000a0',
  '50000000-0000-0000-0000-0000000000a0',
  '10000000-0000-0000-0000-0000000000a0',
  'opened',
  now()
);

-- Keep the match and all derived rows pre-existing, then revoke only B's age
-- verification before the first authenticated access checks below.
UPDATE public.user_profiles
SET age_verified_at = NULL,
    age_verification_method = NULL
WHERE id = '10000000-0000-0000-0000-0000000000b0';

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a0"}';

DO $$
BEGIN
  IF public.get_user_profile_id() <> '10000000-0000-0000-0000-0000000000a0'::uuid THEN
    RAISE EXCEPTION 'FAIL B1-A: verified user did not resolve through get_user_profile_id()';
  END IF;
  RAISE NOTICE 'PASS B1-A: verified user resolves through get_user_profile_id()';
END $$;

SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000b0"}';

DO $$
BEGIN
  IF public.get_user_profile_id() IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL B1-A: unverified user resolved through get_user_profile_id()';
  END IF;
  RAISE NOTICE 'PASS B1-A: unverified user resolves to NULL';
END $$;

SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a0"}';

DO $$
DECLARE
  visible_matches integer;
  visible_conversations integer;
  visible_dna_scores integer;
  visible_notifications integer;
  visible_notification_events integer;
BEGIN
  IF public.are_match_participants_age_verified(
    '20000000-0000-0000-0000-0000000000a0'::uuid
  ) THEN
    RAISE EXCEPTION 'FAIL B1-A: verified caller reached an unverified counterpart match through the RPC helper';
  END IF;
  SELECT count(*) INTO visible_matches FROM public.matches;
  SELECT count(*) INTO visible_conversations FROM public.fox_conversations;
  SELECT count(*) INTO visible_dna_scores FROM public.interaction_dna_scores;
  SELECT count(*) INTO visible_notifications FROM public.notifications;
  SELECT count(*) INTO visible_notification_events FROM public.notification_events;
  IF visible_matches <> 0 OR visible_conversations <> 0 OR visible_dna_scores <> 0
    OR visible_notifications <> 0 OR visible_notification_events <> 0 THEN
    RAISE EXCEPTION 'FAIL B1-A: unverified counterpart exposed match-derived rows (%/%/%/%/%)',
      visible_matches, visible_conversations, visible_dna_scores,
      visible_notifications, visible_notification_events;
  END IF;
  RAISE NOTICE 'PASS B1-A: verified caller cannot read existing match-derived rows until both ages are verified';
END $$;

DO $$
BEGIN
  INSERT INTO public.user_profiles (auth_user_id, nickname)
  VALUES ('00000000-0000-0000-0000-0000000000b0', 'forged');
  RAISE EXCEPTION 'FAIL B1-A: authenticated JWT inserted user_profiles directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS B1-A: authenticated user_profiles INSERT rejected';
END $$;

SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000c0"}';

DO $$
BEGIN
  IF public.are_match_participants_age_verified(
    '20000000-0000-0000-0000-0000000000a0'::uuid
  ) THEN
    RAISE EXCEPTION 'FAIL B1-A: third-party caller learned a match was age-verified';
  END IF;
  RAISE NOTICE 'PASS B1-A: third-party RPC call returns false without an oracle';
END $$;

DO $$
BEGIN
  UPDATE public.user_profiles SET nickname = 'forged'
  WHERE id = '10000000-0000-0000-0000-0000000000b0';
  RAISE EXCEPTION 'FAIL B1-A: authenticated JWT updated user_profiles directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS B1-A: authenticated user_profiles UPDATE rejected';
END $$;

RESET role;
RESET request.jwt.claims;

-- Once the counterpart is verified, both participants can read the same
-- existing match and its derived rows without recreating the relationship.
UPDATE public.user_profiles
SET birth_date = '1990-02-02',
    age_verified_at = '2026-08-24T00:00:00Z',
    age_verification_method = 'self_declared'
WHERE id = '10000000-0000-0000-0000-0000000000b0';

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a0"}';

DO $$
DECLARE
  visible_matches integer;
  visible_conversations integer;
  visible_dna_scores integer;
  visible_notifications integer;
  visible_notification_events integer;
BEGIN
  IF NOT public.are_match_participants_age_verified(
    '20000000-0000-0000-0000-0000000000a0'::uuid
  ) THEN
    RAISE EXCEPTION 'FAIL B1-A: both verified participants did not pass the RPC helper';
  END IF;
  SELECT count(*) INTO visible_matches FROM public.matches;
  SELECT count(*) INTO visible_conversations FROM public.fox_conversations;
  SELECT count(*) INTO visible_dna_scores FROM public.interaction_dna_scores;
  SELECT count(*) INTO visible_notifications FROM public.notifications;
  SELECT count(*) INTO visible_notification_events FROM public.notification_events;
  IF visible_matches <> 1 OR visible_conversations <> 1 OR visible_dna_scores <> 1
    OR visible_notifications <> 1 OR visible_notification_events <> 1 THEN
    RAISE EXCEPTION 'FAIL B1-A: verified pair could not read existing derived rows (%/%/%/%/%)',
      visible_matches, visible_conversations, visible_dna_scores,
      visible_notifications, visible_notification_events;
  END IF;
  RAISE NOTICE 'PASS B1-A: both verified participants can read existing match-derived rows';
END $$;

SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000c0"}';

DO $$
BEGIN
  IF public.are_match_participants_age_verified(
    '20000000-0000-0000-0000-0000000000a0'::uuid
  ) THEN
    RAISE EXCEPTION 'FAIL B1-A: third-party caller learned a fully verified match exists';
  END IF;
  RAISE NOTICE 'PASS B1-A: third-party RPC call remains false for a fully verified match';
END $$;

RESET role;
RESET request.jwt.claims;

ROLLBACK;
