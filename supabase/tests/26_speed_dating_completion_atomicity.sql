-- SQL26 speed-dating completion acceptance fixture.
--
-- Run with psql -v ON_ERROR_STOP=1 after all migrations. The fixture is
-- transactional and rolls back. It exercises the privileged RPC directly so
-- route mocks cannot stand in for database atomicity: malformed payloads,
-- no-body incremental completion, replay/conflict, completed-row immutability,
-- rollback when a message insert fails, and cross-owner isolation. The lock-order assertions cover
-- the concurrent-completion contract; a two-session interleaving still needs
-- to be run by the local runtime harness because this script has one session.

BEGIN;
SET LOCAL statement_timeout = '15s';

DO $$
DECLARE
  v_oid oid;
  v_definition text;
BEGIN
  v_oid := to_regprocedure('public.complete_speed_dating_session(uuid,uuid,jsonb)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL26a: completion RPC is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_proc AS proc
     WHERE proc.oid = v_oid
       AND proc.prosecdef IS TRUE
       AND proc.proconfig @> ARRAY['search_path=""']::text[]
  ) THEN
    RAISE EXCEPTION 'FAIL SQL26a: completion RPC is not SECURITY DEFINER with empty search_path';
  END IF;

  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL26a: completion RPC grants are not service_role-only';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(v_oid) INTO v_definition;
  IF pg_catalog.strpos(v_definition, 'FROM public.user_profiles') < 1
     OR pg_catalog.strpos(v_definition, 'FROM public.speed_dating_sessions AS session_row')
        <= pg_catalog.strpos(v_definition, 'FROM public.user_profiles')
     OR v_definition NOT LIKE '%ORDER BY owner_session.id%'
     OR v_definition NOT LIKE '%FOR UPDATE%' THEN
    RAISE EXCEPTION 'FAIL SQL26b: completion RPC does not take the owner-first stable lock order';
  END IF;
END $$;

INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-00000000c261', 'wingward-test-sql26@example.invalid');

UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-00000000c261',
       nickname = 'SQL26 completion fixture'
 WHERE auth_user_id = '00000000-0000-0000-0000-00000000c261';

INSERT INTO public.personas (id, user_id, persona_type, name, compiled_document)
VALUES (
  '11000000-0000-0000-0000-00000000c261',
  '10000000-0000-0000-0000-00000000c261',
  'virtual_similar',
  'SQL26 Persona',
  'SQL26 persona fixture'
);

INSERT INTO public.speed_dating_sessions (id, user_id, persona_id, status, message_count, completed_at)
VALUES
  ('20000000-0000-0000-0000-00000000c261', '10000000-0000-0000-0000-00000000c261', '11000000-0000-0000-0000-00000000c261', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c262', '10000000-0000-0000-0000-00000000c261', '11000000-0000-0000-0000-00000000c261', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c263', '10000000-0000-0000-0000-00000000c261', '11000000-0000-0000-0000-00000000c261', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c264', '10000000-0000-0000-0000-00000000c261', '11000000-0000-0000-0000-00000000c261', 'completed', 1, '2026-09-01T00:00:00Z');

INSERT INTO public.speed_dating_messages (id, session_id, role, content, created_at)
VALUES ('21000000-0000-0000-0000-00000000c264', '20000000-0000-0000-0000-00000000c264', 'user', 'legacy saved body', '2026-09-01T00:00:01Z');

-- A second real owner/session makes the privileged ownership boundary
-- observable for active and completed sessions. The completed transcript also
-- catches a removed SELECT owner filter before the later UPDATE owner guard.
INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-00000000d261', 'wingward-test-sql26-victim@example.invalid');
UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-00000000d261', nickname = 'SQL26 other owner'
 WHERE auth_user_id = '00000000-0000-0000-0000-00000000d261';
INSERT INTO public.personas (id, user_id, persona_type, name, compiled_document)
VALUES ('11000000-0000-0000-0000-00000000d261', '10000000-0000-0000-0000-00000000d261',
        'virtual_similar', 'SQL26 other persona', 'SQL26 synthetic other persona');
INSERT INTO public.speed_dating_sessions (id, user_id, persona_id, status, message_count, completed_at)
VALUES ('20000000-0000-0000-0000-00000000d261', '10000000-0000-0000-0000-00000000d261',
        '11000000-0000-0000-0000-00000000d261', 'active', 1, NULL),
       ('20000000-0000-0000-0000-00000000d262', '10000000-0000-0000-0000-00000000d261',
        '11000000-0000-0000-0000-00000000d261', 'completed', 1, '2026-09-01T00:00:00Z');
INSERT INTO public.speed_dating_messages (id, session_id, role, content, created_at)
VALUES ('21000000-0000-0000-0000-00000000d261', '20000000-0000-0000-0000-00000000d261',
        'user', 'SQL26 synthetic other transcript', '2026-09-01T00:00:01Z'),
       ('21000000-0000-0000-0000-00000000d262', '20000000-0000-0000-0000-00000000d262',
        'user', 'SQL26 synthetic completed transcript', '2026-09-01T00:00:01Z');

-- Install the rollback probe while the fixture still runs as the database
-- owner. The trigger is inert until the inner test block sets its private
-- transaction-local flag, so all ordinary RPC calls continue normally.
CREATE OR REPLACE FUNCTION public.sql26_abort_speed_dating_message()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF pg_catalog.current_setting('sql26.fail', true) = 'on' THEN
    RAISE EXCEPTION 'sql26 injected message failure';
  END IF;
  RETURN NEW;
END;
$fn$;
CREATE TRIGGER sql26_abort_speed_dating_message
  BEFORE INSERT ON public.speed_dating_messages
  FOR EACH ROW EXECUTE FUNCTION public.sql26_abort_speed_dating_message();

SET LOCAL role = 'service_role';

DO $$
DECLARE
  v_row record;
  v_failed boolean;
  v_message_count integer;
  v_completed_at timestamptz;
  v_other_session jsonb;
  v_profiles jsonb;
  v_other_messages jsonb;
  v_other_id uuid;
BEGIN
  SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) INTO v_other_session FROM public.speed_dating_sessions s
   WHERE user_id = '10000000-0000-0000-0000-00000000d261';
  SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) INTO v_profiles FROM public.user_profiles p
   WHERE id IN ('10000000-0000-0000-0000-00000000c261', '10000000-0000-0000-0000-00000000d261');
  SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) INTO v_other_messages FROM public.speed_dating_messages m
   WHERE session_id IN ('20000000-0000-0000-0000-00000000d261', '20000000-0000-0000-0000-00000000d262');
  FOREACH v_other_id IN ARRAY ARRAY['20000000-0000-0000-0000-00000000d262'::uuid,
                                   '20000000-0000-0000-0000-00000000d261'::uuid] LOOP
    SELECT * INTO v_row FROM public.complete_speed_dating_session(
      v_other_id, '10000000-0000-0000-0000-00000000c261', NULL::jsonb);
    IF v_row.outcome IS DISTINCT FROM 'not_found'
       OR v_row.status IS NOT NULL OR v_row.message_count IS NOT NULL
       OR v_row.all_sessions_completed IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL SQL26 owner: another owner session returned completion data';
    END IF;
  END LOOP;
  IF (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id) FROM public.speed_dating_sessions s
       WHERE user_id = '10000000-0000-0000-0000-00000000d261') IS DISTINCT FROM v_other_session
     OR (SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM public.user_profiles p
          WHERE id IN ('10000000-0000-0000-0000-00000000c261', '10000000-0000-0000-0000-00000000d261')) IS DISTINCT FROM v_profiles
     OR (SELECT jsonb_agg(to_jsonb(m) ORDER BY m.id) FROM public.speed_dating_messages m
          WHERE session_id IN ('20000000-0000-0000-0000-00000000d261', '20000000-0000-0000-0000-00000000d262')) IS DISTINCT FROM v_other_messages THEN
    RAISE EXCEPTION 'FAIL SQL26 owner: unowned completion changed session, profiles or messages';
  END IF;

  -- Invalid JSON shapes are rejected before any session can be certified.
  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c261',
      '10000000-0000-0000-0000-00000000c261',
      '{}'::jsonb
    );
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL SQL26c: non-array transcript was accepted';
  END IF;

  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c261',
      '10000000-0000-0000-0000-00000000c261',
      '[{}]'::jsonb
    );
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL SQL26c: missing transcript fields were accepted';
  END IF;

  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c261',
      '10000000-0000-0000-0000-00000000c261',
      '[]'::jsonb
    );
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL SQL26c: empty submitted transcript was accepted';
  END IF;

  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c261',
      '10000000-0000-0000-0000-00000000c261',
      pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('source', 'user', 'message', 'x')
      )
    );
  IF v_row.outcome IS DISTINCT FROM 'stored'
     OR v_row.status IS DISTINCT FROM 'completed'
     OR v_row.message_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL SQL26d: valid transcript was not atomically stored';
  END IF;

  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c261',
      '10000000-0000-0000-0000-00000000c261',
      pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('source', 'user', 'message', 'x')
      )
    );
  IF v_row.outcome IS DISTINCT FROM 'already_completed' THEN
    RAISE EXCEPTION 'FAIL SQL26e: same transcript replay was not idempotent';
  END IF;

  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c261',
      '10000000-0000-0000-0000-00000000c261',
      pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('source', 'user', 'message', 'different retry')
      )
    );
  IF v_row.outcome IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'FAIL SQL26f: different transcript replay was accepted';
  END IF;

  SELECT count(*)::integer INTO v_message_count
    FROM public.speed_dating_messages
   WHERE session_id = '20000000-0000-0000-0000-00000000c261';
  IF v_message_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL SQL26f: replay duplicated transcript rows';
  END IF;

  -- A no-body web completion uses the already-saved incremental transcript.
  INSERT INTO public.speed_dating_messages (session_id, role, content)
  VALUES ('20000000-0000-0000-0000-00000000c263', 'persona', 'saved incremental body');
  UPDATE public.speed_dating_sessions SET message_count = 1
   WHERE id = '20000000-0000-0000-0000-00000000c263';
  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c263',
      '10000000-0000-0000-0000-00000000c261',
      NULL::jsonb
    );
  IF v_row.outcome IS DISTINCT FROM 'stored' THEN
    RAISE EXCEPTION 'FAIL SQL26g: saved incremental transcript was not completed';
  END IF;

  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c263',
      '10000000-0000-0000-0000-00000000c261',
      NULL::jsonb
    );
  IF v_row.outcome IS DISTINCT FROM 'already_completed' THEN
    RAISE EXCEPTION 'FAIL SQL26h: no-body replay was not idempotent';
  END IF;

  -- An omitted body cannot certify a session whose stored transcript is empty.
  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c262',
      '10000000-0000-0000-0000-00000000c261',
      NULL::jsonb
    );
  IF v_row.outcome IS DISTINCT FROM 'invalid_state' THEN
    RAISE EXCEPTION 'FAIL SQL26i: empty omitted transcript was accepted';
  END IF;

  -- Force a downstream message failure and verify the session remains active
  -- with no rows. This is the rollback property the old route did not have.
  PERFORM pg_catalog.set_config('sql26.fail', 'on', true);
  v_failed := false;
  BEGIN
    PERFORM *
      FROM public.complete_speed_dating_session(
        '20000000-0000-0000-0000-00000000c262',
        '10000000-0000-0000-0000-00000000c261',
        pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object('source', 'user', 'message', 'will roll back')
        )
      );
  EXCEPTION WHEN OTHERS THEN
    v_failed := true;
  END;
  PERFORM pg_catalog.set_config('sql26.fail', 'off', true);

  IF NOT v_failed THEN
    RAISE EXCEPTION 'FAIL SQL26j: injected downstream failure did not abort';
  END IF;
  SELECT s.message_count, s.completed_at INTO v_message_count, v_completed_at
    FROM public.speed_dating_sessions AS s
   WHERE s.id = '20000000-0000-0000-0000-00000000c262';
  SELECT count(*)::integer INTO v_message_count
    FROM public.speed_dating_messages
   WHERE session_id = '20000000-0000-0000-0000-00000000c262';
  IF EXISTS (
    SELECT 1 FROM public.speed_dating_sessions
     WHERE id = '20000000-0000-0000-0000-00000000c262'
       AND (status <> 'active' OR message_count <> 0 OR completed_at IS NOT NULL)
  ) OR v_message_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL SQL26j: downstream failure left a partial completion';
  END IF;

  -- A completed legacy row can be replayed only with its exact body and is not
  -- updated by the idempotent path.
  SELECT completed_at INTO v_completed_at
    FROM public.speed_dating_sessions
   WHERE id = '20000000-0000-0000-0000-00000000c264';
  SELECT * INTO v_row
    FROM public.complete_speed_dating_session(
      '20000000-0000-0000-0000-00000000c264',
      '10000000-0000-0000-0000-00000000c261',
      pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('source', 'user', 'message', 'legacy saved body')
      )
    );
  IF v_row.outcome IS DISTINCT FROM 'already_completed' THEN
    RAISE EXCEPTION 'FAIL SQL26k: completed legacy replay was not idempotent';
  END IF;
  IF (SELECT completed_at FROM public.speed_dating_sessions WHERE id = '20000000-0000-0000-0000-00000000c264') IS DISTINCT FROM v_completed_at THEN
    RAISE EXCEPTION 'FAIL SQL26k: completed legacy row was mutated';
  END IF;
END $$;

ROLLBACK;
