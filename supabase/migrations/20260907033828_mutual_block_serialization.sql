-- B2 block serialization backstop.
--
-- The existing mutual helper locks both current profiles in UUID order before
-- a protected write.  A block INSERT must take the conflicting profile locks
-- in the same order before the block row becomes visible; otherwise a block
-- can commit between the helper's profile read and its protected write.  This
-- migration keeps the public blocks INSERT policy and service-role API path
-- unchanged.  It adds only a private trigger lock, participant immutability,
-- and the post-lock block recheck used by the existing mutual guards.

-- The helper is VOLATILE on purpose.  Each PL/pgSQL statement gets a fresh
-- READ COMMITTED snapshot, so the block query after the two FOR SHARE locks
-- observes a block INSERT that held the conflicting locks and committed while
-- the protected writer waited.
-- Do not change this to STABLE or inline the block query into the profile
-- SELECTs: that would make the post-lock check use an older snapshot.
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

  -- The profile locks are the shared serialization point with the block
  -- INSERT trigger below.  Keep both SELECTs separate so the returned
  -- composites are the rows whose locks were actually acquired.
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

  -- This is intentionally a separate statement after both profile locks.
  -- SECURITY DEFINER lets the private helper see both directions even though
  -- the public blocks SELECT policy exposes only rows owned by the caller.
  IF EXISTS (
    SELECT 1
      FROM public.blocks AS block_row
     WHERE (block_row.blocker_id = v_low_id AND block_row.blocked_id = v_high_id)
        OR (block_row.blocker_id = v_high_id AND block_row.blocked_id = v_low_id)
  ) THEN
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
  'Private volatile pair check. Locks current user_profiles rows in sorted UUID order with FOR SHARE, then checks both block directions in a fresh statement before validating strict mutual eligibility.';

-- Validate the authenticated actor before taking any private profile lock.
-- Trusted service_role/postgres calls without a JWT remain usable for the API
-- and synthetic fixtures.  The function returns only a generic error and does
-- not expose whether the target profile or an opposite block exists.
CREATE OR REPLACE FUNCTION wingward_private.guard_block_insert_serialization()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_low_id uuid;
  v_high_id uuid;
  v_auth_user_id uuid;
  v_enforce_actor boolean;
  v_profile_id uuid;
BEGIN
  v_auth_user_id := (SELECT auth.uid());
  v_enforce_actor :=
    COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated'
    OR (
      COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none'
      AND session_user = 'authenticated'
    );

  -- Do this before either FOR NO KEY UPDATE statement.  It binds the public
  -- blocks INSERT policy to the same actor and prevents an authenticated
  -- caller from using lock timing as an oracle for another profile.
  IF v_enforce_actor THEN
    IF v_auth_user_id IS NULL THEN
      RAISE EXCEPTION 'block write is not eligible'
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT profile_row.id
      INTO v_profile_id
      FROM public.user_profiles AS profile_row
     WHERE profile_row.id = NEW.blocker_id
       AND profile_row.auth_user_id = v_auth_user_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'block write is not eligible'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF NEW.blocker_id IS NULL OR NEW.blocked_id IS NULL
     OR NEW.blocker_id = NEW.blocked_id THEN
    -- The table NOT NULL/CHECK constraints remain the authoritative result;
    -- fail here without acquiring a private profile lock.
    RETURN NEW;
  END IF;

  IF NEW.blocker_id < NEW.blocked_id THEN
    v_low_id := NEW.blocker_id;
    v_high_id := NEW.blocked_id;
  ELSE
    v_low_id := NEW.blocked_id;
    v_high_id := NEW.blocker_id;
  END IF;

  -- Match the helper's sorted profile lock order.  A block INSERT that wins
  -- these locks commits before a protected writer can acquire FOR SHARE;
  -- the writer's subsequent block SELECT then sees the committed row.
  SELECT profile_row.id
    INTO v_profile_id
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = v_low_id
   FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'block write is not eligible'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT profile_row.id
    INTO v_profile_id
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = v_high_id
   FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'block write is not eligible'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION wingward_private.guard_block_insert_serialization()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION wingward_private.guard_block_insert_serialization() IS
  'Private blocks INSERT/UPSERT backstop. Validates the authenticated blocker before locking both existing profiles in sorted UUID order with FOR NO KEY UPDATE.';

DROP TRIGGER IF EXISTS blocks_guard_insert_serialization ON public.blocks;
CREATE TRIGGER blocks_guard_insert_serialization
  BEFORE INSERT ON public.blocks
  FOR EACH ROW
  EXECUTE FUNCTION wingward_private.guard_block_insert_serialization();

-- Existing blocks rows remain removable restrictions.  Do not add profile
-- locks to DELETE: a block-row -> profile lock would invert the profile ->
-- block-row order above and could deadlock unblock with a concurrent insert.

CREATE OR REPLACE FUNCTION wingward_private.freeze_block_participants()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.blocker_id IS DISTINCT FROM OLD.blocker_id
     OR NEW.blocked_id IS DISTINCT FROM OLD.blocked_id THEN
    RAISE EXCEPTION 'block participants are immutable'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION wingward_private.freeze_block_participants()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION wingward_private.freeze_block_participants() IS
  'Private blocks UPDATE backstop. Blocker and blocked profile IDs cannot be relabeled; cleanup/delete remains available through the existing API path.';

DROP TRIGGER IF EXISTS blocks_freeze_participants ON public.blocks;
CREATE TRIGGER blocks_freeze_participants
  BEFORE UPDATE ON public.blocks
  FOR EACH ROW
  EXECUTE FUNCTION wingward_private.freeze_block_participants();
