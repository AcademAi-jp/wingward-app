BEGIN;
SET LOCAL statement_timeout='10s';
INSERT INTO auth.users(id,email) VALUES
('00000000-0000-0000-0000-00000000f901','b2-lineage-a@example.invalid'),
('00000000-0000-0000-0000-00000000f902','b2-lineage-b@example.invalid'),
('00000000-0000-0000-0000-00000000f903','b2-lineage-c@example.invalid');
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000f901' WHERE auth_user_id='00000000-0000-0000-0000-00000000f901';
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000f902' WHERE auth_user_id='00000000-0000-0000-0000-00000000f902';
UPDATE public.user_profiles SET id='10000000-0000-0000-0000-00000000f903' WHERE auth_user_id='00000000-0000-0000-0000-00000000f903';
UPDATE public.user_profiles SET age_verified_at=now(),onboarding_settings_completed_at=now(),dating_market='JP',gender_identity='nonbinary',preferred_genders=ARRAY['nonbinary'],preference_mode='selected' WHERE id IN ('10000000-0000-0000-0000-00000000f901','10000000-0000-0000-0000-00000000f902','10000000-0000-0000-0000-00000000f903');
SET LOCAL ROLE service_role;
INSERT INTO public.matches(id,user_a_id,user_b_id) VALUES ('20000000-0000-0000-0000-00000000f901','10000000-0000-0000-0000-00000000f901','10000000-0000-0000-0000-00000000f902');
INSERT INTO public.fox_conversations(id,match_id) VALUES ('30000000-0000-0000-0000-00000000f901','20000000-0000-0000-0000-00000000f901');
INSERT INTO public.fox_conversation_messages(conversation_id,speaker_user_id,content,round_number) VALUES ('30000000-0000-0000-0000-00000000f901','10000000-0000-0000-0000-00000000f902','synthetic lineage probe',1);
DO $$ BEGIN
 BEGIN
  UPDATE public.matches SET user_b_id='10000000-0000-0000-0000-00000000f903' WHERE id='20000000-0000-0000-0000-00000000f901';
  RAISE EXCEPTION 'FAIL parent lineage: eligible replacement was accepted';
 EXCEPTION WHEN check_violation THEN
  IF SQLERRM NOT LIKE '%matching eligibility%' THEN RAISE; END IF;
 END;
 BEGIN
  UPDATE public.matches SET user_a_id='10000000-0000-0000-0000-00000000f902',user_b_id='10000000-0000-0000-0000-00000000f901' WHERE id='20000000-0000-0000-0000-00000000f901';
  RAISE EXCEPTION 'FAIL parent lineage: reversal was accepted';
 EXCEPTION WHEN check_violation THEN
  IF SQLERRM NOT LIKE '%matching eligibility%' THEN RAISE; END IF;
 END;
 IF NOT EXISTS (SELECT 1 FROM public.matches WHERE id='20000000-0000-0000-0000-00000000f901' AND user_a_id='10000000-0000-0000-0000-00000000f901' AND user_b_id='10000000-0000-0000-0000-00000000f902') THEN
  RAISE EXCEPTION 'FAIL parent lineage: original pair changed';
 END IF;
END $$;
SELECT 'parent replacement and reversal rejected: PASS';
ROLLBACK;
