-- Durable, resumable daily matching. User-visible match rows are written only
-- by publish_durable_daily_matching_batch, in one transaction after every
-- closed snapshot and score page has been committed.

CREATE SCHEMA IF NOT EXISTS wingward_private;
REVOKE ALL ON SCHEMA wingward_private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA wingward_private TO service_role;

CREATE TABLE public.daily_match_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_date date NOT NULL UNIQUE,
  batch_timezone text NOT NULL DEFAULT 'Asia/Tokyo'
    CHECK (batch_timezone = 'Asia/Tokyo'),
  algorithm_version text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'matching', 'completed', 'failed')),
  total_users integer NOT NULL DEFAULT 0 CHECK (total_users >= 0),
  users_matched integer NOT NULL DEFAULT 0 CHECK (users_matched >= 0),
  total_matches integer NOT NULL DEFAULT 0 CHECK (total_matches >= 0),
  conversations_completed integer NOT NULL DEFAULT 0 CHECK (conversations_completed >= 0),
  conversations_failed integer NOT NULL DEFAULT 0 CHECK (conversations_failed >= 0),
  error_message text,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  member_cursor uuid,
  member_scan_complete boolean NOT NULL DEFAULT false,
  snapshot_user_count integer NOT NULL DEFAULT 0 CHECK (snapshot_user_count >= 0),
  pair_cursor_user_a uuid,
  pair_cursor_user_b uuid,
  pair_scan_complete boolean NOT NULL DEFAULT false,
  lease_token uuid,
  lease_generation bigint NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
  lease_expires_at timestamptz,
  published_at timestamptz,
  CONSTRAINT daily_match_batches_lease_pair_check
    CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
  CONSTRAINT daily_match_batches_pair_cursor_check
    CHECK ((pair_cursor_user_a IS NULL) = (pair_cursor_user_b IS NULL)),
  CONSTRAINT daily_match_batches_completion_check
    CHECK ((status = 'completed') = (completed_at IS NOT NULL AND published_at IS NOT NULL))
);
ALTER TABLE public.daily_match_batches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.daily_match_batches FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.daily_match_batches TO service_role;

ALTER TABLE public.matches
  ADD COLUMN batch_id uuid REFERENCES public.daily_match_batches(id) ON DELETE SET NULL;
CREATE INDEX idx_matches_batch_id ON public.matches(batch_id) WHERE batch_id IS NOT NULL;

CREATE TABLE wingward_private.daily_matching_batch_members (
  batch_id uuid NOT NULL REFERENCES public.daily_match_batches(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  eligibility_snapshot jsonb NOT NULL,
  scoring_profile_snapshot jsonb,
  profile_version integer,
  profile_updated_at timestamptz,
  persona_version integer NOT NULL DEFAULT 0 CHECK (persona_version >= 0),
  persona_traits jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(persona_traits) = 'object'),
  snapshotted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (batch_id, user_id),
  CHECK ((scoring_profile_snapshot IS NULL) = (profile_version IS NULL)),
  CHECK ((scoring_profile_snapshot IS NULL) = (profile_updated_at IS NULL))
);
CREATE INDEX daily_matching_batch_members_profile_idx
  ON wingward_private.daily_matching_batch_members(batch_id, user_id)
  WHERE scoring_profile_snapshot IS NOT NULL;
ALTER TABLE wingward_private.daily_matching_batch_members ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE wingward_private.daily_matching_batch_members FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE wingward_private.daily_matching_batch_candidates (
  batch_id uuid NOT NULL,
  user_a_id uuid NOT NULL,
  user_b_id uuid NOT NULL,
  score numeric(5,2) NOT NULL CHECK (score BETWEEN 0 AND 100),
  score_details jsonb NOT NULL CHECK (jsonb_typeof(score_details) = 'object'),
  layer_scores jsonb NOT NULL CHECK (jsonb_typeof(layer_scores) = 'object'),
  feature_scores jsonb NOT NULL CHECK (jsonb_typeof(feature_scores) = 'array'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (batch_id, user_a_id, user_b_id),
  CHECK (user_a_id < user_b_id),
  FOREIGN KEY (batch_id, user_a_id)
    REFERENCES wingward_private.daily_matching_batch_members(batch_id, user_id) ON DELETE CASCADE,
  FOREIGN KEY (batch_id, user_b_id)
    REFERENCES wingward_private.daily_matching_batch_members(batch_id, user_id) ON DELETE CASCADE
);
CREATE INDEX daily_matching_batch_candidates_order_idx
  ON wingward_private.daily_matching_batch_candidates(batch_id, score DESC, user_a_id, user_b_id);
ALTER TABLE wingward_private.daily_matching_batch_candidates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE wingward_private.daily_matching_batch_candidates FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE wingward_private.daily_matching_notification_outbox (
  batch_id uuid NOT NULL REFERENCES public.daily_match_batches(id) ON DELETE CASCADE,
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'leased', 'completed')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  available_at timestamptz NOT NULL DEFAULT now(),
  claim_token uuid,
  claim_generation bigint NOT NULL DEFAULT 0 CHECK (claim_generation >= 0),
  lease_expires_at timestamptz,
  notification_id uuid REFERENCES public.notifications(id) ON DELETE SET NULL,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (batch_id, match_id, user_id),
  CHECK ((claim_token IS NULL) = (lease_expires_at IS NULL)),
  CHECK ((status = 'completed') = (completed_at IS NOT NULL AND notification_id IS NOT NULL))
);
CREATE INDEX daily_matching_notification_outbox_ready_idx
  ON wingward_private.daily_matching_notification_outbox(available_at, batch_id, match_id, user_id)
  WHERE status <> 'completed';
ALTER TABLE wingward_private.daily_matching_notification_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE wingward_private.daily_matching_notification_outbox FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION wingward_private.daily_matching_snapshot_is_eligible(p_eligibility jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_gender text;
  v_market text;
  v_preference text;
  v_preferences jsonb;
  v_seen text[] := ARRAY[]::text[];
  v_item jsonb;
  v_value text;
BEGIN
  IF pg_catalog.jsonb_typeof(p_eligibility) <> 'object'
     OR NULLIF(p_eligibility ->> 'id', '') IS NULL
     OR NULLIF(p_eligibility ->> 'age_verified_at', '') IS NULL
     OR NULLIF(p_eligibility ->> 'onboarding_settings_completed_at', '') IS NULL THEN
    RETURN false;
  END IF;
  v_gender := p_eligibility ->> 'gender_identity';
  v_market := p_eligibility ->> 'dating_market';
  v_preference := p_eligibility ->> 'preference_mode';
  IF v_gender NOT IN ('woman', 'man', 'nonbinary')
     OR v_market NOT IN ('JP', 'US')
     OR v_preference <> 'selected' THEN
    RETURN false;
  END IF;
  v_preferences := p_eligibility -> 'preferred_genders';
  IF pg_catalog.jsonb_typeof(v_preferences) <> 'array'
     OR pg_catalog.jsonb_array_length(v_preferences) < 1
     OR pg_catalog.jsonb_array_length(v_preferences) > 3 THEN
    RETURN false;
  END IF;
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(v_preferences) LOOP
    IF pg_catalog.jsonb_typeof(v_item) <> 'string' THEN RETURN false; END IF;
    v_value := v_item #>> '{}';
    IF v_value NOT IN ('woman', 'man', 'nonbinary') OR v_value = ANY(v_seen) THEN
      RETURN false;
    END IF;
    v_seen := pg_catalog.array_append(v_seen, v_value);
  END LOOP;
  RETURN true;
END;
$$;

CREATE FUNCTION wingward_private.daily_matching_snapshot_pair_is_eligible(
  p_first jsonb,
  p_second jsonb
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT wingward_private.daily_matching_snapshot_is_eligible(p_first)
     AND wingward_private.daily_matching_snapshot_is_eligible(p_second)
     AND (p_first ->> 'id') <> (p_second ->> 'id')
     AND (p_first ->> 'dating_market') = (p_second ->> 'dating_market')
     AND ((p_first ->> 'id') = ANY (ARRAY[
       '96b31c0a-b8c4-4536-ada2-f3537dadd146',
       '9d836fee-7b93-41ce-b577-34a63006aaea',
       'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'
     ])) = ((p_second ->> 'id') = ANY (ARRAY[
       '96b31c0a-b8c4-4536-ada2-f3537dadd146',
       '9d836fee-7b93-41ce-b577-34a63006aaea',
       'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'
     ]))
     AND (p_first -> 'preferred_genders') ? (p_second ->> 'gender_identity')
     AND (p_second -> 'preferred_genders') ? (p_first ->> 'gender_identity')
$$;

CREATE FUNCTION public.claim_durable_daily_matching_batch(
  p_batch_date date,
  p_batch_timezone text,
  p_algorithm_version text,
  p_lease_seconds integer,
  p_resume_only boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.daily_match_batches%ROWTYPE;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF p_batch_date IS NULL OR p_batch_timezone <> 'Asia/Tokyo'
     OR p_algorithm_version <> 'daily-matching-v1'
     OR p_lease_seconds < 60 OR p_lease_seconds > 600 THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'incompatible', 'batch_id', NULL, 'lease_token', NULL,
      'lease_generation', 0, 'member_cursor', NULL, 'member_scan_complete', false,
      'pair_cursor_user_a', NULL, 'pair_cursor_user_b', NULL, 'pair_scan_complete', false,
      'total_users', 0, 'users_matched', 0, 'total_matches', 0
    );
  END IF;

  IF p_resume_only THEN
    SELECT * INTO v_batch
      FROM public.daily_match_batches AS batch_row
     WHERE batch_row.batch_date = p_batch_date
     FOR UPDATE;
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object(
        'state', 'not_started', 'batch_id', NULL, 'lease_token', NULL,
        'lease_generation', 0, 'member_cursor', NULL, 'member_scan_complete', false,
        'pair_cursor_user_a', NULL, 'pair_cursor_user_b', NULL, 'pair_scan_complete', false,
        'total_users', 0, 'users_matched', 0, 'total_matches', 0
      );
    END IF;
  ELSE
    INSERT INTO public.daily_match_batches(batch_date, batch_timezone, algorithm_version)
    VALUES (p_batch_date, p_batch_timezone, p_algorithm_version)
    ON CONFLICT (batch_date) DO NOTHING;
    SELECT * INTO v_batch
      FROM public.daily_match_batches AS batch_row
     WHERE batch_row.batch_date = p_batch_date
     FOR UPDATE;
  END IF;

  IF v_batch.batch_timezone <> p_batch_timezone
     OR v_batch.algorithm_version <> p_algorithm_version THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'incompatible', 'batch_id', v_batch.id, 'lease_token', NULL,
      'lease_generation', v_batch.lease_generation, 'member_cursor', v_batch.member_cursor,
      'member_scan_complete', v_batch.member_scan_complete,
      'pair_cursor_user_a', v_batch.pair_cursor_user_a,
      'pair_cursor_user_b', v_batch.pair_cursor_user_b,
      'pair_scan_complete', v_batch.pair_scan_complete,
      'total_users', v_batch.total_users, 'users_matched', v_batch.users_matched,
      'total_matches', v_batch.total_matches
    );
  END IF;

  IF v_batch.status = 'completed' THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'completed', 'batch_id', v_batch.id, 'lease_token', NULL,
      'lease_generation', v_batch.lease_generation, 'member_cursor', v_batch.member_cursor,
      'member_scan_complete', v_batch.member_scan_complete,
      'pair_cursor_user_a', v_batch.pair_cursor_user_a,
      'pair_cursor_user_b', v_batch.pair_cursor_user_b,
      'pair_scan_complete', v_batch.pair_scan_complete,
      'total_users', v_batch.total_users, 'users_matched', v_batch.users_matched,
      'total_matches', v_batch.total_matches
    );
  END IF;

  IF v_batch.lease_token IS NOT NULL AND v_batch.lease_expires_at > v_now THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'busy', 'batch_id', v_batch.id, 'lease_token', NULL,
      'lease_generation', v_batch.lease_generation, 'member_cursor', v_batch.member_cursor,
      'member_scan_complete', v_batch.member_scan_complete,
      'pair_cursor_user_a', v_batch.pair_cursor_user_a,
      'pair_cursor_user_b', v_batch.pair_cursor_user_b,
      'pair_scan_complete', v_batch.pair_scan_complete,
      'total_users', v_batch.total_users, 'users_matched', v_batch.users_matched,
      'total_matches', v_batch.total_matches
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.daily_match_batches AS other_batch
     WHERE other_batch.id <> v_batch.id
       AND other_batch.status = 'matching'
       AND other_batch.lease_expires_at > v_now
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'busy', 'batch_id', v_batch.id, 'lease_token', NULL,
      'lease_generation', v_batch.lease_generation, 'member_cursor', v_batch.member_cursor,
      'member_scan_complete', v_batch.member_scan_complete,
      'pair_cursor_user_a', v_batch.pair_cursor_user_a,
      'pair_cursor_user_b', v_batch.pair_cursor_user_b,
      'pair_scan_complete', v_batch.pair_scan_complete,
      'total_users', v_batch.total_users, 'users_matched', v_batch.users_matched,
      'total_matches', v_batch.total_matches
    );
  END IF;

  UPDATE public.daily_match_batches AS batch_row
     SET status = 'matching',
         started_at = COALESCE(batch_row.started_at, v_now),
         lease_token = gen_random_uuid(),
         lease_generation = batch_row.lease_generation + 1,
         lease_expires_at = v_now + pg_catalog.make_interval(secs => p_lease_seconds)
   WHERE batch_row.id = v_batch.id
  RETURNING * INTO v_batch;
  RETURN pg_catalog.jsonb_build_object(
    'state', 'claimed', 'batch_id', v_batch.id, 'lease_token', v_batch.lease_token,
    'lease_generation', v_batch.lease_generation, 'member_cursor', v_batch.member_cursor,
    'member_scan_complete', v_batch.member_scan_complete,
    'pair_cursor_user_a', v_batch.pair_cursor_user_a,
    'pair_cursor_user_b', v_batch.pair_cursor_user_b,
    'pair_scan_complete', v_batch.pair_scan_complete,
    'total_users', v_batch.total_users, 'users_matched', v_batch.users_matched,
    'total_matches', v_batch.total_matches
  );
END;
$$;

CREATE FUNCTION public.scan_durable_daily_matching_member_page(
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint,
  p_after_user_id uuid,
  p_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.daily_match_batches%ROWTYPE;
  v_count integer := 0;
  v_saved_count integer := 0;
  v_next uuid;
  v_done boolean;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF p_limit < 1 OR p_limit > 100 THEN RAISE EXCEPTION 'invalid page size'; END IF;
  UPDATE public.daily_match_batches AS batch_row
     SET lease_expires_at = v_now + interval '3 minutes'
   WHERE batch_row.id = p_batch_id AND batch_row.status = 'matching'
     AND batch_row.lease_token = p_lease_token
     AND batch_row.lease_generation = p_lease_generation
     AND batch_row.lease_expires_at > v_now
  RETURNING * INTO v_batch;
  IF NOT FOUND THEN RAISE EXCEPTION 'daily matching lease lost'; END IF;
  IF v_batch.member_scan_complete THEN
    RETURN pg_catalog.jsonb_build_object('next_user_id', v_batch.member_cursor, 'done', true, 'scanned_count', 0);
  END IF;
  IF v_batch.member_cursor IS DISTINCT FROM p_after_user_id THEN
    RAISE EXCEPTION 'daily matching member cursor changed';
  END IF;

  WITH page AS MATERIALIZED (
    SELECT up.id AS user_id,
           pg_catalog.jsonb_build_object(
             'id', up.id, 'age_verified_at', up.age_verified_at,
             'gender_identity', up.gender_identity,
             'preferred_genders', pg_catalog.to_jsonb(up.preferred_genders),
             'preference_mode', up.preference_mode,
             'dating_market', up.dating_market,
             'onboarding_settings_completed_at', up.onboarding_settings_completed_at
           ) AS eligibility_snapshot,
           CASE WHEN profile_row.user_id IS NULL THEN NULL::jsonb ELSE
             pg_catalog.jsonb_build_object(
               'user_id', profile_row.user_id,
               'basic_info', profile_row.basic_info,
               'personality_tags', profile_row.personality_tags,
               'personality_analysis', profile_row.personality_analysis,
               'interaction_style', profile_row.interaction_style,
               'interests', profile_row.interests,
               'values', profile_row.values,
               'communication_style', profile_row.communication_style
             ) END AS scoring_profile_snapshot,
           profile_row.version AS profile_version,
           profile_row.updated_at AS profile_updated_at,
           COALESCE(persona_row.version, 0)::integer AS persona_version,
           COALESCE(persona_row.traits, '{}'::jsonb) AS persona_traits
      FROM public.user_profiles AS up
      LEFT JOIN public.profiles AS profile_row
        ON profile_row.user_id = up.id AND profile_row.status = 'confirmed'
      LEFT JOIN LATERAL (
        SELECT persona.version, persona.traits
          FROM public.user_persona_versions AS persona
         WHERE persona.user_id = up.id AND persona.confirmed_at IS NOT NULL
           AND persona.confirmed_at <= v_batch.started_at
         ORDER BY persona.version DESC
         LIMIT 1
      ) AS persona_row ON true
     WHERE up.created_at <= v_batch.started_at
       AND (p_after_user_id IS NULL OR up.id > p_after_user_id)
     ORDER BY up.id
     LIMIT p_limit
  ), saved AS (
    INSERT INTO wingward_private.daily_matching_batch_members(
      batch_id, user_id, eligibility_snapshot, scoring_profile_snapshot,
      profile_version, profile_updated_at, persona_version, persona_traits
    )
    SELECT p_batch_id, page.user_id, page.eligibility_snapshot,
           page.scoring_profile_snapshot, page.profile_version,
           page.profile_updated_at, page.persona_version, page.persona_traits
      FROM page
    ON CONFLICT (batch_id, user_id) DO NOTHING
    RETURNING user_id
  )
  SELECT pg_catalog.max(page.user_id), pg_catalog.count(*)::integer,
         (SELECT pg_catalog.count(*)::integer FROM saved)
    INTO v_next, v_count, v_saved_count
    FROM page;
  IF v_saved_count <> v_count THEN
    RAISE EXCEPTION 'daily matching snapshot page was not fully persisted';
  END IF;
  v_done := v_count < p_limit;
  UPDATE public.daily_match_batches AS batch_row
     SET member_cursor = COALESCE(v_next, batch_row.member_cursor),
         member_scan_complete = v_done,
         snapshot_user_count = batch_row.snapshot_user_count + v_count
   WHERE batch_row.id = p_batch_id;
  RETURN pg_catalog.jsonb_build_object('next_user_id', v_next, 'done', v_done, 'scanned_count', v_count);
END;
$$;

CREATE FUNCTION public.read_durable_daily_matching_pair_page(
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint,
  p_after_user_a_id uuid,
  p_after_user_b_id uuid,
  p_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.daily_match_batches%ROWTYPE;
  v_pairs jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_next_a uuid;
  v_next_b uuid;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF p_limit < 1 OR p_limit > 100
     OR ((p_after_user_a_id IS NULL) <> (p_after_user_b_id IS NULL)) THEN
    RAISE EXCEPTION 'invalid pair cursor or page size';
  END IF;
  SELECT * INTO v_batch
    FROM public.daily_match_batches AS batch_row
   WHERE batch_row.id = p_batch_id AND batch_row.status = 'matching'
     AND batch_row.lease_token = p_lease_token
     AND batch_row.lease_generation = p_lease_generation
     AND batch_row.lease_expires_at > v_now
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'daily matching lease lost'; END IF;
  IF NOT v_batch.member_scan_complete THEN RAISE EXCEPTION 'member snapshot is incomplete'; END IF;
  IF v_batch.pair_scan_complete THEN
    RETURN pg_catalog.jsonb_build_object('pairs', v_pairs,
      'next_user_a_id', v_batch.pair_cursor_user_a,
      'next_user_b_id', v_batch.pair_cursor_user_b, 'done', true);
  END IF;
  IF v_batch.pair_cursor_user_a IS DISTINCT FROM p_after_user_a_id
     OR v_batch.pair_cursor_user_b IS DISTINCT FROM p_after_user_b_id THEN
    RAISE EXCEPTION 'daily matching pair cursor changed';
  END IF;

  WITH page AS MATERIALIZED (
    SELECT member_a.user_id AS user_a_id,
           member_b.user_id AS user_b_id,
           member_a.eligibility_snapshot AS eligibility_a,
           member_b.eligibility_snapshot AS eligibility_b,
           member_a.scoring_profile_snapshot AS profile_a,
           member_b.scoring_profile_snapshot AS profile_b,
           member_a.persona_traits AS persona_traits_a,
           member_b.persona_traits AS persona_traits_b,
           member_a.profile_version AS profile_version_a,
           member_b.profile_version AS profile_version_b,
           member_a.profile_updated_at AS profile_updated_at_a,
           member_b.profile_updated_at AS profile_updated_at_b,
           member_a.persona_version AS persona_version_a,
           member_b.persona_version AS persona_version_b,
           EXISTS (
             SELECT 1 FROM public.blocks AS block_row
              WHERE (block_row.blocker_id = member_a.user_id AND block_row.blocked_id = member_b.user_id)
                 OR (block_row.blocker_id = member_b.user_id AND block_row.blocked_id = member_a.user_id)
           ) AS blocked,
           EXISTS (
             SELECT 1 FROM public.matches AS match_row
              WHERE match_row.user_a_id = member_a.user_id AND match_row.user_b_id = member_b.user_id
           ) AS existing_match
      FROM wingward_private.daily_matching_batch_members AS member_a
      JOIN wingward_private.daily_matching_batch_members AS member_b
        ON member_b.batch_id = member_a.batch_id AND member_a.user_id < member_b.user_id
      WHERE member_a.batch_id = p_batch_id
        AND member_a.scoring_profile_snapshot IS NOT NULL
        AND member_b.scoring_profile_snapshot IS NOT NULL
        AND ((member_a.user_id = ANY (ARRAY[
          '96b31c0a-b8c4-4536-ada2-f3537dadd146'::uuid,
          '9d836fee-7b93-41ce-b577-34a63006aaea'::uuid,
          'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'::uuid
        ])) = (member_b.user_id = ANY (ARRAY[
          '96b31c0a-b8c4-4536-ada2-f3537dadd146'::uuid,
          '9d836fee-7b93-41ce-b577-34a63006aaea'::uuid,
          'd327a193-9eeb-42b1-bac4-fb5bea3ca21f'::uuid
        ])))
        AND (p_after_user_a_id IS NULL OR
             (member_a.user_id, member_b.user_id) > (p_after_user_a_id, p_after_user_b_id))
      ORDER BY member_a.user_id, member_b.user_id
      LIMIT p_limit
  )
  SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'user_a_id', page.user_a_id, 'user_b_id', page.user_b_id,
           'eligibility_a', page.eligibility_a, 'eligibility_b', page.eligibility_b,
           'profile_a', page.profile_a, 'profile_b', page.profile_b,
           'persona_traits_a', page.persona_traits_a, 'persona_traits_b', page.persona_traits_b,
           'profile_version_a', page.profile_version_a, 'profile_version_b', page.profile_version_b,
           'profile_updated_at_a', page.profile_updated_at_a, 'profile_updated_at_b', page.profile_updated_at_b,
           'persona_version_a', page.persona_version_a, 'persona_version_b', page.persona_version_b,
           'blocked', page.blocked, 'existing_match', page.existing_match
         ) ORDER BY page.user_a_id, page.user_b_id), '[]'::jsonb),
         pg_catalog.count(*)::integer
    INTO v_pairs, v_count
    FROM page;
  IF v_count > 0 THEN
    v_next_a := (v_pairs -> (v_count - 1) ->> 'user_a_id')::uuid;
    v_next_b := (v_pairs -> (v_count - 1) ->> 'user_b_id')::uuid;
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'pairs', v_pairs, 'next_user_a_id', v_next_a,
    'next_user_b_id', v_next_b, 'done', v_count < p_limit
  );
END;
$$;

CREATE FUNCTION public.stage_durable_daily_matching_candidate_page(
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint,
  p_after_user_a_id uuid,
  p_after_user_b_id uuid,
  p_next_user_a_id uuid,
  p_next_user_b_id uuid,
  p_candidates jsonb,
  p_done boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.daily_match_batches%ROWTYPE;
  v_candidate jsonb;
  v_a uuid;
  v_b uuid;
  v_score numeric;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF pg_catalog.jsonb_typeof(p_candidates) <> 'array'
     OR pg_catalog.jsonb_array_length(p_candidates) > 100
     OR ((p_next_user_a_id IS NULL) <> (p_next_user_b_id IS NULL))
     OR ((p_after_user_a_id IS NULL) <> (p_after_user_b_id IS NULL)) THEN
    RAISE EXCEPTION 'invalid candidate page';
  END IF;
  UPDATE public.daily_match_batches AS batch_row
     SET lease_expires_at = v_now + interval '3 minutes'
   WHERE batch_row.id = p_batch_id AND batch_row.status = 'matching'
     AND batch_row.lease_token = p_lease_token
     AND batch_row.lease_generation = p_lease_generation
     AND batch_row.lease_expires_at > v_now
  RETURNING * INTO v_batch;
  IF NOT FOUND THEN RAISE EXCEPTION 'daily matching lease lost'; END IF;
  IF NOT v_batch.member_scan_complete OR v_batch.pair_scan_complete
     OR v_batch.pair_cursor_user_a IS DISTINCT FROM p_after_user_a_id
     OR v_batch.pair_cursor_user_b IS DISTINCT FROM p_after_user_b_id THEN
    RAISE EXCEPTION 'daily matching pair cursor changed';
  END IF;

  FOR v_candidate IN SELECT value FROM pg_catalog.jsonb_array_elements(p_candidates) LOOP
    IF pg_catalog.jsonb_typeof(v_candidate) <> 'object'
       OR pg_catalog.jsonb_typeof(v_candidate -> 'score_details') <> 'object'
       OR pg_catalog.jsonb_typeof(v_candidate -> 'layer_scores') <> 'object'
       OR pg_catalog.jsonb_typeof(v_candidate -> 'feature_scores') <> 'array' THEN
      RAISE EXCEPTION 'invalid scored candidate';
    END IF;
    v_a := (v_candidate ->> 'user_a_id')::uuid;
    v_b := (v_candidate ->> 'user_b_id')::uuid;
    v_score := (v_candidate ->> 'score')::numeric;
    IF v_a >= v_b OR v_score < 0 OR v_score > 100 THEN
      RAISE EXCEPTION 'invalid scored candidate values';
    END IF;
    IF NOT EXISTS (
      SELECT 1
        FROM wingward_private.daily_matching_batch_members AS member_a
        JOIN wingward_private.daily_matching_batch_members AS member_b
          ON member_b.batch_id = member_a.batch_id
       WHERE member_a.batch_id = p_batch_id
         AND member_a.user_id = v_a AND member_b.user_id = v_b
         AND member_a.scoring_profile_snapshot IS NOT NULL
         AND member_b.scoring_profile_snapshot IS NOT NULL
         AND wingward_private.daily_matching_snapshot_pair_is_eligible(
               member_a.eligibility_snapshot, member_b.eligibility_snapshot)
    ) THEN
      RAISE EXCEPTION 'candidate is outside the eligible snapshot';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.blocks AS block_row
       WHERE (block_row.blocker_id = v_a AND block_row.blocked_id = v_b)
          OR (block_row.blocker_id = v_b AND block_row.blocked_id = v_a)
    ) OR EXISTS (
      SELECT 1 FROM public.matches AS match_row
       WHERE match_row.user_a_id = v_a AND match_row.user_b_id = v_b
    ) THEN
      CONTINUE;
    END IF;
    INSERT INTO wingward_private.daily_matching_batch_candidates(
      batch_id, user_a_id, user_b_id, score, score_details, layer_scores, feature_scores
    ) VALUES (
      p_batch_id, v_a, v_b, v_score,
      v_candidate -> 'score_details', v_candidate -> 'layer_scores', v_candidate -> 'feature_scores'
    ) ON CONFLICT (batch_id, user_a_id, user_b_id) DO NOTHING;
  END LOOP;

  UPDATE public.daily_match_batches AS batch_row
     SET pair_cursor_user_a = p_next_user_a_id,
         pair_cursor_user_b = p_next_user_b_id,
         pair_scan_complete = p_done
   WHERE batch_row.id = p_batch_id;
  RETURN true;
END;
$$;

CREATE FUNCTION public.release_durable_daily_matching_lease(
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rows integer;
BEGIN
  UPDATE public.daily_match_batches AS batch_row
     SET lease_token = NULL, lease_expires_at = NULL
   WHERE batch_row.id = p_batch_id AND batch_row.status = 'matching'
     AND batch_row.lease_token = p_lease_token
     AND batch_row.lease_generation = p_lease_generation;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END;
$$;

CREATE FUNCTION public.publish_durable_daily_matching_batch(
  p_batch_id uuid,
  p_lease_token uuid,
  p_lease_generation bigint,
  p_max_per_user integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_batch public.daily_match_batches%ROWTYPE;
  v_candidate record;
  v_feature jsonb;
  v_match_id uuid;
  v_matched_users uuid[] := ARRAY[]::uuid[];
  v_match_count integer := 0;
  v_total_users integer := 0;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_snapshot_version_a integer;
  v_snapshot_version_b integer;
  v_snapshot_persona_a integer;
  v_snapshot_persona_b integer;
  v_live_profile_version integer;
  v_live_profile_updated_at timestamptz;
  v_live_persona_version integer;
BEGIN
  IF p_max_per_user <> 1 THEN RAISE EXCEPTION 'daily allocation limit must be one'; END IF;
  -- A single transaction-wide publisher lock prevents overlapping dates from
  -- taking participant profile locks in different score orders. Pair helper
  -- locks remain UUID-ordered and use the same lock discipline as blocks.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('wingward:daily-matching:publish', 0)
  );
  SELECT * INTO v_batch
    FROM public.daily_match_batches AS batch_row
   WHERE batch_row.id = p_batch_id AND batch_row.status = 'matching'
     AND batch_row.lease_token = p_lease_token
     AND batch_row.lease_generation = p_lease_generation
     AND batch_row.lease_expires_at > v_now
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'daily matching lease lost'; END IF;
  IF NOT v_batch.member_scan_complete OR NOT v_batch.pair_scan_complete THEN
    RAISE EXCEPTION 'daily matching scan is incomplete';
  END IF;

  SELECT pg_catalog.count(*)::integer INTO v_total_users
    FROM wingward_private.daily_matching_batch_members AS member_row
   WHERE member_row.batch_id = p_batch_id
     AND member_row.scoring_profile_snapshot IS NOT NULL
     AND wingward_private.daily_matching_snapshot_is_eligible(member_row.eligibility_snapshot);

  FOR v_candidate IN
    SELECT candidate.*
      FROM wingward_private.daily_matching_batch_candidates AS candidate
      JOIN wingward_private.daily_matching_batch_members AS member_a
        ON member_a.batch_id = candidate.batch_id AND member_a.user_id = candidate.user_a_id
      JOIN wingward_private.daily_matching_batch_members AS member_b
        ON member_b.batch_id = candidate.batch_id AND member_b.user_id = candidate.user_b_id
      JOIN public.user_profiles AS current_a ON current_a.id = candidate.user_a_id
      JOIN public.user_profiles AS current_b ON current_b.id = candidate.user_b_id
      JOIN public.profiles AS profile_a
        ON profile_a.user_id = current_a.id AND profile_a.status = 'confirmed'
       AND profile_a.version = member_a.profile_version
       AND profile_a.updated_at = member_a.profile_updated_at
      JOIN public.profiles AS profile_b
        ON profile_b.user_id = current_b.id AND profile_b.status = 'confirmed'
       AND profile_b.version = member_b.profile_version
       AND profile_b.updated_at = member_b.profile_updated_at
     WHERE candidate.batch_id = p_batch_id
       AND wingward_private.daily_matching_snapshot_pair_is_eligible(
             jsonb_build_object('id', current_a.id, 'age_verified_at', current_a.age_verified_at,
               'gender_identity', current_a.gender_identity, 'preferred_genders', to_jsonb(current_a.preferred_genders),
               'preference_mode', current_a.preference_mode, 'dating_market', current_a.dating_market,
               'onboarding_settings_completed_at', current_a.onboarding_settings_completed_at),
             jsonb_build_object('id', current_b.id, 'age_verified_at', current_b.age_verified_at,
               'gender_identity', current_b.gender_identity, 'preferred_genders', to_jsonb(current_b.preferred_genders),
               'preference_mode', current_b.preference_mode, 'dating_market', current_b.dating_market,
               'onboarding_settings_completed_at', current_b.onboarding_settings_completed_at))
       AND COALESCE((SELECT pg_catalog.max(persona.version)
                       FROM public.user_persona_versions AS persona
                      WHERE persona.user_id = current_a.id AND persona.confirmed_at IS NOT NULL), 0) = member_a.persona_version
       AND COALESCE((SELECT pg_catalog.max(persona.version)
                       FROM public.user_persona_versions AS persona
                      WHERE persona.user_id = current_b.id AND persona.confirmed_at IS NOT NULL), 0) = member_b.persona_version
       AND NOT EXISTS (
         SELECT 1 FROM public.blocks AS block_row
          WHERE (block_row.blocker_id = candidate.user_a_id AND block_row.blocked_id = candidate.user_b_id)
             OR (block_row.blocker_id = candidate.user_b_id AND block_row.blocked_id = candidate.user_a_id)
       )
       AND NOT EXISTS (
         SELECT 1 FROM public.matches AS match_row
          WHERE match_row.user_a_id = candidate.user_a_id AND match_row.user_b_id = candidate.user_b_id
       )
     ORDER BY candidate.score DESC, candidate.user_a_id, candidate.user_b_id
  LOOP
    IF v_candidate.user_a_id = ANY (v_matched_users)
       OR v_candidate.user_b_id = ANY (v_matched_users) THEN
      CONTINUE;
    END IF;

    -- This helper locks the current user_profiles in UUID order and checks
    -- both block directions after those locks. Reflection confirmation uses
    -- the same locks, so the persona version cannot advance during publish.
    IF NOT wingward_private.lock_and_check_mutual_eligibility(
      v_candidate.user_a_id, v_candidate.user_b_id
    ) THEN
      CONTINUE;
    END IF;
    -- Compare the exact consent and verification inputs used for scoring with
    -- the current rows protected by the helper's UUID-ordered FOR SHARE locks.
    -- A still-eligible but changed preference is not the same consent snapshot.
    IF NOT EXISTS (
      SELECT 1
        FROM wingward_private.daily_matching_batch_members AS member_a
        JOIN wingward_private.daily_matching_batch_members AS member_b
          ON member_b.batch_id = member_a.batch_id
        JOIN public.user_profiles AS current_a ON current_a.id = member_a.user_id
        JOIN public.user_profiles AS current_b ON current_b.id = member_b.user_id
       WHERE member_a.batch_id = p_batch_id
         AND member_a.user_id = v_candidate.user_a_id
         AND member_b.user_id = v_candidate.user_b_id
         AND member_a.eligibility_snapshot IS NOT DISTINCT FROM pg_catalog.jsonb_build_object(
           'id', current_a.id, 'age_verified_at', current_a.age_verified_at,
           'gender_identity', current_a.gender_identity,
           'preferred_genders', pg_catalog.to_jsonb(current_a.preferred_genders),
           'preference_mode', current_a.preference_mode,
           'dating_market', current_a.dating_market,
           'onboarding_settings_completed_at', current_a.onboarding_settings_completed_at
         )
         AND member_b.eligibility_snapshot IS NOT DISTINCT FROM pg_catalog.jsonb_build_object(
           'id', current_b.id, 'age_verified_at', current_b.age_verified_at,
           'gender_identity', current_b.gender_identity,
           'preferred_genders', pg_catalog.to_jsonb(current_b.preferred_genders),
           'preference_mode', current_b.preference_mode,
           'dating_market', current_b.dating_market,
           'onboarding_settings_completed_at', current_b.onboarding_settings_completed_at
         )
    ) THEN
      CONTINUE;
    END IF;
    SELECT member_row.profile_version, member_row.persona_version
      INTO v_snapshot_version_a, v_snapshot_persona_a
      FROM wingward_private.daily_matching_batch_members AS member_row
     WHERE member_row.batch_id = p_batch_id AND member_row.user_id = v_candidate.user_a_id;
    SELECT member_row.profile_version, member_row.persona_version
      INTO v_snapshot_version_b, v_snapshot_persona_b
      FROM wingward_private.daily_matching_batch_members AS member_row
     WHERE member_row.batch_id = p_batch_id AND member_row.user_id = v_candidate.user_b_id;

    -- Lock the current scoring profiles in the same UUID order and compare
    -- the locked versions/timestamps with the immutable batch snapshot.
    SELECT profile_row.version, profile_row.updated_at
      INTO v_live_profile_version, v_live_profile_updated_at
      FROM public.profiles AS profile_row
     WHERE profile_row.user_id = v_candidate.user_a_id AND profile_row.status = 'confirmed'
     FOR SHARE;
    IF NOT FOUND OR v_live_profile_version IS DISTINCT FROM v_snapshot_version_a
       OR v_live_profile_updated_at IS DISTINCT FROM (
         SELECT member_row.profile_updated_at FROM wingward_private.daily_matching_batch_members AS member_row
          WHERE member_row.batch_id = p_batch_id AND member_row.user_id = v_candidate.user_a_id
       ) THEN
      CONTINUE;
    END IF;
    SELECT profile_row.version, profile_row.updated_at
      INTO v_live_profile_version, v_live_profile_updated_at
      FROM public.profiles AS profile_row
     WHERE profile_row.user_id = v_candidate.user_b_id AND profile_row.status = 'confirmed'
     FOR SHARE;
    IF NOT FOUND OR v_live_profile_version IS DISTINCT FROM v_snapshot_version_b
       OR v_live_profile_updated_at IS DISTINCT FROM (
         SELECT member_row.profile_updated_at FROM wingward_private.daily_matching_batch_members AS member_row
          WHERE member_row.batch_id = p_batch_id AND member_row.user_id = v_candidate.user_b_id
       ) THEN
      CONTINUE;
    END IF;
    SELECT COALESCE(pg_catalog.max(persona.version), 0)::integer
      INTO v_live_persona_version
      FROM public.user_persona_versions AS persona
     WHERE persona.user_id = v_candidate.user_a_id AND persona.confirmed_at IS NOT NULL;
    IF v_live_persona_version IS DISTINCT FROM v_snapshot_persona_a THEN CONTINUE; END IF;
    SELECT COALESCE(pg_catalog.max(persona.version), 0)::integer
      INTO v_live_persona_version
      FROM public.user_persona_versions AS persona
     WHERE persona.user_id = v_candidate.user_b_id AND persona.confirmed_at IS NOT NULL;
    IF v_live_persona_version IS DISTINCT FROM v_snapshot_persona_b THEN CONTINUE; END IF;

    INSERT INTO public.matches(
      user_a_id, user_b_id, profile_score, final_score, score_details, layer_scores, batch_id
    ) VALUES (
      v_candidate.user_a_id, v_candidate.user_b_id, v_candidate.score, NULL,
      v_candidate.score_details, v_candidate.layer_scores, p_batch_id
    ) ON CONFLICT (user_a_id, user_b_id) DO NOTHING
    RETURNING id INTO v_match_id;
    IF v_match_id IS NULL THEN CONTINUE; END IF;

    INSERT INTO public.daily_match_pairs(match_id, match_date)
    VALUES (v_match_id, v_batch.batch_date);
    FOR v_feature IN SELECT value FROM pg_catalog.jsonb_array_elements(v_candidate.feature_scores) LOOP
      INSERT INTO public.interaction_dna_scores(
        match_id, feature_id, feature_name, raw_score, normalized_score,
        confidence, evidence, source_phase
      ) VALUES (
        v_match_id, (v_feature ->> 'featureId')::smallint,
        v_feature ->> 'featureName', (v_feature ->> 'rawScore')::numeric,
        (v_feature ->> 'normalizedScore')::numeric,
        (v_feature ->> 'confidence')::numeric,
        COALESCE(v_feature -> 'evidence', '{}'::jsonb), v_feature ->> 'sourcePhase'
      ) ON CONFLICT (match_id, feature_id, source_phase) DO NOTHING;
    END LOOP;

    INSERT INTO wingward_private.daily_matching_notification_outbox(batch_id, match_id, user_id)
    VALUES (p_batch_id, v_match_id, v_candidate.user_a_id),
           (p_batch_id, v_match_id, v_candidate.user_b_id);
    v_matched_users := pg_catalog.array_append(v_matched_users, v_candidate.user_a_id);
    v_matched_users := pg_catalog.array_append(v_matched_users, v_candidate.user_b_id);
    v_match_count := v_match_count + 1;
  END LOOP;

  UPDATE public.daily_match_batches AS batch_row
     SET status = 'completed', total_users = v_total_users,
         users_matched = pg_catalog.cardinality(v_matched_users),
         total_matches = v_match_count, completed_at = v_now, published_at = v_now,
         lease_token = NULL, lease_expires_at = NULL
   WHERE batch_row.id = p_batch_id;
  RETURN pg_catalog.jsonb_build_object(
    'state', 'completed', 'batch_id', p_batch_id,
    'total_users', v_total_users, 'users_matched', pg_catalog.cardinality(v_matched_users),
    'total_matches', v_match_count
  );
END;
$$;


CREATE FUNCTION public.get_durable_daily_matching_conversation_status(p_batch_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'requested_count', pg_catalog.count(conversation.id)::integer,
    'pending_count', pg_catalog.count(*) FILTER (WHERE conversation.status = 'pending')::integer,
    'in_progress_count', pg_catalog.count(*) FILTER (WHERE conversation.status = 'in_progress')::integer,
    'completed_count', pg_catalog.count(*) FILTER (WHERE conversation.status = 'completed')::integer,
    'failed_count', pg_catalog.count(*) FILTER (WHERE conversation.status = 'failed')::integer
  )
    FROM public.matches AS match_row
    JOIN public.daily_match_batches AS batch_row
      ON batch_row.id = match_row.batch_id AND batch_row.status = 'completed'
    JOIN public.fox_conversations AS conversation
      ON conversation.match_id = match_row.id AND conversation.purpose = 'compatibility'
   WHERE batch_row.id = p_batch_id
$$;

CREATE FUNCTION public.claim_daily_matching_notification_outbox(
  p_limit integer,
  p_lease_seconds integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_rows jsonb;
BEGIN
  IF p_limit < 1 OR p_limit > 2 OR p_lease_seconds < 30 OR p_lease_seconds > 600 THEN
    RETURN '[]'::jsonb;
  END IF;
  WITH selected AS MATERIALIZED (
    SELECT outbox.batch_id, outbox.match_id, outbox.user_id
      FROM wingward_private.daily_matching_notification_outbox AS outbox
      JOIN public.daily_match_batches AS batch_row
        ON batch_row.id = outbox.batch_id AND batch_row.status = 'completed'
      JOIN public.matches AS match_row
        ON match_row.id = outbox.match_id
       AND outbox.user_id IN (match_row.user_a_id, match_row.user_b_id)
      JOIN public.fox_conversations AS conversation
        ON conversation.match_id = outbox.match_id AND conversation.purpose = 'compatibility'
       AND conversation.status = 'completed'
     WHERE outbox.status <> 'completed'
       AND outbox.available_at <= v_now
       AND (outbox.status = 'pending' OR outbox.lease_expires_at <= v_now)
     ORDER BY outbox.available_at, outbox.batch_id, outbox.match_id, outbox.user_id
     FOR UPDATE OF outbox SKIP LOCKED
     LIMIT p_limit
  ), claimed AS (
    UPDATE wingward_private.daily_matching_notification_outbox AS outbox
       SET status = 'leased', claim_token = gen_random_uuid(),
           claim_generation = outbox.claim_generation + 1,
           lease_expires_at = v_now + pg_catalog.make_interval(secs => p_lease_seconds),
           attempt_count = outbox.attempt_count + 1
      FROM selected
     WHERE outbox.batch_id = selected.batch_id
       AND outbox.match_id = selected.match_id
       AND outbox.user_id = selected.user_id
    RETURNING outbox.batch_id, outbox.match_id, outbox.user_id,
              outbox.claim_token, outbox.claim_generation
  )
  SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
           'batch_id', claimed.batch_id, 'match_id', claimed.match_id,
           'user_id', claimed.user_id, 'conversation_id', conversation.id,
           'claim_token', claimed.claim_token,
           'claim_generation', claimed.claim_generation
         ) ORDER BY claimed.batch_id, claimed.match_id, claimed.user_id), '[]'::jsonb)
    INTO v_rows
    FROM claimed
    JOIN public.fox_conversations AS conversation
      ON conversation.match_id = claimed.match_id AND conversation.purpose = 'compatibility'
       AND conversation.status = 'completed';
  RETURN v_rows;
END;
$$;

CREATE FUNCTION public.complete_daily_matching_notification_outbox(
  p_batch_id uuid,
  p_match_id uuid,
  p_user_id uuid,
  p_claim_token uuid,
  p_claim_generation bigint,
  p_notification_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rows integer;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  UPDATE wingward_private.daily_matching_notification_outbox AS outbox
     SET status = 'completed', notification_id = p_notification_id,
         completed_at = v_now, claim_token = NULL, lease_expires_at = NULL
    FROM public.daily_match_batches AS batch_row,
         public.matches AS match_row,
         public.fox_conversations AS conversation,
         public.notifications AS notification
   WHERE outbox.batch_id = p_batch_id AND outbox.match_id = p_match_id
     AND outbox.user_id = p_user_id AND outbox.status = 'leased'
     AND outbox.claim_token = p_claim_token
     AND outbox.claim_generation = p_claim_generation
     AND outbox.lease_expires_at > v_now
     AND batch_row.id = outbox.batch_id AND batch_row.status = 'completed'
     AND match_row.id = outbox.match_id
     AND outbox.user_id IN (match_row.user_a_id, match_row.user_b_id)
     AND conversation.match_id = outbox.match_id AND conversation.purpose = 'compatibility'
       AND conversation.status = 'completed'
     AND notification.id = p_notification_id
     AND notification.scenario_id = 'N-01'
     AND notification.user_id = outbox.user_id
     AND notification.match_id = outbox.match_id
     AND notification.payload -> 'delivery_context' ->> 'conversation_id' = conversation.id::text
     AND (notification.sent_at IS NOT NULL OR notification.scheduled_for IS NOT NULL
          OR notification.suppressed_reason = 'no_subscription');
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END;
$$;

CREATE FUNCTION public.release_daily_matching_notification_outbox(
  p_batch_id uuid,
  p_match_id uuid,
  p_user_id uuid,
  p_claim_token uuid,
  p_claim_generation bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_rows integer;
BEGIN
  UPDATE wingward_private.daily_matching_notification_outbox AS outbox
     SET status = 'pending', claim_token = NULL, lease_expires_at = NULL,
         available_at = pg_catalog.clock_timestamp()
           + pg_catalog.make_interval(mins => LEAST(15, outbox.attempt_count))
   WHERE outbox.batch_id = p_batch_id AND outbox.match_id = p_match_id
     AND outbox.user_id = p_user_id AND outbox.status = 'leased'
     AND outbox.claim_token = p_claim_token
     AND outbox.claim_generation = p_claim_generation;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_durable_daily_matching_batch(date, text, text, integer, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.scan_durable_daily_matching_member_page(uuid, uuid, bigint, uuid, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.read_durable_daily_matching_pair_page(uuid, uuid, bigint, uuid, uuid, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.stage_durable_daily_matching_candidate_page(uuid, uuid, bigint, uuid, uuid, uuid, uuid, jsonb, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_durable_daily_matching_lease(uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.publish_durable_daily_matching_batch(uuid, uuid, bigint, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_durable_daily_matching_conversation_status(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION wingward_private.daily_matching_snapshot_is_eligible(jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION wingward_private.daily_matching_snapshot_pair_is_eligible(jsonb, jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.claim_daily_matching_notification_outbox(integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_daily_matching_notification_outbox(uuid, uuid, uuid, uuid, bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_daily_matching_notification_outbox(uuid, uuid, uuid, uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_durable_daily_matching_batch(date, text, text, integer, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.scan_durable_daily_matching_member_page(uuid, uuid, bigint, uuid, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.read_durable_daily_matching_pair_page(uuid, uuid, bigint, uuid, uuid, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.stage_durable_daily_matching_candidate_page(uuid, uuid, bigint, uuid, uuid, uuid, uuid, jsonb, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.release_durable_daily_matching_lease(uuid, uuid, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.publish_durable_daily_matching_batch(uuid, uuid, bigint, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_durable_daily_matching_conversation_status(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.claim_daily_matching_notification_outbox(integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.complete_daily_matching_notification_outbox(uuid, uuid, uuid, uuid, bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.release_daily_matching_notification_outbox(uuid, uuid, uuid, uuid, bigint) TO service_role;

COMMENT ON TABLE wingward_private.daily_matching_batch_members IS
  'Private immutable daily matching input snapshot. Includes every registered profile id at its keyset scan position; only closed eligibility/scoring fields are stored.';
COMMENT ON TABLE wingward_private.daily_matching_batch_candidates IS
  'Private resumable score staging. Rows are not user-visible until the batch publish RPC commits.';
COMMENT ON TABLE wingward_private.daily_matching_notification_outbox IS
  'N-01 delivery intents created atomically with publication; claim requires the published batch and completed Fox conversation.';
