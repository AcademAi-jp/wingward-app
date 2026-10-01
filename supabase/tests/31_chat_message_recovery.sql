-- SQL31 message-send recovery acceptance test.
-- Synthetic fixtures only; all database writes are rolled back.

BEGIN;
SET LOCAL statement_timeout = '15s';

DO $$
DECLARE
  v_function oid;
  v_table regclass;
  v_is_definer boolean;
BEGIN
  FOREACH v_function IN ARRAY ARRAY[
    to_regprocedure('public.recover_direct_chat_message_send(uuid,uuid,uuid,text)')::oid,
    to_regprocedure('public.recover_partner_fox_message_send(uuid,uuid,uuid,text)')::oid
  ] LOOP
    IF v_function IS NULL THEN
      RAISE EXCEPTION 'FAIL SQL31a: message recovery RPC is missing';
    END IF;
    SELECT proc.prosecdef INTO v_is_definer FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function;
    IF NOT v_is_definer
       OR NOT COALESCE((SELECT proc.proconfig @> ARRAY['search_path=""']::text[]
                          FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function), false)
       OR has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('authenticated', v_function, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL SQL31b: recovery RPC must be SECURITY DEFINER with empty search_path and service_role-only EXECUTE';
    END IF;
  END LOOP;

  FOREACH v_table IN ARRAY ARRAY[
    'public.direct_chat_message_idempotency'::regclass,
    'public.partner_fox_message_sends'::regclass
  ] LOOP
    IF has_table_privilege('anon', v_table, 'SELECT')
       OR has_table_privilege('authenticated', v_table, 'SELECT')
       OR has_table_privilege('service_role', v_table, 'SELECT') THEN
      RAISE EXCEPTION 'FAIL SQL31c: retry ledgers must not be readable directly';
    END IF;
  END LOOP;
END $$;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-00000000c311', 'wingward-test-sql31-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000c312', 'wingward-test-sql31-b@example.invalid'),
  ('00000000-0000-0000-0000-00000000c313', 'wingward-test-sql31-c@example.invalid');

WITH fixtures (auth_user_id, profile_id, nickname) AS (
  VALUES
    ('00000000-0000-0000-0000-00000000c311'::uuid, '10000000-0000-0000-0000-00000000c311'::uuid, 'SQL31 A'),
    ('00000000-0000-0000-0000-00000000c312'::uuid, '10000000-0000-0000-0000-00000000c312'::uuid, 'SQL31 B'),
    ('00000000-0000-0000-0000-00000000c313'::uuid, '10000000-0000-0000-0000-00000000c313'::uuid, 'SQL31 C')
)
UPDATE public.user_profiles AS profile_row
   SET id = fixture.profile_id,
       nickname = fixture.nickname,
       birth_date = DATE '1990-01-01',
       age_verified_at = '2026-09-26T00:00:00Z',
       age_verification_method = 'self_declared',
       gender_identity = 'woman',
       preferred_genders = ARRAY['woman']::text[],
       preference_mode = 'selected',
       dating_market = 'JP',
       onboarding_settings_completed_at = '2026-09-26T00:00:00Z',
       identity_verification_status = 'verified',
       identity_verified_at = '2026-09-26T00:00:00Z'
  FROM fixtures AS fixture
 WHERE profile_row.auth_user_id = fixture.auth_user_id;

INSERT INTO public.matches (id, user_a_id, user_b_id, status) VALUES
  ('20000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c312', 'partner_chat_started');
INSERT INTO public.chat_requests
  (id, match_id, requester_id, responder_id, status, responded_at, expires_at)
VALUES
  ('30000000-0000-0000-0000-00000000c311', '20000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c312', 'accepted', '2026-09-26T00:00:00Z', '2026-10-01T00:00:00Z');
INSERT INTO public.direct_chat_rooms (id, match_id, status) VALUES
  ('40000000-0000-0000-0000-00000000c311', '20000000-0000-0000-0000-00000000c311', 'active');
INSERT INTO public.partner_fox_chats (id, match_id, user_id, partner_user_id) VALUES
  ('50000000-0000-0000-0000-00000000c311', '20000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c312');

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_key uuid := '80000000-0000-0000-0000-00000000c311';
  v_direct_content_digest text := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('hello direct', 'UTF8')), 'hex');
  v_partner_content_digest text := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('hello partner', 'UTF8')), 'hex');
  v_direct_id uuid;
  v_claim_token uuid;
  v_user_id uuid;
  v_fox_id uuid;
  v_count integer;
BEGIN
  -- Direct: committed row is owner/key/hash bound and recovery never inserts.
  SELECT * INTO v_row FROM public.recover_direct_chat_message_send(
    '40000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, v_direct_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' OR v_row.message_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL31d: pre-commit lookup must stay empty without consuming the retry key';
  END IF;
  SELECT * INTO v_row FROM public.persist_direct_chat_message(
    '40000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, 'hello direct', v_direct_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'inserted' OR v_row.message_id IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL31e: direct seed send did not commit';
  END IF;
  v_direct_id := v_row.message_id;
  SELECT * INTO v_row FROM public.persist_direct_chat_message(
    '40000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, 'hello direct', v_direct_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'replayed' OR v_row.message_id IS DISTINCT FROM v_direct_id THEN
    RAISE EXCEPTION 'FAIL SQL31f: same-key direct retry did not replay the late commit';
  END IF;
  SELECT * INTO v_row FROM public.recover_direct_chat_message_send(
    '40000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, v_direct_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'found' OR v_row.message_id IS DISTINCT FROM v_direct_id
     OR v_row.message_content IS DISTINCT FROM 'hello direct' THEN
    RAISE EXCEPTION 'FAIL SQL31g: direct recovery did not return the committed row';
  END IF;
  SELECT * INTO v_row FROM public.recover_direct_chat_message_send(
    '40000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, pg_catalog.repeat('b', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'conflict' OR v_row.message_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL31h: direct recovery accepted a changed content hash';
  END IF;
  SELECT * INTO v_row FROM public.recover_direct_chat_message_send(
    '40000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c313',
    v_key, pg_catalog.repeat('a', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' OR v_row.message_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL31i: direct recovery disclosed another owner''s message';
  END IF;
  SELECT count(*) INTO v_count FROM public.direct_chat_messages
   WHERE room_id = '40000000-0000-0000-0000-00000000c311';
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL31j: direct recovery inserted another row'; END IF;
  UPDATE public.direct_chat_messages SET content = 'tampered direct' WHERE id = v_direct_id;
  SELECT * INTO v_row FROM public.recover_direct_chat_message_send(
    '40000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, v_direct_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'conflict' OR v_row.message_content IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL31k: modified direct content escaped receipt hash verification';
  END IF;
  DELETE FROM public.direct_chat_messages WHERE id = v_direct_id;
  SELECT * INTO v_row FROM public.recover_direct_chat_message_send(
    '40000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, v_direct_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'missing' OR v_row.message_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL31l: deleted direct message was not terminal';
  END IF;

  -- Partner Ward: recovery returns processing without body, then authoritative
  -- pair only after atomic completion. Unknown outcomes never return content.
  v_key := '80000000-0000-0000-0000-00000000c312';
  SELECT * INTO v_row FROM public.recover_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, v_partner_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' OR v_row.user_message_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL31m: pre-claim lookup must not consume the Partner Ward retry key';
  END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, 'hello partner', v_partner_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' OR v_row.claim_token IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL31n: Partner Ward send claim failed';
  END IF;
  v_claim_token := v_row.claim_token;
  v_user_id := v_row.user_message_id;
  SELECT * INTO v_row FROM public.recover_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, v_partner_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'processing' OR v_row.user_message_id IS NOT NULL OR v_row.user_content IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL31o: pending Partner Ward receipt disclosed content';
  END IF;
  SELECT * INTO v_row FROM public.complete_partner_fox_message_send(v_key, v_claim_token, 'hello back');
  IF v_row.outcome IS DISTINCT FROM 'completed' OR v_row.user_message_id IS DISTINCT FROM v_user_id OR v_row.fox_message_id IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL31p: Partner Ward pair did not complete';
  END IF;
  v_fox_id := v_row.fox_message_id;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, 'hello partner', v_partner_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'replayed' OR v_row.user_message_id IS DISTINCT FROM v_user_id
     OR v_row.fox_message_id IS DISTINCT FROM v_fox_id THEN
    RAISE EXCEPTION 'FAIL SQL31u: same-key Partner Ward retry generated a different result';
  END IF;
  SELECT * INTO v_row FROM public.recover_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, v_partner_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'completed' OR v_row.user_message_id IS DISTINCT FROM v_user_id
     OR v_row.fox_message_id IS DISTINCT FROM v_fox_id OR v_row.user_content IS DISTINCT FROM 'hello partner'
     OR v_row.fox_content IS DISTINCT FROM 'hello back' THEN
    RAISE EXCEPTION 'FAIL SQL31q: completed Partner Ward recovery did not return the same pair';
  END IF;
  SELECT * INTO v_row FROM public.recover_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c312',
    v_key, v_partner_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' OR v_row.user_message_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL31r: Partner Ward recovery disclosed another owner’s pair';
  END IF;
  UPDATE public.partner_fox_messages SET content = 'tampered partner' WHERE id = v_user_id;
  SELECT * INTO v_row FROM public.recover_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c311', '10000000-0000-0000-0000-00000000c311',
    v_key, v_partner_content_digest
  );
  IF v_row.outcome IS DISTINCT FROM 'conflict' OR v_row.user_content IS NOT NULL OR v_row.fox_content IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL31s: modified Partner Ward user content escaped receipt hash verification';
  END IF;
  SELECT count(*) INTO v_count FROM public.partner_fox_messages
   WHERE chat_id = '50000000-0000-0000-0000-00000000c311';
  IF v_count <> 2 THEN RAISE EXCEPTION 'FAIL SQL31t: Partner Ward recovery created duplicate rows'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
