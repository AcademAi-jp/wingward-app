-- Synthetic rollback-only boundary checks; no external provider calls.
BEGIN;
DO $test$
BEGIN
 INSERT INTO wingward_private.judge_provider_policies(operation,reservation_usd_micros,daily_limit,minimum_interval_ms,max_units,max_seconds,enabled,pricing_evidence,server_bound_enforced)
 VALUES('ward_generate',1,48,1000,20000,180,true,'Synthetic boundary test',true),
 ('voice_session',1,12,1000,20000,180,true,'Synthetic boundary test',true)
 ON CONFLICT(operation) DO UPDATE SET daily_limit=EXCLUDED.daily_limit;
 BEGIN
  UPDATE wingward_private.judge_provider_policies SET daily_limit=49 WHERE operation='ward_generate';
  RAISE EXCEPTION 'ward limit above 48 accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 BEGIN
  UPDATE wingward_private.judge_provider_policies SET daily_limit=0 WHERE operation='ward_generate';
  RAISE EXCEPTION 'zero ward limit accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 BEGIN
  UPDATE wingward_private.judge_provider_policies SET daily_limit=13 WHERE operation='voice_session';
  RAISE EXCEPTION 'other operation limit expanded';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
END $test$;
ROLLBACK;
