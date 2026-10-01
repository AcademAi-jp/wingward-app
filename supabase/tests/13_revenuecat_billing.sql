-- RevenueCat billing acceptance checks.
--
-- Covers the database half of Phase 2's billing boundary: RLS/default deny,
-- service_role-only credit RPCs, atomic webhook application, subscription
-- ordering, purchase/consume/refund idempotency, and the durable webhook event
-- key. The script is transactional and leaves no data.

BEGIN;

DO $$
DECLARE
  expected text[] := ARRAY[
    'revenuecat_webhook_events',
    'consumable_credit_balances',
    'consumable_credit_ledger'
  ];
  table_name text;
  is_enabled boolean;
BEGIN
  FOREACH table_name IN ARRAY expected LOOP
    SELECT c.relrowsecurity
      INTO is_enabled
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = table_name;

    IF is_enabled IS NULL THEN
      RAISE EXCEPTION 'FAIL RevenueCat: public.% does not exist', table_name;
    END IF;
    IF is_enabled IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL RevenueCat: RLS is not enabled on public.%', table_name;
    END IF;
  END LOOP;
END $$;

-- The signup trigger creates a profile; use a stable profile id like the
-- existing SQL fixtures do, without inserting directly into user_profiles.
INSERT INTO auth.users (id, email)
VALUES ('00000000-0000-0000-0000-0000000000a4', 'wingward-test-a4@example.invalid');

UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-0000000000a4',
       nickname = 'RevenueCat test fixture',
       birth_date = '1990-01-01',
       age_verified_at = '2026-08-24T00:00:00Z',
       age_verification_method = 'self_declared'
 WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a4';

SET LOCAL role = 'service_role';

DO $$
DECLARE
  application record;
  balance integer;
  ledger_count integer;
  event_count integer;
BEGIN
  -- The RevenueCat app user ID is the stable auth user UUID. The RPC resolves
  -- the profile itself and atomically records and applies the newest event.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-subscription-new',
      'RENEWAL',
      '00000000-0000-0000-0000-0000000000a4',
      '2026-09-04T02:00:00Z',
      'subscription',
      true,
      'wingward.monthly',
      'APP_STORE',
      '2026-10-04T02:00:00Z',
      0
    );
  IF application.result_status <> 'processed'
     OR application.resolved_user_id <> '10000000-0000-0000-0000-0000000000a4'
     OR application.entitlement_was_applied IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: newest subscription event was not applied';
  END IF;

  -- Duplicate subscription delivery is acknowledged without replaying the
  -- entitlement mutation.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-subscription-new',
      'RENEWAL',
      '00000000-0000-0000-0000-0000000000a4',
      '2026-09-04T02:00:00Z',
      'subscription',
      true,
      'wingward.monthly',
      'APP_STORE',
      '2026-10-04T02:00:00Z',
      0
    );
  IF application.result_status <> 'duplicate'
     OR application.entitlement_was_applied IS NOT TRUE
     OR application.credit_was_granted IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: duplicate subscription replayed side effects';
  END IF;

  -- An older cancellation is recorded but cannot roll the newer purchase back.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-subscription-old',
      'CANCELLATION',
      '00000000-0000-0000-0000-0000000000a4',
      '2026-09-04T01:00:00Z',
      'subscription',
      false,
      'wingward.monthly',
      'APP_STORE',
      '2026-09-04T01:00:00Z',
      0
    );
  IF application.result_status <> 'ignored'
     OR application.entitlement_was_applied IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: older subscription event was accepted';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.entitlements
     WHERE user_id = '10000000-0000-0000-0000-0000000000a4'
       AND is_active IS TRUE
       AND last_webhook_event_id = 'rc-subscription-new'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: old event rolled back the newest entitlement';
  END IF;

  -- Equal timestamps use the lexicographically greatest accepted event ID as
  -- a deterministic tie-break, independent of webhook delivery order.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-subscription-tie-a',
      'RENEWAL',
      '00000000-0000-0000-0000-0000000000a4',
      '2026-09-04T06:00:00Z',
      'subscription',
      true,
      'wingward.monthly',
      'APP_STORE',
      '2026-10-04T06:00:00Z',
      0
    );
  IF application.result_status <> 'processed'
     OR application.entitlement_was_applied IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: first equal-time event was not applied';
  END IF;

  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-subscription-tie-z',
      'CANCELLATION',
      '00000000-0000-0000-0000-0000000000a4',
      '2026-09-04T06:00:00Z',
      'subscription',
      false,
      'wingward.monthly',
      'APP_STORE',
      '2026-09-04T06:00:00Z',
      0
    );
  IF application.result_status <> 'processed'
     OR application.entitlement_was_applied IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: greater equal-time event did not win';
  END IF;

  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-subscription-tie-m',
      'RENEWAL',
      '00000000-0000-0000-0000-0000000000a4',
      '2026-09-04T06:00:00Z',
      'subscription',
      true,
      'wingward.monthly',
      'APP_STORE',
      '2026-10-04T06:00:00Z',
      0
    );
  IF application.result_status <> 'ignored'
     OR application.entitlement_was_applied IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: lower equal-time event changed entitlement';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.entitlements
     WHERE user_id = '10000000-0000-0000-0000-0000000000a4'
       AND is_active IS FALSE
       AND last_webhook_event_id = 'rc-subscription-tie-z'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: equal-time tie-break was not deterministic';
  END IF;

  -- An unknown/ignored event is durable but has no entitlement side effect.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-unknown-event',
      'FUTURE_UNKNOWN_TYPE',
      '00000000-0000-0000-0000-0000000000a4',
      '2026-09-04T03:00:00Z',
      'ignored',
      false,
      'malicious.product',
      'UNKNOWN',
      NULL,
      100
    );
  IF application.result_status <> 'ignored'
     OR application.entitlement_was_applied IS NOT FALSE
     OR application.credit_was_granted IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: ignored event caused a side effect';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.entitlements
     WHERE user_id = '10000000-0000-0000-0000-0000000000a4'
       AND is_active IS FALSE
       AND last_webhook_event_id = 'rc-subscription-tie-z'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: ignored event changed entitlement state';
  END IF;

  -- A consumable purchase and the durable event row commit together.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-event-credit-1',
      'NON_RENEWING_PURCHASE',
      '00000000-0000-0000-0000-0000000000a4',
      '2026-09-04T04:00:00Z',
      'consumable',
      NULL,
      NULL,
      'APP_STORE',
      NULL,
      2
    );
  IF application.result_status <> 'processed'
     OR application.credit_was_granted IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: first consumable purchase was not granted';
  END IF;

  -- Duplicate delivery returns success metadata without a second grant.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-event-credit-1',
      'NON_RENEWING_PURCHASE',
      '00000000-0000-0000-0000-0000000000a4',
      '2026-09-04T04:00:00Z',
      'consumable',
      NULL,
      NULL,
      'APP_STORE',
      NULL,
      2
    );
  IF application.result_status <> 'duplicate'
     OR application.credit_was_granted IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: duplicate purchase result was not idempotent';
  END IF;

  SELECT balances.balance INTO balance
    FROM public.consumable_credit_balances AS balances
   WHERE balances.user_id = '10000000-0000-0000-0000-0000000000a4';
  IF balance <> 2 THEN
    RAISE EXCEPTION 'FAIL RevenueCat: duplicate purchase changed balance to %', balance;
  END IF;

  SELECT count(*) INTO ledger_count
    FROM public.consumable_credit_ledger
   WHERE entry_type = 'purchase'
     AND reference_id = 'rc-event-credit-1';
  IF ledger_count <> 1 THEN
    RAISE EXCEPTION 'FAIL RevenueCat: duplicate purchase created % ledger rows', ledger_count;
  END IF;

  SELECT count(*) INTO event_count
    FROM public.revenuecat_webhook_events
   WHERE event_id = 'rc-event-credit-1';
  IF event_count <> 1 THEN
    RAISE EXCEPTION 'FAIL RevenueCat: duplicate event created % event rows', event_count;
  END IF;

  -- An unmapped app user is recorded as ignored and receives no inventory.
  SELECT * INTO application
    FROM public.apply_revenuecat_webhook_event(
      'rc-unmapped-credit',
      'NON_RENEWING_PURCHASE',
      'ffffffff-ffff-ffff-ffff-ffffffffffff',
      '2026-09-04T05:00:00Z',
      'consumable',
      NULL,
      NULL,
      'APP_STORE',
      NULL,
      5
    );
  IF application.result_status <> 'ignored'
     OR application.resolved_user_id IS NOT NULL
     OR application.credit_was_granted IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL RevenueCat: unmapped app user received a grant';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.consumable_credit_ledger
     WHERE reference_id = 'rc-unmapped-credit'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: unmapped app user created a credit ledger entry';
  END IF;

  IF NOT public.consume_consumable_credit(
    '10000000-0000-0000-0000-0000000000a4', 'arrange-operation-1'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: first consume should succeed';
  END IF;

  -- Retrying the same operation is successful but does not consume twice.
  IF NOT public.consume_consumable_credit(
    '10000000-0000-0000-0000-0000000000a4', 'arrange-operation-1'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: duplicate consume should be idempotent';
  END IF;

  IF NOT public.consume_consumable_credit(
    '10000000-0000-0000-0000-0000000000a4', 'arrange-operation-2'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: second consume should succeed';
  END IF;

  IF public.consume_consumable_credit(
    '10000000-0000-0000-0000-0000000000a4', 'arrange-operation-3'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: exhausted consume should fail';
  END IF;

  SELECT balances.balance INTO balance
    FROM public.consumable_credit_balances AS balances
   WHERE balances.user_id = '10000000-0000-0000-0000-0000000000a4';
  IF balance <> 0 THEN
    RAISE EXCEPTION 'FAIL RevenueCat: exhausted balance should be 0, got %', balance;
  END IF;

  IF NOT public.refund_consumable_credit(
    '10000000-0000-0000-0000-0000000000a4', 'arrange-operation-1'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: refund of a consume should succeed';
  END IF;
  IF NOT public.refund_consumable_credit(
    '10000000-0000-0000-0000-0000000000a4', 'arrange-operation-1'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: duplicate refund should be idempotent';
  END IF;

  SELECT balances.balance INTO balance
    FROM public.consumable_credit_balances AS balances
   WHERE balances.user_id = '10000000-0000-0000-0000-0000000000a4';
  IF balance <> 1 THEN
    RAISE EXCEPTION 'FAIL RevenueCat: refunded balance should be 1, got %', balance;
  END IF;

  IF public.refund_consumable_credit(
    '10000000-0000-0000-0000-0000000000a4', 'unknown-operation'
  ) THEN
    RAISE EXCEPTION 'FAIL RevenueCat: unknown refund should fail';
  END IF;
END $$;

-- service_role can no longer split webhook event writes from their effects or
-- bypass server-side identity resolution through the old grant RPC.
DO $$
BEGIN
  INSERT INTO public.revenuecat_webhook_events (
    event_id, event_type, rc_app_user_id, effective_at
  ) VALUES (
    'split-webhook-write', 'INITIAL_PURCHASE',
    '00000000-0000-0000-0000-0000000000a4', now()
  );
  RAISE EXCEPTION 'FAIL RevenueCat: service_role inserted webhook state directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: split webhook write rejected';
END $$;

DO $$
BEGIN
  UPDATE public.revenuecat_webhook_events
     SET processing_status = 'failed'
   WHERE event_id = 'rc-event-credit-1';
  RAISE EXCEPTION 'FAIL RevenueCat: service_role updated webhook state directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: direct webhook update rejected';
END $$;

DO $$
BEGIN
  PERFORM public.grant_consumable_credits(
    '10000000-0000-0000-0000-0000000000a4', 'split-credit-grant', 1
  );
  RAISE EXCEPTION 'FAIL RevenueCat: service_role called direct purchase grant';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: direct purchase grant rejected';
END $$;

DO $$
BEGIN
  INSERT INTO public.entitlements (user_id, is_active)
  VALUES ('10000000-0000-0000-0000-0000000000a4', true)
  ON CONFLICT (user_id) DO NOTHING;
  RAISE EXCEPTION 'FAIL RevenueCat: service_role inserted entitlements directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: direct entitlements INSERT rejected';
END $$;

DO $$
BEGIN
  UPDATE public.entitlements
     SET updated_at = updated_at
   WHERE user_id = '10000000-0000-0000-0000-0000000000a4';
  RAISE EXCEPTION 'FAIL RevenueCat: service_role updated entitlements directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: direct entitlements UPDATE rejected';
END $$;

DO $$
BEGIN
  DELETE FROM public.entitlements
   WHERE user_id = '10000000-0000-0000-0000-0000000000a4';
  RAISE EXCEPTION 'FAIL RevenueCat: service_role deleted entitlements directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: direct entitlements DELETE rejected';
END $$;

-- Client roles cannot read or write the new server-only tables, nor execute
-- the credit functions. The explicit role names matter on hosted Supabase.
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a4"}';

DO $$
BEGIN
  INSERT INTO public.consumable_credit_ledger (user_id, delta, entry_type, reference_id)
  VALUES ('10000000-0000-0000-0000-0000000000a4', 1, 'adjustment', 'client-write');
  RAISE EXCEPTION 'FAIL RevenueCat: authenticated inserted into credit ledger';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: authenticated credit-ledger write rejected';
END $$;

DO $$
BEGIN
  INSERT INTO public.revenuecat_webhook_events (
    event_id, event_type, rc_app_user_id, effective_at
  ) VALUES (
    'client-webhook-write', 'INITIAL_PURCHASE',
    '10000000-0000-0000-0000-0000000000a4', now()
  );
  RAISE EXCEPTION 'FAIL RevenueCat: authenticated inserted webhook state';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: authenticated webhook write rejected';
END $$;

DO $$
BEGIN
  PERFORM public.apply_revenuecat_webhook_event(
    'client-apply-call',
    'RENEWAL',
    '00000000-0000-0000-0000-0000000000a4',
    now(),
    'subscription',
    true,
    'wingward.monthly',
    'APP_STORE',
    now(),
    0
  );
  RAISE EXCEPTION 'FAIL RevenueCat: authenticated executed apply RPC';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: authenticated apply RPC rejected';
END $$;

DO $$
BEGIN
  PERFORM public.consume_consumable_credit(
    '10000000-0000-0000-0000-0000000000a4', 'client-rpc-call'
  );
  RAISE EXCEPTION 'FAIL RevenueCat: authenticated executed consume RPC';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: authenticated consume RPC rejected';
END $$;

DO $$
BEGIN
  PERFORM public.grant_consumable_credits(
    '10000000-0000-0000-0000-0000000000a4', 'client-grant-call', 1
  );
  RAISE EXCEPTION 'FAIL RevenueCat: authenticated executed grant RPC';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: authenticated grant RPC rejected';
END $$;

DO $$
BEGIN
  PERFORM public.refund_consumable_credit(
    '10000000-0000-0000-0000-0000000000a4', 'client-refund-call'
  );
  RAISE EXCEPTION 'FAIL RevenueCat: authenticated executed refund RPC';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: authenticated refund RPC rejected';
END $$;

DO $$
BEGIN
  PERFORM count(*) FROM public.consumable_credit_balances;
  RAISE EXCEPTION 'FAIL RevenueCat: authenticated read credit balances';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: authenticated balance read rejected';
END $$;

DO $$
BEGIN
  PERFORM count(*) FROM public.consumable_credit_ledger;
  RAISE EXCEPTION 'FAIL RevenueCat: authenticated read credit ledger';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: authenticated ledger read rejected';
END $$;

DO $$
BEGIN
  PERFORM count(*) FROM public.revenuecat_webhook_events;
  RAISE EXCEPTION 'FAIL RevenueCat: authenticated read webhook events';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS RevenueCat: authenticated webhook-event read rejected';
END $$;

RESET role;
RESET request.jwt.claims;

ROLLBACK;
