-- Synthetic rollback-only checks of the actual voice admission and settlement RPCs.
BEGIN;
SET LOCAL statement_timeout='20s';
DO $test$
DECLARE
 actor uuid:='56f96c3d-6040-5c57-b6ad-c59284ba4f3c'; peer uuid:='e7c595cb-ff44-5611-aff1-44fb0ca8bf58';
 au uuid:=gen_random_uuid(); bu uuid:=gen_random_uuid(); persona uuid:=gen_random_uuid();
 first_session uuid:=gen_random_uuid(); second_session uuid:=gen_random_uuid(); key uuid:=gen_random_uuid(); rid uuid;
 meetup uuid:=gen_random_uuid();match_id uuid:=gen_random_uuid();room_id uuid:=gen_random_uuid();
 foreign_meetup uuid:=gen_random_uuid();foreign_match uuid:=gen_random_uuid();foreign_room uuid:=gen_random_uuid();third_auth uuid:=gen_random_uuid();third_actor uuid:='c0195ccd-de1e-5102-ad9c-d5bf4493f493';boundary_session uuid:=gen_random_uuid();
 test_clock timestamptz:='2026-10-02T01:00:00Z'; original_voice text; definition text; r record; role_name text;
BEGIN
 FOREACH definition IN ARRAY ARRAY[
  pg_get_functiondef('public.check_judge_access(uuid)'::regprocedure),
  pg_get_functiondef('wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean)'::regprocedure),
  pg_get_functiondef('wingward_private.reserve_judge_voice_core(uuid,uuid,uuid,text)'::regprocedure),
  pg_get_functiondef('public.settle_judge_voice_session(uuid,uuid)'::regprocedure)
 ] LOOP EXECUTE replace(definition,'clock_timestamp()',quote_literal(test_clock)||'::timestamptz'); END LOOP;
 original_voice:=pg_get_functiondef('wingward_private.reserve_judge_voice_core(uuid,uuid,uuid,text)'::regprocedure);
 INSERT INTO auth.users(id,email,raw_app_meta_data) VALUES
 (au,'voice-owner@example.invalid',jsonb_build_object('wingward_judge_cohort','shipaton-20261001','wingward_judge_slot','owner01','wingward_judge_profile_id',actor,'wingward_provision_batch','shipaton-seven-20261001','wingward_provision_slot','owner01')),
 (bu,'voice-peer@example.invalid','{}');
 UPDATE auth.users SET email_confirmed_at=test_clock WHERE id IN(au,bu);
 UPDATE public.user_profiles SET id=CASE WHEN auth_user_id=au THEN actor ELSE peer END WHERE auth_user_id IN(au,bu);
 INSERT INTO wingward_private.judge_accounts(slot,actor_user_id,auth_user_id,counterpart_user_id,account_kind,issued_at,expires_at,access_scope)
 VALUES('owner01',actor,au,peer,'owner',test_clock-interval '1 minute','2026-10-13T19:00:00Z','shipaton-seven-20261001');
 INSERT INTO wingward_private.judge_provider_policies(operation,reservation_usd_micros,daily_limit,minimum_interval_ms,max_units,max_seconds,enabled,pricing_evidence,server_bound_enforced)
 VALUES('voice_session',100000,12,1000,20000,180,true,'Inactive synthetic estimate',true);
 INSERT INTO public.personas(id,user_id,persona_type,name,compiled_document) VALUES(persona,actor,'virtual_similar','Synthetic voice persona','Synthetic test only');
 INSERT INTO public.speed_dating_sessions(id,user_id,persona_id) VALUES(first_session,actor,persona),(second_session,actor,persona);
 -- Change one policy flag at a time; all other admission inputs stay valid.
 UPDATE wingward_private.judge_provider_policies SET enabled=false WHERE operation='voice_session';
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'disabled voice policy admitted'; END IF;
 BEGIN
  UPDATE wingward_private.judge_provider_policies SET enabled=true,server_bound_enforced=false WHERE operation='voice_session';
  RAISE EXCEPTION 'schema accepted unbound enabled voice policy';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 -- Rollback-only removal of the redundant schema guard tests the RPC guard too.
 ALTER TABLE wingward_private.judge_provider_policies DROP CONSTRAINT judge_provider_policies_check;
 UPDATE wingward_private.judge_provider_policies SET enabled=true,server_bound_enforced=false WHERE operation='voice_session';
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'unbound voice policy admitted'; END IF;
 UPDATE wingward_private.judge_provider_policies SET server_bound_enforced=true,max_seconds=181 WHERE operation='voice_session';
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'oversized voice duration policy admitted'; END IF;
 UPDATE wingward_private.judge_provider_policies SET max_seconds=180 WHERE operation='voice_session';
 ALTER TABLE wingward_private.judge_provider_policies ADD CONSTRAINT judge_provider_policies_check CHECK(operation NOT IN('voice_session','reflection_voice') OR NOT enabled OR server_bound_enforced);
 UPDATE wingward_private.judge_accounts SET disabled_at=test_clock WHERE actor_user_id=actor;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 IF r.outcome='allowed' THEN RAISE EXCEPTION 'disabled voice account admitted'; END IF;
 UPDATE wingward_private.judge_accounts SET disabled_at=NULL WHERE actor_user_id=actor;
 -- Each interview predicate is the only changed state. The deleted predicate must permit the same request.
 UPDATE public.speed_dating_sessions SET user_id=peer WHERE id=first_session;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'foreign session owner admitted'; END IF;
 EXECUTE replace(original_voice,'AND s.user_id=p_user_id','');
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 EXECUTE original_voice;
 IF r.outcome<>'allowed' THEN RAISE EXCEPTION 'session owner mutation did not admit'; END IF;
 DELETE FROM wingward_private.judge_voice_leases WHERE reservation_id=r.reservation_id;
 DELETE FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id;
 UPDATE public.speed_dating_sessions SET user_id=actor,status='completed' WHERE id=first_session;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'completed session admitted'; END IF;
 EXECUTE replace(original_voice,'AND s.status=''active''','');
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 EXECUTE original_voice;
 IF r.outcome<>'allowed' THEN RAISE EXCEPTION 'active mutation did not admit'; END IF;
 DELETE FROM wingward_private.judge_voice_leases WHERE reservation_id=r.reservation_id;
 DELETE FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id;
 UPDATE public.speed_dating_sessions SET status='active' WHERE id=first_session;
 UPDATE public.personas SET user_id=peer WHERE id=persona;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'foreign persona admitted'; END IF;
 EXECUTE replace(original_voice,'AND p.user_id=p_user_id','');
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 EXECUTE original_voice;
 IF r.outcome<>'allowed' THEN RAISE EXCEPTION 'persona owner mutation did not admit'; END IF;
 DELETE FROM wingward_private.judge_voice_leases WHERE reservation_id=r.reservation_id;
 DELETE FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id;
 UPDATE public.personas SET user_id=actor,persona_type='wingfox' WHERE id=persona;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'nonvirtual persona admitted'; END IF;
 EXECUTE replace(original_voice,'AND p.persona_type IN(''virtual_similar'',''virtual_complementary'',''virtual_discovery'')','');
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 EXECUTE original_voice;
 IF r.outcome<>'allowed' THEN RAISE EXCEPTION 'virtual persona mutation did not admit'; END IF;
 DELETE FROM wingward_private.judge_voice_leases WHERE reservation_id=r.reservation_id;
 DELETE FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id;
 UPDATE public.personas SET persona_type='virtual_similar' WHERE id=persona;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);rid:=r.reservation_id;
 IF r.outcome<>'allowed' OR r.max_seconds<>180 OR r.expires_at<>test_clock+interval '180 seconds' THEN RAISE EXCEPTION 'valid bounded voice rejected'; END IF;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,key);
 IF r.outcome<>'replayed' OR r.reservation_id<>rid THEN RAISE EXCEPTION 'voice replay changed lease'; END IF;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,first_session,gen_random_uuid());
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'different key reopened context'; END IF;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,second_session,gen_random_uuid());
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'unsettled parallel voice admitted'; END IF;
 EXECUTE replace(pg_get_functiondef('wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean)'::regprocedure),quote_literal(test_clock)||'::timestamptz',quote_literal(test_clock+interval '1 second')||'::timestamptz');
 EXECUTE replace(original_voice,'EXISTS(SELECT 1 FROM wingward_private.judge_voice_leases l WHERE l.actor_user_id=p_user_id AND l.settled_at IS NULL)','false');
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,second_session,gen_random_uuid());
 EXECUTE original_voice;
 IF r.outcome<>'allowed' THEN RAISE EXCEPTION 'unsettled lease mutation did not admit'; END IF;
 DELETE FROM wingward_private.judge_voice_leases WHERE reservation_id=r.reservation_id;
 DELETE FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id;
 EXECUTE replace(original_voice,quote_literal(test_clock)||'::timestamptz',quote_literal(test_clock+interval '4 minutes')||'::timestamptz');
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,second_session,gen_random_uuid());
 EXECUTE original_voice;
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'expired unsettled voice failed to block'; END IF;
 SELECT * INTO r FROM public.settle_judge_voice_session(peer,rid);
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'foreign owner settled voice'; END IF;
 SELECT * INTO r FROM public.settle_judge_voice_session(actor,rid);
 IF r.outcome<>'settled' THEN RAISE EXCEPTION 'owner settlement rejected'; END IF;
 SELECT * INTO r FROM public.settle_judge_voice_session(actor,rid);
 IF r.outcome<>'replayed' THEN RAISE EXCEPTION 'settlement not idempotent'; END IF;
 EXECUTE replace(pg_get_functiondef('wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean)'::regprocedure),quote_literal(test_clock)||'::timestamptz',quote_literal(test_clock+interval '1 second')||'::timestamptz');
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,second_session,gen_random_uuid());
 IF r.outcome<>'allowed' THEN RAISE EXCEPTION 'settled lease still blocks fresh context'; END IF;
 -- Actual reflection-state RPC, not a substitute or echo fixture.
 SELECT * INTO r FROM public.settle_judge_voice_session(actor,r.reservation_id);
 IF r.outcome<>'settled' THEN RAISE EXCEPTION 'second voice settlement rejected'; END IF;
 -- Account expiry independently shortens the actual voice deadline.
 INSERT INTO public.speed_dating_sessions(id,user_id,persona_id) VALUES(boundary_session,actor,persona);
 EXECUTE replace(pg_get_functiondef('wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean)'::regprocedure),quote_literal(test_clock+interval '1 second')||'::timestamptz',quote_literal(test_clock+interval '2 seconds')||'::timestamptz');
 UPDATE wingward_private.judge_accounts SET expires_at=test_clock+interval '60 seconds' WHERE actor_user_id=actor;
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,boundary_session,gen_random_uuid());
 IF r.outcome<>'allowed' OR r.max_seconds<>60 OR r.expires_at<>test_clock+interval '60 seconds' THEN RAISE EXCEPTION 'account expiry did not shorten voice'; END IF;
 DELETE FROM wingward_private.judge_voice_leases WHERE reservation_id=r.reservation_id;
 DELETE FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id;
 UPDATE wingward_private.judge_accounts SET expires_at=test_clock+interval '2.5 seconds' WHERE actor_user_id=actor;
 EXECUTE replace(original_voice,quote_literal(test_clock)||'::timestamptz',quote_literal(test_clock+interval '2 seconds')||'::timestamptz');
 SELECT * INTO r FROM public.reserve_judge_voice_session(actor,boundary_session,gen_random_uuid());
 EXECUTE original_voice;
 IF r.outcome<>'expired' OR r.reservation_id IS NOT NULL OR EXISTS(SELECT 1 FROM wingward_private.judge_voice_leases WHERE context_id=boundary_session) THEN RAISE EXCEPTION 'subsecond duration admitted a lease'; END IF;
 UPDATE wingward_private.judge_accounts SET expires_at='2026-10-13T19:00:00Z' WHERE actor_user_id=actor;
 UPDATE public.user_profiles SET birth_date='1990-01-01',age_verified_at='2026-09-26T00:00:00Z',age_verification_method='self_declared',gender_identity='woman',preferred_genders=ARRAY['woman']::text[],preference_mode='selected',dating_market='JP',onboarding_settings_completed_at='2026-09-26T00:00:00Z',identity_verification_status='verified',identity_verified_at='2026-09-26T00:00:00Z' WHERE id IN(actor,peer);
 INSERT INTO public.profiles(user_id,status,confirmed_at,personality_tags) VALUES(actor,'confirmed',test_clock,'["Synthetic"]'),(peer,'confirmed',test_clock,'["Synthetic"]');
 INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES(match_id,actor,peer,'direct_chat_active');
 INSERT INTO public.direct_chat_rooms(id,match_id,status) VALUES(room_id,match_id,'active');
 INSERT INTO public.meetups(id,match_id,initiator_id,status) VALUES(meetup,match_id,actor,'intent_pending');
 INSERT INTO public.chat_meetup_sessions(meetup_id,match_id,room_id,user_a_id,user_b_id,status,confirmed_starts_at,confirmed_ends_at,confirmed_timezone,completed_a_at,completed_b_at)
 VALUES(meetup,match_id,room_id,actor,peer,'confirmed',now()-interval '3 hours',now()-interval '2 hours','UTC',NULL,NULL);
 INSERT INTO wingward_private.judge_provider_policies(operation,reservation_usd_micros,daily_limit,minimum_interval_ms,max_units,max_seconds,enabled,pricing_evidence,server_bound_enforced)
 VALUES('reflection_voice',100000,12,1000,20000,180,true,'Inactive synthetic reflection estimate',true);
 SELECT * INTO r FROM public.reserve_judge_reflection_voice_session(actor,meetup,gen_random_uuid());
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'reflection without own completion admitted'; END IF;
 EXECUTE replace(original_voice,'IF NOT FOUND OR state.outcome<>''ok''','IF false');
 SELECT * INTO r FROM public.reserve_judge_reflection_voice_session(actor,meetup,gen_random_uuid());
 EXECUTE original_voice;
 IF r.outcome<>'allowed' THEN RAISE EXCEPTION 'reflection completion guard mutation did not admit'; END IF;
 DELETE FROM wingward_private.judge_voice_leases WHERE reservation_id=r.reservation_id;
 DELETE FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id;
 UPDATE public.chat_meetup_sessions SET completed_a_at=now() WHERE meetup_id=meetup;
 key:=gen_random_uuid();
 SELECT * INTO r FROM public.reserve_judge_reflection_voice_session(actor,meetup,key);rid:=r.reservation_id;
 IF r.outcome<>'allowed' THEN RAISE EXCEPTION 'completed owned reflection denied'; END IF;
 SELECT * INTO r FROM public.reserve_judge_reflection_voice_session(actor,meetup,key);
 IF r.outcome<>'replayed' OR r.reservation_id<>rid THEN RAISE EXCEPTION 'reflection replay changed lease'; END IF;
 SELECT * INTO r FROM public.reserve_judge_reflection_voice_session(actor,gen_random_uuid(),gen_random_uuid());
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'foreign or missing reflection context admitted'; END IF;
 SELECT * INTO r FROM public.settle_judge_voice_session(actor,rid);
 IF r.outcome<>'settled' THEN RAISE EXCEPTION 'reflection settlement rejected'; END IF;
 EXECUTE replace(pg_get_functiondef('wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean)'::regprocedure),quote_literal(test_clock+interval '2 seconds')||'::timestamptz',quote_literal(test_clock+interval '3 seconds')||'::timestamptz');
 -- A real completed meetup exists, but actor is not one of its participants.
 INSERT INTO auth.users(id,email,raw_app_meta_data,email_confirmed_at) VALUES(third_auth,'voice-third@example.invalid','{}',test_clock);
 UPDATE public.user_profiles SET id=third_actor WHERE auth_user_id=third_auth;
 UPDATE public.user_profiles SET birth_date='1990-01-01',age_verified_at='2026-09-26T00:00:00Z',age_verification_method='self_declared',gender_identity='woman',preferred_genders=ARRAY['woman']::text[],preference_mode='selected',dating_market='JP',onboarding_settings_completed_at='2026-09-26T00:00:00Z',identity_verification_status='verified',identity_verified_at='2026-09-26T00:00:00Z' WHERE id=third_actor;
 INSERT INTO public.profiles(user_id,status,confirmed_at,personality_tags) VALUES(third_actor,'confirmed',test_clock,'["Synthetic"]');
 INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES(foreign_match,least(peer,third_actor),greatest(peer,third_actor),'direct_chat_active');
 INSERT INTO public.direct_chat_rooms(id,match_id,status) VALUES(foreign_room,foreign_match,'active');
 INSERT INTO public.meetups(id,match_id,initiator_id,status) VALUES(foreign_meetup,foreign_match,peer,'intent_pending');
 INSERT INTO public.chat_meetup_sessions(meetup_id,match_id,room_id,user_a_id,user_b_id,status,confirmed_starts_at,confirmed_ends_at,confirmed_timezone,completed_a_at,completed_b_at)
 VALUES(foreign_meetup,foreign_match,foreign_room,least(peer,third_actor),greatest(peer,third_actor),'confirmed',now()-interval '3 hours',now()-interval '2 hours','UTC',now(),now());
 SELECT * INTO r FROM public.get_meetup_reflection_state(foreign_meetup,peer);
 IF r.outcome<>'ok' THEN RAISE EXCEPTION 'foreign meetup fixture is not valid for its actual participant'; END IF;
 SELECT * INTO r FROM public.reserve_judge_reflection_voice_session(actor,foreign_meetup,gen_random_uuid());
 IF r.outcome<>'denied' THEN RAISE EXCEPTION 'existing foreign reflection context admitted'; END IF;
 EXECUTE replace(original_voice,'IF NOT FOUND OR state.outcome<>''ok''','IF false');
 SELECT * INTO r FROM public.reserve_judge_reflection_voice_session(actor,foreign_meetup,gen_random_uuid());
 EXECUTE original_voice;
 IF r.outcome<>'allowed' THEN RAISE EXCEPTION 'foreign reflection guard mutation did not admit'; END IF;
 DELETE FROM wingward_private.judge_voice_leases WHERE reservation_id=r.reservation_id;
 DELETE FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id;
 IF NOT has_function_privilege('service_role','public.reserve_judge_voice_session(uuid,uuid,uuid)','execute') OR NOT has_function_privilege('service_role','public.reserve_judge_reflection_voice_session(uuid,uuid,uuid)','execute') OR NOT has_function_privilege('service_role','public.settle_judge_voice_session(uuid,uuid)','execute') THEN RAISE EXCEPTION 'service role voice RPC unavailable'; END IF;
 FOREACH role_name IN ARRAY ARRAY['anon','authenticated'] LOOP
  IF has_function_privilege(role_name,'public.reserve_judge_voice_session(uuid,uuid,uuid)','execute') OR has_function_privilege(role_name,'public.reserve_judge_reflection_voice_session(uuid,uuid,uuid)','execute') OR has_function_privilege(role_name,'public.settle_judge_voice_session(uuid,uuid)','execute') THEN RAISE EXCEPTION 'public voice RPC access'; END IF;
 END LOOP;
 FOREACH role_name IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
  IF has_function_privilege(role_name,'wingward_private.reserve_judge_voice_core(uuid,uuid,uuid,text)','execute') OR has_table_privilege(role_name,'wingward_private.judge_voice_leases','SELECT,INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'private voice core or lease exposed'; END IF;
 END LOOP;
 IF EXISTS(SELECT 1 FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE p.oid IN('public.reserve_judge_voice_session(uuid,uuid,uuid)'::regprocedure,'public.reserve_judge_reflection_voice_session(uuid,uuid,uuid)'::regprocedure,'public.settle_judge_voice_session(uuid,uuid)'::regprocedure,'wingward_private.reserve_judge_voice_core(uuid,uuid,uuid,text)'::regprocedure) AND a.grantee=0 AND a.privilege_type='EXECUTE') THEN RAISE EXCEPTION 'PUBLIC voice execute exposed'; END IF;
 IF EXISTS(SELECT 1 FROM pg_class p CROSS JOIN LATERAL aclexplode(coalesce(p.relacl,acldefault('r',p.relowner))) a WHERE p.oid='wingward_private.judge_voice_leases'::regclass AND a.grantee=0) THEN RAISE EXCEPTION 'PUBLIC lease access exposed'; END IF;
 IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='wingward_private.judge_voice_leases'::regclass) THEN RAISE EXCEPTION 'lease RLS removed'; END IF;
END $test$;
ROLLBACK;
