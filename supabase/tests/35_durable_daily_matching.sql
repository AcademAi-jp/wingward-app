-- SQL35 verifies the durable matching fence, bounded worker surfaces, and ACLs.
-- Fixtures are synthetic and every database write is rolled back.
BEGIN;
SET LOCAL statement_timeout = '15s';

DO $$
DECLARE
  v_function oid;
  v_is_definer boolean;
  v_publish_definition text;
BEGIN
  FOREACH v_function IN ARRAY ARRAY[
    to_regprocedure('public.claim_durable_daily_matching_batch(date,text,text,integer,boolean)')::oid,
    to_regprocedure('public.scan_durable_daily_matching_member_page(uuid,uuid,bigint,uuid,integer)')::oid,
    to_regprocedure('public.read_durable_daily_matching_pair_page(uuid,uuid,bigint,uuid,uuid,integer)')::oid,
    to_regprocedure('public.stage_durable_daily_matching_candidate_page(uuid,uuid,bigint,uuid,uuid,uuid,uuid,jsonb,boolean)')::oid,
    to_regprocedure('public.release_durable_daily_matching_lease(uuid,uuid,bigint)')::oid,
    to_regprocedure('public.publish_durable_daily_matching_batch(uuid,uuid,bigint,integer)')::oid,
    to_regprocedure('public.get_durable_daily_matching_conversation_status(uuid)')::oid,
    to_regprocedure('public.claim_daily_matching_notification_outbox(integer,integer)')::oid,
    to_regprocedure('public.complete_daily_matching_notification_outbox(uuid,uuid,uuid,uuid,bigint,uuid)')::oid,
    to_regprocedure('public.release_daily_matching_notification_outbox(uuid,uuid,uuid,uuid,bigint)')::oid
  ] LOOP
    IF v_function IS NULL THEN
      RAISE EXCEPTION 'FAIL SQL35a: a durable matching RPC is missing';
    END IF;
    SELECT proc.prosecdef INTO v_is_definer
      FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function;
    IF NOT v_is_definer
       OR NOT COALESCE((SELECT proc.proconfig @> ARRAY['search_path=""']::text[]
                          FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function), false)
       OR has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('authenticated', v_function, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL SQL35b: durable matching RPCs must be SECURITY DEFINER, use an empty search_path, and allow service_role only';
    END IF;
  END LOOP;

  v_publish_definition := pg_catalog.pg_get_functiondef(
    to_regprocedure('public.publish_durable_daily_matching_batch(uuid,uuid,bigint,integer)')
  );
  IF pg_catalog.strpos(v_publish_definition, 'pg_advisory_xact_lock') = 0
     OR pg_catalog.strpos(v_publish_definition, 'lock_and_check_mutual_eligibility') = 0
     OR pg_catalog.strpos(v_publish_definition, 'eligibility_snapshot IS NOT DISTINCT FROM') = 0 THEN
    RAISE EXCEPTION 'FAIL SQL35p: publication must serialize batch dates and retain UUID-ordered mutual eligibility locking';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'public.daily_match_batches'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'wingward_private.daily_matching_batch_members'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'wingward_private.daily_matching_batch_candidates'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'wingward_private.daily_matching_notification_outbox'::regclass)
     OR NOT has_table_privilege('service_role', 'public.daily_match_batches', 'SELECT')
     OR has_table_privilege('service_role', 'public.daily_match_batches', 'INSERT')
     OR has_table_privilege('service_role', 'public.daily_match_batches', 'UPDATE')
     OR has_table_privilege('service_role', 'public.daily_match_batches', 'DELETE')
     OR has_table_privilege('service_role', 'wingward_private.daily_matching_batch_members', 'SELECT')
     OR has_table_privilege('service_role', 'wingward_private.daily_matching_batch_candidates', 'SELECT')
     OR has_table_privilege('service_role', 'wingward_private.daily_matching_notification_outbox', 'SELECT')
     OR has_table_privilege('anon', 'public.daily_match_batches', 'SELECT')
     OR has_table_privilege('authenticated', 'public.daily_match_batches', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL SQL35c: durable batch storage grants or RLS are too broad';
  END IF;
END $$;

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_batch_id uuid;
  v_token uuid;
  v_generation bigint;
  v_wrong_timezone jsonb;
  v_missing jsonb;
  v_first jsonb;
  v_duplicate jsonb;
  v_resumed jsonb;
  v_release boolean;
  v_rejected boolean := false;
  v_visible_matches integer;
  v_status jsonb;
  v_outbox jsonb;
BEGIN
  v_wrong_timezone := public.claim_durable_daily_matching_batch(
    DATE '2099-12-31', 'America/Los_Angeles', 'daily-matching-v1', 180, false
  );
  IF v_wrong_timezone ->> 'state' IS DISTINCT FROM 'incompatible'
     OR EXISTS (SELECT 1 FROM public.daily_match_batches WHERE batch_date = DATE '2099-12-31') THEN
    RAISE EXCEPTION 'FAIL SQL35d: non-Tokyo or incompatible batch requests must fail without creating a row';
  END IF;

  v_missing := public.claim_durable_daily_matching_batch(
    DATE '2099-12-30', 'Asia/Tokyo', 'daily-matching-v1', 180, true
  );
  IF v_missing ->> 'state' IS DISTINCT FROM 'not_started'
     OR EXISTS (SELECT 1 FROM public.daily_match_batches WHERE batch_date = DATE '2099-12-30') THEN
    RAISE EXCEPTION 'FAIL SQL35e: resume-only must not create an absent date';
  END IF;

  v_first := public.claim_durable_daily_matching_batch(
    DATE '2099-12-31', 'Asia/Tokyo', 'daily-matching-v1', 180, false
  );
  v_batch_id := (v_first ->> 'batch_id')::uuid;
  v_token := (v_first ->> 'lease_token')::uuid;
  v_generation := (v_first ->> 'lease_generation')::bigint;
  IF v_first ->> 'state' IS DISTINCT FROM 'claimed' OR v_token IS NULL OR v_generation <> 1 THEN
    RAISE EXCEPTION 'FAIL SQL35f: initial daily lease was not created';
  END IF;

  v_duplicate := public.claim_durable_daily_matching_batch(
    DATE '2099-12-31', 'Asia/Tokyo', 'daily-matching-v1', 180, false
  );
  IF v_duplicate ->> 'state' IS DISTINCT FROM 'busy'
     OR (v_duplicate ->> 'lease_generation')::bigint <> v_generation THEN
    RAISE EXCEPTION 'FAIL SQL35g: duplicate launch must observe the active lease';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.scan_durable_daily_matching_member_page(v_batch_id, v_token, v_generation, NULL, 101);
  EXCEPTION WHEN OTHERS THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'FAIL SQL35q: member page exceeded the 100-row cap'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.read_durable_daily_matching_pair_page(v_batch_id, v_token, v_generation, NULL, NULL, 101);
  EXCEPTION WHEN OTHERS THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'FAIL SQL35r: pair page exceeded the 100-row cap'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.stage_durable_daily_matching_candidate_page(
      v_batch_id, v_token, v_generation, NULL, NULL, NULL, NULL,
      (SELECT pg_catalog.jsonb_agg('{}'::jsonb) FROM pg_catalog.generate_series(1, 101)), false
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'FAIL SQL35s: staged candidate page exceeded the 100-row cap'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.scan_durable_daily_matching_member_page(
      v_batch_id, gen_random_uuid(), v_generation, NULL, 100
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL SQL35h: a stale fence advanced the member snapshot';
  END IF;

  SELECT count(*)::integer INTO v_visible_matches
    FROM public.matches WHERE batch_id = v_batch_id;
  IF v_visible_matches <> 0 THEN
    RAISE EXCEPTION 'FAIL SQL35i: unpublished batch matches became visible';
  END IF;

  v_status := public.get_durable_daily_matching_conversation_status(v_batch_id);
  IF v_status IS DISTINCT FROM '{"requested_count":0,"pending_count":0,"in_progress_count":0,"completed_count":0,"failed_count":0}'::jsonb THEN
    RAISE EXCEPTION 'FAIL SQL35j: an empty batch conversation status was not truthful';
  END IF;
  v_outbox := public.claim_daily_matching_notification_outbox(2, 120);
  IF v_outbox IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL SQL35k: no notification may be claimed before publication and conversation completion';
  END IF;

  v_release := public.release_durable_daily_matching_lease(v_batch_id, gen_random_uuid(), v_generation);
  IF v_release THEN RAISE EXCEPTION 'FAIL SQL35l: an old token released a current lease'; END IF;
  v_release := public.release_durable_daily_matching_lease(v_batch_id, v_token, v_generation);
  IF NOT v_release THEN RAISE EXCEPTION 'FAIL SQL35m: current lease release failed'; END IF;

  v_resumed := public.claim_durable_daily_matching_batch(
    DATE '2099-12-31', 'Asia/Tokyo', 'daily-matching-v1', 180, true
  );
  IF v_resumed ->> 'state' IS DISTINCT FROM 'claimed'
     OR (v_resumed ->> 'lease_generation')::bigint <> v_generation + 1 THEN
    RAISE EXCEPTION 'FAIL SQL35n: a released partial batch did not resume under a new fence';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.publish_durable_daily_matching_batch(
      v_batch_id, (v_resumed ->> 'lease_token')::uuid,
      (v_resumed ->> 'lease_generation')::bigint, 1
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'FAIL SQL35o: incomplete cursors reached atomic publication';
  END IF;
END $$;
RESET ROLE;

ROLLBACK;
