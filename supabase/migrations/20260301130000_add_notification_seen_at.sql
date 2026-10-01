-- Store when the user last opened the notification dropdown (for "notification seen" badge behavior).
-- Notifications created/updated after this time are shown as unseen in the badge.
ALTER TABLE public.user_profiles
ADD COLUMN IF NOT EXISTS notification_seen_at timestamptz;

COMMENT ON COLUMN public.user_profiles.notification_seen_at IS 'Last time user opened the notification dropdown; used to compute unseen notification count across reloads.';
