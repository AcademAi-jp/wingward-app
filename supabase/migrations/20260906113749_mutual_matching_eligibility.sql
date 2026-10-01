-- B2 SQL foundation: current mutual matching eligibility and write fencing.
--
-- This migration deliberately stops at the parent match boundary.  Child-row
-- and meetup RPC backstops are separate follow-up work.  The predicate reads
-- only owner-scoped internal profile fields; it never returns a profile row.

-- The private schema is created by the merged meetup migration.  Revoke the
-- new helpers from every API role explicitly below: trigger and SECURITY
-- DEFINER callers run under the function owner, so no direct EXECUTE grant is
-- needed.

-- Strict, non-locking two-profile predicate.  Do not use `user_profiles.gender`
-- or infer an answer from legacy fields.  The explicit array checks also keep
-- this safe for malformed composite values constructed outside table CHECKs.
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

-- Lock both current rows in UUID order and validate those locked row values.
-- Two statements are intentional: each SELECT returns the row whose FOR SHARE
-- lock was acquired, rather than validating a stale pre-lock snapshot.
CREATE OR REPLACE FUNCTION wingward_private.lock_and_check_mutual_eligibility(
  p_first_id uuid,
  p_second_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_low_id uuid;
  v_high_id uuid;
  v_low_profile public.user_profiles;
  v_high_profile public.user_profiles;
BEGIN
  IF p_first_id IS NULL OR p_second_id IS NULL OR p_first_id = p_second_id THEN
    RETURN false;
  END IF;

  IF p_first_id < p_second_id THEN
    v_low_id := p_first_id;
    v_high_id := p_second_id;
  ELSE
    v_low_id := p_second_id;
    v_high_id := p_first_id;
  END IF;

  SELECT profile_row.*
    INTO v_low_profile
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = v_low_id
   FOR SHARE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  SELECT profile_row.*
    INTO v_high_profile
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = v_high_id
   FOR SHARE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  RETURN COALESCE(
    wingward_private.is_mutually_eligible(v_low_profile, v_high_profile),
    false
  );
END;
$$;

REVOKE ALL ON FUNCTION wingward_private.lock_and_check_mutual_eligibility(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION wingward_private.lock_and_check_mutual_eligibility(uuid, uuid) IS
  'Private volatile pair check. Locks existing user_profiles rows in sorted UUID order with FOR SHARE and validates the locked records.';

-- Preserve the historical public signature and participant ownership check,
-- while adding the strict current-settings predicate as its non-locking read
-- gate.  The function remains safe for RLS policies and reveals no pair bit to
-- an outsider or an authless caller.
CREATE OR REPLACE FUNCTION public.are_match_participants_age_verified(p_match_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.matches AS match_row
    JOIN public.user_profiles AS first_profile
      ON first_profile.id = match_row.user_a_id
    JOIN public.user_profiles AS second_profile
      ON second_profile.id = match_row.user_b_id
    WHERE match_row.id = p_match_id
      AND (
        first_profile.auth_user_id = (SELECT auth.uid())
        OR second_profile.auth_user_id = (SELECT auth.uid())
      )
      AND wingward_private.is_mutually_eligible(first_profile, second_profile)
  )
$$;

REVOKE ALL ON FUNCTION public.are_match_participants_age_verified(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.are_match_participants_age_verified(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.are_match_participants_age_verified(uuid) IS
  'Historical name retained for compatibility; returns true only for an authenticated match participant when both profiles pass current strict mutual matching eligibility.';

-- A match INSERT and an ordinary eligible UPDATE must use the current locked
-- profile rows.  When eligibility was revoked, only narrow terminal cleanup
-- and request-maintenance writes remain available.  JSONB row subtraction is
-- deliberate: every current column must remain unchanged except the listed
-- allow-list, so a future column cannot hide behind a safe status update.
CREATE OR REPLACE FUNCTION wingward_private.guard_match_mutual_eligibility()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_eligible boolean;
  v_participants_changed boolean := false;
BEGIN
  v_participants_changed := TG_OP = 'UPDATE'
    AND (
      NEW.user_a_id IS DISTINCT FROM OLD.user_a_id
      OR NEW.user_b_id IS DISTINCT FROM OLD.user_b_id
    );

  v_eligible := wingward_private.lock_and_check_mutual_eligibility(
    NEW.user_a_id,
    NEW.user_b_id
  );

  IF COALESCE(v_eligible, false) THEN
    RETURN NEW;
  END IF;

  -- An INSERT, or an UPDATE that changes the relationship to an ineligible
  -- pair, cannot use a terminal status to smuggle participant/content/score
  -- changes through the exception path.
  IF TG_OP = 'INSERT' OR v_participants_changed THEN
    RAISE EXCEPTION 'match participants fail matching eligibility'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Failure/expiry/decline cleanup may change only status and its timestamp.
  IF NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN (
       'fox_conversation_failed',
       'chat_request_expired',
       'chat_request_declined'
     )
     AND pg_catalog.to_jsonb(NEW) - ARRAY['status', 'updated_at']::text[]
       = pg_catalog.to_jsonb(OLD) - ARRAY['status', 'updated_at']::text[] THEN
    RETURN NEW;
  END IF;

  -- Request bookkeeping and the row timestamp are the only non-terminal
  -- maintenance fields permitted after eligibility is revoked.
  IF NEW.status IS NOT DISTINCT FROM OLD.status
     AND pg_catalog.to_jsonb(NEW)
       - ARRAY[
           'updated_at',
           'fox_conversation_requested_at',
           'fox_conversation_requested_by'
         ]::text[]
       = pg_catalog.to_jsonb(OLD)
       - ARRAY[
           'updated_at',
           'fox_conversation_requested_at',
           'fox_conversation_requested_by'
         ]::text[] THEN
    -- Request metadata may remain unchanged, or be cleared as a pair during
    -- terminal cleanup.  A fresh request after revocation is not maintenance.
    IF (
      (
        NEW.fox_conversation_requested_at IS NOT DISTINCT FROM OLD.fox_conversation_requested_at
        AND NEW.fox_conversation_requested_by IS NOT DISTINCT FROM OLD.fox_conversation_requested_by
      )
      OR (
        NEW.fox_conversation_requested_at IS NULL
        AND NEW.fox_conversation_requested_by IS NULL
      )
    ) THEN
    RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'match participants fail matching eligibility'
    USING ERRCODE = 'check_violation';
END;
$$;

REVOKE ALL ON FUNCTION wingward_private.guard_match_mutual_eligibility()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION wingward_private.guard_match_mutual_eligibility() IS
  'Private matches INSERT/UPDATE backstop. Uses the sorted FOR SHARE pair check and permits only narrow terminal or maintenance changes after eligibility revocation.';

DROP TRIGGER IF EXISTS matches_guard_mutual_eligibility ON public.matches;
CREATE TRIGGER matches_guard_mutual_eligibility
  BEFORE INSERT OR UPDATE ON public.matches
  FOR EACH ROW
  EXECUTE FUNCTION wingward_private.guard_match_mutual_eligibility();
