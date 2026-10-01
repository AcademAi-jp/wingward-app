-- SQL34 post-meetup reflection authorization, cumulative confirmation and CAS.
-- Uses synthetic fixtures and rolls every database write back.

BEGIN;
SET LOCAL statement_timeout = '15s';

DO $$
DECLARE
  v_function oid;
  v_is_definer boolean;
BEGIN
  FOREACH v_function IN ARRAY ARRAY[
    to_regprocedure('public.get_meetup_reflection_state(uuid,uuid)')::oid,
    to_regprocedure('public.confirm_meetup_reflection(uuid,uuid,uuid,integer,jsonb)')::oid
  ] LOOP
    IF v_function IS NULL THEN
      RAISE EXCEPTION 'FAIL SQL34a: reflection RPC is missing';
    END IF;
    SELECT proc.prosecdef INTO v_is_definer
      FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function;
    IF NOT v_is_definer
       OR NOT COALESCE((SELECT proc.proconfig @> ARRAY['search_path=""']::text[]
                          FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function), false)
       OR has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('authenticated', v_function, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL SQL34b: reflection RPCs must be SECURITY DEFINER with empty search_path and service_role-only EXECUTE';
    END IF;
  END LOOP;

  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'public.user_persona_versions'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'public.user_persona_confirmation_operations'::regclass)
     OR has_table_privilege('anon', 'public.user_persona_versions', 'SELECT')
     OR has_table_privilege('authenticated', 'public.user_persona_versions', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.user_persona_versions', 'SELECT')
     OR has_table_privilege('service_role', 'public.user_persona_versions', 'INSERT')
     OR has_table_privilege('service_role', 'public.user_persona_versions', 'UPDATE')
     OR has_table_privilege('service_role', 'public.user_persona_versions', 'DELETE')
     OR has_table_privilege('service_role', 'public.user_persona_confirmation_operations', 'SELECT')
     OR has_table_privilege('service_role', 'public.user_persona_confirmation_operations', 'INSERT')
     OR has_table_privilege('authenticated', 'public.user_persona_versions', 'INSERT') THEN
    RAISE EXCEPTION 'FAIL SQL34c: persona versions and retry ledger have unsafe RLS or grants';
  END IF;
END $$;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-00000000d341', 'wingward-test-sql34-a@example.invalid'),
  ('00000000-0000-0000-0000-00000000d342', 'wingward-test-sql34-b@example.invalid'),
  ('00000000-0000-0000-0000-00000000d343', 'wingward-test-sql34-outsider@example.invalid');

WITH fixtures (auth_user_id, profile_id, nickname) AS (
  VALUES
    ('00000000-0000-0000-0000-00000000d341'::uuid, '10000000-0000-0000-0000-00000000d341'::uuid, 'SQL34 A'),
    ('00000000-0000-0000-0000-00000000d342'::uuid, '10000000-0000-0000-0000-00000000d342'::uuid, 'SQL34 B'),
    ('00000000-0000-0000-0000-00000000d343'::uuid, '10000000-0000-0000-0000-00000000d343'::uuid, 'SQL34 outsider')
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

-- Reflections merge into an existing owner-confirmed canonical profile.
INSERT INTO public.profiles (user_id, status, confirmed_at, personality_tags) VALUES
  ('10000000-0000-0000-0000-00000000d341', 'confirmed', now(), '["Original A"]'),
  ('10000000-0000-0000-0000-00000000d342', 'confirmed', now(), '["Original B"]');

INSERT INTO public.matches (id, user_a_id, user_b_id, status) VALUES
  ('20000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d342', 'direct_chat_active');
INSERT INTO public.direct_chat_rooms (id, match_id, status) VALUES
  ('40000000-0000-0000-0000-00000000d341', '20000000-0000-0000-0000-00000000d341', 'active');
INSERT INTO public.meetups (id, match_id, initiator_id, status) VALUES
  ('30000000-0000-0000-0000-00000000d341', '20000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341', 'intent_pending');
INSERT INTO public.chat_meetup_sessions (
  meetup_id, match_id, room_id, user_a_id, user_b_id, status,
  confirmed_starts_at, confirmed_ends_at, confirmed_timezone,
  completed_a_at, completed_b_at
) VALUES (
  '30000000-0000-0000-0000-00000000d341', '20000000-0000-0000-0000-00000000d341',
  '40000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341',
  '10000000-0000-0000-0000-00000000d342', 'confirmed',
  pg_catalog.now() - interval '3 hours', pg_catalog.now() - interval '2 hours', 'UTC',
  NULL, NULL
);

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_first_key uuid := '80000000-0000-0000-0000-00000000d341';
  v_next_key uuid := '80000000-0000-0000-0000-00000000d342';
  v_action record;
  v_before_updated_at timestamptz;
BEGIN
  SELECT * INTO v_row FROM public.get_meetup_reflection_state(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341'
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL34d: a participant without their own completion cannot start reflection';
  END IF;

  -- Exercise the real owner-scoped completion RPC. It must persist A's
  -- attendance marker while leaving the shared confirmed state unchanged.
  SELECT session_row.updated_at INTO v_before_updated_at
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.meetup_id = '30000000-0000-0000-0000-00000000d341';
  SELECT * INTO v_action FROM public.apply_chat_meetup_action(
    '40000000-0000-0000-0000-00000000d341',
    '10000000-0000-0000-0000-00000000d341',
    0, 0, '80000000-0000-0000-0000-00000000d345', pg_catalog.repeat('a', 64),
    '{"type":"meeting.complete"}'::jsonb
  );
  IF v_action.outcome IS DISTINCT FROM 'ok' OR v_action.status IS DISTINCT FROM 'confirmed'
     OR v_action.revision <> 0 OR v_action.own_revision <> 1 THEN
    RAISE EXCEPTION 'FAIL SQL34e: one-sided completion did not preserve the shared state';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_meetup_sessions AS session_row
     WHERE session_row.meetup_id = '30000000-0000-0000-0000-00000000d341'
       AND session_row.status = 'confirmed'
       AND session_row.revision = 0
       AND session_row.updated_at IS NOT DISTINCT FROM v_before_updated_at
       AND session_row.completed_a_at IS NOT NULL
       AND session_row.completed_a_at <= pg_catalog.clock_timestamp()
       AND session_row.completed_b_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL SQL34e: one-sided completion did not preserve its private owner marker only';
  END IF;

  SELECT * INTO v_row FROM public.get_meetup_reflection_state(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341'
  );
  IF v_row.outcome IS DISTINCT FROM 'ok' OR v_row.current_version <> 0
     OR v_row.traits IS DISTINCT FROM '{}'::jsonb OR v_row.confirmed_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL34f: completed owner should start with an empty private reflection state';
  END IF;

  SELECT * INTO v_row FROM public.get_meetup_reflection_state(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d342'
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' OR v_row.traits IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL34g: the peer must not read reflection before their own completion';
  END IF;
  SELECT * INTO v_row FROM public.get_meetup_reflection_state(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d343'
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL34h: a nonparticipant received reflection access';
  END IF;

  SELECT * INTO v_row FROM public.confirm_meetup_reflection(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341',
    v_first_key, 0, '{"priority_value":"community","favorite_activity":"reading"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'confirmed' OR v_row.version <> 1
     OR v_row.traits IS DISTINCT FROM '{"priority_value":"community","favorite_activity":"reading"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL SQL34i: first explicit confirmation did not create persona version one';
  END IF;

  SELECT * INTO v_row FROM public.confirm_meetup_reflection(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341',
    v_first_key, 0, '{"priority_value":"community","favorite_activity":"reading"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'replayed' OR v_row.version <> 1 THEN
    RAISE EXCEPTION 'FAIL SQL34j: exact retry did not return the original confirmed version';
  END IF;

  SELECT * INTO v_row FROM public.confirm_meetup_reflection(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341',
    v_first_key, 0, '{"priority_value":"family"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'key_reused' THEN
    RAISE EXCEPTION 'FAIL SQL34k: same-key changed request was not rejected';
  END IF;

  SELECT * INTO v_row FROM public.confirm_meetup_reflection(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341',
    v_next_key, 0, '{"communication_preference":"detailed"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'version_conflict' THEN
    RAISE EXCEPTION 'FAIL SQL34l: stale persona baseline was not rejected';
  END IF;

  SELECT * INTO v_row FROM public.confirm_meetup_reflection(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341',
    v_next_key, 1, '{"communication_preference":"detailed"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'confirmed' OR v_row.version <> 2
     OR v_row.traits IS DISTINCT FROM '{"priority_value":"community","favorite_activity":"reading","communication_preference":"detailed"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL SQL34m: a later version did not retain confirmed preferences cumulatively';
  END IF;

  SELECT * INTO v_row FROM public.get_meetup_reflection_state(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341'
  );
  IF v_row.outcome IS DISTINCT FROM 'ok' OR v_row.current_version <> 2
     OR v_row.traits IS DISTINCT FROM '{"priority_value":"community","favorite_activity":"reading","communication_preference":"detailed"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL SQL34n: owner state did not return the latest cumulative persona';
  END IF;

  SELECT * INTO v_row FROM public.confirm_meetup_reflection(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d342',
    '80000000-0000-0000-0000-00000000d343', 0, '{"social_energy":"introverted"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL34o: peer without own completion created persona data';
  END IF;

  SELECT * INTO v_row FROM public.confirm_meetup_reflection(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341',
    '80000000-0000-0000-0000-00000000d344', 2, '{"free_text":"not allowed"}'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL SQL34p: open-text traits reached the persistence boundary';
  END IF;
END $$;
RESET ROLE;

-- The current-block check must also fence existing owners from reflection.
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d342');
SET LOCAL ROLE service_role;
DO $$
DECLARE v_row record;
BEGIN
  SELECT * INTO v_row FROM public.get_meetup_reflection_state(
    '30000000-0000-0000-0000-00000000d341', '10000000-0000-0000-0000-00000000d341'
  );
  IF v_row.outcome IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'FAIL SQL34q: a current block did not fence private reflection';
  END IF;
END $$;
RESET ROLE;
ROLLBACK;
