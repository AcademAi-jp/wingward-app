-- SQL46: real service-role janitor, synthetic owner-created rollback fixtures.
-- Extra nonparticipant input rows exercise a structural budget, not an account exploit.
BEGIN;
SET LOCAL statement_timeout = '30s';
SET LOCAL TIME ZONE 'UTC';
CREATE TEMP TABLE sql46_users AS SELECT i, gen_random_uuid() AS id FROM generate_series(1,260) i;
INSERT INTO auth.users(id,email) SELECT id,id::text||'@example.invalid' FROM sql46_users;
UPDATE public.user_profiles SET id=auth_user_id,nickname='SQL46 synthetic',
 birth_date='1990-01-01',age_verified_at=now(),age_verification_method='self_declared',
 timezone='UTC',identity_verification_status='verified',identity_verified_at=now(),
 dating_market='JP',gender_identity='woman',preferred_genders=ARRAY['woman'],
 preference_mode='selected',onboarding_settings_completed_at=now()
 WHERE auth_user_id IN(SELECT id FROM sql46_users);
CREATE TEMP TABLE sql46_matches(id uuid);
CREATE FUNCTION pg_temp.sql46_session(p_status text,p_expires timestamptz)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE a uuid; b uuid; pair_index integer; m uuid:=gen_random_uuid(); r uuid:=gen_random_uuid(); s uuid:=gen_random_uuid();
BEGIN
 SELECT count(*)+1 INTO pair_index FROM sql46_matches;
 SELECT least(x.id,y.id),greatest(x.id,y.id) INTO a,b FROM sql46_users x,sql46_users y WHERE x.i=pair_index*2-1 AND y.i=pair_index*2;
 INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES(m,a,b,'direct_chat_active');
 INSERT INTO sql46_matches VALUES(m);
 INSERT INTO public.direct_chat_rooms(id,match_id,status) VALUES(r,m,'active');
 INSERT INTO public.meetups(id,match_id,initiator_id,status,intent_expires_at,proposal_expires_at)
 VALUES(s,m,a,'arranging',now()+interval '1 day',now()+interval '1 day');
 INSERT INTO public.chat_meetup_sessions(meetup_id,match_id,room_id,user_a_id,user_b_id,status,revision,expires_at,
 time_choice_a,time_choice_b,cafe_choice_a,cafe_choice_b,selected_time_candidate_id,time_candidates,cafe_candidates)
 VALUES(s,m,r,a,b,p_status,3,p_expires,'old-time','old-time','old-cafe','old-cafe','old-time',
 '[{"id":"old-time"}]','[{"id":"old-cafe"}]');
 RETURN s;
END $$;
CREATE FUNCTION pg_temp.sql46_inputs(p_session uuid,p_count integer,p_expires timestamptz)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 INSERT INTO public.chat_meetup_availability(meetup_id,user_id,source,window_starts_at,window_ends_at,intervals,created_at,expires_at)
 SELECT p_session,id,'manual',now(),now()+interval '1 hour','[]',now(),p_expires FROM (SELECT u.id FROM sql46_users u WHERE
  (p_count>2 AND u.i<=p_count) OR (p_count<=2 AND u.id IN
   (SELECT user_a_id FROM public.chat_meetup_sessions WHERE meetup_id=p_session
    UNION ALL SELECT user_b_id FROM public.chat_meetup_sessions WHERE meetup_id=p_session))
  ORDER BY u.id LIMIT p_count) picked;
 INSERT INTO public.chat_meetup_locations(meetup_id,user_id,method,origin,consented_at,expires_at)
 SELECT p_session,id,'current','{"kind":"coordinates","lat":35.0,"lng":139.0}',now(),p_expires FROM (SELECT u.id FROM sql46_users u WHERE
  (p_count>2 AND u.i<=p_count) OR (p_count<=2 AND u.id IN
   (SELECT user_a_id FROM public.chat_meetup_sessions WHERE meetup_id=p_session
    UNION ALL SELECT user_b_id FROM public.chat_meetup_sessions WHERE meetup_id=p_session))
  ORDER BY u.id LIMIT p_count) picked;
END $$;
CREATE FUNCTION pg_temp.sql46_reset() RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 DELETE FROM public.matches WHERE id IN(SELECT id FROM sql46_matches);
 DELETE FROM sql46_matches;
END $$;
DO $$
DECLARE s uuid; t uuid; n integer; remaining integer; events_before integer; srow public.chat_meetup_sessions;
BEGIN
 -- ACL and routine fencing continue to be real, even though the body changes.
 IF (SELECT NOT prosecdef OR NOT proconfig @> ARRAY['search_path=""'] FROM pg_proc
 WHERE oid='public.prune_chat_meetup_private_inputs()'::regprocedure)
 OR has_function_privilege('anon','public.prune_chat_meetup_private_inputs()','EXECUTE')
 OR has_function_privilege('authenticated','public.prune_chat_meetup_private_inputs()','EXECUTE')
 OR NOT has_function_privilege('service_role','public.prune_chat_meetup_private_inputs()','EXECUTE') THEN
 RAISE EXCEPTION 'FAIL SQL46 ACL boundary'; END IF;

 -- An abandoned plan needs neither another participant action nor an HTTP read.
 s:=pg_temp.sql46_session('awaiting_location',now()-interval '1 minute');
 PERFORM pg_temp.sql46_inputs(s,2,now()-interval '1 minute');
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>4 OR EXISTS(SELECT 1 FROM public.chat_meetup_availability WHERE meetup_id=s)
 OR EXISTS(SELECT 1 FROM public.chat_meetup_locations WHERE meetup_id=s) THEN
 RAISE EXCEPTION 'FAIL SQL46 abandoned plan private inputs or returned count'; END IF;
 SELECT * INTO srow FROM public.chat_meetup_sessions WHERE meetup_id=s;
 IF srow.status<>'expired' OR srow.revision<>4 OR srow.expires_at IS NOT NULL
 OR srow.time_candidates<>'[]' OR srow.cafe_candidates<>'[]'
 OR srow.time_choice_a IS NOT NULL OR srow.time_choice_b IS NOT NULL
 OR srow.cafe_choice_a IS NOT NULL OR srow.cafe_choice_b IS NOT NULL
 OR srow.selected_time_candidate_id IS NOT NULL THEN
 RAISE EXCEPTION 'FAIL SQL46 terminalization clears shared projection'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.meetups WHERE id=s AND status='expired'
 AND intent_expires_at IS NULL AND proposal_expires_at IS NULL) THEN
 RAISE EXCEPTION 'FAIL SQL46 legacy terminalization'; END IF;
 IF (SELECT count(*) FROM public.chat_meetup_events WHERE meetup_id=s AND revision=4
 AND event_key='state:expired:4' AND kind='system'
 AND text='This meetup plan expired. You can start another plan.')<>1 THEN
 RAISE EXCEPTION 'FAIL SQL46 terminalization event'; END IF;
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>0 OR (SELECT revision FROM public.chat_meetup_sessions WHERE meetup_id=s)<>4
 OR (SELECT count(*) FROM public.chat_meetup_events WHERE meetup_id=s)<>1 THEN
 RAISE EXCEPTION 'FAIL SQL46 retry duplicated expiry event/revision'; END IF;
 PERFORM pg_temp.sql46_reset();

 -- TTL expiry is independent of a still-active session's longer lifetime.
 s:=pg_temp.sql46_session('awaiting_availability',now()+interval '1 day');
 t:=pg_temp.sql46_session('awaiting_location',now()+interval '1 day');
 PERFORM pg_temp.sql46_inputs(s,1,now()-interval '1 second');
 PERFORM pg_temp.sql46_inputs(t,1,now()-interval '1 second');
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>4 OR EXISTS(SELECT 1 FROM public.chat_meetup_availability) OR EXISTS(SELECT 1 FROM public.chat_meetup_locations)
 OR EXISTS(SELECT 1 FROM public.chat_meetup_sessions WHERE meetup_id IN(s,t) AND revision<>3) THEN
 RAISE EXCEPTION 'FAIL SQL46 private TTL predicate/count changed active session'; END IF;
 PERFORM pg_temp.sql46_reset();

 -- Fresh consent is retained only while its corresponding stage needs it.
 s:=pg_temp.sql46_session('awaiting_availability',now()+interval '1 day');
 t:=pg_temp.sql46_session('awaiting_location',now()+interval '1 day');
 PERFORM pg_temp.sql46_inputs(s,1,now()+interval '30 minutes');
 PERFORM pg_temp.sql46_inputs(t,1,now()+interval '30 minutes');
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>2 OR (SELECT count(*) FROM public.chat_meetup_availability WHERE meetup_id=s)<>1
 OR (SELECT count(*) FROM public.chat_meetup_locations WHERE meetup_id=t)<>1
 OR EXISTS(SELECT 1 FROM public.chat_meetup_locations WHERE meetup_id=s)
 OR EXISTS(SELECT 1 FROM public.chat_meetup_availability WHERE meetup_id=t) THEN
 RAISE EXCEPTION 'FAIL SQL46 no-longer-needed/fresh-retention predicates'; END IF;
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>0 THEN RAISE EXCEPTION 'FAIL SQL46 retained fresh inputs repeatedly counted'; END IF;
 PERFORM pg_temp.sql46_reset();

 -- 126 elapsed plans with both participants in both input tables: pass 1
 -- terminalizes 125 and deletes exactly 500, pass 2 catches the remaining 4.
 FOR remaining IN 1..126 LOOP
 s:=pg_temp.sql46_session('awaiting_location',now()-interval '1 minute');
 PERFORM pg_temp.sql46_inputs(s,2,now()-interval '1 minute');
 END LOOP;
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>500 OR (SELECT count(*) FROM public.chat_meetup_sessions WHERE status='expired')<>125
 OR (SELECT count(*) FROM public.chat_meetup_events WHERE event_key='state:expired:4')<>125
 OR ((SELECT count(*) FROM public.chat_meetup_availability)+(SELECT count(*) FROM public.chat_meetup_locations))<>4 THEN
 RAISE EXCEPTION 'FAIL SQL46 125-session/500-input first pass'; END IF;
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>4 OR (SELECT count(*) FROM public.chat_meetup_sessions WHERE status='expired')<>126
 OR (SELECT count(*) FROM public.chat_meetup_events WHERE event_key='state:expired:4')<>126 THEN
 RAISE EXCEPTION 'FAIL SQL46 bounded backlog second pass'; END IF;
 PERFORM pg_temp.sql46_reset();

 -- Generic availability can consume all 500: the skipped location branch
 -- must neither add a stale count nor delete one extra row.
 s:=pg_temp.sql46_session('awaiting_availability',now()+interval '1 day');
 t:=pg_temp.sql46_session('awaiting_availability',now()+interval '1 day');
 PERFORM pg_temp.sql46_inputs(s,250,now()-interval '1 minute');
 PERFORM pg_temp.sql46_inputs(t,250,now()-interval '1 minute');
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>500 OR EXISTS(SELECT 1 FROM public.chat_meetup_availability)
 OR (SELECT count(*) FROM public.chat_meetup_locations)<>500 THEN
 RAISE EXCEPTION 'FAIL SQL46 availability exhausted budget/count'; END IF;
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>500 OR EXISTS(SELECT 1 FROM public.chat_meetup_locations) THEN
 RAISE EXCEPTION 'FAIL SQL46 location-only bounded count'; END IF;
 PERFORM pg_temp.sql46_reset();

 -- A hard bound must hold even for structurally valid service-owned input
 -- rows beyond the usual two participants (no participant-membership CHECK).
 s:=pg_temp.sql46_session('awaiting_location',now()-interval '1 minute');
 PERFORM pg_temp.sql46_inputs(s,251,now()-interval '1 minute');
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 remaining:=(SELECT count(*) FROM public.chat_meetup_availability)+(SELECT count(*) FROM public.chat_meetup_locations);
 IF n<>500 OR remaining<>2 OR (SELECT count(*) FROM public.chat_meetup_events WHERE meetup_id=s)<>1 THEN
 RAISE EXCEPTION 'FAIL SQL46 hard terminalization deletion bound: returned %, retained %',n,remaining; END IF;
 SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
 IF n<>2 OR EXISTS(SELECT 1 FROM public.chat_meetup_availability) OR EXISTS(SELECT 1 FROM public.chat_meetup_locations)
 OR (SELECT count(*) FROM public.chat_meetup_events WHERE meetup_id=s)<>1 THEN
 RAISE EXCEPTION 'FAIL SQL46 terminalization overflow catchup/event dedup'; END IF;
 RAISE NOTICE 'PASS SQL46 janitor TTL, stage retention, returned counts, 125 sessions, 500 inputs, overflow and expiry events';
END $$;
ROLLBACK;
