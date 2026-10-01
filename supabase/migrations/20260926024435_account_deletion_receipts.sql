-- Recover account deletion after Auth succeeds but the response or client
-- session is lost. Receipts are 256-bit bearer secrets; only their SHA-256
-- digest is stored here. This table intentionally has no profile/Auth FK so
-- the proof survives the account cascade.

CREATE SCHEMA IF NOT EXISTS wingward_private;
REVOKE ALL ON SCHEMA wingward_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA wingward_private TO service_role;

CREATE TABLE wingward_private.account_deletion_operations (
  operation_id uuid PRIMARY KEY,
  owner_profile_id uuid NOT NULL,
  auth_user_id uuid NOT NULL,
  receipt_hash text NOT NULL CHECK (receipt_hash ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'deleting', 'deleted')),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  expires_at timestamptz NOT NULL,
  delete_lease_until timestamptz,
  delete_claim_token uuid,
  delete_window_started_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  delete_attempt_count integer NOT NULL DEFAULT 0 CHECK (delete_attempt_count >= 0),
  status_window_started_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  status_request_count integer NOT NULL DEFAULT 0 CHECK (status_request_count >= 0),
  deleted_at timestamptz,
  CONSTRAINT account_deletion_expiry_bound_check
    CHECK (expires_at > created_at AND expires_at <= created_at + interval '7 days'),
  CONSTRAINT account_deletion_deleted_timestamp_check
    CHECK ((status = 'deleted') = (deleted_at IS NOT NULL)),
  CONSTRAINT account_deletion_claim_state_check
    CHECK ((delete_lease_until IS NULL) = (delete_claim_token IS NULL))
);

CREATE INDEX account_deletion_operations_owner_expiry_idx
  ON wingward_private.account_deletion_operations (owner_profile_id, expires_at DESC);
CREATE INDEX account_deletion_operations_expiry_idx
  ON wingward_private.account_deletion_operations (expires_at);

-- This FK-less limiter survives the account cascade and caps successful new
-- receipts at three per owner in a rolling 24-hour window. It is retained for
-- at most 30 days after the last active window and purged in bounded batches.
CREATE TABLE wingward_private.account_deletion_intent_limits (
  owner_profile_id uuid PRIMARY KEY,
  window_started_at timestamptz NOT NULL,
  issued_count integer NOT NULL CHECK (issued_count BETWEEN 1 AND 3),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

ALTER TABLE wingward_private.account_deletion_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE wingward_private.account_deletion_intent_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE wingward_private.account_deletion_operations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE wingward_private.account_deletion_intent_limits FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE wingward_private.account_deletion_operations TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE wingward_private.account_deletion_intent_limits TO service_role;

-- RPC entry points live in public for PostgREST routing but are invoker
-- functions, use an empty search_path, and are executable only by the server's
-- service_role client. Direct table access remains unavailable to app roles.

CREATE FUNCTION public.read_account_deletion_operation(p_operation_id uuid)
RETURNS TABLE (
  operation_id uuid,
  owner_profile_id uuid,
  auth_user_id uuid,
  receipt_hash text,
  status text,
  expires_at timestamptz,
  delete_lease_until timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT operation.operation_id,
         operation.owner_profile_id,
         operation.auth_user_id,
         operation.receipt_hash,
         operation.status,
         operation.expires_at,
         operation.delete_lease_until
    FROM wingward_private.account_deletion_operations AS operation
   WHERE operation.operation_id = p_operation_id
$$;

CREATE FUNCTION public.register_account_deletion_intent(
  p_operation_id uuid,
  p_owner_profile_id uuid,
  p_auth_user_id uuid,
  p_receipt_hash text
)
RETURNS TABLE (result text, status text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := pg_catalog.now();
  v_existing wingward_private.account_deletion_operations%ROWTYPE;
  v_issued_count integer;
BEGIN
  IF p_operation_id IS NULL OR p_owner_profile_id IS NULL OR p_auth_user_id IS NULL
     OR p_receipt_hash IS NULL OR p_receipt_hash !~ '^[0-9a-f]{64}$' THEN
    RETURN QUERY SELECT 'invalid'::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  -- Serialize all new intents for an owner, including different operation IDs.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_owner_profile_id::text, 0)
  );

  PERFORM 1
    FROM public.user_profiles AS profile_row
   WHERE profile_row.id = p_owner_profile_id
     AND profile_row.auth_user_id = p_auth_user_id
   FOR KEY SHARE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'owner_missing'::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  -- FK-less data is purged opportunistically in bounded batches whenever a
  -- new intent is registered. Expired receipts are never renewed or accepted.
  WITH doomed AS (
    SELECT operation.ctid
      FROM wingward_private.account_deletion_operations AS operation
     WHERE operation.expires_at <= v_now
     ORDER BY operation.expires_at
     LIMIT 100
  )
  DELETE FROM wingward_private.account_deletion_operations AS operation
   USING doomed
   WHERE operation.ctid = doomed.ctid;

  WITH doomed AS (
    SELECT limiter.ctid
      FROM wingward_private.account_deletion_intent_limits AS limiter
     WHERE limiter.window_started_at < v_now - interval '30 days'
     ORDER BY limiter.window_started_at
     LIMIT 100
  )
  DELETE FROM wingward_private.account_deletion_intent_limits AS limiter
   USING doomed
   WHERE limiter.ctid = doomed.ctid;

  SELECT operation.* INTO v_existing
    FROM wingward_private.account_deletion_operations AS operation
   WHERE operation.owner_profile_id = p_owner_profile_id
     AND operation.expires_at > v_now
   ORDER BY operation.created_at DESC
   LIMIT 1
   FOR UPDATE;
  IF FOUND THEN
    IF v_existing.operation_id = p_operation_id
       AND v_existing.receipt_hash = p_receipt_hash THEN
      RETURN QUERY SELECT 'existing'::text, v_existing.status, v_existing.expires_at;
      RETURN;
    END IF;
    -- Never replace a live receipt, including while a delete claim is in flight.
    RETURN QUERY SELECT 'conflict'::text, v_existing.status, v_existing.expires_at;
    RETURN;
  END IF;

  INSERT INTO wingward_private.account_deletion_intent_limits AS limiter (
    owner_profile_id, window_started_at, issued_count, updated_at
  ) VALUES (p_owner_profile_id, v_now, 1, v_now)
  ON CONFLICT (owner_profile_id) DO UPDATE
    SET window_started_at = CASE
          WHEN limiter.window_started_at <= v_now - interval '24 hours' THEN v_now
          ELSE limiter.window_started_at
        END,
        issued_count = CASE
          WHEN limiter.window_started_at <= v_now - interval '24 hours' THEN 1
          ELSE limiter.issued_count + 1
        END,
        updated_at = v_now
  WHERE limiter.window_started_at <= v_now - interval '24 hours'
     OR limiter.issued_count < 3
  RETURNING limiter.issued_count INTO v_issued_count;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'rate_limited'::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  INSERT INTO wingward_private.account_deletion_operations (
    operation_id, owner_profile_id, auth_user_id, receipt_hash,
    status, created_at, expires_at
  ) VALUES (
    p_operation_id, p_owner_profile_id, p_auth_user_id, p_receipt_hash,
    'pending', v_now, v_now + interval '7 days'
  );

  RETURN QUERY SELECT 'created'::text, 'pending'::text, v_now + interval '7 days';
END;
$$;

CREATE FUNCTION public.consume_account_deletion_status_rate_limit(
  p_operation_id uuid,
  p_receipt_hash text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := pg_catalog.now();
  v_allowed boolean;
BEGIN
  UPDATE wingward_private.account_deletion_operations AS operation
     SET status_window_started_at = CASE
           WHEN operation.status_window_started_at <= v_now - interval '1 minute' THEN v_now
           ELSE operation.status_window_started_at
         END,
         status_request_count = CASE
           WHEN operation.status_window_started_at <= v_now - interval '1 minute' THEN 1
           ELSE operation.status_request_count + 1
         END
   WHERE operation.operation_id = p_operation_id
     AND operation.receipt_hash = p_receipt_hash
     AND operation.expires_at > v_now
     AND (
       operation.status_window_started_at <= v_now - interval '1 minute'
       OR operation.status_request_count < 10
     )
  RETURNING true INTO v_allowed;
  RETURN COALESCE(v_allowed, false);
END;
$$;

CREATE FUNCTION public.claim_account_deletion_operation(
  p_operation_id uuid,
  p_owner_profile_id uuid,
  p_auth_user_id uuid,
  p_receipt_hash text,
  p_claim_token uuid
)
RETURNS TABLE (result text, status text, lease_until timestamptz)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := pg_catalog.now();
  v_operation wingward_private.account_deletion_operations%ROWTYPE;
BEGIN
  IF p_claim_token IS NULL THEN
    RETURN QUERY SELECT 'invalid'::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  UPDATE wingward_private.account_deletion_operations AS operation
     SET status = 'deleting',
         delete_lease_until = v_now + interval '30 seconds',
         delete_claim_token = p_claim_token,
         delete_window_started_at = CASE
           WHEN operation.delete_window_started_at <= v_now - interval '1 hour' THEN v_now
           ELSE operation.delete_window_started_at
         END,
         delete_attempt_count = CASE
           WHEN operation.delete_window_started_at <= v_now - interval '1 hour' THEN 1
           ELSE operation.delete_attempt_count + 1
         END
   WHERE operation.operation_id = p_operation_id
     AND operation.owner_profile_id = p_owner_profile_id
     AND operation.auth_user_id = p_auth_user_id
     AND operation.receipt_hash = p_receipt_hash
     AND operation.expires_at > v_now
     AND operation.status <> 'deleted'
     AND (operation.delete_lease_until IS NULL OR operation.delete_lease_until <= v_now)
     AND (
       operation.delete_window_started_at <= v_now - interval '1 hour'
       OR operation.delete_attempt_count < 6
     )
  RETURNING operation.* INTO v_operation;

  IF FOUND THEN
    RETURN QUERY SELECT 'claimed'::text, v_operation.status, v_operation.delete_lease_until;
    RETURN;
  END IF;

  SELECT operation.* INTO v_operation
    FROM wingward_private.account_deletion_operations AS operation
   WHERE operation.operation_id = p_operation_id
     AND operation.owner_profile_id = p_owner_profile_id
     AND operation.auth_user_id = p_auth_user_id
     AND operation.receipt_hash = p_receipt_hash;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::text, NULL::timestamptz;
  ELSIF v_operation.expires_at <= v_now THEN
    RETURN QUERY SELECT 'expired'::text, NULL::text, NULL::timestamptz;
  ELSIF v_operation.status = 'deleted' THEN
    RETURN QUERY SELECT 'deleted'::text, v_operation.status, NULL::timestamptz;
  ELSIF v_operation.delete_lease_until > v_now THEN
    RETURN QUERY SELECT 'in_progress'::text, v_operation.status, v_operation.delete_lease_until;
  ELSIF v_operation.delete_window_started_at > v_now - interval '1 hour'
        AND v_operation.delete_attempt_count >= 6 THEN
    RETURN QUERY SELECT 'rate_limited'::text, v_operation.status, NULL::timestamptz;
  ELSE
    RETURN QUERY SELECT 'unavailable'::text, v_operation.status, NULL::timestamptz;
  END IF;
END;
$$;

CREATE FUNCTION public.release_account_deletion_operation(
  p_operation_id uuid,
  p_receipt_hash text,
  p_claim_token uuid
)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  WITH released AS (
    -- Never regress a claimed operation to `pending`. An expired lease does
    -- not prove a slow or response-lost Auth delete stopped; receipt status
    -- must keep reconciling Auth and profile state once deletion has begun.
    UPDATE wingward_private.account_deletion_operations AS operation
       SET delete_lease_until = NULL,
           delete_claim_token = NULL
     WHERE operation.operation_id = p_operation_id
       AND operation.receipt_hash = p_receipt_hash
       AND operation.delete_claim_token = p_claim_token
       AND operation.status = 'deleting'
       AND operation.expires_at > pg_catalog.now()
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM released)
$$;

CREATE FUNCTION public.mark_account_deletion_operation_deleted(
  p_operation_id uuid,
  p_owner_profile_id uuid,
  p_auth_user_id uuid,
  p_receipt_hash text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_changed boolean;
BEGIN
  UPDATE wingward_private.account_deletion_operations AS operation
     SET status = 'deleted',
         deleted_at = COALESCE(operation.deleted_at, pg_catalog.now()),
         delete_lease_until = NULL,
         delete_claim_token = NULL
   WHERE operation.operation_id = p_operation_id
     AND operation.owner_profile_id = p_owner_profile_id
     AND operation.auth_user_id = p_auth_user_id
     AND operation.receipt_hash = p_receipt_hash
     AND operation.expires_at > pg_catalog.now()
     AND operation.status IN ('deleting', 'deleted')
     AND NOT EXISTS (
       SELECT 1
         FROM public.user_profiles AS profile_row
        WHERE profile_row.id = operation.owner_profile_id
     )
  RETURNING true INTO v_changed;
  RETURN COALESCE(v_changed, false);
END;
$$;

DO $$
DECLARE
  v_signature text;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.read_account_deletion_operation(uuid)',
    'public.register_account_deletion_intent(uuid,uuid,uuid,text)',
    'public.consume_account_deletion_status_rate_limit(uuid,text)',
    'public.claim_account_deletion_operation(uuid,uuid,uuid,text,uuid)',
    'public.release_account_deletion_operation(uuid,text,uuid)',
    'public.mark_account_deletion_operation_deleted(uuid,uuid,uuid,text)'
  ] LOOP
    EXECUTE pg_catalog.format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', v_signature);
    EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION %s TO service_role', v_signature);
  END LOOP;
END;
$$;
