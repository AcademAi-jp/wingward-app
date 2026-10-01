-- Local synthetic acceptance test for one Sora profile replacement.
-- Run after migrations with psql -v ON_ERROR_STOP=1; everything rolls back.

BEGIN;
SET LOCAL statement_timeout = '30s';

DO $$
DECLARE
  v_oid oid;
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'public.read_sora_three_interview_profile_revision_state(uuid,timestamptz)',
    'public.claim_sora_three_interview_profile_revision(uuid,timestamptz)',
    'public.complete_sora_three_interview_profile_revision(uuid,timestamptz,uuid,integer,jsonb)'
  ] LOOP
    v_oid := pg_catalog.to_regprocedure(v_name);
    IF v_oid IS NULL THEN RAISE EXCEPTION 'FAIL SQL38a: required revision RPC is missing'; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_proc AS proc
       WHERE proc.oid = v_oid AND proc.prosecdef IS TRUE
         AND proc.proconfig @> ARRAY['search_path=""']::text[]
    ) THEN RAISE EXCEPTION 'FAIL SQL38a: RPC security configuration is invalid'; END IF;
    IF has_function_privilege('anon', v_oid, 'EXECUTE')
       OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL SQL38a: RPC grants are not service_role-only';
    END IF;
  END LOOP;
  IF has_table_privilege('anon', 'public.sora_profile_revision_runs', 'SELECT')
     OR has_table_privilege('authenticated', 'public.sora_profile_revision_runs', 'SELECT')
     OR has_table_privilege('service_role', 'public.sora_profile_revision_runs', 'SELECT')
     OR has_table_privilege('service_role', 'public.sora_profile_revision_runs', 'INSERT')
     OR has_table_privilege('service_role', 'public.sora_profile_revision_runs', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL SQL38a: revision ledger is directly accessible';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class AS relation
     WHERE relation.oid = 'public.sora_profile_revision_runs'::regclass
       AND relation.relrowsecurity IS TRUE
  ) THEN RAISE EXCEPTION 'FAIL SQL38a: revision ledger RLS is disabled'; END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint AS constraint_row
     WHERE constraint_row.conrelid = 'public.sora_profile_revision_runs'::regclass
       AND constraint_row.conname = 'sora_profile_revision_runs_source_profile_id_fkey'
       AND constraint_row.confdeltype = 'c'
  ) THEN RAISE EXCEPTION 'FAIL SQL38a: deleting a source profile could reopen the one-time claim'; END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.user_profiles WHERE id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f') THEN
    RAISE EXCEPTION 'FAIL SQL38b: fixed synthetic Sora ID is already occupied';
  END IF;
END $$;

INSERT INTO auth.users (id, email)
VALUES
  ('00000000-0000-0000-0000-00000000c381', 'wingward-test-sql38@example.invalid'),
  ('00000000-0000-0000-0000-00000000c382', 'wingward-test-sql38-other@example.invalid');

UPDATE public.user_profiles
   SET id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f',
       nickname = 'SQL38 synthetic Sora',
       onboarding_status = 'speed_dating_completed'
 WHERE auth_user_id = '00000000-0000-0000-0000-00000000c381';

INSERT INTO public.personas (id, user_id, persona_type, name, compiled_document)
VALUES
  ('11000000-0000-0000-0000-00000000c381', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', 'virtual_similar', 'SQL38 similar', 'synthetic fixture'),
  ('11000000-0000-0000-0000-00000000c382', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', 'virtual_complementary', 'SQL38 complementary', 'synthetic fixture'),
  ('11000000-0000-0000-0000-00000000c383', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', 'virtual_discovery', 'SQL38 discovery', 'synthetic fixture'),
  ('11000000-0000-0000-0000-00000000c384', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', 'wingfox', 'SQL38 preserved Wingfox', 'synthetic Wingfox document'),
  ('11000000-0000-0000-0000-00000000c385', (SELECT id FROM public.user_profiles WHERE auth_user_id = '00000000-0000-0000-0000-00000000c382'), 'virtual_discovery', 'SQL38 other owner', 'synthetic fixture');

INSERT INTO public.speed_dating_sessions (id, user_id, persona_id, status, message_count, completed_at)
VALUES
  ('20000000-0000-0000-0000-00000000c381', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c381', 'completed', 4, '2026-09-29T03:00:00Z'),
  ('20000000-0000-0000-0000-00000000c382', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c382', 'completed', 4, '2026-09-29T02:00:00Z'),
  ('20000000-0000-0000-0000-00000000c383', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', '11000000-0000-0000-0000-00000000c383', 'completed', 4, '2026-09-29T01:00:00Z');

INSERT INTO public.speed_dating_sessions (id, user_id, persona_id, status, message_count, completed_at)
SELECT
  ('20000000-0000-0000-0000-' || pg_catalog.lpad(pg_catalog.to_hex(50000 + n), 12, '0'))::uuid,
  'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'::uuid,
  CASE n % 3
    WHEN 1 THEN '11000000-0000-0000-0000-00000000c381'::uuid
    WHEN 2 THEN '11000000-0000-0000-0000-00000000c382'::uuid
    ELSE '11000000-0000-0000-0000-00000000c383'::uuid
  END,
  'active', 0, NULL
FROM pg_catalog.generate_series(1, 12) AS series(n);

INSERT INTO public.persona_sections (persona_id, section_id, content, source)
VALUES
  ('11000000-0000-0000-0000-00000000c384', 'core_identity', 'synthetic old core identity', 'manual'),
  ('11000000-0000-0000-0000-00000000c384', 'communication_rules', 'synthetic old communication rules', 'manual'),
  ('11000000-0000-0000-0000-00000000c384', 'personality_profile', 'synthetic old personality profile', 'manual'),
  ('11000000-0000-0000-0000-00000000c384', 'interests', 'synthetic old interests', 'manual'),
  ('11000000-0000-0000-0000-00000000c384', 'values', 'synthetic old values', 'manual'),
  ('11000000-0000-0000-0000-00000000c384', 'romance_style', 'synthetic old romance style', 'manual'),
  ('11000000-0000-0000-0000-00000000c384', 'conversation_references', 'synthetic old conversation references', 'manual'),
  ('11000000-0000-0000-0000-00000000c384', 'constraints', 'synthetic old constraints', 'manual');

INSERT INTO public.profiles (
  id, user_id, basic_info, personality_tags, personality_analysis, interests,
  values, romance_style, communication_style, lifestyle, status, version, confirmed_at,
  created_at, updated_at
) VALUES (
  '30000000-0000-0000-0000-00000000c381', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f',
  '{"sentinel":"old draft"}', '["preserve until success"]', '{"old_score":0.25}', '[{"category":"old","items":["preserve"]}]',
  '{"old_value":0.25}', '{"old_romance":"keep"}', '{"old_communication":"keep"}', '{"old_lifestyle":"keep"}',
  'draft', 7, NULL, '2026-09-28T00:00:00Z', '2026-09-29T00:00:00Z'
);

CREATE TEMP TABLE sora_old_profile_snapshot ON COMMIT DROP AS
SELECT * FROM public.profiles WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f';
CREATE TEMP TABLE sora_old_wingfox_snapshot ON COMMIT DROP AS
SELECT id, persona_id, section_id, content, source
  FROM public.persona_sections WHERE persona_id = '11000000-0000-0000-0000-00000000c384';
CREATE TEMP TABLE sora_active_session_snapshot ON COMMIT DROP AS
SELECT id, user_id, persona_id, status, message_count, completed_at
  FROM public.speed_dating_sessions
 WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f' AND status = 'active';
GRANT SELECT ON sora_old_profile_snapshot, sora_old_wingfox_snapshot, sora_active_session_snapshot TO service_role;

SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_expiry timestamptz;
  v_row record;
  v_wrong record;
  v_source_id uuid;
  v_source_version integer;
  v_sessions uuid[];
  v_candidate jsonb := '{
    "basic_info":{"age_range":"25-29","location":"","occupation":""},
    "personality_tags":["curious and open-minded","warm once comfortable","thoughtful listener"],
    "personality_analysis":{"introvert_extrovert":0.5,"planned_spontaneous":0.5,"logical_emotional":0.5},
    "interaction_style":{"warmup_speed":0.55,"dna_scores":{"mere_exposure":{"score":0.55,"confidence":0.7,"evidence_turns":[1],"reasoning":"synthetic"}}},
    "interests":[{"category":"Music","items":["Jazz"]}],
    "values":{"work_life_balance":0.5},
    "romance_style":{"communication_frequency":"daily","ideal_relationship":"supportive","dealbreakers":[],"preferred_partner_type":"similar"},
    "communication_style":{"message_length":"medium","question_ratio":0.5,"humor_level":0.5,"empathy_level":0.5,"topic_preferences":[]},
    "lifestyle":{"weekend_activities":[],"diet":"","exercise":""}
  }'::jsonb;
BEGIN
  v_expiry := v_now + INTERVAL '2 hours';

  SELECT * INTO v_row FROM public.read_sora_three_interview_profile_revision_state(
    '10000000-0000-0000-0000-00000000c381', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'FAIL SQL38b: another user can read Sora revision state';
  END IF;

  SELECT * INTO v_row FROM public.read_sora_three_interview_profile_revision_state(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_now - INTERVAL '1 second'
  );
  IF v_row.outcome IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'FAIL SQL38b: expired rehearsal reports revision available';
  END IF;

  SELECT * INTO v_row FROM public.read_sora_three_interview_profile_revision_state(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'available' THEN
    RAISE EXCEPTION 'FAIL SQL38c: exactly three distinct completed virtual interviews are not available';
  END IF;

  UPDATE public.speed_dating_sessions SET persona_id = '11000000-0000-0000-0000-00000000c385'
   WHERE id = '20000000-0000-0000-0000-00000000c383';
  SELECT * INTO v_row FROM public.read_sora_three_interview_profile_revision_state(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'FAIL SQL38c: a session with a persona owned by another profile was accepted';
  END IF;
  UPDATE public.speed_dating_sessions SET persona_id = '11000000-0000-0000-0000-00000000c383'
   WHERE id = '20000000-0000-0000-0000-00000000c383';

  UPDATE public.speed_dating_sessions SET completed_at = NULL
   WHERE id = '20000000-0000-0000-0000-00000000c383';
  SELECT * INTO v_row FROM public.read_sora_three_interview_profile_revision_state(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'FAIL SQL38c: a completed row without completed_at was accepted';
  END IF;
  UPDATE public.speed_dating_sessions SET completed_at = '2026-09-29T01:00:00Z'
   WHERE id = '20000000-0000-0000-0000-00000000c383';

  INSERT INTO public.speed_dating_sessions (id, user_id, persona_id, status, message_count, completed_at)
  VALUES ('20000000-0000-0000-0000-00000000c38f', 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f',
    '11000000-0000-0000-0000-00000000c381', 'completed', 4, '2026-09-29T00:00:00Z');
  SELECT * INTO v_row FROM public.read_sora_three_interview_profile_revision_state(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'FAIL SQL38c: more than three completed sessions were accepted';
  END IF;
  DELETE FROM public.speed_dating_sessions WHERE id = '20000000-0000-0000-0000-00000000c38f';

  SELECT * INTO v_row FROM public.claim_sora_three_interview_profile_revision(
    '10000000-0000-0000-0000-00000000c381', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'not_eligible' THEN
    RAISE EXCEPTION 'FAIL SQL38c: another user claimed Sora revision';
  END IF;

  SELECT * INTO v_row FROM public.claim_sora_three_interview_profile_revision(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' OR v_row.source_profile_id IS DISTINCT FROM '30000000-0000-0000-0000-00000000c381'::uuid
     OR v_row.source_version IS DISTINCT FROM 7 OR pg_catalog.cardinality(v_row.session_ids) IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'FAIL SQL38d: valid one-time profile claim failed';
  END IF;
  v_source_id := v_row.source_profile_id;
  v_source_version := v_row.source_version;
  v_sessions := v_row.session_ids;

  SELECT * INTO v_row FROM public.read_sora_three_interview_profile_revision_state(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'claimed' THEN
    RAISE EXCEPTION 'FAIL SQL38d: claimed state was not persisted';
  END IF;
  SELECT * INTO v_row FROM public.claim_sora_three_interview_profile_revision(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'already_claimed' THEN
    RAISE EXCEPTION 'FAIL SQL38d: a provider-failure retry reclaimed the one-time run';
  END IF;

  UPDATE public.profiles SET personality_tags = '["same-version concurrent edit"]'
   WHERE id = v_source_id;
  SELECT * INTO v_row FROM public.complete_sora_three_interview_profile_revision(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry, v_source_id, v_source_version, v_candidate
  );
  IF v_row.outcome IS DISTINCT FROM 'not_eligible' THEN
    RAISE EXCEPTION 'FAIL SQL38e: same-version edit passed full-source-snapshot validation';
  END IF;
  IF (SELECT personality_tags FROM public.profiles WHERE id = v_source_id) IS DISTINCT FROM '["same-version concurrent edit"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL SQL38e: a rejected source edit was overwritten';
  END IF;
  UPDATE public.profiles AS live
     SET basic_info = old.basic_info,
         personality_tags = old.personality_tags,
         personality_analysis = old.personality_analysis,
         interests = old.interests,
         values = old.values,
         romance_style = old.romance_style,
         communication_style = old.communication_style,
         lifestyle = old.lifestyle,
         status = old.status,
         version = old.version,
         confirmed_at = old.confirmed_at,
         created_at = old.created_at,
         updated_at = old.updated_at
    FROM sora_old_profile_snapshot AS old WHERE live.id = old.id;

  UPDATE public.speed_dating_sessions SET completed_at = NULL
   WHERE id = v_sessions[1];
  SELECT * INTO v_row FROM public.complete_sora_three_interview_profile_revision(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry, v_source_id, v_source_version, v_candidate
  );
  IF v_row.outcome IS DISTINCT FROM 'not_eligible' THEN
    RAISE EXCEPTION 'FAIL SQL38e: a completion without all three timestamps was accepted';
  END IF;
  UPDATE public.speed_dating_sessions SET completed_at = '2026-09-29T03:00:00Z'
   WHERE id = v_sessions[1];

  SELECT * INTO v_row FROM public.complete_sora_three_interview_profile_revision(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry, v_source_id, v_source_version, v_candidate
  );
  IF v_row.outcome IS DISTINCT FROM 'saved' OR v_row.target_version IS DISTINCT FROM 8 THEN
    RAISE EXCEPTION 'FAIL SQL38f: valid revision was not saved as version 8';
  END IF;
  IF (SELECT onboarding_status FROM public.user_profiles WHERE id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f') IS DISTINCT FROM 'profile_generated' THEN
    RAISE EXCEPTION 'FAIL SQL38f: successful revision did not advance onboarding';
  END IF;
  IF (SELECT status FROM public.profiles WHERE id = v_source_id) IS DISTINCT FROM 'draft'
     OR (SELECT version FROM public.profiles WHERE id = v_source_id) IS DISTINCT FROM 8
     OR (SELECT personality_tags FROM public.profiles WHERE id = v_source_id) IS DISTINCT FROM '["curious and open-minded", "warm once comfortable", "thoughtful listener"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL SQL38f: successful revision did not replace the old draft';
  END IF;

  SELECT * INTO v_row FROM public.read_sora_three_interview_profile_revision_state(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'FAIL SQL38f: completed state was not persisted';
  END IF;
  SELECT * INTO v_row FROM public.claim_sora_three_interview_profile_revision(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry
  );
  IF v_row.outcome IS DISTINCT FROM 'already_completed' THEN
    RAISE EXCEPTION 'FAIL SQL38f: completed revision can be reclaimed';
  END IF;
  SELECT * INTO v_row FROM public.complete_sora_three_interview_profile_revision(
    'd327a193-9eeb-42b1-bac4-fb5bea3ca21f', v_expiry, v_source_id, v_source_version, v_candidate
  );
  IF v_row.outcome IS DISTINCT FROM 'already_completed' THEN
    RAISE EXCEPTION 'FAIL SQL38f: duplicate completion was not idempotent';
  END IF;

  IF EXISTS (
    SELECT id, persona_id, section_id, content, source FROM public.persona_sections
     WHERE persona_id = '11000000-0000-0000-0000-00000000c384'
    EXCEPT SELECT id, persona_id, section_id, content, source FROM sora_old_wingfox_snapshot
  ) OR EXISTS (
    SELECT id, persona_id, section_id, content, source FROM sora_old_wingfox_snapshot
    EXCEPT SELECT id, persona_id, section_id, content, source FROM public.persona_sections
     WHERE persona_id = '11000000-0000-0000-0000-00000000c384'
  ) THEN RAISE EXCEPTION 'FAIL SQL38g: original Wingfox sections changed'; END IF;
  IF EXISTS (
    SELECT id, user_id, persona_id, status, message_count, completed_at FROM public.speed_dating_sessions
     WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f' AND status = 'active'
    EXCEPT SELECT id, user_id, persona_id, status, message_count, completed_at FROM sora_active_session_snapshot
  ) OR EXISTS (
    SELECT id, user_id, persona_id, status, message_count, completed_at FROM sora_active_session_snapshot
    EXCEPT SELECT id, user_id, persona_id, status, message_count, completed_at FROM public.speed_dating_sessions
     WHERE user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f' AND status = 'active'
  ) THEN RAISE EXCEPTION 'FAIL SQL38g: existing active interview rows changed'; END IF;
END $$;

RESET ROLE;

DO $$
DECLARE
  v_snapshot jsonb;
  v_expected_snapshot jsonb;
  v_run record;
BEGIN
  SELECT run_row.source_snapshot INTO v_snapshot
    FROM public.sora_profile_revision_runs AS run_row
   WHERE run_row.user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f';
  SELECT pg_catalog.to_jsonb(old_row) INTO v_expected_snapshot
    FROM sora_old_profile_snapshot AS old_row;
  IF v_snapshot IS DISTINCT FROM v_expected_snapshot THEN
    RAISE EXCEPTION 'FAIL SQL38h: original full profile snapshot was not retained';
  END IF;
  SELECT run_row.* INTO v_run
    FROM public.sora_profile_revision_runs AS run_row
   WHERE run_row.user_id = 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f';
  IF v_run.source_profile_id IS DISTINCT FROM '30000000-0000-0000-0000-00000000c381'::uuid
     OR v_run.source_version IS DISTINCT FROM 7
     OR v_run.target_version IS DISTINCT FROM 8
     OR v_run.session_ids IS DISTINCT FROM ARRAY[
       '20000000-0000-0000-0000-00000000c381'::uuid,
       '20000000-0000-0000-0000-00000000c382'::uuid,
       '20000000-0000-0000-0000-00000000c383'::uuid
     ] THEN
    RAISE EXCEPTION 'FAIL SQL38h: durable run ledger does not preserve the source and frozen session set';
  END IF;
END $$;

ROLLBACK;
