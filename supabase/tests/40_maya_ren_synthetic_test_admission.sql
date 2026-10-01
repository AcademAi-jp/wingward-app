-- LOCAL SYNTHETIC TEST ONLY: simulated match/session timestamps are test fixtures.
-- No cloud seed, real-user identity verification, payment, provider call or real meeting evidence.
BEGIN;
SET LOCAL TIME ZONE 'UTC';
DO $$
DECLARE p record;
BEGIN
 IF EXISTS(SELECT 1 FROM wingward_private.synthetic_recording_admissions) THEN RAISE EXCEPTION 'SQL40 expected initially unarmed permit'; END IF;
 FOR p IN SELECT oid,proname,pronamespace FROM pg_catalog.pg_proc WHERE proname LIKE 'demo_recording_%' LOOP
  IF has_function_privilege('anon',p.oid,'execute') OR has_function_privilege('authenticated',p.oid,'execute') THEN RAISE EXCEPTION 'SQL40 wrapper/client ACL'; END IF;
  IF p.pronamespace='wingward_private'::regnamespace AND has_function_privilege('service_role',p.oid,'execute') THEN RAISE EXCEPTION 'SQL40 private direct execution'; END IF;
  IF p.pronamespace='public'::regnamespace AND NOT has_function_privilege('service_role',p.oid,'execute') THEN RAISE EXCEPTION 'SQL40 service wrapper missing'; END IF;
 END LOOP;
 IF (SELECT count(*) FROM pg_catalog.pg_proc WHERE proname LIKE 'demo_recording_%' AND pronamespace='public'::regnamespace)<>8 THEN RAISE EXCEPTION 'SQL40 expected eight wrappers'; END IF;
 IF has_table_privilege('service_role','wingward_private.synthetic_recording_admissions','select') OR has_table_privilege('service_role','wingward_private.synthetic_recording_admissions','insert') THEN RAISE EXCEPTION 'SQL40 direct permit access'; END IF;
END $$;
INSERT INTO auth.users(id,email) VALUES('00000000-0000-0000-0000-00000000d401','sql40-ren@example.invalid'),('00000000-0000-0000-0000-00000000d402','sql40-maya@example.invalid');
UPDATE public.user_profiles SET id=CASE WHEN auth_user_id='00000000-0000-0000-0000-00000000d401' THEN '9d836fee-7b93-41ce-b577-34a63006aaea'::uuid ELSE 'a88a89e2-5421-5ce9-a33b-76d512898c37'::uuid END,
 nickname='SQL40 fictional',birth_date='1990-01-01',age_verified_at=now(),age_verification_method='self_declared',timezone='UTC',dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['nonbinary'],preference_mode='selected',onboarding_settings_completed_at=now()
WHERE auth_user_id IN('00000000-0000-0000-0000-00000000d401','00000000-0000-0000-0000-00000000d402');
-- Canonical profiles already exist before the owner confirms reflection.
INSERT INTO public.profiles(user_id,status,confirmed_at,personality_tags) VALUES
('9d836fee-7b93-41ce-b577-34a63006aaea','confirmed',now(),'["Original Ren"]'),
('a88a89e2-5421-5ce9-a33b-76d512898c37','confirmed',now(),'["Original Maya"]');
INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES('20000000-0000-0000-0000-00000000d401','9d836fee-7b93-41ce-b577-34a63006aaea','a88a89e2-5421-5ce9-a33b-76d512898c37','direct_chat_active');
INSERT INTO public.direct_chat_rooms(id,match_id,status) VALUES('40000000-0000-0000-0000-00000000d401','20000000-0000-0000-0000-00000000d401','active');
DO $$
DECLARE aid uuid:='90000000-0000-4000-8000-00000000d401'; a uuid:='9d836fee-7b93-41ce-b577-34a63006aaea'; b uuid:='a88a89e2-5421-5ce9-a33b-76d512898c37';
 room uuid:='40000000-0000-0000-0000-00000000d401'; issued timestamptz:=now()-interval '1 minute'; expires timestamptz:=now()+interval '119 minutes'; r record; mid uuid; ar integer; br integer; rev integer; prior integer; candidates jsonb;
BEGIN
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,a,room,NULL,issued,expires);
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 unarmed admission'; END IF;
 BEGIN
  INSERT INTO wingward_private.synthetic_recording_admissions(admission_id,issued_at,expires_at) VALUES(aid,issued,issued+interval '121 minutes');
  RAISE EXCEPTION 'SQL40 excessive window accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;
 INSERT INTO wingward_private.synthetic_recording_admissions(admission_id,issued_at,expires_at) VALUES(aid,issued,expires);
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,a,room,NULL,issued,expires);
 IF r.outcome<>'admitted' OR r.match_id<>'20000000-0000-0000-0000-00000000d401' OR r.user_a_id<>a OR r.user_b_id<>b THEN RAISE EXCEPTION 'SQL40 metadata context'; END IF;
 IF EXISTS(SELECT 1 FROM wingward_private.synthetic_recording_admissions WHERE match_id IS NOT NULL) THEN RAISE EXCEPTION 'SQL40 metadata mutated binding'; END IF;
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,'11111111-1111-4111-8111-111111111111',room,NULL,issued,expires);
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 outsider'; END IF;
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,NULL,room,NULL,issued,expires);
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 null actor'; END IF;
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,a,room,NULL,issued,expires+interval '1 second');
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 caller expiry override'; END IF;
 UPDATE public.user_profiles SET age_verified_at=NULL WHERE id=b;
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,a,room,NULL,issued,expires);
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 age gate'; END IF;
 UPDATE public.user_profiles SET age_verified_at=now() WHERE id=b;
 UPDATE public.user_profiles SET preferred_genders=ARRAY['woman'] WHERE id=b;
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,a,room,NULL,issued,expires);
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 mutual preference gate'; END IF;
 UPDATE public.user_profiles SET preferred_genders=ARRAY['nonbinary'] WHERE id=b;
 INSERT INTO public.blocks(blocker_id,blocked_id) VALUES(a,b);
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,a,room,NULL,issued,expires);
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 block gate'; END IF;
 DELETE FROM public.blocks WHERE blocker_id=a AND blocked_id=b;
 -- Real wrappers create one intent anchor and bind exactly that one context.
 SELECT * INTO r FROM public.demo_recording_apply_chat_meetup_action(aid,issued,expires,room,a,0,0,'80000000-0000-4000-8000-00000000d401',repeat('1',64),'{"type":"intent","value":"yes"}');
 IF r.outcome<>'ok' THEN RAISE EXCEPTION 'SQL40 first intent'; END IF;
 SELECT meetup_id INTO mid FROM wingward_private.synthetic_recording_admissions WHERE admission_id=aid;
 IF mid IS NULL THEN RAISE EXCEPTION 'SQL40 first meetup binding'; END IF;
 SELECT * INTO r FROM public.demo_recording_apply_chat_meetup_action(aid,issued,expires,room,b,0,0,'80000000-0000-4000-8000-00000000d402',repeat('2',64),'{"type":"intent","value":"yes"}');
 IF r.outcome<>'ok' OR r.meetup_id<>mid THEN RAISE EXCEPTION 'SQL40 same pair mutual intent'; END IF;
 rev:=r.revision;
 SELECT * INTO r FROM public.claim_meetup_arrangement(mid,a,false,'normal-identity-check');
 IF r.outcome<>'identity_verification_required' THEN RAISE EXCEPTION 'SQL40 normal path changed'; END IF;
 SELECT * INTO r FROM public.demo_recording_claim_meetup_arrangement(aid,issued,expires,mid,a,false,'test-arrange');
 IF r.outcome<>'claimed' OR r.billing_source<>'meetup_arrange' THEN RAISE EXCEPTION 'SQL40 ordinary initial monthly quota'; END IF;
 SELECT * INTO r FROM public.demo_recording_claim_meetup_arrangement(aid,issued,expires,mid,a,false,'test-arrange');
 IF r.outcome<>'already_claimed' THEN RAISE EXCEPTION 'SQL40 quota idempotency'; END IF;
 IF (SELECT used_count FROM public.usage_counters WHERE user_id=a AND quota_key='meetup_arrange')<>1 THEN RAISE EXCEPTION 'SQL40 quota double charge'; END IF;
 -- No provider calls: local fixtures submit manual availability via real transition cores.
 SELECT private_revision INTO ar FROM public.chat_meetup_private_decisions WHERE user_id=a AND match_id='20000000-0000-0000-0000-00000000d401';
 SELECT private_revision INTO br FROM public.chat_meetup_private_decisions WHERE user_id=b AND match_id='20000000-0000-0000-0000-00000000d401';
 SELECT * INTO r FROM public.demo_recording_apply_chat_meetup_action(aid,issued,expires,room,a,rev,ar,'80000000-0000-4000-8000-00000000d403',repeat('3',64),jsonb_build_object('type','availability.submit','source','manual','window',jsonb_build_object('starts_at',now()+interval '5 minutes','ends_at',now()+interval '100 minutes'),'available',jsonb_build_array(jsonb_build_object('starts_at',now()+interval '5 minutes','ends_at',now()+interval '100 minutes'))));
 IF r.outcome<>'ok' THEN RAISE EXCEPTION 'SQL40 synthetic availability'; END IF; ar:=r.own_revision;
 SELECT * INTO r FROM public.demo_recording_apply_chat_meetup_action(aid,issued,expires,room,b,rev,br,'80000000-0000-4000-8000-00000000d404',repeat('4',64),jsonb_build_object('type','availability.submit','source','manual','window',jsonb_build_object('starts_at',now()+interval '5 minutes','ends_at',now()+interval '100 minutes'),'available',jsonb_build_array(jsonb_build_object('starts_at',now()+interval '5 minutes','ends_at',now()+interval '100 minutes'))));
 IF r.outcome<>'ok' THEN RAISE EXCEPTION 'SQL40 second availability'; END IF; br:=r.own_revision;
 SELECT * INTO r FROM public.demo_recording_publish_chat_meetup_times(aid,issued,expires,room,a,rev,ar,br,jsonb_build_array(jsonb_build_object('id','past','starts_at',now()-interval '1 second','ends_at',now()+interval '59 minutes 59 seconds')),NULL);
 IF r.outcome<>'invalid_input' THEN RAISE EXCEPTION 'SQL40 past proposal live-clock gate'; END IF;
 candidates:=jsonb_build_array(jsonb_build_object('id','sql40-time','starts_at',now()+interval '10 minutes','ends_at',now()+interval '70 minutes','timezone','UTC'));
 SELECT * INTO r FROM public.demo_recording_publish_chat_meetup_times(aid,issued,expires,room,a,rev,ar,br,candidates,NULL);
 IF r.outcome<>'ok' THEN RAISE EXCEPTION 'SQL40 real sixty-minute proposal'; END IF; rev:=r.revision;
 -- Other three planning wrappers retain invalid-state/input decisions rather than fabricating results.
 PERFORM public.demo_recording_publish_chat_meetup_cafes(aid,issued,expires,room,a,rev,ar,br,'[]',NULL);
 PERFORM public.demo_recording_publish_chat_meetup_google_cafes(aid,issued,expires,room,a,rev,ar,br,ARRAY[]::text[],NULL);
 PERFORM public.demo_recording_apply_chat_meetup_google_cafe_action(aid,issued,expires,room,a,rev,ar,'80000000-0000-4000-8000-00000000d405',repeat('5',64),'cafe.approve','unpublished');
 SELECT * INTO r FROM public.demo_recording_get_meetup_reflection_state(aid,issued,expires,mid,a);
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 premature reflection'; END IF;
 SELECT * INTO r FROM public.demo_recording_confirm_meetup_reflection(aid,issued,expires,mid,a,'80000000-0000-4000-8000-00000000d406',0,'{}');
 IF r.outcome NOT IN('not_found','invalid_input') THEN RAISE EXCEPTION 'SQL40 premature reflection confirmation'; END IF;
 -- A non-60-minute stored proposal is rejected even on an unrelated action.
 UPDATE public.chat_meetup_sessions SET time_candidates=jsonb_build_array(jsonb_build_object('id','bad','starts_at',now()+interval '10 minutes','ends_at',now()+interval '69 minutes')) WHERE meetup_id=mid;
 BEGIN PERFORM public.demo_recording_get_meetup_reflection_state(aid,issued,expires,mid,a); RAISE EXCEPTION 'SQL40 duration gate missing'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 UPDATE public.chat_meetup_sessions SET time_candidates=candidates WHERE meetup_id=mid;
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,a,NULL,mid,issued,expires);
 IF r.outcome<>'admitted' OR r.room_id<>room OR r.meetup_id<>mid THEN RAISE EXCEPTION 'SQL40 reflection room metadata'; END IF;
 -- Synthetic time travel is a LOCAL fixture only, never a runtime bypass or cloud history write.
 issued:=now()-interval '65 minutes'; expires:=now()+interval '55 minutes';
 UPDATE wingward_private.synthetic_recording_admissions SET issued_at=issued,expires_at=expires WHERE admission_id=aid;
 UPDATE public.chat_meetup_sessions SET status='confirmed',time_candidates='[]',confirmed_starts_at=now()-interval '60 minutes'+interval '10 seconds',confirmed_ends_at=now()+interval '10 seconds',confirmed_timezone='UTC',expires_at=NULL WHERE meetup_id=mid;
 UPDATE public.meetups SET status='confirmed',confirmed_start_at=now()-interval '60 minutes'+interval '10 seconds',confirmed_timezone='UTC' WHERE id=mid;
 SELECT private_revision INTO ar FROM public.chat_meetup_private_decisions WHERE user_id=a AND match_id='20000000-0000-0000-0000-00000000d401';
 SELECT revision INTO rev FROM public.chat_meetup_sessions WHERE meetup_id=mid;
 SELECT * INTO r FROM public.demo_recording_apply_chat_meetup_action(aid,issued,expires,room,a,rev,ar,'80000000-0000-4000-8000-00000000d407',repeat('7',64),' {"type":"meeting.complete"}');
 IF r.outcome<>'invalid_state' THEN RAISE EXCEPTION 'SQL40 real end-time gate'; END IF;
 UPDATE public.chat_meetup_sessions SET confirmed_starts_at=now()-interval '60 minutes'-interval '1 second',confirmed_ends_at=now()-interval '1 second' WHERE meetup_id=mid;
 UPDATE public.meetups SET confirmed_start_at=now()-interval '60 minutes'-interval '1 second' WHERE id=mid;
 SELECT * INTO r FROM public.demo_recording_get_meetup_reflection_state(aid,issued,expires,mid,a);
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 explicit completion gate'; END IF;
 SELECT * INTO r FROM public.demo_recording_apply_chat_meetup_action(aid,issued,expires,room,a,rev,ar,'80000000-0000-4000-8000-00000000d408',repeat('8',64),'{"type":"meeting.complete"}');
 IF r.outcome<>'ok' THEN RAISE EXCEPTION 'SQL40 post-end completion'; END IF;
 SELECT * INTO r FROM public.demo_recording_get_meetup_reflection_state(aid,issued,expires,mid,a);
 IF r.outcome<>'ok' OR r.current_version<>0 THEN RAISE EXCEPTION 'SQL40 same-pair reflection state'; END IF;
 SELECT * INTO r FROM public.get_meetup_reflection_state(mid,a);
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 normal reflection weakened'; END IF;
 SELECT * INTO r FROM public.demo_recording_confirm_meetup_reflection(aid,issued,expires,mid,a,'80000000-0000-4000-8000-00000000d409',0,'{"priority_value":"community"}');
 IF r.outcome<>'confirmed' OR r.version<>1 THEN RAISE EXCEPTION 'SQL40 explicit reflection version'; END IF;
 SELECT * INTO r FROM public.demo_recording_confirm_meetup_reflection(aid,issued,expires,mid,a,'80000000-0000-4000-8000-00000000d409',0,'{"priority_value":"community"}');
 IF r.outcome<>'replayed' OR r.version<>1 THEN RAISE EXCEPTION 'SQL40 reflection idempotency'; END IF;
 SELECT * INTO r FROM public.demo_recording_confirm_meetup_reflection(aid,issued,expires,mid,a,'80000000-0000-4000-8000-00000000d410',0,'{"priority_value":"family"}');
 IF r.outcome<>'version_conflict' THEN RAISE EXCEPTION 'SQL40 reflection version fence'; END IF;
 -- Local test expires the permit; RPC cannot resurrect it with caller dates.
 UPDATE wingward_private.synthetic_recording_admissions SET issued_at=now()-interval '2 hours',expires_at=now()-interval '1 second' WHERE admission_id=aid;
 SELECT * INTO r FROM public.check_synthetic_recording_admission(aid,a,room,NULL,now()-interval '2 hours',now()-interval '1 second');
 IF r.outcome<>'not_found' THEN RAISE EXCEPTION 'SQL40 expired metadata'; END IF;
 BEGIN PERFORM public.demo_recording_get_meetup_reflection_state(aid,issued,expires,mid,a); RAISE EXCEPTION 'SQL40 expiry wrapper gate'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF EXISTS(SELECT 1 FROM public.user_profiles WHERE id IN(a,b) AND(identity_verification_status<>'none' OR identity_verified_at IS NOT NULL OR identity_subject_hash IS NOT NULL)) THEN RAISE EXCEPTION 'SQL40 fabricated identity'; END IF;
 IF EXISTS(SELECT 1 FROM public.consumable_credit_ledger WHERE user_id IN(a,b)) THEN RAISE EXCEPTION 'SQL40 fabricated credit'; END IF;
END $$;
ROLLBACK;
