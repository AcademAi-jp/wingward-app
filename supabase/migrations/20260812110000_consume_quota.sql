-- M9: atomic quota consumption for lazy fox-conversation generation
-- See docs/spec/impl (step-3a security impact report) §4: the JS supabase
-- client cannot express "increment usage_counters.used_count only if it is
-- still under the limit, tell me if it happened" as a single statement — the
-- `.upsert()` builder can only set a literal value on conflict and cannot
-- attach a WHERE clause to the DO UPDATE branch. This function does it
-- server-side in one round trip, so two concurrent requests for the same
-- (user_id, quota_key, period_start) can never both succeed past the limit.
--
-- usage_counters has no INSERT/UPDATE RLS policy (see 20260812100500_billing_quota.sql):
-- only service_role may write it. This function is SECURITY DEFINER for the
-- same reason get_user_profile_id() is (20260228100001_helper_function.sql) —
-- consistency with the rest of the schema — but note the API always calls it
-- with the service_role key already, so RLS is bypassed regardless; this
-- function is not itself the enforcement boundary against a malicious
-- Postgres client, it exists to make the increment atomic.

CREATE OR REPLACE FUNCTION public.consume_quota(
  p_user_id uuid,
  p_quota_key text,
  p_period_start date,
  p_period_end date,
  p_limit integer
) RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.usage_counters (user_id, quota_key, period_start, period_end, used_count)
  VALUES (p_user_id, p_quota_key, p_period_start, p_period_end, 1)
  ON CONFLICT (user_id, quota_key, period_start)
  DO UPDATE SET
    used_count = public.usage_counters.used_count + 1,
    updated_at = now()
  WHERE public.usage_counters.used_count < p_limit
  RETURNING used_count;
$$;

COMMENT ON FUNCTION public.consume_quota IS
  'Atomically increments usage_counters.used_count for (user_id, quota_key, period_start), '
  'creating the row on first use. Returns the new used_count, or NULL (no row returned) when '
  'the existing row is already at or above p_limit. Callers must treat NULL as "quota '
  'exhausted" and must not leak p_limit or the current used_count back to the client.';

-- Compensating decrement for a consume_quota call whose matching action then
-- failed (e.g. the Durable Object failed to start after quota was already
-- spent). Only ever called by the API immediately after its own consume_quota
-- call in the same request; never exposed as a user-facing action.
CREATE OR REPLACE FUNCTION public.refund_quota(
  p_user_id uuid,
  p_quota_key text,
  p_period_start date
) RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.usage_counters
  SET used_count = GREATEST(used_count - 1, 0), updated_at = now()
  WHERE user_id = p_user_id AND quota_key = p_quota_key AND period_start = p_period_start;
$$;

COMMENT ON FUNCTION public.refund_quota IS
  'Compensating decrement for consume_quota, floored at 0. Used when the action a quota unit '
  'was consumed for could not actually be completed.';

REVOKE ALL ON FUNCTION public.consume_quota(uuid, text, date, date, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_quota(uuid, text, date, date, integer) TO service_role;

REVOKE ALL ON FUNCTION public.refund_quota(uuid, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_quota(uuid, text, date) TO service_role;
