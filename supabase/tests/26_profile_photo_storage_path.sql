-- Profile-photo storage path regression checks. Synthetic/local only; this
-- file does not create a bucket or connect to a hosted Supabase project.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'user_profiles'
      AND column_name = 'avatar_storage_path'
  ) THEN
    RAISE EXCEPTION 'FAIL profile photo: avatar_storage_path column is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.user_profiles'::regclass
      AND conname = 'user_profiles_avatar_storage_path_check'
      AND contype = 'c' AND convalidated
  ) THEN
    RAISE EXCEPTION 'FAIL profile photo: canonical path constraint is missing';
  END IF;

  IF has_table_privilege('anon', 'public.user_profiles', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.user_profiles', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL profile photo: direct profile UPDATE remains granted';
  END IF;

END $$;

INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-00000000c265', 'wingward-test-sql26-photo@example.invalid');
UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-00000000c265'
 WHERE auth_user_id = '00000000-0000-0000-0000-00000000c265';

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_canonical text := 'profile-photos/10000000-0000-0000-0000-00000000c265/20000000-0000-0000-0000-00000000c265.png';
  v_path text;
  v_rejected boolean;
  v_constraint text;
BEGIN
  -- This DB guard bounds/trims server-owned paths. Owner/filename semantics
  -- are enforced by the API's owner-path builder and read/write validators;
  -- do not imply this SQL prefix already supplies those later API callers.
  FOREACH v_path IN ARRAY ARRAY[NULL::text, 'a', repeat('a', 500), v_canonical] LOOP
    UPDATE public.user_profiles SET avatar_storage_path = v_path
     WHERE id = '10000000-0000-0000-0000-00000000c265';
    IF NOT FOUND OR (SELECT avatar_storage_path FROM public.user_profiles
       WHERE id = '10000000-0000-0000-0000-00000000c265') IS DISTINCT FROM v_path THEN
      RAISE EXCEPTION 'FAIL profile photo: valid bounded/canonical path rejected';
    END IF;
  END LOOP;

  FOREACH v_path IN ARRAY ARRAY['', ' ', ' ' || v_canonical, v_canonical || ' ',
      '/' || v_canonical, 'profile-photos//photo.png', repeat('a', 501)] LOOP
    v_rejected := false;
    BEGIN
      UPDATE public.user_profiles SET avatar_storage_path = v_path
       WHERE id = '10000000-0000-0000-0000-00000000c265';
    EXCEPTION WHEN check_violation THEN
      GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
      IF v_constraint IS DISTINCT FROM 'user_profiles_avatar_storage_path_check' THEN
        RAISE EXCEPTION 'FAIL profile photo: wrong constraint rejected malformed path';
      END IF;
      v_rejected := true;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'FAIL profile photo: malformed path was accepted';
    END IF;
    IF (SELECT avatar_storage_path FROM public.user_profiles
        WHERE id = '10000000-0000-0000-0000-00000000c265') IS DISTINCT FROM v_canonical THEN
      RAISE EXCEPTION 'FAIL profile photo: rejected path changed stored value';
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS profile photo: real updates accept valid paths and reject malformed paths without changing state';
END $$;

ROLLBACK;
