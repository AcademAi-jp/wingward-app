-- RevenueCat can deliver valid events whose app user ID is absent. Keep the
-- event for audit/idempotency, but only let the explicitly ignored action use
-- a NULL identity; supported actions must resolve an identity before effects.
-- This is additive: the applied billing migrations remain immutable.

ALTER TABLE public.revenuecat_webhook_events
  ALTER COLUMN rc_app_user_id DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.apply_revenuecat_webhook_event(
  p_event_id text,
  p_event_type text,
  p_rc_app_user_id text,
  p_effective_at timestamptz,
  p_action text,
  p_entitlement_is_active boolean DEFAULT NULL,
  p_product_id text DEFAULT NULL,
  p_store text DEFAULT NULL,
  p_current_period_end timestamptz DEFAULT NULL,
  p_credit_amount integer DEFAULT 0
) RETURNS TABLE (
  result_status text,
  resolved_user_id uuid,
  entitlement_was_applied boolean,
  credit_was_granted boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  inserted_event_id text;
  granted_balance integer;
BEGIN
  IF p_event_id IS NULL
     OR char_length(btrim(p_event_id)) = 0
     OR char_length(p_event_id) > 128
     OR p_event_type IS NULL
     OR char_length(btrim(p_event_type)) = 0
     OR char_length(p_event_type) > 100
     -- Only an explicitly ignored event may omit the vendor identity. A
     -- supplied identity is still validated for every action.
     OR (p_rc_app_user_id IS NULL AND p_action <> 'ignored')
     OR (p_rc_app_user_id IS NOT NULL AND (
          char_length(btrim(p_rc_app_user_id)) = 0
          OR char_length(p_rc_app_user_id) > 255
        ))
     OR p_effective_at IS NULL
     OR p_action IS NULL
     OR p_action NOT IN ('subscription', 'consumable', 'ignored')
     OR (p_action = 'subscription' AND p_entitlement_is_active IS NULL)
     OR (p_action = 'consumable' AND (p_credit_amount IS NULL OR p_credit_amount < 1 OR p_credit_amount > 100))
     OR (p_product_id IS NOT NULL AND char_length(p_product_id) > 255)
     OR (p_store IS NOT NULL AND char_length(p_store) > 64) THEN
    RAISE EXCEPTION 'invalid normalized RevenueCat event' USING ERRCODE = '22023';
  END IF;

  SELECT profile.id
    INTO resolved_user_id
    FROM public.user_profiles AS profile
   WHERE profile.auth_user_id::text = p_rc_app_user_id;

  INSERT INTO public.revenuecat_webhook_events (
    event_id,
    event_type,
    rc_app_user_id,
    user_id,
    effective_at,
    entitlement_is_active,
    product_id,
    store,
    current_period_end,
    credit_amount
  ) VALUES (
    p_event_id,
    p_event_type,
    p_rc_app_user_id,
    resolved_user_id,
    p_effective_at,
    CASE WHEN p_action = 'subscription' THEN p_entitlement_is_active ELSE NULL END,
    CASE WHEN p_action = 'subscription' THEN p_product_id ELSE NULL END,
    CASE WHEN p_action = 'subscription' THEN p_store ELSE NULL END,
    CASE WHEN p_action = 'subscription' THEN p_current_period_end ELSE NULL END,
    CASE WHEN p_action = 'consumable' THEN p_credit_amount ELSE 0 END
  )
  ON CONFLICT (event_id) DO NOTHING
  RETURNING event_id INTO inserted_event_id;

  IF inserted_event_id IS NULL THEN
    SELECT
      'duplicate',
      existing.user_id,
      existing.entitlement_applied,
      EXISTS (
        SELECT 1
          FROM public.consumable_credit_ledger AS ledger
         WHERE ledger.entry_type = 'purchase'
           AND ledger.reference_id = existing.event_id
      )
      INTO result_status, resolved_user_id, entitlement_was_applied, credit_was_granted
      FROM public.revenuecat_webhook_events AS existing
      WHERE existing.event_id = p_event_id;

    RETURN NEXT;
    RETURN;
  END IF;

  entitlement_was_applied := false;
  credit_was_granted := false;

  -- A NULL identity is valid only for ignored events and therefore cannot
  -- reach either subscription or consumable side effects.
  IF resolved_user_id IS NULL OR p_action = 'ignored' THEN
    result_status := 'ignored';
  ELSIF p_action = 'subscription' THEN
    INSERT INTO public.entitlements (
      user_id,
      is_active,
      product_id,
      store,
      current_period_end,
      rc_app_user_id,
      updated_at,
      last_webhook_event_at,
      last_webhook_event_id
    ) VALUES (
      resolved_user_id,
      p_entitlement_is_active,
      p_product_id,
      p_store,
      p_current_period_end,
      p_rc_app_user_id,
      now(),
      p_effective_at,
      p_event_id
    )
    ON CONFLICT (user_id) DO UPDATE
      SET is_active = EXCLUDED.is_active,
          product_id = EXCLUDED.product_id,
          store = EXCLUDED.store,
          current_period_end = EXCLUDED.current_period_end,
          rc_app_user_id = EXCLUDED.rc_app_user_id,
          updated_at = now(),
          last_webhook_event_at = EXCLUDED.last_webhook_event_at,
          last_webhook_event_id = EXCLUDED.last_webhook_event_id
      WHERE public.entitlements.last_webhook_event_at IS NULL
         OR EXCLUDED.last_webhook_event_at > public.entitlements.last_webhook_event_at
         OR (
           EXCLUDED.last_webhook_event_at = public.entitlements.last_webhook_event_at
           AND (
             public.entitlements.last_webhook_event_id IS NULL
             OR EXCLUDED.last_webhook_event_id COLLATE "C"
                > public.entitlements.last_webhook_event_id COLLATE "C"
           )
         )
    RETURNING true INTO entitlement_was_applied;

    entitlement_was_applied := COALESCE(entitlement_was_applied, false);
    result_status := CASE WHEN entitlement_was_applied THEN 'processed' ELSE 'ignored' END;
  ELSE
    granted_balance := public.grant_consumable_credits(
      resolved_user_id,
      p_event_id,
      p_credit_amount
    );
    credit_was_granted := granted_balance IS NOT NULL;
    result_status := CASE WHEN credit_was_granted THEN 'processed' ELSE 'ignored' END;
  END IF;

  UPDATE public.revenuecat_webhook_events
     SET processing_status = result_status,
         entitlement_applied = entitlement_was_applied,
         processed_at = now()
   WHERE event_id = p_event_id;

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.apply_revenuecat_webhook_event(
  text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer
) IS
  'Atomically records and applies one normalized RevenueCat event; service_role only. NULL identity is accepted only for ignored events.';

-- CREATE OR REPLACE preserves existing ACLs; repeat the service-only boundary
-- here so the additive migration remains safe if grants differ in a fresh DB.
REVOKE INSERT, UPDATE ON TABLE public.revenuecat_webhook_events FROM service_role;
REVOKE ALL ON FUNCTION public.grant_consumable_credits(uuid, text, integer) FROM service_role;
REVOKE ALL ON TABLE public.entitlements FROM service_role;
GRANT SELECT ON TABLE public.entitlements TO service_role;
REVOKE ALL ON FUNCTION public.apply_revenuecat_webhook_event(
  text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_revenuecat_webhook_event(
  text, text, text, timestamptz, text, boolean, text, text, timestamptz, integer
) TO service_role;
