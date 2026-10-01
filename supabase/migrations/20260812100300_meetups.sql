-- M4: meetups, meetup_preferences, meetup_proposals, meetup_proposal_responses + RLS
-- See docs/spec/wingward-implementation-scope.md §3-3 and docs/spec/impl/step-01-migrations-rls.md §4 (M4), §5

-- meetups
CREATE TABLE public.meetups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  initiator_id uuid NOT NULL REFERENCES public.user_profiles(id),
  status text NOT NULL DEFAULT 'intent_pending' CHECK (status IN (
    'intent_pending', 'intent_matched', 'verifying', 'arranging',
    'proposed', 'confirmed', 'checked_in', 'completed',
    'no_show', 'cancelled', 'declined', 'expired', 'arrange_failed'
  )),
  intent_a_at timestamptz,
  intent_b_at timestamptz,
  confirmed_start_at timestamptz,
  confirmed_timezone text,
  area text,
  format text CHECK (format IN ('cafe', 'meal', 'activity', 'online')),
  venue_id uuid,
  intent_expires_at timestamptz,
  proposal_expires_at timestamptz,
  arrange_attempt_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN public.meetups.area IS 'City/ward-grain text only. Do not add latitude/longitude columns here (venues carries precise location).';
COMMENT ON COLUMN public.meetups.venue_id IS 'FK to public.venues added in a later migration once venues exists (S3 scope).';

CREATE INDEX idx_meetups_match_id ON public.meetups(match_id);
CREATE INDEX idx_meetups_initiator_id ON public.meetups(initiator_id);
CREATE INDEX idx_meetups_status ON public.meetups(status);

-- Only one non-terminal meetup per match at a time; retries create new rows (history preserved).
CREATE UNIQUE INDEX meetups_match_id_active_key ON public.meetups(match_id) WHERE status IN (
  'intent_pending', 'intent_matched', 'verifying', 'arranging', 'proposed', 'confirmed', 'checked_in'
);

-- Attach the fox_conversations.meetup_id FK now that meetups exists (column added in M3).
ALTER TABLE public.fox_conversations
  ADD CONSTRAINT fox_conversations_meetup_id_fkey FOREIGN KEY (meetup_id) REFERENCES public.meetups(id) ON DELETE CASCADE;

-- meetup_preferences
CREATE TABLE public.meetup_preferences (
  user_id uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  availability jsonb NOT NULL DEFAULT '{}',
  areas text[] NOT NULL DEFAULT '{}',
  budget_band text,
  formats text[] NOT NULL DEFAULT '{}',
  constraints jsonb NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- meetup_proposals
CREATE TABLE public.meetup_proposals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meetup_id uuid NOT NULL REFERENCES public.meetups(id) ON DELETE CASCADE,
  attempt_number integer NOT NULL DEFAULT 1,
  candidates jsonb NOT NULL,
  area text,
  format text,
  budget_band text,
  rationale text,
  generated_by_conversation_id uuid REFERENCES public.fox_conversations(id),
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_meetup_proposals_meetup_id ON public.meetup_proposals(meetup_id);

-- meetup_proposal_responses
CREATE TABLE public.meetup_proposal_responses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  proposal_id uuid NOT NULL REFERENCES public.meetup_proposals(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id),
  selected_candidate_indexes int[],
  response text,
  responded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(proposal_id, user_id)
);
CREATE INDEX idx_meetup_proposal_responses_proposal_id ON public.meetup_proposal_responses(proposal_id);
CREATE INDEX idx_meetup_proposal_responses_user_id ON public.meetup_proposal_responses(user_id);

-- RLS
ALTER TABLE public.meetups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetup_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetup_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.meetup_proposal_responses ENABLE ROW LEVEL SECURITY;

-- meetups: both parties can see it, EXCEPT while intent_pending, where only the initiator
-- can see it (one-sided intent is not disclosed to the other party).
CREATE POLICY meetups_select ON public.meetups FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = match_id
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = match_id
    )
    AND (status <> 'intent_pending' OR initiator_id = public.get_user_profile_id())
  );

-- meetups: a party may only create an intent_pending row for themselves as initiator.
CREATE POLICY meetups_insert ON public.meetups FOR INSERT
  WITH CHECK (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = match_id
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = match_id
    )
    AND status = 'intent_pending'
    AND initiator_id = public.get_user_profile_id()
  );
-- No UPDATE/DELETE policy: state transitions and expiry are performed by the API (service_role).

-- meetup_preferences: self only, read/write.
CREATE POLICY meetup_preferences_select ON public.meetup_preferences FOR SELECT USING (public.get_user_profile_id() = user_id);
CREATE POLICY meetup_preferences_insert ON public.meetup_preferences FOR INSERT WITH CHECK (public.get_user_profile_id() = user_id);
CREATE POLICY meetup_preferences_update ON public.meetup_preferences FOR UPDATE USING (public.get_user_profile_id() = user_id);

-- meetup_proposals: read-only for the meetup's two parties; Fox/API (service_role) writes.
CREATE POLICY meetup_proposals_select ON public.meetup_proposals FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
    )
  );

-- meetup_proposal_responses: the two parties can see both responses; each user can only insert their own.
CREATE POLICY meetup_proposal_responses_select ON public.meetup_proposal_responses FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
    )
  );
CREATE POLICY meetup_proposal_responses_insert ON public.meetup_proposal_responses FOR INSERT
  WITH CHECK (
    public.get_user_profile_id() = user_id
    AND public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
    )
  );
