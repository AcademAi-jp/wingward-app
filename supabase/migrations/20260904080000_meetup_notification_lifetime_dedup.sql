-- Keep the two notifications emitted for a mutual meetup intent idempotent
-- for the lifetime of that meetup. The ordinary 24-hour notification
-- deduplication window is intentionally not sufficient for retries after a
-- failed delivery or a long-running verification flow.
--
-- sendNotification maps a concurrent/existing 23505 from this index to its
-- safe "duplicate" result. The index is partial so unrelated scenarios and
-- notifications without a meetup retain their existing semantics.
CREATE UNIQUE INDEX notifications_meetup_lifetime_scenario_user_key
  ON public.notifications (scenario_id, user_id, meetup_id)
  WHERE meetup_id IS NOT NULL
    AND scenario_id IN ('N-04', 'N-07');
