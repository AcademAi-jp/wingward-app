-- B1-A: make age verification and user profile creation server-owned.

-- Auth signup is the only profile creation source. The trigger is deliberately
-- SECURITY DEFINER so it can insert through user_profiles RLS while keeping
-- the function's name resolution deterministic.
CREATE OR REPLACE FUNCTION public.handle_new_user_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.user_profiles (auth_user_id, nickname)
  VALUES (NEW.id, 'User')
  ON CONFLICT (auth_user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.handle_new_user_profile() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS user_profiles_after_auth_insert ON auth.users;
CREATE TRIGGER user_profiles_after_auth_insert
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user_profile();

-- The trigger covers future signups; repair any auth users created before this
-- migration whose profile row is missing.  This is deliberately a NULL-only
-- backfill: it never overwrites an existing profile or imports age fields, and
-- the unique-key guard makes reruns/concurrent provisioning idempotent.
INSERT INTO public.user_profiles (auth_user_id, nickname)
SELECT u.id, 'User'
FROM auth.users AS u
LEFT JOIN public.user_profiles AS p ON p.auth_user_id = u.id
WHERE p.auth_user_id IS NULL
ON CONFLICT (auth_user_id) DO NOTHING;

-- Direct authenticated writes are no longer part of the signup or profile
-- update path. The API uses service_role and the trigger uses its definer.
DROP POLICY IF EXISTS user_profiles_insert ON public.user_profiles;
DROP POLICY IF EXISTS user_profiles_update ON public.user_profiles;
REVOKE INSERT, UPDATE ON TABLE public.user_profiles FROM authenticated;

-- Values written before the server-owned age-verification path are
-- untrusted, including vendor-provided values whose provenance cannot be
-- proven. Reset every legacy verification field before the helper below can
-- trust age_verified_at for authorization decisions.
UPDATE public.user_profiles
SET birth_date = NULL,
    age_verified_at = NULL,
    age_verification_method = NULL
WHERE birth_date IS NOT NULL
   OR age_verified_at IS NOT NULL
   OR age_verification_method IS NOT NULL;

-- RLS helper functions must not resolve an unverified profile as the caller.
CREATE OR REPLACE FUNCTION public.get_user_profile_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT id
  FROM public.user_profiles
  WHERE auth_user_id = (SELECT auth.uid())
    AND age_verified_at IS NOT NULL
$$;

-- Existing matches survive the profile reset above.  A caller that has
-- verified only their own age must not be able to use one of those rows as a
-- bridge to the other participant's profile, persona, conversation, or
-- notification.  Keep this check in a SECURITY DEFINER function so it can
-- inspect both profiles under RLS without exposing match existence through a
-- direct RPC call: the caller must be one of the match's auth users, and a
-- missing match/profile simply produces false.
CREATE OR REPLACE FUNCTION public.are_match_participants_age_verified(p_match_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.matches AS m
    JOIN public.user_profiles AS first_profile ON first_profile.id = m.user_a_id
    JOIN public.user_profiles AS second_profile ON second_profile.id = m.user_b_id
    WHERE m.id = p_match_id
      AND (
        first_profile.auth_user_id = (SELECT auth.uid())
        OR second_profile.auth_user_id = (SELECT auth.uid())
      )
      AND first_profile.age_verified_at IS NOT NULL
      AND second_profile.age_verified_at IS NOT NULL
  )
$$;

REVOKE ALL ON FUNCTION public.are_match_participants_age_verified(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.are_match_participants_age_verified(uuid) TO authenticated, service_role;

-- Match-derived reads/writes retain their original ownership and intent
-- hiding predicates, with the shared counterparty gate added.  The two
-- client INSERT policies deliberately dropped by
-- 20260821100000_blocked_pair_invariant.sql are not recreated here.

-- matches
DROP POLICY IF EXISTS matches_select ON public.matches;
CREATE POLICY matches_select ON public.matches FOR SELECT
  USING (
    public.get_user_profile_id() IN (user_a_id, user_b_id)
    AND public.are_match_participants_age_verified(id)
  );

-- interaction DNA scores
DROP POLICY IF EXISTS interaction_dna_scores_select ON public.interaction_dna_scores;
CREATE POLICY interaction_dna_scores_select ON public.interaction_dna_scores FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = match_id
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = match_id
    )
    AND public.are_match_participants_age_verified(match_id)
  );

-- Fox conversation and partner-Fox rows
DROP POLICY IF EXISTS fox_conversations_select ON public.fox_conversations;
CREATE POLICY fox_conversations_select ON public.fox_conversations FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = match_id
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = match_id
    )
    AND public.are_match_participants_age_verified(match_id)
  );

DROP POLICY IF EXISTS fox_conversation_messages_select ON public.fox_conversation_messages;
CREATE POLICY fox_conversation_messages_select ON public.fox_conversation_messages FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.fox_conversations WHERE id = conversation_id)
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.fox_conversations WHERE id = conversation_id)
    )
    AND public.are_match_participants_age_verified(
      (SELECT match_id FROM public.fox_conversations WHERE id = conversation_id)
    )
  );

DROP POLICY IF EXISTS partner_fox_chats_select ON public.partner_fox_chats;
CREATE POLICY partner_fox_chats_select ON public.partner_fox_chats FOR SELECT
  USING (
    public.get_user_profile_id() = user_id
    AND public.are_match_participants_age_verified(match_id)
  );

DROP POLICY IF EXISTS partner_fox_chats_insert ON public.partner_fox_chats;
CREATE POLICY partner_fox_chats_insert ON public.partner_fox_chats FOR INSERT
  WITH CHECK (
    public.get_user_profile_id() = user_id
    AND public.are_match_participants_age_verified(match_id)
  );

DROP POLICY IF EXISTS partner_fox_messages_select ON public.partner_fox_messages;
CREATE POLICY partner_fox_messages_select ON public.partner_fox_messages FOR SELECT
  USING (
    public.get_user_profile_id() = (SELECT user_id FROM public.partner_fox_chats WHERE id = chat_id)
    AND public.are_match_participants_age_verified(
      (SELECT match_id FROM public.partner_fox_chats WHERE id = chat_id)
    )
  );

DROP POLICY IF EXISTS partner_fox_messages_insert ON public.partner_fox_messages;
CREATE POLICY partner_fox_messages_insert ON public.partner_fox_messages FOR INSERT
  WITH CHECK (
    public.get_user_profile_id() = (SELECT user_id FROM public.partner_fox_chats WHERE id = chat_id)
    AND public.are_match_participants_age_verified(
      (SELECT match_id FROM public.partner_fox_chats WHERE id = chat_id)
    )
  );

-- Chat requests: preserve participant visibility and responder-only updates.
-- There is intentionally no chat_requests_insert policy here.
DROP POLICY IF EXISTS chat_requests_select ON public.chat_requests;
CREATE POLICY chat_requests_select ON public.chat_requests FOR SELECT
  USING (
    public.get_user_profile_id() IN (requester_id, responder_id)
    AND public.are_match_participants_age_verified(match_id)
  );

DROP POLICY IF EXISTS chat_requests_update ON public.chat_requests;
CREATE POLICY chat_requests_update ON public.chat_requests FOR UPDATE
  USING (
    public.get_user_profile_id() = responder_id
    AND public.are_match_participants_age_verified(match_id)
  )
  WITH CHECK (
    public.get_user_profile_id() = responder_id
    AND public.are_match_participants_age_verified(match_id)
  );

-- Direct chat rows.  The client INSERT policy was removed by the blocked-pair
-- migration and remains absent; API writes use service_role.
DROP POLICY IF EXISTS direct_chat_rooms_select ON public.direct_chat_rooms;
CREATE POLICY direct_chat_rooms_select ON public.direct_chat_rooms FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = match_id
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = match_id
    )
    AND public.are_match_participants_age_verified(match_id)
  );

DROP POLICY IF EXISTS direct_chat_messages_select ON public.direct_chat_messages;
CREATE POLICY direct_chat_messages_select ON public.direct_chat_messages FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.direct_chat_rooms WHERE id = room_id)
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.direct_chat_rooms WHERE id = room_id)
    )
    AND public.are_match_participants_age_verified(
      (SELECT match_id FROM public.direct_chat_rooms WHERE id = room_id)
    )
  );

-- Meetups and proposal responses retain the intent-pending hiding rule and
-- self-only response ownership while requiring an age-verified pair.
DROP POLICY IF EXISTS meetups_select ON public.meetups;
CREATE POLICY meetups_select ON public.meetups FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = match_id
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = match_id
    )
    AND public.are_match_participants_age_verified(match_id)
    AND (status <> 'intent_pending' OR initiator_id = public.get_user_profile_id())
  );

DROP POLICY IF EXISTS meetups_insert ON public.meetups;
CREATE POLICY meetups_insert ON public.meetups FOR INSERT
  WITH CHECK (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = match_id
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = match_id
    )
    AND public.are_match_participants_age_verified(match_id)
    AND status = 'intent_pending'
    AND initiator_id = public.get_user_profile_id()
  );

DROP POLICY IF EXISTS meetup_proposals_select ON public.meetup_proposals;
CREATE POLICY meetup_proposals_select ON public.meetup_proposals FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
    )
    AND public.are_match_participants_age_verified(
      (SELECT match_id FROM public.meetups WHERE id = meetup_id)
    )
  );

DROP POLICY IF EXISTS meetup_proposal_responses_select ON public.meetup_proposal_responses;
CREATE POLICY meetup_proposal_responses_select ON public.meetup_proposal_responses FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
    )
    AND public.are_match_participants_age_verified(
      (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
    )
  );

DROP POLICY IF EXISTS meetup_proposal_responses_insert ON public.meetup_proposal_responses;
CREATE POLICY meetup_proposal_responses_insert ON public.meetup_proposal_responses FOR INSERT
  WITH CHECK (
    public.get_user_profile_id() = user_id
    AND public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
    )
    AND public.are_match_participants_age_verified(
      (SELECT match_id FROM public.meetups WHERE id = (SELECT meetup_id FROM public.meetup_proposals WHERE id = proposal_id))
    )
  );

-- Venue check-ins are match-linked; feedback is deliberately self-only and
-- is not widened by this migration.
DROP POLICY IF EXISTS venue_checkins_select ON public.venue_checkins;
CREATE POLICY venue_checkins_select ON public.venue_checkins FOR SELECT
  USING (
    public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
    )
    AND public.are_match_participants_age_verified(
      (SELECT match_id FROM public.meetups WHERE id = meetup_id)
    )
  );

DROP POLICY IF EXISTS venue_checkins_insert ON public.venue_checkins;
CREATE POLICY venue_checkins_insert ON public.venue_checkins FOR INSERT
  WITH CHECK (
    public.get_user_profile_id() = user_id
    AND public.get_user_profile_id() IN (
      SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
      UNION ALL
      SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.meetups WHERE id = meetup_id)
    )
    AND public.are_match_participants_age_verified(
      (SELECT match_id FROM public.meetups WHERE id = meetup_id)
    )
  );

-- Match-linked notifications/events remain self-owned, with the pair gate
-- applied only when the notification carries a match_id.
DROP POLICY IF EXISTS notifications_select ON public.notifications;
CREATE POLICY notifications_select ON public.notifications FOR SELECT
  USING (
    public.get_user_profile_id() = user_id
    AND (
      match_id IS NULL
      OR public.are_match_participants_age_verified(match_id)
    )
  );

DROP POLICY IF EXISTS notification_events_select ON public.notification_events;
CREATE POLICY notification_events_select ON public.notification_events FOR SELECT
  USING (
    public.get_user_profile_id() = user_id
    AND EXISTS (
      SELECT 1
      FROM public.notifications AS n
      WHERE n.id = notification_id
        AND public.get_user_profile_id() = n.user_id
        AND (
          n.match_id IS NULL
          OR public.are_match_participants_age_verified(n.match_id)
        )
    )
  );

DROP POLICY IF EXISTS notification_events_insert ON public.notification_events;
CREATE POLICY notification_events_insert ON public.notification_events FOR INSERT
  WITH CHECK (
    event_type <> 'sent'
    AND public.get_user_profile_id() = user_id
    AND EXISTS (
      SELECT 1
      FROM public.notifications AS n
      WHERE n.id = notification_id
        AND public.get_user_profile_id() = n.user_id
        AND (
          n.match_id IS NULL
          OR public.are_match_participants_age_verified(n.match_id)
        )
    )
  );
