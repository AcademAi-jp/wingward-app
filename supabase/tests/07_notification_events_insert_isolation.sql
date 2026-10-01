-- Acceptance criterion A-4 (DB layer): an authenticated JWT can INSERT a
-- notification_events row only for a notification_id that belongs to them.
-- docs/spec/impl/step-04-notifications.md §6, A-4 ("かつ service_role を経由
-- しない直接アクセスでも RLS が拒否する（DB 層）").
--
-- Exercises RLS policy notification_events_insert
-- (supabase/migrations/20260812100400_notifications.sql):
--   WITH CHECK (
--     public.get_user_profile_id() = user_id
--     AND public.get_user_profile_id() = (SELECT user_id FROM public.notifications WHERE id = notification_id)
--   )
-- This is the DB-layer half of A-4; the API-layer half (route rejects a
-- report against someone else's notification_id before ever reaching the
-- DB) is covered by apps/api/src/routes/notification-events.test.ts.

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000b1', 'wingward-test-b1@example.invalid'),
  ('00000000-0000-0000-0000-0000000000b2', 'wingward-test-b2@example.invalid');

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b1', nickname = 'Test B1',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b1';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000b2', nickname = 'Test B2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000b2';

INSERT INTO public.notification_scenarios (scenario_id, title, trigger_description, target_action, priority)
VALUES ('N-TEST-EVT', 'test scenario', 'test trigger', 'test action', 'P1')
ON CONFLICT (scenario_id) DO NOTHING;

-- A notification addressed to B1 (created as service_role, bypassing RLS —
-- notifications has no INSERT policy for authenticated users, matching
-- test 04's write-restriction check).
INSERT INTO public.notifications (id, scenario_id, user_id)
VALUES ('20000000-0000-0000-0000-0000000000b1', 'N-TEST-EVT', '10000000-0000-0000-0000-0000000000b1');

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000b2"}'; -- impersonating B2

DO $$
BEGIN
  -- B2 tries to report an event against B1's notification, with user_id
  -- correctly set to their own id (the "honest but wrong notification_id"
  -- case, and the one the WITH CHECK's second clause exists for).
  INSERT INTO public.notification_events (notification_id, user_id, event_type, occurred_at)
  VALUES ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-0000000000b2', 'opened', now());
  RAISE EXCEPTION 'FAIL A-4: B2 was able to INSERT a notification_event against B1''s notification_id';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS A-4a: cross-user notification_id rejected (insufficient_privilege / WITH CHECK)';
END $$;

DO $$
BEGIN
  -- B2 tries to claim the event as belonging to B1 (user_id spoofed to B1)
  -- against B1's own notification — the first WITH CHECK clause must still
  -- reject this because the JWT-derived get_user_profile_id() is B2's.
  INSERT INTO public.notification_events (notification_id, user_id, event_type, occurred_at)
  VALUES ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-0000000000b1', 'opened', now());
  RAISE EXCEPTION 'FAIL A-4: B2 was able to INSERT a notification_event with a spoofed user_id';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS A-4b: spoofed user_id on someone else''s notification rejected';
END $$;

RESET role;
RESET request.jwt.claims;

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000b1"}'; -- impersonating B1, the owner

DO $$
BEGIN
  -- B1 reporting an event against their own notification must succeed.
  INSERT INTO public.notification_events (notification_id, user_id, event_type, occurred_at)
  VALUES ('20000000-0000-0000-0000-0000000000b1', '10000000-0000-0000-0000-0000000000b1', 'opened', now());
  RAISE NOTICE 'PASS A-4c: the notification''s own owner can INSERT a notification_event for it';
END $$;

RESET role;
RESET request.jwt.claims;

ROLLBACK;
