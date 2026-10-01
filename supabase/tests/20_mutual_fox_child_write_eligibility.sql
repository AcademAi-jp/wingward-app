-- Synthetic fixture; each invocation rolls back all rows and temporary helpers.
BEGIN;
SET LOCAL statement_timeout='15s';
DELETE FROM public.matches WHERE id IN ('20000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f502');
DELETE FROM auth.users WHERE id IN ('00000000-0000-0000-0000-00000000f501','00000000-0000-0000-0000-00000000f502','00000000-0000-0000-0000-00000000f503','00000000-0000-0000-0000-00000000f504') AND email IN ('b2-fox-child-sql20-a@example.invalid','b2-fox-child-sql20-b@example.invalid','b2-fox-child-sql20-c@example.invalid','b2-fox-child-sql20-d@example.invalid');
INSERT INTO auth.users(id,email) VALUES ('00000000-0000-0000-0000-00000000f501','b2-fox-child-sql20-a@example.invalid'),('00000000-0000-0000-0000-00000000f502','b2-fox-child-sql20-b@example.invalid'),('00000000-0000-0000-0000-00000000f503','b2-fox-child-sql20-c@example.invalid'),('00000000-0000-0000-0000-00000000f504','b2-fox-child-sql20-d@example.invalid');
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000f501',nickname='B2 Fox SQL20 A',birth_date=DATE '1990-01-01',age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['nonbinary'],preference_mode='selected' WHERE auth_user_id='00000000-0000-0000-0000-00000000f501';
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000f502',nickname='B2 Fox SQL20 B',birth_date=DATE '1990-01-01',age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['nonbinary'],preference_mode='selected' WHERE auth_user_id='00000000-0000-0000-0000-00000000f502';
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000f503',nickname='B2 Fox SQL20 C',birth_date=DATE '1990-01-01',age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='woman',preferred_genders=ARRAY['nonbinary'],preference_mode='selected' WHERE auth_user_id='00000000-0000-0000-0000-00000000f503';
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000f504',nickname='B2 Fox SQL20 D',birth_date=DATE '1990-01-01',age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['woman'],preference_mode='selected' WHERE auth_user_id='00000000-0000-0000-0000-00000000f504';
CREATE OR REPLACE FUNCTION pg_temp.reset_pair(p_status text) RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
 DELETE FROM public.matches WHERE id='20000000-0000-0000-0000-00000000f501';
 UPDATE public.user_profiles SET age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['nonbinary'],preference_mode='selected' WHERE id IN ('10000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f502');
 INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES ('20000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f502',p_status);
END;$fn$;
CREATE OR REPLACE FUNCTION pg_temp.reset_second_pair(p_status text) RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
 DELETE FROM public.matches WHERE id='20000000-0000-0000-0000-00000000f502';
 UPDATE public.user_profiles SET age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='woman',preferred_genders=ARRAY['nonbinary'],preference_mode='selected' WHERE id='10000000-0000-0000-0000-00000000f503';
 UPDATE public.user_profiles SET age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['woman'],preference_mode='selected' WHERE id='10000000-0000-0000-0000-00000000f504';
 INSERT INTO public.matches(id,user_a_id,user_b_id,status) VALUES ('20000000-0000-0000-0000-00000000f502','10000000-0000-0000-0000-00000000f503','10000000-0000-0000-0000-00000000f504',p_status);
END;$fn$;
CREATE OR REPLACE FUNCTION pg_temp.expect_rejected(p_statement text,p_expected_error text) RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
 BEGIN
  EXECUTE p_statement;
  RAISE EXCEPTION 'expected guarded statement to fail';
 EXCEPTION WHEN check_violation THEN
  IF SQLERRM<>p_expected_error THEN RAISE EXCEPTION 'unexpected guard error: %',SQLERRM; END IF;
 END;
END;$fn$;
DO $fn$
BEGIN
 PERFORM pg_temp.reset_pair('fox_conversation_in_progress'); PERFORM pg_temp.reset_second_pair('fox_conversation_in_progress');
 INSERT INTO public.fox_conversations(id,match_id,status,purpose,total_rounds) VALUES ('30000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501','pending','compatibility',10);
 UPDATE public.fox_conversations SET current_round=1 WHERE id='30000000-0000-0000-0000-00000000f501';
 IF NOT EXISTS(SELECT 1 FROM public.fox_conversations WHERE id='30000000-0000-0000-0000-00000000f501' AND current_round=1) THEN RAISE EXCEPTION 'FAIL 20a: eligible fox conversation INSERT/UPDATE'; END IF;
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversations SET match_id=''20000000-0000-0000-0000-00000000f502'' WHERE id=''30000000-0000-0000-0000-00000000f501''','fox conversation write is not eligible');
 UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f502';
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversations SET current_round=2 WHERE id=''30000000-0000-0000-0000-00000000f501''','fox conversation write is not eligible');
 UPDATE public.fox_conversations SET cache_hit_tokens=1,input_tokens=20,output_tokens=30 WHERE id='30000000-0000-0000-0000-00000000f501';
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversations SET input_tokens=19 WHERE id=''30000000-0000-0000-0000-00000000f501''','fox conversation write is not eligible');
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversations SET output_tokens=-1 WHERE id=''30000000-0000-0000-0000-00000000f501''','fox conversation write is not eligible');
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversations SET output_tokens=NULL WHERE id=''30000000-0000-0000-0000-00000000f501''','fox conversation write is not eligible');
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversations SET status=''failed'',current_round=2 WHERE id=''30000000-0000-0000-0000-00000000f501''','fox conversation write is not eligible');
 UPDATE public.fox_conversations SET status='failed' WHERE id='30000000-0000-0000-0000-00000000f501';
 DELETE FROM public.fox_conversations WHERE id='30000000-0000-0000-0000-00000000f501';
 PERFORM pg_temp.expect_rejected('INSERT INTO public.fox_conversations(id,match_id,status,purpose,total_rounds) VALUES (''30000000-0000-0000-0000-00000000f501'',''20000000-0000-0000-0000-00000000f501'',''pending'',''compatibility'',10)','fox conversation write is not eligible');
 RAISE NOTICE 'PASS 20a: fox conversation behavior and narrow cleanup rules';
END;$fn$;
DO $fn$
BEGIN
 PERFORM pg_temp.reset_pair('fox_conversation_in_progress'); PERFORM pg_temp.reset_second_pair('fox_conversation_in_progress');
 INSERT INTO public.fox_conversations(id,match_id,status,purpose,total_rounds) VALUES ('30000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501','in_progress','compatibility',10),('30000000-0000-0000-0000-00000000f502','20000000-0000-0000-0000-00000000f502','in_progress','compatibility',10);
 INSERT INTO public.fox_conversation_messages(id,conversation_id,speaker_user_id,content,round_number) VALUES ('40000000-0000-0000-0000-00000000f501','30000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f502','eligible fox message',1);
 UPDATE public.fox_conversation_messages SET content='eligible fox message updated' WHERE id='40000000-0000-0000-0000-00000000f501';
 IF NOT EXISTS(SELECT 1 FROM public.fox_conversation_messages WHERE id='40000000-0000-0000-0000-00000000f501' AND content='eligible fox message updated') THEN RAISE EXCEPTION 'FAIL 20b: eligible fox message INSERT/UPDATE'; END IF;
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversation_messages SET conversation_id=''30000000-0000-0000-0000-00000000f502'' WHERE id=''40000000-0000-0000-0000-00000000f501''','fox conversation message write is not eligible');
 UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f502';
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversation_messages SET content=''revoked update'' WHERE id=''40000000-0000-0000-0000-00000000f501''','fox conversation message write is not eligible');
 PERFORM pg_temp.expect_rejected('INSERT INTO public.fox_conversation_messages(id,conversation_id,speaker_user_id,content,round_number) VALUES (''40000000-0000-0000-0000-00000000f521'',''30000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f502'',''revoked insert'',2)','fox conversation message write is not eligible');
 RAISE NOTICE 'PASS 20b: fox conversation message behavior and lineage';
END;$fn$;
DO $fn$
BEGIN
 PERFORM pg_temp.reset_pair('partner_chat_started'); PERFORM pg_temp.reset_second_pair('partner_chat_started');
 INSERT INTO public.fox_conversations(id,match_id,status,purpose,total_rounds,current_round,completed_at) VALUES ('30000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501','completed','compatibility',10,10,now()),('30000000-0000-0000-0000-00000000f502','20000000-0000-0000-0000-00000000f502','completed','compatibility',10,10,now());
 INSERT INTO public.partner_fox_chats(id,match_id,user_id,partner_user_id,created_at) VALUES ('50000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f502','2026-09-07T00:00:00Z');
 UPDATE public.partner_fox_chats SET created_at='2026-09-07T00:00:01Z' WHERE id='50000000-0000-0000-0000-00000000f501';
 IF NOT EXISTS(SELECT 1 FROM public.partner_fox_chats WHERE id='50000000-0000-0000-0000-00000000f501' AND created_at='2026-09-07T00:00:01Z') THEN RAISE EXCEPTION 'FAIL 20c: eligible partner Fox chat INSERT/UPDATE'; END IF;
 PERFORM pg_temp.expect_rejected('UPDATE public.partner_fox_chats SET match_id=''20000000-0000-0000-0000-00000000f502'',user_id=''10000000-0000-0000-0000-00000000f503'',partner_user_id=''10000000-0000-0000-0000-00000000f504'' WHERE id=''50000000-0000-0000-0000-00000000f501''','partner fox chat write is not eligible');
 UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f502';
 PERFORM pg_temp.expect_rejected('UPDATE public.partner_fox_chats SET created_at=''2026-09-07T00:00:02Z'' WHERE id=''50000000-0000-0000-0000-00000000f501''','partner fox chat write is not eligible');
 PERFORM pg_temp.expect_rejected('INSERT INTO public.partner_fox_chats(id,match_id,user_id,partner_user_id) VALUES (''50000000-0000-0000-0000-00000000f531'',''20000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f502'',''10000000-0000-0000-0000-00000000f501'')','partner fox chat write is not eligible');
 RAISE NOTICE 'PASS 20c: partner Fox chat behavior and lineage';
END;$fn$;
DO $fn$
BEGIN
 PERFORM pg_temp.reset_pair('partner_chat_started'); PERFORM pg_temp.reset_second_pair('partner_chat_started');
 INSERT INTO public.fox_conversations(id,match_id,status,purpose,total_rounds,current_round,completed_at) VALUES ('30000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501','completed','compatibility',10,10,now()),('30000000-0000-0000-0000-00000000f502','20000000-0000-0000-0000-00000000f502','completed','compatibility',10,10,now());
 INSERT INTO public.partner_fox_chats(id,match_id,user_id,partner_user_id) VALUES ('50000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f502'),('50000000-0000-0000-0000-00000000f502','20000000-0000-0000-0000-00000000f502','10000000-0000-0000-0000-00000000f503','10000000-0000-0000-0000-00000000f504');
 INSERT INTO public.partner_fox_messages(id,chat_id,role,content) VALUES ('60000000-0000-0000-0000-00000000f501','50000000-0000-0000-0000-00000000f501','user','eligible partner Fox message');
 UPDATE public.partner_fox_messages SET content='eligible partner Fox message updated' WHERE id='60000000-0000-0000-0000-00000000f501';
 IF NOT EXISTS(SELECT 1 FROM public.partner_fox_messages WHERE id='60000000-0000-0000-0000-00000000f501' AND content='eligible partner Fox message updated') THEN RAISE EXCEPTION 'FAIL 20d: eligible partner Fox message INSERT/UPDATE'; END IF;
 PERFORM pg_temp.expect_rejected('UPDATE public.partner_fox_messages SET chat_id=''50000000-0000-0000-0000-00000000f502'' WHERE id=''60000000-0000-0000-0000-00000000f501''','partner fox message write is not eligible');
 UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f502';
 PERFORM pg_temp.expect_rejected('UPDATE public.partner_fox_messages SET content=''revoked update'' WHERE id=''60000000-0000-0000-0000-00000000f501''','partner fox message write is not eligible');
 PERFORM pg_temp.expect_rejected('INSERT INTO public.partner_fox_messages(id,chat_id,role,content) VALUES (''60000000-0000-0000-0000-00000000f541'',''50000000-0000-0000-0000-00000000f501'',''user'',''revoked insert'')','partner fox message write is not eligible');
 RAISE NOTICE 'PASS 20d: partner Fox message behavior and lineage';
END;$fn$;
DO $fn$
BEGIN
 PERFORM pg_temp.reset_pair('fox_conversation_completed'); PERFORM pg_temp.reset_second_pair('fox_conversation_completed');
 INSERT INTO public.fox_conversations(id,match_id,status,purpose,total_rounds,current_round,completed_at) VALUES ('30000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501','completed','compatibility',10,10,now()),('30000000-0000-0000-0000-00000000f502','20000000-0000-0000-0000-00000000f502','completed','compatibility',10,10,now());
 INSERT INTO public.interaction_dna_scores(id,match_id,feature_id,feature_name,raw_score,normalized_score,confidence,evidence,source_phase) VALUES ('70000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501',1,'communication',0.600,0.600,0.800,'{}'::jsonb,'fox_conversation');
 UPDATE public.interaction_dna_scores SET normalized_score=0.700 WHERE id='70000000-0000-0000-0000-00000000f501';
 IF NOT EXISTS(SELECT 1 FROM public.interaction_dna_scores WHERE id='70000000-0000-0000-0000-00000000f501' AND normalized_score=0.700) THEN RAISE EXCEPTION 'FAIL 20e: eligible DNA score INSERT/UPDATE'; END IF;
 PERFORM pg_temp.expect_rejected('UPDATE public.interaction_dna_scores SET match_id=''20000000-0000-0000-0000-00000000f502'' WHERE id=''70000000-0000-0000-0000-00000000f501''','interaction score write is not eligible');
 UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f502';
 PERFORM pg_temp.expect_rejected('UPDATE public.interaction_dna_scores SET normalized_score=0.800 WHERE id=''70000000-0000-0000-0000-00000000f501''','interaction score write is not eligible');
 PERFORM pg_temp.expect_rejected('INSERT INTO public.interaction_dna_scores(id,match_id,feature_id,feature_name,raw_score,normalized_score,confidence,evidence,source_phase) VALUES (''70000000-0000-0000-0000-00000000f551'',''20000000-0000-0000-0000-00000000f501'',2,''values'',0.400,0.400,0.700,''{}''::jsonb,''fox_conversation'')','interaction score write is not eligible');
 RAISE NOTICE 'PASS 20e: DNA score behavior and lineage';
END;$fn$;
CREATE OR REPLACE FUNCTION pg_temp.expect_role_rejected(p_statement text,p_expected_sqlstate text,p_expected_message text) RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE v_succeeded boolean:=false;v_sqlstate text;v_message text;
BEGIN
 BEGIN EXECUTE p_statement; v_succeeded:=true;
 EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_sqlstate=RETURNED_SQLSTATE,v_message=MESSAGE_TEXT; END;
 IF v_succeeded THEN RAISE EXCEPTION 'expected role-restricted statement to fail'; END IF;
 IF v_sqlstate<>p_expected_sqlstate OR v_message<>p_expected_message THEN RAISE EXCEPTION 'unexpected role error: state=%, message=%',v_sqlstate,v_message; END IF;
END;$fn$;
DO $fn$
BEGIN
 PERFORM pg_temp.reset_pair('direct_chat_active'); PERFORM pg_temp.reset_second_pair('direct_chat_active');
 INSERT INTO public.meetups(id,match_id,initiator_id,status) VALUES ('80000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f501','intent_pending'),('80000000-0000-0000-0000-00000000f502','20000000-0000-0000-0000-00000000f502','10000000-0000-0000-0000-00000000f503','intent_pending');
 INSERT INTO public.fox_conversations(id,match_id,status,purpose,meetup_id,total_rounds) VALUES ('30000000-0000-0000-0000-00000000f501','20000000-0000-0000-0000-00000000f501','completed','compatibility',NULL,10),('30000000-0000-0000-0000-00000000f561','20000000-0000-0000-0000-00000000f501','pending','scheduling','80000000-0000-0000-0000-00000000f501',10);
 IF NOT EXISTS(SELECT 1 FROM public.fox_conversations WHERE id='30000000-0000-0000-0000-00000000f561' AND purpose='scheduling' AND meetup_id='80000000-0000-0000-0000-00000000f501') THEN RAISE EXCEPTION 'FAIL 20f: eligible scheduling binding was not inserted'; END IF;
 PERFORM pg_temp.expect_rejected('INSERT INTO public.fox_conversations(id,match_id,status,purpose,meetup_id,total_rounds) VALUES (''30000000-0000-0000-0000-00000000f562'',''20000000-0000-0000-0000-00000000f501'',''pending'',''scheduling'',''80000000-0000-0000-0000-00000000f502'',10)','fox conversation write is not eligible');
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversations SET meetup_id=NULL WHERE id=''30000000-0000-0000-0000-00000000f561''','fox conversation write is not eligible');
 PERFORM pg_temp.expect_rejected('UPDATE public.fox_conversations SET meetup_id=''80000000-0000-0000-0000-00000000f501'' WHERE id=''30000000-0000-0000-0000-00000000f501''','fox conversation write is not eligible');
 RAISE NOTICE 'PASS 20f: scheduling binding and mismatched meetup rejection';
END;$fn$;
-- Hosted existing-project defaults grant anon table verbs. The historical
-- grants migration adds no anon grants but does not revoke these inherited ACLs.
-- Anonymous denial here therefore depends on the RLS helper EXECUTE revocations;
-- assert both layers explicitly instead of accepting a table-permission fallback.
DO $fn$
DECLARE v_verb text;v_helper text;
BEGIN
 FOREACH v_verb IN ARRAY ARRAY['INSERT','UPDATE','DELETE'] LOOP
  IF NOT pg_catalog.has_table_privilege('anon','public.partner_fox_chats',v_verb) THEN RAISE EXCEPTION 'FAIL 20i: hosted default anon % table grant is missing',v_verb; END IF;
 END LOOP;
 FOREACH v_helper IN ARRAY ARRAY['public.get_user_profile_id()','public.are_match_participants_age_verified(uuid)'] LOOP
  IF pg_catalog.has_function_privilege('anon',v_helper,'EXECUTE') THEN RAISE EXCEPTION 'FAIL 20i: anon can execute RLS helper %',v_helper; END IF;
 END LOOP;
 RAISE NOTICE 'PASS 20i: hosted default anon table grants and revoked RLS helper EXECUTE';
END;$fn$;
DO $fn$ BEGIN PERFORM pg_temp.reset_pair('partner_chat_started'); END;$fn$;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000f501',true);
SET LOCAL ROLE authenticated;
INSERT INTO public.partner_fox_chats(id,match_id,user_id,partner_user_id) VALUES ('50000000-0000-0000-0000-00000000f571','20000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f501','10000000-0000-0000-0000-00000000f502');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000f501',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_role_rejected('INSERT INTO public.partner_fox_chats(id,match_id,user_id,partner_user_id) VALUES (''50000000-0000-0000-0000-00000000f572'',''20000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f503'')','23514','partner fox chat write is not eligible');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000f502',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_role_rejected('INSERT INTO public.partner_fox_chats(id,match_id,user_id,partner_user_id) VALUES (''50000000-0000-0000-0000-00000000f573'',''20000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f502'')','23514','partner fox chat write is not eligible');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',NULL,true);
SET LOCAL ROLE anon;
SELECT pg_temp.expect_role_rejected('INSERT INTO public.partner_fox_chats(id,match_id,user_id,partner_user_id) VALUES (''50000000-0000-0000-0000-00000000f574'',''20000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f502'')','42501','permission denied for function get_user_profile_id');
RESET ROLE;
UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f502';
SELECT set_config('request.jwt.claim.sub',NULL,true);
SET LOCAL ROLE anon;
SELECT pg_temp.expect_role_rejected('INSERT INTO public.partner_fox_chats(id,match_id,user_id,partner_user_id) VALUES (''50000000-0000-0000-0000-00000000f575'',''20000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f501'',''10000000-0000-0000-0000-00000000f502'')','42501','permission denied for function get_user_profile_id');
RESET ROLE;
DO $fn$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.partner_fox_chats WHERE id='50000000-0000-0000-0000-00000000f571') THEN RAISE EXCEPTION 'FAIL 20i: authenticated owner INSERT was not retained'; END IF;
 IF EXISTS(SELECT 1 FROM public.partner_fox_chats WHERE id IN ('50000000-0000-0000-0000-00000000f572','50000000-0000-0000-0000-00000000f573','50000000-0000-0000-0000-00000000f574','50000000-0000-0000-0000-00000000f575')) THEN RAISE EXCEPTION 'FAIL 20i: forged or anonymous INSERT left a row'; END IF;
 RAISE NOTICE 'PASS 20i: authenticated owner, forged partner, and anonymous actor gates';
END;$fn$;
DO $fn$
DECLARE v_table text;v_trigger text;v_function_name text;v_expected_error text;v_oid oid;v_is_definer boolean;v_config text[];v_definition text;
BEGIN
 FOR v_table,v_trigger,v_function_name,v_expected_error IN SELECT * FROM (VALUES
 ('fox_conversations','fox_conversations_guard_mutual_eligibility','guard_fox_conversation_mutual_eligibility','fox conversation write is not eligible'),
 ('fox_conversation_messages','fox_conversation_messages_guard_mutual_eligibility','guard_fox_conversation_message_mutual_eligibility','fox conversation message write is not eligible'),
 ('partner_fox_chats','partner_fox_chats_guard_mutual_eligibility','guard_partner_fox_chat_mutual_eligibility','partner fox chat write is not eligible'),
 ('partner_fox_messages','partner_fox_messages_guard_mutual_eligibility','guard_partner_fox_message_mutual_eligibility','partner fox message write is not eligible'),
 ('interaction_dna_scores','interaction_dna_scores_guard_mutual_eligibility','guard_interaction_dna_score_mutual_eligibility','interaction score write is not eligible')) AS item(table_name,trigger_name,function_name,error_text)
 LOOP
  v_oid:=pg_catalog.to_regprocedure('wingward_private.'||v_function_name||'()');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'FAIL 20h: missing private function %',v_function_name; END IF;
  SELECT p.prosecdef,p.proconfig,pg_catalog.pg_get_functiondef(p.oid) INTO v_is_definer,v_config,v_definition FROM pg_catalog.pg_proc AS p WHERE p.oid=v_oid;
  IF NOT v_is_definer THEN RAISE EXCEPTION 'FAIL 20h: % is not SECURITY DEFINER',v_function_name; END IF;
  IF NOT coalesce('search_path=""'=ANY(v_config),false) THEN RAISE EXCEPTION 'FAIL 20h: % does not fix search_path',v_function_name; END IF;
  IF pg_catalog.strpos(v_definition,v_expected_error)=0 THEN RAISE EXCEPTION 'FAIL 20h: % has the wrong fixed error',v_function_name; END IF;
  IF pg_catalog.has_function_privilege('anon',v_oid,'EXECUTE') OR pg_catalog.has_function_privilege('authenticated',v_oid,'EXECUTE') OR pg_catalog.has_function_privilege('service_role',v_oid,'EXECUTE') OR EXISTS(SELECT 1 FROM pg_catalog.aclexplode(coalesce((SELECT p.proacl FROM pg_catalog.pg_proc AS p WHERE p.oid=v_oid),pg_catalog.acldefault('f',(SELECT p.proowner FROM pg_catalog.pg_proc AS p WHERE p.oid=v_oid)))) AS privilege WHERE privilege.grantee=0 AND privilege.privilege_type='EXECUTE') THEN RAISE EXCEPTION 'FAIL 20h: % has an API or PUBLIC EXECUTE grant',v_function_name; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_trigger AS trigger_row JOIN pg_catalog.pg_class AS table_row ON table_row.oid=trigger_row.tgrelid JOIN pg_catalog.pg_namespace AS table_schema ON table_schema.oid=table_row.relnamespace JOIN pg_catalog.pg_proc AS function_row ON function_row.oid=trigger_row.tgfoid JOIN pg_catalog.pg_namespace AS function_schema ON function_schema.oid=function_row.pronamespace WHERE table_schema.nspname='public' AND table_row.relname=v_table AND trigger_row.tgname=v_trigger AND function_schema.nspname='wingward_private' AND function_row.proname=v_function_name AND pg_catalog.pg_get_triggerdef(trigger_row.oid) LIKE '%BEFORE INSERT OR UPDATE%' AND trigger_row.tgenabled='O' AND NOT trigger_row.tgisinternal) THEN RAISE EXCEPTION 'FAIL 20h: % is not wired for BEFORE INSERT OR UPDATE',v_table; END IF;
 END LOOP;
 RAISE NOTICE 'PASS 20h: five private guards, ACLs, errors, and trigger wiring';
END;$fn$;
DO $fn$ BEGIN RAISE NOTICE 'PASS SQL20: Fox child behavior, lineage, scheduling, actor, ACL, and cleanup checks'; END;$fn$;
ROLLBACK;
