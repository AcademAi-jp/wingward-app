-- B2 private meetup child write guards. Local source only; no deployment.
-- No ancestor locks in child UPDATE triggers. Safe cleanup avoids profile locks.
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
    -- Exact columns used by claim_expired_meetups.
    IF OLD.status IN ('intent_pending','proposed','confirmed') AND NEW.status = 'expired'
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

CREATE OR REPLACE FUNCTION wingward_private.guard_meetup_proposal_mutual_eligibility()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_match_id uuid; v_match_a uuid; v_match_b uuid;
  v_generated_match_id uuid; v_generated_meetup_id uuid; v_generated_purpose text;
  v_auth_user_id uuid; v_enforce_actor boolean;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.meetup_id IS DISTINCT FROM OLD.meetup_id OR NEW.attempt_number IS DISTINCT FROM OLD.attempt_number OR NEW.generated_by_conversation_id IS DISTINCT FROM OLD.generated_by_conversation_id) THEN
    RAISE EXCEPTION 'meetup proposal write is not eligible' USING ERRCODE = 'check_violation';
  END IF;
  SELECT meetup_row.match_id INTO v_match_id FROM public.meetups AS meetup_row WHERE meetup_row.id = NEW.meetup_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'meetup proposal write is not eligible' USING ERRCODE = 'check_violation'; END IF;
  SELECT match_row.user_a_id,match_row.user_b_id INTO v_match_a,v_match_b FROM public.matches AS match_row WHERE match_row.id = v_match_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'meetup proposal write is not eligible' USING ERRCODE = 'check_violation'; END IF;
  -- Current persistence leaves this nullable field unset. A supplied source
  -- must be this exact meetup's scheduling conversation.
  IF NEW.generated_by_conversation_id IS NOT NULL THEN
    SELECT conversation_row.match_id,conversation_row.meetup_id,conversation_row.purpose
      INTO v_generated_match_id,v_generated_meetup_id,v_generated_purpose
      FROM public.fox_conversations AS conversation_row WHERE conversation_row.id = NEW.generated_by_conversation_id;
    IF NOT FOUND OR v_generated_match_id IS DISTINCT FROM v_match_id OR v_generated_meetup_id IS DISTINCT FROM NEW.meetup_id OR v_generated_purpose IS DISTINCT FROM 'scheduling' THEN
      RAISE EXCEPTION 'meetup proposal write is not eligible' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  v_auth_user_id := (SELECT auth.uid());
  v_enforce_actor := COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated'
    OR (COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none' AND session_user = 'authenticated');
  IF v_enforce_actor AND (v_auth_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles AS actor_profile WHERE actor_profile.auth_user_id = v_auth_user_id AND actor_profile.id IN (v_match_a,v_match_b)
  )) THEN RAISE EXCEPTION 'meetup proposal write is not eligible' USING ERRCODE = 'check_violation'; END IF;
  IF TG_OP = 'UPDATE' AND pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN RETURN NEW; END IF;
  IF wingward_private.lock_and_check_mutual_eligibility(v_match_a,v_match_b) THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'meetup proposal write is not eligible' USING ERRCODE = 'check_violation';
END;
$$;
REVOKE ALL ON FUNCTION wingward_private.guard_meetup_proposal_mutual_eligibility() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.guard_meetup_proposal_mutual_eligibility() IS 'Private proposal write backstop. Freezes meetup/attempt/source lineage, validates optional scheduling source, locks current mutual profiles and permits only exact no-ops after revocation.';

CREATE OR REPLACE FUNCTION wingward_private.guard_meetup_proposal_response_mutual_eligibility()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_meetup_id uuid; v_match_id uuid; v_match_a uuid; v_match_b uuid;
  v_auth_user_id uuid; v_enforce_actor boolean;
BEGIN
  IF TG_OP = 'UPDATE' AND (NEW.proposal_id IS DISTINCT FROM OLD.proposal_id OR NEW.user_id IS DISTINCT FROM OLD.user_id) THEN
    RAISE EXCEPTION 'meetup proposal response write is not eligible' USING ERRCODE = 'check_violation';
  END IF;
  SELECT proposal_row.meetup_id INTO v_meetup_id FROM public.meetup_proposals AS proposal_row WHERE proposal_row.id = NEW.proposal_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'meetup proposal response write is not eligible' USING ERRCODE = 'check_violation'; END IF;
  SELECT meetup_row.match_id INTO v_match_id FROM public.meetups AS meetup_row WHERE meetup_row.id = v_meetup_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'meetup proposal response write is not eligible' USING ERRCODE = 'check_violation'; END IF;
  SELECT match_row.user_a_id,match_row.user_b_id INTO v_match_a,v_match_b FROM public.matches AS match_row WHERE match_row.id = v_match_id;
  IF NOT FOUND OR NEW.user_id IS NULL OR NOT (NEW.user_id = v_match_a OR NEW.user_id = v_match_b) THEN
    RAISE EXCEPTION 'meetup proposal response write is not eligible' USING ERRCODE = 'check_violation';
  END IF;
  v_auth_user_id := (SELECT auth.uid());
  v_enforce_actor := COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated'
    OR (COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none' AND session_user = 'authenticated');
  IF v_enforce_actor AND (v_auth_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles AS actor_profile WHERE actor_profile.id = NEW.user_id AND actor_profile.auth_user_id = v_auth_user_id
  )) THEN RAISE EXCEPTION 'meetup proposal response write is not eligible' USING ERRCODE = 'check_violation'; END IF;
  IF TG_OP = 'UPDATE' AND pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN RETURN NEW; END IF;
  IF wingward_private.lock_and_check_mutual_eligibility(v_match_a,v_match_b) THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'meetup proposal response write is not eligible' USING ERRCODE = 'check_violation';
END;
$$;
REVOKE ALL ON FUNCTION wingward_private.guard_meetup_proposal_response_mutual_eligibility() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.guard_meetup_proposal_response_mutual_eligibility() IS 'Private response write backstop. Validates exact proposal/match membership and response ownership, freezes proposal/user lineage and checks current mutual profiles; only exact no-ops bypass eligibility.';

CREATE TRIGGER meetups_guard_mutual_eligibility BEFORE INSERT OR UPDATE ON public.meetups FOR EACH ROW EXECUTE FUNCTION wingward_private.guard_meetup_mutual_eligibility();
CREATE TRIGGER meetup_proposals_guard_mutual_eligibility BEFORE INSERT OR UPDATE ON public.meetup_proposals FOR EACH ROW EXECUTE FUNCTION wingward_private.guard_meetup_proposal_mutual_eligibility();
CREATE TRIGGER meetup_proposal_responses_guard_mutual_eligibility BEFORE INSERT OR UPDATE ON public.meetup_proposal_responses FOR EACH ROW EXECUTE FUNCTION wingward_private.guard_meetup_proposal_response_mutual_eligibility();
