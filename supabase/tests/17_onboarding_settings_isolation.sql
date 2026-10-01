-- B1: onboarding settings are owner-only and direct authenticated writes stay
-- revoked. This synthetic acceptance script was authored but NOT RUN here:
-- this task does not start a Supabase/Postgres runtime. Run it with the
-- existing migration test harness after applying the new migration.

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000d1', 'wingward-onboarding-a@example.invalid'),
  ('00000000-0000-0000-0000-0000000000d2', 'wingward-onboarding-b@example.invalid');

-- The auth trigger owns profile creation. Move only these synthetic rows to
-- stable IDs, then set private settings as the service-role test owner.
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000d1',
    nickname = 'Onboarding A',
    ui_locale = 'ja',
    dating_market = 'JP',
    conversation_language = 'en',
    timezone = 'Asia/Tokyo',
    distance_unit = 'km',
    gender_identity = NULL,
    gender_visibility = 'private',
    preferred_genders = ARRAY[]::text[],
    preference_mode = 'no_answer',
    location_mode = 'not_set',
    station_id = NULL,
    coarse_area_id = NULL,
    onboarding_settings_completed_at = now()
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000d1';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000d2',
    nickname = 'Onboarding B',
    ui_locale = 'en',
    dating_market = 'US',
    conversation_language = 'en',
    timezone = 'America/Los_Angeles',
    distance_unit = 'mi',
    gender_identity = 'woman',
    gender_visibility = 'private',
    preferred_genders = ARRAY['man']::text[],
    preference_mode = 'selected',
    location_mode = 'no_transit',
    station_id = NULL,
    coarse_area_id = 'us-ca-san-francisco',
    onboarding_settings_completed_at = now()
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000d2';

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000d1"}';

DO $$
DECLARE
  own_rows integer;
  other_rows integer;
  own_identity text;
  own_preferences text[];
BEGIN
  SELECT count(*) INTO own_rows
  FROM public.user_profiles
  WHERE id = '10000000-0000-0000-0000-0000000000d1';
  IF own_rows <> 1 THEN
    RAISE EXCEPTION 'FAIL B1: authenticated owner cannot read own onboarding row';
  END IF;

  SELECT count(*) INTO other_rows
  FROM public.user_profiles
  WHERE id = '10000000-0000-0000-0000-0000000000d2';
  IF other_rows <> 0 THEN
    RAISE EXCEPTION 'FAIL B1: authenticated owner can read another profile onboarding row';
  END IF;

  SELECT gender_identity, preferred_genders
  INTO own_identity, own_preferences
  FROM public.user_profiles
  WHERE id = '10000000-0000-0000-0000-0000000000d1';
  IF own_identity IS NOT NULL OR own_preferences <> ARRAY[]::text[] THEN
    RAISE EXCEPTION 'FAIL B1: owner onboarding settings were not returned intact';
  END IF;
  RAISE NOTICE 'PASS B1: owner can read own settings and cross-owner settings are hidden';
END $$;

DO $$
BEGIN
  INSERT INTO public.user_profiles (auth_user_id, nickname)
  VALUES ('00000000-0000-0000-0000-0000000000d1', 'forged onboarding row');
  RAISE EXCEPTION 'FAIL B1: authenticated JWT inserted user_profiles directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS B1: authenticated user_profiles INSERT rejected';
END $$;

DO $$
BEGIN
  UPDATE public.user_profiles
  SET gender_identity = 'man', preferred_genders = ARRAY['woman']::text[]
  WHERE id = '10000000-0000-0000-0000-0000000000d1';
  RAISE EXCEPTION 'FAIL B1: authenticated JWT updated private onboarding settings directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS B1: authenticated user_profiles UPDATE rejected for private settings';
END $$;

RESET role;
RESET request.jwt.claims;
ROLLBACK;
