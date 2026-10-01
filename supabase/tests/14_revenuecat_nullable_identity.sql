-- RevenueCat valid ignored events may have no app-user identity.
--
-- This acceptance script covers the additive nullable-identity migration. It
-- is intentionally separate from test 12 so the old billing acceptance suite
-- remains a stable regression test. No database reset is performed here.

BEGIN;

INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-0000000000a5', 'wingward-test-a5@example.invalid');

UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-0000000000a5',
       nickname = 'RevenueCat identity test',
       birth_date = '1990-01-01',
       age_verified_at = '2026-08-24T00:00:00Z',
       age_verification_method = 'self_declared'
 WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a5';

SET LOCAL role = 'service_role';

DO $$
DECLARE
  application record;
  event_count integer;
  ledger_count integer;
  entitlement_count integer;
BEGIN
  -- Positive: an otherwise-valid unsupported event is durably recorded even
  -- when RevenueCat did not provide an app-user ID, and causes no side effect.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-ignored-no-identity',
      'TRANSFER_UNKNOWN',
      NULL,
      '2026-09-04T07:00:00Z',
      'ignored',
      NULL,
      NULL,
      NULL,
      NULL,
      0
    );
  IF application.result_status <> 'ignored'
     OR application.resolved_user_id IS NOT NULL
     OR application.entitlement_was_applied IS NOT FALSE
     OR application.credit_was_granted IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL 13a: NULL-identity ignored event was not safely ignored';
  END IF;

  SELECT count(*) INTO event_count
    FROM public.revenuecat_webhook_events
   WHERE event_id = 'rc-ignored-no-identity'
     AND rc_app_user_id IS NULL
     AND user_id IS NULL
     AND processing_status = 'ignored'
     AND entitlement_applied IS FALSE;
  IF event_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 13a: NULL-identity ignored event was not durably recorded';
  END IF;

  SELECT count(*) INTO entitlement_count
    FROM public.entitlements
   WHERE user_id = '10000000-0000-0000-0000-0000000000a5';
  IF entitlement_count <> 0 THEN
    RAISE EXCEPTION 'FAIL 13a: NULL-identity ignored event changed entitlements';
  END IF;

  SELECT count(*) INTO ledger_count
    FROM public.consumable_credit_ledger
   WHERE reference_id = 'rc-ignored-no-identity';
  IF ledger_count <> 0 THEN
    RAISE EXCEPTION 'FAIL 13a: NULL-identity ignored event created credit inventory';
  END IF;

  -- Duplicate: recording the same event again remains idempotent and does
  -- not create another durable row or any side effect.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-ignored-no-identity',
      'TRANSFER_UNKNOWN',
      NULL,
      '2026-09-04T07:00:00Z',
      'ignored'
    );
  IF application.result_status <> 'duplicate'
     OR application.resolved_user_id IS NOT NULL
     OR application.entitlement_was_applied IS NOT FALSE
     OR application.credit_was_granted IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL 13b: duplicate NULL-identity event was not idempotent';
  END IF;

  SELECT count(*) INTO event_count
    FROM public.revenuecat_webhook_events
   WHERE event_id = 'rc-ignored-no-identity';
  IF event_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 13b: duplicate NULL-identity event created another row';
  END IF;

  -- Negative: supported actions cannot omit the app-user ID. The exception
  -- is deliberately safe and leaves no event row behind.
  BEGIN
    PERFORM public.apply_revenuecat_webhook_event(
      'rc-subscription-no-identity',
      'RENEWAL',
      NULL,
      '2026-09-04T07:01:00Z',
      'subscription',
      true,
      'wingward_premium_monthly',
      'APP_STORE',
      '2026-10-04T07:01:00Z',
      0
    );
    RAISE EXCEPTION 'FAIL 13c: subscription without identity was accepted';
  EXCEPTION
    WHEN SQLSTATE '22023' THEN
      NULL;
  END;

  BEGIN
    PERFORM public.apply_revenuecat_webhook_event(
      'rc-consumable-no-identity',
      'NON_RENEWING_PURCHASE',
      NULL,
      '2026-09-04T07:02:00Z',
      'consumable',
      NULL,
      'wingward_meetup_credit',
      'APP_STORE',
      NULL,
      1
    );
    RAISE EXCEPTION 'FAIL 13d: consumable without identity was accepted';
  EXCEPTION
    WHEN SQLSTATE '22023' THEN
      NULL;
  END;

  SELECT count(*) INTO event_count
    FROM public.revenuecat_webhook_events
   WHERE event_id IN ('rc-subscription-no-identity', 'rc-consumable-no-identity');
  IF event_count <> 0 THEN
    RAISE EXCEPTION 'FAIL 13c-d: rejected NULL-identity events were recorded';
  END IF;

  RAISE NOTICE 'PASS 13a-d: NULL identity is durable only for ignored events; supported actions reject it and duplicates are idempotent';
END $$;

-- The additive migration must retain the server-only execution boundary after
-- replacing the function definition.
DO $$
BEGIN
  IF has_function_privilege('anon', 'public.apply_revenuecat_webhook_event(text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 13e: anon can execute the RevenueCat apply RPC';
  END IF;
  IF has_function_privilege('authenticated', 'public.apply_revenuecat_webhook_event(text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 13e: authenticated can execute the RevenueCat apply RPC';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.apply_revenuecat_webhook_event(text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 13e: service_role cannot execute the RevenueCat apply RPC';
  END IF;
  RAISE NOTICE 'PASS 13e: RevenueCat apply RPC remains service_role-only';
END $$;

RESET role;

ROLLBACK;
