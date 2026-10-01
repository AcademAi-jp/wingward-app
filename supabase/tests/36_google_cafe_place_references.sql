-- SQL36 Google cafe references: persisted fields contain only exempt Place IDs and operation times.
-- No provider account, network, credentials, or durable Google place content is used.
BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL TIME ZONE 'UTC';

DO $$
DECLARE
  v_function oid;
  v_function_name text;
  v_attnotnull boolean;
  v_default text;
BEGIN
  IF NOT public.chat_meetup_google_references_valid('[]'::jsonb)
     OR NOT public.chat_meetup_google_references_valid(
       '[{"place_id":"ChIJsynthetic123","proposed_at":"2026-09-26T13:26:09.123Z"}]'::jsonb
     ) THEN
    RAISE EXCEPTION 'FAIL SQL36a: valid reference-only payload was rejected';
  END IF;

  IF public.chat_meetup_google_references_valid(
       '[{"place_id":"ChIJsynthetic123","proposed_at":"2026-09-26T13:26:09.123Z","name":"Cafe"}]'::jsonb
     )
     OR public.chat_meetup_google_references_valid(
       '[{"place_id":"ChIJsynthetic123","proposed_at":"2026-09-26T13:26:09.123Z","address":"Private address"}]'::jsonb
     )
     OR public.chat_meetup_google_references_valid(
       '[{"place_id":"ChIJsynthetic123","proposed_at":"2026-09-26T13:26:09.123Z","currentOpeningHours":{}}]'::jsonb
     )
     OR public.chat_meetup_google_references_valid(
       '[{"place_id":"ChIJsynthetic123","proposed_at":"2026-09-26T13:26:09.123Z","travel_minutes_first":0}]'::jsonb
     )
     OR public.chat_meetup_google_references_valid(
       '[{"place_id":"ChIJsynthetic123","proposed_at":"2026-09-26T13:26:09.123Z"},{"place_id":"ChIJsynthetic123","proposed_at":"2026-09-26T13:26:09.123Z"}]'::jsonb
     )
     OR public.chat_meetup_google_references_valid(
       '[{"place_id":"bad/id","proposed_at":"2026-09-26T13:26:09.123Z"}]'::jsonb
     )
     OR public.chat_meetup_google_references_valid(
       '[{"place_id":"ChIJ1","proposed_at":"2026-09-26T13:26:09.123Z"},{"place_id":"ChIJ2","proposed_at":"2026-09-26T13:26:09.123Z"},{"place_id":"ChIJ3","proposed_at":"2026-09-26T13:26:09.123Z"},{"place_id":"ChIJ4","proposed_at":"2026-09-26T13:26:09.123Z"}]'::jsonb
     ) THEN
    RAISE EXCEPTION 'FAIL SQL36b: provider content, malformed IDs, duplicate IDs, or excess references were accepted';
  END IF;

  SELECT attribute.attnotnull, pg_catalog.pg_get_expr(default_value.adbin, default_value.adrelid)
    INTO v_attnotnull, v_default
    FROM pg_catalog.pg_attribute AS attribute
    LEFT JOIN pg_catalog.pg_attrdef AS default_value
      ON default_value.adrelid = attribute.attrelid AND default_value.adnum = attribute.attnum
   WHERE attribute.attrelid = 'public.chat_meetup_sessions'::regclass
     AND attribute.attname = 'google_cafe_references'
     AND NOT attribute.attisdropped;
  IF v_attnotnull IS DISTINCT FROM true
     OR v_default IS DISTINCT FROM (pg_catalog.chr(39) || '[]' || pg_catalog.chr(39) || '::jsonb') THEN
    RAISE EXCEPTION 'FAIL SQL36c: reference-only column must be NOT NULL and default to an empty list';
  END IF;

  FOREACH v_function_name IN ARRAY ARRAY[
    'public.publish_chat_meetup_google_cafes(uuid,uuid,integer,integer,integer,text[],text)',
    'public.apply_chat_meetup_google_cafe_action(uuid,uuid,integer,integer,uuid,text,text,text)'
  ] LOOP
    v_function := pg_catalog.to_regprocedure(v_function_name)::oid;
    IF v_function IS NULL
       OR NOT COALESCE((SELECT proc.prosecdef FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function), false)
       OR NOT COALESCE((SELECT proc.proconfig @> ARRAY['search_path=""']::text[] FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_function), false)
       OR has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('authenticated', v_function, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL SQL36d: Google reference RPC must be empty-search-path SECURITY DEFINER and service-role-only';
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger AS trigger_row
     WHERE trigger_row.tgrelid = 'public.chat_meetup_sessions'::regclass
       AND trigger_row.tgname = 'chat_meetup_sessions_clear_stale_google_cafe_references'
       AND NOT trigger_row.tgisinternal
       AND trigger_row.tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'FAIL SQL36e: session transitions must clear stale place references';
  END IF;
END $$;

-- The current time-only planner no longer routes time approval into Google
-- cafes. These synthetic historical prerequisites exercise the retained Google
-- RPC/trigger contract on both schema prefixes, not a current provider/client
-- request path. Every fixture and write is rolled back with this test.
CREATE FUNCTION pg_temp.google_reference_step(p_room uuid, p_user uuid, p_action jsonb)
RETURNS TABLE(outcome text, meetup_id uuid, status text, revision integer, own_revision integer)
LANGUAGE plpgsql AS $$
DECLARE m uuid; r integer; o integer;
BEGIN
  SELECT match_id INTO m FROM public.direct_chat_rooms WHERE id=p_room;
  SELECT s.revision INTO r FROM public.chat_meetup_sessions s
    WHERE s.room_id=p_room ORDER BY created_at DESC, s.meetup_id DESC LIMIT 1;
  SELECT private_revision INTO o FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=p_user;
  SET LOCAL ROLE service_role;
  RETURN QUERY SELECT * FROM public.apply_chat_meetup_action(
    p_room,p_user,coalesce(r,0),coalesce(o,0),gen_random_uuid(),repeat('a',64),p_action);
  RESET ROLE;
END $$;

DO $$
DECLARE
  test_case text; a uuid; b uuid; swap uuid; m uuid; room uuid; id uuid;
  r record; s public.chat_meetup_sessions; ra integer; rb integer;
  proposed jsonb; expected jsonb; candidate jsonb; place_ids text[];
  historical_google boolean; before_rejection jsonb;
  checks integer := 0;
BEGIN
  FOREACH test_case IN ARRAY ARRAY[
    'mutual_single_rpc', 'mutual_subset_rpc', 'foreign_confirmation',
    'multiple_confirmation', 'empty_confirmation', 'replan_rpc',
    'time_candidates_changed', 'selected_time_changed', 'terminal_transition',
    'unchanged_proposal', 'unchanged_confirmed'
  ] LOOP
    a:=gen_random_uuid(); b:=gen_random_uuid(); m:=gen_random_uuid(); room:=gen_random_uuid();
    IF a>b THEN swap:=a; a:=b; b:=swap; END IF;
    INSERT INTO auth.users(id,email) VALUES(a,a::text||'@example.invalid'),(b,b::text||'@example.invalid');
    UPDATE public.user_profiles SET id=auth_user_id,nickname='SQL36 synthetic',
      birth_date='1990-01-01',age_verified_at=now(),age_verification_method='self_declared',
      timezone='UTC',identity_verification_status='verified',identity_verified_at=now(),
      dating_market='JP',gender_identity='woman',preferred_genders=ARRAY['woman'],
      preference_mode='selected',onboarding_settings_completed_at=now()
      WHERE auth_user_id IN(a,b);
    INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES(m,a,b,'direct_chat_active');
    INSERT INTO public.direct_chat_rooms(id,match_id,status) VALUES(room,m,'active');
    SELECT * INTO r FROM pg_temp.google_reference_step(room,a,'{"type":"intent","value":"yes"}');
    IF r.outcome IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'FAIL SQL36f: first intent %',r.outcome; END IF;
    SELECT * INTO r FROM pg_temp.google_reference_step(room,b,'{"type":"intent","value":"yes"}');
    IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'awaiting_availability' THEN
      RAISE EXCEPTION 'FAIL SQL36f: second intent %',r.outcome;
    END IF;
    id:=r.meetup_id;
    candidate:=jsonb_build_object('id','synthetic-time','starts_at',now()+interval '1 hour',
      'ends_at',now()+interval '2 hours','timezone','UTC');
    UPDATE public.chat_meetup_sessions SET status='time_proposed',
      time_candidates=jsonb_build_array(candidate)
      WHERE meetup_id=id;
    SELECT * INTO r FROM pg_temp.google_reference_step(room,a,'{"type":"time.approve","candidate_id":"synthetic-time"}');
    IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'time_proposed' THEN
      RAISE EXCEPTION 'FAIL SQL36f: first time consent';
    END IF;
    SELECT * INTO r FROM pg_temp.google_reference_step(room,b,'{"type":"time.approve","candidate_id":"synthetic-time"}');
    IF r.outcome IS DISTINCT FROM 'ok' OR r.status NOT IN ('awaiting_location','confirmed') THEN
      RAISE EXCEPTION 'FAIL SQL36f: unexpected time-approval contract';
    END IF;
    historical_google:=r.status='awaiting_location';
    -- The old contract arrives here naturally. For the time-only contract the
    -- following is an explicit synthetic legacy state, not a natural request.
    UPDATE public.chat_meetup_sessions SET status='awaiting_location',
      selected_time_candidate_id='synthetic-time',confirmed_starts_at=NULL,
      confirmed_ends_at=NULL,confirmed_timezone=NULL WHERE meetup_id=id;
    INSERT INTO public.chat_meetup_locations(meetup_id,user_id,method,origin,consented_at,expires_at)
      VALUES(id,a,'station','{"kind":"station","name":"SQL36 Synthetic Station","walk_minutes":8}',now(),now()+interval '30 minutes'),
            (id,b,'station','{"kind":"station","name":"SQL36 Synthetic Station","walk_minutes":8}',now(),now()+interval '30 minutes');
    SELECT * INTO s FROM public.chat_meetup_sessions WHERE meetup_id=id;
    SELECT private_revision INTO ra FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=a;
    SELECT private_revision INTO rb FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=b;
    place_ids:=CASE WHEN test_case IN ('mutual_subset_rpc','multiple_confirmation')
      THEN ARRAY['StablePlaceP','StablePlaceQ'] ELSE ARRAY['StablePlaceP'] END;
    SET LOCAL ROLE service_role;
    SELECT * INTO r FROM public.publish_chat_meetup_google_cafes(room,a,s.revision,ra,rb,place_ids,NULL);
    RESET ROLE;
    IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'cafe_proposed' THEN
      RAISE EXCEPTION 'FAIL SQL36g: actual stable-id publication %',r.outcome;
    END IF;
    SELECT google_cafe_references INTO proposed FROM public.chat_meetup_sessions WHERE meetup_id=id;
    SELECT jsonb_agg(jsonb_build_object('place_id',p,'proposed_at',to_char(now() AT TIME ZONE 'UTC',
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) ORDER BY ordinality)
      INTO expected FROM unnest(place_ids) WITH ORDINALITY AS place(p,ordinality);
    IF proposed IS DISTINCT FROM expected OR jsonb_array_length(proposed) <> cardinality(place_ids) THEN
      RAISE EXCEPTION 'FAIL SQL36g: publication must persist only exact place IDs and database operation times';
    END IF;

    IF test_case IN ('mutual_single_rpc','mutual_subset_rpc','unchanged_confirmed') THEN
      SELECT to_jsonb(session_row) INTO before_rejection FROM public.chat_meetup_sessions session_row WHERE meetup_id=id;
      SELECT private_revision INTO ra FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=a;
      SET LOCAL ROLE service_role;
      SELECT * INTO r FROM public.apply_chat_meetup_google_cafe_action(
        room,a,r.revision,ra,gen_random_uuid(),repeat('b',64),'cafe.approve','google:StablePlaceP');
      RESET ROLE;
      IF NOT historical_google THEN
        IF r.outcome IS DISTINCT FROM 'invalid_input'
          OR (SELECT to_jsonb(session_row) FROM public.chat_meetup_sessions session_row WHERE meetup_id=id)
             IS DISTINCT FROM before_rejection THEN
          RAISE EXCEPTION 'FAIL SQL36h: current time-only must reject legacy cafe approval without session mutation (%)',r.outcome;
        END IF;
        -- The retained trigger is still exercised against a valid contained
        -- singleton; this is a direct synthetic table transition, not approval.
        UPDATE public.chat_meetup_sessions SET status='confirmed',expires_at=NULL,
          confirmed_starts_at=now()+interval '1 hour',confirmed_ends_at=now()+interval '2 hours',confirmed_timezone='UTC',
          google_cafe_references=jsonb_build_array(proposed->0) WHERE meetup_id=id;
      ELSE
      IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'cafe_proposed'
        OR (SELECT google_cafe_references FROM public.chat_meetup_sessions WHERE meetup_id=id) IS DISTINCT FROM proposed THEN
        RAISE EXCEPTION 'FAIL SQL36h: one consent must preserve the proposal without confirmation';
      END IF;
      SELECT private_revision INTO rb FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=b;
      SET LOCAL ROLE service_role;
      SELECT * INTO r FROM public.apply_chat_meetup_google_cafe_action(
        room,b,r.revision,rb,gen_random_uuid(),repeat('c',64),'cafe.approve','google:StablePlaceP');
      RESET ROLE;
      END IF;
      SELECT * INTO s FROM public.chat_meetup_sessions WHERE meetup_id=id;
      IF (historical_google AND (r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'confirmed'))
        OR s.status IS DISTINCT FROM 'confirmed'
        OR jsonb_array_length(s.google_cafe_references) <> 1
        OR s.google_cafe_references IS DISTINCT FROM jsonb_build_array(proposed->0)
        OR NOT proposed @> s.google_cafe_references THEN
        RAISE EXCEPTION 'FAIL SQL36i: mutual approval must retain exactly one contained reference';
      END IF;
      IF test_case='unchanged_confirmed' THEN
        UPDATE public.chat_meetup_sessions SET revision=revision+1 WHERE meetup_id=id;
        IF (SELECT google_cafe_references FROM public.chat_meetup_sessions WHERE meetup_id=id)
          IS DISTINCT FROM s.google_cafe_references THEN
          RAISE EXCEPTION 'FAIL SQL36j: unchanged confirmed reference was discarded';
        END IF;
      END IF;
    ELSIF test_case IN ('foreign_confirmation','multiple_confirmation','empty_confirmation') THEN
      UPDATE public.chat_meetup_sessions SET status='confirmed',expires_at=NULL,
        confirmed_starts_at=now()+interval '1 hour',confirmed_ends_at=now()+interval '2 hours',confirmed_timezone='UTC',
        google_cafe_references=CASE test_case
          WHEN 'foreign_confirmation' THEN jsonb_build_array(jsonb_set(proposed->0,'{place_id}','"UnproposedPlace"'::jsonb))
          WHEN 'multiple_confirmation' THEN proposed ELSE '[]'::jsonb END
        WHERE meetup_id=id;
      IF (SELECT google_cafe_references FROM public.chat_meetup_sessions WHERE meetup_id=id) IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL SQL36k: confirmation retained a reference outside the one-contained-reference rule (%)',test_case;
      END IF;
    ELSIF test_case='replan_rpc' THEN
      SELECT * INTO r FROM pg_temp.google_reference_step(room,a,'{"type":"replan"}');
      IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'awaiting_availability'
        OR (SELECT google_cafe_references FROM public.chat_meetup_sessions WHERE meetup_id=id) IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'FAIL SQL36l: actual replan retained Google references';
      END IF;
    ELSE
      IF test_case='time_candidates_changed' THEN
        UPDATE public.chat_meetup_sessions SET time_candidates=jsonb_build_array(
          jsonb_set(candidate,'{ends_at}',to_jsonb(now()+interval '3 hours'))) WHERE meetup_id=id;
      ELSIF test_case='selected_time_changed' THEN
        UPDATE public.chat_meetup_sessions SET selected_time_candidate_id='different-time' WHERE meetup_id=id;
      ELSIF test_case='terminal_transition' THEN
        UPDATE public.chat_meetup_sessions SET status='cancelled' WHERE meetup_id=id;
      ELSE
        UPDATE public.chat_meetup_sessions SET revision=revision+1 WHERE meetup_id=id;
      END IF;
      expected:=CASE WHEN test_case='unchanged_proposal' THEN proposed ELSE '[]'::jsonb END;
      IF (SELECT google_cafe_references FROM public.chat_meetup_sessions WHERE meetup_id=id) IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL SQL36m: reference transition policy not enforced (%)',test_case;
      END IF;
    END IF;
    checks:=checks+1;
  END LOOP;
  RAISE NOTICE 'SQL36 reference lifecycle cases passed: %',checks;
END $$;

ROLLBACK;
