-- Covers supabase/migrations/20260820100000_notification_gap_hardening.sql:
-- the three gaps left open by step 4-A (PR #27), all of which go live the
-- moment a per-scenario trigger calls sendNotification.
--
-- Each block asserts the negative control too -- the case that must still be
-- allowed -- because a constraint that rejects everything would pass a
-- rejection-only test.

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000c1', 'wingward-test-c1@example.invalid'),
  ('00000000-0000-0000-0000-0000000000c2', 'wingward-test-c2@example.invalid');

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000c1', nickname = 'Test C1',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c1';
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000c2', nickname = 'Test C2',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c2';

INSERT INTO public.notification_scenarios (scenario_id, title, trigger_description, target_action, priority)
VALUES ('N-TEST-GAP', 'test scenario', 'test trigger', 'test action', 'P1')
ON CONFLICT (scenario_id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Gap 1: the dedup race, with match_id NULL.
--
-- This is the case the pre-existing UNIQUE(scenario_id, user_id, match_id,
-- dedup_window_start) could never cover, on two separate counts: NULL never
-- equals NULL, and the two racers carry different dedup_window_start values.
-- ---------------------------------------------------------------------------
INSERT INTO public.notifications (id, scenario_id, user_id, match_id, dedup_window_start)
VALUES ('20000000-0000-0000-0000-0000000000c1', 'N-TEST-GAP', '10000000-0000-0000-0000-0000000000c1',
        NULL, '2026-08-20T00:00:00Z');

DO $$
BEGIN
  -- A second call one hour later: distinct dedup_window_start, NULL match_id,
  -- overlapping 24h window.
  INSERT INTO public.notifications (scenario_id, user_id, match_id, dedup_window_start)
  VALUES ('N-TEST-GAP', '10000000-0000-0000-0000-0000000000c1', NULL, '2026-08-20T01:00:00Z');
  RAISE EXCEPTION 'FAIL gap-1a: a second notification inside the 24h dedup window was accepted (NULL match_id)';
EXCEPTION
  WHEN exclusion_violation THEN
    RAISE NOTICE 'PASS gap-1a: overlapping 24h dedup window rejected with NULL match_id';
END $$;

DO $$
BEGIN
  -- Negative control: past the window, the same key must be allowed again,
  -- or the constraint would have broken re-engagement entirely.
  INSERT INTO public.notifications (scenario_id, user_id, match_id, dedup_window_start)
  VALUES ('N-TEST-GAP', '10000000-0000-0000-0000-0000000000c1', NULL, '2026-08-21T00:00:01Z');
  RAISE NOTICE 'PASS gap-1b: the same key is accepted once the 24h window has passed';
END $$;

DO $$
BEGIN
  -- Negative control: a different user, same scenario, overlapping window.
  INSERT INTO public.notifications (scenario_id, user_id, match_id, dedup_window_start)
  VALUES ('N-TEST-GAP', '10000000-0000-0000-0000-0000000000c2', NULL, '2026-08-20T01:00:00Z');
  RAISE NOTICE 'PASS gap-1c: a different user is unaffected by another user''s dedup window';
END $$;

DO $$
BEGIN
  -- Rows with no dedup window at all are outside the constraint's WHERE
  -- clause and must remain insertable.
  INSERT INTO public.notifications (scenario_id, user_id, match_id, dedup_window_start)
  VALUES ('N-TEST-GAP', '10000000-0000-0000-0000-0000000000c1', NULL, NULL);
  INSERT INTO public.notifications (scenario_id, user_id, match_id, dedup_window_start)
  VALUES ('N-TEST-GAP', '10000000-0000-0000-0000-0000000000c1', NULL, NULL);
  RAISE NOTICE 'PASS gap-1d: rows with a NULL dedup_window_start are unconstrained';
END $$;

-- ---------------------------------------------------------------------------
-- Gap 2: a client fabricating its own event_type='sent' row.
-- ---------------------------------------------------------------------------
SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000c1"}';

DO $$
BEGIN
  -- C1 owns this notification, so the ownership clauses all pass. Only the
  -- new event_type clause can reject it.
  INSERT INTO public.notification_events (notification_id, user_id, event_type, occurred_at)
  VALUES ('20000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c1', 'sent', now());
  RAISE EXCEPTION 'FAIL gap-2a: a client inserted its own event_type=''sent'' row on a notification it owns';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS gap-2a: a client-supplied event_type=''sent'' is rejected by RLS';
END $$;

DO $$
BEGIN
  -- Negative control: the event types a client is supposed to report must
  -- still go through, or step 4-B's reporting path is dead.
  INSERT INTO public.notification_events (notification_id, user_id, event_type, occurred_at)
  VALUES ('20000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c1', 'opened', now());
  RAISE NOTICE 'PASS gap-2b: a client may still report its own non-sent events';
END $$;

RESET role;
RESET request.jwt.claims;

-- ---------------------------------------------------------------------------
-- Gap 3: two 'sent' rows for one notification.
--
-- Written as service_role (RLS bypassed), which is the only writer of 'sent'
-- once gap 2 is closed -- so this asserts the invariant holds even against the
-- pipeline's own fallback-id path.
-- ---------------------------------------------------------------------------
INSERT INTO public.notification_events (id, notification_id, user_id, event_type, occurred_at)
VALUES ('20000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-0000000000c1',
        '10000000-0000-0000-0000-0000000000c1', 'sent', now());

DO $$
BEGIN
  -- The recordSentEvent fallback: a different (generated) id, same identity.
  INSERT INTO public.notification_events (notification_id, user_id, event_type, occurred_at)
  VALUES ('20000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c1', 'sent', now());
  RAISE EXCEPTION 'FAIL gap-3a: a second sent event was accepted for the same notification';
EXCEPTION
  WHEN unique_violation THEN
    RAISE NOTICE 'PASS gap-3a: exactly one sent event per notification is enforced';
END $$;

DO $$
BEGIN
  -- Negative control: the index is partial, so non-sent events must still be
  -- repeatable for the same notification (delivered, opened, screen_viewed...).
  INSERT INTO public.notification_events (notification_id, user_id, event_type, occurred_at)
  VALUES ('20000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c1', 'screen_viewed', now());
  INSERT INTO public.notification_events (notification_id, user_id, event_type, occurred_at)
  VALUES ('20000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-0000000000c1', 'screen_viewed', now());
  RAISE NOTICE 'PASS gap-3b: non-sent events remain repeatable for the same notification';
END $$;

ROLLBACK;
