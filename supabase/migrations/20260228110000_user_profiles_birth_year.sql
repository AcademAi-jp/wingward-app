-- Add birth_year to user_profiles for 誕生年 (birth year) registration
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS birth_year integer CHECK (birth_year >= 1900 AND birth_year <= 2100);

COMMENT ON COLUMN public.user_profiles.birth_year IS 'User birth year (e.g. 1990) for age display.';
