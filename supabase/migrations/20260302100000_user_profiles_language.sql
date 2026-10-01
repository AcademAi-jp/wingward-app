-- Add language preference to user_profiles for prompt language selection.
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS language text;
-- Ensure default language is Japanese for new users.
ALTER TABLE public.user_profiles
  ALTER COLUMN language SET DEFAULT 'ja';
-- Backfill existing rows and enforce non-null.
UPDATE public.user_profiles
SET language = 'ja'
WHERE language IS NULL;
ALTER TABLE public.user_profiles
  ALTER COLUMN language SET NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'user_profiles_language_check'
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT user_profiles_language_check
      CHECK (language IN ('ja', 'en'));
  END IF;
END $$;
COMMENT ON COLUMN public.user_profiles.language IS 'Preferred UI language ("ja" | "en").';
