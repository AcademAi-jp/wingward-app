-- M8: explicit table grants (least privilege).
-- GRANT provides the verb; RLS filters the rows. Both are required.
-- This environment's default privileges do not include the standard Supabase grants,
-- so we grant explicitly instead of relying on defaults.
-- anon gets nothing: every feature requires an authenticated user.

-- service_role: full access (API/batch role; bypasses RLS by design).
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;

-- authenticated: verbs used by RLS policies. Row filtering is enforced by RLS;
-- tables without a policy for a verb still deny it (default-deny), so granting
-- the verb here does not widen access beyond the policies.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;

-- Future tables created by postgres inherit the same grants.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
