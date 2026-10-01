-- Local synthetic regression only. The transaction rolls back all data and clock substitutions.
BEGIN;
SET LOCAL statement_timeout='20s';
CREATE TEMP TABLE seven_assertions(label text PRIMARY KEY);
CREATE FUNCTION pg_temp.seven_ok(value boolean,label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL %',label;END IF;
 INSERT INTO seven_assertions VALUES(label);
END $$;
-- This executes the production function and its clause-deleted mutation.
-- Both the mutation and all receipts exist only inside this rollback fixture.
CREATE FUNCTION pg_temp.quota_control(actor uuid,op text,label text,clause text) RETURNS void LANGUAGE plpgsql AS $quota$
DECLARE original text; mutated text; receipt record;
BEGIN
 original:=pg_get_functiondef('wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean)'::regprocedure);
 SELECT * INTO receipt FROM wingward_private.reserve_judge_provider_core(actor,op,gen_random_uuid(),true);
 PERFORM pg_temp.seven_ok(receipt.outcome='denied',label||' boundary denies');
 mutated:=replace(original,clause,'false');
 IF mutated=original THEN RAISE EXCEPTION 'Quota mutation did not match';END IF;
 EXECUTE mutated;
 SELECT * INTO receipt FROM wingward_private.reserve_judge_provider_core(actor,op,gen_random_uuid(),true);
 EXECUTE original;
 PERFORM pg_temp.seven_ok(receipt.outcome='allowed',label||' clause-deleted mutation allows');
 DELETE FROM wingward_private.judge_provider_reservations WHERE reservation_id=receipt.reservation_id;
END $quota$;
DO $test$
DECLARE
 actors uuid[]:=ARRAY['970f08d1-c1b8-572b-ad42-00277c8facbb','69ef089a-ff8e-5344-8335-8b931364b064','bc7b2853-234f-5191-a720-b88893217597','a8a78dc4-02c2-54a2-b205-486bd44d3387','b0caf6bb-4481-5ac0-ba8f-cbab9baef418','56f96c3d-6040-5c57-b6ad-c59284ba4f3c','907cd918-c426-529b-8d36-39aaae2ae1a6']::uuid[];
 slots text[]:=ARRAY['judge01','judge02','judge03','judge04','judge05','owner01','owner02'];
 bot uuid:='e7c595cb-ff44-5611-aff1-44fb0ca8bf58'; au uuid; bot_auth uuid:=gen_random_uuid();
 qa uuid:='0ed47fef-1266-5fa9-8852-0a2c6b9dc741';qa_auth uuid:=gen_random_uuid();
 test_clock timestamptz:='2026-10-01T11:00:00Z';deadline timestamptz:='2026-10-13T19:00:00Z';
 definition text; original_access text; original_core text; i integer;r record;k uuid;marker jsonb;legacy jsonb;rejected boolean;role_name text;
BEGIN
 SELECT to_jsonb(b) INTO legacy FROM wingward_private.judge_provider_budget b;
 original_access:=pg_get_functiondef('public.check_judge_access(uuid)'::regprocedure);
 original_core:=pg_get_functiondef('wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean)'::regprocedure);
 FOREACH definition IN ARRAY ARRAY[
  pg_get_functiondef('public.check_judge_access(uuid)'::regprocedure),
  pg_get_functiondef('wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean)'::regprocedure)
 ] LOOP
  EXECUTE replace(definition,'clock_timestamp()',quote_literal(test_clock)||'::timestamptz');
 END LOOP;
 INSERT INTO auth.users(id,email) VALUES(bot_auth,'seven-fictional-peer@example.invalid');
 UPDATE public.user_profiles SET id=bot WHERE auth_user_id=bot_auth;
 FOR i IN 1..7 LOOP
  au:=gen_random_uuid();
  marker:=jsonb_build_object('wingward_judge_cohort','shipaton-20261001','wingward_judge_slot',slots[i],'wingward_judge_profile_id',actors[i],
   'wingward_provision_batch','shipaton-seven-20261001','wingward_provision_slot',slots[i]);
  INSERT INTO auth.users(id,email,raw_app_meta_data,email_confirmed_at) VALUES(au,slots[i]||'@seven.example.invalid',marker,test_clock);
  UPDATE public.user_profiles SET id=actors[i] WHERE auth_user_id=au;
  INSERT INTO wingward_private.judge_accounts(slot,actor_user_id,auth_user_id,counterpart_user_id,account_kind,issued_at,expires_at,access_scope)
  VALUES(slots[i],actors[i],au,bot,CASE WHEN i<=5 THEN 'judge' ELSE 'owner' END,test_clock-interval '1 minute',deadline,'shipaton-seven-20261001');
  SELECT * INTO r FROM public.check_judge_access(actors[i]);
  PERFORM pg_temp.seven_ok(r.outcome='allowed' AND r.expires_at=deadline,'fresh access '||slots[i]);
  SELECT * INTO r FROM public.check_judge_webhook_access(au);
  PERFORM pg_temp.seven_ok(r.outcome='allowed','fresh webhook '||slots[i]);
  UPDATE auth.users SET raw_app_meta_data=marker-'wingward_provision_batch' WHERE id=au;
  SELECT * INTO r FROM public.check_judge_access(actors[i]);
  PERFORM pg_temp.seven_ok(r.outcome='denied','missing authoritative fresh batch '||slots[i]);
  UPDATE auth.users SET raw_app_meta_data=marker WHERE id=au;
  UPDATE auth.users SET raw_app_meta_data=marker||jsonb_build_object('wingward_provision_slot','wrong') WHERE id=au;
  SELECT * INTO r FROM public.check_judge_access(actors[i]);
  PERFORM pg_temp.seven_ok(r.outcome='denied','mismatched fresh provision slot '||slots[i]);
  UPDATE auth.users SET raw_app_meta_data=marker WHERE id=au;
  IF i<=5 THEN
   UPDATE wingward_private.judge_accounts SET access_scope=NULL WHERE slot=slots[i];
   SELECT * INTO r FROM public.check_judge_access(actors[i]);
   PERFORM pg_temp.seven_ok(r.outcome='denied','fresh judge missing scope cannot use legacy ledger '||slots[i]);
   SELECT * INTO r FROM public.reserve_judge_provider_operation(actors[i],'ward_chat',gen_random_uuid());
   PERFORM pg_temp.seven_ok(r.outcome='denied','fresh judge missing scope paid request denied '||slots[i]);
   UPDATE wingward_private.judge_accounts SET access_scope=('shipaton-'||'seven-20261001') WHERE slot=slots[i];
  END IF;
 END LOOP;
 SELECT * INTO r FROM public.reserve_judge_provider_operation(actors[1],'ward_chat',gen_random_uuid());
 PERFORM pg_temp.seven_ok(r.outcome='denied','missing policy remains closed without monetary prerequisite');
 SELECT * INTO r FROM public.reserve_judge_provider_operation(actors[1],'ward_chat',gen_random_uuid());
 PERFORM pg_temp.seven_ok(r.outcome='denied','empty policy closed');
 INSERT INTO wingward_private.judge_provider_policies(operation,reservation_usd_micros,daily_limit,minimum_interval_ms,max_units,max_seconds,enabled,pricing_evidence,server_bound_enforced)
 VALUES('ward_chat',100000,12,1000,20000,180,true,'Synthetic fixed reservation',true),
 ('voice_session',100000,12,1000,20000,180,true,'Synthetic fixed reservation',true);
 FOR i IN 1..7 LOOP
  k:=gen_random_uuid();
  SELECT * INTO r FROM public.reserve_judge_provider_operation(actors[i],'ward_chat',k);
  PERFORM pg_temp.seven_ok(r.outcome='allowed','new reservation '||slots[i]);
  SELECT * INTO r FROM public.reserve_judge_provider_operation(actors[i],'ward_chat',k);
  PERFORM pg_temp.seven_ok(r.outcome='replayed','no second paid reservation '||slots[i]);
 END LOOP;
 PERFORM pg_temp.seven_ok((SELECT reserved_usd_micros=0 FROM wingward_private.judge_seven_provider_budget),'inactive fresh ledger remains unchanged');
 PERFORM pg_temp.seven_ok((SELECT count(*)=7 FROM wingward_private.judge_provider_reservations WHERE budget_scope='shipaton-seven-20261001'),'seven reservations tagged to fresh ledger');
 PERFORM pg_temp.seven_ok((SELECT sum(reserved_usd_micros)=0 FROM wingward_private.judge_provider_reservations WHERE budget_scope='shipaton-seven-20261001'),'new receipts do not calculate monetary amounts');
 PERFORM pg_temp.seven_ok((SELECT to_jsonb(b)=legacy FROM wingward_private.judge_provider_budget b),'legacy budget unchanged');
 SELECT * INTO r FROM public.reserve_judge_provider_operation(actors[1],'voice_session',gen_random_uuid());
 PERFORM pg_temp.seven_ok(r.outcome='denied','voice cannot use generic token reservation');
 -- Saturate only the inactive synthetic ledger to prove it cannot block access.
 UPDATE wingward_private.judge_seven_provider_budget SET prior_spend_usd_micros=10000000,prior_spend_evidence='Synthetic inactive full ledger';
 SELECT * INTO r FROM wingward_private.reserve_judge_provider_core(actors[1],'voice_session',gen_random_uuid(),true);
 PERFORM pg_temp.seven_ok(r.outcome='allowed','voice allowed despite inactive ledger being full');
 SELECT * INTO r FROM wingward_private.reserve_judge_provider_core(actors[2],'voice_session',gen_random_uuid(),true);
 PERFORM pg_temp.seven_ok(r.outcome='allowed','another voice reservation ignores former dollar ceiling');
 INSERT INTO wingward_private.judge_provider_policies(operation,reservation_usd_micros,daily_limit,minimum_interval_ms,max_units,max_seconds,enabled,pricing_evidence) VALUES('personas_generate',100000,1,1000,20000,180,true,'Synthetic Mistral reservation');
 k:=gen_random_uuid();
 SELECT * INTO r FROM public.reserve_judge_provider_operation(actors[3],'personas_generate',k);
 PERFORM pg_temp.seven_ok(r.outcome='allowed','operation allowed with an inactive full ledger');
 SELECT * INTO r FROM public.reserve_judge_provider_operation(actors[3],'personas_generate',k);
 PERFORM pg_temp.seven_ok(r.outcome='replayed','receipt replay cannot repeat a provider call');
 SELECT * INTO r FROM public.reserve_judge_provider_operation(actors[3],'personas_generate',gen_random_uuid());
 PERFORM pg_temp.seven_ok(r.outcome='denied','operation quota remains enforced');
 PERFORM pg_temp.seven_ok((SELECT prior_spend_usd_micros=10000000 AND reserved_usd_micros=0 FROM wingward_private.judge_seven_provider_budget),'no monetary ledger calculation performed');
 -- All nine providers ignore money while retaining per-operation receipt controls.
 EXECUTE replace(original_core,'clock_timestamp()',quote_literal(test_clock+interval '2 minutes')||'::timestamptz');
 FOR definition IN SELECT unnest(ARRAY['personas_generate','profile_generate','ward_generate','ward_conversation','ward_greeting','ward_chat','reflection_draft','voice_session','reflection_voice']) LOOP
  INSERT INTO wingward_private.judge_provider_policies(operation,reservation_usd_micros,daily_limit,minimum_interval_ms,max_units,max_seconds,enabled,pricing_evidence,server_bound_enforced)
  VALUES(definition,5000000,12,1000,20000,180,true,'Inactive synthetic historical estimate',true) ON CONFLICT(operation) DO UPDATE SET minimum_interval_ms=1000,daily_limit=12;
  SELECT * INTO r FROM wingward_private.reserve_judge_provider_core(actors[7],definition,gen_random_uuid(),true);
  PERFORM pg_temp.seven_ok(r.outcome='allowed','all operations independent of money '||definition);
  PERFORM pg_temp.seven_ok((SELECT reserved_usd_micros=0 FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id),'zero monetary sentinel '||definition);
 END LOOP;
 PERFORM pg_temp.seven_ok((SELECT reserved_usd_micros=0 FROM wingward_private.judge_seven_provider_budget),'all operations leave inactive ledger untouched');
 -- Only the account quota applies to the new operation; policy count is zero.
 SELECT * INTO r FROM wingward_private.reserve_judge_provider_core(actors[5],'reflection_draft',gen_random_uuid(),true);
 PERFORM pg_temp.seven_ok(r.outcome='allowed','quota probe starts below account and rate bounds');
 UPDATE wingward_private.judge_accounts SET daily_provider_limit=2 WHERE actor_user_id=actors[5];
 PERFORM pg_temp.quota_control(actors[5],'profile_generate','account daily quota',
  '(SELECT count(*) FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.reserved_at>=v_day)>=a.daily_provider_limit');
 UPDATE wingward_private.judge_accounts SET daily_provider_limit=40,per_minute_limit=1 WHERE actor_user_id=actors[5];
 PERFORM pg_temp.quota_control(actors[5],'profile_generate','account minute quota',
  '(SELECT count(*) FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.reserved_at>v_now-interval ''1 minute'')>=a.per_minute_limit');
 UPDATE wingward_private.judge_accounts SET per_minute_limit=24 WHERE actor_user_id=actors[5];
 PERFORM pg_temp.quota_control(actors[5],'reflection_draft','operation minimum interval',
  'EXISTS(SELECT 1 FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.operation=p_operation AND r.reserved_at>v_now-policy.minimum_interval_ms*interval ''1 millisecond'')');
 EXECUTE replace(original_core,'clock_timestamp()',quote_literal(test_clock+interval '2 minutes 1 second')||'::timestamptz');
 SELECT * INTO r FROM wingward_private.reserve_judge_provider_core(actors[5],'reflection_draft',gen_random_uuid(),true);
 PERFORM pg_temp.seven_ok(r.outcome='allowed','minimum interval allows precisely at boundary');
 EXECUTE replace(original_core,'clock_timestamp()',quote_literal(test_clock+interval '2 minutes 3 seconds')||'::timestamptz');
 UPDATE wingward_private.judge_provider_policies SET daily_limit=2 WHERE operation='reflection_draft';
 PERFORM pg_temp.quota_control(actors[5],'reflection_draft','operation daily quota',
  '(SELECT count(*) FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.operation=p_operation AND r.reserved_at>=v_day)>=policy.daily_limit');
 -- Each admission predicate is independently necessary; all changes roll back.
 UPDATE wingward_private.judge_provider_policies SET enabled=false WHERE operation='ward_greeting';
 PERFORM pg_temp.quota_control(actors[4],'ward_greeting','policy enablement','NOT policy.enabled');
 UPDATE wingward_private.judge_provider_policies SET enabled=true WHERE operation='ward_greeting';
 SELECT raw_app_meta_data INTO marker FROM auth.users WHERE id=(SELECT auth_user_id FROM wingward_private.judge_accounts WHERE actor_user_id=actors[4]);
 UPDATE auth.users SET raw_app_meta_data=marker-'wingward_provision_batch' WHERE id=(SELECT auth_user_id FROM wingward_private.judge_accounts WHERE actor_user_id=actors[4]);
 PERFORM pg_temp.quota_control(actors[4],'ward_greeting','core admission','access.outcome<>''allowed''');
 UPDATE auth.users SET raw_app_meta_data=marker WHERE id=(SELECT auth_user_id FROM wingward_private.judge_accounts WHERE actor_user_id=actors[4]);
 INSERT INTO auth.users(id,email,raw_app_meta_data) VALUES(qa_auth,'old-qa@seven.example.invalid',jsonb_build_object('wingward_judge_cohort','shipaton-20261001','wingward_judge_slot','qa','wingward_judge_profile_id',qa));
 UPDATE public.user_profiles SET id=qa WHERE auth_user_id=qa_auth;
 INSERT INTO wingward_private.judge_accounts(slot,actor_user_id,auth_user_id,counterpart_user_id,account_kind,issued_at,expires_at)
 VALUES('qa',qa,qa_auth,bot,'qa','2026-09-30T18:00:00Z','2026-10-01T00:00:00Z');
 SELECT * INTO r FROM public.check_judge_access(qa);PERFORM pg_temp.seven_ok(r.outcome='expired','old QA not revived');
 rejected:=false;BEGIN UPDATE wingward_private.judge_accounts SET access_scope=('shipaton-'||'seven-20261001') WHERE slot='qa';EXCEPTION WHEN check_violation THEN rejected:=true;END;
 PERFORM pg_temp.seven_ok(rejected,'QA cannot join fresh ledger');
 rejected:=false;BEGIN UPDATE wingward_private.judge_accounts SET access_scope=NULL WHERE slot='owner02';EXCEPTION WHEN check_violation THEN rejected:=true;END;
 PERFORM pg_temp.seven_ok(rejected,'fresh owner must retain fresh batch');
 FOREACH role_name IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
  PERFORM pg_temp.seven_ok(NOT has_table_privilege(role_name,'wingward_private.judge_seven_provider_budget','SELECT,INSERT,UPDATE,DELETE'),'fresh ledger private to '||role_name);
  PERFORM pg_temp.seven_ok(NOT has_function_privilege(role_name,'wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean)','execute'),'fresh core private to '||role_name);
 END LOOP;
 PERFORM pg_temp.seven_ok((SELECT relrowsecurity FROM pg_class WHERE oid='wingward_private.judge_seven_provider_budget'::regclass),'fresh ledger RLS');
 -- Freeze only admission at the real deadline, retaining the original predicate.
 EXECUTE replace(original_access,'clock_timestamp()',quote_literal(deadline)||'::timestamptz');
 SELECT * INTO r FROM public.check_judge_access(actors[7]);PERFORM pg_temp.seven_ok(r.outcome='expired','fresh owner expires exactly at deadline');
END $test$;
SELECT count(*) AS seven_assertions_passed FROM seven_assertions;
ROLLBACK;
