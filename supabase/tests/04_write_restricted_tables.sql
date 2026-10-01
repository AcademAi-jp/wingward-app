-- Acceptance criterion #6: an authenticated JWT cannot write to usage_counters, entitlements,
-- or notifications (no write policies exist for these tables; only service_role writes).
-- docs/spec/impl/step-01-migrations-rls.md §7 item 6

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-0000000000a3', 'wingward-test-a3@example.invalid');

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-0000000000a3', nickname = 'Test A3',
    birth_date = '1990-01-01', age_verified_at = '2026-08-24T00:00:00Z', age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-0000000000a3';

INSERT INTO public.notification_scenarios (scenario_id, title, trigger_description, target_action, priority)
VALUES ('N-TEST', 'test scenario', 'test trigger', 'test action', 'P1')
ON CONFLICT (scenario_id) DO NOTHING;

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-0000000000a3"}';

DO $$
BEGIN
  INSERT INTO public.usage_counters (user_id, quota_key, period_start, period_end, used_count)
  VALUES ('10000000-0000-0000-0000-0000000000a3', 'fox_conversation', current_date, current_date, 0);
  RAISE EXCEPTION 'FAIL #6: authenticated JWT was able to INSERT into usage_counters';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS #6: usage_counters INSERT rejected (insufficient_privilege / no policy)';
END $$;

DO $$
BEGIN
  INSERT INTO public.entitlements (user_id, is_active) VALUES ('10000000-0000-0000-0000-0000000000a3', true);
  RAISE EXCEPTION 'FAIL #6: authenticated JWT was able to INSERT into entitlements';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS #6: entitlements INSERT rejected (insufficient_privilege / no policy)';
END $$;

DO $$
BEGIN
  INSERT INTO public.notifications (scenario_id, user_id) VALUES ('N-TEST', '10000000-0000-0000-0000-0000000000a3');
  RAISE EXCEPTION 'FAIL #6: authenticated JWT was able to INSERT into notifications';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS #6: notifications INSERT rejected (insufficient_privilege / no policy)';
END $$;

RESET role;
RESET request.jwt.claims;

ROLLBACK;
