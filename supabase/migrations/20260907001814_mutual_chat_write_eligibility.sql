-- B2 additive chat-write backstops.
--
-- The three trigger functions below deliberately return no relationship or
-- profile detail. They validate the authoritative match/room relationship
-- first, then lock the current profile rows through the private foundation
-- helper. A service-role call with no JWT remains a supported synthetic/API
-- path; an authenticated database caller is bound to the actor represented by
-- the row before the private eligibility check runs.

CREATE OR REPLACE FUNCTION wingward_private.guard_chat_request_mutual_eligibility()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_match_a uuid;
  v_match_b uuid;
  v_actor_id uuid;
  v_auth_user_id uuid;
  v_enforce_actor boolean;
BEGIN
  -- Resolve the relationship without locking it. The target chat-request row
  -- is already protected by its INSERT/UPDATE statement lock; only the
  -- profile helper takes the ordered FOR SHARE locks required for eligibility.
  SELECT match_row.user_a_id, match_row.user_b_id
    INTO v_match_a, v_match_b
    FROM public.matches AS match_row
   WHERE match_row.id = NEW.match_id;

  -- A request may name the match pair in either direction, but no other pair.
  IF NOT FOUND
     OR NEW.requester_id IS NULL
     OR NEW.responder_id IS NULL
     OR NOT (
       (NEW.requester_id = v_match_a AND NEW.responder_id = v_match_b)
       OR (NEW.requester_id = v_match_b AND NEW.responder_id = v_match_a)
     ) THEN
    RAISE EXCEPTION 'chat write is not eligible'
      USING ERRCODE = 'check_violation';
  END IF;

  -- The request ownership contract is requester on INSERT and responder on
  -- UPDATE (the direct INSERT policy is intentionally absent). Bind trigger
  -- checks to those same actors when this is an authenticated database
  -- invocation. Trusted service_role/postgres paths with no JWT (and postgres
  -- RESET ROLE with a stale JWT) remain usable for synthetic fixtures and the
  -- API's service client.
  v_actor_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.requester_id ELSE OLD.responder_id END;
  v_auth_user_id := (SELECT auth.uid());
  v_enforce_actor :=
    COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated'
    OR (
      COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none'
      AND session_user = 'authenticated'
    );

  IF v_enforce_actor
     AND (
       v_auth_user_id IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM public.user_profiles AS actor_profile
         WHERE actor_profile.id = v_actor_id
           AND actor_profile.auth_user_id = v_auth_user_id
       )
     ) THEN
    RAISE EXCEPTION 'chat write is not eligible'
      USING ERRCODE = 'check_violation';
  END IF;

  IF wingward_private.lock_and_check_mutual_eligibility(v_match_a, v_match_b) THEN
    RETURN NEW;
  END IF;

  -- After revocation, only a narrow request terminal transition or terminal
  -- timestamp repair remains available. JSONB subtraction makes every other
  -- current (and future) column exact; in particular expires_at cannot move.
  IF TG_OP = 'UPDATE' THEN
    IF pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN
      RETURN NEW;
    END IF;

    IF pg_catalog.to_jsonb(NEW) - ARRAY['status', 'responded_at']::text[]
         = pg_catalog.to_jsonb(OLD) - ARRAY['status', 'responded_at']::text[]
       AND (
         (
           NEW.status = OLD.status
           AND NEW.status IN ('declined', 'expired')
         )
         OR (
           OLD.status = 'pending'
           AND NEW.status IN ('declined', 'expired')
         )
       ) THEN
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'chat write is not eligible'
    USING ERRCODE = 'check_violation';
END;
$$;

REVOKE ALL ON FUNCTION wingward_private.guard_chat_request_mutual_eligibility()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION wingward_private.guard_chat_request_mutual_eligibility() IS
  'Private chat-request INSERT/UPDATE backstop. Validates the exact match pair and actor before the ordered current-profile eligibility check, with only terminal request cleanup allowed after revocation.';

CREATE OR REPLACE FUNCTION wingward_private.guard_direct_chat_room_mutual_eligibility()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_match_a uuid;
  v_match_b uuid;
  v_actor_id uuid;
  v_auth_user_id uuid;
  v_enforce_actor boolean;
BEGIN
  -- A room is born attached to one match. Keep that lineage immutable so a
  -- revoked row cannot be laundered through an eligible replacement pair;
  -- status-only updates are the only room UPDATE API used by the server.
  IF TG_OP = 'UPDATE' AND NEW.match_id IS DISTINCT FROM OLD.match_id THEN
    RAISE EXCEPTION 'chat write is not eligible'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT match_row.user_a_id, match_row.user_b_id
    INTO v_match_a, v_match_b
    FROM public.matches AS match_row
   WHERE match_row.id = NEW.match_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat write is not eligible'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Rooms have no actor column. An authenticated caller must nevertheless be
  -- one of the authoritative match participants before private inspection.
  v_auth_user_id := (SELECT auth.uid());
  v_enforce_actor :=
    COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated'
    OR (
      COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none'
      AND session_user = 'authenticated'
    );

  IF v_enforce_actor THEN
    IF v_auth_user_id IS NULL THEN
      RAISE EXCEPTION 'chat write is not eligible'
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT profile_row.id
      INTO v_actor_id
      FROM public.user_profiles AS profile_row
     WHERE profile_row.auth_user_id = v_auth_user_id;

    IF NOT FOUND OR v_actor_id <> v_match_a AND v_actor_id <> v_match_b THEN
      RAISE EXCEPTION 'chat write is not eligible'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF wingward_private.lock_and_check_mutual_eligibility(v_match_a, v_match_b) THEN
    RETURN NEW;
  END IF;

  -- Once access is revoked, an active room may be closed and a closed room
  -- may receive an exact status-only no-op. Reopening or changing its match
  -- linkage remains ineligible. An INSERT (including status = 'closed') is
  -- always subject to the current pair check above.
  IF TG_OP = 'UPDATE' THEN
    IF pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN
      RETURN NEW;
    END IF;

    IF pg_catalog.to_jsonb(NEW) - ARRAY['status']::text[]
         = pg_catalog.to_jsonb(OLD) - ARRAY['status']::text[]
       AND (
         (OLD.status = 'active' AND NEW.status = 'closed')
         OR (OLD.status = 'closed' AND NEW.status = 'closed')
       ) THEN
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'chat write is not eligible'
    USING ERRCODE = 'check_violation';
END;
$$;

REVOKE ALL ON FUNCTION wingward_private.guard_direct_chat_room_mutual_eligibility()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION wingward_private.guard_direct_chat_room_mutual_eligibility() IS
  'Private direct-chat-room INSERT/UPDATE backstop. Validates the authoritative match and authenticated participant before the ordered current-profile eligibility check, with only close cleanup after revocation.';

CREATE OR REPLACE FUNCTION wingward_private.guard_direct_chat_message_mutual_eligibility()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_match_a uuid;
  v_match_b uuid;
  v_actor_id uuid;
  v_auth_user_id uuid;
  v_enforce_actor boolean;
BEGIN
  -- Message lineage is likewise fixed at INSERT. A room reparent would let a
  -- content/sender write switch to a different eligible pair, and would also
  -- invert the room -> profile lock order. Sender changes remain subject to
  -- the normal eligibility path below; only room_id is immutable.
  IF TG_OP = 'UPDATE' AND NEW.room_id IS DISTINCT FROM OLD.room_id THEN
    RAISE EXCEPTION 'chat write is not eligible'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Resolve room -> match without a second room lock. The existing active-room
  -- trigger runs alphabetically before this one and owns the room lock/order.
  SELECT chat_match.user_a_id, chat_match.user_b_id
    INTO v_match_a, v_match_b
    FROM public.direct_chat_rooms AS room_row
    JOIN public.matches AS chat_match ON chat_match.id = room_row.match_id
   WHERE room_row.id = NEW.room_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'chat write is not eligible'
      USING ERRCODE = 'check_violation';
  END IF;

  -- The sender column is part of the room relationship on both INSERT and
  -- UPDATE. Validate it even for trusted service-role updates; otherwise an
  -- eligible pair could still rewrite a message to name an outsider.
  IF NEW.sender_id IS NULL
     OR (NEW.sender_id <> v_match_a AND NEW.sender_id <> v_match_b) THEN
    RAISE EXCEPTION 'chat write is not eligible'
      USING ERRCODE = 'check_violation';
  END IF;

  v_auth_user_id := (SELECT auth.uid());
  v_enforce_actor :=
    COALESCE(pg_catalog.current_setting('role', true), 'none') = 'authenticated'
    OR (
      COALESCE(pg_catalog.current_setting('role', true), 'none') = 'none'
      AND session_user = 'authenticated'
    );

  IF v_enforce_actor THEN
    IF v_auth_user_id IS NULL THEN
      RAISE EXCEPTION 'chat write is not eligible'
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT profile_row.id
      INTO v_actor_id
      FROM public.user_profiles AS profile_row
     WHERE profile_row.auth_user_id = v_auth_user_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'chat write is not eligible'
        USING ERRCODE = 'check_violation';
    END IF;

    IF TG_OP = 'INSERT' THEN
      -- A new message is owned by its declared sender.
      IF v_actor_id <> NEW.sender_id THEN
        RAISE EXCEPTION 'chat write is not eligible'
          USING ERRCODE = 'check_violation';
      END IF;
    ELSIF v_actor_id <> v_match_a AND v_actor_id <> v_match_b THEN
      -- Updates include read receipts, whose actor is the recipient/member;
      -- they must not be tied to the historical sender column.
      RAISE EXCEPTION 'chat write is not eligible'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF wingward_private.lock_and_check_mutual_eligibility(v_match_a, v_match_b) THEN
    RETURN NEW;
  END IF;

  -- Only an unread -> read receipt survives preference revocation. The active
  -- room trigger remains earlier in alphabetical order, so a closed-room
  -- receipt is rejected before this exception can apply.
  IF TG_OP = 'UPDATE' THEN
    IF pg_catalog.to_jsonb(NEW) = pg_catalog.to_jsonb(OLD) THEN
      RETURN NEW;
    END IF;

    IF pg_catalog.to_jsonb(NEW) - ARRAY['is_read']::text[]
         = pg_catalog.to_jsonb(OLD) - ARRAY['is_read']::text[]
       AND OLD.is_read = false
       AND NEW.is_read = true THEN
      RETURN NEW;
    END IF;
  END IF;

  RAISE EXCEPTION 'chat write is not eligible'
    USING ERRCODE = 'check_violation';
END;
$$;

REVOKE ALL ON FUNCTION wingward_private.guard_direct_chat_message_mutual_eligibility()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION wingward_private.guard_direct_chat_message_mutual_eligibility() IS
  'Private direct-chat-message INSERT/UPDATE backstop. Uses the prior active-room lock, validates room membership/sender ownership, and permits only read-receipt cleanup after revocation.';

DROP TRIGGER IF EXISTS chat_requests_guard_mutual_eligibility
  ON public.chat_requests;
CREATE TRIGGER chat_requests_guard_mutual_eligibility
  BEFORE INSERT OR UPDATE ON public.chat_requests
  FOR EACH ROW
  EXECUTE FUNCTION wingward_private.guard_chat_request_mutual_eligibility();

DROP TRIGGER IF EXISTS direct_chat_rooms_guard_mutual_eligibility
  ON public.direct_chat_rooms;
CREATE TRIGGER direct_chat_rooms_guard_mutual_eligibility
  BEFORE INSERT OR UPDATE ON public.direct_chat_rooms
  FOR EACH ROW
  EXECUTE FUNCTION wingward_private.guard_direct_chat_room_mutual_eligibility();

-- The `z_` prefix is intentional: PostgreSQL orders same-event BEFORE
-- triggers alphabetically, so the existing active-room trigger acquires its
-- room lock before this function takes the ordered profile locks.
DROP TRIGGER IF EXISTS direct_chat_messages_z_guard_mutual_eligibility
  ON public.direct_chat_messages;
CREATE TRIGGER direct_chat_messages_z_guard_mutual_eligibility
  BEFORE INSERT OR UPDATE ON public.direct_chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION wingward_private.guard_direct_chat_message_mutual_eligibility();
