-- Phase 2 S2: additive meetup state-machine hardening.
--
-- The API uses the service_role client for these functions.  The functions
-- deliberately lock the match/meetup row before reading or changing state;
-- route-level select-then-update is not an atomic state transition.

-- ─────────────────────────────────────────────────────────────────────────
-- Constraints and indexes

ALTER TABLE public.meetup_proposals
  ADD CONSTRAINT meetup_proposals_attempt_number_check
    CHECK (attempt_number >= 1),
  ADD CONSTRAINT meetup_proposals_exactly_three_candidates_check
    CHECK (
      pg_catalog.jsonb_typeof(candidates) = 'array'
      AND pg_catalog.jsonb_array_length(candidates) = 3
    );

-- A meetup cannot have two proposal rows for the same arrangement attempt.
CREATE UNIQUE INDEX meetup_proposals_meetup_attempt_key
  ON public.meetup_proposals (meetup_id, attempt_number);

ALTER TABLE public.meetup_proposal_responses
  ADD CONSTRAINT meetup_proposal_responses_one_index_check
    CHECK (
      selected_candidate_indexes IS NOT NULL
      AND pg_catalog.cardinality(selected_candidate_indexes) = 1
      AND pg_catalog.array_lower(selected_candidate_indexes, 1) = 1
      AND pg_catalog.array_upper(selected_candidate_indexes, 1) = 1
      AND selected_candidate_indexes[1] IS NOT NULL
      AND selected_candidate_indexes[1] BETWEEN 0 AND 2
    );

CREATE INDEX idx_meetups_intent_expiry
  ON public.meetups (intent_expires_at)
  WHERE status = 'intent_pending' AND intent_expires_at IS NOT NULL;

CREATE INDEX idx_meetups_proposal_expiry
  ON public.meetups (proposal_expires_at)
  WHERE status = 'proposed' AND proposal_expires_at IS NOT NULL;

CREATE INDEX idx_meetups_confirmed_start
  ON public.meetups (confirmed_start_at)
  WHERE status IN ('confirmed', 'checked_in') AND confirmed_start_at IS NOT NULL;

-- Preferences are server-owned through the API.  Keep the direct Supabase
-- path from reassigning a row and constrain the closed enums at the DB edge.
ALTER TABLE public.meetup_preferences
  ADD CONSTRAINT meetup_preferences_budget_band_check
    CHECK (budget_band IS NULL OR budget_band IN ('low', 'medium', 'high')),
  ADD CONSTRAINT meetup_preferences_formats_check
    CHECK (
      formats <@ ARRAY['cafe', 'meal', 'activity', 'online']::text[]
      AND pg_catalog.cardinality(formats) <= 4
    );

DROP POLICY IF EXISTS meetup_preferences_update ON public.meetup_preferences;
CREATE POLICY meetup_preferences_update ON public.meetup_preferences FOR UPDATE
  USING (public.get_user_profile_id() = user_id)
  WITH CHECK (public.get_user_profile_id() = user_id);

-- Intent creation and proposal responses are atomic API operations.  The
-- legacy direct-INSERT policies would let an authenticated client bypass the
-- match/room/identity/state checks below and, for intents, probe the partial
-- unique index for a hidden counterpart action.  Keep both write paths
-- service-owned; RLS SELECT policies remain available for authorized reads.
DROP POLICY IF EXISTS meetups_insert ON public.meetups;
DROP POLICY IF EXISTS meetup_proposal_responses_insert
  ON public.meetup_proposal_responses;

-- A block must hide meetup state from both participants, including the blockee
-- whose own RLS view cannot see the other side's blocks row. Keep the
-- participant check inside this match-level helper so a direct boolean call
-- cannot probe an unrelated match. The schema is deliberately not exposed to
-- API roles; the stored RLS policy can invoke the function without granting
-- those roles direct schema access. A cached meetup ID may still change row
-- visibility after access is revoked; this check adds no direct visibility bit.
CREATE SCHEMA IF NOT EXISTS wingward_private;
REVOKE ALL ON SCHEMA wingward_private FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION wingward_private.can_read_unblocked_meetup_match(p_match_id uuid)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.matches AS meetup_match
    WHERE meetup_match.id = p_match_id
      AND public.get_user_profile_id() IN (
        meetup_match.user_a_id,
        meetup_match.user_b_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.blocks AS block_row
        WHERE (block_row.blocker_id = meetup_match.user_a_id
               AND block_row.blocked_id = meetup_match.user_b_id)
           OR (block_row.blocker_id = meetup_match.user_b_id
               AND block_row.blocked_id = meetup_match.user_a_id)
      )
  )
$$;

REVOKE ALL ON FUNCTION wingward_private.can_read_unblocked_meetup_match(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION wingward_private.can_read_unblocked_meetup_match(uuid)
  TO authenticated, service_role;

-- One-sided intent remains private after a lazy expiry or an explicit
-- cancellation.  The old policy used status = 'intent_pending' as the
-- privacy boundary, which disclosed a terminal one-sided row to the other
-- participant.  Consent is mutual only when both intent timestamps exist;
-- the initiator can see their own row in every state.  Keep the participant
-- and age-verification gates on the parent row.
DROP POLICY IF EXISTS meetups_select ON public.meetups;
CREATE POLICY meetups_select ON public.meetups FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = match_id
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = match_id
    )
    AND public.are_match_participants_age_verified(match_id)
    AND (
      initiator_id = public.get_user_profile_id()
      OR (intent_a_at IS NOT NULL AND intent_b_at IS NOT NULL)
    )
    AND wingward_private.can_read_unblocked_meetup_match(match_id)
  );

-- ─────────────────────────────────────────────────────────────────────────
-- Notification scenario seed

INSERT INTO public.notification_scenarios
  (scenario_id, title, trigger_description, target_action, priority, quiet_hours_exempt)
VALUES
  (
    'N-14',
    'Meetup scheduling needs attention',
    'Meetup arrangement failed and needs a retry or updated preferences',
    'Review meetup scheduling',
    'P0',
    false
  )
ON CONFLICT (scenario_id) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────
-- Atomic mutual-intent transition

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

  -- The partial unique index is a backstop; the match lock makes this lookup
  -- and the following transition one serialized operation for this pair.
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

  IF FOUND THEN
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
  'Service-role-only atomic meetup intent creation/matching. Locks the match row, hides one-sided intent at the API boundary, and transitions the second intent to intent_matched.';

REVOKE ALL ON FUNCTION public.create_or_match_meetup_intent(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_or_match_meetup_intent(uuid, uuid)
  TO service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- Atomic proposal response and confirmation

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
  'Service-role-only atomic proposal response and confirmation. Locks the meetup, validates ownership and safety state, and confirms only when both participants selected the same candidate index.';

REVOKE ALL ON FUNCTION public.record_meetup_proposal_response(uuid, uuid, uuid, integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_meetup_proposal_response(uuid, uuid, uuid, integer)
  TO service_role;
