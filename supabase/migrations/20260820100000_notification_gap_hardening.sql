-- Closes the three migration-blocked gaps recorded as KNOWN GAP comments in
-- apps/api/src/services/notifications.ts (step 4-A, PR #27) and in ai/tasks.md.
-- All three are unreachable while nothing calls sendNotification, and all three
-- go live the moment a per-scenario trigger is wired, so this migration is a
-- prerequisite for that work rather than a follow-up to it.
--
-- See docs/spec/impl/step-04-notifications.md.

-- btree_gist gives GiST the plain-equality operator classes for uuid and text
-- that the exclusion constraint below needs alongside the range overlap.
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- Gap 1: the notification-creation dedup race.
--
-- sendNotification's dedup is a non-atomic SELECT-then-INSERT: two concurrent
-- calls for the same (scenario_id, user_id, match_id) can both pass the SELECT
-- before either has inserted, and both then send. The existing
-- UNIQUE(scenario_id, user_id, match_id, dedup_window_start) cannot close it --
-- dedup_window_start is `now` per call, so two near-simultaneous calls get two
-- different values and never conflict, and a NULL match_id never conflicts with
-- anything at all.
--
-- A partial UNIQUE index cannot express the real rule either, because the rule
-- is not "same key, same instant" but "same key, windows within 24h of each
-- other". An exclusion constraint over the 24h window as a range is the
-- primitive that states exactly that. coalesce() folds NULL match_id rows onto
-- a sentinel so they compare equal to each other; the WHERE clause leaves rows
-- with no dedup window unconstrained.
--
-- Consequence for callers: a losing racer now gets SQLSTATE 23P01
-- (exclusion_violation) from the INSERT. services/notifications.ts maps that to
-- reason "duplicate", the same outcome the pre-send SELECT produces.
-- The window has to come from a function marked IMMUTABLE, because an index
-- expression may not call a STABLE one -- and `timestamptz + interval` is
-- declared STABLE in general, since an interval carrying month or day
-- components resolves against the session time zone. This interval carries
-- neither: `interval '24 hours'` is stored purely in the time field, so the
-- addition is fixed-microsecond arithmetic and the IMMUTABLE marking is
-- honest. Do not widen this function to accept a caller-supplied interval;
-- that would make the marking a lie and silently corrupt the index.
CREATE FUNCTION public.notification_dedup_window(ts timestamptz)
  RETURNS tstzrange
  LANGUAGE sql
  IMMUTABLE
  STRICT
  PARALLEL SAFE
AS $$
  SELECT tstzrange(ts, ts + interval '24 hours');
$$;

-- Only the send pipeline (service_role) ever writes public.notifications --
-- the table has no INSERT policy for authenticated at all. See M10's note:
-- revoking PUBLIC is not enough on hosted Supabase, the roles hold their own
-- default grants and must be named.
REVOKE ALL ON FUNCTION public.notification_dedup_window(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notification_dedup_window(timestamptz) TO service_role;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_dedup_window_excl
  EXCLUDE USING gist (
    scenario_id WITH =,
    user_id WITH =,
    coalesce(match_id, '00000000-0000-0000-0000-000000000000'::uuid) WITH =,
    public.notification_dedup_window(dedup_window_start) WITH &&
  )
  WHERE (dedup_window_start IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Gap 2: a client fabricating its own event_type='sent' row.
--
-- notification_events_insert constrained user_id and notification_id ownership
-- but not event_type. A client on the direct-Supabase path can read its own
-- notifications row (notifications_select allows the owner), learn the
-- notification_id before the pipeline ever runs for it, and insert its OWN
-- 'sent' row with a fabricated occurred_at. recordSentEvent's identity check
-- would then accept that row as the genuine sent event and stop.
--
-- 'sent' is written only by the send pipeline, which runs as service_role and
-- bypasses RLS entirely, so rejecting it here costs the pipeline nothing.
-- routes/notification-events.ts already excludes 'sent' from what a client may
-- report; this makes the database, not the route, the place that decides.
DROP POLICY notification_events_insert ON public.notification_events;
CREATE POLICY notification_events_insert ON public.notification_events FOR INSERT
  WITH CHECK (
    event_type <> 'sent'
    AND public.get_user_profile_id() = user_id
    AND public.get_user_profile_id() = (SELECT user_id FROM public.notifications WHERE id = notification_id)
  );

-- ---------------------------------------------------------------------------
-- Gap 3: two 'sent' rows for one notification.
--
-- recordSentEvent inserts with a deterministic id (= notification_id). When a
-- foreign row already occupies that id, it falls back to a generated id -- and
-- two claimants can each reach that fallback, leaving two 'sent' rows. This is
-- not closable in application code: a fixed id is forgeable and a generated id
-- is not unique. Gap 2 removes the only plausible way for a foreign row to
-- occupy the id in the first place; this index makes the invariant hold
-- regardless of how the row got there.
CREATE UNIQUE INDEX notification_events_one_sent_per_notification
  ON public.notification_events (notification_id)
  WHERE event_type = 'sent';
