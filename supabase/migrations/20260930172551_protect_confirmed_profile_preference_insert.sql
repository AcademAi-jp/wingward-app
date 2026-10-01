-- Preserve existing client profile creation while preventing fabricated
-- owner-confirmed preferences during INSERT. Normal confirmation is trusted SQL.
REVOKE INSERT ON TABLE public.profiles FROM authenticated;
DO $columns$
DECLARE columns text;
BEGIN
 SELECT pg_catalog.string_agg(pg_catalog.quote_ident(attname),', ' ORDER BY attnum)
 INTO columns FROM pg_catalog.pg_attribute
 WHERE attrelid='public.profiles'::regclass AND attnum>0 AND NOT attisdropped
 AND attname NOT IN('confirmed_preferences','merged_persona_version');
 EXECUTE 'GRANT INSERT ('||columns||') ON TABLE public.profiles TO authenticated';
END;
$columns$;
