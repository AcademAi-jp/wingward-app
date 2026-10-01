-- B2 meetup RPC write serialization.
--
-- Keep the public signatures, return shapes, service_role-only grants, and
-- existing relationship/block/identity/expiry/quota/replay rules.  The
-- current locked profile pair is checked only after match -> room -> meetup
-- locks and before any state replay, quota, or content write.

CREATE OR REPLACE FUNCTION public.create_or_match_meetup_intent(
  p_match_id uuid,
  p_user_id uuid
)
RETURNS TABLE (
  meetup_id uuid,
  outcome text,
  status text,
  initiator_id uuid,
  matched boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_meetup public.meetups%ROWTYPE;
  v_now timestamptz := pg_catalog.now();
  v_new_meetup_id uuid;
  v_active_meetup_found boolean;
  v_mutual_eligible boolean;
BEGIN
  -- Lock the match first.  Every invocation for one pair takes this same
  -- lock, so two concurrent intents cannot both create a pending row or miss
  -- the counterpart's intent between a read and an update.
  SELECT * INTO v_match
  FROM public.matches
  WHERE id = p_match_id
  FOR UPDATE;

  IF NOT FOUND OR p_user_id IS NULL
     OR (p_user_id <> v_match.user_a_id AND p_user_id <> v_match.user_b_id) THEN
    RETURN QUERY SELECT NULL::uuid, 'not_found'::text, NULL::text, NULL::uuid, false;
    RETURN;
  END IF;

  -- Meetup intent exists only inside an active direct chat.  Lock the room as
  -- well as the match so a concurrent close and this transition have one
  -- order: a close that wins the lock is observed and fails closed.
  IF v_match.status IS DISTINCT FROM 'direct_chat_active' THEN
    RETURN QUERY SELECT NULL::uuid, 'not_found'::text, NULL::text, NULL::uuid, false;
    RETURN;
  END IF;

  SELECT * INTO v_room
  FROM public.direct_chat_rooms
  WHERE match_id = p_match_id
  FOR UPDATE;

  IF NOT FOUND OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT NULL::uuid, 'not_found'::text, NULL::text, NULL::uuid, false;
    RETURN;
  END IF;

  -- The API also runs its age gate, but this service-only transition keeps
  -- the database path fail-closed if a future caller forgets that middleware.
  IF (
    SELECT count(*)
    FROM public.user_profiles
    WHERE id IN (v_match.user_a_id, v_match.user_b_id)
      AND age_verified_at IS NOT NULL
  ) <> 2 THEN
    RETURN QUERY SELECT NULL::uuid, 'not_found'::text, NULL::text, NULL::uuid, false;
    RETURN;
  END IF;

  -- A block in either direction is a hard safety stop.  The route maps this
  -- non-disclosing outcome to its normal not-found response.
  IF EXISTS (
    SELECT 1
    FROM public.blocks
    WHERE (blocker_id = v_match.user_a_id AND blocked_id = v_match.user_b_id)
       OR (blocker_id = v_match.user_b_id AND blocked_id = v_match.user_a_id)
  ) THEN
    RETURN QUERY SELECT NULL::uuid, 'blocked'::text, NULL::text, NULL::uuid, false;
    RETURN;
  END IF;

  -- Keep this existence result before the eligibility check and any future
  -- statements so the active-row branch remains explicit and stable.
  SELECT * INTO v_meetup
  FROM public.meetups
  WHERE match_id = p_match_id
    AND meetups.status IN (
      'intent_pending', 'intent_matched', 'verifying', 'arranging',
      'proposed', 'confirmed', 'checked_in'
    )
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;
  v_active_meetup_found := FOUND;

  -- This helper acquires the sorted current profile FOR SHARE locks.  A
  -- failed check returns the existing nondisclosing not_found shape before
  -- expiry cleanup, counterpart matching, replay, or insertion.
  v_mutual_eligible := wingward_private.lock_and_check_mutual_eligibility(
    v_match.user_a_id,
    v_match.user_b_id
  );
  IF NOT COALESCE(v_mutual_eligible, false) THEN
    RETURN QUERY SELECT NULL::uuid, 'not_found'::text, NULL::text, NULL::uuid, false;
    RETURN;
  END IF;

  IF v_active_meetup_found THEN
    -- An expired one-sided intent must not be reused as the counterpart's
    -- consent. Mark it terminal while holding the match/room/meetup locks,
    -- then fall through to create a fresh one-sided intent for this caller in
    -- the same invocation. The old row is excluded from the active lookup, so
    -- its timestamp can never be combined with the new caller's intent.
    IF v_meetup.status = 'intent_pending'
       AND v_meetup.intent_expires_at IS NOT NULL
       AND v_meetup.intent_expires_at <= v_now THEN
      UPDATE public.meetups AS meetup_row
      SET status = 'expired',
          intent_expires_at = NULL,
          updated_at = v_now
      WHERE meetup_row.id = v_meetup.id
        AND meetup_row.status = 'intent_pending';
    ELSE
      IF v_meetup.status = 'intent_pending' AND v_meetup.initiator_id <> p_user_id THEN
        UPDATE public.meetups
        SET intent_a_at = CASE WHEN v_match.user_a_id = p_user_id THEN v_now ELSE intent_a_at END,
            intent_b_at = CASE WHEN v_match.user_b_id = p_user_id THEN v_now ELSE intent_b_at END,
            intent_expires_at = NULL,
            status = 'intent_matched',
            updated_at = v_now
        WHERE id = v_meetup.id;

        RETURN QUERY SELECT v_meetup.id, 'matched'::text, 'intent_matched'::text,
          v_meetup.initiator_id, true;
        RETURN;
      END IF;

      -- Repeating one's own intent, or tapping intent after a match already
      -- advanced, is idempotent. Do not return whether the counterpart acted.
      RETURN QUERY SELECT v_meetup.id, 'already_active'::text, v_meetup.status,
        v_meetup.initiator_id, v_meetup.status <> 'intent_pending';
      RETURN;
    END IF;
  END IF;

  INSERT INTO public.meetups (
    match_id,
    initiator_id,
    status,
    intent_a_at,
    intent_b_at,
    intent_expires_at,
    created_at,
    updated_at
  )
  VALUES (
    p_match_id,
    p_user_id,
    'intent_pending',
    CASE WHEN v_match.user_a_id = p_user_id THEN v_now ELSE NULL END,
    CASE WHEN v_match.user_b_id = p_user_id THEN v_now ELSE NULL END,
    v_now + pg_catalog.interval '7 days',
    v_now,
    v_now
  )
  RETURNING id INTO v_new_meetup_id;

  RETURN QUERY SELECT v_new_meetup_id, 'created'::text, 'intent_pending'::text,
    p_user_id, false;
END;
$$;

COMMENT ON FUNCTION public.create_or_match_meetup_intent(uuid, uuid) IS
  'Service-role-only atomic meetup intent creation/matching. Locks the match row, room, meetup, and current mutual profile pair before expiry, replay, or insertion.';

REVOKE ALL ON FUNCTION public.create_or_match_meetup_intent(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_or_match_meetup_intent(uuid, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION public.record_meetup_proposal_response(
  p_meetup_id uuid,
  p_proposal_id uuid,
  p_user_id uuid,
  p_candidate_index integer
)
RETURNS TABLE (
  meetup_id uuid,
  proposal_id uuid,
  outcome text,
  status text,
  confirmed_candidate_index integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_match public.matches%ROWTYPE;
  v_meetup public.meetups%ROWTYPE;
  v_proposal public.meetup_proposals%ROWTYPE;
  v_room public.direct_chat_rooms%ROWTYPE;
  v_response public.meetup_proposal_responses%ROWTYPE;
  v_candidate jsonb;
  v_start timestamptz;
  v_now timestamptz := pg_catalog.now();
  v_a_index integer;
  v_b_index integer;
  v_confirmed_index integer;
  v_response_found boolean;
  v_mutual_eligible boolean;
BEGIN
  IF p_meetup_id IS NULL OR p_proposal_id IS NULL OR p_user_id IS NULL
     OR p_candidate_index IS NULL
     OR p_candidate_index < 0 OR p_candidate_index > 2 THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'invalid_input'::text,
      NULL::text, NULL::integer;
    RETURN;
  END IF;

  -- Resolve the parent without locking, then use the same match -> room ->
  -- meetup lock order as intent creation. Re-read the child after the locks
  -- so a stale parent lookup never authorizes a changed meetup.
  SELECT * INTO v_meetup
  FROM public.meetups
  WHERE id = p_meetup_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'not_found'::text,
      NULL::text, NULL::integer;
    RETURN;
  END IF;

  SELECT * INTO v_match
  FROM public.matches
  WHERE id = v_meetup.match_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_match.status IS DISTINCT FROM 'direct_chat_active'
     OR (p_user_id <> v_match.user_a_id AND p_user_id <> v_match.user_b_id) THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'not_found'::text,
      NULL::text, NULL::integer;
    RETURN;
  END IF;

  IF (
    SELECT count(*)
    FROM public.user_profiles
    WHERE id IN (v_match.user_a_id, v_match.user_b_id)
      AND age_verified_at IS NOT NULL
  ) <> 2 THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'not_found'::text,
      NULL::text, NULL::integer;
    RETURN;
  END IF;

  -- A block can be removed without reopening its closed room. The room is
  -- therefore an independent safety gate, including on confirmation replay.
  SELECT * INTO v_room
  FROM public.direct_chat_rooms
  WHERE match_id = v_match.id
  FOR UPDATE;
  IF NOT FOUND OR v_room.status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'not_found'::text,
      NULL::text, NULL::integer;
    RETURN;
  END IF;

  SELECT * INTO v_meetup
  FROM public.meetups
  WHERE id = p_meetup_id AND match_id = v_match.id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'not_found'::text,
      NULL::text, NULL::integer;
    RETURN;
  END IF;

  -- The profile locks precede identity reads, proposal/response locks, expiry,
  -- and every successful replay or confirmation write.
  v_mutual_eligible := wingward_private.lock_and_check_mutual_eligibility(
    v_match.user_a_id,
    v_match.user_b_id
  );
  IF NOT COALESCE(v_mutual_eligible, false) THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'not_found'::text,
      NULL::text, NULL::integer;
    RETURN;
  END IF;

  -- Responding (including an idempotent confirmation replay) requires both
  -- participants to remain fully identity verified.  The status and timestamp
  -- are separate server-owned fields, so neither one alone is sufficient.
  IF (
    SELECT count(*)
    FROM public.user_profiles
    WHERE id IN (v_match.user_a_id, v_match.user_b_id)
      AND identity_verification_status = 'verified'
      AND identity_verified_at IS NOT NULL
  ) <> 2 THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'invalid_state'::text,
      v_meetup.status, NULL::integer;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocks
    WHERE (blocker_id = v_match.user_a_id AND blocked_id = v_match.user_b_id)
       OR (blocker_id = v_match.user_b_id AND blocked_id = v_match.user_a_id)
  ) THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'blocked'::text,
      NULL::text, NULL::integer;
    RETURN;
  END IF;

  SELECT * INTO v_proposal
  FROM public.meetup_proposals
  WHERE meetup_proposals.meetup_id = p_meetup_id
  ORDER BY attempt_number DESC
  LIMIT 1
  FOR UPDATE;
  -- Reject superseded IDs before either expiry or response writes. An old
  -- proposal must not confirm or expire the live arrangement attempt.
  IF NOT FOUND OR v_proposal.id IS DISTINCT FROM p_proposal_id THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'not_found'::text,
      NULL::text, NULL::integer;
    RETURN;
  END IF;

  -- A repeated request after confirmation is idempotent only for the same
  -- choice.  It cannot be used to rewrite the confirmed candidate.
  SELECT * INTO v_response
  FROM public.meetup_proposal_responses
  WHERE meetup_proposal_responses.proposal_id = p_proposal_id AND user_id = p_user_id
  FOR UPDATE;
  v_response_found := FOUND;

  IF v_meetup.status = 'confirmed' THEN
    IF v_response_found
       AND v_response.selected_candidate_indexes[1] = p_candidate_index THEN
      RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'confirmed'::text,
        'confirmed'::text, p_candidate_index;
    ELSE
      RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'invalid_state'::text,
        'confirmed'::text, NULL::integer;
    END IF;
    RETURN;
  END IF;

  IF v_meetup.status <> 'proposed' THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'invalid_state'::text,
      v_meetup.status, NULL::integer;
    RETURN;
  END IF;

  IF (v_proposal.expires_at IS NOT NULL AND v_proposal.expires_at <= v_now)
     OR (v_meetup.proposal_expires_at IS NOT NULL AND v_meetup.proposal_expires_at <= v_now) THEN
    UPDATE public.meetups
    SET status = 'expired', proposal_expires_at = NULL, updated_at = v_now
    WHERE id = p_meetup_id AND meetups.status = 'proposed';
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'expired'::text,
      'expired'::text, NULL::integer;
    RETURN;
  END IF;

  -- The table CHECK is the durable boundary; keep the function defensive as
  -- well so a malformed pre-existing row cannot be used for confirmation.
  IF pg_catalog.jsonb_typeof(v_proposal.candidates) IS DISTINCT FROM 'array' THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'invalid_input'::text,
      'proposed'::text, NULL::integer;
    RETURN;
  END IF;
  IF pg_catalog.jsonb_array_length(v_proposal.candidates) <> 3 THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'invalid_input'::text,
      'proposed'::text, NULL::integer;
    RETURN;
  END IF;

  -- Validate the selected candidate before inserting the caller's response.
  -- Otherwise a malformed privileged proposal could leave a response row
  -- behind even though the call returns invalid_input.
  v_candidate := v_proposal.candidates -> p_candidate_index;
  IF pg_catalog.jsonb_typeof(v_candidate) IS DISTINCT FROM 'object'
     OR NULLIF(v_candidate ->> 'starts_at', '') IS NULL
     -- Require an explicit UTC offset or Z before the timestamptz cast. An
     -- offsetless value would otherwise be interpreted in the caller's
     -- session timezone, making the accepted instant session-dependent.
     OR (v_candidate ->> 'starts_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$'
     OR NULLIF(v_candidate ->> 'timezone', '') IS NULL
     OR NULLIF(v_candidate ->> 'area', '') IS NULL
     OR NULLIF(v_candidate ->> 'format', '') IS NULL
     OR NULLIF(v_candidate ->> 'format', '') NOT IN ('cafe', 'meal', 'activity', 'online')
     OR pg_catalog.char_length(v_candidate ->> 'area') > 160
     OR pg_catalog.char_length(COALESCE(v_candidate ->> 'rationale', '')) > 500
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_timezone_names
       WHERE name = v_candidate ->> 'timezone'
     ) THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'invalid_input'::text,
      'proposed'::text, NULL::integer;
    RETURN;
  END IF;

  BEGIN
    v_start := (v_candidate ->> 'starts_at')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    v_start := NULL;
  END;

  IF v_start IS NULL OR v_start <= v_now
     OR v_start > v_now + pg_catalog.interval '21 days' THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'invalid_input'::text,
      'proposed'::text, NULL::integer;
    RETURN;
  END IF;

  IF NOT v_response_found THEN
    INSERT INTO public.meetup_proposal_responses (
      proposal_id, user_id, selected_candidate_indexes, response, responded_at
    )
    VALUES (
      p_proposal_id, p_user_id, ARRAY[p_candidate_index], 'selected', v_now
    );
  ELSE
    IF v_response.selected_candidate_indexes[1] <> p_candidate_index THEN
      UPDATE public.meetup_proposal_responses
      SET selected_candidate_indexes = ARRAY[p_candidate_index],
          response = 'selected',
          responded_at = v_now
      WHERE id = v_response.id;
    END IF;
  END IF;

  SELECT selected_candidate_indexes[1] INTO v_a_index
  FROM public.meetup_proposal_responses
  WHERE meetup_proposal_responses.proposal_id = p_proposal_id AND user_id = v_match.user_a_id;

  SELECT selected_candidate_indexes[1] INTO v_b_index
  FROM public.meetup_proposal_responses
  WHERE meetup_proposal_responses.proposal_id = p_proposal_id AND user_id = v_match.user_b_id;

  IF v_a_index IS NULL OR v_b_index IS NULL OR v_a_index <> v_b_index THEN
    RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'accepted'::text,
      'proposed'::text, NULL::integer;
    RETURN;
  END IF;

  v_confirmed_index := v_a_index;
  v_candidate := v_proposal.candidates -> v_confirmed_index;

  UPDATE public.meetups
  SET status = 'confirmed',
      confirmed_start_at = v_start,
      confirmed_timezone = v_candidate ->> 'timezone',
      area = v_candidate ->> 'area',
      format = v_candidate ->> 'format',
      proposal_expires_at = NULL,
      updated_at = v_now
  WHERE id = p_meetup_id AND meetups.status = 'proposed';

  RETURN QUERY SELECT p_meetup_id, p_proposal_id, 'confirmed'::text,
    'confirmed'::text, v_confirmed_index;
END;
$$;

COMMENT ON FUNCTION public.record_meetup_proposal_response(uuid, uuid, uuid, integer) IS
  'Service-role-only atomic proposal response and confirmation. Locks match, room, meetup, and current mutual profile pair before identity, replay, expiry, or response writes.';

REVOKE ALL ON FUNCTION public.record_meetup_proposal_response(uuid, uuid, uuid, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_meetup_proposal_response(uuid, uuid, uuid, integer)
  TO service_role;

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
  v_mutual_eligible boolean;
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

  -- Lock and validate current profiles before identity reads, idempotency
  -- replay, quota/credit use, or the arrangement transition.
  v_mutual_eligible := wingward_private.lock_and_check_mutual_eligibility(
    v_match.user_a_id,
    v_match.user_b_id
  );
  IF NOT COALESCE(v_mutual_eligible, false) THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, 'not_found'::text,
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
  'Service-role-only atomic arrange/retry claim. Locks match, room, meetup, and current mutual profile pair before identity, replay, quota or credit billing; existing state and cleanup semantics are preserved.';

REVOKE ALL ON FUNCTION public.claim_meetup_arrangement(uuid, uuid, boolean, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_meetup_arrangement(uuid, uuid, boolean, text)
  TO service_role;

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
  v_mutual_eligible boolean;
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

  -- Check current locked profiles before identity, proposal replay, candidate
  -- validation, or either generated proposal write.
  v_mutual_eligible := wingward_private.lock_and_check_mutual_eligibility(
    v_match.user_a_id,
    v_match.user_b_id
  );
  IF NOT COALESCE(v_mutual_eligible, false) THEN
    RETURN QUERY SELECT p_meetup_id, NULL::uuid, NULL::uuid, p_attempt_number,
      'not_found'::text, NULL::text, false;
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
  'Service-role-only strict proposal validator and arranging-to-proposed/arrange_failed transition. Locks match, room, meetup, and current mutual profile pair before identity, replay, validation, or generated proposal writes.';

REVOKE ALL ON FUNCTION public.persist_meetup_proposal(uuid, uuid, integer, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.persist_meetup_proposal(uuid, uuid, integer, jsonb)
  TO service_role;
