-- M6: usage_counters, entitlements + RLS
-- See docs/spec/wingward-implementation-scope.md §3-5 and docs/spec/impl/step-01-migrations-rls.md §4 (M6), §5

-- usage_counters: free-quota consumption. Writes are service_role only (tamper prevention).
CREATE TABLE public.usage_counters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  quota_key text NOT NULL CHECK (quota_key IN ('fox_conversation', 'partner_fox_chat', 'direct_chat_slot', 'meetup_arrange', 'arrange_retry')),
  period_start date NOT NULL,
  period_end date NOT NULL,
  used_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, quota_key, period_start)
);
CREATE INDEX idx_usage_counters_user_id ON public.usage_counters(user_id);

-- entitlements: RevenueCat webhook mirror (RevenueCat itself remains the source of truth).
CREATE TABLE public.entitlements (
  user_id uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  is_active boolean NOT NULL DEFAULT false,
  product_id text,
  store text,
  current_period_end timestamptz,
  rc_app_user_id text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- RLS
ALTER TABLE public.usage_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entitlements ENABLE ROW LEVEL SECURITY;

CREATE POLICY usage_counters_select ON public.usage_counters FOR SELECT USING (public.get_user_profile_id() = user_id);
-- No write policy: only service_role (quota consumption/reset) may write.

CREATE POLICY entitlements_select ON public.entitlements FOR SELECT USING (public.get_user_profile_id() = user_id);
-- No write policy: only service_role (RevenueCat webhook mirror) may write.
