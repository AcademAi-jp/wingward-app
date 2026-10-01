-- Synthetic fixture; each invocation rolls back all rows and temporary helpers.
BEGIN;
SET LOCAL statement_timeout='15s';
DELETE FROM public.matches WHERE id IN ('20000000-0000-0000-0000-00000000fa01','20000000-0000-0000-0000-00000000fa02');
DELETE FROM auth.users WHERE id IN ('00000000-0000-0000-0000-00000000fa01','00000000-0000-0000-0000-00000000fa02','00000000-0000-0000-0000-00000000fa03','00000000-0000-0000-0000-00000000fa04') AND email IN ('b2-meetup-child-sql23-a@example.invalid','b2-meetup-child-sql23-b@example.invalid','b2-meetup-child-sql23-c@example.invalid','b2-meetup-child-sql23-d@example.invalid');
INSERT INTO auth.users(id,email) VALUES ('00000000-0000-0000-0000-00000000fa01','b2-meetup-child-sql23-a@example.invalid'),('00000000-0000-0000-0000-00000000fa02','b2-meetup-child-sql23-b@example.invalid'),('00000000-0000-0000-0000-00000000fa03','b2-meetup-child-sql23-c@example.invalid'),('00000000-0000-0000-0000-00000000fa04','b2-meetup-child-sql23-d@example.invalid');
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000fa01',nickname='B2 Meetup SQL23 A',birth_date=DATE '1990-01-01',age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['nonbinary'],preference_mode='selected' WHERE auth_user_id='00000000-0000-0000-0000-00000000fa01';
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000fa02',nickname='B2 Meetup SQL23 B',birth_date=DATE '1990-01-01',age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['nonbinary'],preference_mode='selected' WHERE auth_user_id='00000000-0000-0000-0000-00000000fa02';
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000fa03',nickname='B2 Meetup SQL23 C',birth_date=DATE '1990-01-01',age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='woman',preferred_genders=ARRAY['nonbinary'],preference_mode='selected' WHERE auth_user_id='00000000-0000-0000-0000-00000000fa03';
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000fa04',nickname='B2 Meetup SQL23 D',birth_date=DATE '1990-01-01',age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['woman'],preference_mode='selected' WHERE auth_user_id='00000000-0000-0000-0000-00000000fa04';
UPDATE public.user_profiles SET gender_identity='nonbinary',preferred_genders=ARRAY['nonbinary'] WHERE id IN ('10000000-0000-0000-0000-00000000fa03','10000000-0000-0000-0000-00000000fa04');
CREATE OR REPLACE FUNCTION pg_temp.expect_rejected(stmt text, expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 BEGIN
  EXECUTE stmt;
  RAISE EXCEPTION 'expected guarded statement to fail';
 EXCEPTION WHEN check_violation THEN
  IF SQLERRM IS DISTINCT FROM expected THEN RAISE EXCEPTION 'unexpected guard error: %',SQLERRM; END IF;
 END;
END;$$;
CREATE OR REPLACE FUNCTION pg_temp.assert_true(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL SQL23: %',label; END IF; END;$$;
INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES ('20000000-0000-0000-0000-00000000fa01','10000000-0000-0000-0000-00000000fa01','10000000-0000-0000-0000-00000000fa02','direct_chat_active'),('20000000-0000-0000-0000-00000000fa02','10000000-0000-0000-0000-00000000fa03','10000000-0000-0000-0000-00000000fa04','direct_chat_active');
INSERT INTO public.meetups(id,match_id,initiator_id,status,area,intent_expires_at,proposal_expires_at) VALUES ('80000000-0000-0000-0000-00000000fa01','20000000-0000-0000-0000-00000000fa01','10000000-0000-0000-0000-00000000fa01','proposed','baseline',now()+interval '1 day',now()+interval '1 day'),('80000000-0000-0000-0000-00000000fa02','20000000-0000-0000-0000-00000000fa02','10000000-0000-0000-0000-00000000fa03','arranging','baseline',NULL,now()+interval '1 day');
INSERT INTO public.fox_conversations(id,match_id,meetup_id,purpose,status,total_rounds) VALUES ('30000000-0000-0000-0000-00000000fa01','20000000-0000-0000-0000-00000000fa01','80000000-0000-0000-0000-00000000fa01','scheduling','pending',10),('30000000-0000-0000-0000-00000000fa02','20000000-0000-0000-0000-00000000fa02','80000000-0000-0000-0000-00000000fa02','scheduling','pending',10);
INSERT INTO public.meetup_proposals(id,meetup_id,attempt_number,candidates,generated_by_conversation_id) VALUES ('90000000-0000-0000-0000-00000000fa01','80000000-0000-0000-0000-00000000fa01',1,'[{},{},{}]','30000000-0000-0000-0000-00000000fa01'),('90000000-0000-0000-0000-00000000fa02','80000000-0000-0000-0000-00000000fa02',1,'[{},{},{}]','30000000-0000-0000-0000-00000000fa02');
INSERT INTO public.meetup_proposal_responses(id,proposal_id,user_id,selected_candidate_indexes,response) VALUES ('a0000000-0000-0000-0000-00000000fa01','90000000-0000-0000-0000-00000000fa01','10000000-0000-0000-0000-00000000fa01',ARRAY[0],'baseline');
UPDATE public.meetups SET area='updated' WHERE id='80000000-0000-0000-0000-00000000fa01'; SELECT pg_temp.assert_true((SELECT area='updated' FROM public.meetups WHERE id='80000000-0000-0000-0000-00000000fa01'),'eligible meetups update');
UPDATE public.meetup_proposals SET rationale='updated' WHERE id='90000000-0000-0000-0000-00000000fa01'; SELECT pg_temp.assert_true((SELECT rationale='updated' FROM public.meetup_proposals WHERE id='90000000-0000-0000-0000-00000000fa01'),'eligible meetup_proposals update');
UPDATE public.meetup_proposal_responses SET response='updated' WHERE id='a0000000-0000-0000-0000-00000000fa01'; SELECT pg_temp.assert_true((SELECT response='updated' FROM public.meetup_proposal_responses WHERE id='a0000000-0000-0000-0000-00000000fa01'),'eligible meetup_proposal_responses update');
SELECT pg_temp.expect_rejected('UPDATE public.meetups SET match_id=''20000000-0000-0000-0000-00000000fa02'' WHERE id=''80000000-0000-0000-0000-00000000fa01''','meetup write is not eligible');
SELECT pg_temp.expect_rejected('UPDATE public.meetups SET initiator_id=''10000000-0000-0000-0000-00000000fa02'' WHERE id=''80000000-0000-0000-0000-00000000fa01''','meetup write is not eligible');
SELECT pg_temp.expect_rejected('UPDATE public.meetup_proposals SET meetup_id=''80000000-0000-0000-0000-00000000fa02'' WHERE id=''90000000-0000-0000-0000-00000000fa01''','meetup proposal write is not eligible');
SELECT pg_temp.expect_rejected('UPDATE public.meetup_proposals SET attempt_number=2 WHERE id=''90000000-0000-0000-0000-00000000fa01''','meetup proposal write is not eligible');
SELECT pg_temp.expect_rejected('UPDATE public.meetup_proposals SET generated_by_conversation_id=NULL WHERE id=''90000000-0000-0000-0000-00000000fa01''','meetup proposal write is not eligible');
SELECT pg_temp.expect_rejected('UPDATE public.meetup_proposal_responses SET proposal_id=''90000000-0000-0000-0000-00000000fa02'' WHERE id=''a0000000-0000-0000-0000-00000000fa01''','meetup proposal response write is not eligible');
SELECT pg_temp.expect_rejected('UPDATE public.meetup_proposal_responses SET user_id=''10000000-0000-0000-0000-00000000fa02'' WHERE id=''a0000000-0000-0000-0000-00000000fa01''','meetup proposal response write is not eligible');
SELECT pg_temp.expect_rejected('INSERT INTO public.meetup_proposals(meetup_id,attempt_number,candidates,generated_by_conversation_id) VALUES (''80000000-0000-0000-0000-00000000fa01'',2,''[{},{},{}]'',''30000000-0000-0000-0000-00000000fa02'')','meetup proposal write is not eligible');
CREATE OR REPLACE FUNCTION pg_temp.expect_role_denied(stmt text, expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE code text;
BEGIN
 BEGIN EXECUTE stmt; EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS code = RETURNED_SQLSTATE; END;
 IF code IS DISTINCT FROM expected THEN RAISE EXCEPTION 'FAIL actor denial: expected %, got %',expected,code; END IF;
END;$$;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000fa01',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_role_denied('INSERT INTO public.meetups(match_id,initiator_id,status) VALUES (''20000000-0000-0000-0000-00000000fa01'',''10000000-0000-0000-0000-00000000fa01'',''expired'')','42501');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000fa03',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_role_denied('INSERT INTO public.meetups(match_id,initiator_id,status) VALUES (''20000000-0000-0000-0000-00000000fa01'',''10000000-0000-0000-0000-00000000fa01'',''expired'')','23514');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000fa01',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_role_denied('INSERT INTO public.meetup_proposal_responses(proposal_id,user_id,selected_candidate_indexes) VALUES (''90000000-0000-0000-0000-00000000fa01'',''10000000-0000-0000-0000-00000000fa02'',ARRAY[0])','23514');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','',true);
-- NEGATIVE_CONTROL_POINT: disable only one guard here inside this transaction.
UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id IN ('10000000-0000-0000-0000-00000000fa01','10000000-0000-0000-0000-00000000fa03');
SELECT pg_temp.expect_rejected('UPDATE public.meetups SET area=''forged'' WHERE id=''80000000-0000-0000-0000-00000000fa01''','meetup write is not eligible');
UPDATE public.meetups SET area=area WHERE id='80000000-0000-0000-0000-00000000fa01'; SELECT pg_temp.assert_true((SELECT area='updated' FROM public.meetups WHERE id='80000000-0000-0000-0000-00000000fa01'),'revoked meetups no-op');
SELECT pg_temp.expect_rejected('UPDATE public.meetup_proposals SET rationale=''forged'' WHERE id=''90000000-0000-0000-0000-00000000fa01''','meetup proposal write is not eligible');
UPDATE public.meetup_proposals SET rationale=rationale WHERE id='90000000-0000-0000-0000-00000000fa01'; SELECT pg_temp.assert_true((SELECT rationale='updated' FROM public.meetup_proposals WHERE id='90000000-0000-0000-0000-00000000fa01'),'revoked meetup_proposals no-op');
SELECT pg_temp.expect_rejected('UPDATE public.meetup_proposal_responses SET response=''forged'' WHERE id=''a0000000-0000-0000-0000-00000000fa01''','meetup proposal response write is not eligible');
UPDATE public.meetup_proposal_responses SET response=response WHERE id='a0000000-0000-0000-0000-00000000fa01'; SELECT pg_temp.assert_true((SELECT response='updated' FROM public.meetup_proposal_responses WHERE id='a0000000-0000-0000-0000-00000000fa01'),'revoked meetup_proposal_responses no-op');
SELECT pg_temp.expect_rejected('INSERT INTO public.meetups(match_id,initiator_id,status) VALUES (''20000000-0000-0000-0000-00000000fa01'',''10000000-0000-0000-0000-00000000fa01'',''expired'')','meetup write is not eligible');
SELECT pg_temp.expect_rejected('INSERT INTO public.meetup_proposals(meetup_id,attempt_number,candidates) VALUES (''80000000-0000-0000-0000-00000000fa01'',2,''[{},{},{}]'')','meetup proposal write is not eligible');
SELECT pg_temp.expect_rejected('INSERT INTO public.meetup_proposal_responses(proposal_id,user_id,selected_candidate_indexes) VALUES (''90000000-0000-0000-0000-00000000fa01'',''10000000-0000-0000-0000-00000000fa02'',ARRAY[0])','meetup proposal response write is not eligible');
SELECT pg_temp.expect_rejected('UPDATE public.meetups SET status=''expired'',intent_expires_at=NULL,proposal_expires_at=NULL,area=''forged'' WHERE id=''80000000-0000-0000-0000-00000000fa01''','meetup write is not eligible');
UPDATE public.meetups SET status='expired',intent_expires_at=NULL,proposal_expires_at=NULL,updated_at=now() WHERE id='80000000-0000-0000-0000-00000000fa01'; SELECT pg_temp.assert_true((SELECT status='expired' AND intent_expires_at IS NULL AND proposal_expires_at IS NULL AND area='updated' FROM public.meetups WHERE id='80000000-0000-0000-0000-00000000fa01'),'expiry cleanup');
SELECT pg_temp.expect_rejected('UPDATE public.meetups SET status=''arrange_failed'',proposal_expires_at=NULL,area=''forged'' WHERE id=''80000000-0000-0000-0000-00000000fa02''','meetup write is not eligible');
UPDATE public.meetups SET status='arrange_failed',proposal_expires_at=NULL,updated_at=now() WHERE id='80000000-0000-0000-0000-00000000fa02'; SELECT pg_temp.assert_true((SELECT status='arrange_failed' AND proposal_expires_at IS NULL AND area='baseline' FROM public.meetups WHERE id='80000000-0000-0000-0000-00000000fa02'),'failure cleanup');
UPDATE public.user_profiles SET preference_mode='selected',preferred_genders=ARRAY['nonbinary'] WHERE id='10000000-0000-0000-0000-00000000fa01'; INSERT INTO public.meetups(id,match_id,initiator_id,status) VALUES ('80000000-0000-0000-0000-00000000fa03','20000000-0000-0000-0000-00000000fa01','10000000-0000-0000-0000-00000000fa01','intent_pending'); UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000fa01';
SELECT pg_temp.expect_rejected('UPDATE public.meetups SET status=''cancelled'',intent_a_at=now() WHERE id=''80000000-0000-0000-0000-00000000fa03''','meetup write is not eligible');
UPDATE public.meetups SET status='cancelled',updated_at=now() WHERE id='80000000-0000-0000-0000-00000000fa03'; SELECT pg_temp.assert_true((SELECT status='cancelled' AND intent_a_at IS NULL FROM public.meetups WHERE id='80000000-0000-0000-0000-00000000fa03'),'cancel without consent mutation');
DO $$ DECLARE n text; oid_ oid; BEGIN
 FOREACH n IN ARRAY ARRAY['guard_meetup_mutual_eligibility','guard_meetup_proposal_mutual_eligibility','guard_meetup_proposal_response_mutual_eligibility'] LOOP
  oid_ := to_regprocedure('wingward_private.'||n||'()');
  PERFORM pg_temp.assert_true(oid_ IS NOT NULL,'private guard exists');
  PERFORM pg_temp.assert_true((SELECT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc WHERE oid=oid_),'fixed definer search path');
  PERFORM pg_temp.assert_true(NOT has_function_privilege('anon',oid_,'EXECUTE') AND NOT has_function_privilege('authenticated',oid_,'EXECUTE') AND NOT has_function_privilege('service_role',oid_,'EXECUTE'),'private execute revoked');
 END LOOP;
END;$$;
SELECT 'PASS SQL23: meetup child eligibility, lineage and narrow cleanup';
ROLLBACK;
