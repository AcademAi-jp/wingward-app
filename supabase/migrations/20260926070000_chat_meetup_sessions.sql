-- Chat-owned meetup projection, private short-lived planning inputs, and safe replay state.
-- All writes go through service_role-only RPCs. Existing meetups remain the safety/quota anchor.

CREATE TABLE public.chat_meetup_sessions (
  meetup_id uuid PRIMARY KEY REFERENCES public.meetups(id) ON DELETE CASCADE,
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  room_id uuid NOT NULL REFERENCES public.direct_chat_rooms(id) ON DELETE CASCADE,
  user_a_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  user_b_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN (
    'intent_pending', 'awaiting_availability', 'time_proposed', 'awaiting_location',
    'cafe_proposed', 'confirmed', 'completed', 'cancelled', 'expired', 'unavailable'
  )),
  revision integer NOT NULL DEFAULT 0 CHECK (revision >= 0),
  time_candidates jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (
    pg_catalog.jsonb_typeof(time_candidates) = 'array'
    AND pg_catalog.jsonb_array_length(time_candidates) <= 3
  ),
  cafe_candidates jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (
    pg_catalog.jsonb_typeof(cafe_candidates) = 'array'
    AND pg_catalog.jsonb_array_length(cafe_candidates) <= 3
  ),
  time_choice_a text,
  time_choice_b text,
  selected_time_candidate_id text,
  cafe_choice_a text,
  cafe_choice_b text,
  confirmed_starts_at timestamptz,
  confirmed_ends_at timestamptz,
  confirmed_timezone text,
  completed_a_at timestamptz,
  completed_b_at timestamptz,
  unavailable_reason text CHECK (unavailable_reason IS NULL OR unavailable_reason IN (
    'calendar_unavailable', 'no_shared_time', 'cafe_unavailable', 'no_cafe'
  )),
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (meetup_id, match_id, room_id),
  CHECK (user_a_id <> user_b_id),
  CHECK (
    (confirmed_starts_at IS NULL AND confirmed_ends_at IS NULL AND confirmed_timezone IS NULL)
    OR (confirmed_starts_at IS NOT NULL AND confirmed_ends_at IS NOT NULL
        AND confirmed_timezone = 'UTC' AND confirmed_ends_at > confirmed_starts_at)
  ),
  CHECK (
    status NOT IN ('confirmed', 'completed')
    OR (confirmed_starts_at IS NOT NULL AND confirmed_ends_at IS NOT NULL)
  )
);

CREATE INDEX chat_meetup_sessions_room_latest_idx
  ON public.chat_meetup_sessions (room_id, created_at DESC);
CREATE UNIQUE INDEX chat_meetup_sessions_one_open_match_idx
  ON public.chat_meetup_sessions (match_id)
  WHERE status NOT IN ('completed', 'cancelled', 'expired');
CREATE INDEX chat_meetup_sessions_expiry_idx
  ON public.chat_meetup_sessions (expires_at)
  WHERE expires_at IS NOT NULL AND status NOT IN ('completed', 'cancelled', 'expired');

CREATE TABLE public.chat_meetup_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meetup_id uuid NOT NULL REFERENCES public.chat_meetup_sessions(meetup_id) ON DELETE CASCADE,
  revision integer NOT NULL CHECK (revision >= 0),
  event_key text NOT NULL CHECK (char_length(event_key) BETWEEN 1 AND 160),
  kind text NOT NULL CHECK (kind IN ('system', 'human', 'ward')),
  text text NOT NULL CHECK (char_length(text) BETWEEN 1 AND 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (meetup_id, event_key)
);
CREATE INDEX chat_meetup_events_timeline_idx
  ON public.chat_meetup_events (meetup_id, revision, created_at, id);

-- Calendar data contains only bounded UTC intervals. It is service-owned and
-- deleted after candidate generation or at its short TTL.
CREATE TABLE public.chat_meetup_availability (
  meetup_id uuid NOT NULL REFERENCES public.chat_meetup_sessions(meetup_id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  source text NOT NULL CHECK (source IN ('calendar', 'manual')),
  window_starts_at timestamptz NOT NULL,
  window_ends_at timestamptz NOT NULL,
  intervals jsonb NOT NULL CHECK (
    pg_catalog.jsonb_typeof(intervals) = 'array'
    AND pg_catalog.jsonb_array_length(intervals) <= 128
  ),
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (meetup_id, user_id),
  CHECK (window_ends_at > window_starts_at),
  CHECK (window_ends_at <= window_starts_at + interval '21 days'),
  CHECK (expires_at <= created_at + interval '30 minutes')
);
CREATE INDEX chat_meetup_availability_expiry_idx ON public.chat_meetup_availability (expires_at);

-- Current location/station input is caller-consented, provider-only and expires
-- quickly. It is never copied to the event or public session tables.
CREATE TABLE public.chat_meetup_locations (
  meetup_id uuid NOT NULL REFERENCES public.chat_meetup_sessions(meetup_id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  method text NOT NULL CHECK (method IN ('current', 'station')),
  origin jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(origin) = 'object'),
  consented_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (meetup_id, user_id),
  CHECK (expires_at <= consented_at + interval '30 minutes')
);
CREATE INDEX chat_meetup_locations_expiry_idx ON public.chat_meetup_locations (expires_at);

-- The replay ledger stores only a one-way request digest, never request JSON.
CREATE TABLE public.chat_meetup_operations (
  room_id uuid NOT NULL REFERENCES public.direct_chat_rooms(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  idempotency_key uuid NOT NULL,
  meetup_id uuid REFERENCES public.chat_meetup_sessions(meetup_id) ON DELETE CASCADE,
  request_digest text NOT NULL CHECK (request_digest ~ '^[0-9a-f]{64}$'),
  outcome text NOT NULL,
  result_status text NOT NULL,
  result_revision integer NOT NULL CHECK (result_revision >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, user_id, idempotency_key)
);
CREATE INDEX chat_meetup_operations_meetup_idx
  ON public.chat_meetup_operations (meetup_id, created_at DESC);

ALTER TABLE public.chat_meetup_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_meetup_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_meetup_availability ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_meetup_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_meetup_operations ENABLE ROW LEVEL SECURITY;

-- The API reads through service_role after its authenticated projection check;
-- no direct client table access can expose peer decisions or private inputs.
REVOKE ALL ON TABLE public.chat_meetup_sessions,
  public.chat_meetup_events,
  public.chat_meetup_availability,
  public.chat_meetup_locations,
  public.chat_meetup_operations
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.chat_meetup_sessions, public.chat_meetup_events,
  public.chat_meetup_availability, public.chat_meetup_locations,
  public.chat_meetup_operations
  FROM service_role;
GRANT SELECT ON TABLE public.chat_meetup_sessions, public.chat_meetup_events,
  public.chat_meetup_availability, public.chat_meetup_locations TO service_role;


-- Caller-private consent and fencing. A participant's one-sided actions never
-- increment the shared session revision or create a shared event.
CREATE TABLE public.chat_meetup_private_decisions (
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  room_id uuid NOT NULL REFERENCES public.direct_chat_rooms(id) ON DELETE CASCADE,
  meetup_id uuid REFERENCES public.chat_meetup_sessions(meetup_id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  intent_value boolean,
  private_revision integer NOT NULL DEFAULT 0 CHECK (private_revision >= 0),
  time_choice_id text,
  cafe_choice_id text,
  completed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (match_id, user_id)
);
CREATE INDEX chat_meetup_private_decisions_meetup_idx
  ON public.chat_meetup_private_decisions (meetup_id, user_id);

ALTER TABLE public.chat_meetup_sessions
  ADD COLUMN quota_claim_owner_id uuid REFERENCES public.user_profiles(id),
  ADD COLUMN quota_operation_key text;

ALTER TABLE public.chat_meetup_private_decisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.chat_meetup_private_decisions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.chat_meetup_private_decisions TO service_role;

-- The state RPC follows the project serialization order: pair profile locks,
-- match, active room, meetup, shared session, then caller-private rows.
-- The route additionally validates the exact strict DTO before calling this
-- service-role-only function.
CREATE OR REPLACE FUNCTION public.apply_chat_meetup_action(
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_expected_own_revision integer,
  p_idempotency_key uuid,
  p_request_digest text,
  p_action jsonb
)
RETURNS TABLE (
  outcome text,
  meetup_id uuid,
  status text,
  revision integer,
  own_revision integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_match_id uuid;
  v_a_id uuid;
  v_b_id uuid;
  v_room_status text;
  v_meetup public.meetups%ROWTYPE;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_decision public.chat_meetup_private_decisions%ROWTYPE;
  v_other_decision public.chat_meetup_private_decisions%ROWTYPE;
  v_operation public.chat_meetup_operations%ROWTYPE;
  v_actor_choice text;
  v_other_choice text;
  v_action_type text;
  v_now timestamptz := pg_catalog.now();
  v_revision integer := 0;
  v_own_revision integer := 0;
  v_session_exists boolean := false;
  v_session_created boolean := false;
  v_completed_count integer := 0;
  v_operation_key text;
  v_time_candidate jsonb;
  v_cafe_candidate jsonb;
  v_meetup_id uuid;
  v_previous_meetup_id uuid;
  v_previous_revision integer;
BEGIN
  IF p_room_id IS NULL OR p_user_id IS NULL
     OR p_expected_revision IS NULL OR p_expected_revision < 0
     OR p_expected_own_revision IS NULL OR p_expected_own_revision < 0
     OR p_idempotency_key IS NULL
     OR p_request_digest IS NULL OR p_request_digest !~ '^[0-9a-f]{64}$'
     OR pg_catalog.jsonb_typeof(p_action) IS DISTINCT FROM 'object' THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT room.match_id INTO v_match_id
    FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT match_row.user_a_id, match_row.user_b_id
    INTO v_a_id, v_b_id
    FROM public.matches AS match_row
   WHERE match_row.id = v_match_id;
  IF NOT FOUND OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT match_row.user_a_id, match_row.user_b_id, match_row.status
    INTO v_a_id, v_b_id, v_room_status
    FROM public.matches AS match_row
   WHERE match_row.id = v_match_id
   FOR UPDATE;
  IF NOT FOUND OR v_room_status IS DISTINCT FROM 'direct_chat_active'
     OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT room.status INTO v_room_status
    FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id
   FOR UPDATE;
  IF NOT FOUND OR v_room_status IS DISTINCT FROM 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
    RETURN;
  END IF;

  SELECT session_row.* INTO v_session
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.room_id = p_room_id
   ORDER BY session_row.created_at DESC, session_row.meetup_id DESC
   LIMIT 1
   FOR UPDATE;
  v_session_exists := FOUND;
  IF v_session_exists THEN
    IF v_session.match_id <> v_match_id
       OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
      RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0, 0;
      RETURN;
    END IF;
    v_meetup_id := v_session.meetup_id;
    v_previous_meetup_id := v_session.meetup_id;
    v_revision := v_session.revision;
    v_previous_revision := v_session.revision;
    IF v_session.status IN ('completed', 'cancelled')
       OR (v_session.status = 'expired' AND p_action ->> 'type' <> 'replan') THEN
      v_session_exists := false;
      v_meetup_id := NULL;
    END IF;
  END IF;

  SELECT operation_row.* INTO v_operation
    FROM public.chat_meetup_operations AS operation_row
   WHERE operation_row.room_id = p_room_id
     AND operation_row.user_id = p_user_id
     AND operation_row.idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_operation.request_digest IS DISTINCT FROM p_request_digest THEN
      RETURN QUERY SELECT 'idempotency_conflict'::text, NULL::uuid, NULL::text, 0, 0;
      RETURN;
    END IF;
    SELECT COALESCE(decision.private_revision, 0) INTO v_own_revision
      FROM public.chat_meetup_private_decisions AS decision
     WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
    RETURN QUERY SELECT 'replayed'::text,
      CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
      CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
      v_revision, COALESCE(v_own_revision, 0);
    RETURN;
  END IF;

  INSERT INTO public.chat_meetup_private_decisions
    (match_id, room_id, meetup_id, user_id)
  VALUES (v_match_id, p_room_id, CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END, p_user_id)
  ON CONFLICT (match_id, user_id) DO NOTHING;

  SELECT decision.* INTO v_decision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id
   FOR UPDATE;
  v_own_revision := v_decision.private_revision;
  IF v_revision <> p_expected_revision OR v_own_revision <> p_expected_own_revision THEN
    RETURN QUERY SELECT 'stale_revision'::text,
      CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
      CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
      v_revision, v_own_revision;
    RETURN;
  END IF;

  v_action_type := p_action ->> 'type';

  IF v_action_type = 'intent' THEN
    IF v_session_exists OR p_action ->> 'value' IS NULL OR p_action ->> 'value' NOT IN ('yes', 'withdraw') THEN
      RETURN QUERY SELECT 'invalid_state'::text, NULL::uuid, NULL::text, v_revision, v_own_revision;
      RETURN;
    END IF;

    IF p_action ->> 'value' = 'withdraw' THEN
      UPDATE public.chat_meetup_private_decisions
         SET intent_value = NULL,
             private_revision = private_revision + 1,
             updated_at = v_now
       WHERE match_id = v_match_id AND user_id = p_user_id
       RETURNING private_revision INTO v_own_revision;

      UPDATE public.meetups AS meetup_row
         SET status = 'declined',
             intent_expires_at = NULL,
             updated_at = v_now
       WHERE meetup_row.match_id = v_match_id
         AND meetup_row.status = 'intent_pending'
         AND meetup_row.initiator_id = p_user_id;
    ELSE
      IF v_previous_meetup_id IS NOT NULL AND v_session.status IN ('expired', 'cancelled') THEN
        UPDATE public.meetups AS old_meetup
           SET status = CASE WHEN v_session.status = 'expired' THEN 'expired' ELSE 'cancelled' END,
               intent_expires_at = NULL, proposal_expires_at = NULL, updated_at = v_now
         WHERE old_meetup.id = v_previous_meetup_id
           AND old_meetup.status IN ('intent_pending', 'intent_matched', 'verifying', 'arranging', 'proposed');
      END IF;
      SELECT meetup_row.* INTO v_meetup
        FROM public.meetups AS meetup_row
       WHERE meetup_row.match_id = v_match_id
         AND meetup_row.status IN ('intent_pending', 'intent_matched', 'verifying')
       ORDER BY meetup_row.created_at DESC
       LIMIT 1
       FOR UPDATE;

      IF FOUND AND v_meetup.status = 'intent_pending'
         AND v_meetup.intent_expires_at IS NOT NULL
         AND v_meetup.intent_expires_at <= v_now THEN
        UPDATE public.meetups AS meetup_row
           SET status = 'expired', intent_expires_at = NULL, updated_at = v_now
         WHERE meetup_row.id = v_meetup.id;
        v_meetup := NULL;
      END IF;

      IF v_meetup.id IS NULL THEN
        INSERT INTO public.meetups
          (match_id, initiator_id, status, intent_a_at, intent_b_at, intent_expires_at, created_at, updated_at)
        VALUES
          (v_match_id, p_user_id, 'intent_pending',
           CASE WHEN p_user_id = v_a_id THEN v_now ELSE NULL END,
           CASE WHEN p_user_id = v_b_id THEN v_now ELSE NULL END,
           v_now + pg_catalog.interval '7 days', v_now, v_now)
        RETURNING * INTO v_meetup;
      ELSIF v_meetup.status = 'intent_pending'
            AND v_meetup.initiator_id <> p_user_id THEN
        UPDATE public.meetups AS meetup_row
           SET intent_a_at = CASE WHEN p_user_id = v_a_id THEN v_now ELSE meetup_row.intent_a_at END,
               intent_b_at = CASE WHEN p_user_id = v_b_id THEN v_now ELSE meetup_row.intent_b_at END,
               intent_expires_at = NULL,
               status = 'intent_matched',
               updated_at = v_now
         WHERE meetup_row.id = v_meetup.id
         RETURNING * INTO v_meetup;
      END IF;

      v_meetup_id := v_meetup.id;
      UPDATE public.chat_meetup_private_decisions
         SET meetup_id = NULL,
             intent_value = true,
             private_revision = private_revision + 1,
             updated_at = v_now
       WHERE match_id = v_match_id AND user_id = p_user_id
       RETURNING private_revision INTO v_own_revision;

      IF v_meetup.status IN ('intent_matched', 'verifying')
         AND v_meetup.intent_a_at IS NOT NULL AND v_meetup.intent_b_at IS NOT NULL THEN
        UPDATE public.meetups AS meetup_row
           SET status = 'verifying', updated_at = v_now
         WHERE meetup_row.id = v_meetup.id
           AND meetup_row.status = 'intent_matched';

        -- The caller-private rows below reference the session. Create that
        -- durable FK target first, within this same transaction.
        INSERT INTO public.chat_meetup_sessions
          (meetup_id, match_id, room_id, user_a_id, user_b_id, status, revision, expires_at)
        VALUES (v_meetup.id, v_match_id, p_room_id, v_a_id, v_b_id,
          'awaiting_availability', v_revision + 1, v_now + pg_catalog.interval '7 days')
        ON CONFLICT ON CONSTRAINT chat_meetup_sessions_pkey DO NOTHING;

        SELECT session_row.* INTO v_session
          FROM public.chat_meetup_sessions AS session_row
         WHERE session_row.meetup_id = v_meetup.id
         FOR UPDATE;
        v_session_exists := FOUND;
        v_meetup_id := v_meetup.id;
        v_revision := v_session.revision;
        v_session_created := true;

        INSERT INTO public.chat_meetup_private_decisions
          (match_id, room_id, meetup_id, user_id, intent_value)
        VALUES (v_match_id, p_room_id, v_meetup.id,
          CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END, true)
        ON CONFLICT (match_id, user_id) DO UPDATE
          SET meetup_id = EXCLUDED.meetup_id,
              intent_value = true,
              time_choice_id = NULL,
              cafe_choice_id = NULL,
              completed_at = NULL;

        INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
        VALUES (v_meetup.id, v_revision, 'state:mutual-intent', 'system',
          'You both want to meet. Choose a time together.')
        ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;

        UPDATE public.chat_meetup_private_decisions
           SET meetup_id = v_meetup.id
         WHERE match_id = v_match_id AND user_id = p_user_id;
        UPDATE public.chat_meetup_private_decisions
           SET time_choice_id = NULL, cafe_choice_id = NULL, completed_at = NULL
         WHERE match_id = v_match_id
           AND user_id = CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END;
      END IF;
    END IF;
  ELSE
    IF NOT v_session_exists OR (v_session.expires_at IS NOT NULL AND v_session.expires_at <= v_now AND v_session.status <> 'expired') THEN
      RETURN QUERY SELECT 'invalid_state'::text,
        CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
        CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
        v_revision, v_own_revision;
      RETURN;
    END IF;

    IF v_session.status NOT IN ('cancelled', 'expired', 'completed') OR (v_action_type = 'replan' AND v_session.status = 'expired') THEN
      IF (
        SELECT count(*) FROM public.user_profiles AS profile
         WHERE profile.id IN (v_a_id, v_b_id)
           AND profile.identity_verification_status = 'verified'
           AND profile.identity_verified_at IS NOT NULL
      ) <> 2
      AND v_action_type IN (
        'availability.submit', 'time.approve', 'location.submit',
        'cafe.approve', 'cafe.decline', 'replan'
      ) THEN
        RETURN QUERY SELECT 'identity_verification_required'::text, v_meetup_id,
          v_session.status, v_revision, v_own_revision;
        RETURN;
      END IF;

      IF v_action_type = 'availability.submit' THEN
        IF v_session.status <> 'awaiting_availability' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        IF p_action ->> 'source' IS NULL OR p_action ->> 'source' NOT IN ('calendar', 'manual')
           OR pg_catalog.jsonb_typeof(p_action -> 'window') IS DISTINCT FROM 'object'
           OR pg_catalog.jsonb_typeof(COALESCE(p_action -> 'busy', p_action -> 'available')) IS DISTINCT FROM 'array'
           OR pg_catalog.jsonb_array_length(COALESCE(p_action -> 'busy', p_action -> 'available')) > 128 THEN
          RETURN QUERY SELECT 'invalid_input'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        INSERT INTO public.chat_meetup_availability
          (meetup_id, user_id, source, window_starts_at, window_ends_at, intervals, expires_at, created_at)
        VALUES (
          v_meetup_id, p_user_id, p_action ->> 'source',
          (p_action -> 'window' ->> 'starts_at')::timestamptz,
          (p_action -> 'window' ->> 'ends_at')::timestamptz,
          COALESCE(p_action -> 'busy', p_action -> 'available'),
          v_now + pg_catalog.interval '30 minutes', v_now
        )
        ON CONFLICT ON CONSTRAINT chat_meetup_availability_pkey DO UPDATE
          SET source = EXCLUDED.source,
              window_starts_at = EXCLUDED.window_starts_at,
              window_ends_at = EXCLUDED.window_ends_at,
              intervals = EXCLUDED.intervals,
              expires_at = EXCLUDED.expires_at,
              created_at = EXCLUDED.created_at;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;

        IF v_session.quota_claim_owner_id IS NULL
           AND 2 = (
             SELECT count(*) FROM public.chat_meetup_availability AS availability
              WHERE availability.meetup_id = v_meetup_id
                AND availability.expires_at > v_now
           ) THEN
          UPDATE public.chat_meetup_sessions
             SET quota_claim_owner_id = p_user_id,
                 quota_operation_key = 'chat-meetup:' || v_meetup_id::text
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id;
        END IF;
      ELSIF v_action_type = 'availability.clear' THEN
        IF v_session.status <> 'awaiting_availability' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        DELETE FROM public.chat_meetup_availability AS availability
         WHERE availability.meetup_id = v_meetup_id AND user_id = p_user_id;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
      ELSIF v_action_type = 'time.approve' THEN
        IF v_session.status <> 'time_proposed'
           OR NOT EXISTS (
             SELECT 1 FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
              WHERE candidate ->> 'id' = p_action ->> 'candidate_id'
           ) THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        SELECT candidate INTO v_time_candidate
          FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
         WHERE candidate ->> 'id' = p_action ->> 'candidate_id';
        IF v_time_candidate IS NULL
           OR (v_time_candidate ->> 'starts_at')::timestamptz <= v_now
           OR (v_time_candidate ->> 'ends_at')::timestamptz <= (v_time_candidate ->> 'starts_at')::timestamptz THEN
          RETURN QUERY SELECT 'expired_candidate'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        v_actor_choice := p_action ->> 'candidate_id';
        UPDATE public.chat_meetup_private_decisions
           SET time_choice_id = v_actor_choice,
               private_revision = private_revision + 1,
               updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
        SELECT decision.* INTO v_other_decision
          FROM public.chat_meetup_private_decisions AS decision
         WHERE decision.match_id = v_match_id
           AND decision.user_id = CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END;
        IF FOUND AND v_other_decision.time_choice_id = v_actor_choice THEN
          UPDATE public.chat_meetup_sessions
             SET status = 'awaiting_location',
                 selected_time_candidate_id = v_actor_choice,
                 cafe_candidates = '[]'::jsonb,
                 unavailable_reason = NULL,
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now,
                 expires_at = v_now + pg_catalog.interval '30 minutes'
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:time-approved:' || v_revision::text, 'system',
            'You both chose the same time. Share a starting area only if you want help finding a cafe.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        END IF;
      ELSIF v_action_type = 'location.submit' THEN
        IF v_session.status <> 'awaiting_location'
           OR pg_catalog.jsonb_typeof(p_action -> 'location') IS DISTINCT FROM 'object' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        INSERT INTO public.chat_meetup_locations
          (meetup_id, user_id, method, origin, consented_at, expires_at)
        VALUES (
          v_meetup_id, p_user_id,
          CASE WHEN p_action -> 'location' ->> 'kind' = 'coordinates' THEN 'current' ELSE 'station' END,
          p_action -> 'location', v_now, v_now + pg_catalog.interval '30 minutes'
        )
        ON CONFLICT ON CONSTRAINT chat_meetup_locations_pkey DO UPDATE
          SET method = EXCLUDED.method,
              origin = EXCLUDED.origin,
              consented_at = EXCLUDED.consented_at,
              expires_at = EXCLUDED.expires_at;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
      ELSIF v_action_type = 'location.clear' THEN
        IF v_session.status <> 'awaiting_location' THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        DELETE FROM public.chat_meetup_locations AS location
         WHERE location.meetup_id = v_meetup_id AND user_id = p_user_id;
        UPDATE public.chat_meetup_private_decisions
           SET private_revision = private_revision + 1, updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
      ELSIF v_action_type = 'cafe.approve' THEN
        IF v_session.status <> 'cafe_proposed'
           OR pg_catalog.jsonb_typeof(v_session.cafe_candidates) IS DISTINCT FROM 'array'
           OR NOT EXISTS (
             SELECT 1 FROM pg_catalog.jsonb_array_elements(v_session.cafe_candidates) AS candidate
              WHERE candidate ->> 'id' = p_action ->> 'candidate_id'
           ) THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        v_actor_choice := p_action ->> 'candidate_id';
        SELECT candidate INTO v_cafe_candidate
          FROM pg_catalog.jsonb_array_elements(v_session.cafe_candidates) AS candidate
         WHERE candidate ->> 'id' = v_actor_choice;
        SELECT candidate INTO v_time_candidate
          FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
         WHERE candidate ->> 'id' = v_session.selected_time_candidate_id;
        IF v_cafe_candidate IS NULL OR v_time_candidate IS NULL
           OR (v_cafe_candidate ->> 'verified_at') IS NULL
           OR (v_cafe_candidate ->> 'verified_at')::timestamptz > v_now + pg_catalog.interval '5 minutes'
           OR (v_cafe_candidate ->> 'verified_at')::timestamptz < v_now - pg_catalog.interval '6 hours'
           OR (v_time_candidate ->> 'starts_at')::timestamptz <= v_now
           OR (v_time_candidate ->> 'ends_at')::timestamptz <= (v_time_candidate ->> 'starts_at')::timestamptz
           OR (v_cafe_candidate ->> 'starts_at') IS NULL
           OR (v_cafe_candidate ->> 'ends_at') IS NULL
           OR (v_cafe_candidate ->> 'starts_at')::timestamptz > (v_time_candidate ->> 'starts_at')::timestamptz
           OR (v_cafe_candidate ->> 'ends_at')::timestamptz < (v_time_candidate ->> 'ends_at')::timestamptz THEN
          RETURN QUERY SELECT 'expired_candidate'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        UPDATE public.chat_meetup_private_decisions
           SET cafe_choice_id = v_actor_choice,
               private_revision = private_revision + 1,
               updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
        SELECT decision.* INTO v_other_decision
          FROM public.chat_meetup_private_decisions AS decision
         WHERE decision.match_id = v_match_id
           AND decision.user_id = CASE WHEN p_user_id = v_a_id THEN v_b_id ELSE v_a_id END;
        IF FOUND AND v_other_decision.cafe_choice_id = v_actor_choice THEN

          UPDATE public.chat_meetup_sessions
             SET status = 'confirmed',
                 confirmed_starts_at = (v_time_candidate ->> 'starts_at')::timestamptz,
                 confirmed_ends_at = (v_time_candidate ->> 'ends_at')::timestamptz,
                 confirmed_timezone = 'UTC',
                 cafe_candidates = jsonb_build_array(v_cafe_candidate),
                 unavailable_reason = NULL,
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now,
                 expires_at = NULL
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          UPDATE public.meetups AS meetup_row
             SET status = 'confirmed',
                 confirmed_start_at = v_session.confirmed_starts_at,
                 confirmed_timezone = 'UTC',
                 area = v_cafe_candidate ->> 'area',
                 format = 'cafe',
                 proposal_expires_at = NULL,
                 updated_at = v_now
           WHERE meetup_row.id = v_meetup_id
             AND meetup_row.status IN ('verifying', 'arranging', 'proposed');
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:confirmed:' || v_revision::text, 'system',
            'You both chose this cafe. Your meetup is confirmed.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        END IF;
      ELSIF v_action_type = 'cafe.decline' THEN
        IF v_session.status <> 'cafe_proposed'
           OR NOT EXISTS (
             SELECT 1 FROM pg_catalog.jsonb_array_elements(v_session.cafe_candidates) AS candidate
              WHERE candidate ->> 'id' = p_action ->> 'candidate_id'
           ) THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        UPDATE public.chat_meetup_private_decisions
           SET cafe_choice_id = NULL,
               private_revision = private_revision + 1,
               updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
      ELSIF v_action_type = 'replan' THEN
        IF v_session.status = 'confirmed' THEN
          IF v_session.confirmed_ends_at IS NULL OR v_session.confirmed_ends_at <= v_now THEN
            RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
            RETURN;
          END IF;
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          UPDATE public.chat_meetup_sessions
             SET status = 'cancelled', expires_at = NULL,
                 revision = chat_meetup_sessions.revision + 1, updated_at = v_now
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          UPDATE public.meetups AS old_meetup
             SET status = 'cancelled', updated_at = v_now
           WHERE old_meetup.id = v_meetup_id AND old_meetup.status = 'confirmed';
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replaced:' || v_revision::text, 'system',
            'The confirmed plan was replaced with a new planning round.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
          v_previous_meetup_id := v_meetup_id;
          v_previous_revision := v_revision;
          INSERT INTO public.meetups
            (match_id, initiator_id, status, intent_a_at, intent_b_at, created_at, updated_at)
          VALUES (v_match_id, p_user_id, 'verifying', v_now, v_now, v_now, v_now)
          RETURNING * INTO v_meetup;
          INSERT INTO public.chat_meetup_sessions
            (meetup_id, match_id, room_id, user_a_id, user_b_id, status, revision, expires_at)
          VALUES (v_meetup.id, v_match_id, p_room_id, v_a_id, v_b_id,
            'awaiting_availability', v_revision + 1, v_now + pg_catalog.interval '7 days')
          RETURNING * INTO v_session;
          v_meetup_id := v_meetup.id;
          v_revision := v_session.revision;
          UPDATE public.chat_meetup_private_decisions
             SET meetup_id = v_meetup_id, time_choice_id = NULL,
                 cafe_choice_id = NULL, completed_at = NULL,
                 private_revision = private_revision + 1, updated_at = v_now
           WHERE match_id = v_match_id;
          SELECT decision.private_revision INTO v_own_revision
            FROM public.chat_meetup_private_decisions AS decision
           WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replan:' || v_revision::text, 'system',
            'A new plan is ready. Suggest availability to choose another time.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        ELSIF v_session.status = 'expired' THEN
          UPDATE public.meetups AS old_meetup
             SET status = 'expired', intent_expires_at = NULL,
                 proposal_expires_at = NULL, updated_at = v_now
           WHERE old_meetup.id = v_meetup_id
             AND old_meetup.status IN ('verifying', 'arranging', 'proposed');
          INSERT INTO public.meetups
            (match_id, initiator_id, status, intent_a_at, intent_b_at, created_at, updated_at)
          VALUES (v_match_id, p_user_id, 'verifying', v_now, v_now, v_now, v_now)
          RETURNING * INTO v_meetup;
          INSERT INTO public.chat_meetup_sessions
            (meetup_id, match_id, room_id, user_a_id, user_b_id, status, revision, expires_at)
          VALUES (v_meetup.id, v_match_id, p_room_id, v_a_id, v_b_id,
            'awaiting_availability', v_revision + 1, v_now + pg_catalog.interval '7 days')
          RETURNING * INTO v_session;
          v_meetup_id := v_meetup.id;
          v_revision := v_session.revision;
          UPDATE public.chat_meetup_private_decisions
             SET meetup_id = v_meetup_id, time_choice_id = NULL,
                 cafe_choice_id = NULL, completed_at = NULL,
                 private_revision = private_revision + 1, updated_at = v_now
           WHERE match_id = v_match_id;
          SELECT decision.private_revision INTO v_own_revision
            FROM public.chat_meetup_private_decisions AS decision
           WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replan:' || v_revision::text, 'system',
            'A new plan is ready. Suggest availability to choose another time.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        ELSIF v_session.status IN ('time_proposed', 'awaiting_location', 'cafe_proposed', 'unavailable') THEN
          DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
          DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
          UPDATE public.chat_meetup_private_decisions
             SET time_choice_id = NULL, cafe_choice_id = NULL,
                 private_revision = private_revision + 1, updated_at = v_now
           WHERE match_id = v_match_id;
          UPDATE public.chat_meetup_sessions
             SET status = 'awaiting_availability',
                 time_candidates = '[]'::jsonb,
                 cafe_candidates = '[]'::jsonb,
                 time_choice_a = NULL, time_choice_b = NULL,
                 selected_time_candidate_id = NULL,
                 cafe_choice_a = NULL, cafe_choice_b = NULL,
                 confirmed_starts_at = NULL, confirmed_ends_at = NULL,
                 confirmed_timezone = NULL,
                 unavailable_reason = NULL,
                 expires_at = v_now + pg_catalog.interval '7 days',
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          UPDATE public.meetups AS meetup_row
             SET status = 'verifying', updated_at = v_now
           WHERE meetup_row.id = v_meetup_id
             AND meetup_row.status = 'arranging';
          SELECT decision.private_revision INTO v_own_revision
            FROM public.chat_meetup_private_decisions AS decision
           WHERE decision.match_id = v_match_id AND decision.user_id = p_user_id;
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:replan:' || v_revision::text, 'system',
            'You can suggest new availability and try again.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        ELSE
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
      ELSIF v_action_type = 'cancel' THEN
        IF v_session.status IN ('cancelled', 'expired', 'completed') THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_meetup_id;
        DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_meetup_id;
        UPDATE public.chat_meetup_sessions
           SET status = 'cancelled', expires_at = NULL,
               time_candidates = '[]'::jsonb, cafe_candidates = '[]'::jsonb,
               revision = chat_meetup_sessions.revision + 1, updated_at = v_now
         WHERE chat_meetup_sessions.meetup_id = v_meetup_id
         RETURNING * INTO v_session;
        v_revision := v_session.revision;
        UPDATE public.chat_meetup_private_decisions
           SET time_choice_id = NULL, cafe_choice_id = NULL
         WHERE match_id = v_match_id;
        UPDATE public.meetups AS meetup_row
           SET status = 'cancelled', intent_expires_at = NULL,
               proposal_expires_at = NULL, updated_at = v_now
         WHERE meetup_row.id = v_meetup_id
           AND meetup_row.status NOT IN ('completed', 'no_show', 'declined', 'expired', 'cancelled');
        INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
        VALUES (v_meetup_id, v_revision, 'state:cancelled:' || v_revision::text, 'system',
          'This meetup plan was cancelled.')
        ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
      ELSIF v_action_type = 'meeting.complete' THEN
        IF v_session.status <> 'confirmed'
           OR v_session.confirmed_ends_at IS NULL
           OR v_session.confirmed_ends_at > v_now THEN
          RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
          RETURN;
        END IF;
        UPDATE public.chat_meetup_private_decisions
           SET completed_at = COALESCE(completed_at, v_now),
               private_revision = private_revision + 1,
               updated_at = v_now
         WHERE match_id = v_match_id AND user_id = p_user_id
         RETURNING private_revision INTO v_own_revision;
        IF p_user_id = v_a_id THEN
          UPDATE public.chat_meetup_sessions AS session_row
             SET completed_a_at = COALESCE(session_row.completed_a_at, v_now)
           WHERE session_row.meetup_id = v_meetup_id;
        ELSE
          UPDATE public.chat_meetup_sessions AS session_row
             SET completed_b_at = COALESCE(session_row.completed_b_at, v_now)
           WHERE session_row.meetup_id = v_meetup_id;
        END IF;
        SELECT session_row.* INTO v_session
          FROM public.chat_meetup_sessions AS session_row
         WHERE session_row.meetup_id = v_meetup_id;
        IF v_session.completed_a_at IS NOT NULL AND v_session.completed_b_at IS NOT NULL THEN
          UPDATE public.chat_meetup_sessions
             SET status = 'completed',
                 completed_a_at = (SELECT decision.completed_at FROM public.chat_meetup_private_decisions AS decision WHERE decision.match_id = v_match_id AND decision.user_id = v_a_id),
                 completed_b_at = (SELECT decision.completed_at FROM public.chat_meetup_private_decisions AS decision WHERE decision.match_id = v_match_id AND decision.user_id = v_b_id),
                 revision = chat_meetup_sessions.revision + 1,
                 updated_at = v_now
           WHERE chat_meetup_sessions.meetup_id = v_meetup_id
           RETURNING * INTO v_session;
          v_revision := v_session.revision;
          UPDATE public.meetups AS meetup_row
             SET status = 'completed', updated_at = v_now
           WHERE meetup_row.id = v_meetup_id AND meetup_row.status = 'confirmed';
          INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
          VALUES (v_meetup_id, v_revision, 'state:completed:' || v_revision::text, 'system',
            'You both marked this meetup complete.')
          ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
        END IF;
      ELSE
        RETURN QUERY SELECT 'invalid_input'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
        RETURN;
      END IF;
    ELSE
      RETURN QUERY SELECT 'invalid_state'::text, v_meetup_id, v_session.status, v_revision, v_own_revision;
      RETURN;
    END IF;
  END IF;

  -- Record only a digest and safe outcome metadata. Replays are access-checked
  -- above and the HTTP service returns the fresh caller-scoped projection.
  INSERT INTO public.chat_meetup_operations
    (room_id, user_id, idempotency_key, meetup_id, request_digest, outcome, result_status, result_revision)
  VALUES (
    p_room_id, p_user_id, p_idempotency_key,
    CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
    p_request_digest, 'ok',
    CASE WHEN v_session_exists THEN v_session.status ELSE COALESCE(v_meetup.status, 'idle') END,
    v_revision
  );

  RETURN QUERY SELECT 'ok'::text,
    CASE WHEN v_session_exists THEN v_meetup_id ELSE NULL::uuid END,
    CASE WHEN v_session_exists THEN v_session.status ELSE NULL::text END,
    v_revision, v_own_revision;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_chat_meetup_action(uuid, uuid, integer, integer, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_chat_meetup_action(uuid, uuid, integer, integer, uuid, text, jsonb)
  TO service_role;

CREATE OR REPLACE FUNCTION public.publish_chat_meetup_times(
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_first_private_revision integer,
  p_second_private_revision integer,
  p_candidates jsonb,
  p_unavailable_reason text DEFAULT NULL
)
RETURNS TABLE (outcome text, meetup_id uuid, status text, revision integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_first_private_revision integer;
  v_second_private_revision integer;
  v_match_id uuid;
  v_a_id uuid;
  v_b_id uuid;
  v_match_status text;
  v_room_status text;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_reason text := p_unavailable_reason;
  v_now timestamptz := pg_catalog.now();
BEGIN
  SELECT room.match_id INTO v_match_id FROM public.direct_chat_rooms AS room WHERE room.id = p_room_id;
  IF NOT FOUND THEN RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN; END IF;
  SELECT m.user_a_id, m.user_b_id INTO v_a_id, v_b_id FROM public.matches AS m WHERE m.id = v_match_id;
  IF NOT FOUND OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT m.status INTO v_match_status FROM public.matches AS m WHERE m.id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_match_status <> 'direct_chat_active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT room.status INTO v_room_status FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_room_status <> 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT s.* INTO v_session FROM public.chat_meetup_sessions AS s
   WHERE s.room_id = p_room_id
   ORDER BY s.created_at DESC, s.meetup_id DESC
   LIMIT 1
   FOR UPDATE;
  IF NOT FOUND OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF v_session.revision <> p_expected_revision OR v_session.status <> 'awaiting_availability' THEN
    RETURN QUERY SELECT 'stale_revision'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF p_first_private_revision IS NULL OR p_second_private_revision IS NULL THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  SELECT decision.private_revision INTO v_first_private_revision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = v_a_id;
  SELECT decision.private_revision INTO v_second_private_revision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = v_b_id;
  IF v_first_private_revision IS DISTINCT FROM p_first_private_revision
     OR v_second_private_revision IS DISTINCT FROM p_second_private_revision
     OR NOT EXISTS (
       SELECT 1 FROM public.chat_meetup_availability AS availability
        WHERE availability.meetup_id = v_session.meetup_id
          AND availability.user_id IN (v_a_id, v_b_id)
          AND availability.expires_at > v_now
       GROUP BY availability.meetup_id
       HAVING count(*) = 2
     ) THEN
    RETURN QUERY SELECT 'stale_private_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF pg_catalog.jsonb_typeof(p_candidates) IS DISTINCT FROM 'array' THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF pg_catalog.jsonb_array_length(p_candidates) > 3
     OR (v_reason IS NOT NULL AND v_reason NOT IN ('no_shared_time', 'calendar_unavailable'))
     OR (v_reason IS NULL AND pg_catalog.jsonb_array_length(p_candidates) = 0)
     OR (v_reason IS NOT NULL AND pg_catalog.jsonb_array_length(p_candidates) > 0) THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF (
    SELECT count(*) FROM public.user_profiles AS profile
     WHERE profile.id IN (v_a_id, v_b_id)
       AND profile.identity_verification_status = 'verified'
       AND profile.identity_verified_at IS NOT NULL
  ) <> 2 THEN
    RETURN QUERY SELECT 'identity_verification_required'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  UPDATE public.chat_meetup_sessions
     SET status = CASE WHEN v_reason IS NULL THEN 'time_proposed' ELSE 'unavailable' END,
         time_candidates = p_candidates,
         cafe_candidates = '[]'::jsonb,
         selected_time_candidate_id = NULL,
         unavailable_reason = v_reason,
         revision = chat_meetup_sessions.revision + 1,
         updated_at = v_now,
         expires_at = v_now + pg_catalog.interval '7 days'
   WHERE chat_meetup_sessions.meetup_id = v_session.meetup_id
   RETURNING * INTO v_session;
  DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_session.meetup_id;
  DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_session.meetup_id;
  UPDATE public.meetups AS legacy
     SET status = 'verifying', updated_at = v_now
   WHERE legacy.id = v_session.meetup_id AND legacy.status = 'arranging';
  INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
  VALUES (v_session.meetup_id, v_session.revision, 'state:times:' || v_session.revision::text, 'system',
    CASE WHEN v_reason IS NULL
      THEN 'A few times work for both of you. Choose the same time to continue.'
      ELSE 'We could not confirm a shared time yet. You can try another availability window.'
    END)
  ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
  RETURN QUERY SELECT 'ok'::text, v_session.meetup_id, v_session.status, v_session.revision;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_chat_meetup_times(uuid, uuid, integer, integer, integer, jsonb, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_chat_meetup_times(uuid, uuid, integer, integer, integer, jsonb, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.publish_chat_meetup_cafes(
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_first_private_revision integer,
  p_second_private_revision integer,
  p_candidates jsonb,
  p_unavailable_reason text DEFAULT NULL
)
RETURNS TABLE (outcome text, meetup_id uuid, status text, revision integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_first_private_revision integer;
  v_second_private_revision integer;
  v_match_id uuid;
  v_a_id uuid;
  v_b_id uuid;
  v_match_status text;
  v_room_status text;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_time_candidate jsonb;
  v_reason text := p_unavailable_reason;
  v_expiry timestamptz;
  v_now timestamptz := pg_catalog.now();
BEGIN
  SELECT room.match_id INTO v_match_id FROM public.direct_chat_rooms AS room WHERE room.id = p_room_id;
  IF NOT FOUND THEN RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN; END IF;
  SELECT m.user_a_id, m.user_b_id INTO v_a_id, v_b_id FROM public.matches AS m WHERE m.id = v_match_id;
  IF NOT FOUND OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT m.status INTO v_match_status FROM public.matches AS m WHERE m.id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_match_status <> 'direct_chat_active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT room.status INTO v_room_status FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_room_status <> 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT s.* INTO v_session FROM public.chat_meetup_sessions AS s
   WHERE s.room_id = p_room_id
   ORDER BY s.created_at DESC, s.meetup_id DESC
   LIMIT 1
   FOR UPDATE;
  IF NOT FOUND OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF v_session.revision <> p_expected_revision OR v_session.status <> 'awaiting_location' THEN
    RETURN QUERY SELECT 'stale_revision'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF p_first_private_revision IS NULL OR p_second_private_revision IS NULL THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  SELECT decision.private_revision INTO v_first_private_revision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = v_a_id;
  SELECT decision.private_revision INTO v_second_private_revision
    FROM public.chat_meetup_private_decisions AS decision
   WHERE decision.match_id = v_match_id AND decision.user_id = v_b_id;
  IF v_first_private_revision IS DISTINCT FROM p_first_private_revision
     OR v_second_private_revision IS DISTINCT FROM p_second_private_revision
     OR NOT EXISTS (
       SELECT 1 FROM public.chat_meetup_locations AS location
        WHERE location.meetup_id = v_session.meetup_id
          AND location.user_id IN (v_a_id, v_b_id)
          AND location.expires_at > v_now
       GROUP BY location.meetup_id
       HAVING count(*) = 2
     ) THEN
    RETURN QUERY SELECT 'stale_private_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF pg_catalog.jsonb_typeof(p_candidates) IS DISTINCT FROM 'array' THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF pg_catalog.jsonb_array_length(p_candidates) > 3
     OR (v_reason IS NOT NULL AND v_reason NOT IN ('cafe_unavailable', 'no_cafe'))
     OR (v_reason IS NULL AND pg_catalog.jsonb_array_length(p_candidates) = 0)
     OR (v_reason IS NOT NULL AND pg_catalog.jsonb_array_length(p_candidates) > 0) THEN
    RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF v_reason IS NULL THEN
    SELECT candidate INTO v_time_candidate
      FROM pg_catalog.jsonb_array_elements(v_session.time_candidates) AS candidate
     WHERE candidate ->> 'id' = v_session.selected_time_candidate_id;
    IF v_time_candidate IS NULL
       OR (v_time_candidate ->> 'starts_at')::timestamptz <= v_now
       OR (v_time_candidate ->> 'ends_at')::timestamptz <= (v_time_candidate ->> 'starts_at')::timestamptz
       OR EXISTS (
         SELECT 1 FROM pg_catalog.jsonb_array_elements(p_candidates) AS candidate
          WHERE pg_catalog.jsonb_typeof(candidate) IS DISTINCT FROM 'object'
             OR NOT (candidate ?& ARRAY['id','name','address','starts_at','ends_at','travel_minutes_first','travel_minutes_second','verified_at'])
             OR candidate - ARRAY['id','name','address','area','starts_at','ends_at','travel_minutes_first','travel_minutes_second','verified_at'] <> '{}'::jsonb
             OR pg_catalog.jsonb_typeof(candidate -> 'id') IS DISTINCT FROM 'string'
             OR pg_catalog.char_length(candidate ->> 'id') NOT BETWEEN 1 AND 256
             OR pg_catalog.jsonb_typeof(candidate -> 'name') IS DISTINCT FROM 'string'
             OR pg_catalog.char_length(candidate ->> 'name') NOT BETWEEN 1 AND 120
             OR pg_catalog.jsonb_typeof(candidate -> 'address') IS DISTINCT FROM 'string'
             OR pg_catalog.char_length(candidate ->> 'address') NOT BETWEEN 1 AND 300
             OR pg_catalog.jsonb_typeof(candidate -> 'starts_at') IS DISTINCT FROM 'string'
             OR pg_catalog.jsonb_typeof(candidate -> 'ends_at') IS DISTINCT FROM 'string'
             OR pg_catalog.jsonb_typeof(candidate -> 'verified_at') IS DISTINCT FROM 'string'
             OR pg_catalog.jsonb_typeof(candidate -> 'travel_minutes_first') IS DISTINCT FROM 'number'
             OR (candidate ->> 'travel_minutes_first')::numeric < 0
             OR (candidate ->> 'travel_minutes_first')::numeric > 120
             OR pg_catalog.jsonb_typeof(candidate -> 'travel_minutes_second') IS DISTINCT FROM 'number'
             OR (candidate ->> 'travel_minutes_second')::numeric < 0
             OR (candidate ->> 'travel_minutes_second')::numeric > 120
             OR (candidate ->> 'starts_at')::timestamptz > (v_time_candidate ->> 'starts_at')::timestamptz
             OR (candidate ->> 'ends_at')::timestamptz < (v_time_candidate ->> 'ends_at')::timestamptz
             OR (candidate ->> 'ends_at')::timestamptz <= (candidate ->> 'starts_at')::timestamptz
             OR (candidate ->> 'verified_at')::timestamptz > v_now + pg_catalog.interval '5 minutes'
             OR (candidate ->> 'verified_at')::timestamptz < v_now - pg_catalog.interval '6 hours'
       )
    THEN
      RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
    END IF;
    SELECT LEAST(
             v_now + pg_catalog.interval '7 days',
             pg_catalog.min((candidate ->> 'verified_at')::timestamptz + pg_catalog.interval '6 hours')
           )
      INTO v_expiry
      FROM pg_catalog.jsonb_array_elements(p_candidates) AS candidate;
    IF v_expiry IS NULL OR v_expiry <= v_now THEN
      RETURN QUERY SELECT 'invalid_input'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
    END IF;
  ELSE
    v_expiry := v_now + pg_catalog.interval '7 days';
  END IF;
  IF (
    SELECT count(*) FROM public.user_profiles AS profile
     WHERE profile.id IN (v_a_id, v_b_id)
       AND profile.identity_verification_status = 'verified'
       AND profile.identity_verified_at IS NOT NULL
  ) <> 2 THEN
    RETURN QUERY SELECT 'identity_verification_required'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_meetup_locations AS location
     WHERE location.meetup_id = v_session.meetup_id
       AND location.user_id IN (v_a_id, v_b_id)
       AND location.expires_at > v_now
    GROUP BY location.meetup_id
    HAVING count(*) = 2
  ) THEN
    RETURN QUERY SELECT 'missing_consent'::text, v_session.meetup_id, v_session.status, v_session.revision; RETURN;
  END IF;
  UPDATE public.chat_meetup_sessions
     SET status = CASE WHEN v_reason IS NULL THEN 'cafe_proposed' ELSE 'unavailable' END,
         cafe_candidates = p_candidates,
         unavailable_reason = v_reason,
         revision = chat_meetup_sessions.revision + 1,
         updated_at = v_now,
         expires_at = v_expiry
   WHERE chat_meetup_sessions.meetup_id = v_session.meetup_id
   RETURNING * INTO v_session;
  DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_session.meetup_id;
  INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
  VALUES (v_session.meetup_id, v_session.revision, 'state:cafes:' || v_session.revision::text, 'system',
    CASE WHEN v_reason IS NULL
      THEN 'Cafe options are ready. Choose the same cafe to confirm.'
      ELSE 'We could not verify cafe options. You can try again later.'
    END)
  ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
  RETURN QUERY SELECT 'ok'::text, v_session.meetup_id, v_session.status, v_session.revision;
END;
$$;

REVOKE ALL ON FUNCTION public.publish_chat_meetup_cafes(uuid, uuid, integer, integer, integer, jsonb, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_chat_meetup_cafes(uuid, uuid, integer, integer, integer, jsonb, text)
  TO service_role;

-- Request-scoped expiry makes an elapsed plan terminal before the caller sees
-- it. The same pair/match/room/session lock order as actions is preserved.
CREATE OR REPLACE FUNCTION public.expire_chat_meetup_session(
  p_room_id uuid,
  p_user_id uuid
)
RETURNS TABLE (outcome text, meetup_id uuid, status text, revision integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_match_id uuid;
  v_a_id uuid;
  v_b_id uuid;
  v_match_status text;
  v_room_status text;
  v_session public.chat_meetup_sessions%ROWTYPE;
  v_now timestamptz := pg_catalog.now();
BEGIN
  IF p_room_id IS NULL OR p_user_id IS NULL THEN
    RETURN QUERY SELECT 'invalid_input'::text, NULL::uuid, NULL::text, 0;
    RETURN;
  END IF;
  SELECT room.match_id INTO v_match_id
    FROM public.direct_chat_rooms AS room WHERE room.id = p_room_id;
  IF NOT FOUND THEN RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN; END IF;
  SELECT match_row.user_a_id, match_row.user_b_id
    INTO v_a_id, v_b_id
    FROM public.matches AS match_row WHERE match_row.id = v_match_id;
  IF NOT FOUND OR p_user_id <> v_a_id AND p_user_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(v_a_id, v_b_id), false) THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT match_row.status INTO v_match_status
    FROM public.matches AS match_row WHERE match_row.id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_match_status <> 'direct_chat_active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT room.status INTO v_room_status
    FROM public.direct_chat_rooms AS room
   WHERE room.id = p_room_id AND room.match_id = v_match_id FOR UPDATE;
  IF NOT FOUND OR v_room_status <> 'active' THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  SELECT session_row.* INTO v_session
    FROM public.chat_meetup_sessions AS session_row
   WHERE session_row.room_id = p_room_id
   ORDER BY session_row.created_at DESC, session_row.meetup_id DESC
   LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR v_session.match_id <> v_match_id
     OR v_session.user_a_id <> v_a_id OR v_session.user_b_id <> v_b_id THEN
    RETURN QUERY SELECT 'not_found'::text, NULL::uuid, NULL::text, 0; RETURN;
  END IF;
  IF v_session.status IN ('completed', 'cancelled', 'expired')
     OR v_session.expires_at IS NULL OR v_session.expires_at > v_now THEN
    RETURN QUERY SELECT 'ok'::text, v_session.meetup_id, v_session.status, v_session.revision;
    RETURN;
  END IF;
  UPDATE public.chat_meetup_sessions
     SET status = 'expired', expires_at = NULL,
         time_candidates = '[]'::jsonb, cafe_candidates = '[]'::jsonb,
         time_choice_a = NULL, time_choice_b = NULL,
         selected_time_candidate_id = NULL, cafe_choice_a = NULL, cafe_choice_b = NULL,
         unavailable_reason = NULL,
         revision = chat_meetup_sessions.revision + 1, updated_at = v_now
   WHERE chat_meetup_sessions.meetup_id = v_session.meetup_id
   RETURNING * INTO v_session;
  DELETE FROM public.chat_meetup_availability AS availability WHERE availability.meetup_id = v_session.meetup_id;
  DELETE FROM public.chat_meetup_locations AS location WHERE location.meetup_id = v_session.meetup_id;
  UPDATE public.meetups AS legacy
     SET status = 'expired', intent_expires_at = NULL,
         proposal_expires_at = NULL, updated_at = v_now
   WHERE legacy.id = v_session.meetup_id
     AND legacy.status IN ('verifying', 'arranging', 'proposed');
  INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
  VALUES (v_session.meetup_id, v_session.revision,
          'state:expired:' || v_session.revision::text, 'system',
          'This meetup plan expired. You can start another plan.')
  ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
  RETURN QUERY SELECT 'expired'::text, v_session.meetup_id, v_session.status, v_session.revision;
END;
$$;

REVOKE ALL ON FUNCTION public.expire_chat_meetup_session(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_chat_meetup_session(uuid, uuid)
  TO service_role;

-- This bounded service-role janitor deletes expired or no-longer-needed private
-- availability/location rows; it never selects or returns their contents.
CREATE OR REPLACE FUNCTION public.prune_chat_meetup_private_inputs()
RETURNS TABLE (pruned integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted integer := 0;
  v_count integer := 0;
  v_expired_session record;
  v_session_revision integer := 0;
  v_session_input_count integer := 0;
  v_session_inputs_pruned integer := 0;
  v_added integer := 0;
  v_now timestamptz := pg_catalog.now();
BEGIN
  -- Terminalize at most 125 elapsed active plans per pass. The service-facing
  -- return value remains only the private-input row count.
  FOR v_expired_session IN
    SELECT session_row.meetup_id
      FROM public.chat_meetup_sessions AS session_row
     WHERE session_row.expires_at <= v_now
       AND session_row.status NOT IN ('completed', 'cancelled', 'expired')
     ORDER BY session_row.expires_at, session_row.meetup_id
     LIMIT 125
     FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.chat_meetup_sessions
       SET status = 'expired', expires_at = NULL,
           time_candidates = '[]'::jsonb, cafe_candidates = '[]'::jsonb,
           time_choice_a = NULL, time_choice_b = NULL,
           selected_time_candidate_id = NULL, cafe_choice_a = NULL, cafe_choice_b = NULL,
           unavailable_reason = NULL,
           revision = chat_meetup_sessions.revision + 1, updated_at = v_now
     WHERE chat_meetup_sessions.meetup_id = v_expired_session.meetup_id
     RETURNING revision INTO v_session_revision;
    UPDATE public.meetups AS legacy
       SET status = 'expired', intent_expires_at = NULL,
           proposal_expires_at = NULL, updated_at = v_now
     WHERE legacy.id = v_expired_session.meetup_id
       AND legacy.status IN ('verifying', 'arranging', 'proposed');
    DELETE FROM public.chat_meetup_availability AS availability
     WHERE availability.meetup_id = v_expired_session.meetup_id;
    GET DIAGNOSTICS v_session_input_count = ROW_COUNT;
    v_session_inputs_pruned := v_session_inputs_pruned + v_session_input_count;
    DELETE FROM public.chat_meetup_locations AS location
     WHERE location.meetup_id = v_expired_session.meetup_id;
    GET DIAGNOSTICS v_session_input_count = ROW_COUNT;
    v_session_inputs_pruned := v_session_inputs_pruned + v_session_input_count;
    INSERT INTO public.chat_meetup_events (meetup_id, revision, event_key, kind, text)
    VALUES (v_expired_session.meetup_id, v_session_revision,
            'state:expired:' || v_session_revision::text, 'system',
            'This meetup plan expired. You can start another plan.')
    ON CONFLICT ON CONSTRAINT chat_meetup_events_meetup_id_event_key_key DO NOTHING;
  END LOOP;

  v_deleted := v_session_inputs_pruned;
  IF v_deleted < 500 THEN
  WITH expired AS (
    SELECT availability.meetup_id, availability.user_id
      FROM public.chat_meetup_availability AS availability
     WHERE availability.expires_at <= v_now
        OR EXISTS (
          SELECT 1 FROM public.chat_meetup_sessions AS session_row
           WHERE session_row.meetup_id = availability.meetup_id
             AND session_row.status <> 'awaiting_availability'
        )
     ORDER BY availability.expires_at
     LIMIT (500 - v_deleted)
     FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.chat_meetup_availability AS availability
   USING expired
   WHERE availability.meetup_id = expired.meetup_id
     AND availability.user_id = expired.user_id;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  v_deleted := v_deleted + v_added;

  IF v_deleted < 500 THEN
    WITH expired AS (
      SELECT location.meetup_id, location.user_id
        FROM public.chat_meetup_locations AS location
       WHERE location.expires_at <= v_now
          OR EXISTS (
            SELECT 1 FROM public.chat_meetup_sessions AS session_row
             WHERE session_row.meetup_id = location.meetup_id
               AND session_row.status <> 'awaiting_location'
          )
       ORDER BY location.expires_at
       LIMIT (500 - v_deleted)
       FOR UPDATE SKIP LOCKED
    )
    DELETE FROM public.chat_meetup_locations AS location
     USING expired
     WHERE location.meetup_id = expired.meetup_id
       AND location.user_id = expired.user_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
  END IF;
  END IF;

  RETURN QUERY SELECT v_deleted + v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.prune_chat_meetup_private_inputs()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prune_chat_meetup_private_inputs()
  TO service_role;
