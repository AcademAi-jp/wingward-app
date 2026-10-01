-- B2 block-serialization fixture.  Prepare only; do not execute until the
-- separate per-run approval for synthetic DB writes, commit and deletion is
-- granted.  The transaction below rolls back all synthetic rows when run.
--
-- The two-session race probe is intentionally outside this file.  This
-- fixture verifies the SQL contract that makes that probe meaningful:
-- INSERT/UPSERT takes sorted profile locks, the helper rechecks both block
-- directions after its FOR SHARE locks, and existing protected writers keep
-- their narrow cleanup paths after the helper returns false.

BEGIN;
SET LOCAL statement_timeout = '15s';

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-00000000b241', 'b2-block-sql24-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000b242', 'b2-block-sql24-b@example.invalid'),
  ('00000000-0000-0000-0000-00000000b243', 'b2-block-sql24-c@example.invalid'),
  ('00000000-0000-0000-0000-00000000b244', 'b2-block-sql24-d@example.invalid');

-- The signup trigger creates these rows.  All four profiles are mutually
-- eligible so a later false result is attributable to the block itself.
WITH fixtures (auth_user_id, profile_id, nickname) AS (
  VALUES
    ('00000000-0000-0000-0000-00000000b241'::uuid, '10000000-0000-0000-0000-00000000b241'::uuid, 'B2 block SQL24 A'),
    ('00000000-0000-0000-0000-00000000b242'::uuid, '10000000-0000-0000-0000-00000000b242'::uuid, 'B2 block SQL24 B'),
    ('00000000-0000-0000-0000-00000000b243'::uuid, '10000000-0000-0000-0000-00000000b243'::uuid, 'B2 block SQL24 C'),
    ('00000000-0000-0000-0000-00000000b244'::uuid, '10000000-0000-0000-0000-00000000b244'::uuid, 'B2 block SQL24 D')
)
UPDATE public.user_profiles AS profile_row
   SET id = fixture.profile_id,
       nickname = fixture.nickname,
       birth_date = DATE '1990-01-01',
       age_verified_at = '2026-09-07T00:00:00Z',
       age_verification_method = 'self_declared',
       gender_identity = 'nonbinary',
       preferred_genders = ARRAY['nonbinary']::text[],
       preference_mode = 'selected',
       dating_market = 'JP',
       onboarding_settings_completed_at = '2026-09-07T00:00:00Z'
  FROM fixtures AS fixture
 WHERE profile_row.auth_user_id = fixture.auth_user_id;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(p_ok boolean, p_label text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_ok IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL SQL24: %', p_label;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.assert_false(p_ok boolean, p_label text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_ok IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL SQL24: %', p_label;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.expect_rejected(p_statement text, p_message text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_sqlstate text;
  v_message text;
BEGIN
  BEGIN
    EXECUTE p_statement;
    RAISE EXCEPTION 'expected guarded statement to fail';
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS
        v_sqlstate = RETURNED_SQLSTATE,
        v_message = MESSAGE_TEXT;
  END;

  IF v_sqlstate IS DISTINCT FROM '23514' OR v_message IS DISTINCT FROM p_message THEN
    RAISE EXCEPTION 'FAIL SQL24: expected check_violation %, got % (%)', p_message, v_message, v_sqlstate;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.expect_role_rejected(
  p_statement text,
  p_sqlstate text,
  p_message text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_sqlstate text;
  v_message text;
BEGIN
  BEGIN
    EXECUTE p_statement;
    RAISE EXCEPTION 'expected role-restricted statement to fail';
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS
        v_sqlstate = RETURNED_SQLSTATE,
        v_message = MESSAGE_TEXT;
  END;

  IF v_sqlstate IS DISTINCT FROM p_sqlstate OR v_message IS DISTINCT FROM p_message THEN
    RAISE EXCEPTION 'FAIL SQL24: expected % %, got % (%)', p_sqlstate, p_message, v_sqlstate, v_message;
  END IF;
END;
$$;

RESET ROLE;

-- Verify the private surface and the shared lock contract before exercising
-- rows.  These checks also prove the original blocks INSERT policy remains in
-- place; this migration does not widen grants or replace RLS.
DO $$
DECLARE
  v_oid oid;
  v_definition text;
  v_config text[];
  v_provolatile "char";
  v_is_definer boolean;
  v_trigger_definition text;
BEGIN
  v_oid := to_regprocedure('wingward_private.lock_and_check_mutual_eligibility(uuid,uuid)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL24a: mutual helper is missing';
  END IF;
  SELECT p.provolatile, p.prosecdef, p.proconfig, pg_get_functiondef(p.oid)
    INTO v_provolatile, v_is_definer, v_config, v_definition
    FROM pg_proc AS p
   WHERE p.oid = v_oid;
  IF NOT v_is_definer OR v_provolatile <> 'v' OR NOT ('search_path=""' = ANY(v_config)) THEN
    RAISE EXCEPTION 'FAIL SQL24a: helper is not volatile SECURITY DEFINER with empty search_path';
  END IF;
  IF strpos(v_definition, 'FOR SHARE') = 0
     OR strpos(v_definition, 'FROM public.blocks') = 0
     OR strpos(v_definition, 'RETURN false') = 0 THEN
    RAISE EXCEPTION 'FAIL SQL24a: helper lacks the post-lock bidirectional block check';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL24a: mutual helper has an API-role EXECUTE grant';
  END IF;

  v_oid := to_regprocedure('wingward_private.guard_block_insert_serialization()');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL24b: block INSERT guard is missing';
  END IF;
  SELECT p.prosecdef, p.proconfig, pg_get_functiondef(p.oid)
    INTO v_is_definer, v_config, v_definition
    FROM pg_proc AS p
   WHERE p.oid = v_oid;
  IF NOT v_is_definer OR NOT ('search_path=""' = ANY(v_config))
     OR strpos(v_definition, 'FOR NO KEY UPDATE') = 0
     OR strpos(v_definition, 'NEW.blocker_id < NEW.blocked_id') = 0
     OR strpos(v_definition, 'v_auth_user_id := (SELECT auth.uid())') = 0
     OR strpos(v_definition, 'v_auth_user_id := (SELECT auth.uid())') > strpos(v_definition, 'WHERE profile_row.id = v_low_id') THEN
    RAISE EXCEPTION 'FAIL SQL24b: block guard does not validate actor before sorted profile locks';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL24b: block INSERT guard has an API-role EXECUTE grant';
  END IF;
  IF strpos(v_definition, 'public.matches') > 0
     OR strpos(v_definition, 'public.direct_chat_rooms') > 0 THEN
    RAISE EXCEPTION 'FAIL SQL24b: block guard acquires an out-of-scope match/room lock';
  END IF;

  v_oid := to_regprocedure('wingward_private.freeze_block_participants()');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL24c: block UPDATE guard is missing';
  END IF;
  SELECT p.prosecdef, p.proconfig, pg_get_functiondef(p.oid)
    INTO v_is_definer, v_config, v_definition
    FROM pg_proc AS p
   WHERE p.oid = v_oid;
  IF NOT v_is_definer OR NOT ('search_path=""' = ANY(v_config))
     OR strpos(v_definition, 'NEW.blocker_id IS DISTINCT FROM OLD.blocker_id') = 0
     OR strpos(v_definition, 'NEW.blocked_id IS DISTINCT FROM OLD.blocked_id') = 0 THEN
    RAISE EXCEPTION 'FAIL SQL24c: block participants are not frozen';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL24c: block UPDATE guard has an API-role EXECUTE grant';
  END IF;

  SELECT pg_get_triggerdef(t.oid)
    INTO v_trigger_definition
    FROM pg_trigger AS t
    JOIN pg_class AS c ON c.oid = t.tgrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_proc AS p ON p.oid = t.tgfoid
    JOIN pg_namespace AS pn ON pn.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'blocks'
     AND t.tgname = 'blocks_guard_insert_serialization'
     AND pn.nspname = 'wingward_private'
     AND p.proname = 'guard_block_insert_serialization'
     AND NOT t.tgisinternal;
  IF v_trigger_definition IS NULL OR v_trigger_definition NOT LIKE '%BEFORE INSERT%' THEN
    RAISE EXCEPTION 'FAIL SQL24d: block INSERT trigger is not wired';
  END IF;

  SELECT pg_get_triggerdef(t.oid)
    INTO v_trigger_definition
    FROM pg_trigger AS t
    JOIN pg_class AS c ON c.oid = t.tgrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    JOIN pg_proc AS p ON p.oid = t.tgfoid
    JOIN pg_namespace AS pn ON pn.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'blocks'
     AND t.tgname = 'blocks_freeze_participants'
     AND pn.nspname = 'wingward_private'
     AND p.proname = 'freeze_block_participants'
     AND NOT t.tgisinternal;
  IF v_trigger_definition IS NULL OR v_trigger_definition NOT LIKE '%BEFORE UPDATE%' THEN
    RAISE EXCEPTION 'FAIL SQL24d: block UPDATE trigger is not wired';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_policy AS policy_row
      JOIN pg_class AS table_row ON table_row.oid = policy_row.polrelid
      JOIN pg_namespace AS schema_row ON schema_row.oid = table_row.relnamespace
     WHERE schema_row.nspname = 'public'
       AND table_row.relname = 'blocks'
       AND policy_row.polname = 'blocks_insert'
       AND policy_row.polcmd = 'a'
  ) THEN
    RAISE EXCEPTION 'FAIL SQL24d: existing blocks INSERT policy was removed';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_trigger AS t
      JOIN pg_class AS c ON c.oid = t.tgrelid
      JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname = 'blocks'
       AND pg_get_triggerdef(t.oid) LIKE '%DELETE%'
       AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL SQL24d: block DELETE unexpectedly takes a profile lock';
  END IF;

  RAISE NOTICE 'PASS SQL24a-d: helper volatility, private ACLs, sorted block triggers, preserved RLS and unlocked DELETE';
END;
$$;

-- The four service-only RPCs retain their existing nondisclosing false/error
-- paths.  The helper extension is the post-profile-lock backstop; no RPC
-- signature or grant changes are introduced here.
DO $$
DECLARE
  v_name text;
  v_oid oid;
  v_definition text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'public.create_or_match_meetup_intent(uuid,uuid)',
    'public.record_meetup_proposal_response(uuid,uuid,uuid,integer)',
    'public.claim_meetup_arrangement(uuid,uuid,boolean,text)',
    'public.persist_meetup_proposal(uuid,uuid,integer,jsonb)'
  ] LOOP
    v_oid := to_regprocedure(v_name);
    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'FAIL SQL24e: missing existing RPC %', v_name;
    END IF;
    SELECT pg_get_functiondef(p.oid) INTO v_definition FROM pg_proc AS p WHERE p.oid = v_oid;
    IF strpos(v_definition, 'lock_and_check_mutual_eligibility') = 0 THEN
      RAISE EXCEPTION 'FAIL SQL24e: RPC % bypasses the current mutual helper', v_name;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS SQL24e: intent, response, arrangement and proposal RPCs retain helper false/error gates';
END;
$$;

-- Before any block exists, the helper accepts both argument orders.
RESET ROLE;
SELECT pg_temp.assert_true(
  wingward_private.lock_and_check_mutual_eligibility(
    '10000000-0000-0000-0000-00000000b241',
    '10000000-0000-0000-0000-00000000b242'
  ),
  'unblocked pair is eligible in blocker order'
);
SELECT pg_temp.assert_true(
  wingward_private.lock_and_check_mutual_eligibility(
    '10000000-0000-0000-0000-00000000b242',
    '10000000-0000-0000-0000-00000000b241'
  ),
  'unblocked pair is eligible in reverse order'
);
SET LOCAL ROLE service_role;

-- A block that predates a match must be visible to both helper directions and
-- to the existing parent guard.  This is the sequential form of the
-- block-first race assertion; the two-session wait/commit case remains a
-- separately approved runtime probe.
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-00000000b241', '10000000-0000-0000-0000-00000000b242');
RESET ROLE;
SELECT pg_temp.assert_false(
  wingward_private.lock_and_check_mutual_eligibility(
    '10000000-0000-0000-0000-00000000b241',
    '10000000-0000-0000-0000-00000000b242'
  ),
  'blocker-first pair is rejected after the post-lock block check'
);
SELECT pg_temp.assert_false(
  wingward_private.lock_and_check_mutual_eligibility(
    '10000000-0000-0000-0000-00000000b242',
    '10000000-0000-0000-0000-00000000b241'
  ),
  'blocked-first pair is rejected after the post-lock block check'
);
SET LOCAL ROLE service_role;
SELECT pg_temp.expect_rejected(
  $$INSERT INTO public.matches (id, user_a_id, user_b_id, status)
    VALUES ('20000000-0000-0000-0000-00000000b242',
            '10000000-0000-0000-0000-00000000b241',
            '10000000-0000-0000-0000-00000000b242',
            'direct_chat_active')$$,
  'match participants fail matching eligibility'
);

-- ON CONFLICT exercises both triggers on the upsert path.  It is an exact
-- participant no-op and remains valid for idempotent block requests.
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-00000000b241', '10000000-0000-0000-0000-00000000b242')
ON CONFLICT (blocker_id, blocked_id) DO UPDATE
      SET blocker_id = EXCLUDED.blocker_id,
          blocked_id = EXCLUDED.blocked_id;
SELECT pg_temp.assert_true(
  (SELECT count(*) = 1
     FROM public.blocks
    WHERE blocker_id = '10000000-0000-0000-0000-00000000b241'
      AND blocked_id = '10000000-0000-0000-0000-00000000b242'),
  'same-pair upsert remains idempotent'
);
SELECT pg_temp.expect_rejected(
  $$UPDATE public.blocks
       SET blocker_id = '10000000-0000-0000-0000-00000000b243'
     WHERE blocker_id = '10000000-0000-0000-0000-00000000b241'
       AND blocked_id = '10000000-0000-0000-0000-00000000b242'$$,
  'block participants are immutable'
);
UPDATE public.blocks
   SET created_at = created_at
 WHERE blocker_id = '10000000-0000-0000-0000-00000000b241'
   AND blocked_id = '10000000-0000-0000-0000-00000000b242';

-- Build one complete, eligible output chain before blocking C/D.  Each row is
-- later used to prove that the helper's false result rejects new content or
-- consent while preserving its table-specific cleanup allowlist.
INSERT INTO public.matches (id, user_a_id, user_b_id, status)
VALUES ('20000000-0000-0000-0000-00000000b241',
        '10000000-0000-0000-0000-00000000b243',
        '10000000-0000-0000-0000-00000000b244',
        'direct_chat_active');
INSERT INTO public.chat_requests
  (id, match_id, requester_id, responder_id, status, expires_at)
VALUES ('30000000-0000-0000-0000-00000000b241',
        '20000000-0000-0000-0000-00000000b241',
        '10000000-0000-0000-0000-00000000b243',
        '10000000-0000-0000-0000-00000000b244',
        'pending', now() + pg_catalog.interval '2 days');
INSERT INTO public.direct_chat_rooms (id, match_id, status)
VALUES ('40000000-0000-0000-0000-00000000b241',
        '20000000-0000-0000-0000-00000000b241',
        'active');
INSERT INTO public.direct_chat_messages
  (id, room_id, sender_id, content, is_read)
VALUES ('41000000-0000-0000-0000-00000000b241',
        '40000000-0000-0000-0000-00000000b241',
        '10000000-0000-0000-0000-00000000b243',
        'synthetic unread message', false);
INSERT INTO public.fox_conversations
  (id, match_id, purpose, status, total_rounds)
VALUES ('50000000-0000-0000-0000-00000000b241',
        '20000000-0000-0000-0000-00000000b241',
        'compatibility', 'in_progress', 5);
INSERT INTO public.fox_conversation_messages
  (id, conversation_id, speaker_user_id, content, round_number)
VALUES ('60000000-0000-0000-0000-00000000b241',
        '50000000-0000-0000-0000-00000000b241',
        '10000000-0000-0000-0000-00000000b243',
        'synthetic fox message', 1);
INSERT INTO public.partner_fox_chats
  (id, match_id, user_id, partner_user_id)
VALUES ('70000000-0000-0000-0000-00000000b241',
        '20000000-0000-0000-0000-00000000b241',
        '10000000-0000-0000-0000-00000000b243',
        '10000000-0000-0000-0000-00000000b244');
INSERT INTO public.partner_fox_messages
  (id, chat_id, role, content)
VALUES ('71000000-0000-0000-0000-00000000b241',
        '70000000-0000-0000-0000-00000000b241',
        'user', 'synthetic partner fox message');
INSERT INTO public.interaction_dna_scores
  (id, match_id, feature_id, feature_name, raw_score, normalized_score, confidence, evidence, source_phase)
VALUES ('90000000-0000-0000-0000-00000000b241',
        '20000000-0000-0000-0000-00000000b241',
        1, 'communication', 0.500, 0.500, 0.500, '{}'::jsonb, 'fox_conversation');
INSERT INTO public.meetups
  (id, match_id, initiator_id, status, area, intent_expires_at)
VALUES ('a0000000-0000-0000-0000-00000000b241',
        '20000000-0000-0000-0000-00000000b241',
        '10000000-0000-0000-0000-00000000b243',
        'intent_pending', 'synthetic', now() + pg_catalog.interval '2 days');
INSERT INTO public.meetup_proposals
  (id, meetup_id, attempt_number, candidates)
VALUES ('b0000000-0000-0000-0000-00000000b241',
        'a0000000-0000-0000-0000-00000000b241',
        1, '[{},{},{}]'::jsonb);
INSERT INTO public.meetup_proposal_responses
  (id, proposal_id, user_id, selected_candidate_indexes, response)
VALUES ('c0000000-0000-0000-0000-00000000b241',
        'b0000000-0000-0000-0000-00000000b241',
        '10000000-0000-0000-0000-00000000b243',
        ARRAY[0], 'yes');

INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-00000000b243', '10000000-0000-0000-0000-00000000b244');
RESET ROLE;
SELECT pg_temp.assert_false(
  wingward_private.lock_and_check_mutual_eligibility(
    '10000000-0000-0000-0000-00000000b243',
    '10000000-0000-0000-0000-00000000b244'
  ),
  'blocked output pair is rejected in blocker order'
);
SELECT pg_temp.assert_false(
  wingward_private.lock_and_check_mutual_eligibility(
    '10000000-0000-0000-0000-00000000b244',
    '10000000-0000-0000-0000-00000000b243'
  ),
  'blocked output pair is rejected in reverse order'
);
SET LOCAL ROLE service_role;

-- Parent match: only the existing terminal failure cleanup remains allowed.
SELECT pg_temp.expect_rejected(
  $$UPDATE public.matches SET final_score = 0.900
      WHERE id = '20000000-0000-0000-0000-00000000b241'$$,
  'match participants fail matching eligibility'
);
UPDATE public.matches
   SET status = 'chat_request_declined', updated_at = now()
 WHERE id = '20000000-0000-0000-0000-00000000b241';

-- Chat request: decline/expiry bookkeeping survives, but the deadline cannot
-- be moved after block revocation.
SELECT pg_temp.expect_rejected(
  $$UPDATE public.chat_requests SET expires_at = now() + pg_catalog.interval '9 days'
      WHERE id = '30000000-0000-0000-0000-00000000b241'$$,
  'chat write is not eligible'
);
UPDATE public.chat_requests
   SET status = 'declined', responded_at = now()
 WHERE id = '30000000-0000-0000-0000-00000000b241';

-- Message read receipt is the authorized content-free cleanup; a content
-- mutation is rejected.  Perform it before closing the room because the
-- earlier active-room trigger intentionally remains authoritative.
SELECT pg_temp.expect_rejected(
  $$UPDATE public.direct_chat_messages SET content = 'forged after block'
      WHERE id = '41000000-0000-0000-0000-00000000b241'$$,
  'chat write is not eligible'
);
UPDATE public.direct_chat_messages
   SET is_read = true
 WHERE id = '41000000-0000-0000-0000-00000000b241';
UPDATE public.direct_chat_rooms
   SET status = 'closed'
 WHERE id = '40000000-0000-0000-0000-00000000b241';
SELECT pg_temp.expect_rejected(
  $$UPDATE public.direct_chat_rooms SET status = 'active'
      WHERE id = '40000000-0000-0000-0000-00000000b241'$$,
  'chat write is not eligible'
);

-- Fox child branches: token accounting and failure cleanup stay narrow;
-- content, lineage and new rows remain rejected.
SELECT pg_temp.expect_rejected(
  $$UPDATE public.fox_conversations SET current_round = 2
      WHERE id = '50000000-0000-0000-0000-00000000b241'$$,
  'fox conversation write is not eligible'
);
UPDATE public.fox_conversations
   SET cache_hit_tokens = 1, input_tokens = 2, output_tokens = 3
 WHERE id = '50000000-0000-0000-0000-00000000b241';
UPDATE public.fox_conversations
   SET status = 'failed'
 WHERE id = '50000000-0000-0000-0000-00000000b241';
SELECT pg_temp.expect_rejected(
  $$UPDATE public.fox_conversation_messages SET content = 'forged after block'
      WHERE id = '60000000-0000-0000-0000-00000000b241'$$,
  'fox conversation message write is not eligible'
);
UPDATE public.fox_conversation_messages
   SET content = content
 WHERE id = '60000000-0000-0000-0000-00000000b241';
SELECT pg_temp.expect_rejected(
  $$UPDATE public.partner_fox_chats SET created_at = created_at + pg_catalog.interval '1 second'
      WHERE id = '70000000-0000-0000-0000-00000000b241'$$,
  'partner fox chat write is not eligible'
);
UPDATE public.partner_fox_chats
   SET created_at = created_at
 WHERE id = '70000000-0000-0000-0000-00000000b241';
SELECT pg_temp.expect_rejected(
  $$UPDATE public.partner_fox_messages SET content = 'forged after block'
      WHERE id = '71000000-0000-0000-0000-00000000b241'$$,
  'partner fox message write is not eligible'
);
UPDATE public.partner_fox_messages
   SET content = content
 WHERE id = '71000000-0000-0000-0000-00000000b241';
SELECT pg_temp.expect_rejected(
  $$UPDATE public.interaction_dna_scores SET normalized_score = 0.900
      WHERE id = '90000000-0000-0000-0000-00000000b241'$$,
  'interaction score write is not eligible'
);
UPDATE public.interaction_dna_scores
   SET normalized_score = normalized_score
 WHERE id = '90000000-0000-0000-0000-00000000b241';

-- Meetup child branches: cancellation is allowed without consent mutation;
-- proposals and responses keep exact no-op cleanup only.
SELECT pg_temp.expect_rejected(
  $$UPDATE public.meetups SET status = 'cancelled', intent_a_at = now()
      WHERE id = 'a0000000-0000-0000-0000-00000000b241'$$,
  'meetup write is not eligible'
);
UPDATE public.meetups
   SET status = 'cancelled', updated_at = now()
 WHERE id = 'a0000000-0000-0000-0000-00000000b241';
SELECT pg_temp.expect_rejected(
  $$UPDATE public.meetup_proposals SET rationale = 'forged after block'
      WHERE id = 'b0000000-0000-0000-0000-00000000b241'$$,
  'meetup proposal write is not eligible'
);
UPDATE public.meetup_proposals
   SET rationale = rationale
 WHERE id = 'b0000000-0000-0000-0000-00000000b241';
SELECT pg_temp.expect_rejected(
  $$UPDATE public.meetup_proposal_responses SET response = 'forged after block'
      WHERE id = 'c0000000-0000-0000-0000-00000000b241'$$,
  'meetup proposal response write is not eligible'
);
UPDATE public.meetup_proposal_responses
   SET response = response
 WHERE id = 'c0000000-0000-0000-0000-00000000b241';

-- The public INSERT policy and the private actor check are both preserved.
-- Trigger execution precedes the policy's WITH CHECK, so the forged blocker
-- receives the same generic check_violation before any profile lock is taken.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000b243', true);
SET LOCAL ROLE authenticated;
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-00000000b243', '10000000-0000-0000-0000-00000000b242');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000b242', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_role_rejected(
  $$INSERT INTO public.blocks (blocker_id, blocked_id)
      VALUES ('10000000-0000-0000-0000-00000000b243',
              '10000000-0000-0000-0000-00000000b241')$$,
  '23514',
  'block write is not eligible'
);
RESET ROLE;
SELECT pg_temp.assert_true(
  NOT EXISTS (
    SELECT 1 FROM public.blocks
     WHERE blocker_id = '10000000-0000-0000-0000-00000000b243'
       AND blocked_id = '10000000-0000-0000-0000-00000000b241'
  ),
  'forged authenticated blocker left no row'
);

-- DELETE is deliberately unlocked and removes only the restriction.  The
-- resulting helper value documents the intended unblock semantics.
SET LOCAL ROLE service_role;
DELETE FROM public.blocks
 WHERE blocker_id = '10000000-0000-0000-0000-00000000b243'
   AND blocked_id = '10000000-0000-0000-0000-00000000b244';
RESET ROLE;
SELECT pg_temp.assert_true(
  wingward_private.lock_and_check_mutual_eligibility(
    '10000000-0000-0000-0000-00000000b243',
    '10000000-0000-0000-0000-00000000b244'
  ),
  'unblocked pair becomes eligible after unlocked DELETE'
);

SELECT 'PASS SQL24: block lock serialization, actor-before-lock, immutable participants, post-lock nondisclosure and cleanup allowlists';
ROLLBACK;
