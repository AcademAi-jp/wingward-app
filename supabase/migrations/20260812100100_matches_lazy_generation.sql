-- M2: matches lazy Fox-conversation generation tracking + meetup statuses
-- See docs/spec/wingward-implementation-scope.md §3-2 and docs/spec/impl/step-01-migrations-rls.md §4 (M2)

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS fox_conversation_requested_at timestamptz,
  ADD COLUMN IF NOT EXISTS fox_conversation_requested_by uuid REFERENCES public.user_profiles(id);

ALTER TABLE public.matches
  DROP CONSTRAINT IF EXISTS matches_status_check,
  ADD CONSTRAINT matches_status_check CHECK (status IN (
    'pending',
    'fox_conversation_in_progress',
    'fox_conversation_completed',
    'fox_conversation_failed',
    'partner_chat_started',
    'direct_chat_requested',
    'direct_chat_active',
    'chat_request_expired',
    'chat_request_declined',
    'meetup_intent',
    'meetup_confirmed'
  ));

CREATE INDEX IF NOT EXISTS idx_matches_fox_conversation_requested_by ON public.matches(fox_conversation_requested_by) WHERE fox_conversation_requested_by IS NOT NULL;
