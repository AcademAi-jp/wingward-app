-- Allow users to insert their own profile row (e.g. first-time generation via POST /api/profiles/generate)
DROP POLICY IF EXISTS profiles_insert ON public.profiles;
CREATE POLICY profiles_insert ON public.profiles FOR INSERT
  WITH CHECK (public.get_user_profile_id() = user_id);
