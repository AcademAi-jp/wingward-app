-- Preserve the existing match guard and its private ACL/trigger.
-- One condition changes: an eligible replacement pair cannot relabel history.
-- All observed API writers assign participants at INSERT only.
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

  IF COALESCE(v_eligible, false) AND NOT v_participants_changed THEN
    RETURN NEW;
  END IF;

  -- An ineligible INSERT, or any UPDATE that changes the participant pair,
  -- cannot use a terminal status to smuggle participant/content/score
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

COMMENT ON FUNCTION wingward_private.guard_match_mutual_eligibility() IS
  'Private matches INSERT/UPDATE backstop. Participant IDs are immutable; current eligibility and narrow terminal/maintenance exceptions are preserved.';
