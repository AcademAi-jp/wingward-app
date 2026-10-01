-- interaction_dna_scores: per-pair feature scores for 14 compatibility features
-- Each row stores one feature score for a specific match (user pair).
-- Scores are normalized 0.0-1.0 as specified in US-8 design.

CREATE TABLE IF NOT EXISTS public.interaction_dna_scores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  feature_id smallint NOT NULL CHECK (feature_id BETWEEN 1 AND 14),
  feature_name text NOT NULL,
  raw_score numeric(4,3) NOT NULL CHECK (raw_score BETWEEN 0 AND 1),
  normalized_score numeric(4,3) NOT NULL CHECK (normalized_score BETWEEN 0 AND 1),
  confidence numeric(4,3) NOT NULL DEFAULT 0.5 CHECK (confidence BETWEEN 0 AND 1),
  evidence jsonb NOT NULL DEFAULT '{}',
  source_phase text NOT NULL CHECK (source_phase IN ('quiz', 'speed_dating', 'fox_conversation', 'partner_fox_chat', 'direct_chat')),
  computed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(match_id, feature_id, source_phase)
);

CREATE INDEX IF NOT EXISTS idx_dna_scores_match_id ON public.interaction_dna_scores(match_id);
CREATE INDEX IF NOT EXISTS idx_dna_scores_feature_id ON public.interaction_dna_scores(feature_id);
CREATE INDEX IF NOT EXISTS idx_dna_scores_match_feature ON public.interaction_dna_scores(match_id, feature_id);

-- RLS
ALTER TABLE public.interaction_dna_scores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS interaction_dna_scores_select ON public.interaction_dna_scores;
CREATE POLICY interaction_dna_scores_select ON public.interaction_dna_scores FOR SELECT
  USING (public.get_user_profile_id() IN (
    SELECT user_a_id FROM public.matches WHERE id = match_id
    UNION ALL
    SELECT user_b_id FROM public.matches WHERE id = match_id
  ));

-- Add layer_scores column to matches for caching 3-layer structure
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS layer_scores jsonb DEFAULT '{}';
