-- M5: notification_scenarios (seeded N-01..N-13), notifications, notification_events + RLS
-- See docs/spec/wingward-implementation-scope.md §3-4 and docs/spec/impl/step-01-migrations-rls.md §4 (M5), §5
--
-- Scenario titles/descriptions reconciled against docs/spec/wingfox-notification-design.md by the orchestrator on 2026-08-12.

-- notification_scenarios
CREATE TABLE public.notification_scenarios (
  scenario_id text PRIMARY KEY,
  title text NOT NULL,
  trigger_description text NOT NULL,
  target_action text NOT NULL,
  priority text NOT NULL CHECK (priority IN ('P0', 'P1')),
  quiet_hours_exempt boolean NOT NULL DEFAULT false,
  is_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.notification_scenarios (scenario_id, title, trigger_description, target_action, priority, quiet_hours_exempt) VALUES
  ('N-01', 'Your Fox found something', 'fox_conversations (purpose=compatibility) completed for a match', 'Open the match''s Fox conversation results', 'P0', false),
  ('N-02', 'Your question was answered', 'The partner''s Fox answered a question you asked it', 'Read the answer', 'P1', false),
  ('N-03', 'Chat request received', 'A chat_requests row was created for you', 'Respond to the chat request', 'P0', false),
  ('N-04', 'You both want to meet', 'Both parties set meetup intent (meetups.status -> intent_matched)', 'Open the meetup screen', 'P0', false),
  ('N-05', 'Fox is scheduling your meetup', 'meetup_proposals created with 3 time/place candidates', 'Review and select a candidate', 'P0', false),
  ('N-06', 'Meetup confirmed', 'Both parties selected the same proposal candidate', 'View confirmed meetup details', 'P0', false),
  ('N-07', 'Identity verification requested', 'meetups.status -> intent_matched triggers stage-2 identity verification for both parties', 'Complete identity verification', 'P0', false),
  ('N-08', 'Your meetup is tomorrow', 'confirmed_start_at is the next day, sent at 20:00 venue-local time', 'Review meetup details', 'P0', true),
  ('N-09', 'Your meetup is in 2 hours', 'confirmed_start_at is 2 hours away (venue-local time)', 'View route, safety guide, and cancellation path', 'P1', true),
  ('N-10', 'How did your meetup go?', 'meetups.status -> completed', 'Submit meetup feedback', 'P0', false),
  ('N-11', 'You both want to meet again', 'Both parties submitted want_to_meet_again=true on meetup_feedback', 'Open the shared result screen', 'P0', false),
  ('N-12', 'Your Fox learned something', 'User submitted meetup_feedback; their Fox reports what it learned', 'Read the Fox''s analysis', 'P1', false),
  ('N-13', 'Your availability is expiring', 'Registered availability window is 3 days from running out', 'Update your availability', 'P1', false)
ON CONFLICT (scenario_id) DO NOTHING;

-- notifications: id is the notification_id carried through OneSignal + notification_events
CREATE TABLE public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scenario_id text NOT NULL REFERENCES public.notification_scenarios(scenario_id),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  match_id uuid REFERENCES public.matches(id) ON DELETE SET NULL,
  meetup_id uuid REFERENCES public.meetups(id) ON DELETE SET NULL,
  ab_variant text,
  payload jsonb,
  onesignal_notification_id text,
  scheduled_for timestamptz,
  sent_at timestamptz,
  delivered_at timestamptz,
  opened_at timestamptz,
  action_completed_at timestamptz,
  suppressed_reason text,
  dedup_window_start timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(scenario_id, user_id, match_id, dedup_window_start)
);
CREATE INDEX idx_notifications_user_id ON public.notifications(user_id);
CREATE INDEX idx_notifications_scenario_id ON public.notifications(scenario_id);
CREATE INDEX idx_notifications_meetup_id ON public.notifications(meetup_id) WHERE meetup_id IS NOT NULL;

-- notification_events
CREATE TABLE public.notification_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id uuid NOT NULL REFERENCES public.notifications(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN ('sent', 'delivered', 'opened', 'screen_viewed', 'action_completed', 'dismissed')),
  screen text,
  occurred_at timestamptz NOT NULL,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_notification_events_notification_id ON public.notification_events(notification_id);
CREATE INDEX idx_notification_events_user_id ON public.notification_events(user_id);

-- RLS
ALTER TABLE public.notification_scenarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY notification_scenarios_select ON public.notification_scenarios FOR SELECT TO authenticated USING (true);

CREATE POLICY notifications_select ON public.notifications FOR SELECT USING (public.get_user_profile_id() = user_id);
-- No write policy: notifications are created/updated only by service_role (send pipeline).

CREATE POLICY notification_events_select ON public.notification_events FOR SELECT USING (public.get_user_profile_id() = user_id);
CREATE POLICY notification_events_insert ON public.notification_events FOR INSERT
  WITH CHECK (
    public.get_user_profile_id() = user_id
    AND public.get_user_profile_id() = (SELECT user_id FROM public.notifications WHERE id = notification_id)
  );
