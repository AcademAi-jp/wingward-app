-- Acceptance criterion #3: all 12 new tables have RLS enabled.
-- docs/spec/impl/step-01-migrations-rls.md §7 item 3

DO $$
DECLARE
  expected text[] := ARRAY[
    'meetups', 'meetup_preferences', 'meetup_proposals', 'meetup_proposal_responses',
    'notification_scenarios', 'notifications', 'notification_events',
    'usage_counters', 'entitlements',
    'venues', 'venue_checkins', 'meetup_feedback'
  ];
  t text;
  is_enabled boolean;
BEGIN
  FOREACH t IN ARRAY expected LOOP
    SELECT relrowsecurity INTO is_enabled
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = t;

    IF is_enabled IS NULL THEN
      RAISE EXCEPTION 'table public.% does not exist', t;
    END IF;

    IF is_enabled IS NOT TRUE THEN
      RAISE EXCEPTION 'RLS is NOT enabled on public.%', t;
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS: RLS enabled on all % new tables', array_length(expected, 1);
END $$;
