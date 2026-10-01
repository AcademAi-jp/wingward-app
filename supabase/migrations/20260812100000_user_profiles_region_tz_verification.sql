-- M1: user_profiles region/timezone/age+identity verification/suspension columns
-- See docs/spec/wingward-implementation-scope.md §3-2 and docs/spec/impl/step-01-migrations-rls.md §4 (M1)

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'America/Los_Angeles',
  ADD COLUMN IF NOT EXISTS region text NOT NULL DEFAULT 'US' CHECK (region IN ('US', 'JP')),
  ADD COLUMN IF NOT EXISTS region_subdivision text,
  ADD COLUMN IF NOT EXISTS birth_date date,
  ADD COLUMN IF NOT EXISTS age_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS age_verification_method text CHECK (age_verification_method IN ('self_declared', 'platform_attested', 'vendor')),
  ADD COLUMN IF NOT EXISTS identity_verified_at timestamptz,
  ADD COLUMN IF NOT EXISTS identity_subject_hash text,
  ADD COLUMN IF NOT EXISTS identity_verification_status text NOT NULL DEFAULT 'none' CHECK (identity_verification_status IN ('none', 'pending', 'verified', 'failed', 'expired')),
  ADD COLUMN IF NOT EXISTS no_show_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS suspended_until timestamptz,
  ADD COLUMN IF NOT EXISTS suspended_reason text;

COMMENT ON COLUMN public.user_profiles.birth_year IS 'Deprecated: superseded by birth_date (year alone is insufficient for 18+ verification). Kept until callers are migrated (Track B); do not use for new code.';
COMMENT ON COLUMN public.user_profiles.timezone IS 'IANA timezone name. Basis for notification send time and quiet hours.';
COMMENT ON COLUMN public.user_profiles.region IS 'Regulatory bundle (US/JP). Not a 1:1 mapping with timezone.';
COMMENT ON COLUMN public.user_profiles.identity_subject_hash IS 'Hash of the identity vendor subject reference only. Never store raw identity document data here.';
