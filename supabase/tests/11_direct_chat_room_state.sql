-- Covers supabase/migrations/20260830130037_direct_chat_active_room_send_guard.sql.
--
-- The API's active-only lookup is an early, indistinguishable response.  The
-- trigger below is the database invariant that protects INSERT and UPDATE when a
-- room is closed after that lookup.  These assertions run through the direct
-- database write path (the same service_role path used by the API), so an
-- application-only guard cannot make the rejection tests pass.
--
-- The active INSERT is intentionally first: a trigger or constraint that
-- rejects every message would otherwise produce a false-positive rejection
-- result.  The catalog checks are tripwires for the function/trigger wiring,
-- the row lock, and the existing blocked-pair/policy boundary.

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-000000001101', 'wingward-test-1101@example.invalid'),
  ('00000000-0000-0000-0000-000000001102', 'wingward-test-1102@example.invalid'),
  ('00000000-0000-0000-0000-000000001103', 'wingward-test-1103@example.invalid');

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001101',
    nickname = 'Test 1101',
    birth_date = '1990-01-01',
    age_verified_at = '2026-08-24T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001101';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001102',
    nickname = 'Test 1102',
    birth_date = '1990-01-01',
    age_verified_at = '2026-08-24T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001102';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000001103',
    nickname = 'Test 1103',
    birth_date = '1990-01-01',
    age_verified_at = '2026-08-24T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE auth_user_id = '00000000-0000-0000-0000-000000001103';

INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES
  (
    '20000000-0000-0000-0000-000000001101',
    '10000000-0000-0000-0000-000000001101',
    '10000000-0000-0000-0000-000000001102'
  ),
  (
    '20000000-0000-0000-0000-000000001102',
    '10000000-0000-0000-0000-000000001101',
    '10000000-0000-0000-0000-000000001103'
  ),
  (
    '20000000-0000-0000-0000-000000001103',
    '10000000-0000-0000-0000-000000001102',
    '10000000-0000-0000-0000-000000001103'
  );

INSERT INTO public.direct_chat_rooms (id, match_id, status)
VALUES
  (
    '40000000-0000-0000-0000-000000001101',
    '20000000-0000-0000-0000-000000001101',
    'active'
  ),
  (
    '40000000-0000-0000-0000-000000001102',
    '20000000-0000-0000-0000-000000001102',
    'active'
  ),
  (
    '40000000-0000-0000-0000-000000001103',
    '20000000-0000-0000-0000-000000001103',
    'active'
  );

-- Seed history while both rooms are active. The rows must become invisible
-- through RLS after one room closes and the other pair becomes blocked.
INSERT INTO public.direct_chat_messages (id, room_id, sender_id, content)
VALUES
  (
    '50000000-0000-0000-0000-000000001104',
    '40000000-0000-0000-0000-000000001102',
    '10000000-0000-0000-0000-000000001101',
    'history before close'
  ),
  (
    '50000000-0000-0000-0000-000000001105',
    '40000000-0000-0000-0000-000000001103',
    '10000000-0000-0000-0000-000000001102',
    'history before block'
  );

UPDATE public.direct_chat_rooms
SET status = 'closed'
WHERE id = '40000000-0000-0000-0000-000000001102';

DO $$
DECLARE
  active_room_trigger_count integer;
  blocked_pair_trigger_count integer;
  active_room_function_definition text;
  active_room_trigger_definition text;
  direct_insert_policy_count integer;
  room_read_policy_count integer;
  message_read_policy_count integer;
BEGIN
  SELECT count(*)
  INTO active_room_trigger_count
  FROM pg_trigger AS t
  JOIN pg_class AS c ON c.oid = t.tgrelid
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  JOIN pg_proc AS p ON p.oid = t.tgfoid
  WHERE n.nspname = 'public'
    AND c.relname = 'direct_chat_messages'
    AND t.tgname = 'direct_chat_messages_reject_non_active_room'
    AND p.oid = 'public.reject_non_active_direct_chat_room()'::regprocedure
    AND NOT t.tgisinternal
    AND t.tgenabled = 'O';
  IF active_room_trigger_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 11a: active-room write trigger is not wired and enabled';
  END IF;

  SELECT pg_get_triggerdef(t.oid)
  INTO active_room_trigger_definition
  FROM pg_trigger AS t
  JOIN pg_class AS c ON c.oid = t.tgrelid
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'direct_chat_messages'
    AND t.tgname = 'direct_chat_messages_reject_non_active_room'
    AND NOT t.tgisinternal;
  IF active_room_trigger_definition NOT LIKE '%BEFORE INSERT OR UPDATE%' THEN
    RAISE EXCEPTION 'FAIL 11a: active-room trigger does not protect INSERT and UPDATE';
  END IF;

  SELECT count(*)
  INTO blocked_pair_trigger_count
  FROM pg_trigger AS t
  JOIN pg_class AS c ON c.oid = t.tgrelid
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  JOIN pg_proc AS p ON p.oid = t.tgfoid
  WHERE n.nspname = 'public'
    AND c.relname = 'direct_chat_messages'
    AND t.tgname = 'direct_chat_messages_reject_blocked_pair'
    AND p.oid = 'public.reject_blocked_pair_by_room()'::regprocedure
    AND NOT t.tgisinternal
    AND t.tgenabled = 'O';
  IF blocked_pair_trigger_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 11b: existing blocked-pair message trigger is missing';
  END IF;

  SELECT pg_get_functiondef('public.reject_non_active_direct_chat_room()'::regprocedure)
  INTO active_room_function_definition;
  IF active_room_function_definition NOT LIKE '%FOR UPDATE%' THEN
    RAISE EXCEPTION 'FAIL 11c: active-room guard does not lock the room row';
  END IF;
  IF active_room_function_definition NOT LIKE '%status IS DISTINCT FROM ''active''%' THEN
    RAISE EXCEPTION 'FAIL 11d: active-room guard does not reject non-active status';
  END IF;

  SELECT count(*)
  INTO direct_insert_policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'direct_chat_messages'
    AND policyname = 'direct_chat_messages_insert';
  IF direct_insert_policy_count <> 0 THEN
    RAISE EXCEPTION 'FAIL 11e: direct_chat_messages INSERT policy was restored';
  END IF;

  SELECT count(*) INTO room_read_policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'direct_chat_rooms'
    AND policyname = 'direct_chat_rooms_select'
    AND qual LIKE '%can_read_active_direct_chat_room(id)%';
  IF room_read_policy_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 11e: direct_chat_rooms SELECT policy lacks the active/unblocked guard';
  END IF;

  SELECT count(*) INTO message_read_policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'direct_chat_messages'
    AND policyname = 'direct_chat_messages_select'
    AND qual LIKE '%can_read_active_direct_chat_room(room_id)%';
  IF message_read_policy_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 11e: direct_chat_messages SELECT policy lacks the active/unblocked guard';
  END IF;

  IF has_function_privilege('anon', 'public.reject_non_active_direct_chat_room()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 11f: anon can execute the active-room SECURITY DEFINER helper';
  END IF;
  IF has_function_privilege('authenticated', 'public.reject_non_active_direct_chat_room()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 11g: authenticated can execute the active-room SECURITY DEFINER helper';
  END IF;

  IF has_function_privilege('anon', 'public.can_read_active_direct_chat_room(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 11g: anon can call the direct-chat read authorization helper';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.can_read_active_direct_chat_room(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL 11g: authenticated cannot evaluate direct-chat read RLS';
  END IF;

  RAISE NOTICE 'PASS 11a-g: active-room trigger, lock/status guard, blocked-pair trigger, policies, and function grants are wired';
END $$;

-- Positive control: an active room remains writable through the service_role
-- path used by the API.
INSERT INTO public.direct_chat_messages (
  id, room_id, sender_id, content
)
VALUES (
  '50000000-0000-0000-0000-000000001101',
  '40000000-0000-0000-0000-000000001101',
  '10000000-0000-0000-0000-000000001101',
  'active message'
);

DO $$
DECLARE
  message_count integer;
BEGIN
  SELECT count(*) INTO message_count
  FROM public.direct_chat_messages
  WHERE id = '50000000-0000-0000-0000-000000001101';
  IF message_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 11h: active direct-chat room did not accept a message';
  END IF;
  RAISE NOTICE 'PASS 11h: active direct-chat room accepts a message';
END $$;

-- Positive RLS control: a verified participant can read an active, unblocked
-- room and its messages directly through the authenticated/PostgREST role.
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000001102"}';

DO $$
DECLARE
  visible_rooms integer;
  visible_messages integer;
BEGIN
  SELECT count(*) INTO visible_rooms
  FROM public.direct_chat_rooms
  WHERE id = '40000000-0000-0000-0000-000000001101';

  SELECT count(*) INTO visible_messages
  FROM public.direct_chat_messages
  WHERE room_id = '40000000-0000-0000-0000-000000001101';

  IF visible_rooms <> 1 OR visible_messages <> 1 THEN
    RAISE EXCEPTION 'FAIL 11o: active unblocked room/messages hidden by RLS (%/%)', visible_rooms, visible_messages;
  END IF;
  RAISE NOTICE 'PASS 11o: active unblocked room/messages remain readable through authenticated RLS';
END $$;

RESET role;
RESET request.jwt.claims;

-- Negative control: a room that is already closed cannot accept a message.
DO $$
BEGIN
  INSERT INTO public.direct_chat_messages (
    id, room_id, sender_id, content
  )
  VALUES (
    '50000000-0000-0000-0000-000000001102',
    '40000000-0000-0000-0000-000000001102',
    '10000000-0000-0000-0000-000000001101',
    'closed message'
  );
  RAISE EXCEPTION 'FAIL 11i: closed direct-chat room accepted a message';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'PASS 11i: closed direct-chat room rejects a message';
END $$;

DO $$
DECLARE
  message_count integer;
BEGIN
  SELECT count(*) INTO message_count
  FROM public.direct_chat_messages
  WHERE id = '50000000-0000-0000-0000-000000001102';
  IF message_count <> 0 THEN
    RAISE EXCEPTION 'FAIL 11j: rejected closed-room message was persisted';
  END IF;
  RAISE NOTICE 'PASS 11j: closed-room rejection leaves no message row';
END $$;

-- State-transition check: once an active room is closed, the same invariant
-- applies to subsequent writes.  The existing message remains as history.
UPDATE public.direct_chat_rooms
SET status = 'closed'
WHERE id = '40000000-0000-0000-0000-000000001101';

DO $$
BEGIN
  INSERT INTO public.direct_chat_messages (
    id, room_id, sender_id, content
  )
  VALUES (
    '50000000-0000-0000-0000-000000001103',
    '40000000-0000-0000-0000-000000001101',
    '10000000-0000-0000-0000-000000001102',
    'after close'
  );
  RAISE EXCEPTION 'FAIL 11k: a message was accepted after the room transitioned to closed';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'PASS 11k: room close transition rejects subsequent messages';
END $$;

DO $$
DECLARE
  message_count integer;
BEGIN
  SELECT count(*) INTO message_count
  FROM public.direct_chat_messages
  WHERE room_id = '40000000-0000-0000-0000-000000001101';
  IF message_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 11l: room close transition changed existing message history';
  END IF;
  RAISE NOTICE 'PASS 11l: room close transition leaves prior message history intact';
END $$;

-- A read receipt is also a message-row write and must not be accepted after
-- the room closes.
DO $$
BEGIN
  UPDATE public.direct_chat_messages
  SET is_read = true
  WHERE id = '50000000-0000-0000-0000-000000001101';
  RAISE EXCEPTION 'FAIL 11m: closed direct-chat room accepted a read-receipt update';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'PASS 11m: closed direct-chat room rejects read-receipt updates';
END $$;

DO $$
DECLARE
  read_state boolean;
BEGIN
  SELECT is_read INTO read_state
  FROM public.direct_chat_messages
  WHERE id = '50000000-0000-0000-0000-000000001101';
  IF read_state IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL 11n: rejected read-receipt update changed message state';
  END IF;
  RAISE NOTICE 'PASS 11n: rejected read-receipt update leaves message state unchanged';
END $$;

-- Closed-room history must not be reachable by a participant through direct
-- PostgREST/Realtime SELECTs, even though the historical row is retained.
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000001103"}';

DO $$
DECLARE
  visible_rooms integer;
  visible_messages integer;
BEGIN
  SELECT count(*) INTO visible_rooms
  FROM public.direct_chat_rooms
  WHERE id = '40000000-0000-0000-0000-000000001102';

  SELECT count(*) INTO visible_messages
  FROM public.direct_chat_messages
  WHERE room_id = '40000000-0000-0000-0000-000000001102';

  IF visible_rooms <> 0 OR visible_messages <> 0 THEN
    RAISE EXCEPTION 'FAIL 11p: authenticated participant read closed-room history (%/%)', visible_rooms, visible_messages;
  END IF;
  RAISE NOTICE 'PASS 11p: authenticated participant cannot read closed-room history';
END $$;

RESET role;
RESET request.jwt.claims;

-- Keep the room active to prove that a block alone revokes both the room and
-- its retained history. Test as the blockee, who cannot see the blocker's row
-- through `blocks_select`; the SECURITY DEFINER helper must still find it.
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES (
  '10000000-0000-0000-0000-000000001102',
  '10000000-0000-0000-0000-000000001103'
);

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000001103"}';

DO $$
DECLARE
  visible_rooms integer;
  visible_messages integer;
BEGIN
  SELECT count(*) INTO visible_rooms
  FROM public.direct_chat_rooms
  WHERE id = '40000000-0000-0000-0000-000000001103';

  SELECT count(*) INTO visible_messages
  FROM public.direct_chat_messages
  WHERE room_id = '40000000-0000-0000-0000-000000001103';

  IF visible_rooms <> 0 OR visible_messages <> 0 THEN
    RAISE EXCEPTION 'FAIL 11q: blocked participant read active-room history (%/%)', visible_rooms, visible_messages;
  END IF;
  RAISE NOTICE 'PASS 11q: blocked participant cannot read active-room history';
END $$;

RESET role;
RESET request.jwt.claims;

ROLLBACK;
