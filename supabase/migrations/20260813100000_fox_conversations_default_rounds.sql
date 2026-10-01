-- step-03d D-1: fox_conversations.total_rounds default 15 -> 10
-- The production path (FoxConversationDO) has always hardcoded 10 rounds; the
-- column default of 15 (see 20260228100000_initial_schema.sql) never matched
-- what actually ran. See docs/spec/impl/step-03d-unify-conversation-loop.md.
-- No existing-row UPDATE: Wingward has not been deployed yet, so there are no
-- rows to backfill.

ALTER TABLE public.fox_conversations ALTER COLUMN total_rounds SET DEFAULT 10;
