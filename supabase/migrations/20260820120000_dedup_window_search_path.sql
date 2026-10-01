-- Pins `public.notification_dedup_window`'s search_path.
--
-- Supabase's database linter flagged it as `function_search_path_mutable`
-- immediately after 20260820100000 was applied to the hosted project. The
-- function was created without `SET search_path`, so it resolves `tstzrange`
-- and the timestamptz `+` operator through whatever search_path the calling
-- role happens to have.
--
-- That matters more here than it would for an ordinary helper, because this
-- function is the index expression of the `notifications_dedup_window_excl`
-- exclusion constraint. A function whose resolution depends on the caller's
-- search_path is, in principle, not the immutable function the index was
-- built on — and an index built on one definition and probed under another
-- is silently wrong rather than loudly broken.
--
-- `SET search_path = ''` plus fully-qualified `pg_catalog` names removes the
-- dependency entirely. The body is otherwise unchanged, so the index stays
-- valid: CREATE OR REPLACE is safe precisely because the computed value for
-- any given input is identical.
CREATE OR REPLACE FUNCTION public.notification_dedup_window(ts timestamptz)
  RETURNS tstzrange
  LANGUAGE sql
  IMMUTABLE
  STRICT
  PARALLEL SAFE
  SET search_path = ''
AS $$
  SELECT pg_catalog.tstzrange(ts, ts + pg_catalog.interval '24 hours');
$$;

-- CREATE OR REPLACE resets nothing about privileges, but restate them so this
-- file is self-contained if it is ever replayed onto a fresh database (M10:
-- naming the roles matters on hosted Supabase, where anon/authenticated hold
-- their own default grants that a REVOKE on PUBLIC does not touch).
REVOKE ALL ON FUNCTION public.notification_dedup_window(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notification_dedup_window(timestamptz) TO service_role;
