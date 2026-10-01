-- Phase 2 S2: atomic arrangement claims, proposal persistence, and expiry.
--
-- This migration is additive.  The API calls these functions with the
-- service_role client; clients must not be able to call them or write the
-- claim ledger directly.  All relationship, block, identity, quota, and
-- expected-state checks remain inside the locked database transition.

CREATE TABLE public.meetup_arrangement_claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meetup_id uuid NOT NULL REFERENCES public.meetups(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  operation_key text NOT NULL CHECK (char_length(operation_key) BETWEEN 1 AND 128),
  is_retry boolean NOT NULL,
  attempt_number integer NOT NULL CHECK (attempt_number >= 1),
  billing_source text NOT NULL CHECK (billing_source IN (
    'meetup_arrange', 'arrange_retry', 'entitlement', 'credit', 'free_retry'
  )),
  period_start date,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (meetup_id, operation_key)
);

ALTER TABLE public.meetup_arrangement_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.meetup_arrangement_claims FROM PUBLIC, anon, authenticated, service_role;

-- N-14 must be emitted at most once per participant for the lifetime of one
-- meetup, just like the existing mutual-intent notifications. Rebuild the
-- additive partial index so the shared notification pipeline enforces this
-- even across retries separated by more than its ordinary 24-hour window.
DROP INDEX IF EXISTS public.notifications_meetup_lifetime_scenario_user_key;
CREATE UNIQUE INDEX notifications_meetup_lifetime_scenario_user_key
  ON public.notifications (scenario_id, user_id, meetup_id)
  WHERE meetup_id IS NOT NULL
    AND scenario_id IN ('N-04', 'N-07', 'N-14');

CREATE INDEX meetup_arrangement_claims_meetup_idx
  ON public.meetup_arrangement_claims (meetup_id, attempt_number);

-- ---------------------------------------------------------------------------
-- Atomic arrange/retry claim and billing boundary.

CREATE OR REPLACE FUNCTION public.claim_meetup_arrangement(
  p_meetup_id uuid,
  p_user_id uuid,
  p_is_retry boolean,
  p_operation_key text
)
RETURNS TABLE (
  meetup_id uuid,
  match_id uuid,
  outcome text,
  status text,
  attempt_number integer,
  billing_source text,
  transitioned boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_meetup public.meetups%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_claim public.meetup_arrangement_claims%ROWTYPE;
  v_entitled boolean := false;
  v_credit_consumed boolean := false;
  v_quota_used integer;
  v_period_start date;
  v_period_end date;
  v_timezone text;
  v_initial_meetup_match_id uuid;
  v_now timestamptz := pg_catalog.now();
  v_attempt integer;
  v_billing_source text;
BEGIN
  IF p_meetup_id IS NULL OR p_user_id IS NULL OR p_is_retry IS NULL
     OR p_operation_key IS NULL
     OR pg_catalog.char_length(p_operation_key) < 1
     OR pg_catalog.char_length(p_operation_key) > 128
     OR p_operation_key !~ '^[\x21-\x7e]+$' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'invalid_input'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Resolve the relationship without locking it.  Every caller then takes
  -- the same match -> room -> meetup lock order before reading state.
  SELECT initial_meetup.match_id
    INTO v_initial_meetup_match_id
    FROM public.meetups AS initial_meetup
   WHERE initial_meetup.id = p_meetup_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Lock the relationship first and validate the caller against its fresh
  -- participant list.  This keeps an idempotency replay from disclosing a
  -- claim to an outsider, even when the operation key is already present.
  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_initial_meetup_match_id
   FOR UPDATE;
  IF NOT FOUND
     OR (p_user_id <> v_match.user_a_id AND p_user_id <> v_match.user_b_id) THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Arrangement is only available inside the same active direct-chat safety
  -- boundary as meetup intent.  The caller's participant id is server-owned.
  IF v_match.status IS DISTINCT FROM 'direct_chat_active' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;
  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- The meetup is the final lock in this order.  Revalidate both foreign-key
  -- relationships after taking it so a stale initial lookup cannot authorize
  -- state from a different match or room.
  SELECT locked_meetup.* INTO v_meetup
    FROM public.meetups AS locked_meetup
   WHERE locked_meetup.id = p_meetup_id
     AND locked_meetup.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND
     OR v_meetup.match_id IS DISTINCT FROM v_match.id
     OR v_room.match_id IS DISTINCT FROM v_meetup.match_id
     OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.blocks
     WHERE (blocker_id = v_match.user_a_id AND blocked_id = v_match.user_b_id)
        OR (blocker_id = v_match.user_b_id AND blocked_id = v_match.user_a_id)
  ) THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'blocked'::text,
      NULL::text, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Both status and timestamp are required.  No development/test bypass is
  -- permitted on this server-owned transition.
  IF (
    SELECT count(*)
      FROM public.user_profiles
     WHERE id IN (v_match.user_a_id, v_match.user_b_id)
       AND age_verified_at IS NOT NULL
       AND identity_verification_status = 'verified'
       AND identity_verified_at IS NOT NULL
  ) <> 2 THEN
    RETURN QUERY SELECT p_meetup_id, v_match.id, 'identity_verification_required'::text,
      v_meetup.status, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  -- Idempotency is checked only after relationship and safety validation.  A
  -- key cannot be replayed by a different participant or operation kind, and
  -- no replay result discloses meetup state to an outsider.
  SELECT claim_row.* INTO v_claim
    FROM public.meetup_arrangement_claims AS claim_row
   WHERE claim_row.meetup_id = p_meetup_id
     AND claim_row.operation_key = p_operation_key;
  IF FOUND THEN
    IF v_claim.user_id <> p_user_id OR v_claim.is_retry IS DISTINCT FROM p_is_retry THEN
      RETURN QUERY SELECT p_meetup_id, v_match.id, 'not_found'::text,
        NULL::text, NULL::integer, NULL::text, false;
      RETURN;
    END IF;
    RETURN QUERY SELECT p_meetup_id, v_match.id, 'already_claimed'::text,
      v_meetup.status, v_claim.attempt_number, v_claim.billing_source, false;
    RETURN;
  END IF;

  SELECT COALESCE(public.entitlements.is_active, false), public.user_profiles.timezone
    INTO v_entitled, v_timezone
    FROM public.user_profiles
    LEFT JOIN public.entitlements
      ON public.entitlements.user_id = public.user_profiles.id
   WHERE public.user_profiles.id = p_user_id;
  IF v_timezone IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = v_timezone
     ) THEN
    -- A malformed profile timezone is an internal fail-closed condition.  It
    -- must never fall back to UTC or another user's calendar month.
    RETURN QUERY SELECT p_meetup_id, v_match.id, 'invalid_input'::text,
      v_meetup.status, NULL::integer, NULL::text, false;
    RETURN;
  END IF;

  IF p_is_retry THEN
    IF v_meetup.status NOT IN ('proposed', 'arrange_failed')
       OR v_meetup.arrange_attempt_count < 1 THEN
      IF v_meetup.status = 'arranging' THEN
        RETURN QUERY SELECT p_meetup_id, v_match.id, 'already_arranging'::text,
          'arranging'::text, v_meetup.arrange_attempt_count, NULL::text, false;
      ELSE
        RETURN QUERY SELECT p_meetup_id, v_match.id, 'invalid_state'::text,
          v_meetup.status, NULL::integer, NULL::text, false;
      END IF;
      RETURN;
    END IF;

    v_attempt := v_meetup.arrange_attempt_count + 1;
    -- The first retry is a per-meetup free retry.  `arrange_retry` is kept as
    -- the billing source so analytics cannot confuse it with meet intent or
    -- the initial monthly `meetup_arrange` allowance.  There is no free path
    -- after this attempt: entitlement or one purchased credit is required.
    IF v_meetup.arrange_attempt_count = 1 THEN
      v_billing_source := 'arrange_retry';
    ELSIF v_entitled THEN
      v_billing_source := 'entitlement';
    ELSE
      v_credit_consumed := public.consume_consumable_credit(
        p_user_id,
        pg_catalog.left('meetup:' || p_meetup_id::text || ':retry:' || p_operation_key, 128)
      );
      IF NOT v_credit_consumed THEN
        RETURN QUERY SELECT p_meetup_id, v_match.id, 'quota_exhausted'::text,
          v_meetup.status, NULL::integer, NULL::text, false;
        RETURN;
      END IF;
      v_billing_source := 'credit';
    END IF;
  ELSE
    IF v_meetup.status = 'arranging' THEN
      RETURN QUERY SELECT p_meetup_id, v_match.id, 'already_arranging'::text,
        'arranging'::text, v_meetup.arrange_attempt_count, NULL::text, false;
      RETURN;
    END IF;
    IF v_meetup.status IS DISTINCT FROM 'verifying' THEN
      RETURN QUERY SELECT p_meetup_id, v_match.id, 'invalid_state'::text,
        v_meetup.status, NULL::integer, NULL::text, false;
      RETURN;
    END IF;

    v_attempt := v_meetup.arrange_attempt_count + 1;
    IF v_entitled THEN
      v_billing_source := 'entitlement';
    ELSE
      -- The free monthly period is computed in the caller's configured IANA
      -- timezone, not in the database/session timezone.
      v_period_start := pg_catalog.date_trunc(
        'month', v_now AT TIME ZONE v_timezone
      )::date;
      v_period_end := (v_period_start + pg_catalog.interval '1 month - 1 day')::date;
      v_quota_used := NULL;
      INSERT INTO public.usage_counters
        (user_id, quota_key, period_start, period_end, used_count)
      VALUES
        (p_user_id, 'meetup_arrange', v_period_start, v_period_end, 1)
      ON CONFLICT (user_id, quota_key, period_start)
      DO UPDATE SET
        used_count = public.usage_counters.used_count + 1,
        period_end = EXCLUDED.period_end,
        updated_at = v_now
      WHERE public.usage_counters.used_count < 1
      RETURNING used_count INTO v_quota_used;

      IF v_quota_used IS NULL THEN
        v_credit_consumed := public.consume_consumable_credit(
          p_user_id,
          pg_catalog.left('meetup:' || p_meetup_id::text || ':arrange:' || p_operation_key, 128)
        );
        IF NOT v_credit_consumed THEN
          RETURN QUERY SELECT p_meetup_id, v_match.id, 'quota_exhausted'::text,
            v_meetup.status, NULL::integer, NULL::text, false;
          RETURN;
        END IF;
        v_billing_source := 'credit';
      ELSE
        v_billing_source := 'meetup_arrange';
      END IF;
    END IF;
  END IF;

  UPDATE public.meetups AS meetup_row
     SET status = 'arranging',
         arrange_attempt_count = v_attempt,
         proposal_expires_at = NULL,
         updated_at = v_now
   WHERE meetup_row.id = p_meetup_id
     AND meetup_row.status = CASE WHEN p_is_retry THEN v_meetup.status ELSE 'verifying' END;

  INSERT INTO public.meetup_arrangement_claims
    (meetup_id, user_id, operation_key, is_retry, attempt_number, billing_source, period_start)
  VALUES
    (p_meetup_id, p_user_id, p_operation_key, p_is_retry, v_attempt, v_billing_source, v_period_start);

  RETURN QUERY SELECT p_meetup_id, v_match.id, 'claimed'::text,
    'arranging'::text, v_attempt, v_billing_source, true;
END;
$$;

COMMENT ON FUNCTION public.claim_meetup_arrangement(uuid, uuid, boolean, text) IS
  'Service-role-only atomic arrange/retry claim. Locks the meetup and match, checks participant/block/identity state, and applies server-owned quota or credit billing exactly once per idempotency key.';

REVOKE ALL ON FUNCTION public.claim_meetup_arrangement(uuid, uuid, boolean, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_meetup_arrangement(uuid, uuid, boolean, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Strict proposal validation and expected-state transition.

CREATE OR REPLACE FUNCTION public.persist_meetup_proposal(
  p_meetup_id uuid,
  p_user_id uuid,
  p_attempt_number integer,
  p_candidates jsonb
)
RETURNS TABLE (
  meetup_id uuid,
  match_id uuid,
  proposal_id uuid,
  attempt_number integer,
  outcome text,
  status text,
  transitioned boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_meetup public.meetups%ROWTYPE;
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_existing public.meetup_proposals%ROWTYPE;
  v_candidate jsonb;
  v_start timestamptz;
  v_now timestamptz := pg_catalog.now();
  v_valid boolean := true;
  v_key text;
  v_rationale text;
  v_area text;
  v_format text;
  v_timezone text;
  v_starts_at text;
  v_proposal_id uuid;
  v_initial_meetup_match_id uuid;
BEGIN
  IF p_meetup_id IS NULL OR p_user_id IS NULL OR p_attempt_number IS NULL
     OR p_attempt_number < 1 THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, NULL::uuid, p_attempt_number,
      'invalid_input'::text, NULL::text, false;
    RETURN;
  END IF;

  -- Resolve the relationship without locking it.  Every caller then takes
  -- the same match -> room -> meetup lock order before reading state.
  SELECT initial_meetup.match_id
    INTO v_initial_meetup_match_id
    FROM public.meetups AS initial_meetup
   WHERE initial_meetup.id = p_meetup_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, NULL::uuid, p_attempt_number,
      'not_found'::text, NULL::text, false;
    RETURN;
  END IF;

  SELECT match_row.* INTO v_match
    FROM public.matches AS match_row
   WHERE match_row.id = v_initial_meetup_match_id
   FOR UPDATE;
  IF NOT FOUND
     OR (p_user_id <> v_match.user_a_id AND p_user_id <> v_match.user_b_id) THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, NULL::uuid, p_attempt_number,
      'not_found'::text, NULL::text, false;
    RETURN;
  END IF;

  IF v_match.status IS DISTINCT FROM 'direct_chat_active' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, NULL::uuid, p_attempt_number,
      'not_found'::text, NULL::text, false;
    RETURN;
  END IF;
  SELECT room_row.* INTO v_room
    FROM public.direct_chat_rooms AS room_row
   WHERE room_row.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, NULL::uuid, p_attempt_number,
      'not_found'::text, NULL::text, false;
    RETURN;
  END IF;

  -- The meetup is the final lock in this order.  Revalidate both foreign-key
  -- relationships after taking it so a stale initial lookup cannot authorize
  -- a changed meetup or room relation.
  SELECT locked_meetup.* INTO v_meetup
    FROM public.meetups AS locked_meetup
   WHERE locked_meetup.id = p_meetup_id
     AND locked_meetup.match_id = v_match.id
   FOR UPDATE;
  IF NOT FOUND
     OR v_meetup.match_id IS DISTINCT FROM v_match.id
     OR v_room.match_id IS DISTINCT FROM v_meetup.match_id
     OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, NULL::uuid, p_attempt_number,
      'not_found'::text, NULL::text, false;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks
     WHERE (blocker_id = v_match.user_a_id AND blocked_id = v_match.user_b_id)
        OR (blocker_id = v_match.user_b_id AND blocked_id = v_match.user_a_id)
  ) THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, NULL::uuid, p_attempt_number,
      'blocked'::text, NULL::text, false;
    RETURN;
  END IF;
  IF (
    SELECT count(*) FROM public.user_profiles
     WHERE id IN (v_match.user_a_id, v_match.user_b_id)
       AND age_verified_at IS NOT NULL
       AND identity_verification_status = 'verified'
       AND identity_verified_at IS NOT NULL
  ) <> 2 THEN
    RETURN QUERY SELECT p_meetup_id, v_match.id, NULL::uuid, p_attempt_number,
      'identity_verification_required'::text, v_meetup.status, false;
    RETURN;
  END IF;

  IF v_meetup.status = 'proposed' THEN
    SELECT proposal_row.* INTO v_existing
      FROM public.meetup_proposals AS proposal_row
     WHERE proposal_row.meetup_id = p_meetup_id
       AND proposal_row.attempt_number = p_attempt_number;
    IF FOUND THEN
      RETURN QUERY SELECT p_meetup_id, v_match.id, v_existing.id, p_attempt_number,
        'already_proposed'::text, 'proposed'::text, false;
      RETURN;
    END IF;
    RETURN QUERY SELECT p_meetup_id, v_match.id, NULL::uuid, p_attempt_number,
      'invalid_state'::text, v_meetup.status, false;
    RETURN;
  END IF;
  IF v_meetup.status = 'arrange_failed' THEN
    RETURN QUERY SELECT p_meetup_id, v_match.id, NULL::uuid, p_attempt_number,
      'already_failed'::text, 'arrange_failed'::text, false;
    RETURN;
  END IF;
  IF v_meetup.status IS DISTINCT FROM 'arranging'
     OR v_meetup.arrange_attempt_count IS DISTINCT FROM p_attempt_number THEN
    RETURN QUERY SELECT p_meetup_id, v_match.id, NULL::uuid, p_attempt_number,
      'invalid_state'::text, v_meetup.status, false;
    RETURN;
  END IF;

  -- Candidate objects are closed: exactly the five public keys are accepted.
  IF p_candidates IS NULL
     OR pg_catalog.jsonb_typeof(p_candidates) IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(p_candidates) <> 3 THEN
    v_valid := false;
  END IF;

  IF v_valid THEN
    FOR v_key IN SELECT '0' UNION ALL SELECT '1' UNION ALL SELECT '2' LOOP
      v_candidate := p_candidates -> (v_key::integer);
      IF pg_catalog.jsonb_typeof(v_candidate) IS DISTINCT FROM 'object'
         OR (SELECT count(*) FROM pg_catalog.jsonb_object_keys(v_candidate)) <> 5
         OR NOT (v_candidate ?& ARRAY['starts_at', 'timezone', 'area', 'format', 'rationale'])
         OR EXISTS (
           SELECT 1 FROM pg_catalog.jsonb_object_keys(v_candidate) AS candidate_key
            WHERE candidate_key NOT IN ('starts_at', 'timezone', 'area', 'format', 'rationale')
         ) THEN
        v_valid := false;
        EXIT;
      END IF;

      v_starts_at := v_candidate ->> 'starts_at';
      v_timezone := v_candidate ->> 'timezone';
      v_area := v_candidate ->> 'area';
      v_format := v_candidate ->> 'format';
      v_rationale := v_candidate ->> 'rationale';
      IF v_starts_at IS NULL
         OR v_starts_at !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$'
         OR v_timezone IS NULL
         OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = v_timezone)
         OR v_area IS NULL
         OR pg_catalog.char_length(v_area) > 160
         OR v_area !~ '^[^/\r\n]{1,80}/[^/\r\n]{1,80}$'
         OR v_area ~ '[,;]'
         OR v_format IS NULL
         OR v_format NOT IN ('cafe', 'meal', 'activity', 'online')
         OR v_rationale IS NULL
         OR pg_catalog.char_length(v_rationale) < 1
         OR pg_catalog.char_length(v_rationale) > 500
         OR pg_catalog.strpos(v_rationale, pg_catalog.chr(10)) > 0
         OR pg_catalog.strpos(v_rationale, pg_catalog.chr(13)) > 0 THEN
        v_valid := false;
        EXIT;
      END IF;
      BEGIN
        v_start := v_starts_at::timestamptz;
      EXCEPTION WHEN OTHERS THEN
        v_start := NULL;
      END;
      IF v_start IS NULL OR v_start <= v_now OR v_start > v_now + pg_catalog.interval '21 days' THEN
        v_valid := false;
        EXIT;
      END IF;
    END LOOP;
  END IF;

  IF v_valid AND (
    p_candidates -> 0 = p_candidates -> 1
    OR p_candidates -> 0 = p_candidates -> 2
    OR p_candidates -> 1 = p_candidates -> 2
  ) THEN
    v_valid := false;
  END IF;

  IF NOT v_valid THEN
    UPDATE public.meetups AS meetup_row
       SET status = 'arrange_failed',
           proposal_expires_at = NULL,
           updated_at = v_now
     WHERE meetup_row.id = p_meetup_id
       AND meetup_row.status = 'arranging';
    RETURN QUERY SELECT p_meetup_id, v_match.id, NULL::uuid, p_attempt_number,
      'arrange_failed'::text, 'arrange_failed'::text, true;
    RETURN;
  END IF;

  INSERT INTO public.meetup_proposals
    (meetup_id, attempt_number, candidates, expires_at, created_at)
  VALUES
    (p_meetup_id, p_attempt_number, p_candidates, v_now + pg_catalog.interval '48 hours', v_now)
  RETURNING id INTO v_proposal_id;

  UPDATE public.meetups AS meetup_row
     SET status = 'proposed',
         proposal_expires_at = v_now + pg_catalog.interval '48 hours',
         updated_at = v_now
   WHERE meetup_row.id = p_meetup_id
     AND meetup_row.status = 'arranging';

  RETURN QUERY SELECT p_meetup_id, v_match.id, v_proposal_id, p_attempt_number,
    'proposed'::text, 'proposed'::text, true;
END;
$$;

COMMENT ON FUNCTION public.persist_meetup_proposal(uuid, uuid, integer, jsonb) IS
  'Service-role-only strict proposal validator and arranging-to-proposed/arrange_failed transition. Invalid model output is never persisted.';

REVOKE ALL ON FUNCTION public.persist_meetup_proposal(uuid, uuid, integer, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.persist_meetup_proposal(uuid, uuid, integer, jsonb)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Code-only expiry branch support.  Only rows that this invocation changed
-- are returned, so notification callers cannot send for an already-expired
-- row or for a concurrent worker's claim.

CREATE OR REPLACE FUNCTION public.claim_expired_meetups(
  p_now timestamptz
)
RETURNS TABLE (
  meetup_id uuid,
  match_id uuid,
  previous_status text,
  status text,
  transitioned boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH candidates AS (
    SELECT m.id, m.match_id, m.status
      FROM public.meetups AS m
     WHERE (
       m.status = 'intent_pending'
       AND m.intent_expires_at IS NOT NULL
       AND m.intent_expires_at <= COALESCE(p_now, pg_catalog.now())
     ) OR (
       m.status = 'proposed'
       AND m.proposal_expires_at IS NOT NULL
       AND m.proposal_expires_at <= COALESCE(p_now, pg_catalog.now())
     ) OR (
       m.status = 'confirmed'
       AND m.confirmed_start_at IS NOT NULL
       AND m.confirmed_start_at <= COALESCE(p_now, pg_catalog.now())
     )
     ORDER BY m.id
     FOR UPDATE SKIP LOCKED
  ), transitioned AS (
    UPDATE public.meetups AS m
       SET status = 'expired',
           intent_expires_at = NULL,
           proposal_expires_at = NULL,
           updated_at = COALESCE(p_now, pg_catalog.now())
      FROM candidates AS c
     WHERE m.id = c.id
       AND m.status = c.status
     RETURNING m.id AS meetup_id, m.match_id, c.status AS previous_status,
               m.status, true AS transitioned
  )
  SELECT transitioned.meetup_id,
         transitioned.match_id,
         transitioned.previous_status,
         transitioned.status,
         transitioned.transitioned
    FROM transitioned;
$$;

COMMENT ON FUNCTION public.claim_expired_meetups(timestamptz) IS
  'Service-role-only conditional meetup expiry claim for intent, proposal, and confirmed meeting boundaries; returns transitioned rows only.';

REVOKE ALL ON FUNCTION public.claim_expired_meetups(timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_expired_meetups(timestamptz)
  TO service_role;
