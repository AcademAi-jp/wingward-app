-- Local synthetic acceptance test for the Sora third-interview admission.
-- Run after migrations with psql -v ON_ERROR_STOP=1; everything rolls back.

BEGIN;
SET LOCAL statement_timeout = '30s';

DO $$
DECLARE
  v_oid oid;
  v_definition text;
BEGIN
  v_oid := to_regprocedure('public.reserve_sora_recording_interview(uuid,uuid,timestamptz,timestamptz,timestamptz)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'FAIL SQL37a: reservation RPC is missing'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS proc
     WHERE proc.oid = v_oid
       AND proc.prosecdef IS TRUE
       AND proc.proconfig @> ARRAY['search_path=""']::text[]
  ) THEN RAISE EXCEPTION 'FAIL SQL37a: reservation RPC security configuration is invalid'; END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL37a: reservation RPC grants are not service_role-only';
  END IF;

  v_oid := to_regprocedure('public.issue_sora_recording_interview_token(uuid,uuid,timestamptz,timestamptz,timestamptz)');
  IF v_oid IS NULL OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL37a: token RPC grants are not service_role-only';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS proc
     WHERE proc.oid = v_oid AND proc.prosecdef IS TRUE
       AND proc.proconfig @> ARRAY['search_path=""']::text[]
  ) THEN RAISE EXCEPTION 'FAIL SQL37a: token RPC security configuration is invalid'; END IF;

  v_oid := to_regprocedure('public.complete_sora_recording_interview(uuid,uuid,timestamptz,timestamptz,timestamptz,jsonb)');
  IF v_oid IS NULL OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL37a: completion RPC grants are not service_role-only';
  END IF;
  SELECT pg_catalog.pg_get_functiondef(v_oid) INTO v_definition;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_oid
      AND proc.prosecdef IS TRUE AND proc.proconfig @> ARRAY['search_path=""']::text[]
  ) OR pg_catalog.strpos(v_definition, 'FROM public.user_profiles') < 1
     OR pg_catalog.strpos(v_definition, 'FROM public.sora_recording_interview_admissions')
        <= pg_catalog.strpos(v_definition, 'FROM public.user_profiles')
     OR pg_catalog.strpos(v_definition, 'public.complete_speed_dating_session')
        <= pg_catalog.strpos(v_definition, 'FROM public.sora_recording_interview_admissions') THEN
    RAISE EXCEPTION 'FAIL SQL37a: completion wrapper does not lock owner before admission before completion';
  END IF;
  IF has_table_privilege('service_role', 'public.sora_recording_interview_admissions', 'SELECT')
     OR has_table_privilege('anon', 'public.sora_recording_interview_admissions', 'SELECT')
     OR has_table_privilege('authenticated', 'public.sora_recording_interview_admissions', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL SQL37a: admission table is directly readable';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS relation
     WHERE relation.oid = 'public.sora_recording_interview_admissions'::regclass
       AND relation.relrowsecurity IS TRUE
  ) THEN RAISE EXCEPTION 'FAIL SQL37a: admission table RLS is disabled'; END IF;
END $$;

-- This fixed profile ID is used only in this rolled-back synthetic fixture.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.user_profiles WHERE id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f') THEN
    RAISE EXCEPTION 'FAIL SQL37b: fixed synthetic Sora profile ID is already occupied';
  END IF;
END $$;

INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-00000000c371', 'wingward-test-sql37@example.invalid');

UPDATE public.user_profiles
   SET id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f',
       nickname = 'SQL37 synthetic Sora',
       onboarding_status = 'quiz_completed'
 WHERE auth_user_id = '00000000-0000-0000-0000-00000000c371';

INSERT INTO public.personas (id, user_id, persona_type, name, compiled_document)
VALUES
  ('11000000-0000-0000-0000-00000000c371', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', 'virtual_similar', 'SQL37 similar', 'synthetic fixture'),
  ('11000000-0000-0000-0000-00000000c372', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', 'virtual_complementary', 'SQL37 complementary', 'synthetic fixture'),
  ('11000000-0000-0000-0000-00000000c373', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', 'virtual_discovery', 'SQL37 discovery', 'synthetic fixture');

INSERT INTO public.speed_dating_sessions (id, user_id, persona_id, status, message_count, completed_at)
VALUES
  ('20000000-0000-0000-0000-00000000c371', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c371', 'completed', 1, pg_catalog.now()),
  ('20000000-0000-0000-0000-00000000c372', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c372', 'completed', 1, pg_catalog.now()),
  ('20000000-0000-0000-0000-00000000c381', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c371', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c382', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c372', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c383', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c373', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c384', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c371', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c385', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c372', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c386', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c373', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c387', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c371', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c388', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c372', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c389', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c373', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c38a', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c371', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c38b', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c372', 'active', 0, NULL),
  ('20000000-0000-0000-0000-00000000c38c', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c373', 'active', 0, NULL);

CREATE TEMP TABLE sora_legacy_session_snapshot ON COMMIT DROP AS
SELECT id, user_id, persona_id, status, message_count, completed_at
  FROM public.speed_dating_sessions
 WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'
   AND id BETWEEN '20000000-0000-0000-0000-00000000c381'::uuid
              AND '20000000-0000-0000-0000-00000000c38c'::uuid;

SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_base_expiry timestamptz;
  v_admission_expiry timestamptz;
  v_reserved record;
  v_retry record;
  v_row record;
  v_before_sessions integer;
  v_after_sessions integer;
  v_transcript jsonb := '[{"source":"user","message":"synthetic user utterance"},{"source":"ai","message":"synthetic assistant utterance"}]'::jsonb;
BEGIN
  v_base_expiry := v_now + pg_catalog.interval '2 hours';
  v_admission_expiry := v_now + pg_catalog.interval '30 minutes';
  SELECT pg_catalog.count(*)::integer INTO v_before_sessions
    FROM public.speed_dating_sessions WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f';

  SELECT * INTO v_row FROM public.reserve_sora_recording_interview(
    '10000000-0000-0000-0000-00000000c371', '11000000-0000-0000-0000-00000000c373',
    v_base_expiry, v_now, v_admission_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'not_eligible' OR v_row.session_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL37c: another user was admitted as Sora';
  END IF;

  SELECT * INTO v_row FROM public.reserve_sora_recording_interview(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c373',
    v_now - pg_catalog.interval '1 second', v_now - pg_catalog.interval '1 minute', v_now + pg_catalog.interval '10 minutes'
  );
  IF v_row.outcome IS DISTINCT FROM 'not_eligible' THEN
    RAISE EXCEPTION 'FAIL SQL37c: expired rehearsal was admitted';
  END IF;

  SELECT * INTO v_row FROM public.reserve_sora_recording_interview(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c373',
    v_now + pg_catalog.interval '3 hours', v_now, v_admission_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'not_eligible' THEN
    RAISE EXCEPTION 'FAIL SQL37c: excessive base expiry was admitted';
  END IF;

  SELECT * INTO v_row FROM public.reserve_sora_recording_interview(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c371',
    v_base_expiry, v_now, v_admission_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'not_eligible' THEN
    RAISE EXCEPTION 'FAIL SQL37c: a persona already completed twice was admitted';
  END IF;

  SELECT * INTO v_reserved FROM public.reserve_sora_recording_interview(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c373',
    v_base_expiry, v_now, v_admission_expiry
  );
  IF v_reserved.outcome IS DISTINCT FROM 'reserved'
     OR v_reserved.session_id IS NULL
     OR v_reserved.persona_id IS DISTINCT FROM '11000000-0000-0000-0000-00000000c373'::uuid THEN
    RAISE EXCEPTION 'FAIL SQL37d: eligible missing third persona was not reserved';
  END IF;

  SELECT * INTO v_retry FROM public.reserve_sora_recording_interview(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c373',
    v_base_expiry, v_now, v_admission_expiry
  );
  IF v_retry.outcome IS DISTINCT FROM 'already_reserved'
     OR v_retry.session_id IS DISTINCT FROM v_reserved.session_id THEN
    RAISE EXCEPTION 'FAIL SQL37d: same reservation retry did not return the original session';
  END IF;

  SELECT * INTO v_row FROM public.reserve_sora_recording_interview(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c371',
    v_base_expiry, v_now, v_admission_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'conflict' OR v_row.session_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL37d: different target reused the one reservation';
  END IF;

  SELECT * INTO v_row FROM public.complete_sora_recording_interview(
    v_reserved.session_id, 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_base_expiry, v_now, v_admission_expiry, v_transcript
  );
  IF v_row.outcome IS DISTINCT FROM 'invalid_state' THEN
    RAISE EXCEPTION 'FAIL SQL37e: completion before token claim was accepted';
  END IF;

  SELECT * INTO v_row FROM public.complete_sora_recording_interview(
    '20000000-0000-0000-0000-00000000c381', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_base_expiry, v_now, v_admission_expiry, v_transcript
  );
  IF v_row.outcome IS DISTINCT FROM 'invalid_state' THEN
    RAISE EXCEPTION 'FAIL SQL37e: old incomplete session completed through the Sora wrapper';
  END IF;

  SELECT public.issue_sora_recording_interview_token(
    '10000000-0000-0000-0000-00000000c371', v_reserved.session_id, v_base_expiry, v_now, v_admission_expiry
  ) INTO v_row;
  IF v_row.issue_sora_recording_interview_token IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL SQL37f: another user claimed the token';
  END IF;

  SELECT public.issue_sora_recording_interview_token(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_reserved.session_id, v_base_expiry,
    v_now, v_now + pg_catalog.interval '5 minutes 59 seconds'
  ) INTO v_row;
  IF v_row.issue_sora_recording_interview_token IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL SQL37f: token was issued with less than six minutes remaining';
  END IF;

  SELECT public.issue_sora_recording_interview_token(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '20000000-0000-0000-0000-00000000c381',
    v_base_expiry, v_now, v_admission_expiry
  ) INTO v_row;
  IF v_row.issue_sora_recording_interview_token IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL SQL37f: token was claimed for an old session';
  END IF;

  IF public.issue_sora_recording_interview_token(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_reserved.session_id, v_base_expiry, v_now, v_admission_expiry
  ) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL SQL37g: eligible one-time token claim failed';
  END IF;
  IF public.issue_sora_recording_interview_token(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_reserved.session_id, v_base_expiry, v_now, v_admission_expiry
  ) IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL SQL37g: duplicate token claim was accepted';
  END IF;

  SELECT * INTO v_row FROM public.complete_sora_recording_interview(
    v_reserved.session_id, 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_base_expiry, v_now, v_admission_expiry, NULL::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL SQL37h: NULL transcript completed a native voice interview';
  END IF;

  SELECT * INTO v_row FROM public.complete_sora_recording_interview(
    v_reserved.session_id, 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_base_expiry, v_now, v_admission_expiry,
    '[{"source":"user","message":"synthetic user utterance"}]'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL SQL37h: one-speaker transcript completed a native voice interview';
  END IF;

  SELECT * INTO v_row FROM public.complete_sora_recording_interview(
    v_reserved.session_id, 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_base_expiry, v_now, v_admission_expiry,
    '[{"source":"user","message":"  "},{"source":"ai","message":"synthetic assistant utterance"}]'::jsonb
  );
  IF v_row.outcome IS DISTINCT FROM 'invalid_input' THEN
    RAISE EXCEPTION 'FAIL SQL37h: blank utterance completed a native voice interview';
  END IF;

  SELECT * INTO v_row FROM public.complete_sora_recording_interview(
    v_reserved.session_id, 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_base_expiry, v_now, v_admission_expiry, v_transcript
  );
  IF v_row.outcome IS DISTINCT FROM 'stored'
     OR v_row.status IS DISTINCT FROM 'completed'
     OR v_row.message_count IS DISTINCT FROM 2
     OR v_row.all_sessions_completed IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL SQL37i: valid transcript did not complete the reserved interview';
  END IF;

  SELECT * INTO v_row FROM public.complete_sora_recording_interview(
    v_reserved.session_id, 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_base_expiry, v_now, v_admission_expiry, v_transcript
  );
  IF v_row.outcome IS DISTINCT FROM 'already_completed' THEN
    RAISE EXCEPTION 'FAIL SQL37i: exact completion replay was not idempotent';
  END IF;

  SELECT pg_catalog.count(*)::integer INTO v_after_sessions
    FROM public.speed_dating_sessions WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f';
  IF v_after_sessions IS DISTINCT FROM v_before_sessions + 1 THEN
    RAISE EXCEPTION 'FAIL SQL37j: reservation created other than exactly one new session';
  END IF;
  SELECT * INTO v_row FROM public.reserve_sora_recording_interview(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c373',
    v_base_expiry, v_now, v_admission_expiry
  );
  IF v_row.outcome NOT IN ('not_eligible', 'conflict') OR v_row.session_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL37j: completed admission was restarted';
  END IF;
END $$;

RESET ROLE;

DO $$
BEGIN
  IF (SELECT pg_catalog.count(*) FROM public.sora_recording_interview_admissions
       WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f') <> 1 THEN
    RAISE EXCEPTION 'FAIL SQL37j: reservation ledger does not contain exactly one row';
  END IF;
  IF EXISTS (
    (SELECT id, user_id, persona_id, status, message_count, completed_at FROM sora_legacy_session_snapshot)
    EXCEPT
    (SELECT id, user_id, persona_id, status, message_count, completed_at
       FROM public.speed_dating_sessions
      WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'
        AND id BETWEEN '20000000-0000-0000-0000-00000000c381'::uuid
                   AND '20000000-0000-0000-0000-00000000c38c'::uuid)
  ) OR EXISTS (
    (SELECT id, user_id, persona_id, status, message_count, completed_at
       FROM public.speed_dating_sessions
      WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'
        AND id BETWEEN '20000000-0000-0000-0000-00000000c381'::uuid
                   AND '20000000-0000-0000-0000-00000000c38c'::uuid)
    EXCEPT
    (SELECT id, user_id, persona_id, status, message_count, completed_at FROM sora_legacy_session_snapshot)
  ) THEN
    RAISE EXCEPTION 'FAIL SQL37k: prior active-session metadata changed';
  END IF;
END $$;

ROLLBACK;
