-- M7: venues, venue_checkins, meetup_feedback (S3 closed-verification scope; schema-only,
-- API/app routes stay flagged off for public builds) + RLS
-- See docs/spec/wingward-implementation-scope.md §3-6 and docs/spec/impl/step-01-migrations-rls.md §4 (M7), §5

-- venues: precise location is allowed here (a venue's location is not personal data).
CREATE TABLE public.venues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  region text NOT NULL CHECK (region IN ('US', 'JP')),
  region_subdivision text,
  city text,
  timezone text NOT NULL,
  latitude numeric,
  longitude numeric,
  geofence_radius_m integer,
  recommended_slots jsonb NOT NULL DEFAULT '{}',
  slots_source text CHECK (slots_source IN ('venue_declared', 'public_data', 'measured')),
  referral_rate numeric,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_venues_is_active ON public.venues(is_active) WHERE is_active = true;

-- Now that venues exists, attach the meetups.venue_id FK (column added in M4).
ALTER TABLE public.meetups
  ADD CONSTRAINT meetups_venue_id_fkey FOREIGN KEY (venue_id) REFERENCES public.venues(id) ON DELETE SET NULL;

-- venue_checkins: no latitude/longitude columns — geofence check happens on-device, only a
-- boolean result is sent.
CREATE TABLE public.venue_checkins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meetup_id uuid NOT NULL REFERENCES public.meetups(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  venue_id uuid REFERENCES public.venues(id),
  method text NOT NULL CHECK (method IN ('geofence', 'mutual_code', 'receipt')),
  verified boolean NOT NULL DEFAULT false,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  evidence_ref text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_venue_checkins_meetup_id ON public.venue_checkins(meetup_id);
CREATE INDEX idx_venue_checkins_user_id ON public.venue_checkins(user_id);

-- meetup_feedback: never visible to the other party, even though both are meetup participants.
CREATE TABLE public.meetup_feedback (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meetup_id uuid NOT NULL REFERENCES public.meetups(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  impression jsonb,
  want_to_meet_again boolean,
  proposal_was_good boolean,
  free_text text,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(meetup_id, user_id)
);
CREATE INDEX idx_meetup_feedback_meetup_id ON public.meetup_feedback(meetup_id);

-- RLS
ALTER TABLE public.venues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.venue_checkins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetup_feedback ENABLE ROW LEVEL SECURITY;

CREATE POLICY venues_select ON public.venues FOR SELECT TO authenticated USING (is_active = true);

CREATE POLICY venue_checkins_select ON public.venue_checkins FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
    )
  );
CREATE POLICY venue_checkins_insert ON public.venue_checkins FOR INSERT
  WITH CHECK (
    public.get_user_profile_id() = user_id
    AND public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
    )
  );

-- meetup_feedback: strictly self-authored rows only, even for the other participant.
CREATE POLICY meetup_feedback_select ON public.meetup_feedback FOR SELECT USING (public.get_user_profile_id() = user_id);
CREATE POLICY meetup_feedback_insert ON public.meetup_feedback FOR INSERT WITH CHECK (public.get_user_profile_id() = user_id);
-- No UPDATE policy: not writable after submission.
