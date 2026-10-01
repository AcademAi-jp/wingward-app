-- Seven fresh identities get a separate $10 ledger. Old ledger and QA rows stay intact.
-- Empty admission and unknown spend remain closed until the bounded rollout enrolls the batch.
ALTER TABLE wingward_private.judge_accounts ADD COLUMN access_scope text;
DO $slots$
DECLARE constraint_name text; matches integer;
BEGIN
 SELECT count(*),min(conname::text) INTO matches,constraint_name FROM pg_catalog.pg_constraint
 WHERE conrelid='wingward_private.judge_accounts'::regclass AND contype='c'
 AND pg_catalog.pg_get_constraintdef(oid) LIKE '%slot%' AND pg_catalog.pg_get_constraintdef(oid) LIKE '%actor_user_id%';
 IF matches<>1 THEN RAISE EXCEPTION 'Unexpected judge slot constraint';END IF;
 EXECUTE pg_catalog.format('ALTER TABLE wingward_private.judge_accounts DROP CONSTRAINT %I',constraint_name);
END $slots$;
ALTER TABLE wingward_private.judge_accounts ADD CONSTRAINT judge_accounts_fixed_slots CHECK((slot='judge01' AND actor_user_id='970f08d1-c1b8-572b-ad42-00277c8facbb'::uuid AND account_kind='judge') OR (slot='judge02' AND actor_user_id='69ef089a-ff8e-5344-8335-8b931364b064'::uuid AND account_kind='judge') OR (slot='judge03' AND actor_user_id='bc7b2853-234f-5191-a720-b88893217597'::uuid AND account_kind='judge') OR (slot='judge04' AND actor_user_id='a8a78dc4-02c2-54a2-b205-486bd44d3387'::uuid AND account_kind='judge') OR (slot='judge05' AND actor_user_id='b0caf6bb-4481-5ac0-ba8f-cbab9baef418'::uuid AND account_kind='judge') OR (slot='owner' AND actor_user_id='6d527260-24a9-57f6-8051-1c79eea0028f'::uuid AND account_kind='owner') OR (slot='qa' AND actor_user_id='0ed47fef-1266-5fa9-8852-0a2c6b9dc741'::uuid AND account_kind='qa') OR (slot='owner01' AND actor_user_id='56f96c3d-6040-5c57-b6ad-c59284ba4f3c'::uuid AND account_kind='owner') OR (slot='owner02' AND actor_user_id='907cd918-c426-529b-8d36-39aaae2ae1a6'::uuid AND account_kind='owner'));
ALTER TABLE wingward_private.judge_accounts ADD CONSTRAINT judge_accounts_access_scope CHECK(
 (access_scope IS NULL AND slot NOT IN('owner01','owner02')) OR
 (access_scope IS NOT NULL AND access_scope=('shipaton-'||'seven-20261001') AND slot IN('judge01','judge02','judge03','judge04','judge05','owner01','owner02')));
CREATE TABLE wingward_private.judge_seven_provider_budget (
 scope text PRIMARY KEY CHECK(scope='shipaton-seven-20261001'),
 limit_usd_micros integer NOT NULL DEFAULT 10000000 CHECK(limit_usd_micros=10000000),
 prior_spend_usd_micros integer CHECK(prior_spend_usd_micros BETWEEN 0 AND 10000000),
 reserved_usd_micros integer NOT NULL DEFAULT 0 CHECK(reserved_usd_micros>=0),
 prior_spend_evidence text,
 CHECK((prior_spend_usd_micros IS NULL AND reserved_usd_micros=0 AND prior_spend_evidence IS NULL)
 OR (prior_spend_usd_micros IS NOT NULL AND prior_spend_evidence IS NOT NULL
 AND char_length(prior_spend_evidence) BETWEEN 1 AND 200
 AND prior_spend_usd_micros+reserved_usd_micros<=limit_usd_micros))
);
INSERT INTO wingward_private.judge_seven_provider_budget(scope) VALUES('shipaton-seven-20261001');
ALTER TABLE wingward_private.judge_seven_provider_budget ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE wingward_private.judge_seven_provider_budget FROM PUBLIC,anon,authenticated,service_role;
ALTER TABLE wingward_private.judge_provider_reservations ADD COLUMN budget_scope text REFERENCES wingward_private.judge_seven_provider_budget(scope);

-- Empty, owner-authorized judge admission. No existing account/history/permit rows change.
-- Prior paid spend is unknown until the operator establishes a conservative bound.
CREATE OR REPLACE FUNCTION wingward_private.synthetic_matching_member(p_id uuid)
RETURNS boolean LANGUAGE sql IMMUTABLE SECURITY INVOKER SET search_path = ''
AS $$ SELECT coalesce(p_id IN (
 '96b31c0a-b8c4-4536-ada2-f3537dadd146'::uuid,
 '9d836fee-7b93-41ce-b577-34a63006aaea'::uuid,
 'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'::uuid,
 'a88a89e2-5421-5ce9-a33b-76d512898c37'::uuid,
 'e7c595cb-ff44-5611-aff1-44fb0ca8bf58'::uuid,
 'c0195ccd-de1e-5102-ad9c-d5bf4493f493'::uuid,
 '8f46024f-57f6-5156-ab67-579750c25d4f'::uuid,
 '2695146e-fa8a-5ed1-a437-3d97fa1aea73'::uuid,
 '0a6abcf2-03e9-5314-afff-5d31bde7d375'::uuid,
 '67b0d667-d24a-51fd-a328-f51ba95e7f34'::uuid,
 '4e7b3007-217d-59c4-a248-9342bcac383f'::uuid,
 '97e36e35-9a3b-5564-af94-9dd3299054bf'::uuid,
 '5236813d-8309-5f07-addc-363650df398a'::uuid,
 '70d6de4c-fcbd-5087-ab9f-b34cdeae39a1'::uuid,
 '84cbc386-bf1d-5b5f-a58b-bebc74f295cc'::uuid,
 'a2807edf-1b46-5991-a205-2773574ea881'::uuid,
 'fbc07cb0-43fb-5a58-a6a6-e42bd9c89fa6'::uuid,
 '7a1d4255-6f79-55e6-a3d5-00649f85c0c2'::uuid,
 'fb57a1b1-803a-5018-a200-5287789cf68f'::uuid,
 '0e7b28b3-41cf-51ab-af21-7bc5c00c5360'::uuid,
 'e83da28b-ea0b-594d-a8e2-94cbdc2bc016'::uuid,
 'd0d9d2b8-ad16-5bc7-afbb-a08ee5ceffe6'::uuid,
 '66633798-57b9-5dbd-a092-10e669ef142d'::uuid,
 '970f08d1-c1b8-572b-ad42-00277c8facbb'::uuid,
 '69ef089a-ff8e-5344-8335-8b931364b064'::uuid,
 'bc7b2853-234f-5191-a720-b88893217597'::uuid,
 'a8a78dc4-02c2-54a2-b205-486bd44d3387'::uuid,
 'b0caf6bb-4481-5ac0-ba8f-cbab9baef418'::uuid,
 '6d527260-24a9-57f6-8051-1c79eea0028f'::uuid,
 '0ed47fef-1266-5fa9-8852-0a2c6b9dc741'::uuid,
 '56f96c3d-6040-5c57-b6ad-c59284ba4f3c'::uuid,
 '907cd918-c426-529b-8d36-39aaae2ae1a6'::uuid
), false) $$;
REVOKE ALL ON FUNCTION wingward_private.synthetic_matching_member(uuid)
FROM PUBLIC, anon, authenticated, service_role;



CREATE OR REPLACE FUNCTION public.check_judge_access(p_user_id uuid)
RETURNS TABLE(outcome text,actor_user_id uuid,account_kind text,counterpart_user_id uuid,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $check$
DECLARE a wingward_private.judge_accounts;
BEGIN
 SELECT * INTO a FROM wingward_private.judge_accounts j WHERE j.actor_user_id=p_user_id;
 IF NOT FOUND THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::text,NULL::uuid,NULL::timestamptz;RETURN;END IF;
 IF a.disabled_at IS NOT NULL OR clock_timestamp()<a.issued_at OR clock_timestamp()>=a.expires_at THEN
  RETURN QUERY SELECT 'expired'::text,NULL::uuid,NULL::text,NULL::uuid,NULL::timestamptz;RETURN;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.user_profiles p JOIN auth.users u ON u.id=p.auth_user_id WHERE p.id=a.actor_user_id AND p.auth_user_id=a.auth_user_id
   AND u.raw_app_meta_data->>'wingward_judge_cohort'='shipaton-20261001'
   AND u.raw_app_meta_data->>'wingward_judge_slot'=a.slot
   AND u.raw_app_meta_data->>'wingward_judge_profile_id'=a.actor_user_id::text
   AND ((a.access_scope IS NULL AND u.raw_app_meta_data->>'wingward_provision_batch' IS DISTINCT FROM 'shipaton-seven-20261001')
     OR (a.access_scope IS NOT NULL AND u.raw_app_meta_data->>'wingward_provision_batch'=a.access_scope AND u.raw_app_meta_data->>'wingward_provision_slot'=a.slot))
   AND COALESCE((to_jsonb(u)->>'is_anonymous')::boolean,false)=false
   AND (to_jsonb(u)->>'banned_until' IS NULL OR (to_jsonb(u)->>'banned_until')::timestamptz<=clock_timestamp()))
  OR NOT wingward_private.synthetic_matching_member(a.counterpart_user_id)
  OR EXISTS(SELECT 1 FROM wingward_private.judge_accounts j WHERE j.actor_user_id=a.counterpart_user_id) THEN
  RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::text,NULL::uuid,NULL::timestamptz;RETURN;
 END IF;
 RETURN QUERY SELECT 'allowed'::text,a.actor_user_id,a.account_kind,a.counterpart_user_id,a.expires_at;
END $check$;
REVOKE ALL ON FUNCTION public.check_judge_access(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.check_judge_access(uuid) TO service_role;


CREATE FUNCTION wingward_private.reserve_judge_seven_provider_core(p_user_id uuid,p_operation text,p_idempotency_key uuid,p_bound_voice boolean)
RETURNS TABLE(outcome text,reservation_id uuid,max_units integer,max_seconds integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $reserve$
DECLARE a wingward_private.judge_accounts;access record;b wingward_private.judge_seven_provider_budget;policy wingward_private.judge_provider_policies;previous wingward_private.judge_provider_reservations;v_now timestamptz;v_day timestamptz;rid uuid;
BEGIN
 IF p_user_id IS NULL OR p_operation IS NULL OR p_idempotency_key IS NULL THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO a FROM wingward_private.judge_accounts j WHERE j.actor_user_id=p_user_id FOR UPDATE;
 IF NOT FOUND OR a.access_scope IS DISTINCT FROM 'shipaton-seven-20261001' THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO access FROM public.check_judge_access(p_user_id);
 IF access.outcome<>'allowed' THEN RETURN QUERY SELECT access.outcome,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO b FROM wingward_private.judge_seven_provider_budget WHERE scope='shipaton-seven-20261001' FOR UPDATE;
 IF NOT FOUND OR b.prior_spend_usd_micros IS NULL THEN RETURN QUERY SELECT 'unknown'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO policy FROM wingward_private.judge_provider_policies WHERE operation=p_operation;
 IF NOT FOUND OR NOT policy.enabled OR (policy.operation IN('voice_session','reflection_voice') AND (NOT policy.server_bound_enforced OR NOT p_bound_voice)) THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 -- Check the real deadline after any lock wait. A replay cannot reopen expiry.
 v_now:=clock_timestamp();
 IF v_now<a.issued_at OR v_now>=a.expires_at OR a.disabled_at IS NOT NULL THEN RETURN QUERY SELECT 'expired'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO previous FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF previous.operation<>p_operation THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;
  ELSE RETURN QUERY SELECT 'replayed'::text,previous.reservation_id,previous.max_units,previous.max_seconds;END IF;
  RETURN;
 END IF;
 v_day:=pg_catalog.date_trunc('day',v_now AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
 IF (SELECT count(*) FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.reserved_at>=v_day)>=a.daily_provider_limit
  OR (SELECT count(*) FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.operation=p_operation AND r.reserved_at>=v_day)>=policy.daily_limit
  OR (SELECT count(*) FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.reserved_at>v_now-interval '1 minute')>=a.per_minute_limit
  OR EXISTS(SELECT 1 FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.operation=p_operation AND r.reserved_at>v_now-policy.minimum_interval_ms*interval '1 millisecond')
  OR b.prior_spend_usd_micros+b.reserved_usd_micros+policy.reservation_usd_micros>b.limit_usd_micros THEN
  RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;
 END IF;
 INSERT INTO wingward_private.judge_provider_reservations(budget_scope,actor_user_id,operation,idempotency_key,reserved_at,reserved_usd_micros,max_units,max_seconds)
 VALUES('shipaton-seven-20261001',p_user_id,p_operation,p_idempotency_key,v_now,policy.reservation_usd_micros,policy.max_units,policy.max_seconds) RETURNING judge_provider_reservations.reservation_id INTO rid;
 UPDATE wingward_private.judge_seven_provider_budget SET reserved_usd_micros=reserved_usd_micros+policy.reservation_usd_micros WHERE scope='shipaton-seven-20261001';
 RETURN QUERY SELECT 'allowed'::text,rid,policy.max_units,policy.max_seconds;
END $reserve$;
REVOKE ALL ON FUNCTION wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean) FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION wingward_private.reserve_judge_provider_core(p_user_id uuid,p_operation text,p_idempotency_key uuid,p_bound_voice boolean)
RETURNS TABLE(outcome text,reservation_id uuid,max_units integer,max_seconds integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $reserve$
DECLARE a wingward_private.judge_accounts;access record;b wingward_private.judge_provider_budget;policy wingward_private.judge_provider_policies;previous wingward_private.judge_provider_reservations;v_now timestamptz;v_day timestamptz;rid uuid;
BEGIN
 IF p_user_id IS NULL OR p_operation IS NULL OR p_idempotency_key IS NULL THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO a FROM wingward_private.judge_accounts j WHERE j.actor_user_id=p_user_id FOR UPDATE;
 IF NOT FOUND THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 IF a.access_scope=('shipaton-'||'seven-20261001') THEN
  RETURN QUERY SELECT * FROM wingward_private.reserve_judge_seven_provider_core(p_user_id,p_operation,p_idempotency_key,p_bound_voice);RETURN;
 END IF;
 SELECT * INTO access FROM public.check_judge_access(p_user_id);
 IF access.outcome<>'allowed' THEN RETURN QUERY SELECT access.outcome,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO b FROM wingward_private.judge_provider_budget WHERE singleton FOR UPDATE;
 IF NOT FOUND OR b.prior_spend_usd_micros IS NULL THEN RETURN QUERY SELECT 'unknown'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO policy FROM wingward_private.judge_provider_policies WHERE operation=p_operation;
 IF NOT FOUND OR NOT policy.enabled OR (policy.operation IN('voice_session','reflection_voice') AND (NOT policy.server_bound_enforced OR NOT p_bound_voice)) THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 -- Check the real deadline after any lock wait. A replay cannot reopen expiry.
 v_now:=clock_timestamp();
 IF v_now<a.issued_at OR v_now>=a.expires_at OR a.disabled_at IS NOT NULL THEN RETURN QUERY SELECT 'expired'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO previous FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF previous.operation<>p_operation THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;
  ELSE RETURN QUERY SELECT 'replayed'::text,previous.reservation_id,previous.max_units,previous.max_seconds;END IF;
  RETURN;
 END IF;
 v_day:=pg_catalog.date_trunc('day',v_now AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
 IF (SELECT count(*) FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.reserved_at>=v_day)>=a.daily_provider_limit
  OR (SELECT count(*) FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.operation=p_operation AND r.reserved_at>=v_day)>=policy.daily_limit
  OR (SELECT count(*) FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.reserved_at>v_now-interval '1 minute')>=a.per_minute_limit
  OR EXISTS(SELECT 1 FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.operation=p_operation AND r.reserved_at>v_now-policy.minimum_interval_ms*interval '1 millisecond')
  OR b.prior_spend_usd_micros+b.reserved_usd_micros+policy.reservation_usd_micros>b.limit_usd_micros THEN
  RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;
 END IF;
 INSERT INTO wingward_private.judge_provider_reservations(actor_user_id,operation,idempotency_key,reserved_at,reserved_usd_micros,max_units,max_seconds)
 VALUES(p_user_id,p_operation,p_idempotency_key,v_now,policy.reservation_usd_micros,policy.max_units,policy.max_seconds) RETURNING judge_provider_reservations.reservation_id INTO rid;
 UPDATE wingward_private.judge_provider_budget SET reserved_usd_micros=reserved_usd_micros+policy.reservation_usd_micros WHERE singleton;
 RETURN QUERY SELECT 'allowed'::text,rid,policy.max_units,policy.max_seconds;
END $reserve$;
REVOKE ALL ON FUNCTION wingward_private.reserve_judge_provider_core(uuid,text,uuid,boolean) FROM PUBLIC,anon,authenticated,service_role;
