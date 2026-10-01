-- B1: server-owned onboarding settings and a private completion marker.
--
-- The API uses service_role for these writes.  The authenticated client must
-- not be able to write user_profiles directly: the existing server-owned
-- profile boundary remains in force below.

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS ui_locale text,
  ADD COLUMN IF NOT EXISTS dating_market text,
  ADD COLUMN IF NOT EXISTS conversation_language text,
  ADD COLUMN IF NOT EXISTS distance_unit text,
  ADD COLUMN IF NOT EXISTS gender_identity text,
  ADD COLUMN IF NOT EXISTS gender_visibility text,
  ADD COLUMN IF NOT EXISTS preferred_genders text[] NOT NULL DEFAULT ARRAY[]::text[],
  ADD COLUMN IF NOT EXISTS preference_mode text,
  ADD COLUMN IF NOT EXISTS location_mode text,
  ADD COLUMN IF NOT EXISTS station_id text,
  ADD COLUMN IF NOT EXISTS coarse_area_id text,
  ADD COLUMN IF NOT EXISTS onboarding_settings_completed_at timestamptz;

-- Preserve the known legacy language/region values for existing rows.  New
-- rows receive conservative non-sensitive defaults; matching preferences and
-- locations remain no-answer/unset until the owner completes this endpoint.
UPDATE public.user_profiles
SET ui_locale = language
WHERE ui_locale IS NULL;

UPDATE public.user_profiles
SET dating_market = region
WHERE dating_market IS NULL;

UPDATE public.user_profiles
SET conversation_language = language
WHERE conversation_language IS NULL;

UPDATE public.user_profiles
SET distance_unit = 'km'
WHERE distance_unit IS NULL;

UPDATE public.user_profiles
SET gender_visibility = 'private'
WHERE gender_visibility IS NULL;

UPDATE public.user_profiles
SET preference_mode = 'no_answer'
WHERE preference_mode IS NULL;

UPDATE public.user_profiles
SET location_mode = 'not_set'
WHERE location_mode IS NULL;

ALTER TABLE public.user_profiles
  ALTER COLUMN ui_locale SET DEFAULT 'ja',
  ALTER COLUMN ui_locale SET NOT NULL,
  ALTER COLUMN dating_market SET DEFAULT 'US',
  ALTER COLUMN dating_market SET NOT NULL,
  ALTER COLUMN conversation_language SET DEFAULT 'ja',
  ALTER COLUMN conversation_language SET NOT NULL,
  ALTER COLUMN distance_unit SET DEFAULT 'km',
  ALTER COLUMN distance_unit SET NOT NULL,
  ALTER COLUMN gender_visibility SET DEFAULT 'private',
  ALTER COLUMN gender_visibility SET NOT NULL,
  ALTER COLUMN preference_mode SET DEFAULT 'no_answer',
  ALTER COLUMN preference_mode SET NOT NULL,
  ALTER COLUMN location_mode SET DEFAULT 'not_set',
  ALTER COLUMN location_mode SET NOT NULL;

ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_ui_locale_check
    CHECK (ui_locale IN ('ja', 'en')),
  ADD CONSTRAINT user_profiles_dating_market_check
    CHECK (dating_market IN ('JP', 'US')),
  ADD CONSTRAINT user_profiles_conversation_language_check
    CHECK (conversation_language IN ('ja', 'en')),
  ADD CONSTRAINT user_profiles_distance_unit_check
    CHECK (distance_unit IN ('km', 'mi')),
  ADD CONSTRAINT user_profiles_gender_identity_check
    CHECK (gender_identity IS NULL OR gender_identity IN ('woman', 'man', 'nonbinary')),
  ADD CONSTRAINT user_profiles_gender_visibility_check
    CHECK (gender_visibility = 'private'),
  ADD CONSTRAINT user_profiles_preferred_genders_check
    CHECK (
      preferred_genders <@ ARRAY['woman', 'man', 'nonbinary']::text[]
      AND pg_catalog.cardinality(preferred_genders) <= 3
      AND pg_catalog.cardinality(preferred_genders) = pg_catalog.cardinality(
        pg_catalog.array_remove(
          ARRAY[
            CASE WHEN 'woman' = ANY(preferred_genders) THEN 'woman'::text END,
            CASE WHEN 'man' = ANY(preferred_genders) THEN 'man'::text END,
            CASE WHEN 'nonbinary' = ANY(preferred_genders) THEN 'nonbinary'::text END
          ],
          NULL
        )
      )
    ),
  ADD CONSTRAINT user_profiles_preference_mode_check
    CHECK (
      (preference_mode = 'no_answer' AND pg_catalog.cardinality(preferred_genders) = 0)
      OR (preference_mode = 'selected' AND pg_catalog.cardinality(preferred_genders) > 0)
    ),
  ADD CONSTRAINT user_profiles_location_mode_check
    CHECK (
      (location_mode = 'station' AND station_id IS NOT NULL AND coarse_area_id IS NOT NULL)
      OR (location_mode = 'no_transit' AND dating_market = 'US' AND station_id IS NULL AND coarse_area_id IS NOT NULL)
      OR (location_mode = 'not_set' AND station_id IS NULL AND coarse_area_id IS NULL)
    ),
  ADD CONSTRAINT user_profiles_station_id_shape_check
    CHECK (station_id IS NULL OR pg_catalog.length(pg_catalog.btrim(station_id)) BETWEEN 1 AND 100),
  ADD CONSTRAINT user_profiles_coarse_area_id_shape_check
    CHECK (coarse_area_id IS NULL OR pg_catalog.length(pg_catalog.btrim(coarse_area_id)) BETWEEN 1 AND 100);

COMMENT ON COLUMN public.user_profiles.ui_locale IS 'Owner-only saved UI locale (ja or en); legacy language is a compatibility alias.';
COMMENT ON COLUMN public.user_profiles.dating_market IS 'Owner-only dating market (JP or US); legacy region is a compatibility alias.';
COMMENT ON COLUMN public.user_profiles.conversation_language IS 'Owner-only language for future Wing Fox conversation output.';
COMMENT ON COLUMN public.user_profiles.gender_identity IS 'Owner-only matching identity; NULL means no answer and is never inferred from legacy gender.';
COMMENT ON COLUMN public.user_profiles.preferred_genders IS 'Owner-only explicit matching categories; empty means no answer.';
COMMENT ON COLUMN public.user_profiles.gender_visibility IS 'Owner-only visibility setting; only private is supported in B1.';
COMMENT ON COLUMN public.user_profiles.station_id IS 'Owner-only fixture catalog station ID; never an address or coordinate.';
COMMENT ON COLUMN public.user_profiles.coarse_area_id IS 'Owner-only fixture catalog coarse-area ID.';
COMMENT ON COLUMN public.user_profiles.onboarding_settings_completed_at IS 'Server-set marker used to distinguish an explicit settings save from legacy defaults.';

-- Reassert the server-owned profile boundary from the age-verification
-- lockdown migration.  No client-side INSERT/UPDATE grant is introduced by
-- adding these columns; service_role remains the API write path.
REVOKE INSERT, UPDATE ON TABLE public.user_profiles FROM PUBLIC, anon, authenticated;
