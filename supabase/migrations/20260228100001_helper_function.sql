-- get_user_profile_id: maps auth.uid() to user_profiles.id for RLS
CREATE OR REPLACE FUNCTION public.get_user_profile_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT id FROM public.user_profiles WHERE auth_user_id = (SELECT auth.uid())
$$;
