-- Acceptance criterion #8: notification_scenarios has N-01..N-13 seeded.
-- docs/spec/impl/step-01-migrations-rls.md §7 item 8

DO $$
DECLARE
  expected text[] := ARRAY[
    'N-01','N-02','N-03','N-04','N-05','N-06','N-07','N-08','N-09','N-10','N-11','N-12','N-13'
  ];
  missing text[];
BEGIN
  SELECT array_agg(s) INTO missing
  FROM unnest(expected) AS s
  WHERE NOT EXISTS (SELECT 1 FROM public.notification_scenarios WHERE scenario_id = s);

  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL #8: missing notification_scenarios rows: %', missing;
  END IF;

  RAISE NOTICE 'PASS #8: all 13 notification_scenarios (N-01..N-13) are present';
END $$;
