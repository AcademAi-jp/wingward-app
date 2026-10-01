-- Guard private JSON at its storage boundary, including historical and cloned
-- RPCs. Later RPC replacements retain these SECURITY INVOKER row guards.
-- Bad input aborts the RPC transaction with a generic 23514; no payload is
-- echoed and no partial revision, consent, event or replay ledger is retained.
CREATE FUNCTION wingward_private.validate_chat_meetup_location_input()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_keys text[]; v_lat numeric; v_lng numeric; v_walk numeric;
BEGIN
  IF pg_catalog.jsonb_typeof(NEW.origin) IS DISTINCT FROM 'object'
     OR pg_catalog.octet_length(NEW.origin::text) > 1024 THEN
    RAISE check_violation USING MESSAGE = 'invalid meetup location input', CONSTRAINT = 'chat_meetup_location_input_guard';
  END IF;
  SELECT array_agg(k ORDER BY k) INTO v_keys FROM pg_catalog.jsonb_object_keys(NEW.origin) AS keys(k);
  -- Reuse existing cafe-provider name/travel bounds (120 chars/minutes).
  IF NEW.origin ->> 'kind' = 'station' THEN
    IF NEW.method IS DISTINCT FROM 'station'
       OR v_keys IS DISTINCT FROM ARRAY['kind','name','walk_minutes']::text[]
       OR pg_catalog.jsonb_typeof(NEW.origin -> 'name') IS DISTINCT FROM 'string'
       OR pg_catalog.char_length(NEW.origin ->> 'name') NOT BETWEEN 1 AND 120
       OR NEW.origin ->> 'name' IS DISTINCT FROM pg_catalog.btrim(NEW.origin ->> 'name')
       OR NEW.origin ->> 'name' ~ '[[:cntrl:]]'
       OR pg_catalog.jsonb_typeof(NEW.origin -> 'walk_minutes') IS DISTINCT FROM 'number' THEN
      RAISE check_violation USING MESSAGE = 'invalid meetup location input', CONSTRAINT = 'chat_meetup_location_input_guard';
    END IF;
    v_walk := (NEW.origin ->> 'walk_minutes')::numeric;
    IF v_walk < 0 OR v_walk > 120 OR v_walk <> pg_catalog.trunc(v_walk) THEN
      RAISE check_violation USING MESSAGE = 'invalid meetup location input', CONSTRAINT = 'chat_meetup_location_input_guard';
    END IF;
  ELSIF NEW.origin ->> 'kind' = 'coordinates' THEN
    -- This legacy provider-only shape is explicitly coarse: reject extra
    -- decimal precision rather than silently rounding exact coordinates.
    IF NEW.method IS DISTINCT FROM 'current'
       OR v_keys IS DISTINCT FROM ARRAY['kind','lat','lng']::text[]
       OR pg_catalog.jsonb_typeof(NEW.origin -> 'lat') IS DISTINCT FROM 'number'
       OR pg_catalog.jsonb_typeof(NEW.origin -> 'lng') IS DISTINCT FROM 'number' THEN
      RAISE check_violation USING MESSAGE = 'invalid meetup location input', CONSTRAINT = 'chat_meetup_location_input_guard';
    END IF;
    v_lat := (NEW.origin ->> 'lat')::numeric; v_lng := (NEW.origin ->> 'lng')::numeric;
    IF v_lat NOT BETWEEN -90 AND 90 OR v_lng NOT BETWEEN -180 AND 180
       OR v_lat <> pg_catalog.round(v_lat,3) OR v_lng <> pg_catalog.round(v_lng,3) THEN
      RAISE check_violation USING MESSAGE = 'invalid meetup location input', CONSTRAINT = 'chat_meetup_location_input_guard';
    END IF;
  ELSE
    RAISE check_violation USING MESSAGE = 'invalid meetup location input', CONSTRAINT = 'chat_meetup_location_input_guard';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION wingward_private.validate_chat_meetup_location_input() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER chat_meetup_location_input_guard
BEFORE INSERT OR UPDATE OF method, origin ON public.chat_meetup_locations
FOR EACH ROW EXECUTE FUNCTION wingward_private.validate_chat_meetup_location_input();

CREATE FUNCTION wingward_private.validate_chat_meetup_availability_input()
RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_entry jsonb; v_keys text[]; v_start timestamptz; v_end timestamptz;
BEGIN
  -- Validate format and the existing 21-day window span, not relative-now.
  -- Valid inputs remain valid after expiry; API DTO owns upcoming-window checks.
  IF NOT pg_catalog.isfinite(NEW.window_starts_at) OR NOT pg_catalog.isfinite(NEW.window_ends_at)
     OR NEW.window_ends_at <= NEW.window_starts_at
     OR NEW.window_ends_at > NEW.window_starts_at + interval '21 days'
     OR pg_catalog.jsonb_typeof(NEW.intervals) IS DISTINCT FROM 'array'
     OR pg_catalog.octet_length(NEW.intervals::text) > 32768 THEN
    RAISE check_violation USING MESSAGE = 'invalid meetup availability input', CONSTRAINT = 'chat_meetup_availability_input_guard';
  END IF;
  IF pg_catalog.jsonb_array_length(NEW.intervals) > 128 THEN
    RAISE check_violation USING MESSAGE = 'invalid meetup availability input', CONSTRAINT = 'chat_meetup_availability_input_guard';
  END IF;
  FOR v_entry IN SELECT value FROM pg_catalog.jsonb_array_elements(NEW.intervals) AS elements(value) LOOP
    IF pg_catalog.jsonb_typeof(v_entry) IS DISTINCT FROM 'object' THEN
      RAISE check_violation USING MESSAGE = 'invalid meetup availability input', CONSTRAINT = 'chat_meetup_availability_input_guard';
    END IF;
    SELECT array_agg(k ORDER BY k) INTO v_keys FROM pg_catalog.jsonb_object_keys(v_entry) AS keys(k);
    IF v_keys IS DISTINCT FROM ARRAY['ends_at','starts_at']::text[]
       OR pg_catalog.jsonb_typeof(v_entry -> 'starts_at') IS DISTINCT FROM 'string'
       OR pg_catalog.jsonb_typeof(v_entry -> 'ends_at') IS DISTINCT FROM 'string'
       OR pg_catalog.char_length(v_entry ->> 'starts_at') > 32
       OR pg_catalog.char_length(v_entry ->> 'ends_at') > 32
       OR (v_entry ->> 'starts_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|\+00:00)$'
       OR (v_entry ->> 'ends_at') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|\+00:00)$' THEN
      RAISE check_violation USING MESSAGE = 'invalid meetup availability input', CONSTRAINT = 'chat_meetup_availability_input_guard';
    END IF;
    BEGIN
      v_start := (v_entry ->> 'starts_at')::timestamptz;
      v_end := (v_entry ->> 'ends_at')::timestamptz;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
      RAISE check_violation USING MESSAGE = 'invalid meetup availability input', CONSTRAINT = 'chat_meetup_availability_input_guard';
    END;
    IF NOT pg_catalog.isfinite(v_start) OR NOT pg_catalog.isfinite(v_end)
       OR v_start < NEW.window_starts_at OR v_end > NEW.window_ends_at OR v_end <= v_start THEN
      RAISE check_violation USING MESSAGE = 'invalid meetup availability input', CONSTRAINT = 'chat_meetup_availability_input_guard';
    END IF;
  END LOOP;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION wingward_private.validate_chat_meetup_availability_input() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER chat_meetup_availability_input_guard
BEFORE INSERT OR UPDATE OF source, window_starts_at, window_ends_at, intervals ON public.chat_meetup_availability
FOR EACH ROW EXECUTE FUNCTION wingward_private.validate_chat_meetup_availability_input();
