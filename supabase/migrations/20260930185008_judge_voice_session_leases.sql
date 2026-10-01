-- A provider reservation is permanent; a runtime lease closes only after the
-- server acknowledges provider hangup (or that no provider call was created).
CREATE TABLE wingward_private.judge_voice_leases (
 reservation_id uuid PRIMARY KEY REFERENCES wingward_private.judge_provider_reservations(reservation_id),
 actor_user_id uuid NOT NULL REFERENCES wingward_private.judge_accounts(actor_user_id),
 context_kind text NOT NULL CHECK(context_kind IN('interview','reflection')),
 context_id uuid NOT NULL,
 idempotency_key uuid NOT NULL,
 starts_at timestamptz NOT NULL,
 expires_at timestamptz NOT NULL,
 settled_at timestamptz,
 UNIQUE(actor_user_id,context_kind,context_id),
 UNIQUE(actor_user_id,idempotency_key),
 CHECK(pg_catalog.isfinite(starts_at) AND pg_catalog.isfinite(expires_at) AND expires_at>starts_at AND expires_at<=starts_at+interval '180 seconds'),
 CHECK(settled_at IS NULL OR (pg_catalog.isfinite(settled_at) AND settled_at>=starts_at))
);
ALTER TABLE wingward_private.judge_voice_leases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE wingward_private.judge_voice_leases FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION wingward_private.reserve_judge_voice_core(p_user_id uuid,p_context_id uuid,p_idempotency_key uuid,p_kind text)
RETURNS TABLE(outcome text,reservation_id uuid,max_units integer,max_seconds integer,expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $voice$
DECLARE access record;previous wingward_private.judge_voice_leases;reservation record;state record;v_now timestamptz;deadline timestamptz;duration integer;v_operation text;
BEGIN
 IF p_user_id IS NULL OR p_context_id IS NULL OR p_idempotency_key IS NULL OR p_kind NOT IN('interview','reflection') OR p_kind IS NULL THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer,NULL::timestamptz;RETURN;END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('wingward-judge-voice:'||p_user_id::text,0));
 SELECT * INTO access FROM public.check_judge_access(p_user_id);
 IF access.outcome<>'allowed' THEN RETURN QUERY SELECT access.outcome,NULL::uuid,NULL::integer,NULL::integer,NULL::timestamptz;RETURN;END IF;
 IF p_kind='interview' THEN
  IF NOT EXISTS(SELECT 1 FROM public.speed_dating_sessions s JOIN public.personas p ON p.id=s.persona_id WHERE s.id=p_context_id AND s.user_id=p_user_id AND s.status='active' AND p.user_id=p_user_id AND p.persona_type IN('virtual_similar','virtual_complementary','virtual_discovery')) THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer,NULL::timestamptz;RETURN;END IF;
  v_operation:='voice_session';
 ELSE
  SELECT * INTO state FROM public.get_meetup_reflection_state(p_context_id,p_user_id);
  IF NOT FOUND OR state.outcome<>'ok' THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer,NULL::timestamptz;RETURN;END IF;
  v_operation:='reflection_voice';
 END IF;
 SELECT * INTO previous FROM wingward_private.judge_voice_leases l WHERE l.actor_user_id=p_user_id AND l.context_kind=p_kind AND l.context_id=p_context_id;
 IF FOUND THEN
  IF previous.idempotency_key IS DISTINCT FROM p_idempotency_key THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer,NULL::timestamptz;
  ELSE RETURN QUERY SELECT 'replayed'::text,previous.reservation_id,NULL::integer,NULL::integer,previous.expires_at;END IF;
  RETURN;
 END IF;
 -- An expired lease without provider-close acknowledgement still blocks calls.
 IF EXISTS(SELECT 1 FROM wingward_private.judge_voice_leases l WHERE l.actor_user_id=p_user_id AND l.settled_at IS NULL) THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer,NULL::timestamptz;RETURN;END IF;
 IF NOT EXISTS(SELECT 1 FROM wingward_private.judge_provider_policies p WHERE p.operation=v_operation AND p.enabled AND p.server_bound_enforced AND p.max_seconds<=180) THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer,NULL::timestamptz;RETURN;END IF;
 SELECT * INTO reservation FROM wingward_private.reserve_judge_provider_core(p_user_id,v_operation,p_idempotency_key,true);
 IF reservation.outcome<>'allowed' THEN RETURN QUERY SELECT reservation.outcome,reservation.reservation_id,reservation.max_units,reservation.max_seconds,NULL::timestamptz;RETURN;END IF;
 v_now:=clock_timestamp();deadline:=least(v_now+reservation.max_seconds*interval '1 second',access.expires_at);duration:=floor(extract(epoch FROM deadline-v_now))::integer;
 IF duration<1 THEN RETURN QUERY SELECT 'expired'::text,NULL::uuid,NULL::integer,NULL::integer,NULL::timestamptz;RETURN;END IF;
 INSERT INTO wingward_private.judge_voice_leases(reservation_id,actor_user_id,context_kind,context_id,idempotency_key,starts_at,expires_at) VALUES(reservation.reservation_id,p_user_id,p_kind,p_context_id,p_idempotency_key,v_now,deadline);
 RETURN QUERY SELECT 'allowed'::text,reservation.reservation_id,reservation.max_units,duration,deadline;
END $voice$;
REVOKE ALL ON FUNCTION wingward_private.reserve_judge_voice_core(uuid,uuid,uuid,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.reserve_judge_voice_session(p_user_id uuid,p_session_id uuid,p_idempotency_key uuid)
RETURNS TABLE(outcome text,reservation_id uuid,max_units integer,max_seconds integer,expires_at timestamptz)
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$SELECT * FROM wingward_private.reserve_judge_voice_core(p_user_id,p_session_id,p_idempotency_key,'interview')$$;
REVOKE ALL ON FUNCTION public.reserve_judge_voice_session(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_judge_voice_session(uuid,uuid,uuid) TO service_role;
CREATE FUNCTION public.reserve_judge_reflection_voice_session(p_user_id uuid,p_meetup_id uuid,p_idempotency_key uuid)
RETURNS TABLE(outcome text,reservation_id uuid,max_units integer,max_seconds integer,expires_at timestamptz)
LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$SELECT * FROM wingward_private.reserve_judge_voice_core(p_user_id,p_meetup_id,p_idempotency_key,'reflection')$$;
REVOKE ALL ON FUNCTION public.reserve_judge_reflection_voice_session(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_judge_reflection_voice_session(uuid,uuid,uuid) TO service_role;
CREATE FUNCTION public.settle_judge_voice_session(p_user_id uuid,p_reservation_id uuid)
RETURNS TABLE(outcome text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $settle$
DECLARE lease wingward_private.judge_voice_leases;
BEGIN
 SELECT * INTO lease FROM wingward_private.judge_voice_leases l WHERE l.reservation_id=p_reservation_id AND l.actor_user_id=p_user_id FOR UPDATE;
 IF NOT FOUND THEN RETURN QUERY SELECT 'denied'::text;RETURN;END IF;
 IF lease.settled_at IS NOT NULL THEN RETURN QUERY SELECT 'replayed'::text;RETURN;END IF;
 UPDATE wingward_private.judge_voice_leases SET settled_at=clock_timestamp() WHERE judge_voice_leases.reservation_id=p_reservation_id AND judge_voice_leases.actor_user_id=p_user_id;
 RETURN QUERY SELECT 'settled'::text;
END $settle$;
REVOKE ALL ON FUNCTION public.settle_judge_voice_session(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.settle_judge_voice_session(uuid,uuid) TO service_role;
