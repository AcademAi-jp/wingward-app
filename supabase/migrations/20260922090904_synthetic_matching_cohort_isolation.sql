-- Owner-authorized fixed cohort. This registry is not client-writable and
-- stays active after the temporary runtime window has expired.
CREATE OR REPLACE FUNCTION wingward_private.synthetic_matching_member(p_id uuid)
RETURNS boolean LANGUAGE sql IMMUTABLE SECURITY INVOKER SET search_path = ''
AS $$ SELECT coalesce(p_id IN (
 '96b31c0a-b8c4-4536-ada2-f3537dadd146'::uuid,
 '9d836fee-7b93-41ce-b577-34a63006aaea'::uuid,
 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'::uuid
), false) $$;
REVOKE ALL ON FUNCTION wingward_private.synthetic_matching_member(uuid)
FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION wingward_private.is_mutually_eligible(
  p_left public.user_profiles,
  p_right public.user_profiles
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    p_left.id IS NOT NULL
    AND p_right.id IS NOT NULL
    AND p_left.id <> p_right.id
    AND wingward_private.synthetic_matching_member(p_left.id) = wingward_private.synthetic_matching_member(p_right.id)
    AND p_left.age_verified_at IS NOT NULL
    AND p_right.age_verified_at IS NOT NULL
    AND pg_catalog.isfinite(p_left.age_verified_at)
    AND pg_catalog.isfinite(p_right.age_verified_at)
    AND p_left.onboarding_settings_completed_at IS NOT NULL
    AND p_right.onboarding_settings_completed_at IS NOT NULL
    AND pg_catalog.isfinite(p_left.onboarding_settings_completed_at)
    AND pg_catalog.isfinite(p_right.onboarding_settings_completed_at)
    AND p_left.gender_identity IN ('woman', 'man', 'nonbinary')
    AND p_right.gender_identity IN ('woman', 'man', 'nonbinary')
    AND p_left.dating_market IN ('JP', 'US')
    AND p_right.dating_market = p_left.dating_market
    AND p_left.preference_mode = 'selected'
    AND p_right.preference_mode = 'selected'
    AND p_left.preferred_genders IS NOT NULL
    AND p_right.preferred_genders IS NOT NULL
    AND pg_catalog.array_ndims(p_left.preferred_genders) = 1
    AND pg_catalog.array_ndims(p_right.preferred_genders) = 1
    AND pg_catalog.cardinality(p_left.preferred_genders) > 0
    AND pg_catalog.cardinality(p_right.preferred_genders) > 0
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.unnest(p_left.preferred_genders) AS preference(value)
      WHERE preference.value IS NULL
         OR preference.value NOT IN ('woman', 'man', 'nonbinary')
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.unnest(p_right.preferred_genders) AS preference(value)
      WHERE preference.value IS NULL
         OR preference.value NOT IN ('woman', 'man', 'nonbinary')
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.unnest(p_left.preferred_genders) AS preference(value)
      GROUP BY preference.value
      HAVING pg_catalog.count(*) > 1
    )
    AND NOT EXISTS (
      SELECT 1
      FROM pg_catalog.unnest(p_right.preferred_genders) AS preference(value)
      GROUP BY preference.value
      HAVING pg_catalog.count(*) > 1
    )
    AND p_right.gender_identity = ANY (p_left.preferred_genders)
    AND p_left.gender_identity = ANY (p_right.preferred_genders),
    false
  )
$$;

REVOKE ALL ON FUNCTION wingward_private.is_mutually_eligible(
  public.user_profiles,
  public.user_profiles
) FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION wingward_private.is_mutually_eligible(
  public.user_profiles,
  public.user_profiles
) IS
  'Private strict mutual matching predicate. Accepts two composite snapshots and returns only a boolean; callers must not expose profile fields.';


-- Abort this migration atomically if the new permanent boundary is wrong.
DO $$
DECLARE
  a public.user_profiles;
  b public.user_profiles;
  outsider public.user_profiles;
BEGIN
  a := jsonb_populate_record(NULL::public.user_profiles, '{"id":"96b31c0a-b8c4-4536-ada2-f3537dadd146","age_verified_at":"2026-09-22T00:00:00Z","onboarding_settings_completed_at":"2026-09-22T00:00:00Z","gender_identity":"nonbinary","preferred_genders":["nonbinary"],"preference_mode":"selected","dating_market":"JP"}'::jsonb);
  b := a; b.id := '9d836fee-7b93-41ce-b577-34a63006aaea';
  outsider := a; outsider.id := '11111111-1111-4111-8111-111111111111';
  IF NOT wingward_private.is_mutually_eligible(a,b)
     OR wingward_private.is_mutually_eligible(a,outsider)
     OR wingward_private.is_mutually_eligible(outsider,a) THEN
    RAISE EXCEPTION 'Synthetic cohort isolation assertion failed';
  END IF;
  IF has_function_privilege('authenticated','wingward_private.synthetic_matching_member(uuid)','execute')
     OR has_function_privilege('anon','wingward_private.synthetic_matching_member(uuid)','execute') THEN
    RAISE EXCEPTION 'Synthetic registry privileges assertion failed';
  END IF;
END $$;
