-- SQL27 chat message idempotency acceptance test.
-- Synthetic fixtures only; every write is rolled back.

BEGIN;
SET LOCAL statement_timeout = '15s';

DO $$
DECLARE
  v_function oid;
  v_table regclass;
  v_is_definer boolean;
BEGIN
  FOREACH v_function IN ARRAY ARRAY[
    to_regprocedure('public.persist_direct_chat_message(uuid,uuid,uuid,text,text)')::oid,
    to_regprocedure('public.claim_partner_fox_message_send(uuid,uuid,uuid,text,text)')::oid,
    to_regprocedure('public.complete_partner_fox_message_send(uuid,uuid,text)')::oid,
    to_regprocedure('public.finish_partner_fox_message_send(uuid,uuid,text)')::oid
  ] LOOP
    IF v_function IS NULL THEN
      RAISE EXCEPTION 'FAIL SQL27a: idempotency RPC is missing';
    END IF;
    SELECT proc.prosecdef INTO v_is_definer FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function;
    IF NOT v_is_definer
       OR NOT COALESCE((SELECT proc.proconfig @> ARRAY['search_path=""']::text[]
                          FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function), false)
       OR has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('authenticated', v_function, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL SQL27b: RPC must be SECURITY DEFINER with empty search_path and service_role-only EXECUTE';
    END IF;
  END LOOP;

  FOREACH v_table IN ARRAY ARRAY[
    'public.direct_chat_message_idempotency'::regclass,
    'public.partner_fox_message_sends'::regclass
  ] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class AS table_row WHERE table_row.oid = v_table AND table_row.relrowsecurity)
       OR has_table_privilege('anon', v_table, 'SELECT')
       OR has_table_privilege('authenticated', v_table, 'SELECT')
       OR has_table_privilege('service_role', v_table, 'SELECT') THEN
      RAISE EXCEPTION 'FAIL SQL27c: idempotency ledger must use RLS and reject direct API-role reads';
    END IF;
  END LOOP;
END $$;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-00000000c271', 'wingward-test-sql27-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000c272', 'wingward-test-sql27-b@example.invalid'),
  ('00000000-0000-0000-0000-00000000c273', 'wingward-test-sql27-c@example.invalid'),
  ('00000000-0000-0000-0000-00000000c274', 'wingward-test-sql27-d@example.invalid');

WITH fixtures (auth_user_id, profile_id, nickname) AS (
  VALUES
    ('00000000-0000-0000-0000-00000000c271'::uuid, '10000000-0000-0000-0000-00000000c271'::uuid, 'SQL27 A'),
    ('00000000-0000-0000-0000-00000000c272'::uuid, '10000000-0000-0000-0000-00000000c272'::uuid, 'SQL27 B'),
    ('00000000-0000-0000-0000-00000000c273'::uuid, '10000000-0000-0000-0000-00000000c273'::uuid, 'SQL27 C'),
    ('00000000-0000-0000-0000-00000000c274'::uuid, '10000000-0000-0000-0000-00000000c274'::uuid, 'SQL27 D')
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
  ('20000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c272', 'direct_chat_active'),
  ('20000000-0000-0000-0000-00000000c272', '10000000-0000-0000-0000-00000000c273', '10000000-0000-0000-0000-00000000c274', 'direct_chat_active');

INSERT INTO public.chat_requests
  (id, match_id, requester_id, responder_id, status, responded_at, expires_at)
VALUES
  ('30000000-0000-0000-0000-00000000c271', '20000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c272', 'pending', NULL, '2026-10-01T00:00:00Z'),
  ('30000000-0000-0000-0000-00000000c272', '20000000-0000-0000-0000-00000000c272', '10000000-0000-0000-0000-00000000c273', '10000000-0000-0000-0000-00000000c274', 'pending', NULL, '2026-10-01T00:00:00Z');

UPDATE public.chat_requests
   SET status = 'accepted', responded_at = '2026-09-26T00:00:00Z'
 WHERE id IN ('30000000-0000-0000-0000-00000000c271', '30000000-0000-0000-0000-00000000c272');

INSERT INTO public.direct_chat_rooms (id, match_id, status) VALUES
  ('40000000-0000-0000-0000-00000000c271', '20000000-0000-0000-0000-00000000c271', 'active'),
  ('40000000-0000-0000-0000-00000000c272', '20000000-0000-0000-0000-00000000c272', 'active');

INSERT INTO public.partner_fox_chats (id, match_id, user_id, partner_user_id) VALUES
  ('50000000-0000-0000-0000-00000000c271', '20000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c272'),
  ('50000000-0000-0000-0000-00000000c272', '20000000-0000-0000-0000-00000000c272', '10000000-0000-0000-0000-00000000c273', '10000000-0000-0000-0000-00000000c274');

CREATE TEMP TABLE sql27_claim_tokens (token_name text PRIMARY KEY, claim_token uuid NOT NULL) ON COMMIT DROP;
GRANT SELECT, INSERT, UPDATE ON TABLE sql27_claim_tokens TO service_role;

SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_row record;
  v_key uuid := '80000000-0000-0000-0000-00000000c271';
  v_message_id uuid;
  v_claim_token uuid;
  v_old_token uuid;
  v_new_token uuid;
  v_user_message_id uuid;
  v_fox_message_id uuid;
  v_count integer;
BEGIN
  -- Direct: the first call inserts; retry returns exactly the same row.
  SELECT * INTO v_row FROM public.persist_direct_chat_message(
    '40000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'hello direct', pg_catalog.repeat('a', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'inserted' OR v_row.message_id IS NULL
     OR v_row.message_content IS DISTINCT FROM 'hello direct' THEN
    RAISE EXCEPTION 'FAIL SQL27d: direct first call did not insert';
  END IF;
  v_message_id := v_row.message_id;
  SELECT * INTO v_row FROM public.persist_direct_chat_message(
    '40000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'hello direct', pg_catalog.repeat('a', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'replayed' OR v_row.message_id IS DISTINCT FROM v_message_id THEN
    RAISE EXCEPTION 'FAIL SQL27e: direct retry did not return the committed row';
  END IF;
  SELECT count(*) INTO v_count FROM public.direct_chat_messages
   WHERE room_id = '40000000-0000-0000-0000-00000000c271' AND sender_id = '10000000-0000-0000-0000-00000000c271';
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL27f: direct retry created duplicate messages'; END IF;

  SELECT * INTO v_row FROM public.persist_direct_chat_message(
    '40000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'changed direct', pg_catalog.repeat('b', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'conflict' THEN RAISE EXCEPTION 'FAIL SQL27g: direct key/content conflict was accepted'; END IF;
  SELECT * INTO v_row FROM public.persist_direct_chat_message(
    '40000000-0000-0000-0000-00000000c272', '10000000-0000-0000-0000-00000000c273',
    v_key, 'hello direct', pg_catalog.repeat('a', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'conflict' THEN RAISE EXCEPTION 'FAIL SQL27h: direct key was reusable in another room/owner scope'; END IF;

  DELETE FROM public.direct_chat_messages WHERE id = v_message_id;
  SELECT * INTO v_row FROM public.persist_direct_chat_message(
    '40000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'hello direct', pg_catalog.repeat('a', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'missing' OR v_row.message_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL27i: deleted direct row did not stay terminal';
  END IF;
  SELECT count(*) INTO v_count FROM public.direct_chat_messages
   WHERE room_id = '40000000-0000-0000-0000-00000000c271';
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL27j: missing-row replay inserted a replacement'; END IF;

  -- Partner Ward: claim -> atomic completion -> replay is the same one pair.
  v_key := '80000000-0000-0000-0000-00000000c272';
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'hello partner', pg_catalog.repeat('c', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' OR v_row.user_message_id IS NULL OR v_row.claim_token IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL27k: Partner Ward claim was not persisted';
  END IF;
  v_claim_token := v_row.claim_token;
  v_user_message_id := v_row.user_message_id;
  SELECT * INTO v_row FROM public.complete_partner_fox_message_send(v_key, v_claim_token, 'hello back');
  IF v_row.outcome IS DISTINCT FROM 'completed' OR v_row.user_message_id IS DISTINCT FROM v_user_message_id
     OR v_row.fox_message_id IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL27l: Partner Ward completion did not atomically save the pair';
  END IF;
  v_fox_message_id := v_row.fox_message_id;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'hello partner', pg_catalog.repeat('c', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'replayed' OR v_row.user_message_id IS DISTINCT FROM v_user_message_id
     OR v_row.fox_message_id IS DISTINCT FROM v_fox_message_id THEN
    RAISE EXCEPTION 'FAIL SQL27m: Partner Ward retry did not replay the completed pair';
  END IF;
  SELECT count(*) INTO v_count FROM public.partner_fox_messages
   WHERE chat_id = '50000000-0000-0000-0000-00000000c271' AND role = 'user';
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL27n: Partner Ward retry duplicated the user message'; END IF;
  SELECT count(*) INTO v_count FROM public.partner_fox_messages
   WHERE chat_id = '50000000-0000-0000-0000-00000000c271' AND role = 'fox';
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL27o: Partner Ward retry regenerated the Fox message'; END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'different content', pg_catalog.repeat('d', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'conflict' THEN RAISE EXCEPTION 'FAIL SQL27p: Partner key/content conflict was accepted'; END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c272', '10000000-0000-0000-0000-00000000c273',
    v_key, 'hello partner', pg_catalog.repeat('c', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'conflict' THEN RAISE EXCEPTION 'FAIL SQL27q: Partner key was reusable across owner/chat scope'; END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c272',
    v_key, 'hello partner', pg_catalog.repeat('c', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN RAISE EXCEPTION 'FAIL SQL27r: wrong Partner Ward owner learned a replay'; END IF;

  -- Only a definite pre-provider failure is retryable, and only the latest
  -- failed key may restart after a later send exists.
  v_key := '80000000-0000-0000-0000-00000000c273';
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'definite failure', pg_catalog.repeat('e', 64)
  );
  v_old_token := v_row.claim_token;
  SELECT * INTO v_row FROM public.finish_partner_fox_message_send(v_key, v_old_token, 'failed');
  IF v_row.outcome IS DISTINCT FROM 'failed' THEN RAISE EXCEPTION 'FAIL SQL27s: definite failure did not become retryable'; END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'definite failure', pg_catalog.repeat('e', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' OR v_row.claim_token IS NULL
     OR v_row.claim_token IS NOT DISTINCT FROM v_old_token THEN
    RAISE EXCEPTION 'FAIL SQL27t: same failed key did not issue a fresh claim';
  END IF;
  v_new_token := v_row.claim_token;
  SELECT * INTO v_row FROM public.complete_partner_fox_message_send(v_key, v_old_token, 'old token output');
  IF v_row.outcome IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'FAIL SQL27u: superseded claim token completed'; END IF;
  SELECT * INTO v_row FROM public.complete_partner_fox_message_send(v_key, v_new_token, 'retry output');
  IF v_row.outcome IS DISTINCT FROM 'completed' THEN RAISE EXCEPTION 'FAIL SQL27v: fresh retry claim did not complete'; END IF;

  v_key := '80000000-0000-0000-0000-00000000c274';
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'older failed message', pg_catalog.repeat('f', 64)
  );
  v_old_token := v_row.claim_token;
  PERFORM public.finish_partner_fox_message_send(v_key, v_old_token, 'failed');
  v_key := '80000000-0000-0000-0000-00000000c275';
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'later message', pg_catalog.repeat('1', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' THEN RAISE EXCEPTION 'FAIL SQL27w: later key was blocked after failure'; END IF;
  v_new_token := v_row.claim_token;
  SELECT * INTO v_row FROM public.complete_partner_fox_message_send(v_key, v_new_token, 'later reply');
  IF v_row.outcome IS DISTINCT FROM 'completed' THEN RAISE EXCEPTION 'FAIL SQL27x: later key did not complete'; END IF;
  v_key := '80000000-0000-0000-0000-00000000c274';
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'older failed message', pg_catalog.repeat('f', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'FAIL SQL27y: older failed key overtook a later completed send'; END IF;

  -- Expiry is uncertain, so admitting a new key seals the previous attempt as
  -- unknown. Its old claim token cannot complete or create another Fox row.
  v_key := '80000000-0000-0000-0000-00000000c276';
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    v_key, 'uncertain message', pg_catalog.repeat('2', 64)
  );
  v_old_token := v_row.claim_token;
  INSERT INTO pg_temp.sql27_claim_tokens (token_name, claim_token) VALUES ('expired-send', v_old_token);

END $$;

-- Simulate worker loss after the claim commit. The next key closes the old
-- lease as unknown, releases the chat, and cannot be followed by an old-token
-- completion.
RESET ROLE;
UPDATE public.partner_fox_message_sends
   SET lease_expires_at = pg_catalog.now() - interval '1 second'
 WHERE idempotency_key = '80000000-0000-0000-0000-00000000c276';
SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_row record;
  v_old_token uuid;
  v_new_token uuid;
BEGIN
  SELECT claim_token INTO v_old_token FROM pg_temp.sql27_claim_tokens WHERE token_name = 'expired-send';
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    '80000000-0000-0000-0000-00000000c277', 'next message', pg_catalog.repeat('3', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' THEN RAISE EXCEPTION 'FAIL SQL27z: expired claim left the chat permanently busy'; END IF;
  v_new_token := v_row.claim_token;
  SELECT * INTO v_row FROM public.complete_partner_fox_message_send(
    '80000000-0000-0000-0000-00000000c276', v_old_token, 'late provider output'
  );
  IF v_row.outcome IS DISTINCT FROM 'stale' THEN RAISE EXCEPTION 'FAIL SQL27aa: expired claim token completed'; END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    '80000000-0000-0000-0000-00000000c276', 'uncertain message', pg_catalog.repeat('2', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'unknown' THEN RAISE EXCEPTION 'FAIL SQL27ab: uncertain key was allowed to regenerate'; END IF;
  SELECT * INTO v_row FROM public.complete_partner_fox_message_send(
    '80000000-0000-0000-0000-00000000c277', v_new_token, 'next reply'
  );
  IF v_row.outcome IS DISTINCT FROM 'completed' THEN RAISE EXCEPTION 'FAIL SQL27ac: later send did not complete after expiry recovery'; END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    '80000000-0000-0000-0000-00000000c278', 'unknown finish', pg_catalog.repeat('4', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' THEN RAISE EXCEPTION 'FAIL SQL27ad: later key was blocked after expiry recovery'; END IF;
  v_new_token := v_row.claim_token;
  SELECT * INTO v_row FROM public.finish_partner_fox_message_send('80000000-0000-0000-0000-00000000c278', v_new_token, NULL);
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN RAISE EXCEPTION 'FAIL SQL27ae: NULL finish outcome was not rejected'; END IF;
  SELECT * INTO v_row FROM public.finish_partner_fox_message_send('80000000-0000-0000-0000-00000000c278', v_new_token, 'unknown');
  IF v_row.outcome IS DISTINCT FROM 'unknown' THEN RAISE EXCEPTION 'FAIL SQL27af: uncertain finish did not become terminal'; END IF;
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c271', '10000000-0000-0000-0000-00000000c271',
    '80000000-0000-0000-0000-00000000c278', 'unknown finish', pg_catalog.repeat('4', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'unknown' THEN RAISE EXCEPTION 'FAIL SQL27ag: explicit unknown finish regenerated'; END IF;
END $$;

RESET ROLE;
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-00000000c273', '10000000-0000-0000-0000-00000000c274');
SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_row record;
BEGIN
  SELECT * INTO v_row FROM public.claim_partner_fox_message_send(
    '50000000-0000-0000-0000-00000000c272', '10000000-0000-0000-0000-00000000c273',
    '80000000-0000-0000-0000-00000000c279', 'blocked message', pg_catalog.repeat('5', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'ineligible' THEN RAISE EXCEPTION 'FAIL SQL27ad: blocked pair passed claim eligibility'; END IF;
  SELECT * INTO v_row FROM public.persist_direct_chat_message(
    '40000000-0000-0000-0000-00000000c272', '10000000-0000-0000-0000-00000000c273',
    '80000000-0000-0000-0000-00000000c280', 'blocked direct message', pg_catalog.repeat('6', 64)
  );
  IF v_row.outcome IS DISTINCT FROM 'ineligible' THEN RAISE EXCEPTION 'FAIL SQL27ah: blocked pair passed direct send eligibility'; END IF;
END $$;

RESET ROLE;
ROLLBACK;
