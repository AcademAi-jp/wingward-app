-- SQL33 Chat meetup session acceptance test.
-- Current time-only contract. Run after all current migrations, including 20260930145624.
-- All writes are rolled back; the test uses no real calendar, location, or provider data.

BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL TIME ZONE 'UTC';
CREATE TEMP TABLE sql33_disabled_action_keys(idempotency_key uuid PRIMARY KEY);
GRANT INSERT, SELECT ON pg_temp.sql33_disabled_action_keys TO service_role;

-- The caller-visible contract is a narrow, service-role-only RPC boundary.
DO $$
DECLARE
  v_function oid;
  v_function_name text;
  v_table regclass;
BEGIN
  FOREACH v_function_name IN ARRAY ARRAY[
    'public.apply_chat_meetup_action(uuid,uuid,integer,integer,uuid,text,jsonb)',
    'public.publish_chat_meetup_times(uuid,uuid,integer,integer,integer,jsonb,text)',
    'public.publish_chat_meetup_cafes(uuid,uuid,integer,integer,integer,jsonb,text)',
    'public.expire_chat_meetup_session(uuid,uuid)',
    'public.prune_chat_meetup_private_inputs()'
  ] LOOP
    v_function := pg_catalog.to_regprocedure(v_function_name)::oid;
    IF v_function IS NULL THEN
      RAISE EXCEPTION 'FAIL SQL33a: expected chat meetup RPC is missing';
    END IF;
    IF NOT COALESCE((
         SELECT proc.prosecdef
           FROM pg_catalog.pg_proc AS proc
          WHERE proc.oid = v_function
       ), false)
       OR NOT COALESCE((
         SELECT proc.proconfig @> ARRAY['search_path=""']::text[]
           FROM pg_catalog.pg_proc AS proc
          WHERE proc.oid = v_function
       ), false)
       OR has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('authenticated', v_function, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL SQL33b: chat meetup RPC must be SECURITY DEFINER with empty search_path and service_role-only EXECUTE';
    END IF;
  END LOOP;

  FOREACH v_table IN ARRAY ARRAY[
    'public.chat_meetup_sessions'::regclass,
    'public.chat_meetup_events'::regclass,
    'public.chat_meetup_availability'::regclass,
    'public.chat_meetup_locations'::regclass,
    'public.chat_meetup_private_decisions'::regclass,
    'public.chat_meetup_operations'::regclass
  ] LOOP
    IF NOT (SELECT relation.relrowsecurity
              FROM pg_catalog.pg_class AS relation
             WHERE relation.oid = v_table)
       OR has_table_privilege('anon', v_table, 'SELECT')
       OR has_table_privilege('authenticated', v_table, 'SELECT') THEN
      RAISE EXCEPTION 'FAIL SQL33c: private meetup tables must have RLS and no direct client SELECT';
    END IF;
  END LOOP;

  IF NOT has_table_privilege('service_role', 'public.chat_meetup_sessions', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.chat_meetup_events', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.chat_meetup_availability', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.chat_meetup_locations', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.chat_meetup_private_decisions', 'SELECT')
     OR has_table_privilege('service_role', 'public.chat_meetup_operations', 'SELECT')
     OR has_table_privilege('service_role', 'public.chat_meetup_operations', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL SQL33d: provider reads and replay-ledger access grants are too broad or incomplete';
  END IF;
END $$;

-- Synthetic actors: main pair A/B, outsider C, blocked pair D/E,
-- unverified-identity pair F/G, and completion pair H/I.
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-00000000c331', 'sql33-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000c332', 'sql33-b@example.invalid'),
  ('00000000-0000-0000-0000-00000000c333', 'sql33-outsider@example.invalid'),
  ('00000000-0000-0000-0000-00000000c334', 'sql33-blocked-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000c335', 'sql33-blocked-b@example.invalid'),
  ('00000000-0000-0000-0000-00000000c336', 'sql33-identity-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000c337', 'sql33-identity-b@example.invalid'),
  ('00000000-0000-0000-0000-00000000c338', 'sql33-complete-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000c339', 'sql33-complete-b@example.invalid');

WITH fixtures(auth_user_id, profile_id, nickname) AS (
  VALUES
    ('00000000-0000-0000-0000-00000000c331'::uuid, '10000000-0000-0000-0000-00000000c331'::uuid, 'SQL33 A'),
    ('00000000-0000-0000-0000-00000000c332'::uuid, '10000000-0000-0000-0000-00000000c332'::uuid, 'SQL33 B'),
    ('00000000-0000-0000-0000-00000000c333'::uuid, '10000000-0000-0000-0000-00000000c333'::uuid, 'SQL33 Outsider'),
    ('00000000-0000-0000-0000-00000000c334'::uuid, '10000000-0000-0000-0000-00000000c334'::uuid, 'SQL33 Blocked A'),
    ('00000000-0000-0000-0000-00000000c335'::uuid, '10000000-0000-0000-0000-00000000c335'::uuid, 'SQL33 Blocked B'),
    ('00000000-0000-0000-0000-00000000c336'::uuid, '10000000-0000-0000-0000-00000000c336'::uuid, 'SQL33 Identity A'),
    ('00000000-0000-0000-0000-00000000c337'::uuid, '10000000-0000-0000-0000-00000000c337'::uuid, 'SQL33 Identity B'),
    ('00000000-0000-0000-0000-00000000c338'::uuid, '10000000-0000-0000-0000-00000000c338'::uuid, 'SQL33 Complete A'),
    ('00000000-0000-0000-0000-00000000c339'::uuid, '10000000-0000-0000-0000-00000000c339'::uuid, 'SQL33 Complete B')
)
UPDATE public.user_profiles AS profile_row
   SET id = fixture.profile_id,
       nickname = fixture.nickname,
       birth_date = DATE '1990-01-01',
       age_verified_at = pg_catalog.now(),
       age_verification_method = 'self_declared',
       timezone = 'UTC',
       identity_verification_status = 'verified',
       identity_verified_at = pg_catalog.now(),
       dating_market = 'JP',
       gender_identity = 'woman',
       preferred_genders = ARRAY['woman']::text[],
       preference_mode = 'selected',
       onboarding_settings_completed_at = pg_catalog.now()
  FROM fixtures AS fixture
 WHERE profile_row.auth_user_id = fixture.auth_user_id;

UPDATE public.user_profiles
   SET identity_verification_status = 'none',
       identity_verified_at = NULL
 WHERE id IN (
   '10000000-0000-0000-0000-00000000c336',
   '10000000-0000-0000-0000-00000000c337'
 );

INSERT INTO public.matches (id, user_a_id, user_b_id, status) VALUES
  ('20000000-0000-0000-0000-00000000c331', '10000000-0000-0000-0000-00000000c331', '10000000-0000-0000-0000-00000000c332', 'direct_chat_active'),
  ('20000000-0000-0000-0000-00000000c334', '10000000-0000-0000-0000-00000000c334', '10000000-0000-0000-0000-00000000c335', 'direct_chat_active'),
  ('20000000-0000-0000-0000-00000000c336', '10000000-0000-0000-0000-00000000c336', '10000000-0000-0000-0000-00000000c337', 'direct_chat_active'),
  ('20000000-0000-0000-0000-00000000c338', '10000000-0000-0000-0000-00000000c338', '10000000-0000-0000-0000-00000000c339', 'direct_chat_active');

INSERT INTO public.direct_chat_rooms (id, match_id, status) VALUES
  ('40000000-0000-0000-0000-00000000c331', '20000000-0000-0000-0000-00000000c331', 'active'),
  ('40000000-0000-0000-0000-00000000c334', '20000000-0000-0000-0000-00000000c334', 'active'),
  ('40000000-0000-0000-0000-00000000c336', '20000000-0000-0000-0000-00000000c336', 'active'),
  ('40000000-0000-0000-0000-00000000c338', '20000000-0000-0000-0000-00000000c338', 'active');



-- A later block must deny the already-created pair without consuming a replay key.
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-00000000c334', '10000000-0000-0000-0000-00000000c335');

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_meetup_id uuid;
  v_count integer;
BEGIN
  -- One participant's intent is private: it changes only that participant's
  -- private revision and the legacy quota/intent anchor.
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    0, 0, '80000000-0000-0000-0000-00000000c331',
    pg_catalog.repeat('a', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.meetup_id IS NOT NULL
     OR v_row.status IS NOT NULL
     OR v_row.revision IS DISTINCT FROM 0
     OR v_row.own_revision IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL SQL33e: one-sided intent did not stay caller-private at shared revision zero';
  END IF;
  SELECT count(*) INTO v_count
    FROM public.chat_meetup_sessions
   WHERE room_id = '40000000-0000-0000-0000-00000000c331';
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL33e: one-sided intent created a shared session'; END IF;
  SELECT count(*) INTO v_count
    FROM public.chat_meetup_events AS event_row
    JOIN public.meetups AS meetup_row ON meetup_row.id = event_row.meetup_id
   WHERE meetup_row.match_id = '20000000-0000-0000-0000-00000000c331';
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL33e: one-sided intent created a shared event'; END IF;
  SELECT count(*) INTO v_count
    FROM public.meetups
   WHERE match_id = '20000000-0000-0000-0000-00000000c331'
     AND status = 'intent_pending'
     AND initiator_id = '10000000-0000-0000-0000-00000000c331';
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL33e: one-sided intent did not reserve one legacy intent anchor'; END IF;

  -- Same owner/key/digest safely replays. A changed digest conflicts before
  -- stale-revision checks and never returns the prior private payload.
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    0, 0, '80000000-0000-0000-0000-00000000c331',
    pg_catalog.repeat('a', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'replayed'
     OR v_row.meetup_id IS NOT NULL
     OR v_row.revision IS DISTINCT FROM 0
     OR v_row.own_revision IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL SQL33f: same-key owner retry did not replay safely';
  END IF;
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    0, 0, '80000000-0000-0000-0000-00000000c331',
    pg_catalog.repeat('b', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'idempotency_conflict'
     OR v_row.meetup_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL33f: changed same-owner replay digest was accepted';
  END IF;

  -- A profile outside the match receives a nondisclosing result and cannot
  -- create a private decision, session, event, or legacy meetup.
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c333',
    0, 0, '80000000-0000-0000-0000-00000000c333',
    pg_catalog.repeat('c', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found'
     OR v_row.meetup_id IS NOT NULL
     OR v_row.status IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL33g: outsider received meetup state';
  END IF;
  SELECT count(*) INTO v_count
    FROM public.meetups
   WHERE match_id = '20000000-0000-0000-0000-00000000c331';
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL33g: outsider changed legacy meetup rows'; END IF;

  -- Existing match, then a block: the write must still fail closed before it
  -- creates a meetup/session or stores an idempotency receipt.
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c334',
    '10000000-0000-0000-0000-00000000c334',
    0, 0, '80000000-0000-0000-0000-00000000c334',
    pg_catalog.repeat('d', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found'
     OR v_row.meetup_id IS NOT NULL
     OR v_row.status IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL33h: blocked pair could still start a meetup plan';
  END IF;
  SELECT count(*) INTO v_count
    FROM public.meetups
   WHERE match_id = '20000000-0000-0000-0000-00000000c334';
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL33h: blocked pair created a legacy meetup'; END IF;

  -- Identity is an explicit later-stage gate. The pending pair may record
  -- intent, but cannot submit scheduling input or advance its private revision.
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c336',
    '10000000-0000-0000-0000-00000000c336',
    0, 0, '80000000-0000-0000-0000-00000000c336',
    pg_catalog.repeat('e', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok' OR v_row.own_revision IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL SQL33i: identity fixture did not accept the initial private intent';
  END IF;
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c336',
    '10000000-0000-0000-0000-00000000c337',
    0, 0, '80000000-0000-0000-0000-00000000c337',
    pg_catalog.repeat('f', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.status IS DISTINCT FROM 'awaiting_availability'
     OR v_row.revision IS DISTINCT FROM 1
     OR v_row.own_revision IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL SQL33i: mutual intent did not create the identity-gated session';
  END IF;
  v_meetup_id := v_row.meetup_id;
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c336',
    '10000000-0000-0000-0000-00000000c336',
    1, 1, '80000000-0000-0000-0000-00000000c33a',
    pg_catalog.repeat('1', 64),
    pg_catalog.jsonb_build_object(
      'type', 'availability.submit', 'source', 'manual',
      'window', pg_catalog.jsonb_build_object(
        'starts_at', pg_catalog.now() + pg_catalog.interval '1 day',
        'ends_at', pg_catalog.now() + pg_catalog.interval '2 days'
      ),
      'available', '[]'::jsonb
    )
  );
  IF v_row.outcome IS DISTINCT FROM 'identity_verification_required'
     OR v_row.meetup_id IS DISTINCT FROM v_meetup_id
     OR v_row.revision IS DISTINCT FROM 1
     OR v_row.own_revision IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL SQL33j: unverified identity advanced scheduling input';
  END IF;
  SELECT count(*) INTO v_count FROM public.chat_meetup_availability
   WHERE meetup_id = v_meetup_id;
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL33j: identity denial retained calendar input'; END IF;
END $$;
RESET ROLE;

DO $$
DECLARE
  v_count integer;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.chat_meetup_operations
     WHERE room_id IN ('40000000-0000-0000-0000-00000000c331',
                       '40000000-0000-0000-0000-00000000c334',
                       '40000000-0000-0000-0000-00000000c336')
       AND idempotency_key IN (
         '80000000-0000-0000-0000-00000000c333',
         '80000000-0000-0000-0000-00000000c334',
         '80000000-0000-0000-0000-00000000c33a'
       )
  ) THEN
    RAISE EXCEPTION 'FAIL SQL33k: denied requests consumed a replay receipt';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute AS attribute
     WHERE attribute.attrelid = 'public.chat_meetup_operations'::regclass
       AND attribute.attnum > 0
       AND NOT attribute.attisdropped
       AND attribute.attname IN ('request_json', 'action_json', 'payload')
  ) THEN
    RAISE EXCEPTION 'FAIL SQL33k: operation ledger stores raw request content';
  END IF;
  SELECT count(*) INTO v_count FROM public.chat_meetup_operations
   WHERE room_id = '40000000-0000-0000-0000-00000000c331'
     AND user_id = '10000000-0000-0000-0000-00000000c331'
     AND idempotency_key = '80000000-0000-0000-0000-00000000c331'
     AND request_digest = pg_catalog.repeat('a', 64);
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL33k: safe digest receipt was not stored exactly once'; END IF;
END $$;

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_meetup_id uuid;
  v_revision integer;
  v_a_revision integer;
  v_b_revision integer;
  v_count integer;
  v_now timestamptz := pg_catalog.now();
  v_ttl_checked_at timestamptz;
  v_window_start timestamptz;
  v_window_end timestamptz;
  v_meetup_start timestamptz;
  v_meetup_end timestamptz;
  v_open_start timestamptz;
  v_open_end timestamptz;
  v_verified_at timestamptz;
  v_time_candidates jsonb;
  v_partial_cafe jsonb;
  v_stale_cafe jsonb;
  v_full_cafe jsonb;
  v_meetup_start_text text;
  v_meetup_end_text text;
  v_open_start_text text;
  v_open_end_text text;
  v_verified_text text;
  v_events_before integer;
  v_session_before jsonb;
  v_meetup_before jsonb;
  v_decisions_before jsonb;
  v_locations_before jsonb;
  v_events_snapshot jsonb;
  v_disabled_action jsonb;
  v_disabled_key uuid;
  v_retry integer;
BEGIN
  -- The second participant's intent is the first shared transition.
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c332',
    0, 0, '80000000-0000-0000-0000-00000000c332',
    pg_catalog.repeat('2', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.meetup_id IS NULL
     OR v_row.status IS DISTINCT FROM 'awaiting_availability'
     OR v_row.revision IS DISTINCT FROM 1
     OR v_row.own_revision IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL SQL33l: mutual intent did not create the shared planning session';
  END IF;
  v_meetup_id := v_row.meetup_id;
  v_revision := v_row.revision;
  v_b_revision := v_row.own_revision;
  SELECT private_revision INTO v_a_revision
    FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c331'
     AND user_id = '10000000-0000-0000-0000-00000000c331';

  -- The caller can submit a manual free window; the peer can submit only a
  -- calendar busy interval. Neither one-sided input changes shared revision
  -- or adds an event.
  v_window_start := v_now + pg_catalog.interval '2 days';
  v_window_end := v_now + pg_catalog.interval '5 days';
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    v_revision, v_a_revision, '80000000-0000-0000-0000-00000000c341',
    pg_catalog.repeat('3', 64),
    pg_catalog.jsonb_build_object(
      'type', 'availability.submit', 'source', 'manual',
      'window', pg_catalog.jsonb_build_object('starts_at', v_window_start, 'ends_at', v_window_end),
      'available', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('starts_at', v_window_start, 'ends_at', v_window_end)
      )
    )
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.status IS DISTINCT FROM 'awaiting_availability'
     OR v_row.revision IS DISTINCT FROM v_revision
     OR v_row.own_revision IS DISTINCT FROM v_a_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33l: manual availability was not caller-private';
  END IF;
  v_a_revision := v_row.own_revision;

  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c332',
    v_revision, v_b_revision, '80000000-0000-0000-0000-00000000c342',
    pg_catalog.repeat('4', 64),
    pg_catalog.jsonb_build_object(
      'type', 'availability.submit', 'source', 'calendar',
      'window', pg_catalog.jsonb_build_object('starts_at', v_window_start, 'ends_at', v_window_end),
      'busy', '[]'::jsonb
    )
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.status IS DISTINCT FROM 'awaiting_availability'
     OR v_row.revision IS DISTINCT FROM v_revision
     OR v_row.own_revision IS DISTINCT FROM v_b_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33l: calendar availability was not caller-private';
  END IF;
  v_b_revision := v_row.own_revision;
  -- The current RPC uses clock_timestamp(), not transaction_timestamp().
  -- Check the same strict 30-minute upper bound against the live observation,
  -- rather than an earlier transaction start that predates the provider input.
  v_ttl_checked_at := pg_catalog.clock_timestamp();
  SELECT count(*) INTO v_count FROM public.chat_meetup_availability
   WHERE meetup_id = v_meetup_id
     AND expires_at > v_ttl_checked_at
     AND expires_at <= v_ttl_checked_at + pg_catalog.interval '30 minutes';
  IF v_count <> 2 THEN RAISE EXCEPTION 'FAIL SQL33l: private availability did not receive a short TTL'; END IF;
  SELECT count(*) INTO v_count FROM public.chat_meetup_events WHERE meetup_id = v_meetup_id;
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL SQL33l: one-sided availability changed the shared event timeline'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_meetup_availability
     WHERE meetup_id = v_meetup_id AND user_id = '10000000-0000-0000-0000-00000000c331'
       AND source = 'manual'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_meetup_availability
     WHERE meetup_id = v_meetup_id AND user_id = '10000000-0000-0000-0000-00000000c332'
       AND source = 'calendar'
  ) THEN
    RAISE EXCEPTION 'FAIL SQL33l: manual/calendar source distinction was lost';
  END IF;

  v_meetup_start := v_now + pg_catalog.interval '3 days';
  v_meetup_end := v_meetup_start + pg_catalog.interval '1 hour';
  v_meetup_start_text := pg_catalog.to_char(v_meetup_start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  v_meetup_end_text := pg_catalog.to_char(v_meetup_end AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  v_time_candidates := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id', '60000000-0000-0000-0000-00000000c331',
    'starts_at', v_meetup_start_text,
    'ends_at', v_meetup_end_text
  ));

  -- Publishing with either stale private revision is fenced. The negative
  -- control below uses both current revisions and succeeds.
  SELECT * INTO v_row FROM public.publish_chat_meetup_times(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    v_revision, v_a_revision - 1, v_b_revision, v_time_candidates, NULL
  );
  IF v_row.outcome IS DISTINCT FROM 'stale_private_input'
     OR v_row.revision IS DISTINCT FROM v_revision THEN
    RAISE EXCEPTION 'FAIL SQL33m: stale private calendar input crossed the publish fence';
  END IF;
  SELECT * INTO v_row FROM public.publish_chat_meetup_times(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    v_revision, v_a_revision, v_b_revision, v_time_candidates, NULL
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.meetup_id IS DISTINCT FROM v_meetup_id
     OR v_row.status IS DISTINCT FROM 'time_proposed'
     OR v_row.revision IS DISTINCT FROM v_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33m: valid private inputs did not publish a time candidate';
  END IF;
  v_revision := v_row.revision;
  SELECT count(*) INTO v_count FROM public.chat_meetup_availability WHERE meetup_id = v_meetup_id;
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL SQL33m: consumed private availability was retained'; END IF;

  -- A's approval is visible only to A. B choosing the same candidate creates
  -- the shared transition and its single system event.
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    v_revision, v_a_revision, '80000000-0000-0000-0000-00000000c343',
    pg_catalog.repeat('5', 64),
    '{"type":"time.approve","candidate_id":"60000000-0000-0000-0000-00000000c331"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.status IS DISTINCT FROM 'time_proposed'
     OR v_row.revision IS DISTINCT FROM v_revision
     OR v_row.own_revision IS DISTINCT FROM v_a_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33n: first time approval changed the shared state';
  END IF;
  v_a_revision := v_row.own_revision;
  SELECT count(*) INTO v_events_before FROM public.chat_meetup_events WHERE meetup_id = v_meetup_id;
  IF v_events_before <> 2
     OR NOT EXISTS (
       SELECT 1 FROM public.chat_meetup_private_decisions
        WHERE match_id = '20000000-0000-0000-0000-00000000c331'
          AND user_id = '10000000-0000-0000-0000-00000000c331'
          AND time_choice_id = '60000000-0000-0000-0000-00000000c331'
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_meetup_private_decisions
        WHERE match_id = '20000000-0000-0000-0000-00000000c331'
          AND user_id = '10000000-0000-0000-0000-00000000c332'
          AND time_choice_id IS NOT NULL
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_meetup_sessions
        WHERE meetup_id = v_meetup_id
          AND (time_choice_a IS NOT NULL OR time_choice_b IS NOT NULL)
     ) THEN
    RAISE EXCEPTION 'FAIL SQL33n: one-sided time choice leaked into the shared envelope';
  END IF;

  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c332',
    v_revision, v_b_revision, '80000000-0000-0000-0000-00000000c344',
    pg_catalog.repeat('6', 64),
    '{"type":"time.approve","candidate_id":"60000000-0000-0000-0000-00000000c331"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.status IS DISTINCT FROM 'confirmed'
     OR v_row.revision IS DISTINCT FROM v_revision + 1
     OR v_row.own_revision IS DISTINCT FROM v_b_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33o: matching time approvals did not confirm the current time-only contract';
  END IF;
  v_revision := v_row.revision;
  v_b_revision := v_row.own_revision;
  SELECT count(*) INTO v_count FROM public.chat_meetup_events WHERE meetup_id = v_meetup_id;
  IF v_count <> v_events_before + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33o: mutual time approval did not add exactly one event';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.chat_meetup_sessions AS session_row
     WHERE session_row.meetup_id = v_meetup_id
       AND session_row.status = 'confirmed'
       AND session_row.selected_time_candidate_id = v_time_candidates -> 0 ->> 'id'
       AND session_row.confirmed_starts_at = (v_time_candidates -> 0 ->> 'starts_at')::timestamptz
       AND session_row.confirmed_ends_at = (v_time_candidates -> 0 ->> 'ends_at')::timestamptz
       AND session_row.confirmed_timezone = 'UTC'
       AND session_row.expires_at IS NULL
       AND session_row.cafe_candidates = '[]'::jsonb
       AND session_row.cafe_choice_a IS NULL AND session_row.cafe_choice_b IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.meetups AS meetup_row
     WHERE meetup_row.id = v_meetup_id AND meetup_row.status = 'confirmed'
       AND meetup_row.confirmed_start_at = (v_time_candidates -> 0 ->> 'starts_at')::timestamptz
       AND meetup_row.confirmed_timezone = 'UTC'
       AND meetup_row.area IS NULL AND meetup_row.format IS NULL
       AND meetup_row.proposal_expires_at IS NULL
  ) OR EXISTS (
    SELECT 1 FROM public.chat_meetup_locations WHERE meetup_id = v_meetup_id
  ) OR EXISTS (
    SELECT 1 FROM public.chat_meetup_availability WHERE meetup_id = v_meetup_id
  ) OR NOT EXISTS (
    SELECT 1 FROM public.chat_meetup_events WHERE meetup_id = v_meetup_id
      AND revision = v_revision AND event_key = 'state:confirmed:' || v_revision::text
      AND kind = 'system'
  ) THEN
    RAISE EXCEPTION 'FAIL SQL33o-current: time-only confirmation changed interval, leaked location, or missed its exact shared event';
  END IF;

  -- Location/cafe actions are closed in the time-only contract. A valid owner
  -- cannot revive them with a well-formed payload or an identical retry key.
  SELECT to_jsonb(r) INTO v_session_before FROM public.chat_meetup_sessions r WHERE meetup_id = v_meetup_id;
  SELECT to_jsonb(r) INTO v_meetup_before FROM public.meetups r WHERE id = v_meetup_id;
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.user_id), '[]'::jsonb) INTO v_decisions_before
    FROM public.chat_meetup_private_decisions r WHERE match_id = '20000000-0000-0000-0000-00000000c331';
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.user_id), '[]'::jsonb) INTO v_locations_before
    FROM public.chat_meetup_locations r WHERE meetup_id = v_meetup_id;
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.event_key), '[]'::jsonb) INTO v_events_snapshot
    FROM public.chat_meetup_events r WHERE meetup_id = v_meetup_id;
  FOR v_disabled_action IN SELECT value FROM jsonb_array_elements('[
    {"type":"location.submit","location":{"kind":"station","name":"SQL33 Synthetic Station","walk_minutes":8}},
    {"type":"location.clear"}, {"type":"cafe.approve","candidate_id":"cafe-sql33"},
    {"type":"cafe.decline","candidate_id":"cafe-sql33"}]'::jsonb)
  LOOP
    v_disabled_key := gen_random_uuid();
    INSERT INTO pg_temp.sql33_disabled_action_keys VALUES (v_disabled_key);
    FOR v_retry IN 1..2 LOOP
      SELECT * INTO v_row FROM public.apply_chat_meetup_action(
        '40000000-0000-0000-0000-00000000c331', '10000000-0000-0000-0000-00000000c331',
        v_revision, v_a_revision, v_disabled_key, repeat('7', 64), v_disabled_action);
      IF v_row.outcome IS DISTINCT FROM 'invalid_input' OR v_row.meetup_id IS NOT NULL
         OR v_row.status IS NOT NULL OR v_row.revision IS DISTINCT FROM 0
         OR v_row.own_revision IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FAIL SQL33-disabled: current owner could enable a closed location/cafe action';
      END IF;
    END LOOP;
  END LOOP;
  IF (SELECT to_jsonb(r) FROM public.chat_meetup_sessions r WHERE meetup_id = v_meetup_id) IS DISTINCT FROM v_session_before
     OR (SELECT to_jsonb(r) FROM public.meetups r WHERE id = v_meetup_id) IS DISTINCT FROM v_meetup_before
     OR (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.user_id), '[]'::jsonb) FROM public.chat_meetup_private_decisions r WHERE match_id = '20000000-0000-0000-0000-00000000c331') IS DISTINCT FROM v_decisions_before
     OR (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.user_id), '[]'::jsonb) FROM public.chat_meetup_locations r WHERE meetup_id = v_meetup_id) IS DISTINCT FROM v_locations_before
     OR (SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.event_key), '[]'::jsonb) FROM public.chat_meetup_events r WHERE meetup_id = v_meetup_id) IS DISTINCT FROM v_events_snapshot THEN
    RAISE EXCEPTION 'FAIL SQL33-disabled: disabled action/retry changed state, revisions, consent, private choice, or event';
  END IF;
END $$;
RESET ROLE;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.chat_meetup_operations r JOIN pg_temp.sql33_disabled_action_keys k USING (idempotency_key)) THEN
    RAISE EXCEPTION 'FAIL SQL33-disabled: disabled action/retry consumed an idempotency receipt';
  END IF;
END $$;

-- Replan starts from the genuine current time-only confirmation above.
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_old_meetup_id uuid;
  v_new_meetup_id uuid;
  v_revision integer;
  v_a_revision integer;
  v_b_revision integer;
  v_count integer;
  v_events_before integer;
BEGIN
  SELECT meetup_id, revision INTO v_old_meetup_id, v_revision
    FROM public.chat_meetup_sessions
   WHERE room_id = '40000000-0000-0000-0000-00000000c331'
   ORDER BY created_at DESC LIMIT 1;
  SELECT private_revision INTO v_a_revision FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c331' AND user_id = '10000000-0000-0000-0000-00000000c331';
  SELECT private_revision INTO v_b_revision FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c331' AND user_id = '10000000-0000-0000-0000-00000000c332';
  SELECT count(*) INTO v_events_before FROM public.chat_meetup_events WHERE meetup_id = v_old_meetup_id;
  -- Replanning a future confirmed plan retires it and creates a clean new
  -- session with new private revisions and no carried decisions.
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    v_revision, v_a_revision, '80000000-0000-0000-0000-00000000c34b',
    pg_catalog.repeat('d', 64),
    '{"type":"replan"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.meetup_id IS NULL
     OR v_row.meetup_id = v_old_meetup_id
     OR v_row.status IS DISTINCT FROM 'awaiting_availability'
     OR v_row.revision IS DISTINCT FROM v_revision + 2
     OR v_row.own_revision IS DISTINCT FROM v_a_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33w: confirmed replan did not create a new clean session';
  END IF;
  v_new_meetup_id := v_row.meetup_id;
  v_revision := v_row.revision;
  v_a_revision := v_row.own_revision;
  SELECT private_revision INTO v_b_revision
    FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c331'
     AND user_id = '10000000-0000-0000-0000-00000000c332';
  SELECT count(*) INTO v_count FROM public.chat_meetup_sessions
   WHERE room_id = '40000000-0000-0000-0000-00000000c331'
     AND status NOT IN ('completed', 'cancelled', 'expired');
  IF v_count <> 1
     OR (SELECT status FROM public.chat_meetup_sessions WHERE meetup_id = v_old_meetup_id) <> 'cancelled'
     OR EXISTS (
       SELECT 1 FROM public.chat_meetup_private_decisions
        WHERE match_id = '20000000-0000-0000-0000-00000000c331'
          AND (time_choice_id IS NOT NULL OR cafe_choice_id IS NOT NULL OR completed_at IS NOT NULL)
     )
     OR (SELECT time_candidates FROM public.chat_meetup_sessions WHERE meetup_id = v_new_meetup_id) <> '[]'::jsonb
     OR (SELECT cafe_candidates FROM public.chat_meetup_sessions WHERE meetup_id = v_new_meetup_id) <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL SQL33w: replan retained old choices or provider candidates';
  END IF;
  IF (SELECT count(*) FROM public.chat_meetup_events WHERE meetup_id = v_old_meetup_id) <> v_events_before + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33w: replan did not record exactly one retirement event';
  END IF;

END $$;
RESET ROLE;

-- Make the new session deterministically newer than the retired session;
-- transaction_timestamp() is constant for this rollback test.
UPDATE public.chat_meetup_sessions
   SET created_at = pg_catalog.now() + pg_catalog.interval '1 second'
 WHERE room_id = '40000000-0000-0000-0000-00000000c331'
   AND status = 'awaiting_availability';

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_new_meetup_id uuid;
  v_revision integer;
  v_a_revision integer;
  v_count integer;
BEGIN
  SELECT meetup_id, revision INTO v_new_meetup_id, v_revision
    FROM public.chat_meetup_sessions
   WHERE room_id = '40000000-0000-0000-0000-00000000c331'
   ORDER BY created_at DESC, meetup_id DESC LIMIT 1;
  SELECT private_revision INTO v_a_revision
    FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c331'
     AND user_id = '10000000-0000-0000-0000-00000000c331';

  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    v_revision, v_a_revision, '80000000-0000-0000-0000-00000000c34c',
    pg_catalog.repeat('e', 64),
    '{"type":"cancel"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.status IS DISTINCT FROM 'cancelled'
     OR v_row.revision IS DISTINCT FROM v_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33x: cancellation did not terminalize the current plan';
  END IF;
  SELECT count(*) INTO v_count FROM public.chat_meetup_sessions
   WHERE meetup_id = v_new_meetup_id
     AND status = 'cancelled'
     AND time_candidates = '[]'::jsonb
     AND cafe_candidates = '[]'::jsonb
     AND confirmed_starts_at IS NULL
     AND confirmed_ends_at IS NULL
     AND confirmed_timezone IS NULL;
  IF v_count <> 1
     OR (SELECT status FROM public.meetups WHERE id = v_new_meetup_id) <> 'cancelled'
     OR EXISTS (SELECT 1 FROM public.chat_meetup_availability WHERE meetup_id = v_new_meetup_id)
     OR EXISTS (SELECT 1 FROM public.chat_meetup_locations WHERE meetup_id = v_new_meetup_id) THEN
    RAISE EXCEPTION 'FAIL SQL33x: cancellation retained plan inputs or legacy state';
  END IF;
END $$;
RESET ROLE;


SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_old_meetup_id uuid;
  v_revision integer;
  v_a_revision integer;
  v_b_revision integer;
BEGIN
  SELECT meetup_id, revision INTO v_old_meetup_id, v_revision
    FROM public.chat_meetup_sessions
   WHERE room_id = '40000000-0000-0000-0000-00000000c331'
   ORDER BY created_at DESC LIMIT 1;
  SELECT private_revision INTO v_a_revision
    FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c331'
     AND user_id = '10000000-0000-0000-0000-00000000c331';
  SELECT private_revision INTO v_b_revision
    FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c331'
     AND user_id = '10000000-0000-0000-0000-00000000c332';

  -- A new intent pair can start after cancellation.
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    v_revision, v_a_revision, '80000000-0000-0000-0000-00000000c34d',
    pg_catalog.repeat('f', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.meetup_id IS NOT NULL
     OR v_row.revision IS DISTINCT FROM v_revision
     OR v_row.own_revision IS DISTINCT FROM v_a_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33y: intent did not restart after cancellation';
  END IF;
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c332',
    v_revision, v_b_revision, '80000000-0000-0000-0000-00000000c34e',
    pg_catalog.repeat('0', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.meetup_id IS NULL
     OR v_row.meetup_id = v_old_meetup_id
     OR v_row.status IS DISTINCT FROM 'awaiting_availability'
     OR v_row.revision IS DISTINCT FROM v_revision + 1
     OR v_row.own_revision IS DISTINCT FROM v_b_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33y: mutual intent did not open a fresh session after cancellation';
  END IF;
END $$;
RESET ROLE;

UPDATE public.chat_meetup_sessions
   SET created_at = pg_catalog.now() + pg_catalog.interval '2 seconds',
       expires_at = pg_catalog.now() - pg_catalog.interval '1 minute'
 WHERE meetup_id = (
   SELECT session_row.meetup_id FROM public.chat_meetup_sessions AS session_row
    WHERE session_row.room_id = '40000000-0000-0000-0000-00000000c331'
      AND session_row.status NOT IN ('completed', 'cancelled', 'expired')
    ORDER BY session_row.created_at DESC, session_row.meetup_id DESC LIMIT 1
 );

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_old_meetup_id uuid;
  v_new_meetup_id uuid;
  v_revision integer;
  v_a_revision integer;
  v_count integer;
BEGIN
  SELECT meetup_id, revision INTO v_old_meetup_id, v_revision
    FROM public.chat_meetup_sessions
   WHERE room_id = '40000000-0000-0000-0000-00000000c331'
   ORDER BY created_at DESC LIMIT 1;
  SELECT private_revision INTO v_a_revision
    FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c331'
     AND user_id = '10000000-0000-0000-0000-00000000c331';

  -- Expiry removes private input and legacy state. Replan is the recovery path.
  SELECT * INTO v_row
    FROM public.expire_chat_meetup_session(
      '40000000-0000-0000-0000-00000000c331',
      '10000000-0000-0000-0000-00000000c331'
    );
  IF v_row.outcome IS DISTINCT FROM 'expired'
     OR v_row.meetup_id IS DISTINCT FROM v_old_meetup_id
     OR v_row.status IS DISTINCT FROM 'expired'
     OR v_row.revision IS DISTINCT FROM v_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33z: elapsed plan was not terminalized by its request-scoped expiry RPC';
  END IF;
  v_revision := v_row.revision;
  SELECT count(*) INTO v_count FROM public.chat_meetup_events WHERE meetup_id = v_old_meetup_id;
  IF v_count <> 2
     OR (SELECT status FROM public.meetups WHERE id = v_old_meetup_id) <> 'expired'
     OR (SELECT expires_at FROM public.chat_meetup_sessions WHERE meetup_id = v_old_meetup_id) IS NOT NULL
     OR (SELECT time_candidates FROM public.chat_meetup_sessions WHERE meetup_id = v_old_meetup_id) <> '[]'::jsonb
     OR (SELECT cafe_candidates FROM public.chat_meetup_sessions WHERE meetup_id = v_old_meetup_id) <> '[]'::jsonb
     OR EXISTS (SELECT 1 FROM public.chat_meetup_availability WHERE meetup_id = v_old_meetup_id)
     OR EXISTS (SELECT 1 FROM public.chat_meetup_locations WHERE meetup_id = v_old_meetup_id) THEN
    RAISE EXCEPTION 'FAIL SQL33z: expiry retained stale candidates, private inputs, or an active legacy row';
  END IF;

  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c331',
    '10000000-0000-0000-0000-00000000c331',
    v_revision, v_a_revision, '80000000-0000-0000-0000-00000000c34f',
    pg_catalog.repeat('1', 64),
    '{"type":"replan"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.meetup_id IS NULL
     OR v_row.meetup_id = v_old_meetup_id
     OR v_row.status IS DISTINCT FROM 'awaiting_availability'
     OR v_row.revision IS DISTINCT FROM v_revision + 1
     OR v_row.own_revision IS DISTINCT FROM v_a_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33z: expired session could not recover to a fresh plan';
  END IF;
  v_new_meetup_id := v_row.meetup_id;
  SELECT count(*) INTO v_count FROM public.chat_meetup_sessions
   WHERE room_id = '40000000-0000-0000-0000-00000000c331'
     AND status NOT IN ('completed', 'cancelled', 'expired');
  IF v_count <> 1
     OR (SELECT status FROM public.meetups WHERE id = v_new_meetup_id) <> 'verifying'
     OR EXISTS (
       SELECT 1 FROM public.chat_meetup_private_decisions
        WHERE match_id = '20000000-0000-0000-0000-00000000c331'
          AND (time_choice_id IS NOT NULL OR cafe_choice_id IS NOT NULL OR completed_at IS NOT NULL)
     ) THEN
    RAISE EXCEPTION 'FAIL SQL33z: expired recovery retained terminal state or private choices';
  END IF;
END $$;
RESET ROLE;

-- A synthetic expired candidate must fail closed without storing choice or replay.
UPDATE public.chat_meetup_sessions SET created_at = (SELECT max(created_at) + interval '1 second' FROM public.chat_meetup_sessions WHERE room_id = '40000000-0000-0000-0000-00000000c331'), status = 'time_proposed', time_candidates = jsonb_build_array(jsonb_build_object(
  'id', 'expired-sql33', 'starts_at', now() - interval '1 minute', 'ends_at', now() + interval '59 minutes'))
 WHERE room_id = '40000000-0000-0000-0000-00000000c331' AND status = 'awaiting_availability';
SET LOCAL ROLE service_role;
DO $$
DECLARE r record; s public.chat_meetup_sessions; d public.chat_meetup_private_decisions; event_count integer;
BEGIN
 SELECT * INTO s FROM public.chat_meetup_sessions WHERE room_id = '40000000-0000-0000-0000-00000000c331' AND status = 'time_proposed';
 SELECT * INTO d FROM public.chat_meetup_private_decisions WHERE match_id = s.match_id AND user_id = '10000000-0000-0000-0000-00000000c331';
 SELECT count(*) INTO event_count FROM public.chat_meetup_events WHERE meetup_id = s.meetup_id;
 SELECT * INTO r FROM public.apply_chat_meetup_action(s.room_id, d.user_id, s.revision, d.private_revision,
   '80000000-0000-0000-0000-00000000c35a', repeat('6',64), '{"type":"time.approve","candidate_id":"expired-sql33"}');
 IF r.outcome IS DISTINCT FROM 'expired_candidate' OR r.status IS DISTINCT FROM 'time_proposed'
    OR r.revision IS DISTINCT FROM s.revision OR r.own_revision IS DISTINCT FROM d.private_revision
    OR (SELECT time_choice_id FROM public.chat_meetup_private_decisions WHERE match_id = s.match_id AND user_id = d.user_id) IS NOT NULL
    OR (SELECT count(*) FROM public.chat_meetup_events WHERE meetup_id = s.meetup_id) <> event_count THEN
   RAISE EXCEPTION 'FAIL SQL33-current-expired: elapsed candidate retained a private choice or mutated the shared plan';
 END IF;
END $$;
RESET ROLE;
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM public.chat_meetup_operations WHERE idempotency_key = '80000000-0000-0000-0000-00000000c35a') THEN
  RAISE EXCEPTION 'FAIL SQL33-current-expired: elapsed candidate consumed a replay key';
 END IF;
END $$;

-- A synthetic past confirmed interval exercises completion through the real
-- RPC: the first person's marker remains private; only the second marker
-- completes the shared session and adds a public event.
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_meetup_id uuid;
BEGIN
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c338',
    '10000000-0000-0000-0000-00000000c338',
    0, 0, '80000000-0000-0000-0000-00000000c338',
    pg_catalog.repeat('2', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok' OR v_row.meetup_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL33aa: completion fixture first intent failed';
  END IF;
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c338',
    '10000000-0000-0000-0000-00000000c339',
    0, 0, '80000000-0000-0000-0000-00000000c339',
    pg_catalog.repeat('3', 64),
    '{"type":"intent","value":"yes"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.meetup_id IS NULL
     OR v_row.status IS DISTINCT FROM 'awaiting_availability'
     OR v_row.revision IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL SQL33aa: completion fixture shared session was not created';
  END IF;
  v_meetup_id := v_row.meetup_id;
END $$;
RESET ROLE;

UPDATE public.chat_meetup_sessions
   SET status = 'confirmed',
       confirmed_starts_at = pg_catalog.now() - pg_catalog.interval '3 hours',
       confirmed_ends_at = pg_catalog.now() - pg_catalog.interval '2 hours',
       confirmed_timezone = 'UTC',
       expires_at = NULL
 WHERE meetup_id = (
   SELECT meetup_id FROM public.chat_meetup_sessions
    WHERE room_id = '40000000-0000-0000-0000-00000000c338'
 );
UPDATE public.meetups
   SET status = 'confirmed',
       confirmed_start_at = pg_catalog.now() - pg_catalog.interval '3 hours',
       confirmed_timezone = 'UTC'
 WHERE id = (
   SELECT meetup_id FROM public.chat_meetup_sessions
    WHERE room_id = '40000000-0000-0000-0000-00000000c338'
 );

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_meetup_id uuid;
  v_event_count integer;
  v_before_revision integer;
  v_own_revision integer;
  v_count integer;
BEGIN
  SELECT meetup_id, revision INTO v_meetup_id, v_before_revision
    FROM public.chat_meetup_sessions
   WHERE room_id = '40000000-0000-0000-0000-00000000c338';
  SELECT count(*) INTO v_event_count FROM public.chat_meetup_events WHERE meetup_id = v_meetup_id;
  SELECT private_revision INTO v_own_revision
    FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c338'
     AND user_id = '10000000-0000-0000-0000-00000000c338';

  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c338',
    '10000000-0000-0000-0000-00000000c338',
    v_before_revision, v_own_revision, '80000000-0000-0000-0000-00000000c33a',
    pg_catalog.repeat('4', 64),
    '{"type":"meeting.complete"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.status IS DISTINCT FROM 'confirmed'
     OR v_row.revision IS DISTINCT FROM v_before_revision
     OR v_row.own_revision IS DISTINCT FROM v_own_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33ab: the first completion marker changed the shared envelope';
  END IF;
  SELECT count(*) INTO v_count FROM public.chat_meetup_events WHERE meetup_id = v_meetup_id;
  IF v_count <> v_event_count
     OR NOT EXISTS (
       SELECT 1 FROM public.chat_meetup_sessions
        WHERE meetup_id = v_meetup_id
          AND completed_a_at IS NOT NULL
          AND completed_b_at IS NULL
          AND status = 'confirmed'
          AND revision = v_before_revision
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.chat_meetup_private_decisions
        WHERE match_id = '20000000-0000-0000-0000-00000000c338'
          AND user_id = '10000000-0000-0000-0000-00000000c338'
          AND completed_at IS NOT NULL
     )
     OR EXISTS (
       SELECT 1 FROM public.chat_meetup_private_decisions
        WHERE match_id = '20000000-0000-0000-0000-00000000c338'
          AND user_id = '10000000-0000-0000-0000-00000000c339'
          AND completed_at IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'FAIL SQL33ab: first completion marked the peer or changed the shared event';
  END IF;

  SELECT private_revision INTO v_own_revision
    FROM public.chat_meetup_private_decisions
   WHERE match_id = '20000000-0000-0000-0000-00000000c338'
     AND user_id = '10000000-0000-0000-0000-00000000c339';
  SELECT * INTO v_row FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000c338',
    '10000000-0000-0000-0000-00000000c339',
    v_before_revision, v_own_revision, '80000000-0000-0000-0000-00000000c33b',
    pg_catalog.repeat('5', 64),
    '{"type":"meeting.complete"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'ok'
     OR v_row.status IS DISTINCT FROM 'completed'
     OR v_row.revision IS DISTINCT FROM v_before_revision + 1
     OR v_row.own_revision IS DISTINCT FROM v_own_revision + 1 THEN
    RAISE EXCEPTION 'FAIL SQL33ac: mutual completion did not close the shared plan';
  END IF;
  IF (SELECT count(*) FROM public.chat_meetup_events WHERE meetup_id = v_meetup_id) <> v_event_count + 1
     OR (SELECT status FROM public.meetups WHERE id = v_meetup_id) <> 'completed'
     OR NOT EXISTS (
       SELECT 1 FROM public.chat_meetup_sessions
        WHERE meetup_id = v_meetup_id
          AND status = 'completed'
          AND completed_a_at IS NOT NULL
          AND completed_b_at IS NOT NULL
          AND revision = v_before_revision + 1
     ) THEN
    RAISE EXCEPTION 'FAIL SQL33ac: mutual completion did not publish its single terminal transition';
  END IF;
END $$;
RESET ROLE;

ROLLBACK;
