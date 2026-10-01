-- SQL25 partner-Fox greeting recovery acceptance fixture.
--
-- Prepare only. Run with psql -v ON_ERROR_STOP=1 after all migrations and an
-- explicit per-run approval for synthetic database writes. This script rolls
-- back its fixtures. It intentionally does not pretend one transaction proves
-- a concurrent interleaving; the two-session probe at the end is the runtime
-- check for simultaneous retries, a user-message winner, room close, and
-- profile/block changes.

BEGIN;
SET LOCAL statement_timeout = '15s';

DO $$
DECLARE
  v_oid oid;
  v_definition text;
  v_rpc_match integer;
  v_rpc_room integer;
  v_rpc_chat integer;
  v_rpc_conversation integer;
  v_rpc_profiles integer;
  v_guard_actor integer;
  v_guard_match_lock integer;
  v_guard_chat_lock integer;
BEGIN
  v_oid := to_regprocedure('public.persist_partner_fox_greeting(uuid,uuid,uuid,uuid,text)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL25a: greeting RPC is missing';
  END IF;
  SELECT pg_catalog.pg_get_functiondef(v_oid) INTO v_definition;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS proc
     WHERE proc.oid = v_oid
       AND proc.prosecdef IS TRUE
       AND proc.proconfig @> ARRAY['search_path=""']::text[]
  ) THEN
    RAISE EXCEPTION 'FAIL SQL25a: greeting RPC is not SECURITY DEFINER with empty search_path';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL25a: greeting RPC grants are not service_role-only';
  END IF;
  IF v_definition NOT LIKE '%p_content ~ ''^[[:space:]]*$''%'
     OR v_definition NOT LIKE '%char_length(p_content) > 2000%'
     OR v_definition NOT LIKE '%message_present%'
     OR v_definition NOT LIKE '%already_started%' THEN
    RAISE EXCEPTION 'FAIL SQL25a: greeting RPC lacks bounded content and winner outcomes';
  END IF;

  v_rpc_match := pg_catalog.strpos(v_definition, 'FROM public.matches AS match_row');
  v_rpc_room := pg_catalog.strpos(v_definition, 'FROM public.direct_chat_rooms AS room_row');
  v_rpc_chat := pg_catalog.strpos(v_definition, 'FROM public.partner_fox_chats AS chat_row');
  v_rpc_conversation := pg_catalog.strpos(v_definition, 'FROM public.fox_conversations AS conversation_row');
  v_rpc_profiles := pg_catalog.strpos(v_definition, 'wingward_private.lock_and_check_mutual_eligibility');
  IF v_rpc_match < 1 OR v_rpc_room <= v_rpc_match OR v_rpc_chat <= v_rpc_room
     OR v_rpc_conversation <= v_rpc_chat OR v_rpc_profiles <= v_rpc_conversation
     OR v_definition NOT LIKE '%FOR UPDATE%'
     OR v_definition NOT LIKE '%FOR SHARE%' THEN
    RAISE EXCEPTION 'FAIL SQL25b: greeting RPC does not preserve match -> room -> chat -> compatibility -> profiles locking';
  END IF;

  v_oid := to_regprocedure('wingward_private.guard_partner_fox_message_mutual_eligibility()');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL25c: message guard is missing';
  END IF;
  SELECT pg_catalog.pg_get_functiondef(v_oid) INTO v_definition;
  v_guard_actor := pg_catalog.strpos(v_definition, 'v_auth_user_id :=');
  v_guard_match_lock := v_guard_actor
    + pg_catalog.strpos(
        pg_catalog.substr(v_definition, v_guard_actor),
        'FROM public.matches AS match_row'
      ) - 1;
  v_guard_chat_lock := v_guard_match_lock
    + pg_catalog.strpos(
        pg_catalog.substr(v_definition, v_guard_match_lock),
        'FOR KEY SHARE'
      ) - 1;
  IF v_guard_actor < 1 OR v_guard_match_lock <= v_guard_actor
     OR v_guard_chat_lock < 1
     OR pg_catalog.strpos(
          pg_catalog.substr(v_definition, v_guard_chat_lock),
          'FROM public.partner_fox_chats AS chat_row'
        ) < 1
     OR v_definition NOT LIKE '%FOR KEY SHARE%'
     OR v_definition NOT LIKE '%lock_and_check_mutual_eligibility%' THEN
    RAISE EXCEPTION 'FAIL SQL25c: message guard does not validate actor before match/chat KEY SHARE and profile locks';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL25c: private message guard has an API-role EXECUTE grant';
  END IF;
END $$;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-00000000b251', 'wingward-test-sql25-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000b252', 'wingward-test-sql25-b@example.invalid'),
  ('00000000-0000-0000-0000-00000000b253', 'wingward-test-sql25-c@example.invalid'),
  ('00000000-0000-0000-0000-00000000b254', 'wingward-test-sql25-d@example.invalid');

WITH fixtures (auth_user_id, profile_id, nickname) AS (
  VALUES
    ('00000000-0000-0000-0000-00000000b251'::uuid, '10000000-0000-0000-0000-00000000b251'::uuid, 'SQL25 A'),
    ('00000000-0000-0000-0000-00000000b252'::uuid, '10000000-0000-0000-0000-00000000b252'::uuid, 'SQL25 B'),
    ('00000000-0000-0000-0000-00000000b253'::uuid, '10000000-0000-0000-0000-00000000b253'::uuid, 'SQL25 C'),
    ('00000000-0000-0000-0000-00000000b254'::uuid, '10000000-0000-0000-0000-00000000b254'::uuid, 'SQL25 D')
)
UPDATE public.user_profiles AS profile_row
   SET id = fixture.profile_id,
       nickname = fixture.nickname,
       birth_date = DATE '1990-01-01',
       age_verified_at = '2026-09-07T00:00:00Z',
       age_verification_method = 'self_declared',
       gender_identity = 'woman',
       preferred_genders = ARRAY['woman']::text[],
       preference_mode = 'selected',
       dating_market = 'JP',
       onboarding_settings_completed_at = '2026-09-07T00:00:00Z',
       identity_verification_status = 'verified',
       identity_verified_at = '2026-09-07T00:00:00Z'
  FROM fixtures AS fixture
 WHERE profile_row.auth_user_id = fixture.auth_user_id;

INSERT INTO public.matches (id, user_a_id, user_b_id, status) VALUES
  ('20000000-0000-0000-0000-00000000b251', '10000000-0000-0000-0000-00000000b251', '10000000-0000-0000-0000-00000000b252', 'fox_conversation_completed'),
  ('20000000-0000-0000-0000-00000000b253', '10000000-0000-0000-0000-00000000b253', '10000000-0000-0000-0000-00000000b254', 'fox_conversation_completed');

INSERT INTO public.fox_conversations (id, match_id, purpose, status, total_rounds, current_round)
VALUES
  ('30000000-0000-0000-0000-00000000b251', '20000000-0000-0000-0000-00000000b251', 'compatibility', 'completed', 15, 15),
  ('30000000-0000-0000-0000-00000000b253', '20000000-0000-0000-0000-00000000b253', 'compatibility', 'completed', 15, 15);

INSERT INTO public.partner_fox_chats (id, match_id, user_id, partner_user_id)
VALUES
  ('50000000-0000-0000-0000-00000000b251', '20000000-0000-0000-0000-00000000b251', '10000000-0000-0000-0000-00000000b251', '10000000-0000-0000-0000-00000000b252'),
  ('50000000-0000-0000-0000-00000000b253', '20000000-0000-0000-0000-00000000b253', '10000000-0000-0000-0000-00000000b253', '10000000-0000-0000-0000-00000000b254');

INSERT INTO public.direct_chat_rooms (id, match_id, status)
VALUES ('40000000-0000-0000-0000-00000000b251', '20000000-0000-0000-0000-00000000b251', 'closed');

SET LOCAL role = 'service_role';

DO $$
DECLARE
  v_row record;
BEGIN
  SELECT * INTO v_row
    FROM public.persist_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b251',
      '20000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b252',
      'blocked by closed room'
    );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL25d: closed room was accepted in fox_conversation_completed';
  END IF;

  UPDATE public.direct_chat_rooms
     SET status = 'active'
   WHERE match_id = '20000000-0000-0000-0000-00000000b251';

  SELECT * INTO v_row
    FROM public.persist_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b251',
      '20000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b252',
      'hello from SQL25'
    );
  IF v_row.outcome IS DISTINCT FROM 'inserted'
     OR v_row.message_role IS DISTINCT FROM 'fox'
     OR v_row.message_content IS DISTINCT FROM 'hello from SQL25'
     OR v_row.transitioned IS DISTINCT FROM true
     OR v_row.match_status IS DISTINCT FROM 'partner_chat_started' THEN
    RAISE EXCEPTION 'FAIL SQL25e: initial greeting did not atomically persist and advance';
  END IF;

  SELECT * INTO v_row
    FROM public.persist_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b251',
      '20000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b252',
      '10000000-0000-0000-0000-00000000b251',
      'a competing provider result'
    );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL25f: wrong owner/partner tuple was accepted';
  END IF;

  UPDATE public.direct_chat_rooms
     SET status = 'closed'
   WHERE match_id = '20000000-0000-0000-0000-00000000b251';
  SELECT * INTO v_row
    FROM public.persist_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b251',
      '20000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b252',
      'must not replay through closed room'
    );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL25g: closed room was accepted after later match state';
  END IF;

  UPDATE public.direct_chat_rooms
     SET status = 'active'
   WHERE match_id = '20000000-0000-0000-0000-00000000b251';
  SELECT * INTO v_row
    FROM public.persist_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b251',
      '20000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b252',
      'a duplicate provider result'
    );
  IF v_row.outcome IS DISTINCT FROM 'already_started'
     OR v_row.message_content IS DISTINCT FROM 'hello from SQL25'
     OR v_row.transitioned IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL SQL25h: replay did not preserve the original winner';
  END IF;

  SELECT * INTO v_row
    FROM public.persist_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b251',
      '20000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b251',
      '10000000-0000-0000-0000-00000000b252',
      E'\n\t\r'
    );
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL SQL25i: whitespace-only greeting was accepted';
  END IF;
END $$;

DO $$
DECLARE
  v_row record;
  v_count integer;
BEGIN
  -- The second pair has no room because fox_conversation_completed does not
  -- require one. A user-first row must remain the winner even if a legacy
  -- later fox row is present.
  INSERT INTO public.partner_fox_messages (id, chat_id, role, content, created_at)
  VALUES
    ('60000000-0000-0000-0000-00000000b253', '50000000-0000-0000-0000-00000000b253', 'user', 'user won first', '2026-09-07T00:00:00Z'),
    ('60000000-0000-0000-0000-00000000b254', '50000000-0000-0000-0000-00000000b253', 'fox', 'legacy later fox', '2026-09-07T00:00:01Z');
  SELECT * INTO v_row
    FROM public.persist_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b253',
      '20000000-0000-0000-0000-00000000b253',
      '10000000-0000-0000-0000-00000000b253',
      '10000000-0000-0000-0000-00000000b254',
      'must not replace user'
    );
  IF v_row.outcome IS DISTINCT FROM 'message_present'
     OR v_row.message_id IS NOT NULL
     OR v_row.message_content IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL25j: user-first message was replaced or disclosed';
  END IF;
  SELECT count(*) INTO v_count
    FROM public.partner_fox_messages
   WHERE chat_id = '50000000-0000-0000-0000-00000000b253';
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'FAIL SQL25j: message count changed during user-first recovery';
  END IF;

  SELECT * INTO v_row
    FROM public.persist_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b253',
      '20000000-0000-0000-0000-00000000b253',
      '10000000-0000-0000-0000-00000000b253',
      '10000000-0000-0000-0000-00000000b254',
      pg_catalog.repeat('x', 2001)
    );
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL SQL25k: oversized greeting was accepted';
  END IF;

  -- A later contact state still permits recovery of an empty chat, but the
  -- RPC must never downgrade it back through partner_chat_started.
  DELETE FROM public.partner_fox_messages
   WHERE chat_id = '50000000-0000-0000-0000-00000000b253';
  INSERT INTO public.direct_chat_rooms (id, match_id, status)
  VALUES ('40000000-0000-0000-0000-00000000b253', '20000000-0000-0000-0000-00000000b253', 'active');
  UPDATE public.matches
     SET status = 'direct_chat_active'
   WHERE id = '20000000-0000-0000-0000-00000000b253';
  SELECT * INTO v_row
    FROM public.persist_partner_fox_greeting(
      '50000000-0000-0000-0000-00000000b253',
      '20000000-0000-0000-0000-00000000b253',
      '10000000-0000-0000-0000-00000000b253',
      '10000000-0000-0000-0000-00000000b254',
      'later-state recovery'
    );
  IF v_row.outcome IS DISTINCT FROM 'inserted'
     OR v_row.transitioned IS DISTINCT FROM false
     OR v_row.match_status IS DISTINCT FROM 'direct_chat_active' THEN
    RAISE EXCEPTION 'FAIL SQL25l: later-state recovery downgraded or failed';
  END IF;
END $$;

-- Runtime concurrency probe (run in two psql sessions, outside this fixture):
--   BEGIN; SET LOCAL role = 'service_role';
--   SELECT * FROM public.persist_partner_fox_greeting(
--     '50000000-0000-0000-0000-00000000b251',
--     '20000000-0000-0000-0000-00000000b251',
--     '10000000-0000-0000-0000-00000000b251',
--     '10000000-0000-0000-0000-00000000b252', 'session result');
-- Keep session A open before running the same call in session B, then commit
-- both. Assert one partner_fox_messages row, one winner content, and no row
-- deletion. Repeat with a concurrent user-message insert, a room close, a
-- compatibility-conversation status change, and a block/profile change; the
-- guarded loser must return not_found or message_present without mutating the
-- winner. The root runtime run owns this DB execution and approval.

ROLLBACK;
