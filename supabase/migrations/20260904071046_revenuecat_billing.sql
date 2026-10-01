-- RevenueCat server mirror and consumable inventory (Phase 2).
--
-- This migration is additive. RevenueCat remains the source of truth for
-- subscription state; the API uses the tables below as a server-side mirror
-- and an auditable consumable-credit inventory. No raw webhook body is stored.
--
-- The three new tables are intentionally service_role-only. The API runs with
-- service_role, while an iOS client must never be able to write webhook state,
-- credit inventory, or invoke the credit RPCs directly through PostgREST.

-- ── RevenueCat webhook idempotency and ordering metadata ───────────────────

CREATE TABLE public.revenuecat_webhook_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id text NOT NULL UNIQUE
    CHECK (char_length(event_id) BETWEEN 1 AND 128),
  event_type text NOT NULL
    CHECK (char_length(event_type) BETWEEN 1 AND 100),
  rc_app_user_id text NOT NULL
    CHECK (char_length(rc_app_user_id) BETWEEN 1 AND 255),
  user_id uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  effective_at timestamptz NOT NULL,
  entitlement_is_active boolean,
  product_id text
    CHECK (product_id IS NULL OR char_length(product_id) <= 255),
  store text
    CHECK (store IS NULL OR char_length(store) <= 64),
  current_period_end timestamptz,
  credit_amount integer NOT NULL DEFAULT 0
    CHECK (credit_amount BETWEEN 0 AND 100),
  processing_status text NOT NULL DEFAULT 'received'
    CHECK (processing_status IN ('received', 'processed', 'ignored', 'failed')),
  entitlement_applied boolean NOT NULL DEFAULT false,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);

CREATE INDEX idx_revenuecat_webhook_events_user_effective
  ON public.revenuecat_webhook_events(user_id, effective_at DESC);
CREATE INDEX idx_revenuecat_webhook_events_rc_app_user
  ON public.revenuecat_webhook_events(rc_app_user_id, effective_at DESC);

-- Ordering metadata lives on the subscription mirror as well. The API must
-- only update an entitlement when the incoming effective_at is greater than
-- or equal to last_webhook_event_at. last_webhook_event_id makes the accepted
-- event auditable without retaining its body.
ALTER TABLE public.entitlements
  ADD COLUMN IF NOT EXISTS last_webhook_event_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_webhook_event_id text
    CHECK (last_webhook_event_id IS NULL OR char_length(last_webhook_event_id) BETWEEN 1 AND 128);

CREATE INDEX IF NOT EXISTS idx_entitlements_rc_app_user_id
  ON public.entitlements(rc_app_user_id);

-- ── Consumable credit ledger and balance ───────────────────────────────────

CREATE TABLE public.consumable_credit_balances (
  user_id uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  balance integer NOT NULL DEFAULT 0 CHECK (balance >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.consumable_credit_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  delta integer NOT NULL CHECK (delta <> 0),
  entry_type text NOT NULL CHECK (entry_type IN ('purchase', 'consume', 'refund', 'adjustment')),
  reference_id text NOT NULL CHECK (char_length(reference_id) BETWEEN 1 AND 128),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, entry_type, reference_id)
);

CREATE INDEX idx_consumable_credit_ledger_user_created
  ON public.consumable_credit_ledger(user_id, created_at DESC);
-- A RevenueCat event ID is globally unique. Keep that invariant for purchase
-- grants too, even if a future caller accidentally resolves one event to a
-- different profile before the webhook event row is checked.
CREATE UNIQUE INDEX idx_consumable_credit_purchase_reference
  ON public.consumable_credit_ledger(reference_id)
  WHERE entry_type = 'purchase';

-- The API maps a validated RevenueCat product to p_amount before calling this
-- function. It is idempotent per purchase reference and locks one balance row
-- before changing it, so concurrent webhook deliveries cannot double-grant.
CREATE OR REPLACE FUNCTION public.grant_consumable_credits(
  p_user_id uuid,
  p_reference_id text,
  p_amount integer
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_balance integer;
BEGIN
  IF p_user_id IS NULL
     OR p_reference_id IS NULL
     OR char_length(btrim(p_reference_id)) = 0
     OR char_length(p_reference_id) > 128
     OR p_amount IS NULL
     OR p_amount < 1
     OR p_amount > 100 THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.consumable_credit_balances (user_id, balance)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT balance
    INTO current_balance
    FROM public.consumable_credit_balances
   WHERE user_id = p_user_id
   FOR UPDATE;

  IF EXISTS (
    SELECT 1
      FROM public.consumable_credit_ledger
     WHERE user_id = p_user_id
       AND entry_type = 'purchase'
       AND reference_id = p_reference_id
  ) THEN
    RETURN current_balance;
  END IF;

  UPDATE public.consumable_credit_balances
     SET balance = balance + p_amount,
         updated_at = now()
   WHERE user_id = p_user_id
   RETURNING balance INTO current_balance;

  INSERT INTO public.consumable_credit_ledger (user_id, delta, entry_type, reference_id)
  VALUES (p_user_id, p_amount, 'purchase', p_reference_id);

  RETURN current_balance;
END;
$$;

COMMENT ON FUNCTION public.grant_consumable_credits(uuid, text, integer) IS
  'Idempotently grants a validated consumable purchase to one user; service_role only.';

-- Consume one credit for an API operation. The reference is an operation
-- idempotency key: retries return true without decrementing twice. A missing
-- or exhausted balance returns false without revealing inventory to clients.
CREATE OR REPLACE FUNCTION public.consume_consumable_credit(
  p_user_id uuid,
  p_reference_id text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_balance integer;
BEGIN
  IF p_user_id IS NULL
     OR p_reference_id IS NULL
     OR char_length(btrim(p_reference_id)) = 0
     OR char_length(p_reference_id) > 128 THEN
    RETURN false;
  END IF;

  INSERT INTO public.consumable_credit_balances (user_id, balance)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT balance
    INTO current_balance
    FROM public.consumable_credit_balances
   WHERE user_id = p_user_id
   FOR UPDATE;

  IF EXISTS (
    SELECT 1
      FROM public.consumable_credit_ledger
     WHERE user_id = p_user_id
       AND entry_type = 'consume'
       AND reference_id = p_reference_id
  ) THEN
    RETURN true;
  END IF;

  IF current_balance <= 0 THEN
    RETURN false;
  END IF;

  UPDATE public.consumable_credit_balances
     SET balance = balance - 1,
         updated_at = now()
   WHERE user_id = p_user_id;

  INSERT INTO public.consumable_credit_ledger (user_id, delta, entry_type, reference_id)
  VALUES (p_user_id, -1, 'consume', p_reference_id);

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.consume_consumable_credit(uuid, text) IS
  'Atomically consumes one server-owned consumable credit; returns false when exhausted.';

-- Refund exactly one prior consume. Repeating a refund is idempotent and does
-- not create additional inventory. This is for compensating a failed server
-- operation, not a user-callable billing action.
CREATE OR REPLACE FUNCTION public.refund_consumable_credit(
  p_user_id uuid,
  p_reference_id text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  current_balance integer;
BEGIN
  IF p_user_id IS NULL
     OR p_reference_id IS NULL
     OR char_length(btrim(p_reference_id)) = 0
     OR char_length(p_reference_id) > 128 THEN
    RETURN false;
  END IF;

  INSERT INTO public.consumable_credit_balances (user_id, balance)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT balance
    INTO current_balance
    FROM public.consumable_credit_balances
   WHERE user_id = p_user_id
   FOR UPDATE;

  IF NOT EXISTS (
    SELECT 1
      FROM public.consumable_credit_ledger
     WHERE user_id = p_user_id
       AND entry_type = 'consume'
       AND reference_id = p_reference_id
  ) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.consumable_credit_ledger
     WHERE user_id = p_user_id
       AND entry_type = 'refund'
       AND reference_id = p_reference_id
  ) THEN
    RETURN true;
  END IF;

  UPDATE public.consumable_credit_balances
     SET balance = balance + 1,
         updated_at = now()
   WHERE user_id = p_user_id
  RETURNING balance INTO current_balance;

  INSERT INTO public.consumable_credit_ledger (user_id, delta, entry_type, reference_id)
  VALUES (p_user_id, 1, 'refund', p_reference_id);

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.refund_consumable_credit(uuid, text) IS
  'Idempotently refunds one prior server-owned consume operation; service_role only.';

-- ── RLS and explicit grants ───────────────────────────────────────────────

ALTER TABLE public.revenuecat_webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.consumable_credit_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.consumable_credit_ledger ENABLE ROW LEVEL SECURITY;

-- The new tables deliberately have no anon/authenticated policies. Explicit
-- revokes matter on hosted Supabase, where role-specific default grants can
-- exist independently of PUBLIC's grant.
REVOKE ALL ON TABLE public.revenuecat_webhook_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.consumable_credit_balances FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.consumable_credit_ledger FROM PUBLIC, anon, authenticated;
-- M8 granted ALL tables to service_role globally. Narrow these three tables
-- back down: webhook processing may insert/update its own metadata, status
-- reads only need SELECT, and credit mutations must go through the atomic
-- SECURITY DEFINER RPCs rather than direct service-role writes.
REVOKE ALL ON TABLE public.revenuecat_webhook_events FROM service_role;
REVOKE ALL ON TABLE public.consumable_credit_balances FROM service_role;
REVOKE ALL ON TABLE public.consumable_credit_ledger FROM service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.revenuecat_webhook_events TO service_role;
GRANT SELECT ON TABLE public.consumable_credit_balances TO service_role;
GRANT SELECT ON TABLE public.consumable_credit_ledger TO service_role;

REVOKE ALL ON FUNCTION public.grant_consumable_credits(uuid, text, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.consume_consumable_credit(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refund_consumable_credit(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grant_consumable_credits(uuid, text, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.consume_consumable_credit(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.refund_consumable_credit(uuid, text) TO service_role;
