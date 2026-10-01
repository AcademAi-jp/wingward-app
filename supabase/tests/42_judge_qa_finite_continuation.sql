-- Synthetic local regression. Operators still choose each explicit finite window.
-- Freeze only the test admission clock inside this rollback transaction.
-- Issuance/deadlines never depend on CI wall time; runtime expiry guards stay intact.
BEGIN;
SET LOCAL statement_timeout='20s';
CREATE TEMP TABLE qa_continuation_assertions(label text PRIMARY KEY);
CREATE FUNCTION pg_temp.qa_ok(value boolean,label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF value IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL %',label;END IF;
 INSERT INTO qa_continuation_assertions VALUES(label);
END $$;
DO $test$
DECLARE
 a constant uuid:='0ed47fef-1266-5fa9-8852-0a2c6b9dc741';
 bot constant uuid:='e7c595cb-ff44-5611-aff1-44fb0ca8bf58';
 au uuid:=gen_random_uuid();bu uuid:=gen_random_uuid();other uuid:=gen_random_uuid();
 test_clock constant timestamptz:='2026-10-01T08:00:00Z';
 issued timestamptz:=test_clock-interval '1 minute';deadline timestamptz:=test_clock+interval '2 hours';
 r record;marker jsonb;rejected boolean;role_name text;original_access_definition text;
 original_access_metadata jsonb;original_registry_constraints jsonb;
BEGIN
 original_access_definition:=pg_get_functiondef('public.check_judge_access(uuid)'::regprocedure);
 SELECT jsonb_build_object('owner',proowner,'acl',proacl,'config',proconfig,'definer',prosecdef)
 INTO original_access_metadata FROM pg_proc WHERE oid='public.check_judge_access(uuid)'::regprocedure;
 SELECT jsonb_agg(jsonb_build_object('name',conname,'definition',pg_get_constraintdef(oid)) ORDER BY conname)
 INTO original_registry_constraints FROM pg_constraint WHERE conrelid='wingward_private.judge_accounts'::regclass;
 PERFORM pg_temp.qa_ok(position('clock_timestamp()>=a.expires_at' IN original_access_definition)>0,
   'real deadline predicate exists before test-only clock substitution');
 EXECUTE replace(original_access_definition,'clock_timestamp()',quote_literal(test_clock)||'::timestamptz');
 marker:=jsonb_build_object('wingward_judge_cohort','shipaton-20261001','wingward_judge_slot','qa','wingward_judge_profile_id',a);
 INSERT INTO auth.users(id,email,raw_app_meta_data,email_confirmed_at)
 VALUES(au,'qa-finite-continuation@example.invalid',marker,now()),(bu,'qa-finite-peer@example.invalid','{}',now());
 UPDATE public.user_profiles SET id=CASE WHEN auth_user_id=au THEN a ELSE bot END WHERE auth_user_id IN(au,bu);
 INSERT INTO wingward_private.judge_accounts(slot,actor_user_id,auth_user_id,counterpart_user_id,account_kind,issued_at,expires_at)
 VALUES('qa',a,au,bot,'qa',issued,deadline);
 SELECT * INTO r FROM public.check_judge_access(a);
 PERFORM pg_temp.qa_ok(r.outcome='allowed' AND r.account_kind='qa' AND r.expires_at=deadline,'QA current plus two-hour window admitted');
 PERFORM pg_temp.qa_ok(deadline>'2026-10-01T00:00:00Z'::timestamptz,'continuation exceeds old nine-AM-only ceiling');
 SELECT * INTO r FROM public.reserve_judge_provider_operation(a,'ward_chat',gen_random_uuid());
 PERFORM pg_temp.qa_ok(r.outcome='denied','missing policy still fails closed after removal of monetary budget');
 -- Legacy QA uses admission and quotas without any monetary initialization.
 EXECUTE replace(pg_get_functiondef('wingward_private.reserve_judge_provider_core(uuid,text,uuid,boolean)'::regprocedure),'clock_timestamp()',quote_literal(test_clock)||'::timestamptz');
 INSERT INTO wingward_private.judge_provider_policies(operation,reservation_usd_micros,daily_limit,minimum_interval_ms,max_units,max_seconds,enabled,pricing_evidence)
 VALUES('ward_chat',5000000,1,1000,20000,180,true,'Inactive synthetic historical estimate');
 SELECT * INTO r FROM public.reserve_judge_provider_operation(a,'ward_chat',gen_random_uuid());
 PERFORM pg_temp.qa_ok(r.outcome='allowed','legacy QA does not require historical monetary initialization');
 PERFORM pg_temp.qa_ok((SELECT reserved_usd_micros=0 FROM wingward_private.judge_provider_reservations WHERE reservation_id=r.reservation_id),'legacy QA uses no monetary calculation');
 SELECT * INTO r FROM public.reserve_judge_provider_operation(a,'ward_chat',gen_random_uuid());
 PERFORM pg_temp.qa_ok(r.outcome='denied','legacy QA operation quota remains enforced');
 UPDATE wingward_private.judge_accounts SET expires_at=test_clock-interval '1 second' WHERE actor_user_id=a;
 SELECT * INTO r FROM public.check_judge_access(a);PERFORM pg_temp.qa_ok(r.outcome='expired','expired QA rejected');
 SELECT * INTO r FROM public.consume_judge_request(a,gen_random_uuid());PERFORM pg_temp.qa_ok(r.outcome='expired','expired QA cannot consume request');
 UPDATE wingward_private.judge_accounts SET expires_at=deadline,disabled_at=test_clock WHERE actor_user_id=a;
 SELECT * INTO r FROM public.check_judge_access(a);PERFORM pg_temp.qa_ok(r.outcome='expired','explicit disable still rejects');
 UPDATE wingward_private.judge_accounts SET disabled_at=NULL WHERE actor_user_id=a;
 rejected:=false;BEGIN UPDATE wingward_private.judge_accounts SET expires_at='2026-10-13T19:00:01Z' WHERE actor_user_id=a;EXCEPTION WHEN check_violation THEN rejected:=true;END;
 PERFORM pg_temp.qa_ok(rejected,'global October-thirteen ceiling rejects overrun');
 rejected:=false;BEGIN UPDATE wingward_private.judge_accounts SET expires_at='infinity' WHERE actor_user_id=a;EXCEPTION WHEN check_violation THEN rejected:=true;END;
 PERFORM pg_temp.qa_ok(rejected,'infinite expiry rejected');
 rejected:=false;BEGIN UPDATE wingward_private.judge_accounts SET issued_at='-infinity' WHERE actor_user_id=a;EXCEPTION WHEN check_violation THEN rejected:=true;END;
 PERFORM pg_temp.qa_ok(rejected,'infinite issue time rejected');
 rejected:=false;BEGIN UPDATE wingward_private.judge_accounts SET expires_at=issued_at WHERE actor_user_id=a;EXCEPTION WHEN check_violation THEN rejected:=true;END;
 PERFORM pg_temp.qa_ok(rejected,'expiry must follow issue time');
 rejected:=false;BEGIN UPDATE wingward_private.judge_accounts SET account_kind='owner' WHERE actor_user_id=a;EXCEPTION WHEN check_violation THEN rejected:=true;END;
 PERFORM pg_temp.qa_ok(rejected,'slot kind ownership binding retained');
 SELECT * INTO r FROM public.check_judge_access(other);PERFORM pg_temp.qa_ok(r.outcome='denied','unregistered actor rejected');
 UPDATE auth.users SET raw_app_meta_data=marker||jsonb_build_object('wingward_judge_slot','owner') WHERE id=au;
 SELECT * INTO r FROM public.check_judge_access(a);PERFORM pg_temp.qa_ok(r.outcome='denied','wrong authoritative slot marker rejected');
 UPDATE auth.users SET raw_app_meta_data=marker||jsonb_build_object('wingward_judge_profile_id',other) WHERE id=au;
 SELECT * INTO r FROM public.check_judge_access(a);PERFORM pg_temp.qa_ok(r.outcome='denied','wrong authoritative profile marker rejected');
 UPDATE auth.users SET raw_app_meta_data=marker||jsonb_build_object('wingward_judge_cohort','wrong-cohort') WHERE id=au;
 SELECT * INTO r FROM public.check_judge_access(a);PERFORM pg_temp.qa_ok(r.outcome='denied','wrong authoritative cohort marker rejected');
 UPDATE auth.users SET raw_app_meta_data=marker WHERE id=au;
 UPDATE wingward_private.judge_accounts SET auth_user_id=bu WHERE actor_user_id=a;
 SELECT * INTO r FROM public.check_judge_access(a);PERFORM pg_temp.qa_ok(r.outcome='denied','profile Auth ownership mismatch rejected');
 UPDATE wingward_private.judge_accounts SET auth_user_id=au WHERE actor_user_id=a;
 PERFORM pg_temp.qa_ok((SELECT relrowsecurity FROM pg_class WHERE oid='wingward_private.judge_accounts'::regclass),'registry RLS retained');
 FOREACH role_name IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
  PERFORM pg_temp.qa_ok(NOT has_table_privilege(role_name,'wingward_private.judge_accounts','SELECT,INSERT,UPDATE,DELETE'),role_name||' cannot read or write private registry');
 END LOOP;
 PERFORM pg_temp.qa_ok(NOT has_function_privilege('anon','public.check_judge_access(uuid)','execute') AND NOT has_function_privilege('authenticated','public.check_judge_access(uuid)','execute') AND has_function_privilege('service_role','public.check_judge_access(uuid)','execute'),'admission RPC remains service-only');
 -- Mutation control: reinstate the old constraint, prove new enrollment fails,
 -- then remove it and prove precisely the same finite enrollment succeeds.
 -- Remove only this rollback fixture receipt before rebuilding its registry row.
 DELETE FROM wingward_private.judge_provider_reservations WHERE actor_user_id=a;
 DELETE FROM wingward_private.judge_accounts WHERE actor_user_id=a;
 ALTER TABLE wingward_private.judge_accounts ADD CONSTRAINT qa_old_deadline_control CHECK(account_kind='judge' OR expires_at<='2026-10-01T00:00:00Z'::timestamptz);
 rejected:=false;BEGIN
  INSERT INTO wingward_private.judge_accounts(slot,actor_user_id,auth_user_id,counterpart_user_id,account_kind,issued_at,expires_at) VALUES('qa',a,au,bot,'qa',issued,deadline);
 EXCEPTION WHEN check_violation THEN rejected:=true;END;
 PERFORM pg_temp.qa_ok(rejected AND NOT EXISTS(SELECT 1 FROM wingward_private.judge_accounts WHERE actor_user_id=a),'negative control old deadline rejects new QA registration');
 ALTER TABLE wingward_private.judge_accounts DROP CONSTRAINT qa_old_deadline_control;
 INSERT INTO wingward_private.judge_accounts(slot,actor_user_id,auth_user_id,counterpart_user_id,account_kind,issued_at,expires_at) VALUES('qa',a,au,bot,'qa',issued,deadline);
 SELECT * INTO r FROM public.check_judge_access(a);PERFORM pg_temp.qa_ok(r.outcome='allowed' AND r.expires_at=deadline,'restored finite constraints admit same QA registration');
 -- Latest explicit QA-only authorization: today at 18:00 JST, never owner.
 UPDATE wingward_private.judge_accounts SET expires_at='2026-10-01T09:00:00Z' WHERE actor_user_id=a;
 SELECT * INTO r FROM public.check_judge_access(a);
 PERFORM pg_temp.qa_ok(r.outcome='allowed' AND r.expires_at='2026-10-01T09:00:00Z'::timestamptz,'explicit QA today eighteen-JST deadline admitted');
 -- Execute the real admission body with only its clock frozen at the deadline.
 -- The production expiry predicate and all authorization branches are unchanged.
 EXECUTE replace(original_access_definition,'clock_timestamp()',quote_literal('2026-10-01T09:00:00Z')||'::timestamptz');
 SELECT * INTO r FROM public.check_judge_access(a);
 PERFORM pg_temp.qa_ok(r.outcome='expired','exact eighteen-JST expiry instant rejects QA');
 EXECUTE replace(original_access_definition,'clock_timestamp()',quote_literal(test_clock)||'::timestamptz');
 SELECT * INTO r FROM public.check_judge_access(a);
 PERFORM pg_temp.qa_ok(r.outcome='allowed' AND r.expires_at='2026-10-01T09:00:00Z'::timestamptz,
   'restored simulated clock admits the same finite registration');
 EXECUTE original_access_definition;
 PERFORM pg_temp.qa_ok(pg_get_functiondef('public.check_judge_access(uuid)'::regprocedure)=original_access_definition,
   'real admission clock and body restored');
 PERFORM pg_temp.qa_ok((SELECT jsonb_build_object('owner',proowner,'acl',proacl,'config',proconfig,'definer',prosecdef)
   FROM pg_proc WHERE oid='public.check_judge_access(uuid)'::regprocedure)=original_access_metadata,
   'real admission owner ACL searchpath and definer metadata restored');
 PERFORM pg_temp.qa_ok((SELECT jsonb_agg(jsonb_build_object('name',conname,'definition',pg_get_constraintdef(oid)) ORDER BY conname)
   FROM pg_constraint WHERE conrelid='wingward_private.judge_accounts'::regclass)=original_registry_constraints,
   'all registry constraints unchanged by synthetic clock test');
END $test$;
SELECT count(*) AS passed_assertions FROM qa_continuation_assertions;
SELECT label FROM qa_continuation_assertions ORDER BY label;
ROLLBACK;
