-- Allow authenticated users to create their own user_profiles row (first-time sign up).
-- API uses service_role and bypasses RLS; this policy helps client-side or other anon-key usage.
CREATE POLICY user_profiles_insert ON public.user_profiles FOR INSERT
  WITH CHECK ((SELECT auth.uid()) = auth_user_id);
