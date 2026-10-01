-- Private input storage regression; all users, rooms and payloads synthetic.
-- Historical location RPCs accept valid legacy consent. Current time-only
-- RPCs reject location actions. Both contracts retain guarded availability.
BEGIN;
SET LOCAL statement_timeout = '30s';
SET LOCAL TIME ZONE 'UTC';
CREATE FUNCTION pg_temp.validation_step(p_room uuid,p_user uuid,p_action jsonb,p_core boolean)
RETURNS TABLE(outcome text,meetup_id uuid,status text,revision integer,own_revision integer)
LANGUAGE plpgsql AS $$
DECLARE m uuid; r integer; o integer;
BEGIN
  SELECT match_id INTO m FROM public.direct_chat_rooms WHERE id=p_room;
  SELECT s.revision INTO r FROM public.chat_meetup_sessions s WHERE s.room_id=p_room ORDER BY s.created_at DESC,s.meetup_id DESC LIMIT 1;
  SELECT private_revision INTO o FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=p_user;
  IF p_core THEN
    RETURN QUERY EXECUTE 'SELECT * FROM wingward_private.demo_recording_core_apply_chat_meetup_action(false,$1,$2,$3,$4,$5,$6,$7)'
      USING p_room,p_user,coalesce(r,0),coalesce(o,0),gen_random_uuid(),repeat('e',64),p_action;
  ELSE
    SET LOCAL ROLE service_role;
    RETURN QUERY SELECT * FROM public.apply_chat_meetup_action(p_room,p_user,coalesce(r,0),coalesce(o,0),gen_random_uuid(),repeat('e',64),p_action);
    RESET ROLE;
  END IF;
END $$;
CREATE FUNCTION pg_temp.validation_snapshot(p_room uuid) RETURNS jsonb LANGUAGE sql AS $$
SELECT jsonb_build_object(
 'session',(SELECT jsonb_agg(to_jsonb(s) ORDER BY s.meetup_id) FROM public.chat_meetup_sessions s WHERE s.room_id=p_room),
 'decision',(SELECT jsonb_agg(to_jsonb(d) ORDER BY d.user_id) FROM public.chat_meetup_private_decisions d WHERE d.room_id=p_room),
 'location',(SELECT jsonb_agg(to_jsonb(l) ORDER BY l.user_id) FROM public.chat_meetup_locations l JOIN public.chat_meetup_sessions s ON s.meetup_id=l.meetup_id WHERE s.room_id=p_room),
 'availability',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.user_id) FROM public.chat_meetup_availability a JOIN public.chat_meetup_sessions s ON s.meetup_id=a.meetup_id WHERE s.room_id=p_room),
 'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM public.chat_meetup_events e JOIN public.chat_meetup_sessions s ON s.meetup_id=e.meetup_id WHERE s.room_id=p_room),
 'operations',(SELECT jsonb_agg(to_jsonb(o) ORDER BY o.idempotency_key) FROM public.chat_meetup_operations o WHERE o.room_id=p_room))
$$;
CREATE FUNCTION pg_temp.reject_input(p_room uuid,p_user uuid,p_action jsonb,p_core boolean,p_guard text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE before_state jsonb; r record; rejected boolean := false; guard text;
BEGIN
  before_state := pg_temp.validation_snapshot(p_room);
  BEGIN
    SELECT * INTO r FROM pg_temp.validation_step(p_room,p_user,p_action,p_core);
    rejected := r.outcome IN ('invalid_input','invalid_state');
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS guard = CONSTRAINT_NAME;
    IF guard IS DISTINCT FROM p_guard THEN RAISE EXCEPTION 'FAIL SQL44: unrelated check rejected input'; END IF;
    rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'FAIL SQL44: malformed private input accepted'; END IF;
  IF pg_temp.validation_snapshot(p_room) IS DISTINCT FROM before_state THEN
    RAISE EXCEPTION 'FAIL SQL44: rejected private input changed state';
  END IF;
END $$;
DO $$
DECLARE
 a uuid; b uuid; t uuid; m uuid; room uuid; id uuid; r record;
 core boolean; cores boolean[] := ARRAY[false]; action jsonb; v_origin jsonb; entry jsonb;
 start_at timestamptz := now()+interval '2 days'; end_at timestamptz := now()+interval '3 days';
 window_json jsonb; valid_interval jsonb; station jsonb; current_location_enabled boolean;
 before_state jsonb; rejected boolean; guard text; n integer:=0;
BEGIN
 IF to_regprocedure('wingward_private.demo_recording_core_apply_chat_meetup_action(boolean,uuid,uuid,integer,integer,uuid,text,jsonb)') IS NOT NULL THEN cores:=ARRAY[false,true]; END IF;
 -- Guards are invoker-only, not new client RPC capabilities.
 IF EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid IN (
   'wingward_private.validate_chat_meetup_location_input()'::regprocedure,
   'wingward_private.validate_chat_meetup_availability_input()'::regprocedure)
   AND (p.prosecdef OR NOT p.proconfig @> ARRAY['search_path=""'] OR
     has_function_privilege('anon',p.oid,'EXECUTE') OR has_function_privilege('authenticated',p.oid,'EXECUTE') OR has_function_privilege('service_role',p.oid,'EXECUTE'))) THEN
   RAISE EXCEPTION 'FAIL SQL44: private input guard privileges';
 END IF;
 window_json:=jsonb_build_object('starts_at',start_at,'ends_at',end_at);
 valid_interval:=window_json;
 station:='{"kind":"station","name":"SQL44 Synthetic Station","walk_minutes":8}'::jsonb;
 FOREACH core IN ARRAY cores LOOP
  a:=gen_random_uuid(); b:=gen_random_uuid(); IF a>b THEN t:=a;a:=b;b:=t; END IF;
  m:=gen_random_uuid();room:=gen_random_uuid();
  INSERT INTO auth.users(id,email) VALUES(a,a::text||'@example.invalid'),(b,b::text||'@example.invalid');
  UPDATE public.user_profiles SET id=auth_user_id,nickname='SQL44 synthetic',birth_date='1990-01-01',age_verified_at=now(),age_verification_method='self_declared',timezone='UTC',identity_verification_status='verified',identity_verified_at=now(),dating_market='JP',gender_identity='woman',preferred_genders=ARRAY['woman'],preference_mode='selected',onboarding_settings_completed_at=now() WHERE auth_user_id IN(a,b);
  INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES(m,a,b,'direct_chat_active');
  INSERT INTO public.direct_chat_rooms(id,match_id,status) VALUES(room,m,'active');
  SELECT * INTO r FROM pg_temp.validation_step(room,a,'{"type":"intent","value":"yes"}',core);
  IF r.outcome IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'FAIL SQL44: first intent'; END IF;
  SELECT * INTO r FROM pg_temp.validation_step(room,b,'{"type":"intent","value":"yes"}',core);
  IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'awaiting_availability' THEN RAISE EXCEPTION 'FAIL SQL44: mutual intent'; END IF;
  id:=r.meetup_id;

  -- Both busy/calendar and available/manual take the same storage validator.
  FOR entry IN SELECT value FROM jsonb_array_elements(jsonb_build_array(
   '{"x":"not an interval"}'::jsonb, '7'::jsonb,
   valid_interval||'{"note":"extra key"}'::jsonb,
   jsonb_build_object('starts_at',repeat('x',200000),'ends_at',end_at),
   jsonb_build_object('starts_at',42,'ends_at',end_at),
   jsonb_build_object('starts_at','2026-02-30T12:00:00Z','ends_at',end_at),
   jsonb_build_object('starts_at',to_char(start_at,'YYYY-MM-DD"T"HH24:MI:SS')||'+09:00','ends_at',end_at),
   jsonb_build_object('starts_at',end_at,'ends_at',start_at),
   jsonb_build_object('starts_at',start_at-interval '1 second','ends_at',end_at),
   jsonb_build_object('starts_at',start_at,'ends_at',end_at+interval '1 second'))) LOOP
   PERFORM pg_temp.reject_input(room,a,jsonb_build_object('type','availability.submit','source','manual','window',window_json,'available',jsonb_build_array(entry)),core,'chat_meetup_availability_input_guard');
   PERFORM pg_temp.reject_input(room,a,jsonb_build_object('type','availability.submit','source','calendar','window',window_json,'busy',jsonb_build_array(entry)),core,'chat_meetup_availability_input_guard');
  END LOOP;
  PERFORM pg_temp.reject_input(room,a,jsonb_build_object('type','availability.submit','source','manual','window',jsonb_build_object('starts_at',start_at,'ends_at',start_at+interval '22 days'),'available','[]'::jsonb),core,'chat_meetup_availability_input_guard');
  SELECT * INTO r FROM pg_temp.validation_step(room,a,jsonb_build_object('type','availability.submit','source','calendar','window',window_json,'busy',jsonb_build_array(valid_interval)),core);
  IF r.outcome IS DISTINCT FROM 'ok' OR NOT EXISTS(SELECT 1 FROM public.chat_meetup_availability WHERE meetup_id=id AND user_id=a AND source='calendar' AND intervals=jsonb_build_array(valid_interval)) THEN RAISE EXCEPTION 'FAIL SQL44: valid calendar input'; END IF;
  SELECT * INTO r FROM pg_temp.validation_step(room,b,jsonb_build_object('type','availability.submit','source','manual','window',window_json,'available',jsonb_build_array(valid_interval)),core);
  IF r.outcome IS DISTINCT FROM 'ok' OR NOT EXISTS(SELECT 1 FROM public.chat_meetup_availability WHERE meetup_id=id AND user_id=b AND source='manual' AND intervals=jsonb_build_array(valid_interval)) THEN RAISE EXCEPTION 'FAIL SQL44: valid manual input'; END IF;

  SELECT * INTO r FROM pg_temp.validation_step(room,a,jsonb_build_object('type','availability.submit','source','manual','window',jsonb_build_object('starts_at',now()-interval '2 days','ends_at',now()-interval '1 day'),'available','[]'::jsonb),core);
  IF r.outcome IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'FAIL SQL44: valid elapsed window rejected by storage guard'; END IF;

  -- Synthetic state prerequisite makes old location branch reachable. Current
  -- time-only RPC rejects location before any write even at this legacy state.
  UPDATE public.chat_meetup_sessions SET status='awaiting_location' WHERE meetup_id=id;
  before_state:=pg_temp.validation_snapshot(room);
  SELECT * INTO r FROM pg_temp.validation_step(room,a,jsonb_build_object('type','location.submit','location',station),core);
  current_location_enabled:=r.outcome='ok';
  IF NOT current_location_enabled AND r.outcome IS DISTINCT FROM 'invalid_input' THEN RAISE EXCEPTION 'FAIL SQL44: unknown location contract'; END IF;
  IF NOT current_location_enabled AND pg_temp.validation_snapshot(room) IS DISTINCT FROM before_state THEN RAISE EXCEPTION 'FAIL SQL44: current location rejection changed state'; END IF;
  IF current_location_enabled THEN
   IF NOT EXISTS(SELECT 1 FROM public.chat_meetup_locations WHERE meetup_id=id AND user_id=a AND method='station' AND origin=station) THEN RAISE EXCEPTION 'FAIL SQL44: valid station consent'; END IF;
   SELECT * INTO r FROM pg_temp.validation_step(room,a,'{"type":"location.submit","location":{"kind":"coordinates","lat":35.681,"lng":139.767}}',core);
   IF r.outcome IS DISTINCT FROM 'ok' OR NOT EXISTS(SELECT 1 FROM public.chat_meetup_locations WHERE meetup_id=id AND user_id=a AND method='current' AND origin='{"kind":"coordinates","lat":35.681,"lng":139.767}'::jsonb) THEN RAISE EXCEPTION 'FAIL SQL44: valid coarse coordinates consent'; END IF;
  END IF;
  FOR v_origin IN SELECT value FROM jsonb_array_elements(jsonb_build_array(
   '{}'::jsonb,'{"kind":"unknown"}'::jsonb,
   station||'{"lat":35.681,"lng":139.767}'::jsonb,
   station||jsonb_build_object('note',repeat('x',200000)),
   station||jsonb_build_object('name',repeat('x',121)),
   station||'{"walk_minutes":1.5}'::jsonb,
   station||'{"walk_minutes":121}'::jsonb,
   station||'{"name":""}'::jsonb,
   '{"kind":"coordinates","lat":"35.681","lng":139.767}'::jsonb,
   '{"kind":"coordinates","lat":91,"lng":139.767}'::jsonb,
   '{"kind":"coordinates","lat":35.681001,"lng":139.767}'::jsonb)) LOOP
   PERFORM pg_temp.reject_input(room,a,jsonb_build_object('type','location.submit','location',v_origin),core,'chat_meetup_location_input_guard');
  END LOOP;
  -- Table backstop remains active even when current RPC rejects this feature.
  before_state:=pg_temp.validation_snapshot(room); rejected:=false;
  BEGIN
   INSERT INTO public.chat_meetup_locations(meetup_id,user_id,method,origin,expires_at) VALUES(id,b,'current',station,now()+interval '30 minutes')
   ON CONFLICT(meetup_id,user_id) DO UPDATE SET method=excluded.method,origin=excluded.origin;
  EXCEPTION WHEN check_violation THEN GET STACKED DIAGNOSTICS guard=CONSTRAINT_NAME; rejected:=guard='chat_meetup_location_input_guard'; END;
  IF NOT rejected OR pg_temp.validation_snapshot(room) IS DISTINCT FROM before_state THEN RAISE EXCEPTION 'FAIL SQL44: consent method mismatched origin'; END IF;
  n:=n+1;
 END LOOP;
 RAISE NOTICE 'SQL44 private input contracts passed: % (public/available cloned core, real RPC rejection and no mutation)',n;
END $$;
ROLLBACK;
