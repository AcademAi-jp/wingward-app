-- B2 SQL22: meetup RPCs must revalidate the current mutual profile pair.
--
-- Synthetic only.  Run against the approved local Postgres fixture after
-- the additive RPC migration is applied.  The transaction rolls back all
-- rows.  Each meetup is prepared while the pair is eligible, then both
-- profiles lose their explicit preference before the RPC call.

BEGIN;
SET LOCAL statement_timeout = '15s';

INSERT INTO auth.users (id, email)
VALUES
  ('00000000-0000-0000-0000-00000000f221', 'b2-meetup-sql22-a1@example.invalid'),
  ('00000000-0000-0000-0000-00000000f222', 'b2-meetup-sql22-b1@example.invalid'),
  ('00000000-0000-0000-0000-00000000f223', 'b2-meetup-sql22-a2@example.invalid'),
  ('00000000-0000-0000-0000-00000000f224', 'b2-meetup-sql22-b2@example.invalid'),
  ('00000000-0000-0000-0000-00000000f225', 'b2-meetup-sql22-a3@example.invalid'),
  ('00000000-0000-0000-0000-00000000f226', 'b2-meetup-sql22-b3@example.invalid'),
  ('00000000-0000-0000-0000-00000000f227', 'b2-meetup-sql22-a4@example.invalid'),
  ('00000000-0000-0000-0000-00000000f228', 'b2-meetup-sql22-b4@example.invalid');

WITH fixtures(auth_user_id, profile_id, nickname) AS (
  VALUES
    ('00000000-0000-0000-0000-00000000f221'::uuid, '10000000-0000-0000-0000-00000000f221'::uuid, 'B2 Meetup SQL22 A1'),
    ('00000000-0000-0000-0000-00000000f222'::uuid, '10000000-0000-0000-0000-00000000f222'::uuid, 'B2 Meetup SQL22 B1'),
    ('00000000-0000-0000-0000-00000000f223'::uuid, '10000000-0000-0000-0000-00000000f223'::uuid, 'B2 Meetup SQL22 A2'),
    ('00000000-0000-0000-0000-00000000f224'::uuid, '10000000-0000-0000-0000-00000000f224'::uuid, 'B2 Meetup SQL22 B2'),
    ('00000000-0000-0000-0000-00000000f225'::uuid, '10000000-0000-0000-0000-00000000f225'::uuid, 'B2 Meetup SQL22 A3'),
    ('00000000-0000-0000-0000-00000000f226'::uuid, '10000000-0000-0000-0000-00000000f226'::uuid, 'B2 Meetup SQL22 B3'),
    ('00000000-0000-0000-0000-00000000f227'::uuid, '10000000-0000-0000-0000-00000000f227'::uuid, 'B2 Meetup SQL22 A4'),
    ('00000000-0000-0000-0000-00000000f228'::uuid, '10000000-0000-0000-0000-00000000f228'::uuid, 'B2 Meetup SQL22 B4')
)
UPDATE public.user_profiles AS profile_row
   SET id = fixture.profile_id,
       nickname = fixture.nickname,
       birth_date = DATE '1990-01-01',
       age_verified_at = pg_catalog.now(),
       age_verification_method = 'self_declared',
       identity_verification_status = 'verified',
       identity_verified_at = pg_catalog.now(),
       timezone = 'UTC',
       dating_market = 'JP',
       gender_identity = 'woman',
       preferred_genders = ARRAY['woman']::text[],
       preference_mode = 'selected',
       onboarding_settings_completed_at = pg_catalog.now()
  FROM fixtures AS fixture
 WHERE profile_row.auth_user_id = fixture.auth_user_id;

INSERT INTO public.matches (id, user_a_id, user_b_id, status)
VALUES
  ('20000000-0000-0000-0000-00000000f221', '10000000-0000-0000-0000-00000000f221', '10000000-0000-0000-0000-00000000f222', 'direct_chat_active'),
  ('20000000-0000-0000-0000-00000000f223', '10000000-0000-0000-0000-00000000f223', '10000000-0000-0000-0000-00000000f224', 'direct_chat_active'),
  ('20000000-0000-0000-0000-00000000f225', '10000000-0000-0000-0000-00000000f225', '10000000-0000-0000-0000-00000000f226', 'direct_chat_active'),
  ('20000000-0000-0000-0000-00000000f227', '10000000-0000-0000-0000-00000000f227', '10000000-0000-0000-0000-00000000f228', 'direct_chat_active');

INSERT INTO public.direct_chat_rooms (id, match_id, status)
VALUES
  ('40000000-0000-0000-0000-00000000f221', '20000000-0000-0000-0000-00000000f221', 'active'),
  ('40000000-0000-0000-0000-00000000f223', '20000000-0000-0000-0000-00000000f223', 'active'),
  ('40000000-0000-0000-0000-00000000f225', '20000000-0000-0000-0000-00000000f225', 'active'),
  ('40000000-0000-0000-0000-00000000f227', '20000000-0000-0000-0000-00000000f227', 'active');

-- Prepare all active states before revocation so this fixture does not rely
-- on any cleanup exception in a future meetup child-write guard.
INSERT INTO public.meetups
  (id, match_id, initiator_id, status, intent_a_at, intent_b_at,
   proposal_expires_at, arrange_attempt_count)
VALUES
  (
    '50000000-0000-0000-0000-00000000f223',
    '20000000-0000-0000-0000-00000000f223',
    '10000000-0000-0000-0000-00000000f223',
    'proposed',
    pg_catalog.now(), pg_catalog.now(),
    pg_catalog.now() + pg_catalog.interval '1 day', 0
  ),
  (
    '50000000-0000-0000-0000-00000000f225',
    '20000000-0000-0000-0000-00000000f225',
    '10000000-0000-0000-0000-00000000f225',
    'verifying',
    pg_catalog.now(), pg_catalog.now(), NULL, 0
  ),
  (
    '50000000-0000-0000-0000-00000000f227',
    '20000000-0000-0000-0000-00000000f227',
    '10000000-0000-0000-0000-00000000f227',
    'arranging',
    pg_catalog.now(), pg_catalog.now(), NULL, 1
  );

INSERT INTO public.meetup_proposals
  (id, meetup_id, attempt_number, candidates, expires_at)
VALUES (
  '60000000-0000-0000-0000-00000000f223',
  '50000000-0000-0000-0000-00000000f223',
  1,
  pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '2 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Minato', 'format', 'cafe',
      'rationale', 'A concise option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '3 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Shibuya', 'format', 'meal',
      'rationale', 'A second option.'
    ),
    pg_catalog.jsonb_build_object(
      'starts_at', pg_catalog.to_char(
        (pg_catalog.now() + pg_catalog.interval '4 days') AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
      ),
      'timezone', 'UTC', 'area', 'Tokyo/Setagaya', 'format', 'online',
      'rationale', 'A flexible option.'
    )
  ),
  pg_catalog.now() + pg_catalog.interval '1 day'
);

-- Revoke only the explicit mutual preference. Age, identity, completion,
-- market, and timezone remain valid so each RPC must fail at the new helper
-- before its later identity, replay, quota, response, or proposal branch.
UPDATE public.user_profiles
   SET preferred_genders = ARRAY[]::text[],
       preference_mode = 'no_answer'
 WHERE id IN (
   '10000000-0000-0000-0000-00000000f221',
   '10000000-0000-0000-0000-00000000f222',
   '10000000-0000-0000-0000-00000000f223',
   '10000000-0000-0000-0000-00000000f224',
   '10000000-0000-0000-0000-00000000f225',
   '10000000-0000-0000-0000-00000000f226',
   '10000000-0000-0000-0000-00000000f227',
   '10000000-0000-0000-0000-00000000f228'
 );

SET LOCAL role = 'service_role';

SET LOCAL ROLE service_role;
DO $fn$
DECLARE
  result record;
  meetup_count integer;
BEGIN
  SELECT * INTO result
    FROM public.create_or_match_meetup_intent(
      '20000000-0000-0000-0000-00000000f221',
      '10000000-0000-0000-0000-00000000f221'
    );
  IF result.outcome IS DISTINCT FROM 'not_found'
     OR result.meetup_id IS NOT NULL
     OR result.status IS NOT NULL
     OR result.initiator_id IS NOT NULL
     OR result.matched IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL 22a: revoked intent did not return the nondisclosing not_found shape';
  END IF;

  RESET ROLE;
  SELECT count(*)::integer INTO meetup_count
    FROM public.meetups
   WHERE match_id = '20000000-0000-0000-0000-00000000f221';
  IF meetup_count <> 0 THEN
    RAISE EXCEPTION 'FAIL 22a: revoked intent created % meetup rows', meetup_count;
  END IF;
  RAISE NOTICE 'PASS 22a: create_or_match_meetup_intent rechecks mutual eligibility before insertion';
END
$fn$;

SET LOCAL ROLE service_role;
DO $fn$
DECLARE
  result record;
  response_count integer;
  meetup_status text;
BEGIN
  SELECT * INTO result
    FROM public.record_meetup_proposal_response(
      '50000000-0000-0000-0000-00000000f223',
      '60000000-0000-0000-0000-00000000f223',
      '10000000-0000-0000-0000-00000000f223',
      0
    );
  IF result.outcome IS DISTINCT FROM 'not_found'
     OR result.meetup_id IS DISTINCT FROM '50000000-0000-0000-0000-00000000f223'::uuid
     OR result.proposal_id IS DISTINCT FROM '60000000-0000-0000-0000-00000000f223'::uuid
     OR result.status IS NOT NULL
     OR result.confirmed_candidate_index IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL 22b: revoked proposal response leaked state or was accepted';
  END IF;

  RESET ROLE;
  SELECT count(*)::integer INTO response_count
    FROM public.meetup_proposal_responses
   WHERE proposal_id = '60000000-0000-0000-0000-00000000f223';
  SELECT status INTO meetup_status
    FROM public.meetups
   WHERE id = '50000000-0000-0000-0000-00000000f223';
  IF response_count <> 0 OR meetup_status IS DISTINCT FROM 'proposed' THEN
    RAISE EXCEPTION 'FAIL 22b: revoked response changed response count or meetup status';
  END IF;
  RAISE NOTICE 'PASS 22b: record_meetup_proposal_response rechecks before response/replay writes';
END
$fn$;

SET LOCAL ROLE service_role;
DO $fn$
DECLARE
  result record;
  claim_count integer;
  quota_count integer;
  meetup_status text;
  attempt_count integer;
BEGIN
  SELECT * INTO result
    FROM public.claim_meetup_arrangement(
      '50000000-0000-0000-0000-00000000f225',
      '10000000-0000-0000-0000-00000000f225',
      false,
      'sql22-claim-f225'
    );
  IF result.outcome IS DISTINCT FROM 'not_found'
     OR result.meetup_id IS DISTINCT FROM '50000000-0000-0000-0000-00000000f225'::uuid
     OR result.match_id IS NOT NULL
     OR result.status IS NOT NULL
     OR result.attempt_number IS NOT NULL
     OR result.billing_source IS NOT NULL
     OR result.transitioned IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL 22c: revoked arrangement claim leaked state or was accepted';
  END IF;

  RESET ROLE;
  SELECT count(*)::integer INTO claim_count
    FROM public.meetup_arrangement_claims
   WHERE meetup_id = '50000000-0000-0000-0000-00000000f225';
  RESET ROLE;
  SELECT count(*)::integer INTO quota_count
    FROM public.usage_counters
   WHERE user_id = '10000000-0000-0000-0000-00000000f225'
     AND quota_key IN ('meetup_arrange', 'arrange_retry');
  SELECT status, arrange_attempt_count
    INTO meetup_status, attempt_count
    FROM public.meetups
   WHERE id = '50000000-0000-0000-0000-00000000f225';
  IF claim_count <> 0 OR quota_count <> 0
     OR meetup_status IS DISTINCT FROM 'verifying'
     OR attempt_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL 22c: revoked claim changed claim, quota, or meetup state';
  END IF;
  RAISE NOTICE 'PASS 22c: claim_meetup_arrangement rechecks before replay/quota/claim writes';
END
$fn$;

SET LOCAL ROLE service_role;
DO $fn$
DECLARE
  result record;
  proposal_count integer;
  meetup_status text;
  attempt_count integer;
BEGIN
  -- NULL content is intentional: the mutual gate must run before candidate
  -- validation and before the arrange_failed/proposal write branches.
  SELECT * INTO result
    FROM public.persist_meetup_proposal(
      '50000000-0000-0000-0000-00000000f227',
      '10000000-0000-0000-0000-00000000f227',
      1,
      NULL
    );
  IF result.outcome IS DISTINCT FROM 'not_found'
     OR result.meetup_id IS DISTINCT FROM '50000000-0000-0000-0000-00000000f227'::uuid
     OR result.match_id IS NOT NULL
     OR result.proposal_id IS NOT NULL
     OR result.status IS NOT NULL
     OR result.attempt_number IS DISTINCT FROM 1
     OR result.transitioned IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL 22d: revoked proposal persistence leaked state or was accepted';
  END IF;

  RESET ROLE;
  SELECT count(*)::integer INTO proposal_count
    FROM public.meetup_proposals
   WHERE meetup_id = '50000000-0000-0000-0000-00000000f227';
  SELECT status, arrange_attempt_count
    INTO meetup_status, attempt_count
    FROM public.meetups
   WHERE id = '50000000-0000-0000-0000-00000000f227';
  IF proposal_count <> 0
     OR meetup_status IS DISTINCT FROM 'arranging'
     OR attempt_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL 22d: revoked persistence changed proposal or meetup state';
  END IF;
  RAISE NOTICE 'PASS 22d: persist_meetup_proposal rechecks before validation/proposal writes';
END
$fn$;


-- Real successful calls followed by revoked retries; every scenario rolls back.
RESET ROLE; SAVEPOINT replay_1; UPDATE public.user_profiles SET preference_mode='selected',preferred_genders=ARRAY['woman'] WHERE id IN ('10000000-0000-0000-0000-00000000f221','10000000-0000-0000-0000-00000000f222'); SET LOCAL ROLE service_role;
DO $$ DECLARE got text; BEGIN SELECT outcome INTO got FROM public.create_or_match_meetup_intent('20000000-0000-0000-0000-00000000f221','10000000-0000-0000-0000-00000000f221'); IF got IS DISTINCT FROM 'created' THEN RAISE EXCEPTION 'FAIL 22 replay 1 positive: %',got; END IF; END;$$;
RESET ROLE; UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f222'; SET LOCAL ROLE service_role;
DO $$ DECLARE got text; BEGIN SELECT outcome INTO got FROM public.create_or_match_meetup_intent('20000000-0000-0000-0000-00000000f221','10000000-0000-0000-0000-00000000f221'); IF got IS DISTINCT FROM 'not_found' THEN RAISE EXCEPTION 'FAIL 22 replay 1 revoked: %',got; END IF; END;$$;
RESET ROLE; ROLLBACK TO SAVEPOINT replay_1; RELEASE SAVEPOINT replay_1;
RESET ROLE; SAVEPOINT replay_3; UPDATE public.user_profiles SET preference_mode='selected',preferred_genders=ARRAY['woman'] WHERE id IN ('10000000-0000-0000-0000-00000000f223','10000000-0000-0000-0000-00000000f224'); SET LOCAL ROLE service_role;
DO $$ DECLARE got text; BEGIN SELECT outcome INTO got FROM public.record_meetup_proposal_response('50000000-0000-0000-0000-00000000f223','60000000-0000-0000-0000-00000000f223','10000000-0000-0000-0000-00000000f223',0); IF got IS DISTINCT FROM 'accepted' THEN RAISE EXCEPTION 'FAIL 22 replay 3 positive: %',got; END IF; END;$$;
RESET ROLE; UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f224'; SET LOCAL ROLE service_role;
DO $$ DECLARE got text; BEGIN SELECT outcome INTO got FROM public.record_meetup_proposal_response('50000000-0000-0000-0000-00000000f223','60000000-0000-0000-0000-00000000f223','10000000-0000-0000-0000-00000000f223',0); IF got IS DISTINCT FROM 'not_found' THEN RAISE EXCEPTION 'FAIL 22 replay 3 revoked: %',got; END IF; END;$$;
RESET ROLE; ROLLBACK TO SAVEPOINT replay_3; RELEASE SAVEPOINT replay_3;
RESET ROLE; SAVEPOINT replay_5; UPDATE public.user_profiles SET preference_mode='selected',preferred_genders=ARRAY['woman'] WHERE id IN ('10000000-0000-0000-0000-00000000f225','10000000-0000-0000-0000-00000000f226'); SET LOCAL ROLE service_role;
DO $$ DECLARE got text; BEGIN SELECT outcome INTO got FROM public.claim_meetup_arrangement('50000000-0000-0000-0000-00000000f225','10000000-0000-0000-0000-00000000f225',false,'sql22-replay-f225'); IF got IS DISTINCT FROM 'claimed' THEN RAISE EXCEPTION 'FAIL 22 replay 5 positive: %',got; END IF; END;$$;
RESET ROLE; UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f226'; SET LOCAL ROLE service_role;
DO $$ DECLARE got text; BEGIN SELECT outcome INTO got FROM public.claim_meetup_arrangement('50000000-0000-0000-0000-00000000f225','10000000-0000-0000-0000-00000000f225',false,'sql22-replay-f225'); IF got IS DISTINCT FROM 'not_found' THEN RAISE EXCEPTION 'FAIL 22 replay 5 revoked: %',got; END IF; END;$$;
RESET ROLE; ROLLBACK TO SAVEPOINT replay_5; RELEASE SAVEPOINT replay_5;
RESET ROLE; SAVEPOINT replay_7; UPDATE public.user_profiles SET preference_mode='selected',preferred_genders=ARRAY['woman'] WHERE id IN ('10000000-0000-0000-0000-00000000f227','10000000-0000-0000-0000-00000000f228'); SET LOCAL ROLE service_role;
DO $$ DECLARE got text; BEGIN SELECT outcome INTO got FROM public.persist_meetup_proposal('50000000-0000-0000-0000-00000000f227','10000000-0000-0000-0000-00000000f227',1,(SELECT candidates FROM public.meetup_proposals WHERE id='60000000-0000-0000-0000-00000000f223')); IF got IS DISTINCT FROM 'proposed' THEN RAISE EXCEPTION 'FAIL 22 replay 7 positive: %',got; END IF; END;$$;
RESET ROLE; UPDATE public.user_profiles SET preference_mode='no_answer',preferred_genders=ARRAY[]::text[] WHERE id='10000000-0000-0000-0000-00000000f228'; SET LOCAL ROLE service_role;
DO $$ DECLARE got text; BEGIN SELECT outcome INTO got FROM public.persist_meetup_proposal('50000000-0000-0000-0000-00000000f227','10000000-0000-0000-0000-00000000f227',1,(SELECT candidates FROM public.meetup_proposals WHERE id='60000000-0000-0000-0000-00000000f223')); IF got IS DISTINCT FROM 'not_found' THEN RAISE EXCEPTION 'FAIL 22 replay 7 revoked: %',got; END IF; END;$$;
RESET ROLE; ROLLBACK TO SAVEPOINT replay_7; RELEASE SAVEPOINT replay_7;
RESET role;
ROLLBACK;
