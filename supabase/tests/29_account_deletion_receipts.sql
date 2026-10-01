-- Synthetic-only acceptance checks for receipt-backed account deletion.
-- The transaction rolls back every Auth/profile/receipt fixture.

BEGIN;
SET LOCAL statement_timeout = '15s';

DO $$
DECLARE
  v_signature text;
  v_oid oid;
  v_definition text;
  v_name text;
BEGIN
  IF to_regclass('wingward_private.account_deletion_operations') IS NULL
     OR to_regclass('wingward_private.account_deletion_intent_limits') IS NULL THEN
    RAISE EXCEPTION 'FAIL SQL29-A: deletion receipt tables are missing';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class
           WHERE oid = 'wingward_private.account_deletion_operations'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class
              WHERE oid = 'wingward_private.account_deletion_intent_limits'::regclass) THEN
    RAISE EXCEPTION 'FAIL SQL29-A: deletion receipt tables must have RLS enabled';
  END IF;
  IF has_schema_privilege('anon', 'wingward_private', 'USAGE')
     OR has_schema_privilege('authenticated', 'wingward_private', 'USAGE')
     OR has_table_privilege('anon', 'wingward_private.account_deletion_operations', 'SELECT')
     OR has_table_privilege('authenticated', 'wingward_private.account_deletion_operations', 'SELECT')
     OR has_table_privilege('anon', 'wingward_private.account_deletion_intent_limits', 'SELECT')
     OR has_table_privilege('authenticated', 'wingward_private.account_deletion_intent_limits', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL SQL29-A: app roles can access private receipt rows';
  END IF;

  FOREACH v_name IN ARRAY ARRAY[
    'read_account_deletion_operation',
    'register_account_deletion_intent',
    'consume_account_deletion_status_rate_limit',
    'claim_account_deletion_operation',
    'release_account_deletion_operation',
    'mark_account_deletion_operation_deleted'
  ] LOOP
    SELECT proc.oid::regprocedure::text INTO v_signature
      FROM pg_catalog.pg_proc AS proc
      JOIN pg_catalog.pg_namespace AS namespace_row ON namespace_row.oid = proc.pronamespace
     WHERE namespace_row.nspname = 'public'
       AND proc.proname = v_name;
    IF v_signature IS NULL THEN
      RAISE EXCEPTION 'FAIL SQL29-B: receipt RPC % is missing', v_name;
    END IF;
    v_oid := to_regprocedure(v_signature);
    SELECT pg_catalog.pg_get_functiondef(v_oid) INTO v_definition;
    IF (SELECT prosecdef FROM pg_catalog.pg_proc WHERE oid = v_oid)
       OR has_function_privilege('anon', v_oid, 'EXECUTE')
       OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'FAIL SQL29-B: receipt RPC % must be invoker-only and service_role-only', v_name;
    END IF;
    IF NOT (SELECT proc.proconfig @> ARRAY['search_path=""']::text[]
              FROM pg_catalog.pg_proc AS proc WHERE proc.oid = v_oid) THEN
      RAISE EXCEPTION 'FAIL SQL29-B: receipt RPC % must use an empty search_path', v_name;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
      FROM pg_catalog.pg_constraint AS constraint_row
     WHERE constraint_row.conrelid = 'wingward_private.account_deletion_operations'::regclass
       AND constraint_row.contype = 'f'
  ) THEN
    RAISE EXCEPTION 'FAIL SQL29-C: deletion receipt rows must survive owner/Auth cascades without FKs';
  END IF;
  RAISE NOTICE 'PASS SQL29-A-C: receipt tables are private, RLS-protected, FK-less, and server-only';
END $$;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-000000002901', 'wingward-sql29-a@example.invalid'),
  ('00000000-0000-0000-0000-000000002902', 'wingward-sql29-b@example.invalid');

UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-000000002901', nickname = 'SQL29 A'
 WHERE auth_user_id = '00000000-0000-0000-0000-000000002901';
UPDATE public.user_profiles
   SET id = '10000000-0000-0000-0000-000000002902', nickname = 'SQL29 B'
 WHERE auth_user_id = '00000000-0000-0000-0000-000000002902';

SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_row record;
  v_allowed boolean;
  v_claim_token uuid := '20000000-0000-0000-0000-000000002901';
  v_index integer;
BEGIN
  SELECT * INTO v_row
    FROM public.register_account_deletion_intent(
      '30000000-0000-0000-0000-000000002901',
      '10000000-0000-0000-0000-000000002901',
      '00000000-0000-0000-0000-000000002901',
      repeat('a', 64)
    );
  IF v_row.result <> 'created' OR v_row.status <> 'pending'
     OR v_row.expires_at <= pg_catalog.now()
     OR v_row.expires_at > pg_catalog.now() + interval '7 days' THEN
    RAISE EXCEPTION 'FAIL SQL29-D: first intent did not create a bounded pending operation';
  END IF;

  SELECT * INTO v_row
    FROM public.register_account_deletion_intent(
      '30000000-0000-0000-0000-000000002901',
      '10000000-0000-0000-0000-000000002901',
      '00000000-0000-0000-0000-000000002901',
      repeat('a', 64)
    );
  IF v_row.result <> 'existing' THEN
    RAISE EXCEPTION 'FAIL SQL29-D: same receipt retry was not idempotent';
  END IF;

  SELECT * INTO v_row
    FROM public.register_account_deletion_intent(
      '30000000-0000-0000-0000-000000002902',
      '10000000-0000-0000-0000-000000002901',
      '00000000-0000-0000-0000-000000002901',
      repeat('b', 64)
    );
  IF v_row.result <> 'conflict' THEN
    RAISE EXCEPTION 'FAIL SQL29-D: concurrent different receipt replaced the active receipt';
  END IF;

  IF public.consume_account_deletion_status_rate_limit(
       '30000000-0000-0000-0000-000000002901', repeat('b', 64)
     ) THEN
    RAISE EXCEPTION 'FAIL SQL29-E: a mismatched receipt consumed the status allowance';
  END IF;
  FOR v_index IN 1..10 LOOP
    v_allowed := public.consume_account_deletion_status_rate_limit(
      '30000000-0000-0000-0000-000000002901', repeat('a', 64)
    );
    IF NOT v_allowed THEN
      RAISE EXCEPTION 'FAIL SQL29-E: valid status attempt % was rejected early', v_index;
    END IF;
  END LOOP;
  IF public.consume_account_deletion_status_rate_limit(
       '30000000-0000-0000-0000-000000002901', repeat('a', 64)
     ) THEN
    RAISE EXCEPTION 'FAIL SQL29-E: status limiter allowed more than 10 checks per minute';
  END IF;

  SELECT * INTO v_row
    FROM public.claim_account_deletion_operation(
      '30000000-0000-0000-0000-000000002901',
      '10000000-0000-0000-0000-000000002901',
      '00000000-0000-0000-0000-000000002901',
      repeat('a', 64), v_claim_token
    );
  IF v_row.result <> 'claimed' OR v_row.status <> 'deleting' THEN
    RAISE EXCEPTION 'FAIL SQL29-F: deletion claim was not acquired';
  END IF;
  SELECT * INTO v_row
    FROM public.claim_account_deletion_operation(
      '30000000-0000-0000-0000-000000002901',
      '10000000-0000-0000-0000-000000002901',
      '00000000-0000-0000-0000-000000002901',
      repeat('a', 64), '20000000-0000-0000-0000-000000002902'
    );
  IF v_row.result <> 'in_progress' THEN
    RAISE EXCEPTION 'FAIL SQL29-F: second concurrent delete did not observe the active lease';
  END IF;
  IF public.release_account_deletion_operation(
       '30000000-0000-0000-0000-000000002901', repeat('a', 64),
       '20000000-0000-0000-0000-000000002902'
     ) THEN
    RAISE EXCEPTION 'FAIL SQL29-F: a competing claim token released another request';
  END IF;
  IF NOT public.release_account_deletion_operation(
       '30000000-0000-0000-0000-000000002901', repeat('a', 64), v_claim_token
     ) THEN
    RAISE EXCEPTION 'FAIL SQL29-F: the current claim could not release a pre-delete failure';
  END IF;
  SELECT * INTO v_row
    FROM public.read_account_deletion_operation('30000000-0000-0000-0000-000000002901');
  IF v_row.status <> 'deleting' OR v_row.delete_lease_until IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL SQL29-F: releasing a claim regressed deletion state or retained the lease';
  END IF;
END $$;

RESET ROLE;
-- Simulate the Auth cascade. The receipt row must survive while its owner row is gone.
DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-000000002901';

SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_marked boolean;
  v_row record;
BEGIN
  SELECT * INTO v_row
    FROM public.claim_account_deletion_operation(
      '30000000-0000-0000-0000-000000002901',
      '10000000-0000-0000-0000-000000002901',
      '00000000-0000-0000-0000-000000002901',
      repeat('a', 64), '20000000-0000-0000-0000-000000002903'
    );
  IF v_row.result <> 'claimed' THEN
    RAISE EXCEPTION 'FAIL SQL29-G: expired release claim could not be reacquired';
  END IF;
  v_marked := public.mark_account_deletion_operation_deleted(
    '30000000-0000-0000-0000-000000002901',
    '10000000-0000-0000-0000-000000002901',
    '00000000-0000-0000-0000-000000002901',
    repeat('a', 64)
  );
  IF NOT v_marked THEN
    RAISE EXCEPTION 'FAIL SQL29-G: confirmed Auth cascade could not mark the receipt deleted';
  END IF;
  SELECT * INTO v_row FROM public.read_account_deletion_operation('30000000-0000-0000-0000-000000002901');
  IF v_row.status <> 'deleted' OR v_row.owner_profile_id <> '10000000-0000-0000-0000-000000002901' THEN
    RAISE EXCEPTION 'FAIL SQL29-G: deleted receipt did not remain readable after the owner cascade';
  END IF;
  IF public.mark_account_deletion_operation_deleted(
       '30000000-0000-0000-0000-000000002901',
       '10000000-0000-0000-0000-000000002901',
       '00000000-0000-0000-0000-000000002901',
       repeat('b', 64)
     ) THEN
    RAISE EXCEPTION 'FAIL SQL29-G: mismatched receipt changed the deleted state';
  END IF;
  SELECT * INTO v_row
    FROM public.register_account_deletion_intent(
      '30000000-0000-0000-0000-000000002902',
      '10000000-0000-0000-0000-000000002901',
      '00000000-0000-0000-0000-000000002901',
      repeat('c', 64)
    );
  IF v_row.result <> 'owner_missing' THEN
    RAISE EXCEPTION 'FAIL SQL29-G: deleted owner was allowed to rotate its receipt';
  END IF;
END $$;

RESET ROLE;

-- Expired receipts fail closed and are removed by the next intent's bounded
-- purge. The per-owner issuance limiter survives operation expiry.
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_row record;
  v_allowed boolean;
BEGIN
  SELECT * INTO v_row
    FROM public.register_account_deletion_intent(
      '30000000-0000-0000-0000-000000002911',
      '10000000-0000-0000-0000-000000002902',
      '00000000-0000-0000-0000-000000002902',
      repeat('d', 64)
    );
  IF v_row.result <> 'created' THEN
    RAISE EXCEPTION 'FAIL SQL29-H: second owner intent setup failed';
  END IF;
END $$;

UPDATE wingward_private.account_deletion_operations
   SET created_at = pg_catalog.now() - interval '8 days',
       expires_at = pg_catalog.now() - interval '1 day'
 WHERE operation_id = '30000000-0000-0000-0000-000000002911';

DO $$
DECLARE
  v_row record;
BEGIN
  SELECT * INTO v_row
    FROM public.register_account_deletion_intent(
      '30000000-0000-0000-0000-000000002912',
      '10000000-0000-0000-0000-000000002902',
      '00000000-0000-0000-0000-000000002902',
      repeat('e', 64)
    );
  IF v_row.result <> 'created' THEN
    RAISE EXCEPTION 'FAIL SQL29-H: active owner could not retry after receipt expiry';
  END IF;
  IF EXISTS (
    SELECT 1 FROM wingward_private.account_deletion_operations
     WHERE operation_id = '30000000-0000-0000-0000-000000002911'
  ) THEN
    RAISE EXCEPTION 'FAIL SQL29-H: expired receipt was not purged during new intent registration';
  END IF;
END $$;

ROLLBACK;
