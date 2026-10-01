-- Terminal expiry after block/preference revocation must not wedge the janitor.
-- Preserve all lineage/actor/admission guards; only exact destructive cleanup bypasses eligibility.
CREATE OR REPLACE FUNCTION wingward_private.guard_meetup_mutual_eligibility()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_match_a uuid; v_match_b uuid; v_auth_user_id uuid; v_enforce_actor boolean;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.match_id IS DISTINCT FROM OLD.match_id OR NEW.initiator_id IS DISTINCT FROM OLD.initiator_id) THEN
    RAISE EXCEPTION 'meetup write is not eligible' USING ERRCODE = 'check_violation';
  END IF;
  SELECT match_row.user_a_id, match_row.user_b_id INTO v_match_a, v_match_b
    FROM public.matches AS match_row WHERE match_row.id = NEW.match_id;
  IF NOT FOUND OR NEW.initiator_id IS NULL OR NOT (NEW.initiator_id = v_match_a OR NEW.initiator_id = v_match_b) THEN
    RAISE EXCEPTION 'meetup write is not eligible' USING ERRCODE = 'check_violation';
  END IF;
  v_auth_user_id := (SELECT auth.uid());
  v_enforce_actor := COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated'
    OR (COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none' AND session_user = 'authenticated');
  IF v_enforce_actor AND (v_auth_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles AS actor_profile WHERE actor_profile.id = NEW.initiator_id AND actor_profile.auth_user_id = v_auth_user_id
  )) THEN
    RAISE EXCEPTION 'meetup write is not eligible' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN RETURN NEW; END IF;
    -- Cancellation/decline cannot carry consent, deadline or content mutations.
    IF NEW.status IS DISTINCT FROM OLD.status AND (
      (OLD.status = 'intent_pending' AND NEW.status IN ('declined', 'cancelled'))
      OR (OLD.status IN ('intent_pending', 'intent_matched', 'verifying', 'arranging', 'proposed', 'confirmed', 'checked_in') AND NEW.status = 'cancelled')
    ) AND pg_catalog.to_jsonb(NEW) - ARRAY['status','updated_at']::text[] = pg_catalog.to_jsonb(OLD) - ARRAY['status','updated_at']::text[] THEN RETURN NEW; END IF;
    -- Exact columns used by claim_expired_meetups and the chat-private-input janitor.
    IF OLD.status IN ('intent_pending','verifying','arranging','proposed','confirmed') AND NEW.status = 'expired'
      AND NEW.intent_expires_at IS NULL AND NEW.proposal_expires_at IS NULL
      AND pg_catalog.to_jsonb(NEW) - ARRAY['status','intent_expires_at','proposal_expires_at','updated_at']::text[]
        = pg_catalog.to_jsonb(OLD) - ARRAY['status','intent_expires_at','proposal_expires_at','updated_at']::text[] THEN RETURN NEW; END IF;
    IF OLD.status = 'arranging' AND NEW.status = 'arrange_failed' AND NEW.proposal_expires_at IS NULL
      AND pg_catalog.to_jsonb(NEW) - ARRAY['status','proposal_expires_at','updated_at']::text[]
        = pg_catalog.to_jsonb(OLD) - ARRAY['status','proposal_expires_at','updated_at']::text[] THEN RETURN NEW; END IF;
  END IF;
  IF wingward_private.lock_and_check_mutual_eligibility(v_match_a,v_match_b) THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'meetup write is not eligible' USING ERRCODE = 'check_violation';
END;
$$;
REVOKE ALL ON FUNCTION wingward_private.guard_meetup_mutual_eligibility() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.guard_meetup_mutual_eligibility() IS 'Private meetup write backstop. Freezes match/initiator lineage and checks current mutual profiles; only no-ops and narrow cancellation, decline, expiry or failure cleanup bypass eligibility.';
