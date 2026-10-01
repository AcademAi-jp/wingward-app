-- ============================================================
-- daily_match_batches: 日次バッチマッチング管理テーブル
-- ============================================================

CREATE TABLE public.daily_match_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_date date NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending', 'matching', 'conversations_running', 'completed', 'failed'
  )),
  total_users integer NOT NULL DEFAULT 0,
  users_matched integer NOT NULL DEFAULT 0,
  total_matches integer NOT NULL DEFAULT 0,
  conversations_completed integer NOT NULL DEFAULT 0,
  conversations_failed integer NOT NULL DEFAULT 0,
  error_message text,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- RLS: service_role のみ（Internal API経由でアクセス）
ALTER TABLE public.daily_match_batches ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- matches テーブルにカラム追加
-- ============================================================

ALTER TABLE public.matches
  ADD COLUMN IF NOT EXISTS batch_id uuid REFERENCES public.daily_match_batches(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS seen_by_a boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS seen_by_b boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_matches_batch_id ON public.matches(batch_id) WHERE batch_id IS NOT NULL;
