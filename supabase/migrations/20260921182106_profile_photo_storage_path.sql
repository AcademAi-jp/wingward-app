-- Draft only for the private profile-photo storage boundary.
-- The bucket and policies stay operator-reviewed; this migration only adds
-- the canonical object path used to renew short-lived signed reads.
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS avatar_storage_path text;

ALTER TABLE public.user_profiles
  ADD CONSTRAINT user_profiles_avatar_storage_path_check
  CHECK (
    avatar_storage_path IS NULL
    OR (
      pg_catalog.length(avatar_storage_path) BETWEEN 1 AND 500
      AND avatar_storage_path = pg_catalog.btrim(avatar_storage_path)
      AND avatar_storage_path NOT LIKE '/%'
      AND avatar_storage_path NOT LIKE '%//%'
    )
  );

COMMENT ON COLUMN public.user_profiles.avatar_storage_path IS
  'Server-owned canonical private Storage object path; never returned to clients.';
