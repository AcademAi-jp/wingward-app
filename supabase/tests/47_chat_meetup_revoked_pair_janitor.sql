-- SQL47: real service-role janitor after block/preference revocation.
-- Synthetic owner-created rollback fixtures; unrelated expired TTL rows prove no global wedge.
BEGIN;
SET LOCAL statement_timeout = '30s';
SET LOCAL TIME ZONE 'UTC';
CREATE TEMP TABLE sql47_users AS SELECT i, gen_random_uuid() AS id FROM generate_series(1,260) i;
INSERT INTO auth.users(id,email) SELECT id,id::text||'@example.invalid' FROM sql47_users;
UPDATE public.user_profiles SET id=auth_user_id,nickname='SQL47 synthetic',
 birth_date='1990-01-01',age_verified_at=now(),age_verification_method='self_declared',
 timezone='UTC',identity_verification_status='verified',identity_verified_at=now(),
 dating_market='JP',gender_identity='woman',preferred_genders=ARRAY['woman'],
 preference_mode='selected',onboarding_settings_completed_at=now()
 WHERE auth_user_id IN(SELECT id FROM sql47_users);
CREATE TEMP TABLE sql47_matches(id uuid);
CREATE FUNCTION pg_temp.sql47_session(p_status text,p_expires timestamptz)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE a uuid; b uuid; pair_index integer; m uuid:=gen_random_uuid(); r uuid:=gen_random_uuid(); s uuid:=gen_random_uuid();
BEGIN
 SELECT count(*)+1 INTO pair_index FROM sql47_matches;
 SELECT least(x.id,y.id),greatest(x.id,y.id) INTO a,b FROM sql47_users x,sql47_users y WHERE x.i=pair_index*2-1 AND y.i=pair_index*2;
 INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES(m,a,b,'direct_chat_active');
 INSERT INTO sql47_matches VALUES(m);
 INSERT INTO public.direct_chat_rooms(id,match_id,status) VALUES(r,m,'active');
 INSERT INTO public.meetups(id,match_id,initiator_id,status,intent_expires_at,proposal_expires_at)
 VALUES(s,m,a,'arranging',now()+interval '1 day',now()+interval '1 day');
 INSERT INTO public.chat_meetup_sessions(meetup_id,match_id,room_id,user_a_id,user_b_id,status,revision,expires_at,
 time_choice_a,time_choice_b,cafe_choice_a,cafe_choice_b,selected_time_candidate_id,time_candidates,cafe_candidates)
 VALUES(s,m,r,a,b,p_status,3,p_expires,'old-time','old-time','old-cafe','old-cafe','old-time',
 '[{"id":"old-time"}]','[{"id":"old-cafe"}]');
 RETURN s;
END $$;
CREATE FUNCTION pg_temp.sql47_inputs(p_session uuid,p_count integer,p_expires timestamptz)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 INSERT INTO public.chat_meetup_availability(meetup_id,user_id,source,window_starts_at,window_ends_at,intervals,created_at,expires_at)
 SELECT p_session,id,'manual',now(),now()+interval '1 hour','[]',now(),p_expires FROM (SELECT u.id FROM sql47_users u WHERE
  (p_count>2 AND u.i<=p_count) OR (p_count<=2 AND u.id IN
   (SELECT user_a_id FROM public.chat_meetup_sessions WHERE meetup_id=p_session
    UNION ALL SELECT user_b_id FROM public.chat_meetup_sessions WHERE meetup_id=p_session))
  ORDER BY u.id LIMIT p_count) picked;
 INSERT INTO public.chat_meetup_locations(meetup_id,user_id,method,origin,consented_at,expires_at)
 SELECT p_session,id,'current','{"kind":"coordinates","lat":35.0,"lng":139.0}',now(),p_expires FROM (SELECT u.id FROM sql47_users u WHERE
  (p_count>2 AND u.i<=p_count) OR (p_count<=2 AND u.id IN
   (SELECT user_a_id FROM public.chat_meetup_sessions WHERE meetup_id=p_session
    UNION ALL SELECT user_b_id FROM public.chat_meetup_sessions WHERE meetup_id=p_session))
  ORDER BY u.id LIMIT p_count) picked;
END $$;
CREATE FUNCTION pg_temp.sql47_reset() RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 DELETE FROM public.matches WHERE id IN(SELECT id FROM sql47_matches);
 DELETE FROM sql47_matches;
END $$;
DO $$
DECLARE s uuid; t uuid; a uuid; b uuid; n integer; legacy text; cause text; caught boolean;
BEGIN
 FOR legacy IN SELECT unnest(ARRAY['verifying','arranging','proposed']) LOOP
  FOR cause IN SELECT unnest(ARRAY['block','preference']) LOOP
   s:=pg_temp.sql47_session('awaiting_availability',now()-interval '2 minutes');
   UPDATE public.meetups SET status=legacy WHERE id=s;
   t:=pg_temp.sql47_session('awaiting_location',now()+interval '1 day');
   PERFORM pg_temp.sql47_inputs(s,2,now()-interval '1 minute');
   PERFORM pg_temp.sql47_inputs(t,2,now()-interval '1 minute');
   SELECT user_a_id,user_b_id INTO a,b FROM public.chat_meetup_sessions WHERE meetup_id=s;
   IF cause='block' THEN INSERT INTO public.blocks(blocker_id,blocked_id) VALUES(a,b);
   ELSE UPDATE public.user_profiles SET preferred_genders=ARRAY['man'] WHERE id=a; END IF;
   IF wingward_private.lock_and_check_mutual_eligibility(a,b) THEN RAISE EXCEPTION 'FAIL SQL47 fixture remained eligible'; END IF;

   -- Revocation still denies admission/reopening and expiry carrying live deadlines.
   caught:=false;
   BEGIN UPDATE public.meetups SET status='confirmed',updated_at=now() WHERE id=s;
   EXCEPTION WHEN check_violation THEN caught:=true; END;
   IF NOT caught THEN RAISE EXCEPTION 'FAIL SQL47 revoked pair admitted'; END IF;
   caught:=false;
   BEGIN UPDATE public.meetups SET status='expired',intent_expires_at=now()+interval '1 day',proposal_expires_at=NULL WHERE id=s;
   EXCEPTION WHEN check_violation THEN caught:=true; END;
   IF NOT caught THEN RAISE EXCEPTION 'FAIL SQL47 expiry with live deadline admitted'; END IF;
   caught:=false;
   BEGIN UPDATE public.meetups SET status='expired',intent_expires_at=NULL,proposal_expires_at=NULL,initiator_id=b WHERE id=s;
   EXCEPTION WHEN check_violation THEN caught:=true; END;
   IF NOT caught THEN RAISE EXCEPTION 'FAIL SQL47 expiry changed initiator lineage'; END IF;

   BEGIN
    SET LOCAL ROLE service_role;
    SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs();
    RESET ROLE;
   EXCEPTION WHEN check_violation THEN
    RESET ROLE;
    IF (SELECT status FROM public.chat_meetup_sessions WHERE meetup_id=s)<>'awaiting_availability'
       OR (SELECT status FROM public.meetups WHERE id=s)<>legacy
       OR (SELECT count(*) FROM public.chat_meetup_availability WHERE meetup_id IN(s,t))<>4
       OR (SELECT count(*) FROM public.chat_meetup_locations WHERE meetup_id IN(s,t))<>4 THEN
      RAISE EXCEPTION 'FAIL SQL47 original wedge did not roll back all cleanup';
    END IF;
    RAISE EXCEPTION 'FAIL SQL47 janitor wedged on % after %: SQLSTATE23514, all 8 private rows including unrelated TTL inputs persist',legacy,cause;
   END;
   IF n<>8 OR EXISTS(SELECT 1 FROM public.chat_meetup_availability WHERE meetup_id IN(s,t))
      OR EXISTS(SELECT 1 FROM public.chat_meetup_locations WHERE meetup_id IN(s,t)) THEN
    RAISE EXCEPTION 'FAIL SQL47 private cleanup count or unrelated TTL cleanup'; END IF;
   IF NOT EXISTS(SELECT 1 FROM public.chat_meetup_sessions WHERE meetup_id=s AND status='expired' AND revision=4 AND expires_at IS NULL)
      OR NOT EXISTS(SELECT 1 FROM public.meetups WHERE id=s AND status='expired' AND intent_expires_at IS NULL AND proposal_expires_at IS NULL)
      OR (SELECT count(*) FROM public.chat_meetup_events WHERE meetup_id=s AND event_key='state:expired:4')<>1
      OR NOT EXISTS(SELECT 1 FROM public.chat_meetup_sessions WHERE meetup_id=t AND status='awaiting_location' AND revision=3) THEN
    RAISE EXCEPTION 'FAIL SQL47 terminal expiry/projection/event or unrelated active session changed'; END IF;
   SET LOCAL ROLE service_role; SELECT pruned INTO n FROM public.prune_chat_meetup_private_inputs(); RESET ROLE;
   IF n<>0 OR (SELECT revision FROM public.chat_meetup_sessions WHERE meetup_id=s)<>4
      OR (SELECT count(*) FROM public.chat_meetup_events WHERE meetup_id=s)<>1 THEN
    RAISE EXCEPTION 'FAIL SQL47 retry changed revision or expiry event'; END IF;
   DELETE FROM public.blocks WHERE blocker_id=a AND blocked_id=b;
   UPDATE public.user_profiles SET preferred_genders=ARRAY['woman'] WHERE id=a;
   PERFORM pg_temp.sql47_reset();
   RAISE NOTICE 'PASS SQL47 % after % and independent private TTL cleanup',legacy,cause;
  END LOOP;
 END LOOP;
END $$;
ROLLBACK;
