-- Execute only against the approved local synthetic database.
-- Runtime evidence: docs/evidence/b2-chat-write-guards.md.
--
-- B2 SQL chat-write backstop assertions. Everything is synthetic and rolled
-- back; no production rows or credentials are used.

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-000000001901', 'wingward-b2-1901@example.invalid'),
  ('00000000-0000-0000-0000-000000001902', 'wingward-b2-1902@example.invalid'),
  ('00000000-0000-0000-0000-000000001903', 'wingward-b2-1903@example.invalid'),
  ('00000000-0000-0000-0000-000000001904', 'wingward-b2-1904@example.invalid'),
  ('00000000-0000-0000-0000-000000001905', 'wingward-b2-1905@example.invalid'),
  ('00000000-0000-0000-0000-000000001906', 'wingward-b2-1906@example.invalid'),
  ('00000000-0000-0000-0000-000000001907', 'wingward-b2-1907@example.invalid'),
  ('00000000-0000-0000-0000-000000001908', 'wingward-b2-1908@example.invalid'),
  ('00000000-0000-0000-0000-000000001909', 'wingward-b2-1909@example.invalid'),
  ('00000000-0000-0000-0000-000000001910', 'wingward-b2-1910@example.invalid'),
  ('00000000-0000-0000-0000-000000001911', 'wingward-b2-1911@example.invalid'),
  ('00000000-0000-0000-0000-000000001912', 'wingward-b2-1912@example.invalid');

-- Signup creates the profile row. These updates give every synthetic pair the
-- complete current settings required by the foundation match trigger before
-- any chat rows are inserted.
WITH fixtures(auth_user_id, profile_id, nickname, gender_identity, preferred_genders) AS (
  VALUES
    ('00000000-0000-0000-0000-000000001901'::uuid, '10000000-0000-0000-0000-000000001901'::uuid, 'B2 chat woman 1', 'woman', ARRAY['woman']::text[]),
    ('00000000-0000-0000-0000-000000001902'::uuid, '10000000-0000-0000-0000-000000001902'::uuid, 'B2 chat woman 2', 'woman', ARRAY['woman']::text[]),
    ('00000000-0000-0000-0000-000000001903'::uuid, '10000000-0000-0000-0000-000000001903'::uuid, 'B2 chat nonbinary 1', 'nonbinary', ARRAY['nonbinary']::text[]),
    ('00000000-0000-0000-0000-000000001904'::uuid, '10000000-0000-0000-0000-000000001904'::uuid, 'B2 chat nonbinary 2', 'nonbinary', ARRAY['nonbinary']::text[]),
    ('00000000-0000-0000-0000-000000001905'::uuid, '10000000-0000-0000-0000-000000001905'::uuid, 'B2 chat woman 3', 'woman', ARRAY['woman']::text[]),
    ('00000000-0000-0000-0000-000000001906'::uuid, '10000000-0000-0000-0000-000000001906'::uuid, 'B2 chat woman 4', 'woman', ARRAY['woman']::text[]),
    ('00000000-0000-0000-0000-000000001907'::uuid, '10000000-0000-0000-0000-000000001907'::uuid, 'B2 chat man 1', 'man', ARRAY['man']::text[]),
    ('00000000-0000-0000-0000-000000001908'::uuid, '10000000-0000-0000-0000-000000001908'::uuid, 'B2 chat man 2', 'man', ARRAY['man']::text[]),
    ('00000000-0000-0000-0000-000000001909'::uuid, '10000000-0000-0000-0000-000000001909'::uuid, 'B2 chat extra woman', 'woman', ARRAY['woman']::text[]),
    ('00000000-0000-0000-0000-000000001910'::uuid, '10000000-0000-0000-0000-000000001910'::uuid, 'B2 chat extra woman', 'woman', ARRAY['woman']::text[]),
    ('00000000-0000-0000-0000-000000001911'::uuid, '10000000-0000-0000-0000-000000001911'::uuid, 'B2 chat room woman 1', 'woman', ARRAY['woman']::text[]),
    ('00000000-0000-0000-0000-000000001912'::uuid, '10000000-0000-0000-0000-000000001912'::uuid, 'B2 chat room woman 2', 'woman', ARRAY['woman']::text[])
)
UPDATE public.user_profiles AS profile_row
SET id = fixture.profile_id,
    nickname = fixture.nickname,
    birth_date = DATE '1990-01-01',
    age_verified_at = '2026-09-07T00:00:00Z',
    age_verification_method = 'self_declared',
    gender_identity = fixture.gender_identity,
    preferred_genders = fixture.preferred_genders,
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-09-07T00:00:00Z'
FROM fixtures AS fixture
WHERE profile_row.auth_user_id = fixture.auth_user_id;

INSERT INTO public.matches (id, user_a_id, user_b_id, status)
VALUES
  ('20000000-0000-0000-0000-000000001901', '10000000-0000-0000-0000-000000001901', '10000000-0000-0000-0000-000000001902', 'direct_chat_active'),
  ('20000000-0000-0000-0000-000000001902', '10000000-0000-0000-0000-000000001903', '10000000-0000-0000-0000-000000001904', 'direct_chat_active'),
  ('20000000-0000-0000-0000-000000001903', '10000000-0000-0000-0000-000000001905', '10000000-0000-0000-0000-000000001906', 'direct_chat_active'),
  ('20000000-0000-0000-0000-000000001904', '10000000-0000-0000-0000-000000001907', '10000000-0000-0000-0000-000000001908', 'direct_chat_active'),
  ('20000000-0000-0000-0000-000000001905', '10000000-0000-0000-0000-000000001911', '10000000-0000-0000-0000-000000001912', 'direct_chat_active'),
  ('20000000-0000-0000-0000-000000001906', '10000000-0000-0000-0000-000000001909', '10000000-0000-0000-0000-000000001910', 'direct_chat_active'),
  ('20000000-0000-0000-0000-000000001907', '10000000-0000-0000-0000-000000001901', '10000000-0000-0000-0000-000000001909', 'direct_chat_active');

INSERT INTO public.direct_chat_rooms (id, match_id, status)
VALUES
  ('40000000-0000-0000-0000-000000001901', '20000000-0000-0000-0000-000000001901', 'active'),
  ('40000000-0000-0000-0000-000000001902', '20000000-0000-0000-0000-000000001902', 'active'),
  ('40000000-0000-0000-0000-000000001903', '20000000-0000-0000-0000-000000001903', 'active'),
  ('40000000-0000-0000-0000-000000001904', '20000000-0000-0000-0000-000000001904', 'active'),
  ('40000000-0000-0000-0000-000000001907', '20000000-0000-0000-0000-000000001907', 'active');

-- Requester/responder is deliberately reversed for the first request. The
-- room/match and message fixtures are created while all pairs are eligible so
-- the foundation trigger cannot mask the chat-specific assertions below.
INSERT INTO public.chat_requests
  (id, match_id, requester_id, responder_id, status, expires_at)
VALUES
  ('30000000-0000-0000-0000-000000001901', '20000000-0000-0000-0000-000000001901', '10000000-0000-0000-0000-000000001902', '10000000-0000-0000-0000-000000001901', 'pending', '2026-09-14T00:00:00Z'),
  ('30000000-0000-0000-0000-000000001902', '20000000-0000-0000-0000-000000001902', '10000000-0000-0000-0000-000000001903', '10000000-0000-0000-0000-000000001904', 'pending', '2026-09-14T00:00:00Z'),
  ('30000000-0000-0000-0000-000000001903', '20000000-0000-0000-0000-000000001903', '10000000-0000-0000-0000-000000001905', '10000000-0000-0000-0000-000000001906', 'pending', '2026-09-14T00:00:00Z'),
  ('30000000-0000-0000-0000-000000001904', '20000000-0000-0000-0000-000000001904', '10000000-0000-0000-0000-000000001907', '10000000-0000-0000-0000-000000001908', 'accepted', '2026-09-14T00:00:00Z');

UPDATE public.chat_requests
SET responded_at = '2026-09-06T23:00:00Z'
WHERE id = '30000000-0000-0000-0000-000000001904';

INSERT INTO public.direct_chat_messages
  (id, room_id, sender_id, content, is_read, created_at)
VALUES
  ('50000000-0000-0000-0000-000000001901', '40000000-0000-0000-0000-000000001901', '10000000-0000-0000-0000-000000001901', 'seed unread woman message', false, '2026-09-07T00:01:00Z'),
  ('50000000-0000-0000-0000-000000001902', '40000000-0000-0000-0000-000000001902', '10000000-0000-0000-0000-000000001903', 'seed unread nonbinary message', false, '2026-09-07T00:02:00Z'),
  ('50000000-0000-0000-0000-000000001903', '40000000-0000-0000-0000-000000001903', '10000000-0000-0000-0000-000000001905', 'seed unread second message', false, '2026-09-07T00:03:00Z');

DO $$
DECLARE
  v_name text;
  v_oid oid;
  v_definition text;
  v_is_definer boolean;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'wingward_private.guard_chat_request_mutual_eligibility()',
    'wingward_private.guard_direct_chat_room_mutual_eligibility()',
    'wingward_private.guard_direct_chat_message_mutual_eligibility()'
  ] LOOP
    v_oid := v_name::regprocedure;
    SELECT p.prosecdef, pg_get_functiondef(p.oid)
      INTO v_is_definer, v_definition
      FROM pg_proc AS p
     WHERE p.oid = v_oid;

    IF NOT FOUND OR NOT v_is_definer THEN
      RAISE EXCEPTION 'FAIL 19a: % is not a SECURITY DEFINER function', v_name;
    END IF;
    IF NOT COALESCE((SELECT 'search_path=""' = ANY(p.proconfig)
                       FROM pg_proc AS p WHERE p.oid = v_oid), false) THEN
      RAISE EXCEPTION 'FAIL 19b: % does not fix an empty search_path', v_name;
    END IF;
    IF v_definition NOT LIKE $pattern$%chat write is not eligible%$pattern$ THEN
      RAISE EXCEPTION 'FAIL 19c: % does not use the fixed generic error', v_name;
    END IF;
    IF EXISTS (
         SELECT 1
         FROM aclexplode(COALESCE(
           (SELECT p.proacl FROM pg_proc AS p WHERE p.oid = v_oid),
           acldefault('f', (SELECT p.proowner FROM pg_proc AS p WHERE p.oid = v_oid))
         )) AS privilege
         WHERE privilege.grantee = 0
           AND privilege.privilege_type = 'EXECUTE'
       )
       OR has_function_privilege('anon', v_oid, 'EXECUTE')
       OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL 19d: % has a direct API-role EXECUTE grant', v_name;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger AS trigger_row
    JOIN pg_class AS table_row ON table_row.oid = trigger_row.tgrelid
    JOIN pg_namespace AS table_schema ON table_schema.oid = table_row.relnamespace
    JOIN pg_proc AS function_row ON function_row.oid = trigger_row.tgfoid
    JOIN pg_namespace AS function_schema ON function_schema.oid = function_row.pronamespace
    WHERE table_schema.nspname = 'public'
      AND table_row.relname = 'chat_requests'
      AND trigger_row.tgname = 'chat_requests_guard_mutual_eligibility'
      AND function_schema.nspname = 'wingward_private'
      AND function_row.proname = 'guard_chat_request_mutual_eligibility'
      AND pg_get_triggerdef(trigger_row.oid) LIKE $pattern$%BEFORE INSERT OR UPDATE%$pattern$
      AND trigger_row.tgenabled = 'O'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL 19e: chat-request trigger is not wired for INSERT and UPDATE';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger AS trigger_row
    JOIN pg_class AS table_row ON table_row.oid = trigger_row.tgrelid
    JOIN pg_namespace AS table_schema ON table_schema.oid = table_row.relnamespace
    JOIN pg_proc AS function_row ON function_row.oid = trigger_row.tgfoid
    JOIN pg_namespace AS function_schema ON function_schema.oid = function_row.pronamespace
    WHERE table_schema.nspname = 'public'
      AND table_row.relname = 'direct_chat_rooms'
      AND trigger_row.tgname = 'direct_chat_rooms_guard_mutual_eligibility'
      AND function_schema.nspname = 'wingward_private'
      AND function_row.proname = 'guard_direct_chat_room_mutual_eligibility'
      AND pg_get_triggerdef(trigger_row.oid) LIKE $pattern$%BEFORE INSERT OR UPDATE%$pattern$
      AND trigger_row.tgenabled = 'O'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL 19f: room trigger is not wired for INSERT and UPDATE';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger AS trigger_row
    JOIN pg_class AS table_row ON table_row.oid = trigger_row.tgrelid
    JOIN pg_namespace AS table_schema ON table_schema.oid = table_row.relnamespace
    JOIN pg_proc AS function_row ON function_row.oid = trigger_row.tgfoid
    JOIN pg_namespace AS function_schema ON function_schema.oid = function_row.pronamespace
    WHERE table_schema.nspname = 'public'
      AND table_row.relname = 'direct_chat_messages'
      AND trigger_row.tgname = 'direct_chat_messages_z_guard_mutual_eligibility'
      AND function_schema.nspname = 'wingward_private'
      AND function_row.proname = 'guard_direct_chat_message_mutual_eligibility'
      AND pg_get_triggerdef(trigger_row.oid) LIKE $pattern$%BEFORE INSERT OR UPDATE%$pattern$
      AND trigger_row.tgenabled = 'O'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL 19g: message trigger is not wired for INSERT and UPDATE';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger AS active_trigger
    JOIN pg_class AS table_row ON table_row.oid = active_trigger.tgrelid
    WHERE table_row.relname = 'direct_chat_messages'
      AND active_trigger.tgname = 'direct_chat_messages_reject_non_active_room'
      AND active_trigger.tgenabled = 'O'
      AND NOT active_trigger.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL 19h: existing active-room trigger was removed';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger AS active_trigger
    JOIN pg_trigger AS guard_trigger ON guard_trigger.tgrelid = active_trigger.tgrelid
    JOIN pg_class AS table_row ON table_row.oid = active_trigger.tgrelid
    WHERE table_row.relname = 'direct_chat_messages'
      AND active_trigger.tgname = 'direct_chat_messages_reject_non_active_room'
      AND guard_trigger.tgname = 'direct_chat_messages_z_guard_mutual_eligibility'
      AND guard_trigger.tgname > active_trigger.tgname
  ) THEN
    RAISE EXCEPTION 'FAIL 19i: message eligibility trigger does not run after the room lock trigger';
  END IF;

  RAISE NOTICE 'PASS 19a-i: three private fixed-search_path helpers, ACLs, INSERT/UPDATE wiring, preserved active-room guard, and trigger order';
END $$;

DO $$
DECLARE
  v_match_count integer;
  v_request_count integer;
BEGIN
  SELECT count(*) INTO v_match_count
  FROM public.matches
  WHERE id IN (
    '20000000-0000-0000-0000-000000001901',
    '20000000-0000-0000-0000-000000001902'
  );
  SELECT count(*) INTO v_request_count
  FROM public.chat_requests
  WHERE id = '30000000-0000-0000-0000-000000001901'
    AND requester_id = '10000000-0000-0000-0000-000000001902'
    AND responder_id = '10000000-0000-0000-0000-000000001901';

  IF v_match_count <> 2 OR v_request_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 19j: eligible same-gender/nonbinary or reversed request fixtures were not accepted';
  END IF;
  RAISE NOTICE 'PASS 19j: same-gender and nonbinary pairs, plus reversed request participants, passed the foundation and chat guards';
END $$;

-- Reparenting is rejected while both old and replacement pairs are eligible.
-- This is the lineage invariant: room_id/match_id are assigned once at INSERT.
DO $$
BEGIN
  UPDATE public.direct_chat_rooms
  SET match_id = '20000000-0000-0000-0000-000000001906'
  WHERE id = '40000000-0000-0000-0000-000000001901';
  RAISE EXCEPTION 'FAIL 19k: eligible room reparent was accepted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19k: eligible room reparent failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19k: room match linkage is immutable even while both pairs are eligible';
END $$;

DO $$
BEGIN
  UPDATE public.direct_chat_messages
  SET room_id = '40000000-0000-0000-0000-000000001907'
  WHERE id = '50000000-0000-0000-0000-000000001901';
  RAISE EXCEPTION 'FAIL 19l: eligible message reparent was accepted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19l: eligible message reparent failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19l: message room linkage is immutable even while both pairs are eligible';
END $$;

-- Revoke only the matching preference settings. Each pair remains a valid
-- foreign-key relationship, but the foundation helper now returns false.
UPDATE public.user_profiles
SET preference_mode = 'no_answer',
    preferred_genders = ARRAY[]::text[]
WHERE id IN (
  '10000000-0000-0000-0000-000000001902',
  '10000000-0000-0000-0000-000000001904',
  '10000000-0000-0000-0000-000000001906',
  '10000000-0000-0000-0000-000000001908',
  '10000000-0000-0000-0000-000000001912'
);

-- A new request, even one declared terminal, cannot be created after
-- preference revocation.
DO $$
BEGIN
  INSERT INTO public.chat_requests
    (id, match_id, requester_id, responder_id, status, expires_at)
  VALUES
    ('30000000-0000-0000-0000-000000001905',
     '20000000-0000-0000-0000-000000001905',
     '10000000-0000-0000-0000-000000001911',
     '10000000-0000-0000-0000-000000001912',
     'declined',
     '2026-09-14T00:00:00Z');
  RAISE EXCEPTION 'FAIL 19m: revoked pair accepted a new chat request';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19m: revoked request INSERT failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19m: revoked pair cannot INSERT a request';
END $$;

-- Acceptance is a forward state transition and must fail after revocation.
DO $$
BEGIN
  UPDATE public.chat_requests
  SET status = 'accepted', responded_at = '2026-09-07T01:00:00Z'
  WHERE id = '30000000-0000-0000-0000-000000001901';
  RAISE EXCEPTION 'FAIL 19n: revoked request accepted a forward acceptance';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19n: request acceptance failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19n: revoked request cannot advance to accepted';
END $$;

-- Terminal request cleanup is bounded to status/responded_at. The first row
-- demonstrates pending -> declined; the second update demonstrates a terminal
-- responded_at repair and the third is an exact no-op.
UPDATE public.chat_requests
SET status = 'declined', responded_at = '2026-09-07T01:01:00Z'
WHERE id = '30000000-0000-0000-0000-000000001901';

UPDATE public.chat_requests
SET responded_at = '2026-09-07T01:02:00Z'
WHERE id = '30000000-0000-0000-0000-000000001901';

UPDATE public.chat_requests
SET status = 'declined'
WHERE id = '30000000-0000-0000-0000-000000001901';

DO $$
BEGIN
  UPDATE public.chat_requests
  SET status = 'expired',
      expires_at = expires_at + INTERVAL '1 hour'
  WHERE id = '30000000-0000-0000-0000-000000001902';
  RAISE EXCEPTION 'FAIL 19o: terminal request update hid an expires_at change';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19o: expires_at tamper failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19o: revoked request cannot change expires_at with terminal status';
END $$;

UPDATE public.chat_requests
SET status = 'expired', responded_at = '2026-09-07T01:03:00Z'
WHERE id = '30000000-0000-0000-0000-000000001902';

DO $$
BEGIN
  UPDATE public.chat_requests
  SET status = 'declined', expires_at = expires_at + INTERVAL '1 hour'
  WHERE id = '30000000-0000-0000-0000-000000001903';
  RAISE EXCEPTION 'FAIL 19p: mixed terminal request/content update was accepted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19p: mixed request update failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19p: request terminal status cannot hide a forbidden expires_at edit';
END $$;

DO $$
BEGIN
  UPDATE public.chat_requests
  SET status = 'pending'
  WHERE id = '30000000-0000-0000-0000-000000001904';
  RAISE EXCEPTION 'FAIL 19q: revoked accepted request rolled back to pending';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19q: accepted-to-pending compensation failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19q: revoked accepted request cannot roll back to pending';
END $$;

-- The service-role path remains valid with a stale JWT: the invoker role is
-- trusted, so auth.uid() is not treated as a forged authenticated actor.
SET LOCAL role = 'service_role';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000001910"}';
INSERT INTO public.chat_requests
  (id, match_id, requester_id, responder_id, status, expires_at)
VALUES
  ('30000000-0000-0000-0000-000000001906',
   '20000000-0000-0000-0000-000000001906',
   '10000000-0000-0000-0000-000000001909',
   '10000000-0000-0000-0000-000000001910',
   'pending',
   '2026-09-14T00:00:00Z');
RESET role;
RESET request.jwt.claims;

DO $$
DECLARE
  v_request_count integer;
BEGIN
  SELECT count(*) INTO v_request_count
  FROM public.chat_requests
  WHERE id = '30000000-0000-0000-0000-000000001906';
  IF v_request_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 19r: service-role stale-JWT request was not persisted';
  END IF;
  RAISE NOTICE 'PASS 19r: trusted service-role request path ignores a stale JWT while preserving pair validation';
END $$;

-- Forged relationship columns are rejected before the private profile helper
-- is consulted. These use the trusted synthetic path so the trigger itself,
-- rather than an RLS policy, is the negative control.
DO $$
BEGIN
  INSERT INTO public.chat_requests
    (id, match_id, requester_id, responder_id, status, expires_at)
  VALUES (
    '30000000-0000-0000-0000-000000001907',
    '20000000-0000-0000-0000-000000001901',
    '10000000-0000-0000-0000-000000001909',
    '10000000-0000-0000-0000-000000001902',
    'pending',
    '2026-09-14T00:00:00Z'
  );
  RAISE EXCEPTION 'FAIL 19r1: forged chat-request participants were accepted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19r1: forged request failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19r1: forged request participants are rejected before private inspection';
END $$;

DO $$
BEGIN
  INSERT INTO public.direct_chat_messages
    (id, room_id, sender_id, content)
  VALUES (
    '50000000-0000-0000-0000-000000001905',
    '40000000-0000-0000-0000-000000001902',
    '10000000-0000-0000-0000-000000001909',
    'forged sender'
  );
  RAISE EXCEPTION 'FAIL 19r2: forged message sender was accepted';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19r2: forged sender failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19r2: forged message sender is rejected before private inspection';
END $$;

-- Authenticated JWT callers still cannot reach a direct write path that RLS
-- intentionally removed. This covers an outsider request, a non-responder
-- request UPDATE, and a forged direct-message sender under an actual JWT.
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000001909"}';
DO $$
BEGIN
  INSERT INTO public.chat_requests
    (id, match_id, requester_id, responder_id, status, expires_at)
  VALUES (
    '30000000-0000-0000-0000-000000001908',
    '20000000-0000-0000-0000-000000001901',
    '10000000-0000-0000-0000-000000001909',
    '10000000-0000-0000-0000-000000001902',
    'pending',
    '2026-09-14T00:00:00Z'
  );
  RAISE EXCEPTION 'FAIL 19r3: authenticated outsider inserted a forged request';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN RAISE; END IF;
    RAISE NOTICE 'PASS 19r3: forged direct write rejected by generic guard';
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS 19r3: authenticated outsider request is blocked by the removed direct INSERT path';
END $$;

SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000001902"}';
DO $$
BEGIN
  UPDATE public.chat_requests
  SET status = 'declined'
  WHERE id = '30000000-0000-0000-0000-000000001901';
  IF FOUND THEN
    RAISE EXCEPTION 'FAIL 19r4: authenticated requester updated a responder-owned request';
  END IF;
  RAISE NOTICE 'PASS 19r4: requester UPDATE affected zero rows';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS 19r4: authenticated requester cannot use the responder-only request UPDATE policy';
END $$;

SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000001909"}';
DO $$
BEGIN
  INSERT INTO public.direct_chat_messages
    (id, room_id, sender_id, content)
  VALUES (
    '50000000-0000-0000-0000-000000001906',
    '40000000-0000-0000-0000-000000001902',
    '10000000-0000-0000-0000-000000001909',
    'authenticated forged sender'
  );
  RAISE EXCEPTION 'FAIL 19r5: authenticated outsider inserted a forged message';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN RAISE; END IF;
    RAISE NOTICE 'PASS 19r5: forged direct write rejected by generic guard';
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS 19r5: authenticated forged message is blocked by the removed direct INSERT path';
END $$;
RESET role;
RESET request.jwt.claims;

-- A newly inserted room is guarded even when its requested status is already
-- closed. This avoids creating an unauthorized terminal room as a side door.
DO $$
BEGIN
  INSERT INTO public.direct_chat_rooms (id, match_id, status)
  VALUES (
    '40000000-0000-0000-0000-000000001905',
    '20000000-0000-0000-0000-000000001905',
    'closed'
  );
  RAISE EXCEPTION 'FAIL 19s: revoked pair accepted a new closed room';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19s: room INSERT failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19s: revoked pair cannot INSERT a closed room';
END $$;

-- Close and terminal no-op are the only room status exceptions after
-- revocation. Reopen, reparent, and mixed linkage changes remain forbidden.
UPDATE public.direct_chat_rooms
SET status = 'closed'
WHERE id = '40000000-0000-0000-0000-000000001901';

UPDATE public.direct_chat_rooms
SET status = 'closed'
WHERE id = '40000000-0000-0000-0000-000000001901';

DO $$
BEGIN
  UPDATE public.direct_chat_rooms
  SET status = 'active'
  WHERE id = '40000000-0000-0000-0000-000000001901';
  RAISE EXCEPTION 'FAIL 19t: revoked room reopened';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19t: room reopen failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19t: revoked room cannot reopen';
END $$;

DO $$
BEGIN
  UPDATE public.direct_chat_rooms
  SET match_id = '20000000-0000-0000-0000-000000001906'
  WHERE id = '40000000-0000-0000-0000-000000001901';
  RAISE EXCEPTION 'FAIL 19u: revoked room was reparented to another match';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19u: revoked room linkage failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19u: revoked room cannot change match linkage';
END $$;

DO $$
BEGIN
  UPDATE public.direct_chat_rooms
  SET status = 'closed',
      match_id = '20000000-0000-0000-0000-000000001906'
  WHERE id = '40000000-0000-0000-0000-000000001902';
  RAISE EXCEPTION 'FAIL 19v: room close hid a forbidden match linkage edit';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19v: mixed room update failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19v: room close cannot hide a forbidden linkage edit';
END $$;

-- The room with pair 1902 remains active after the failed mixed update, which
-- is needed for the message INSERT negative control below.

DO $$
BEGIN
  INSERT INTO public.direct_chat_messages
    (id, room_id, sender_id, content, is_read)
  VALUES (
    '50000000-0000-0000-0000-000000001904',
    '40000000-0000-0000-0000-000000001902',
    '10000000-0000-0000-0000-000000001903',
    'revoked message insert',
    false
  );
  RAISE EXCEPTION 'FAIL 19w: revoked pair accepted a new direct message';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19w: message INSERT failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19w: revoked pair cannot INSERT a direct message';
END $$;

-- A false -> true receipt and an exact no-op are the only message UPDATE
-- exceptions after revocation. They leave every identity/content/linkage field
-- byte-for-byte unchanged.
UPDATE public.direct_chat_messages
SET is_read = true
WHERE id = '50000000-0000-0000-0000-000000001902';

UPDATE public.direct_chat_messages
SET is_read = true
WHERE id = '50000000-0000-0000-0000-000000001902';

DO $$
BEGIN
  UPDATE public.direct_chat_messages
  SET content = 'forbidden content edit'
  WHERE id = '50000000-0000-0000-0000-000000001902';
  RAISE EXCEPTION 'FAIL 19x: revoked message accepted content edit';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19x: message content edit failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19x: revoked message cannot change content';
END $$;

DO $$
BEGIN
  UPDATE public.direct_chat_messages
  SET sender_id = '10000000-0000-0000-0000-000000001904'
  WHERE id = '50000000-0000-0000-0000-000000001902';
  RAISE EXCEPTION 'FAIL 19y: revoked message accepted sender edit';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19y: message sender edit failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19y: revoked message cannot change sender';
END $$;

DO $$
BEGIN
  UPDATE public.direct_chat_messages
  SET room_id = '40000000-0000-0000-0000-000000001907'
  WHERE id = '50000000-0000-0000-0000-000000001901';
  RAISE EXCEPTION 'FAIL 19z: revoked message accepted room reparent';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19z: message room linkage edit failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19z: revoked message cannot change room linkage';
END $$;

DO $$
BEGIN
  UPDATE public.direct_chat_messages
  SET id = '50000000-0000-0000-0000-000000001999'
  WHERE id = '50000000-0000-0000-0000-000000001902';
  RAISE EXCEPTION 'FAIL 19aa: revoked message accepted id edit';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19aa: message id edit failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19aa: revoked message cannot change id';
END $$;

DO $$
BEGIN
  UPDATE public.direct_chat_messages
  SET created_at = '2026-09-07T02:00:00Z'
  WHERE id = '50000000-0000-0000-0000-000000001902';
  RAISE EXCEPTION 'FAIL 19ab: revoked message accepted created_at edit';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19ab: message created_at edit failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19ab: revoked message cannot change created_at';
END $$;

DO $$
BEGIN
  UPDATE public.direct_chat_messages
  SET is_read = true,
      content = 'mixed receipt and content edit'
  WHERE id = '50000000-0000-0000-0000-000000001903';
  RAISE EXCEPTION 'FAIL 19ac: read receipt hid a content edit';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'chat write is not eligible' THEN
      RAISE EXCEPTION 'FAIL 19ac: mixed message update failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19ac: read receipt cannot hide a forbidden content edit';
END $$;

-- The existing active-room trigger runs before the profile guard. A closed
-- room must therefore reject even an otherwise-safe read receipt after the
-- profile preference was revoked.
DO $$
BEGIN
  UPDATE public.direct_chat_messages
  SET is_read = true
  WHERE id = '50000000-0000-0000-0000-000000001901';
  RAISE EXCEPTION 'FAIL 19ad: closed room accepted a read receipt';
EXCEPTION
  WHEN check_violation THEN
    IF SQLERRM <> 'direct chat room is not active' THEN
      RAISE EXCEPTION 'FAIL 19ad: closed-room receipt failed for the wrong reason';
    END IF;
    RAISE NOTICE 'PASS 19ad: existing active-room guard rejects a closed-room receipt before cleanup exception';
END $$;

DO $$
DECLARE
  v_bad_requests integer;
  v_bad_rooms integer;
  v_bad_messages integer;
  v_receipt boolean;
  v_request_status text;
BEGIN
  SELECT count(*) INTO v_bad_requests
  FROM public.chat_requests
  WHERE id IN (
    '30000000-0000-0000-0000-000000001905',
    '30000000-0000-0000-0000-000000001907',
    '30000000-0000-0000-0000-000000001908'
  );
  SELECT count(*) INTO v_bad_rooms
  FROM public.direct_chat_rooms
  WHERE id = '40000000-0000-0000-0000-000000001905';
  SELECT count(*) INTO v_bad_messages
  FROM public.direct_chat_messages
  WHERE id IN (
    '50000000-0000-0000-0000-000000001904',
    '50000000-0000-0000-0000-000000001905',
    '50000000-0000-0000-0000-000000001906'
  );
  SELECT is_read INTO v_receipt
  FROM public.direct_chat_messages
  WHERE id = '50000000-0000-0000-0000-000000001902';
  SELECT status INTO v_request_status
  FROM public.chat_requests
  WHERE id = '30000000-0000-0000-0000-000000001901';

  IF v_bad_requests <> 0 OR v_bad_rooms <> 0 OR v_bad_messages <> 0 THEN
    RAISE EXCEPTION 'FAIL 19ae: rejected rows were persisted (%/%/%)', v_bad_requests, v_bad_rooms, v_bad_messages;
  END IF;
  IF v_receipt IS DISTINCT FROM true OR v_request_status IS DISTINCT FROM 'declined' THEN
    RAISE EXCEPTION 'FAIL 19af: safe receipt or terminal request cleanup did not persist';
  END IF;
  RAISE NOTICE 'PASS 19ae-af: rejected INSERT/UPDATE rows were not persisted and narrow receipt/terminal cleanup persisted';
END $$;

-- Root verification is recorded separately from this executable fixture.
ROLLBACK;
