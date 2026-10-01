-- SQL30 durable single-provider Partner Ward greeting claim acceptance.
-- Prepare only. Run with psql -v ON_ERROR_STOP=1 against the local synthetic
-- database after all migrations; all fixtures are rolled back.

BEGIN;
SET LOCAL statement_timeout = '15s';

DO $$
DECLARE
  v_oid oid;
  v_function_name text;
  v_definition text;
  v_match_lock integer;
  v_room_lock integer;
  v_chat_lock integer;
  v_conversation_lock integer;
  v_profile_lock integer;
  v_completion_insert integer;
  v_completion_claim_update integer;
BEGIN
  v_oid := pg_catalog.to_regprocedure('public.claim_partner_fox_greeting(uuid,uuid,uuid,uuid)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL30a: greeting claim RPC is missing';
  END IF;
  SELECT pg_catalog.pg_get_functiondef(v_oid) INTO v_definition;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS proc
     WHERE proc.oid = v_oid
       AND proc.prosecdef IS TRUE
       AND proc.proconfig @> ARRAY['search_path=""']::text[]
  ) THEN
    RAISE EXCEPTION 'FAIL SQL30a: claim RPC is not SECURITY DEFINER with empty search_path';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL30a: claim RPC grants are not service_role-only';
  END IF;
  IF v_definition NOT LIKE '%partner_fox_greeting_claims%'
     OR v_definition NOT LIKE '%lock_and_check_mutual_eligibility%'
     OR v_definition NOT LIKE '%completed%'
     OR v_definition NOT LIKE '%unknown%'
     OR v_definition NOT LIKE '%lease_expires_at%' THEN
    RAISE EXCEPTION 'FAIL SQL30a: claim RPC lacks durable states/current eligibility checks';
  END IF;
  v_match_lock := pg_catalog.strpos(v_definition, 'FROM public.matches AS match_row');
  v_room_lock := v_match_lock + pg_catalog.strpos(
    pg_catalog.substr(v_definition, v_match_lock), 'FROM public.direct_chat_rooms AS room_row'
  ) - 1;
  v_chat_lock := v_room_lock + pg_catalog.strpos(
    pg_catalog.substr(v_definition, v_room_lock), 'FROM public.partner_fox_chats AS chat_row'
  ) - 1;
  v_conversation_lock := v_chat_lock + pg_catalog.strpos(
    pg_catalog.substr(v_definition, v_chat_lock), 'FROM public.fox_conversations AS conversation_row'
  ) - 1;
  v_profile_lock := v_conversation_lock + pg_catalog.strpos(
    pg_catalog.substr(v_definition, v_conversation_lock), 'lock_and_check_mutual_eligibility'
  ) - 1;
  IF v_match_lock < 1 OR v_room_lock <= v_match_lock OR v_chat_lock <= v_room_lock
     OR v_conversation_lock <= v_chat_lock OR v_profile_lock <= v_conversation_lock
     OR v_definition NOT LIKE '%FOR UPDATE%'
     OR v_definition NOT LIKE '%FOR SHARE%' THEN
    RAISE EXCEPTION 'FAIL SQL30a: claim RPC does not preserve relationship/profile lock order';
  END IF;

  FOREACH v_function_name IN ARRAY ARRAY[
    'public.complete_partner_fox_greeting(uuid,uuid,text)',
    'public.retry_partner_fox_greeting_before_provider(uuid,uuid)'
  ] LOOP
    v_oid := pg_catalog.to_regprocedure(v_function_name);
    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'FAIL SQL30b: RPC % is missing', v_function_name;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_proc AS proc
       WHERE proc.oid = v_oid
         AND proc.prosecdef IS TRUE
         AND proc.proconfig @> ARRAY['search_path=""']::text[]
    ) OR has_function_privilege('anon', v_oid, 'EXECUTE')
      OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
      OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL SQL30b: RPC % lacks fixed security and ACL', v_function_name;
    END IF;
    SELECT pg_catalog.pg_get_functiondef(v_oid) INTO v_definition;
    IF v_definition NOT LIKE '%lock_and_check_mutual_eligibility%'
       OR v_definition NOT LIKE '%partner_fox_greeting_claims%'
       OR v_definition NOT LIKE '%partner_fox_chats%'
       OR v_definition NOT LIKE '%fox_conversations%' THEN
      RAISE EXCEPTION 'FAIL SQL30b: RPC % does not revalidate the current relationship', v_function_name;
    END IF;
    IF v_function_name = 'public.complete_partner_fox_greeting(uuid,uuid,text)'
    THEN
      v_completion_insert := pg_catalog.strpos(v_definition, 'INSERT INTO public.partner_fox_messages');
      v_completion_claim_update := v_completion_insert + pg_catalog.strpos(
        pg_catalog.substr(v_definition, v_completion_insert),
        'UPDATE public.partner_fox_greeting_claims'
      ) - 1;
      IF v_completion_insert < 1 OR v_completion_claim_update <= v_completion_insert THEN
        RAISE EXCEPTION 'FAIL SQL30b: completion RPC does not atomically write message then claim state';
      END IF;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS relation_row
     WHERE relation_row.oid = 'public.partner_fox_greeting_claims'::regclass
       AND relation_row.relrowsecurity IS TRUE
  ) OR has_table_privilege('anon', 'public.partner_fox_greeting_claims', 'SELECT')
    OR has_table_privilege('authenticated', 'public.partner_fox_greeting_claims', 'SELECT')
    OR has_table_privilege('service_role', 'public.partner_fox_greeting_claims', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL SQL30c: greeting claim ledger is exposed outside its definer RPCs';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'partner_fox_greeting_claims'
       AND column_name IN ('content', 'message_content', 'greeting_content')
  ) THEN
    RAISE EXCEPTION 'FAIL SQL30c: claim ledger duplicates greeting body content';
  END IF;
  RAISE NOTICE 'PASS SQL30a-c: service-only fixed-search_path RPCs, lock order, private RLS ledger, and no body copy';
END $$;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-00000000b301', 'wingward-test-sql30-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000b302', 'wingward-test-sql30-b@example.invalid'),
  ('00000000-0000-0000-0000-00000000b303', 'wingward-test-sql30-c@example.invalid'),
  ('00000000-0000-0000-0000-00000000b304', 'wingward-test-sql30-d@example.invalid');

WITH fixtures (auth_user_id, profile_id, nickname) AS (
  VALUES
    ('00000000-0000-0000-0000-00000000b301'::uuid, '10000000-0000-0000-0000-00000000b301'::uuid, 'SQL30 A'),
    ('00000000-0000-0000-0000-00000000b302'::uuid, '10000000-0000-0000-0000-00000000b302'::uuid, 'SQL30 B'),
    ('00000000-0000-0000-0000-00000000b303'::uuid, '10000000-0000-0000-0000-00000000b303'::uuid, 'SQL30 C'),
    ('00000000-0000-0000-0000-00000000b304'::uuid, '10000000-0000-0000-0000-00000000b304'::uuid, 'SQL30 D')
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
  ('20000000-0000-0000-0000-00000000b301', '10000000-0000-0000-0000-00000000b301', '10000000-0000-0000-0000-00000000b302', 'fox_conversation_completed'),
  ('20000000-0000-0000-0000-00000000b303', '10000000-0000-0000-0000-00000000b303', '10000000-0000-0000-0000-00000000b304', 'fox_conversation_completed');

INSERT INTO public.fox_conversations (id, match_id, purpose, status, total_rounds, current_round)
VALUES
  ('30000000-0000-0000-0000-00000000b301', '20000000-0000-0000-0000-00000000b301', 'compatibility', 'completed', 15, 15),
  ('30000000-0000-0000-0000-00000000b303', '20000000-0000-0000-0000-00000000b303', 'compatibility', 'completed', 15, 15);

-- Two orientations of one match exercise owner A/B chat visibility; a second
-- independent match exercises an expired provider lease without waiting.
INSERT INTO public.partner_fox_chats (id, match_id, user_id, partner_user_id)
VALUES
  ('50000000-0000-0000-0000-00000000b301', '20000000-0000-0000-0000-00000000b301', '10000000-0000-0000-0000-00000000b301', '10000000-0000-0000-0000-00000000b302'),
  ('50000000-0000-0000-0000-00000000b302', '20000000-0000-0000-0000-00000000b301', '10000000-0000-0000-0000-00000000b302', '10000000-0000-0000-0000-00000000b301'),
  ('50000000-0000-0000-0000-00000000b303', '20000000-0000-0000-0000-00000000b303', '10000000-0000-0000-0000-00000000b303', '10000000-0000-0000-0000-00000000b304');

CREATE FUNCTION pg_temp.sql30_completion_snapshot() RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
SELECT jsonb_build_object('claim',to_jsonb(c),'match',to_jsonb(m),
    'messages',(SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id) FROM public.partner_fox_messages x WHERE x.chat_id=c.chat_id),
    'events',(SELECT count(*) FROM public.notification_events))
    FROM public.partner_fox_greeting_claims c JOIN public.matches m ON m.id=c.match_id
    WHERE c.chat_id='50000000-0000-0000-0000-00000000b301';
$$;
REVOKE ALL ON FUNCTION pg_temp.sql30_completion_snapshot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_temp.sql30_completion_snapshot() TO service_role;

SET LOCAL role = 'service_role';

DO $$
DECLARE
  v_row record;
  v_first_token uuid;
  v_second_token uuid;
  v_message_id uuid;
  v_messages integer;
  v_rollback_proved boolean := false;
  v_match_status text;
  v_snapshot jsonb;
  v_after jsonb;
BEGIN
  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b301',
    '20000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b302'
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' OR v_row.claim_token IS NULL
     OR v_row.message_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL30d: first request did not acquire one durable claim';
  END IF;
  v_first_token := v_row.claim_token;

  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b301',
    '20000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b302'
  );
  IF v_row.outcome IS DISTINCT FROM 'busy' OR v_row.claim_token IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL30d: simultaneous retry was not held behind the live lease';
  END IF;

  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b301',
    '20000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b302',
    '10000000-0000-0000-0000-00000000b301'
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL30d: non-owner was accepted for the opposite user chat';
  END IF;

  -- Force a caller-side error after the RPC returns. PostgreSQL must roll back
  -- both the greeting INSERT and claim/status update as one function call.
  BEGIN
    SELECT * INTO v_row FROM public.complete_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b301', v_first_token, 'rollback probe'
    );
    IF v_row.outcome = 'completed' THEN
      RAISE EXCEPTION USING ERRCODE = 'ZX001', MESSAGE = 'intentional SQL30 rollback probe';
    END IF;
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    v_rollback_proved := true;
  END;
  IF NOT v_rollback_proved THEN
    RAISE EXCEPTION 'FAIL SQL30e: rollback probe did not reach a completed RPC result';
  END IF;
  SELECT count(*) INTO v_messages
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.chat_id = '50000000-0000-0000-0000-00000000b301';
  SELECT match_row.status INTO v_match_status
    FROM public.matches AS match_row
   WHERE match_row.id = '20000000-0000-0000-0000-00000000b301';
  IF v_messages <> 0 OR v_match_status IS DISTINCT FROM 'fox_conversation_completed' THEN
    RAISE EXCEPTION 'FAIL SQL30e: greeting/message or match transition survived function rollback';
  END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b301',
    '20000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b302'
  );
  IF v_row.outcome IS DISTINCT FROM 'busy' THEN
    RAISE EXCEPTION 'FAIL SQL30e: claim completion status survived forced rollback';
  END IF;

  SELECT * INTO v_row FROM public.complete_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b301', v_first_token, 'authoritative greeting A'
  );
  IF v_row.outcome IS DISTINCT FROM 'completed'
     OR v_row.claim_token IS NOT NULL
     OR v_row.message_id IS NULL
     OR v_row.message_role IS DISTINCT FROM 'fox'
     OR v_row.message_content IS DISTINCT FROM 'authoritative greeting A'
     OR v_row.transitioned IS DISTINCT FROM true
     OR v_row.match_status IS DISTINCT FROM 'partner_chat_started' THEN
    RAISE EXCEPTION 'FAIL SQL30f: completion did not atomically persist and transition';
  END IF;
  v_message_id := v_row.message_id;
  PERFORM set_config('app.sql30_completed_token',v_first_token::text,true);
  SELECT count(*) INTO v_messages
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.chat_id = '50000000-0000-0000-0000-00000000b301'
     AND message_row.role = 'fox';
  IF v_messages <> 1 THEN
    RAISE EXCEPTION 'FAIL SQL30f: completion did not create exactly one greeting row';
  END IF;

  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b301',
    '20000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b302'
  );
  IF v_row.outcome IS DISTINCT FROM 'completed'
     OR v_row.claim_token IS NOT NULL
     OR v_row.message_id IS DISTINCT FROM v_message_id
     OR v_row.message_content IS DISTINCT FROM 'authoritative greeting A' THEN
    RAISE EXCEPTION 'FAIL SQL30f: completed retry did not replay the authoritative stored row';
  END IF;

  -- Completed replay requires the original token and never rewrites stored data.
  SELECT pg_temp.sql30_completion_snapshot() INTO v_snapshot;
  SELECT * INTO v_row FROM public.complete_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b301','11111111-1111-4111-8111-111111111111','wrong completed token');
  IF v_row.outcome IS DISTINCT FROM 'stale' OR v_row.message_id IS NOT NULL
     OR v_row.message_content IS NOT NULL OR v_row.message_role IS NOT NULL
     OR v_row.message_created_at IS NOT NULL OR v_row.transitioned IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL SQL30 completed token proof: wrong token exposed a stored greeting';
  END IF;
  SELECT * INTO v_row FROM public.complete_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b301',v_first_token,'correct replay must not overwrite');
  IF v_row.outcome IS DISTINCT FROM 'completed' OR v_row.message_id IS DISTINCT FROM v_message_id
     OR v_row.message_content IS DISTINCT FROM 'authoritative greeting A' OR v_row.transitioned IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL SQL30 completed token proof: correct token did not replay';
  END IF;
  SELECT pg_temp.sql30_completion_snapshot() INTO v_after;
  IF v_after IS DISTINCT FROM v_snapshot THEN
    RAISE EXCEPTION 'FAIL SQL30 completed token proof: retries changed rows or event/message counts';
  END IF;
  -- Only the explicit pre-provider failure RPC can release a live claim.
  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b302',
    '20000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b302',
    '10000000-0000-0000-0000-00000000b301'
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' OR v_row.claim_token IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL30g: owner B did not acquire the second orientation claim';
  END IF;
  v_first_token := v_row.claim_token;
  SELECT * INTO v_row FROM public.retry_partner_fox_greeting_before_provider(
    '50000000-0000-0000-0000-00000000b302', v_first_token
  );
  IF v_row.outcome IS DISTINCT FROM 'retryable' THEN
    RAISE EXCEPTION 'FAIL SQL30g: definite pre-provider failure was not marked retryable';
  END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b302',
    '20000000-0000-0000-0000-00000000b301',
    '10000000-0000-0000-0000-00000000b302',
    '10000000-0000-0000-0000-00000000b301'
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' OR v_row.claim_token IS NULL
     OR v_row.claim_token = v_first_token THEN
    RAISE EXCEPTION 'FAIL SQL30g: released claim did not issue a fresh token';
  END IF;
  v_second_token := v_row.claim_token;
  SELECT * INTO v_row FROM public.complete_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b302', v_first_token, 'stale old token must not write'
  );
  IF v_row.outcome IS DISTINCT FROM 'stale' THEN
    RAISE EXCEPTION 'FAIL SQL30g: old claim token completed after a retry';
  END IF;
  SELECT count(*) INTO v_messages
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.chat_id = '50000000-0000-0000-0000-00000000b302';
  IF v_messages <> 0 THEN
    RAISE EXCEPTION 'FAIL SQL30g: stale claim token inserted a message';
  END IF;
  SELECT * INTO v_row FROM public.complete_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b302', v_second_token, 'authoritative greeting B'
  );
  IF v_row.outcome IS DISTINCT FROM 'completed'
     OR v_row.message_content IS DISTINCT FROM 'authoritative greeting B' THEN
    RAISE EXCEPTION 'FAIL SQL30g: new claim token failed to complete';
  END IF;

  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b303',
    '20000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b304'
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' OR v_row.claim_token IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL30h: independent owner C did not acquire a claim';
  END IF;
  PERFORM pg_catalog.set_config('app.sql30_expired_token', v_row.claim_token::text, true);
  RAISE NOTICE 'PASS SQL30d-h: live-lease busy, owner/match binding, atomic completion, authoritative replay, safe retry, and old-token rejection';
END $$;

-- A legacy completed row without a token proof fails closed through complete.
RESET ROLE;
DO $$ BEGIN
 IF has_column_privilege('anon','public.partner_fox_greeting_claims','completed_claim_token_hash','SELECT')
    OR has_column_privilege('authenticated','public.partner_fox_greeting_claims','completed_claim_token_hash','SELECT')
    OR has_column_privilege('service_role','public.partner_fox_greeting_claims','completed_claim_token_hash','SELECT') THEN
  RAISE EXCEPTION 'FAIL SQL30 completed token proof: private hash is directly readable';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.partner_fox_greeting_claims WHERE chat_id='50000000-0000-0000-0000-00000000b301'
    AND claim_token IS NULL AND completed_claim_token_hash=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(current_setting('app.sql30_completed_token'),'UTF8')),'hex')) THEN
  RAISE EXCEPTION 'FAIL SQL30 completed token proof: completion did not seal validated token hash';
 END IF;
END $$;
UPDATE public.partner_fox_greeting_claims SET completed_claim_token_hash=NULL WHERE chat_id='50000000-0000-0000-0000-00000000b301';
SET LOCAL ROLE service_role;
DO $$ DECLARE r record; snapshot jsonb; BEGIN
 snapshot:=pg_temp.sql30_completion_snapshot();
 SELECT * INTO r FROM public.complete_partner_fox_greeting('50000000-0000-0000-0000-00000000b301',current_setting('app.sql30_completed_token')::uuid,'legacy unproved replay');
 IF r.outcome IS DISTINCT FROM 'stale' OR r.message_id IS NOT NULL OR r.message_content IS NOT NULL THEN
  RAISE EXCEPTION 'FAIL SQL30 completed token proof: unproved legacy completion exposed a body';
 END IF;
 SELECT * INTO r FROM public.claim_partner_fox_greeting('50000000-0000-0000-0000-00000000b301','20000000-0000-0000-0000-00000000b301','10000000-0000-0000-0000-00000000b301','10000000-0000-0000-0000-00000000b302');
 IF r.outcome IS DISTINCT FROM 'completed' OR r.message_content IS DISTINCT FROM 'authoritative greeting A' THEN
  RAISE EXCEPTION 'FAIL SQL30 completed token proof: owner-bound legacy recovery failed';
 END IF;
 IF pg_temp.sql30_completion_snapshot() IS DISTINCT FROM snapshot THEN
  RAISE EXCEPTION 'FAIL SQL30 completed token proof: legacy retries changed rows or counts';
 END IF;
END $$;

-- Simulate a provider call whose worker died after claim: expiry is terminal,
-- and its previous token cannot persist a greeting or trigger regeneration.
RESET ROLE;
UPDATE public.partner_fox_greeting_claims
   SET lease_expires_at = pg_catalog.now() - interval '1 second'
 WHERE chat_id = '50000000-0000-0000-0000-00000000b303';
SET LOCAL role = 'service_role';
DO $$
DECLARE
  v_row record;
  v_expired_token uuid;
  v_messages integer;
BEGIN
  -- The token value is intentionally read as test fixture setup by the
  -- session owner; application/API roles cannot read the private ledger.
  v_expired_token := pg_catalog.current_setting('app.sql30_expired_token', true)::uuid;
  IF v_expired_token IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL30i: expired fixture did not retain its old token';
  END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b303',
    '20000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b304'
  );
  IF v_row.outcome IS DISTINCT FROM 'unknown' OR v_row.claim_token IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL30i: expired provider work was regenerated instead of sealed unknown';
  END IF;
  SELECT * INTO v_row FROM public.complete_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b303', v_expired_token, 'expired provider result'
  );
  IF v_row.outcome IS DISTINCT FROM 'unknown' THEN
    RAISE EXCEPTION 'FAIL SQL30i: expired claim token was allowed to complete';
  END IF;
  SELECT count(*) INTO v_messages
    FROM public.partner_fox_messages AS message_row
   WHERE message_row.chat_id = '50000000-0000-0000-0000-00000000b303';
  IF v_messages <> 0 THEN
    RAISE EXCEPTION 'FAIL SQL30i: expired provider result wrote a greeting';
  END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b303',
    '20000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b304'
  );
  IF v_row.outcome IS DISTINCT FROM 'unknown' THEN
    RAISE EXCEPTION 'FAIL SQL30i: terminal unknown state was not sticky';
  END IF;
  RAISE NOTICE 'PASS SQL30i: expired processing claim stays unknown and old provider completion writes nothing';
END $$;

-- A closed direct room and either block direction fail the live access check,
-- even for a previously terminal claim.
RESET ROLE;
INSERT INTO public.direct_chat_rooms (id, match_id, status)
VALUES ('40000000-0000-0000-0000-00000000b303', '20000000-0000-0000-0000-00000000b303', 'closed');
SET LOCAL role = 'service_role';
DO $$
DECLARE v_row record;
BEGIN
  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b303',
    '20000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b304'
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL30j: claim accepted a closed current direct room';
  END IF;
END $$;

RESET ROLE;
UPDATE public.direct_chat_rooms
   SET status = 'active'
 WHERE id = '40000000-0000-0000-0000-00000000b303';
INSERT INTO public.blocks (id, blocker_id, blocked_id)
VALUES ('70000000-0000-0000-0000-00000000b303', '10000000-0000-0000-0000-00000000b303', '10000000-0000-0000-0000-00000000b304');
SET LOCAL role = 'service_role';
DO $$
DECLARE v_row record;
BEGIN
  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b303',
    '20000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b304'
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL30j: claim ignored owner C blocking partner D';
  END IF;
END $$;

RESET ROLE;
DELETE FROM public.blocks
 WHERE id = '70000000-0000-0000-0000-00000000b303';
INSERT INTO public.blocks (id, blocker_id, blocked_id)
VALUES ('70000000-0000-0000-0000-00000000b304', '10000000-0000-0000-0000-00000000b304', '10000000-0000-0000-0000-00000000b303');
SET LOCAL role = 'service_role';
DO $$
DECLARE v_row record;
BEGIN
  SELECT * INTO v_row FROM public.claim_partner_fox_greeting(
    '50000000-0000-0000-0000-00000000b303',
    '20000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b303',
    '10000000-0000-0000-0000-00000000b304'
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL30j: claim ignored partner D blocking owner C';
  END IF;
  RAISE NOTICE 'PASS SQL30j: live closed-room and both block directions deny claim';
END $$;

-- Authenticated owners see their own oriented chat only. A partner cannot use
-- the opposite owner's chat id to read or update that owner's messages.
RESET ROLE;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000b301","role":"authenticated"}';
SET LOCAL role = 'authenticated';
DO $$
DECLARE
  v_count integer;
  v_updated integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.partner_fox_chats
   WHERE id = '50000000-0000-0000-0000-00000000b301';
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL30j: owner A cannot read its own chat'; END IF;
  SELECT count(*) INTO v_count FROM public.partner_fox_chats
   WHERE id = '50000000-0000-0000-0000-00000000b302';
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL30j: owner A can read owner B chat'; END IF;
  SELECT count(*) INTO v_count FROM public.partner_fox_messages
   WHERE chat_id = '50000000-0000-0000-0000-00000000b302';
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL30j: owner A can read owner B answers'; END IF;
  UPDATE public.partner_fox_messages SET content = 'cross-owner update attempt'
   WHERE chat_id = '50000000-0000-0000-0000-00000000b302';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 0 THEN RAISE EXCEPTION 'FAIL SQL30j: owner A updated owner B answers'; END IF;
  RAISE NOTICE 'PASS SQL30k: authenticated owner A is isolated from owner B chat and answers';
END $$;

RESET ROLE;
SET LOCAL request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000b302","role":"authenticated"}';
SET LOCAL role = 'authenticated';
DO $$
DECLARE
  v_count integer;
  v_updated integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.partner_fox_chats
   WHERE id = '50000000-0000-0000-0000-00000000b302';
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL30l: owner B cannot read its own chat'; END IF;
  SELECT count(*) INTO v_count FROM public.partner_fox_chats
   WHERE id = '50000000-0000-0000-0000-00000000b301';
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL30l: owner B can read owner A chat'; END IF;
  SELECT count(*) INTO v_count FROM public.partner_fox_messages
   WHERE chat_id = '50000000-0000-0000-0000-00000000b301';
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL30l: owner B can read owner A answers'; END IF;
  UPDATE public.partner_fox_messages SET content = 'cross-owner update attempt'
   WHERE chat_id = '50000000-0000-0000-0000-00000000b301';
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated <> 0 THEN RAISE EXCEPTION 'FAIL SQL30l: owner B updated owner A answers'; END IF;
  RAISE NOTICE 'PASS SQL30l: authenticated owner B is isolated from owner A chat and answers';
END $$;

ROLLBACK;
