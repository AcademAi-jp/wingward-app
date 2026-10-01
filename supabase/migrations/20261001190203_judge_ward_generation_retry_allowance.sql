-- Partner creation performs six separately bounded provider requests.
-- Allow retries without increasing the actor-wide daily allowance.
ALTER TABLE wingward_private.judge_provider_policies
  DROP CONSTRAINT judge_provider_policies_daily_limit_check;
ALTER TABLE wingward_private.judge_provider_policies
  ADD CONSTRAINT judge_provider_policies_daily_limit_check CHECK (
    daily_limit >= 1 AND (
      daily_limit <= 12 OR (operation = 'ward_generate' AND daily_limit <= 48)
    )
  );
UPDATE wingward_private.judge_provider_policies
SET daily_limit = 48
WHERE operation = 'ward_generate';
