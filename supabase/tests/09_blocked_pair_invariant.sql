-- Covers supabase/migrations/20260821100000_blocked_pair_invariant.sql.
--
-- The point of the trigger is that the guarantee does not depend on the caller
-- remembering to check, so every assertion here inserts as `service_role`
-- would — no RLS involved, no application code in the path. If these rows can
-- be created, so can the application create them.
--
-- Each assertion carries its negative control: a constraint that rejected
-- everything would pass a rejection-only test.

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000d1', 'wingward-test-d1@example.invalid'),
  ('00000000-0000-0000-0000-0000000000d2', 'wingward-test-d2@example.invalid'),
  ('00000000-0000-0000-0000-0000000000d3', 'wingward-test-d3@example.invalid');

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000d1', nickname = 'Test D1',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000d1';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000d2', nickname = 'Test D2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000d2';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000d3', nickname = 'Test D3',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000d3';

UPDATE public.user_profiles
SET gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE id IN (
  '10000000-0000-0000-0000-0000000000d1',
  '10000000-0000-0000-0000-0000000000d2',
  '10000000-0000-0000-0000-0000000000d3'
);

-- D1 blocked D2. D3 is blocked by nobody.
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-0000000000d1', '10000000-0000-0000-0000-0000000000d2');

-- ---------------------------------------------------------------------------
-- matches
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  INSERT INTO public.matches (user_a_id, user_b_id)
  VALUES ('10000000-0000-0000-0000-0000000000d1', '10000000-0000-0000-0000-0000000000d2');
  RAISE EXCEPTION 'FAIL 09a: a match was created for a blocked pair (blocker first)';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'PASS 09a: matches rejects a blocked pair with the blocker as user_a';
END $$;

DO $$
BEGIN
  -- Direction must not matter: the block is D1->D2, this insert is D2,D1.
  INSERT INTO public.matches (user_a_id, user_b_id)
  VALUES ('10000000-0000-0000-0000-0000000000d2', '10000000-0000-0000-0000-0000000000d1');
  RAISE EXCEPTION 'FAIL 09b: a match was created for a blocked pair (blocked first)';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'PASS 09b: matches rejects a blocked pair regardless of column order';
END $$;

DO $$
BEGIN
  -- Negative control. Without this the trigger could be rejecting everything.
  INSERT INTO public.matches (user_a_id, user_b_id)
  VALUES ('10000000-0000-0000-0000-0000000000d1', '10000000-0000-0000-0000-0000000000d3');
  RAISE NOTICE 'PASS 09c: an unblocked pair is still matched';
END $$;

-- ---------------------------------------------------------------------------
-- chat_requests
-- ---------------------------------------------------------------------------
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES ('20000000-0000-0000-0000-0000000000d1',
        '10000000-0000-0000-0000-0000000000d2', '10000000-0000-0000-0000-0000000000d3');

DO $$
BEGIN
  -- The match predates the block in this fixture, which is exactly the case
  -- the application check was written for and the race it could not close:
  -- the pair became blocked after they were matched.
  INSERT INTO public.blocks (blocker_id, blocked_id)
  VALUES ('10000000-0000-0000-0000-0000000000d3', '10000000-0000-0000-0000-0000000000d2');

  INSERT INTO public.chat_requests (match_id, requester_id, responder_id, expires_at)
  VALUES ('20000000-0000-0000-0000-0000000000d1',
          '10000000-0000-0000-0000-0000000000d2', '10000000-0000-0000-0000-0000000000d3',
          now() + interval '48 hours');
  RAISE EXCEPTION 'FAIL 09d: a chat request was created after the responder blocked the requester';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'PASS 09d: chat_requests rejects a pair blocked after the match was made';
END $$;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000e1', 'wingward-test-e1@example.invalid'),
  ('00000000-0000-0000-0000-0000000000e2', 'wingward-test-e2@example.invalid');
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000e1', nickname = 'Test E1',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000e1';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000e2', nickname = 'Test E2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000e2';
UPDATE public.user_profiles
SET gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE id IN (
  '10000000-0000-0000-0000-0000000000e1',
  '10000000-0000-0000-0000-0000000000e2'
);
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES ('20000000-0000-0000-0000-0000000000e1',
        '10000000-0000-0000-0000-0000000000e1', '10000000-0000-0000-0000-0000000000e2');

DO $$
BEGIN
  -- Negative control for chat_requests: no block anywhere, so the ordinary
  -- path must be untouched.
  INSERT INTO public.chat_requests (match_id, requester_id, responder_id, expires_at)
  VALUES ('20000000-0000-0000-0000-0000000000e1',
          '10000000-0000-0000-0000-0000000000e1', '10000000-0000-0000-0000-0000000000e2',
          now() + interval '48 hours');
  RAISE NOTICE 'PASS 09e: an unblocked pair can still create a chat request';
END $$;

-- ---------------------------------------------------------------------------
-- chat_requests_insert policy removal
--
-- The trigger above turns a client-reachable chat_requests INSERT into an
-- oracle for "did this person block me" (23514 vs. success), which is exactly
-- what POST /api/chat-requests hides behind an indistinguishable NOT_FOUND.
-- The fix removes chat_requests_insert entirely, so `authenticated` cannot
-- INSERT chat_requests directly at all any more, blocked pair or not — this
-- must hold even for an unblocked pair, which the old policy would have
-- allowed. `service_role` bypasses RLS and must still be able to write,
-- matching how apps/api actually connects (getSupabaseClient). Fresh
-- users/match here: idx_chat_requests_match_id is UNIQUE on match_id alone,
-- and the E1/E2 match above already has a row from 09e.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000f1', 'wingward-test-f1@example.invalid'),
  ('00000000-0000-0000-0000-0000000000f2', 'wingward-test-f2@example.invalid');
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000f1', nickname = 'Test F1',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000f1';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000f2', nickname = 'Test F2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000f2';
UPDATE public.user_profiles
SET gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE id IN (
  '10000000-0000-0000-0000-0000000000f1',
  '10000000-0000-0000-0000-0000000000f2'
);
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES ('20000000-0000-0000-0000-0000000000f1',
        '10000000-0000-0000-0000-0000000000f1', '10000000-0000-0000-0000-0000000000f2');

DO $$
BEGIN
  SET LOCAL role = 'authenticated';
  SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000f1"}';

  INSERT INTO public.chat_requests (match_id, requester_id, responder_id, expires_at)
  VALUES ('20000000-0000-0000-0000-0000000000f1',
          '10000000-0000-0000-0000-0000000000f1', '10000000-0000-0000-0000-0000000000f2',
          now() + interval '48 hours');
  RAISE EXCEPTION 'FAIL 09f: authenticated role was able to INSERT into chat_requests directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS 09f: chat_requests INSERT rejected for authenticated (chat_requests_insert policy removed)';
END $$;

RESET role;
RESET request.jwt.claims;

DO $$
BEGIN
  -- Negative control: service_role (RLS bypassed, matching how apps/api
  -- connects with the service_role key) must still be able to INSERT.
  INSERT INTO public.chat_requests (match_id, requester_id, responder_id, expires_at)
  VALUES ('20000000-0000-0000-0000-0000000000f1',
          '10000000-0000-0000-0000-0000000000f1', '10000000-0000-0000-0000-0000000000f2',
          now() + interval '48 hours');
  RAISE NOTICE 'PASS 09g: service_role can still INSERT into chat_requests directly';
END $$;

-- ---------------------------------------------------------------------------
-- HOLE 1: chat_requests participant columns are frozen on UPDATE.
--
-- chat_requests_update (20260228100002_rls.sql) has no WITH CHECK on
-- requester_id/responder_id/match_id, so a responder could otherwise rewrite
-- an existing row to name a different pair entirely — including a pair the
-- INSERT trigger would have rejected outright. freeze_chat_request_participants
-- closes that. 09i is the regression guard and the whole point of this fix:
-- declining a BLOCKED pair's request must still work, or the fix breaks the
-- one path it must not touch.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'wingward-test-a1@example.invalid'),
  ('00000000-0000-0000-0000-0000000000a2', 'wingward-test-a2@example.invalid'),
  ('00000000-0000-0000-0000-0000000000a3', 'wingward-test-a3@example.invalid');
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000a1', nickname = 'Test A1',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a1';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000a2', nickname = 'Test A2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a2';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000a3', nickname = 'Test A3',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a3';
UPDATE public.user_profiles
SET gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE id IN (
  '10000000-0000-0000-0000-0000000000a1',
  '10000000-0000-0000-0000-0000000000a2',
  '10000000-0000-0000-0000-0000000000a3'
);
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES ('20000000-0000-0000-0000-0000000000a1',
        '10000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-0000000000a2');
INSERT INTO public.chat_requests (id, match_id, requester_id, responder_id, expires_at)
VALUES ('30000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-0000000000a1',
        '10000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-0000000000a2',
        now() + interval '48 hours');

DO $$
BEGIN
  UPDATE public.chat_requests
  SET requester_id = '10000000-0000-0000-0000-0000000000a3'
  WHERE id = '30000000-0000-0000-0000-0000000000a1';
  RAISE EXCEPTION 'FAIL 09h: chat_requests.requester_id was changed by UPDATE';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'PASS 09h: chat_requests rejects an UPDATE that changes requester_id';
END $$;

-- G1 blocked G2 after the request above was created — the same "blocked
-- after the match/request already existed" scenario as 09d.
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-0000000000a1', '10000000-0000-0000-0000-0000000000a2');

DO $$
BEGIN
  -- Negative control / regression guard: an UPDATE that only touches
  -- status/responded_at — exactly what PUT /api/chat-requests/:id does on
  -- decline — must still succeed even though this pair is now blocked. If
  -- freeze_chat_request_participants (or some other trigger) started
  -- re-checking blocks on UPDATE, this would fail and the blocker would be
  -- unable to decline the very request that raced in.
  UPDATE public.chat_requests
  SET status = 'declined', responded_at = now()
  WHERE id = '30000000-0000-0000-0000-0000000000a1';
  RAISE NOTICE 'PASS 09i: a blocked pair''s chat request can still be declined (status-only UPDATE)';
END $$;

-- ---------------------------------------------------------------------------
-- HOLE 2: direct_chat_rooms rejects a blocked pair's match.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000b1', 'wingward-test-b1@example.invalid'),
  ('00000000-0000-0000-0000-0000000000b2', 'wingward-test-b2@example.invalid'),
  ('00000000-0000-0000-0000-0000000000b3', 'wingward-test-b3@example.invalid');
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b1', nickname = 'Test B1',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b1';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b2', nickname = 'Test B2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b2';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b3', nickname = 'Test B3',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b3';
UPDATE public.user_profiles
SET gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE id IN (
  '10000000-0000-0000-0000-0000000000b1',
  '10000000-0000-0000-0000-0000000000b2',
  '10000000-0000-0000-0000-0000000000b3'
);
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES ('20000000-0000-0000-0000-0000000000b1',
        '10000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-0000000000b2');
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES ('20000000-0000-0000-0000-0000000000b2',
        '10000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-0000000000b3');
-- The block goes in AFTER both matches: the matches trigger asserted in 09a
-- would reject the B1/B2 match itself otherwise. What HOLE 2 is about is a
-- room opened for a match that predates the block.
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-0000000000b2');

DO $$
BEGIN
  INSERT INTO public.direct_chat_rooms (match_id)
  VALUES ('20000000-0000-0000-0000-0000000000b1');
  RAISE EXCEPTION 'FAIL 09j: a direct_chat_rooms row was created for a blocked pair''s match';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'PASS 09j: direct_chat_rooms rejects a blocked pair''s match';
END $$;

DO $$
BEGIN
  -- Negative control: an unblocked pair's match must still be able to open a
  -- room. Fresh match (B1/B3) — direct_chat_rooms.match_id is UNIQUE.
  INSERT INTO public.direct_chat_rooms (match_id)
  VALUES ('20000000-0000-0000-0000-0000000000b2');
  RAISE NOTICE 'PASS 09k: direct_chat_rooms still opens for an unblocked pair''s match';
END $$;

-- ---------------------------------------------------------------------------
-- HOLE 3: direct_chat_messages rejects a blocked pair's room.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'wingward-test-c1@example.invalid'),
  ('00000000-0000-0000-0000-0000000000c2', 'wingward-test-c2@example.invalid'),
  ('00000000-0000-0000-0000-0000000000c3', 'wingward-test-c3@example.invalid');
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000c1', nickname = 'Test C1',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c1';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000c2', nickname = 'Test C2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c2';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000c3', nickname = 'Test C3',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c3';
UPDATE public.user_profiles
SET gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE id IN (
  '10000000-0000-0000-0000-0000000000c1',
  '10000000-0000-0000-0000-0000000000c2',
  '10000000-0000-0000-0000-0000000000c3'
);
-- Unblocked room first: C1/C3 have never blocked each other.
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES ('20000000-0000-0000-0000-0000000000c1',
        '10000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c3');
INSERT INTO public.direct_chat_rooms (id, match_id)
VALUES ('40000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-0000000000c1');

DO $$
BEGIN
  INSERT INTO public.direct_chat_messages (room_id, sender_id, content)
  VALUES ('40000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c3', 'hello');
  RAISE NOTICE 'PASS 09l: direct_chat_messages still sends for an unblocked pair''s room';
END $$;

-- Blocked room: the room is created for C1/C2 BEFORE the block, which is
-- exactly the race HOLE 3 exists for — a room that predates the block it
-- should have been closed by. Fresh match (direct_chat_rooms.match_id is
-- UNIQUE).
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES ('20000000-0000-0000-0000-0000000000c2',
        '10000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c2');
INSERT INTO public.direct_chat_rooms (id, match_id)
VALUES ('40000000-0000-0000-0000-0000000000c2', '20000000-0000-0000-0000-0000000000c2');
INSERT INTO public.blocks (blocker_id, blocked_id)
VALUES ('10000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c2');

DO $$
BEGIN
  INSERT INTO public.direct_chat_messages (room_id, sender_id, content)
  VALUES ('40000000-0000-0000-0000-0000000000c2', '10000000-0000-0000-0000-0000000000c1', 'hello');
  RAISE EXCEPTION 'FAIL 09m: a message was inserted into a blocked pair''s room';
EXCEPTION
  WHEN check_violation THEN
    RAISE NOTICE 'PASS 09m: direct_chat_messages rejects an INSERT into a blocked pair''s room';
END $$;

-- ---------------------------------------------------------------------------
-- direct_chat_messages_insert policy removal
--
-- Same shape as 09f/09g: the trigger above turns a client-reachable
-- direct_chat_messages INSERT into an oracle for "did this person block me"
-- (23514 vs. success). The fix removes direct_chat_messages_insert entirely,
-- so `authenticated` cannot INSERT direct_chat_messages directly at all any
-- more, blocked pair or not — this is deliberately exercised on an
-- UNBLOCKED pair, so the assertion is about the policy removal and not about
-- the trigger (which 09l/09m already cover). `service_role` bypasses RLS and
-- must still be able to write, matching how apps/api actually connects
-- (getSupabaseClient). Fresh users/match/room here: direct_chat_rooms.match_id
-- is UNIQUE, and no block row is created for this group at all.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000f3', 'wingward-test-f3@example.invalid'),
  ('00000000-0000-0000-0000-0000000000f4', 'wingward-test-f4@example.invalid');
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000f3', nickname = 'Test F3',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000f3';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000f4', nickname = 'Test F4',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000f4';
UPDATE public.user_profiles
SET gender_identity = 'woman',
    preferred_genders = ARRAY['woman']::text[],
    preference_mode = 'selected',
    dating_market = 'JP',
    onboarding_settings_completed_at = '2026-08-24T00:00:00Z'
WHERE id IN (
  '10000000-0000-0000-0000-0000000000f3',
  '10000000-0000-0000-0000-0000000000f4'
);
INSERT INTO public.matches (id, user_a_id, user_b_id)
VALUES ('20000000-0000-0000-0000-0000000000f3',
        '10000000-0000-0000-0000-0000000000f3', '10000000-0000-0000-0000-0000000000f4');
INSERT INTO public.direct_chat_rooms (id, match_id)
VALUES ('40000000-0000-0000-0000-0000000000f3', '20000000-0000-0000-0000-0000000000f3');

DO $$
BEGIN
  SET LOCAL role = 'authenticated';
  SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000f3"}';

  INSERT INTO public.direct_chat_messages (room_id, sender_id, content)
  VALUES ('40000000-0000-0000-0000-0000000000f3', '10000000-0000-0000-0000-0000000000f3', 'hello');
  RAISE EXCEPTION 'FAIL 09n: authenticated role was able to INSERT into direct_chat_messages directly';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS 09n: direct_chat_messages INSERT rejected for authenticated (direct_chat_messages_insert policy removed)';
END $$;

RESET role;
RESET request.jwt.claims;

DO $$
BEGIN
  -- Negative control: service_role (RLS bypassed, matching how apps/api
  -- connects with the service_role key) must still be able to INSERT.
  INSERT INTO public.direct_chat_messages (room_id, sender_id, content)
  VALUES ('40000000-0000-0000-0000-0000000000f3', '10000000-0000-0000-0000-0000000000f3', 'hello');
  RAISE NOTICE 'PASS 09o: service_role can still INSERT into direct_chat_messages directly';
END $$;

ROLLBACK;
