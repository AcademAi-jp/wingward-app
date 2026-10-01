-- Synthetic quiz-answer acceptance test. Auth users/profiles and answers are
-- rolled back at the end; this script is intended for the local migration DB.

BEGIN;

INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-0000-0000-000000002801', 'wingward-quiz-a@example.invalid'),
  ('00000000-0000-0000-0000-000000002802', 'wingward-quiz-b@example.invalid');

-- The signup trigger owns profile creation. Give both synthetic users verified
-- profiles so get_user_profile_id() resolves them under authenticated RLS.
UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000002801',
    nickname = 'Quiz A',
    birth_date = DATE '1990-01-01',
    age_verified_at = now(),
    age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-000000002801';

UPDATE public.user_profiles
SET id = '10000000-0000-0000-0000-000000002802',
    nickname = 'Quiz B',
    birth_date = DATE '1991-02-02',
    age_verified_at = now(),
    age_verification_method = 'self_declared'
WHERE auth_user_id = '00000000-0000-0000-0000-000000002802';

SET LOCAL role = 'authenticated';
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000002801"}';

-- A single 10-row INSERT ... ON CONFLICT represents the API's bulk upsert.
INSERT INTO public.quiz_answers (user_id, question_id, selected) VALUES
  ('10000000-0000-0000-0000-000000002801', 'q1', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q2', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q3', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q4', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q5', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q6', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q7', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q8', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q9', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q10', '["a"]'::jsonb)
ON CONFLICT (user_id, question_id) DO UPDATE
SET selected = EXCLUDED.selected;

DO $$
DECLARE
  answer_count integer;
BEGIN
  SELECT count(*) INTO answer_count
  FROM public.quiz_answers
  WHERE user_id = '10000000-0000-0000-0000-000000002801';
  IF answer_count <> 10 THEN
    RAISE EXCEPTION 'FAIL 28-A: first bulk upsert stored % rows instead of 10', answer_count;
  END IF;
  RAISE NOTICE 'PASS 28-A: first bulk upsert stored all 10 answers';
END $$;

-- Replay the exact payload. The user/question unique key must keep 10 rows.
INSERT INTO public.quiz_answers (user_id, question_id, selected) VALUES
  ('10000000-0000-0000-0000-000000002801', 'q1', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q2', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q3', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q4', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q5', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q6', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q7', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q8', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q9', '["a"]'::jsonb),
  ('10000000-0000-0000-0000-000000002801', 'q10', '["a"]'::jsonb)
ON CONFLICT (user_id, question_id) DO UPDATE
SET selected = EXCLUDED.selected;

DO $$
DECLARE
  answer_count integer;
  wrong_values integer;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE selected <> '["a"]'::jsonb)
  INTO answer_count, wrong_values
  FROM public.quiz_answers
  WHERE user_id = '10000000-0000-0000-0000-000000002801';
  IF answer_count <> 10 OR wrong_values <> 0 THEN
    RAISE EXCEPTION 'FAIL 28-B: replay produced % rows and % unexpected values', answer_count, wrong_values;
  END IF;
  RAISE NOTICE 'PASS 28-B: replay is idempotent and keeps exactly 10 answers';
END $$;

-- Give B one valid answer so A's cross-owner reads and updates have a target.
SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000002802"}';
INSERT INTO public.quiz_answers (user_id, question_id, selected)
VALUES ('10000000-0000-0000-0000-000000002802', 'q1', '["b"]'::jsonb)
ON CONFLICT (user_id, question_id) DO UPDATE
SET selected = EXCLUDED.selected;

SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000002801"}';

-- A bad FK in the last row must roll back all preceding upserts in the same
-- statement. Compare the complete answer snapshot before and after the error.
DO $$
DECLARE
  before_rows jsonb;
  after_rows jsonb;
  answer_count integer;
BEGIN
  SELECT jsonb_agg(jsonb_build_object('question_id', question_id, 'selected', selected) ORDER BY question_id)
  INTO before_rows
  FROM public.quiz_answers
  WHERE user_id = '10000000-0000-0000-0000-000000002801';

  BEGIN
    INSERT INTO public.quiz_answers (user_id, question_id, selected) VALUES
      ('10000000-0000-0000-0000-000000002801', 'q1', '["b"]'::jsonb),
      ('10000000-0000-0000-0000-000000002801', 'q2', '["b"]'::jsonb),
      ('10000000-0000-0000-0000-000000002801', 'q3', '["b"]'::jsonb),
      ('10000000-0000-0000-0000-000000002801', 'q4', '["b"]'::jsonb),
      ('10000000-0000-0000-0000-000000002801', 'q5', '["b"]'::jsonb),
      ('10000000-0000-0000-0000-000000002801', 'q6', '["b"]'::jsonb),
      ('10000000-0000-0000-0000-000000002801', 'q7', '["b"]'::jsonb),
      ('10000000-0000-0000-0000-000000002801', 'q8', '["b"]'::jsonb),
      ('10000000-0000-0000-0000-000000002801', 'q9', '["b"]'::jsonb),
      ('10000000-0000-0000-0000-000000002801', '__quiz_test_missing_question_28__', '["b"]'::jsonb)
    ON CONFLICT (user_id, question_id) DO UPDATE
    SET selected = EXCLUDED.selected;

    RAISE EXCEPTION 'FAIL 28-C: invalid question foreign key was accepted';
  EXCEPTION
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'PASS 28-C: invalid question FK rejected the bulk statement';
  END;

  SELECT count(*), jsonb_agg(jsonb_build_object('question_id', question_id, 'selected', selected) ORDER BY question_id)
  INTO answer_count, after_rows
  FROM public.quiz_answers
  WHERE user_id = '10000000-0000-0000-0000-000000002801';
  IF answer_count <> 10 OR after_rows IS DISTINCT FROM before_rows THEN
    RAISE EXCEPTION 'FAIL 28-D: FK failure left quiz answers partially changed';
  END IF;
  RAISE NOTICE 'PASS 28-D: FK failure preserved the full pre-existing answer snapshot';
END $$;

DO $$
DECLARE
  own_rows integer;
  other_rows integer;
  affected integer;
BEGIN
  SELECT count(*) INTO own_rows
  FROM public.quiz_answers
  WHERE user_id = '10000000-0000-0000-0000-000000002801';
  SELECT count(*) INTO other_rows
  FROM public.quiz_answers
  WHERE user_id = '10000000-0000-0000-0000-000000002802';
  IF own_rows <> 10 OR other_rows <> 0 THEN
    RAISE EXCEPTION 'FAIL 28-E: owner A sees % own rows and % rows for owner B', own_rows, other_rows;
  END IF;

  UPDATE public.quiz_answers
  SET selected = '["d"]'::jsonb
  WHERE user_id = '10000000-0000-0000-0000-000000002802'
    AND question_id = 'q1';
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 0 THEN
    RAISE EXCEPTION 'FAIL 28-E: owner A updated owner B answer';
  END IF;

  UPDATE public.quiz_answers
  SET selected = '["d"]'::jsonb
  WHERE user_id = '10000000-0000-0000-0000-000000002801'
    AND question_id = 'q1';
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 1 THEN
    RAISE EXCEPTION 'FAIL 28-E: owner A could not update own answer';
  END IF;
  RAISE NOTICE 'PASS 28-E: owner A can read/update own answers but not owner B answers';
END $$;

SET LOCAL request.jwt.claims = '{"sub": "00000000-0000-0000-0000-000000002802"}';

DO $$
DECLARE
  own_rows integer;
  other_rows integer;
  affected integer;
BEGIN
  SELECT count(*) INTO own_rows
  FROM public.quiz_answers
  WHERE user_id = '10000000-0000-0000-0000-000000002802';
  SELECT count(*) INTO other_rows
  FROM public.quiz_answers
  WHERE user_id = '10000000-0000-0000-0000-000000002801';
  IF own_rows <> 1 OR other_rows <> 0 THEN
    RAISE EXCEPTION 'FAIL 28-F: owner B sees % own rows and % rows for owner A', own_rows, other_rows;
  END IF;

  UPDATE public.quiz_answers
  SET selected = '["c"]'::jsonb
  WHERE user_id = '10000000-0000-0000-0000-000000002801'
    AND question_id = 'q1';
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 0 THEN
    RAISE EXCEPTION 'FAIL 28-F: owner B updated owner A answer';
  END IF;
  RAISE NOTICE 'PASS 28-F: owner B cannot read or update owner A answers';
END $$;

RESET role;
RESET request.jwt.claims;
ROLLBACK;
