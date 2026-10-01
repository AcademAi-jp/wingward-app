-- ============================================================
-- Replace daily_match_batches with daily_match_pairs
-- ============================================================

DROP INDEX IF EXISTS idx_matches_batch_id;

ALTER TABLE public.matches
	DROP COLUMN IF EXISTS batch_id,
	DROP COLUMN IF EXISTS seen_by_a,
	DROP COLUMN IF EXISTS seen_by_b;

DROP TABLE IF EXISTS public.daily_match_batches;

CREATE TABLE IF NOT EXISTS public.daily_match_pairs (
	match_id uuid PRIMARY KEY REFERENCES public.matches(id) ON DELETE CASCADE,
	match_date date NOT NULL,
	created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_daily_match_pairs_match_date
	ON public.daily_match_pairs(match_date);
