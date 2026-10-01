-- Backfill persona icon_url for existing rows: random fox icon by user_profiles.gender (male/female).
-- Matches apps/api/src/lib/fox-icons.ts icon lists and logic (other/undisclosed → random from all).

WITH icon_pools AS (
  SELECT
    ARRAY[
      '/foxes/male/normal.png',
      '/foxes/male/balckfox.png',
      '/foxes/male/glasses.png',
      '/foxes/male/face.png',
      '/foxes/male/sunglasses.png',
      '/foxes/male/tie.png',
      '/foxes/male/pias.png'
    ] AS male_icons,
    ARRAY[
      '/foxes/female/ribbon.png',
      '/foxes/female/whitefox_glasses.png',
      '/foxes/female/whitefox.png',
      '/foxes/female/whtefox_hat.png',
      '/foxes/female/pinkfox.png',
      '/foxes/female/pinkfox_cap.png',
      '/foxes/female/whitefox_blue_ribbon.png'
    ] AS female_icons,
    ARRAY[
      '/foxes/male/normal.png',
      '/foxes/male/balckfox.png',
      '/foxes/male/glasses.png',
      '/foxes/male/face.png',
      '/foxes/male/sunglasses.png',
      '/foxes/male/tie.png',
      '/foxes/male/pias.png',
      '/foxes/female/ribbon.png',
      '/foxes/female/whitefox_glasses.png',
      '/foxes/female/whitefox.png',
      '/foxes/female/whtefox_hat.png',
      '/foxes/female/pinkfox.png',
      '/foxes/female/pinkfox_cap.png',
      '/foxes/female/whitefox_blue_ribbon.png'
    ] AS all_icons
),
personas_to_backfill AS (
  SELECT
    p.id AS persona_id,
    lower(coalesce(up.gender, '')) AS gender,
    ip.male_icons,
    ip.female_icons,
    ip.all_icons
  FROM public.personas p
  JOIN public.user_profiles up ON up.id = p.user_id
  CROSS JOIN icon_pools ip
  WHERE p.icon_url IS NULL
),
random_icons AS (
  SELECT
    persona_id,
    CASE
      WHEN gender = 'male' THEN male_icons[1 + floor(random() * array_length(male_icons, 1))::int]
      WHEN gender = 'female' THEN female_icons[1 + floor(random() * array_length(female_icons, 1))::int]
      ELSE all_icons[1 + floor(random() * array_length(all_icons, 1))::int]
    END AS icon_url
  FROM personas_to_backfill
)
UPDATE public.personas p
SET
  icon_url = r.icon_url,
  updated_at = now()
FROM random_icons r
WHERE p.id = r.persona_id;
