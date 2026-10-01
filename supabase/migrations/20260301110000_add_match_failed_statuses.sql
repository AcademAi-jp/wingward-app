-- Add failure-related statuses to matches table
-- fox_conversation_failed: Fox会話が失敗した場合
-- chat_request_expired: チャットリクエストが期限切れになった場合
-- chat_request_declined: チャットリクエストが拒否された場合

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
    'chat_request_declined'
  ));
