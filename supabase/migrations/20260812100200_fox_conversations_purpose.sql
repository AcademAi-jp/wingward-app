-- M3: fox_conversations purpose (compatibility vs scheduling reuse) + token cost tracking
-- See docs/spec/wingward-implementation-scope.md §3-2 and docs/spec/impl/step-01-migrations-rls.md §4 (M3)
--
-- Note: meetup_id references public.meetups(id), but meetups is created in M4. The column is
-- added here without a foreign key; the FK is attached in M4 once the meetups table exists.

ALTER TABLE public.fox_conversations
  ADD COLUMN IF NOT EXISTS purpose text NOT NULL DEFAULT 'compatibility' CHECK (purpose IN ('compatibility', 'scheduling')),
  ADD COLUMN IF NOT EXISTS meetup_id uuid,
  ADD COLUMN IF NOT EXISTS cache_hit_tokens integer,
  ADD COLUMN IF NOT EXISTS input_tokens integer,
  ADD COLUMN IF NOT EXISTS output_tokens integer;

-- Replace the 1:1 match_id UNIQUE with a partial UNIQUE scoped to the compatibility
-- conversation, so a match can also have N scheduling conversations.
DROP INDEX IF EXISTS public.idx_fox_conversations_match_id;
ALTER TABLE public.fox_conversations DROP CONSTRAINT IF EXISTS fox_conversations_match_id_key;
CREATE UNIQUE INDEX fox_conversations_match_id_compatibility_key ON public.fox_conversations(match_id) WHERE purpose = 'compatibility';
CREATE INDEX IF NOT EXISTS idx_fox_conversations_match_id ON public.fox_conversations(match_id);
CREATE INDEX IF NOT EXISTS idx_fox_conversations_meetup_id ON public.fox_conversations(meetup_id) WHERE meetup_id IS NOT NULL;
