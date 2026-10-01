-- Add icon_url to personas for MyPersona generated avatar.
-- Storage: create bucket "persona-icons" (public) in Supabase Dashboard if not exists.
ALTER TABLE public.personas
  ADD COLUMN IF NOT EXISTS icon_url text;
