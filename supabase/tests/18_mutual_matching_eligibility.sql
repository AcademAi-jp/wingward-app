-- B2 SQL foundation: strict mutual matching predicate and match write guard.
--
-- This script is deliberately self-contained.  It exercises the real SQL
-- functions and triggers with synthetic rows, then rolls everything back.

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-000000001801', 'wingward-b2-1801@example.invalid'),
  ('00000000-0000-0000-0000-000000001802', 'wingward-b2-1802@example.invalid'),
  ('00000000-0000-0000-0000-000000001803', 'wingward-b2-1803@example.invalid'),
  ('00000000-0000-0000-0000-000000001804', 'wingward-b2-1804@example.invalid'),
  ('00000000-0000-0000-0000-000000001805', 'wingward-b2-1805@example.invalid'),
  ('00000000-0000-0000-0000-000000001806', 'wingward-b2-1806@example.invalid'),
  ('00000000-0000-0000-0000-000000001807', 'wingward-b2-1807@example.invalid'),
  ('00000000-0000-0000-0000-000000001808', 'wingward-b2-1808@example.invalid'),
  ('00000000-0000-0000-0000-000000001809', 'wingward-b2-1809@example.invalid'),
  ('00000000-0000-0000-0000-000000001810', 'wingward-b2-1810@example.invalid'),
  ('00000000-0000-0000-0000-000000001811', 'wingward-b2-1811@example.invalid'),
  ('00000000-0000-0000-0000-000000001812', 'wingward-b2-1812@example.invalid'),
  ('00000000-0000-0000-0000-000000001813', 'wingward-b2-1813@example.invalid'),
  ('00000000-0000-0000-0000-000000001814', 'wingward-b2-1814@example.invalid'),
  ('00000000-0000-0000-0000-000000001815', 'wingward-b2-1815@example.invalid'),
  ('00000000-0000-0000-0000-000000001816', 'wingward-b2-1816@example.invalid'),
  ('00000000-0000-0000-0000-000000001817', 'wingward-b2-1817@example.invalid');

-- The signup trigger creates these rows.  Every fixture uses the production
-- column constraints; the pure helper tests malformed composites separately.
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001801',
    nickname = 'B2 woman one',
    birth_date = '1990-01-01',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001801';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001802',
    nickname = 'B2 woman two',
    birth_date = '1990-01-02',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001802';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001803',
    nickname = 'B2 man one',
    birth_date = '1990-01-03',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'man',
    preferred_genders = ARRAY['man']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001803';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001804',
    nickname = 'B2 man two',
    birth_date = '1990-01-04',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'man',
    preferred_genders = ARRAY['man']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001804';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001805',
    nickname = 'B2 nonbinary one',
    birth_date = '1990-01-05',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'nonbinary',
    preferred_genders = ARRAY['nonbinary']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001805';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001806',
    nickname = 'B2 nonbinary two',
    birth_date = '1990-01-06',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'nonbinary',
    preferred_genders = ARRAY['nonbinary']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001806';

-- Outsider: a valid profile that is not a participant in the positive match.
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001807',
    nickname = 'B2 outsider',
    birth_date = '1990-01-07',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001807';

-- Independent negative fixtures.
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001808',
    nickname = 'B2 missing age',
    birth_date = '1990-01-08',
    age_verified_at = NULL,
    age_verification_method = NULL,
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001808';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001809',
    nickname = 'B2 incomplete settings',
    birth_date = '1990-01-09',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = NULL
WHERE auth_user_id = '00000000-0000-0000-0000-000000001809';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001810',
    nickname = 'B2 one-way woman',
    birth_date = '1990-01-10',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['man']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001810';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001811',
    nickname = 'B2 one-way man',
    birth_date = '1990-01-11',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'man',
    preferred_genders = ARRAY['man']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001811';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001812',
    nickname = 'B2 market JP',
    birth_date = '1990-01-12',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001812';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001813',
    nickname = 'B2 market US',
    birth_date = '1990-01-13',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'US',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001813';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001814',
    nickname = 'B2 no answer one',
    birth_date = '1990-01-14',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = NULL,
    preferred_genders = ARRAY[]::text[],
    preference_mode = 'no_answer',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001814';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001815',
    nickname = 'B2 no answer two',
    birth_date = '1990-01-15',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = NULL,
    preferred_genders = ARRAY[]::text[],
    preference_mode = 'no_answer',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001815';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001816',
    nickname = 'B2 cleanup one',
    birth_date = '1990-01-16',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001816';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001817',
    nickname = 'B2 cleanup two',
    birth_date = '1990-01-17',
    age_verified_at = '2026-09-06T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-06T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001817';

DO $$
DECLARE
  v_left public.user_profiles;
  v_right public.user_profiles;
  v_mutated public.user_profiles;
BEGIN
  SELECT profile_row.* INTO v_left
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001801';
  SELECT profile_row.* INTO v_right
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001802';

  IF NOT wingward_private.is_mutually_eligible(v_left, v_right) THEN
    RAISE EXCEPTION 'FAIL 18a: woman/woman mutual eligibility rejected';
  END IF;

  SELECT profile_row.* INTO v_left
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001803';
  SELECT profile_row.* INTO v_right
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001804';
  IF NOT wingward_private.is_mutually_eligible(v_left, v_right) THEN
    RAISE EXCEPTION 'FAIL 18b: man/man mutual eligibility rejected';
  END IF;

  SELECT profile_row.* INTO v_left
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001805';
  SELECT profile_row.* INTO v_right
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001806';
  IF NOT wingward_private.is_mutually_eligible(v_left, v_right) THEN
    RAISE EXCEPTION 'FAIL 18c: nonbinary/nonbinary mutual eligibility rejected';
  END IF;

  -- The lock helper must accept reversed arguments while locking in sorted
  -- UUID order.
  IF NOT wingward_private.lock_and_check_mutual_eligibility(
    '10000000-0000-0000-0000-000000001802',
    '10000000-0000-0000-0000-000000001801'
  ) THEN
    RAISE EXCEPTION 'FAIL 18d: reversed UUID lock helper rejected a valid pair';
  END IF;

  SELECT profile_row.* INTO v_left
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001810';
  SELECT profile_row.* INTO v_right
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001811';
  IF wingward_private.is_mutually_eligible(v_left, v_right) THEN
    RAISE EXCEPTION 'FAIL 18e: one-way preference passed';
  END IF;

  SELECT profile_row.* INTO v_left
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001801';
  SELECT profile_row.* INTO v_right
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001808';
  IF wingward_private.is_mutually_eligible(v_left, v_right) THEN
    RAISE EXCEPTION 'FAIL 18f: missing age verification passed';
  END IF;

  SELECT profile_row.* INTO v_right
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001809';
  IF wingward_private.is_mutually_eligible(v_left, v_right) THEN
    RAISE EXCEPTION 'FAIL 18g: missing completion marker passed';
  END IF;

  SELECT profile_row.* INTO v_left
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001812';
  SELECT profile_row.* INTO v_right
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001813';
  IF wingward_private.is_mutually_eligible(v_left, v_right) THEN
    RAISE EXCEPTION 'FAIL 18h: cross-market pair passed';
  END IF;

  SELECT profile_row.* INTO v_left
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001814';
  SELECT profile_row.* INTO v_right
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001815';
  IF wingward_private.is_mutually_eligible(v_left, v_right) THEN
    RAISE EXCEPTION 'FAIL 18i: no-answer pair passed';
  END IF;

  -- Composite-only malformed values are rejected independently of table
  -- constraints and unrelated nullable columns.
  SELECT profile_row.* INTO v_left
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001801';
  SELECT profile_row.* INTO v_right
  FROM public.user_profiles AS profile_row
  WHERE profile_row.id = '10000000-0000-0000-0000-000000001802';

  v_mutated := v_left;
  v_mutated.preferred_genders := ARRAY['woman', 'woman']::text[];
  IF wingward_private.is_mutually_eligible(v_mutated, v_right) THEN
    RAISE EXCEPTION 'FAIL 18j: duplicate preferences passed';
  END IF;

  v_mutated := v_left;
  v_mutated.preferred_genders := ARRAY['woman', 'unknown']::text[];
  IF wingward_private.is_mutually_eligible(v_mutated, v_right) THEN
    RAISE EXCEPTION 'FAIL 18k: unknown preference passed';
  END IF;

  v_mutated := v_left;
  v_mutated.preferred_genders := ARRAY['woman', NULL]::text[];
  IF wingward_private.is_mutually_eligible(v_mutated, v_right) THEN
    RAISE EXCEPTION 'FAIL 18l: NULL preference passed';
  END IF;

  v_mutated := v_left;
  v_mutated.age_verified_at := 'infinity'::timestamptz;
  IF wingward_private.is_mutually_eligible(v_mutated, v_right) THEN
    RAISE EXCEPTION 'FAIL 18m: non-finite age timestamp passed';
  END IF;

  IF wingward_private.is_mutually_eligible(NULL, v_right) THEN
    RAISE EXCEPTION 'FAIL 18n: NULL composite passed';
  END IF;

  RAISE NOTICE 'PASS 18a-n: pure predicate, sorted lock helper, identities, reciprocity, market, completion, age, no-answer, malformed arrays, and finite timestamps';
END $$;

DO $$
DECLARE
  private_function record;
  public_execute boolean;
BEGIN
  FOR private_function IN
    SELECT p.oid, n.nspname, p.proname
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'wingward_private'
      AND p.proname IN (
        'is_mutually_eligible',
        'lock_and_check_mutual_eligibility',
        'guard_match_mutual_eligibility'
      )
  LOOP
    SELECT EXISTS (
      SELECT 1
      FROM aclexplode(COALESCE(
        (SELECT proc.proacl FROM pg_proc AS proc WHERE proc.oid = private_function.oid),
        acldefault('f', (SELECT proc.proowner FROM pg_proc AS proc WHERE proc.oid = private_function.oid))
      )) AS privilege
      WHERE privilege.grantee = 0
        AND privilege.privilege_type = 'EXECUTE'
    ) INTO public_execute;

    IF public_execute
       OR has_function_privilege('anon', private_function.oid, 'EXECUTE')
       OR has_function_privilege('authenticated', private_function.oid, 'EXECUTE')
       OR has_function_privilege('service_role', private_function.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL 18o: private helper % has a direct API-role EXECUTE grant', private_function.proname;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'wingward_private'
      AND p.proname = 'is_mutually_eligible'
  ) THEN
    RAISE EXCEPTION 'FAIL 18p: pure private helper is missing';
  END IF;

  IF has_function_privilege('anon', 'public.are_match_participants_age_verified(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 18q: anon can execute the historical public helper';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.are_match_participants_age_verified(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.are_match_participants_age_verified(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 18r: existing public helper ACL was not preserved';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger AS trigger_row
    JOIN pg_class AS table_row ON table_row.oid = trigger_row.tgrelid
    JOIN pg_namespace AS schema_row ON schema_row.oid = table_row.relnamespace
    JOIN pg_proc AS function_row ON function_row.oid = trigger_row.tgfoid
    JOIN pg_namespace AS function_schema ON function_schema.oid = function_row.pronamespace
    WHERE schema_row.nspname = 'public'
      AND table_row.relname = 'matches'
      AND trigger_row.tgname = 'matches_guard_mutual_eligibility'
      AND function_schema.nspname = 'wingward_private'
      AND function_row.proname = 'guard_match_mutual_eligibility'
      AND trigger_row.tgenabled = 'O'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL 18s: matches eligibility trigger is not wired';
  END IF;

  RAISE NOTICE 'PASS 18o-s: private helper ACLs, historical helper ACL, and match trigger wiring';
END $$;

-- The three supported identities are all valid match INSERTs.
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES
  (
    '20000000-0000-0000-0000-000000001801',
    '10000000-0000-0000-0000-000000001801',
    '10000000-0000-0000-0000-000000001802'
  ),
  (
    '20000000-0000-0000-0000-000000001803',
    '10000000-0000-0000-0000-000000001803',
    '10000000-0000-0000-0000-000000001804'
  ),
  (
    '20000000-0000-0000-0000-000000001805',
    '10000000-0000-0000-0000-000000001805',
    '10000000-0000-0000-0000-000000001806'
  );

-- The historical helper remains participant-bound and now includes the strict
-- settings predicate.  An outsider gets false even for a fully eligible row.
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000001801"}';
DO $$
BEGIN
  IF NOT public.are_match_participants_age_verified(
    '20000000-0000-0000-0000-000000001801'::uuid
  ) THEN
    RAISE EXCEPTION 'FAIL 18t: participant could not pass strengthened helper';
  END IF;
END $$;

SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000001807"}';
DO $$
BEGIN
  IF public.are_match_participants_age_verified(
    '20000000-0000-0000-0000-000000001801'::uuid
  ) THEN
    RAISE EXCEPTION 'FAIL 18u: outsider learned a positive match helper bit';
  END IF;
END $$;

RESET role;
RESET request.jwt.claims;

SET LOCAL role = 'anon';
SET LOCAL request.jwt.claims = '{}';
DO $$
BEGIN
  PERFORM public.are_match_participants_age_verified(
    '20000000-0000-0000-0000-000000001801'::uuid
  );
  RAISE EXCEPTION 'FAIL 18v: authless caller executed the public helper';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS 18v: authless caller cannot execute the public helper';
END $$;
RESET role;
RESET request.jwt.claims;

-- Independent negative INSERT controls.  The fixed check_violation message
-- makes the guard failure non-disclosing while distinguishing it from an
-- accidental FK/unique/ordering rejection in this fixture.
DO $$
BEGIN
  INSERT INTO public.matches (id, user_a_id, user_b_id)
  VALUES (
    '20000000-0000-0000-0000-000000001808',
    '10000000-0000-0000-0000-000000001801',
    '10000000-0000-0000-0000-000000001808'
  );
  RAISE EXCEPTION 'FAIL 18w: missing-age pair was inserted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%matching eligibility%' THEN
      RAISE EXCEPTION 'FAIL 18w: missing-age pair failed for the wrong reason';
    END IF;
END $$;

DO $$
BEGIN
  INSERT INTO public.matches (id, user_a_id, user_b_id)
  VALUES (
    '20000000-0000-0000-0000-000000001809',
    '10000000-0000-0000-0000-000000001801',
    '10000000-0000-0000-0000-000000001809'
  );
  RAISE EXCEPTION 'FAIL 18x: incomplete-settings pair was inserted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%matching eligibility%' THEN
      RAISE EXCEPTION 'FAIL 18x: incomplete-settings pair failed for the wrong reason';
    END IF;
END $$;

DO $$
BEGIN
  INSERT INTO public.matches (id, user_a_id, user_b_id)
  VALUES (
    '20000000-0000-0000-0000-000000001810',
    '10000000-0000-0000-0000-000000001810',
    '10000000-0000-0000-0000-000000001811'
  );
  RAISE EXCEPTION 'FAIL 18y: one-way preference pair was inserted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%matching eligibility%' THEN
      RAISE EXCEPTION 'FAIL 18y: one-way preference pair failed for the wrong reason';
    END IF;
END $$;

DO $$
BEGIN
  INSERT INTO public.matches (id, user_a_id, user_b_id)
  VALUES (
    '20000000-0000-0000-0000-000000001812',
    '10000000-0000-0000-0000-000000001812',
    '10000000-0000-0000-0000-000000001813'
  );
  RAISE EXCEPTION 'FAIL 18z: cross-market pair was inserted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%matching eligibility%' THEN
      RAISE EXCEPTION 'FAIL 18z: cross-market pair failed for the wrong reason';
    END IF;
END $$;

DO $$
BEGIN
  INSERT INTO public.matches (id, user_a_id, user_b_id)
  VALUES (
    '20000000-0000-0000-0000-000000001814',
    '10000000-0000-0000-0000-000000001814',
    '10000000-0000-0000-0000-000000001815'
  );
  RAISE EXCEPTION 'FAIL 18aa: no-answer pair was inserted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%matching eligibility%' THEN
      RAISE EXCEPTION 'FAIL 18aa: no-answer pair failed for the wrong reason';
    END IF;
END $$;

DO $$
BEGIN
  INSERT INTO public.matches (id, user_a_id, user_b_id)
  VALUES (
    '20000000-0000-0000-0000-000000001815',
    '10000000-0000-0000-0000-000000001801',
    'ffffffff-ffff-ffff-ffff-ffffffffffff'
  );
  RAISE EXCEPTION 'FAIL 18ab: missing-profile pair was inserted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%matching eligibility%' THEN
      RAISE EXCEPTION 'FAIL 18ab: missing-profile pair failed for the wrong reason';
    END IF;
END $$;

-- Safe terminal and maintenance updates are available after a profile loses
-- eligibility, while score/content/participant changes remain forbidden.
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES (
  '20000000-0000-0000-0000-000000001816',
  '10000000-0000-0000-0000-000000001816',
  '10000000-0000-0000-0000-000000001817'
);

-- Request metadata is writable while the pair is still eligible.
UPDATE public.matches
SET updated_at = '2026-09-06T00:00:30Z',
    fox_conversation_requested_at = '2026-09-06T00:00:30Z'
WHERE id = '20000000-0000-0000-0000-000000001816';

UPDATE public.user_profiles
SET age_verified_at = NULL,
    age_verification_method = NULL
WHERE id = '10000000-0000-0000-0000-000000001817';

UPDATE public.matches
SET updated_at = '2026-09-06T00:01:00Z',
    fox_conversation_requested_at = NULL,
    fox_conversation_requested_by = NULL
WHERE id = '20000000-0000-0000-0000-000000001816';

UPDATE public.matches
SET status = 'fox_conversation_failed',
    updated_at = '2026-09-06T00:02:00Z'
WHERE id = '20000000-0000-0000-0000-000000001816';

DO $$
BEGIN
  UPDATE public.matches
  SET fox_conversation_requested_at = '2026-09-06T00:02:30Z',
      updated_at = '2026-09-06T00:02:30Z'
  WHERE id = '20000000-0000-0000-0000-000000001816';
  RAISE EXCEPTION 'FAIL 18ac: revoked pair accepted a fresh request timestamp';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%matching eligibility%' THEN
      RAISE EXCEPTION 'FAIL 18ac: fresh request update failed for the wrong reason';
    END IF;
END $$;

DO $$
BEGIN
  UPDATE public.matches
  SET status = 'fox_conversation_failed',
      profile_score = 99.00,
      updated_at = '2026-09-06T00:03:00Z'
  WHERE id = '20000000-0000-0000-0000-000000001816';
  RAISE EXCEPTION 'FAIL 18ac: terminal status hid a score change';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%matching eligibility%' THEN
      RAISE EXCEPTION 'FAIL 18ac: mixed terminal/score update failed for the wrong reason';
    END IF;
END $$;

DO $$
BEGIN
  UPDATE public.matches
  SET status = 'fox_conversation_failed',
      user_b_id = '10000000-0000-0000-0000-000000001808',
      updated_at = '2026-09-06T00:04:00Z'
  WHERE id = '20000000-0000-0000-0000-000000001816';
  RAISE EXCEPTION 'FAIL 18ad: terminal status hid a participant change';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%matching eligibility%' THEN
      RAISE EXCEPTION 'FAIL 18ad: mixed terminal/participant update failed for the wrong reason';
    END IF;
END $$;

DO $$
BEGIN
  RAISE NOTICE 'PASS 18: strict mutual eligibility, participant-bound read helper, private grants, match INSERT guard, independent negatives, and safe cleanup allow-list';
END $$;

ROLLBACK;
