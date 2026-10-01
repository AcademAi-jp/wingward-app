-- B2 private child write guards. Local source only; no deployment.
-- Reviewed Luna implementation; current profile locks follow child writes.
-- Parent match participant mutation and block/contact races remain separate.
CREATE OR REPLACE FUNCTION wingward_private.guard_fox_conversation_mutual_eligibility()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
 v_match_a uuid; v_match_b uuid; v_meetup_match_id uuid; v_actor_id uuid; v_auth_user_id uuid; v_enforce_actor boolean;
BEGIN
 IF TG_OP = 'UPDATE' AND (NEW.match_id IS DISTINCT FROM OLD.match_id OR NEW.purpose IS DISTINCT FROM OLD.purpose OR NEW.meetup_id IS DISTINCT FROM OLD.meetup_id) THEN
  RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 IF NEW.purpose = 'compatibility' AND NEW.meetup_id IS NOT NULL THEN
  RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 IF NEW.purpose = 'scheduling' AND NEW.meetup_id IS NULL THEN
  RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 IF NEW.meetup_id IS NOT NULL THEN
  SELECT meetup_row.match_id INTO v_meetup_match_id FROM public.meetups AS meetup_row WHERE meetup_row.id = NEW.meetup_id;
  IF NOT FOUND OR v_meetup_match_id IS DISTINCT FROM NEW.match_id THEN
   RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation';
  END IF;
 END IF;
 SELECT match_row.user_a_id, match_row.user_b_id INTO v_match_a, v_match_b FROM public.matches AS match_row WHERE match_row.id = NEW.match_id;
 IF NOT FOUND THEN
  RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 v_auth_user_id := (SELECT auth.uid());
 v_enforce_actor := COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated' OR (COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none' AND session_user = 'authenticated');
 IF v_enforce_actor THEN
  IF v_auth_user_id IS NULL THEN RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation'; END IF;
  SELECT profile_row.id INTO v_actor_id FROM public.user_profiles AS profile_row WHERE profile_row.auth_user_id = v_auth_user_id;
  IF NOT FOUND OR (v_actor_id <> v_match_a AND v_actor_id <> v_match_b) THEN RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation'; END IF;
 END IF;
 IF NEW.cache_hit_tokens IS NOT NULL AND NEW.cache_hit_tokens < 0 OR NEW.input_tokens IS NOT NULL AND NEW.input_tokens < 0 OR NEW.output_tokens IS NOT NULL AND NEW.output_tokens < 0 THEN
  RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 IF TG_OP = 'UPDATE' THEN
  IF OLD.cache_hit_tokens IS NOT NULL AND (NEW.cache_hit_tokens IS NULL OR NEW.cache_hit_tokens < OLD.cache_hit_tokens) OR OLD.input_tokens IS NOT NULL AND (NEW.input_tokens IS NULL OR NEW.input_tokens < OLD.input_tokens) OR OLD.output_tokens IS NOT NULL AND (NEW.output_tokens IS NULL OR NEW.output_tokens < OLD.output_tokens) THEN
   RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation';
  END IF;
 END IF;
 IF wingward_private.lock_and_check_mutual_eligibility(v_match_a, v_match_b) THEN RETURN NEW; END IF;
 IF TG_OP = 'UPDATE' THEN
  IF pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN RETURN NEW; END IF;
  IF pg_catalog.to_jsonb(NEW) - ARRAY['cache_hit_tokens','input_tokens','output_tokens']::text[] = pg_catalog.to_jsonb(OLD) - ARRAY['cache_hit_tokens','input_tokens','output_tokens']::text[] THEN RETURN NEW; END IF;
  IF pg_catalog.to_jsonb(NEW) - ARRAY['status']::text[] = pg_catalog.to_jsonb(OLD) - ARRAY['status']::text[] AND OLD.status IN ('pending','in_progress') AND NEW.status = 'failed' THEN RETURN NEW; END IF;
 END IF;
 RAISE EXCEPTION 'fox conversation write is not eligible' USING ERRCODE = 'check_violation';
END;
$$;
REVOKE ALL ON FUNCTION wingward_private.guard_fox_conversation_mutual_eligibility() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.guard_fox_conversation_mutual_eligibility() IS 'Private fox-conversation INSERT/UPDATE backstop. Validates meetup and match membership, freezes relationship lineage, and permits only monotonic token accounting or status-only failure cleanup after revocation.';

CREATE OR REPLACE FUNCTION wingward_private.guard_fox_conversation_message_mutual_eligibility()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
 v_match_id uuid; v_match_a uuid; v_match_b uuid; v_auth_user_id uuid; v_enforce_actor boolean;
BEGIN
 IF TG_OP = 'UPDATE' AND (NEW.conversation_id IS DISTINCT FROM OLD.conversation_id OR NEW.speaker_user_id IS DISTINCT FROM OLD.speaker_user_id) THEN
  RAISE EXCEPTION 'fox conversation message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 SELECT conversation_row.match_id INTO v_match_id FROM public.fox_conversations AS conversation_row WHERE conversation_row.id = NEW.conversation_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'fox conversation message write is not eligible' USING ERRCODE = 'check_violation'; END IF;
 SELECT match_row.user_a_id, match_row.user_b_id INTO v_match_a, v_match_b FROM public.matches AS match_row WHERE match_row.id = v_match_id;
 IF NOT FOUND OR NEW.speaker_user_id IS NULL OR (NEW.speaker_user_id <> v_match_a AND NEW.speaker_user_id <> v_match_b) THEN
  RAISE EXCEPTION 'fox conversation message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 v_auth_user_id := (SELECT auth.uid());
 v_enforce_actor := COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated' OR (COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none' AND session_user = 'authenticated');
 IF v_enforce_actor AND (v_auth_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles AS actor_profile WHERE actor_profile.id = NEW.speaker_user_id AND actor_profile.auth_user_id = v_auth_user_id)) THEN
  RAISE EXCEPTION 'fox conversation message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 IF wingward_private.lock_and_check_mutual_eligibility(v_match_a, v_match_b) THEN RETURN NEW; END IF;
 IF TG_OP = 'UPDATE' AND pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'fox conversation message write is not eligible' USING ERRCODE = 'check_violation';
END;
$$;
REVOKE ALL ON FUNCTION wingward_private.guard_fox_conversation_message_mutual_eligibility() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.guard_fox_conversation_message_mutual_eligibility() IS 'Private fox-conversation-message INSERT/UPDATE backstop. Validates conversation membership and speaker ownership, freezes conversation/speaker lineage, and permits only exact no-ops after revocation.';

CREATE OR REPLACE FUNCTION wingward_private.guard_partner_fox_chat_mutual_eligibility()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
 v_match_a uuid; v_match_b uuid; v_auth_user_id uuid; v_enforce_actor boolean;
BEGIN
 IF TG_OP = 'UPDATE' AND (NEW.match_id IS DISTINCT FROM OLD.match_id OR NEW.user_id IS DISTINCT FROM OLD.user_id OR NEW.partner_user_id IS DISTINCT FROM OLD.partner_user_id) THEN
  RAISE EXCEPTION 'partner fox chat write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 SELECT match_row.user_a_id, match_row.user_b_id INTO v_match_a, v_match_b FROM public.matches AS match_row WHERE match_row.id = NEW.match_id;
 IF NOT FOUND OR NEW.user_id IS NULL OR NEW.partner_user_id IS NULL OR NEW.user_id = NEW.partner_user_id OR NOT ((NEW.user_id = v_match_a AND NEW.partner_user_id = v_match_b) OR (NEW.user_id = v_match_b AND NEW.partner_user_id = v_match_a)) THEN
  RAISE EXCEPTION 'partner fox chat write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 v_auth_user_id := (SELECT auth.uid());
 v_enforce_actor := COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated' OR (COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none' AND session_user = 'authenticated');
 IF v_enforce_actor AND (v_auth_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles AS actor_profile WHERE actor_profile.id = NEW.user_id AND actor_profile.auth_user_id = v_auth_user_id)) THEN
  RAISE EXCEPTION 'partner fox chat write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 IF wingward_private.lock_and_check_mutual_eligibility(v_match_a, v_match_b) THEN RETURN NEW; END IF;
 IF TG_OP = 'UPDATE' AND pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'partner fox chat write is not eligible' USING ERRCODE = 'check_violation';
END;
$$;
REVOKE ALL ON FUNCTION wingward_private.guard_partner_fox_chat_mutual_eligibility() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.guard_partner_fox_chat_mutual_eligibility() IS 'Private partner-Fox-chat INSERT/UPDATE backstop. Validates exact owner/partner membership, freezes chat lineage, and permits only exact no-ops after revocation.';

CREATE OR REPLACE FUNCTION wingward_private.guard_partner_fox_message_mutual_eligibility()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
 v_match_id uuid; v_match_a uuid; v_match_b uuid; v_chat_user_id uuid; v_chat_partner_id uuid; v_auth_user_id uuid; v_enforce_actor boolean;
BEGIN
 IF TG_OP = 'UPDATE' AND NEW.chat_id IS DISTINCT FROM OLD.chat_id THEN RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation'; END IF;
 SELECT chat_row.match_id, chat_row.user_id, chat_row.partner_user_id INTO v_match_id, v_chat_user_id, v_chat_partner_id FROM public.partner_fox_chats AS chat_row WHERE chat_row.id = NEW.chat_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation'; END IF;
 SELECT match_row.user_a_id, match_row.user_b_id INTO v_match_a, v_match_b FROM public.matches AS match_row WHERE match_row.id = v_match_id;
 IF NOT FOUND OR v_chat_user_id IS NULL OR v_chat_partner_id IS NULL OR v_chat_user_id = v_chat_partner_id OR NOT ((v_chat_user_id = v_match_a AND v_chat_partner_id = v_match_b) OR (v_chat_user_id = v_match_b AND v_chat_partner_id = v_match_a)) THEN
  RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 v_auth_user_id := (SELECT auth.uid());
 v_enforce_actor := COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated' OR (COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none' AND session_user = 'authenticated');
 IF v_enforce_actor AND (v_auth_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles AS actor_profile WHERE actor_profile.id = v_chat_user_id AND actor_profile.auth_user_id = v_auth_user_id)) THEN
  RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 IF wingward_private.lock_and_check_mutual_eligibility(v_match_a, v_match_b) THEN RETURN NEW; END IF;
 IF TG_OP = 'UPDATE' AND pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'partner fox message write is not eligible' USING ERRCODE = 'check_violation';
END;
$$;
REVOKE ALL ON FUNCTION wingward_private.guard_partner_fox_message_mutual_eligibility() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.guard_partner_fox_message_mutual_eligibility() IS 'Private partner-Fox-message INSERT/UPDATE backstop. Validates exact chat owner/partner membership, freezes chat lineage, and permits only exact no-ops after revocation.';

CREATE OR REPLACE FUNCTION wingward_private.guard_interaction_dna_score_mutual_eligibility()
RETURNS trigger LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
 v_match_a uuid; v_match_b uuid; v_auth_user_id uuid; v_enforce_actor boolean;
BEGIN
 IF TG_OP = 'UPDATE' AND (NEW.match_id IS DISTINCT FROM OLD.match_id OR NEW.feature_id IS DISTINCT FROM OLD.feature_id OR NEW.source_phase IS DISTINCT FROM OLD.source_phase) THEN
  RAISE EXCEPTION 'interaction score write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 SELECT match_row.user_a_id, match_row.user_b_id INTO v_match_a, v_match_b FROM public.matches AS match_row WHERE match_row.id = NEW.match_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'interaction score write is not eligible' USING ERRCODE = 'check_violation'; END IF;
 v_auth_user_id := (SELECT auth.uid());
 v_enforce_actor := COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated' OR (COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none' AND session_user = 'authenticated');
 IF v_enforce_actor AND (v_auth_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles AS actor_profile WHERE actor_profile.auth_user_id = v_auth_user_id AND actor_profile.id IN (v_match_a, v_match_b))) THEN
  RAISE EXCEPTION 'interaction score write is not eligible' USING ERRCODE = 'check_violation';
 END IF;
 IF wingward_private.lock_and_check_mutual_eligibility(v_match_a, v_match_b) THEN RETURN NEW; END IF;
 IF TG_OP = 'UPDATE' AND pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN RETURN NEW; END IF;
 RAISE EXCEPTION 'interaction score write is not eligible' USING ERRCODE = 'check_violation';
END;
$$;
REVOKE ALL ON FUNCTION wingward_private.guard_interaction_dna_score_mutual_eligibility() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION wingward_private.guard_interaction_dna_score_mutual_eligibility() IS 'Private interaction-DNA-score INSERT/UPDATE backstop. Validates match membership, freezes score lineage, and permits only exact no-ops after revocation.';

DROP TRIGGER IF EXISTS fox_conversations_guard_mutual_eligibility ON public.fox_conversations;
CREATE TRIGGER fox_conversations_guard_mutual_eligibility BEFORE INSERT OR UPDATE ON public.fox_conversations FOR EACH ROW EXECUTE FUNCTION wingward_private.guard_fox_conversation_mutual_eligibility();
DROP TRIGGER IF EXISTS fox_conversation_messages_guard_mutual_eligibility ON public.fox_conversation_messages;
CREATE TRIGGER fox_conversation_messages_guard_mutual_eligibility BEFORE INSERT OR UPDATE ON public.fox_conversation_messages FOR EACH ROW EXECUTE FUNCTION wingward_private.guard_fox_conversation_message_mutual_eligibility();
DROP TRIGGER IF EXISTS partner_fox_chats_guard_mutual_eligibility ON public.partner_fox_chats;
CREATE TRIGGER partner_fox_chats_guard_mutual_eligibility BEFORE INSERT OR UPDATE ON public.partner_fox_chats FOR EACH ROW EXECUTE FUNCTION wingward_private.guard_partner_fox_chat_mutual_eligibility();
DROP TRIGGER IF EXISTS partner_fox_messages_guard_mutual_eligibility ON public.partner_fox_messages;
CREATE TRIGGER partner_fox_messages_guard_mutual_eligibility BEFORE INSERT OR UPDATE ON public.partner_fox_messages FOR EACH ROW EXECUTE FUNCTION wingward_private.guard_partner_fox_message_mutual_eligibility();
DROP TRIGGER IF EXISTS interaction_dna_scores_guard_mutual_eligibility ON public.interaction_dna_scores;
CREATE TRIGGER interaction_dna_scores_guard_mutual_eligibility BEFORE INSERT OR UPDATE ON public.interaction_dna_scores FOR EACH ROW EXECUTE FUNCTION wingward_private.guard_interaction_dna_score_mutual_eligibility();
