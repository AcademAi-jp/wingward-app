-- Owner requested removal of ALL judging monetary caps and estimates.
-- Preserve old accounting rows as inactive history. New receipts track identity,
-- replay, counts and unit/time limits only; zero is an unused monetary sentinel.
-- Admission, expiry, policy enablement, bounded voice and quotas remain enforced.
ALTER TABLE wingward_private.judge_provider_reservations
 DROP CONSTRAINT judge_provider_reservations_reserved_usd_micros_check,
 ADD CONSTRAINT judge_provider_reservations_reserved_usd_micros_check CHECK(reserved_usd_micros BETWEEN 0 AND 5000000);
COMMENT ON COLUMN wingward_private.judge_provider_reservations.reserved_usd_micros IS 'Inactive historical estimate. New judging receipts use zero; no runtime monetary accounting.';
COMMENT ON TABLE wingward_private.judge_provider_budget IS 'Inactive historical ledger; no runtime monetary admission or accounting.';
COMMENT ON TABLE wingward_private.judge_seven_provider_budget IS 'Inactive historical ledger; no runtime monetary admission or accounting.';

CREATE OR REPLACE FUNCTION wingward_private.reserve_judge_seven_provider_core(p_user_id uuid,p_operation text,p_idempotency_key uuid,p_bound_voice boolean)
RETURNS TABLE(outcome text,reservation_id uuid,max_units integer,max_seconds integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $reserve$
DECLARE a wingward_private.judge_accounts;access record;policy wingward_private.judge_provider_policies;previous wingward_private.judge_provider_reservations;v_now timestamptz;v_day timestamptz;rid uuid;
BEGIN
 IF p_user_id IS NULL OR p_operation IS NULL OR p_idempotency_key IS NULL THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO a FROM wingward_private.judge_accounts j WHERE j.actor_user_id=p_user_id FOR UPDATE;
 IF NOT FOUND OR a.access_scope IS DISTINCT FROM 'shipaton-seven-20261001' THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO access FROM public.check_judge_access(p_user_id);
 IF access.outcome<>'allowed' THEN RETURN QUERY SELECT access.outcome,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
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
  OR EXISTS(SELECT 1 FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.operation=p_operation AND r.reserved_at>v_now-policy.minimum_interval_ms*interval '1 millisecond') THEN
  RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;
 END IF;
 INSERT INTO wingward_private.judge_provider_reservations(budget_scope,actor_user_id,operation,idempotency_key,reserved_at,reserved_usd_micros,max_units,max_seconds)
 VALUES('shipaton-seven-20261001',p_user_id,p_operation,p_idempotency_key,v_now,0,policy.max_units,policy.max_seconds) RETURNING judge_provider_reservations.reservation_id INTO rid;
 RETURN QUERY SELECT 'allowed'::text,rid,policy.max_units,policy.max_seconds;
END $reserve$;
REVOKE ALL ON FUNCTION wingward_private.reserve_judge_seven_provider_core(uuid,text,uuid,boolean) FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION wingward_private.reserve_judge_provider_core(p_user_id uuid,p_operation text,p_idempotency_key uuid,p_bound_voice boolean)
RETURNS TABLE(outcome text,reservation_id uuid,max_units integer,max_seconds integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $reserve$
DECLARE a wingward_private.judge_accounts;access record;policy wingward_private.judge_provider_policies;previous wingward_private.judge_provider_reservations;v_now timestamptz;v_day timestamptz;rid uuid;
BEGIN
 IF p_user_id IS NULL OR p_operation IS NULL OR p_idempotency_key IS NULL THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 SELECT * INTO a FROM wingward_private.judge_accounts j WHERE j.actor_user_id=p_user_id FOR UPDATE;
 IF NOT FOUND THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
 IF a.access_scope=('shipaton-'||'seven-20261001') THEN
  RETURN QUERY SELECT * FROM wingward_private.reserve_judge_seven_provider_core(p_user_id,p_operation,p_idempotency_key,p_bound_voice);RETURN;
 END IF;
 SELECT * INTO access FROM public.check_judge_access(p_user_id);
 IF access.outcome<>'allowed' THEN RETURN QUERY SELECT access.outcome,NULL::uuid,NULL::integer,NULL::integer;RETURN;END IF;
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
  OR EXISTS(SELECT 1 FROM wingward_private.judge_provider_reservations r WHERE r.actor_user_id=p_user_id AND r.operation=p_operation AND r.reserved_at>v_now-policy.minimum_interval_ms*interval '1 millisecond') THEN
  RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer;RETURN;
 END IF;
 INSERT INTO wingward_private.judge_provider_reservations(actor_user_id,operation,idempotency_key,reserved_at,reserved_usd_micros,max_units,max_seconds)
 VALUES(p_user_id,p_operation,p_idempotency_key,v_now,0,policy.max_units,policy.max_seconds) RETURNING judge_provider_reservations.reservation_id INTO rid;
 RETURN QUERY SELECT 'allowed'::text,rid,policy.max_units,policy.max_seconds;
END $reserve$;
REVOKE ALL ON FUNCTION wingward_private.reserve_judge_provider_core(uuid,text,uuid,boolean) FROM PUBLIC,anon,authenticated,service_role;
