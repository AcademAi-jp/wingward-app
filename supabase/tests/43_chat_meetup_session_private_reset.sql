-- SQL43: synthetic lifecycle regression. No provider or client E2E is claimed.
-- Runs on the historical Google contract and the current time-only contract.
BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL TIME ZONE 'UTC';

-- An invoker trigger has no standalone client RPC capability or extra grants.
DO $$
DECLARE f oid := 'wingward_private.reset_chat_meetup_session_decisions()'::regprocedure;
BEGIN
  IF (SELECT prosecdef OR NOT proconfig @> ARRAY['search_path=""'] FROM pg_proc WHERE oid=f)
    OR has_function_privilege('anon', f, 'EXECUTE')
    OR has_function_privilege('authenticated', f, 'EXECUTE')
    OR has_function_privilege('service_role', f, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL SQL43: trigger routine privilege boundary';
  END IF;
END $$;

-- Reads the real revision counters, then invokes the production RPC. Public
-- calls use service_role; optional cloned-core calls use the owner and false
-- admission (ordinary eligibility), explicitly testing the shared invariant.
CREATE FUNCTION pg_temp.meetup_step(p_room uuid, p_user uuid, p_action jsonb, p_core boolean DEFAULT false)
RETURNS TABLE(outcome text, meetup_id uuid, status text, revision integer, own_revision integer)
LANGUAGE plpgsql AS $$
DECLARE m uuid; r integer; o integer;
BEGIN
  SELECT match_id INTO m FROM public.direct_chat_rooms WHERE id=p_room;
  SELECT s.revision INTO r FROM public.chat_meetup_sessions s
    WHERE s.room_id=p_room ORDER BY created_at DESC, s.meetup_id DESC LIMIT 1;
  SELECT private_revision INTO o FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=p_user;
  IF p_core THEN
    RETURN QUERY EXECUTE 'SELECT * FROM wingward_private.demo_recording_core_apply_chat_meetup_action(false,$1,$2,$3,$4,$5,$6,$7)'
      USING p_room,p_user,coalesce(r,0),coalesce(o,0),gen_random_uuid(),repeat('a',64),p_action;
  ELSE
    SET LOCAL ROLE service_role;
    RETURN QUERY SELECT * FROM public.apply_chat_meetup_action(p_room,p_user,coalesce(r,0),coalesce(o,0),gen_random_uuid(),repeat('a',64),p_action);
    RESET ROLE;
  END IF;
END $$;

DO $$
DECLARE
  terminal text; reversed boolean; core boolean; cores boolean[] := ARRAY[false];
  a uuid; b uuid; actor uuid; peer uuid; m uuid; room uuid; old_id uuid; new_id uuid;
  r record; s public.chat_meetup_sessions; old_a integer; old_b integer;
  old_stamp timestamptz; old_b_stamp timestamptz; new_stamp timestamptz; time_id text; first_revision integer;
  v_count integer := 0;
BEGIN
  IF to_regprocedure('wingward_private.demo_recording_core_apply_chat_meetup_action(boolean,uuid,uuid,integer,integer,uuid,text,jsonb)') IS NOT NULL THEN
    cores := ARRAY[false,true];
  END IF;
  FOREACH core IN ARRAY cores LOOP
  FOREACH terminal IN ARRAY ARRAY['completed','expired'] LOOP
  FOREACH reversed IN ARRAY ARRAY[false,true] LOOP
    a:=gen_random_uuid(); b:=gen_random_uuid(); m:=gen_random_uuid(); room:=gen_random_uuid();
    IF a>b THEN actor:=a; a:=b; b:=actor; END IF;
    -- Auth trigger creates the profiles. All locations, intervals and identity
    -- verification below are explicit synthetic prerequisites in this rollback.
    INSERT INTO auth.users(id,email) VALUES(a,a::text||'@example.invalid'),(b,b::text||'@example.invalid');
    UPDATE public.user_profiles SET id=auth_user_id, nickname='SQL43 synthetic',
      birth_date='1990-01-01',age_verified_at=now(),age_verification_method='self_declared',
      timezone='UTC',identity_verification_status='verified',identity_verified_at=now(),
      dating_market='JP',gender_identity='woman',preferred_genders=ARRAY['woman'],
      preference_mode='selected',onboarding_settings_completed_at=now()
      WHERE auth_user_id IN(a,b);
    INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES(m,a,b,'direct_chat_active');
    INSERT INTO public.direct_chat_rooms(id,match_id,status) VALUES(room,m,'active');
    SELECT * INTO r FROM pg_temp.meetup_step(room,a,'{"type":"intent","value":"yes"}',core);
    IF r.outcome IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'FAIL SQL43: S1 first intent %',r.outcome; END IF;
    SELECT * INTO r FROM pg_temp.meetup_step(room,b,'{"type":"intent","value":"yes"}',core);
    IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'awaiting_availability' THEN
      RAISE EXCEPTION 'FAIL SQL43: S1 second intent %',r.outcome;
    END IF;
    old_id:=r.meetup_id;
    UPDATE public.chat_meetup_sessions SET created_at=now()-interval '1 day' WHERE meetup_id=old_id;
    IF terminal='completed' THEN
      -- Real mutual completion, after a synthetic elapsed confirmed interval.
      UPDATE public.chat_meetup_sessions SET status='confirmed',expires_at=NULL,
        confirmed_starts_at=now()-interval '3 hours',confirmed_ends_at=now()-interval '2 hours',confirmed_timezone='UTC'
        WHERE meetup_id=old_id;
      UPDATE public.meetups SET status='confirmed' WHERE id=old_id;
      SELECT * INTO r FROM pg_temp.meetup_step(room,a,'{"type":"meeting.complete"}',core);
      IF r.outcome IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'FAIL SQL43: S1 completion A'; END IF;
      SELECT * INTO r FROM pg_temp.meetup_step(room,b,'{"type":"meeting.complete"}',core);
      IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'FAIL SQL43: S1 completion B';
      END IF;
      -- Historical completion uses transaction now(). Model elapsed time by
      -- backdating only this synthetic, genuinely completed S1, so S2 must
      -- receive a newer stamp even when both lifecycles share one rollback.
      UPDATE public.chat_meetup_private_decisions
        SET completed_at=completed_at-interval '1 day' WHERE match_id=m;
      UPDATE public.chat_meetup_sessions
        SET completed_a_at=completed_a_at-interval '1 day',
            completed_b_at=completed_b_at-interval '1 day' WHERE meetup_id=old_id;
    ELSE
      UPDATE public.chat_meetup_sessions SET expires_at=now()-interval '1 minute' WHERE meetup_id=old_id;
      SET LOCAL ROLE service_role;
      SELECT * INTO r FROM public.expire_chat_meetup_session(room,a);
      RESET ROLE;
      IF r.outcome IS DISTINCT FROM 'expired' THEN RAISE EXCEPTION 'FAIL SQL43: S1 expiry'; END IF;
    END IF;
    -- Stable Google ids can genuinely recur. Current time IDs are fresh UUIDs;
    -- the old value is deliberately different from the later new proposal.
    UPDATE public.chat_meetup_private_decisions SET time_choice_id='old-time',cafe_choice_id='google:RepeatedPlaceP'
      WHERE match_id=m;
    SELECT completed_at,private_revision INTO old_stamp,old_a FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=a;
    SELECT completed_at,private_revision INTO old_b_stamp,old_b FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=b;
    actor:=CASE WHEN reversed THEN a ELSE b END;
    peer:=CASE WHEN reversed THEN b ELSE a END;
    SELECT * INTO r FROM pg_temp.meetup_step(room,peer,'{"type":"intent","value":"yes"}',core);
    IF r.outcome IS DISTINCT FROM 'ok' OR r.meetup_id IS NOT NULL THEN RAISE EXCEPTION 'FAIL SQL43: S2 first intent'; END IF;
    IF EXISTS(SELECT 1 FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=peer
      AND (time_choice_id IS NOT NULL OR cafe_choice_id IS NOT NULL OR completed_at IS NOT NULL)) THEN
      RAISE EXCEPTION 'FAIL SQL43: first intent retained old private decision';
    END IF;
    SELECT * INTO r FROM pg_temp.meetup_step(room,actor,'{"type":"intent","value":"yes"}',core);
    IF r.outcome IS DISTINCT FROM 'ok' OR r.meetup_id IS NULL OR r.meetup_id=old_id OR r.status IS DISTINCT FROM 'awaiting_availability' THEN
      RAISE EXCEPTION 'FAIL SQL43: S2 second intent';
    END IF;
    new_id:=r.meetup_id;
    IF (SELECT count(*) FROM public.chat_meetup_private_decisions WHERE match_id=m AND meetup_id=new_id
       AND time_choice_id IS NULL AND cafe_choice_id IS NULL AND completed_at IS NULL) <> 2 THEN
      RAISE EXCEPTION 'FAIL SQL43: new session retained actor or peer decision';
    END IF;
    IF (SELECT private_revision FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=a) <> old_a+1
      OR (SELECT private_revision FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=b) <> old_b+1 THEN
      RAISE EXCEPTION 'FAIL SQL43: session reset changed revision semantics';
    END IF;
    SET LOCAL ROLE service_role;
    SELECT * INTO r FROM public.get_meetup_reflection_state(new_id,actor);
    RESET ROLE;
    IF r.outcome IS DISTINCT FROM 'not_found' THEN RAISE EXCEPTION 'FAIL SQL43: premature reflection read'; END IF;
    SET LOCAL ROLE service_role;
    SELECT * INTO r FROM public.confirm_meetup_reflection(new_id,actor,gen_random_uuid(),0,'{"priority_value":"community"}');
    RESET ROLE;
    IF r.outcome IS DISTINCT FROM 'not_found' THEN RAISE EXCEPTION 'FAIL SQL43: premature reflection write %',r.outcome; END IF;
    SELECT * INTO r FROM pg_temp.meetup_step(room,actor,'{"type":"meeting.complete"}',core);
    IF r.outcome IS DISTINCT FROM 'invalid_state' THEN RAISE EXCEPTION 'FAIL SQL43: premature completion'; END IF;

    time_id:=gen_random_uuid()::text;
    UPDATE public.chat_meetup_sessions SET status='time_proposed',
      time_candidates=jsonb_build_array(jsonb_build_object('id',time_id,'starts_at',now()+interval '1 hour','ends_at',now()+interval '2 hours','timezone','UTC'))
      WHERE meetup_id=new_id;
    SELECT * INTO r FROM pg_temp.meetup_step(room,peer,jsonb_build_object('type','time.approve','candidate_id',time_id),core);
    IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'time_proposed' THEN
      RAISE EXCEPTION 'FAIL SQL43: single fresh time approval confirmed';
    END IF;
    first_revision:=r.own_revision;
    -- Explicit same-session meetup_id write must preserve a valid current vote.
    UPDATE public.chat_meetup_private_decisions SET meetup_id=new_id WHERE match_id=m AND user_id=peer;
    IF NOT EXISTS(SELECT 1 FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=peer
       AND time_choice_id=time_id AND private_revision=first_revision) THEN
      RAISE EXCEPTION 'FAIL SQL43: same session cleared current consent/revision';
    END IF;
    SELECT * INTO r FROM pg_temp.meetup_step(room,actor,jsonb_build_object('type','time.approve','candidate_id',time_id),core);
    IF r.outcome IS DISTINCT FROM 'ok' THEN RAISE EXCEPTION 'FAIL SQL43: mutual time consent'; END IF;
    IF r.status='awaiting_location' THEN
      -- Historical provider-free prerequisite setup, then REAL stable-id
      -- publication and approval RPCs. One new cafe approval must not confirm.
      INSERT INTO public.chat_meetup_locations(meetup_id,user_id,method,origin,consented_at,expires_at)
        VALUES(new_id,a,'station','{"kind":"station","name":"SQL43 Synthetic Station","walk_minutes":8}'::jsonb,now(),now()+interval '30 minutes'),(new_id,b,'station','{"kind":"station","name":"SQL43 Synthetic Station","walk_minutes":8}'::jsonb,now(),now()+interval '30 minutes');
      SELECT * INTO s FROM public.chat_meetup_sessions WHERE meetup_id=new_id;
      SELECT private_revision INTO old_a FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=a;
      SELECT private_revision INTO old_b FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=b;
      SET LOCAL ROLE service_role;
      SELECT * INTO r FROM public.publish_chat_meetup_google_cafes(room,a,s.revision,old_a,old_b,ARRAY['RepeatedPlaceP'],NULL);
      RESET ROLE;
      IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'cafe_proposed' THEN RAISE EXCEPTION 'FAIL SQL43: stable Google publication'; END IF;
      SELECT private_revision INTO old_a FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=peer;
      SET LOCAL ROLE service_role;
      SELECT * INTO r FROM public.apply_chat_meetup_google_cafe_action(room,peer,r.revision,old_a,gen_random_uuid(),repeat('c',64),'cafe.approve','google:RepeatedPlaceP');
      RESET ROLE;
      IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'cafe_proposed' THEN RAISE EXCEPTION 'FAIL SQL43: single fresh Google approval confirmed'; END IF;
      SELECT private_revision INTO old_a FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=actor;
      SET LOCAL ROLE service_role;
      SELECT * INTO r FROM public.apply_chat_meetup_google_cafe_action(room,actor,r.revision,old_a,gen_random_uuid(),repeat('d',64),'cafe.approve','google:RepeatedPlaceP');
      RESET ROLE;
    END IF;
    IF r.status IS DISTINCT FROM 'confirmed' THEN RAISE EXCEPTION 'FAIL SQL43: mutual fresh consent not confirmed'; END IF;
    -- Advance only the synthetic interval; real completion must stamp S2 anew.
    UPDATE public.chat_meetup_sessions SET confirmed_starts_at=now()-interval '3 hours',confirmed_ends_at=now()-interval '2 hours' WHERE meetup_id=new_id;
    SELECT * INTO r FROM pg_temp.meetup_step(room,a,'{"type":"meeting.complete"}',core);
    IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'confirmed' THEN RAISE EXCEPTION 'FAIL SQL43: fresh A completion'; END IF;
    SELECT completed_at INTO new_stamp FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=a;
    IF new_stamp IS NULL OR (old_stamp IS NOT NULL AND new_stamp <= old_stamp) THEN RAISE EXCEPTION 'FAIL SQL43: stale completion timestamp'; END IF;
    SELECT * INTO r FROM pg_temp.meetup_step(room,b,'{"type":"meeting.complete"}',core);
    IF r.outcome IS DISTINCT FROM 'ok' OR r.status IS DISTINCT FROM 'completed' THEN RAISE EXCEPTION 'FAIL SQL43: fresh mutual completion'; END IF;
    SELECT completed_at INTO new_stamp FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=b;
    IF new_stamp IS NULL OR (old_b_stamp IS NOT NULL AND new_stamp <= old_b_stamp) THEN
      RAISE EXCEPTION 'FAIL SQL43: stale B completion timestamp';
    END IF;
    SELECT * INTO s FROM public.chat_meetup_sessions WHERE meetup_id=new_id;
    IF s.completed_a_at IS DISTINCT FROM
        (SELECT completed_at FROM public.chat_meetup_private_decisions WHERE match_id=m AND user_id=a)
      OR s.completed_b_at IS DISTINCT FROM new_stamp THEN
      RAISE EXCEPTION 'FAIL SQL43: session completion timestamps disagree';
    END IF;
    v_count:=v_count+1;
  END LOOP;
  END LOOP;
  END LOOP;
  RAISE NOTICE 'SQL43 lifecycle cases passed: % (both intent orders, completed/expired, public/available cloned core)',v_count;
END $$;
ROLLBACK;
