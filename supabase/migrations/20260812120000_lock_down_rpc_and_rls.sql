-- M10: close two holes that only appear on hosted Supabase, not locally.
--
-- Found by the Supabase database linter on the freshly created cloud project
-- (2026-08-12), against a schema that looked correct locally.
--
-- (1) QUOTA RPC BYPASS.
-- M9 already ran `REVOKE ALL ON FUNCTION ... FROM PUBLIC`, which is enough in
-- the local stack. It is NOT enough on hosted Supabase: there, `anon` and
-- `authenticated` hold their own EXECUTE grants on functions in `public`
-- (from the platform's default privileges), and revoking PUBLIC does not
-- touch a role's own grant. The linter confirmed both roles could execute
-- consume_quota and refund_quota through /rest/v1/rpc/.
--
-- That is a direct paywall bypass: `consume_quota` takes `p_limit` as an
-- argument, so a signed-in user could call it with any limit they liked, and
-- `refund_quota` could hand back the count afterwards. Fox conversations are
-- the app's dominant variable cost, so this defeats the entire free-tier
-- quota built in step 3-A. Both functions are only ever called by the API
-- with the service_role key.
--
-- (2) daily_match_pairs had no RLS.
-- Every other table enables it; this one was missed at creation. M8 grants
-- authenticated SELECT/INSERT/UPDATE/DELETE on ALL tables in public, and with
-- RLS off there is nothing left to filter rows.

-- ── (1) RPC execution: service_role only ────────────────────────────────────
-- Revoke from the roles by name, not just PUBLIC. Order matters only in that
-- the service_role grant must survive; it is re-granted below to be explicit.
REVOKE ALL ON FUNCTION public.consume_quota(uuid, text, date, date, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.refund_quota(uuid, text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consume_quota(uuid, text, date, date, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.refund_quota(uuid, text, date) TO service_role;

-- get_user_profile_id() is different: it is called inside RLS policies (28
-- references in the M2 policy file), and policy expressions are evaluated as
-- the querying role. `authenticated` therefore MUST keep EXECUTE or every one
-- of those policies breaks. `anon` holds no table grants at all (M8: "anon
-- gets nothing"), so it has no legitimate use for it.
REVOKE ALL ON FUNCTION public.get_user_profile_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_profile_id() TO authenticated, service_role;

-- Narrow the default grants for functions created by postgres in `public`.
--
-- IMPORTANT — this does NOT give default-deny, and must not be relied on as
-- if it did. Measured on the hosted project: after running both of these,
-- a freshly created function still comes out with
--   proacl = {=X/postgres, postgres=X/postgres, service_role=X/postgres}
-- i.e. `=X` — EXECUTE for PUBLIC, which anon and authenticated inherit.
-- Postgres' built-in default grant to PUBLIC survived the revoke here, in a
-- standalone statement and its own transaction. The statements below are kept
-- because they do remove the two roles' own default grants, which is strictly
-- better than nothing, but they are not the control.
--
-- The actual control is per function: every SECURITY DEFINER function added to
-- `public` must ship its own REVOKE naming PUBLIC, anon and authenticated, the
-- way the two above do. That rule is enforced mechanically by
-- apps/api/src/lib/lazy-fox-conversation-wiring.test.ts, which fails the build
-- if a migration defines such a function without one.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

-- ── (2) daily_match_pairs: default-deny ─────────────────────────────────────
-- No policy is added on purpose. The table is written and read only by the
-- daily batch through service_role, which bypasses RLS; with RLS enabled and
-- no policy, anon and authenticated are denied by default.
ALTER TABLE public.daily_match_pairs ENABLE ROW LEVEL SECURITY;
