-- Fictional judge journey only. Real identity verification and ordinary RPCs remain unchanged.
CREATE FUNCTION wingward_private.judge_simulated_admitted(p_actor_id uuid,p_user_id uuid,p_room_id uuid,p_meetup_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $permit$
DECLARE a wingward_private.judge_accounts; access record; m public.matches; room public.direct_chat_rooms; s public.chat_meetup_sessions;
BEGIN
 IF p_actor_id IS NULL OR p_user_id IS NULL OR (p_room_id IS NULL AND p_meetup_id IS NULL) THEN RETURN false; END IF;
 SELECT * INTO a FROM wingward_private.judge_accounts j WHERE j.actor_user_id=p_actor_id FOR UPDATE;
 IF NOT FOUND OR a.access_scope IS DISTINCT FROM 'shipaton-seven-20261001'
  OR a.slot NOT IN('judge01','judge02','judge03','judge04','judge05','owner01','owner02')
  OR a.issued_at<'2026-09-30T00:00:00Z' OR a.expires_at>'2026-10-13T19:00:00Z'
  OR NOT isfinite(a.issued_at) OR NOT isfinite(a.expires_at)
  OR p_user_id NOT IN(a.actor_user_id,a.counterpart_user_id) THEN RETURN false; END IF;
 SELECT * INTO access FROM public.check_judge_access(p_actor_id);
 IF access.outcome IS DISTINCT FROM 'allowed' THEN RETURN false; END IF;
 IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(a.actor_user_id,a.counterpart_user_id),false) THEN RETURN false; END IF;
 IF (SELECT count(*) FROM public.profiles p WHERE p.user_id IN(a.actor_user_id,a.counterpart_user_id) AND p.status='confirmed' AND p.confirmed_at IS NOT NULL)<>2 THEN RETURN false; END IF;
 IF p_meetup_id IS NOT NULL THEN
  SELECT * INTO s FROM public.chat_meetup_sessions t WHERE t.meetup_id=p_meetup_id;
  IF NOT FOUND OR (p_room_id IS NOT NULL AND s.room_id<>p_room_id) THEN RETURN false; END IF;
  p_room_id:=s.room_id;
 END IF;
 SELECT * INTO room FROM public.direct_chat_rooms t WHERE t.id=p_room_id;
 IF NOT FOUND THEN RETURN false; END IF;
 SELECT * INTO m FROM public.matches t WHERE t.id=room.match_id FOR UPDATE;
 IF NOT FOUND OR m.status<>'direct_chat_active' OR NOT ((m.user_a_id=a.actor_user_id AND m.user_b_id=a.counterpart_user_id) OR (m.user_b_id=a.actor_user_id AND m.user_a_id=a.counterpart_user_id)) THEN RETURN false; END IF;
 SELECT * INTO room FROM public.direct_chat_rooms t WHERE t.id=p_room_id FOR UPDATE;
 IF NOT FOUND OR room.match_id<>m.id OR room.status<>'active' THEN RETURN false; END IF;
 IF p_meetup_id IS NOT NULL THEN
  SELECT * INTO s FROM public.chat_meetup_sessions t WHERE t.meetup_id=p_meetup_id FOR UPDATE;
  IF NOT FOUND OR s.room_id<>room.id OR s.match_id<>m.id OR s.user_a_id<>m.user_a_id OR s.user_b_id<>m.user_b_id THEN RETURN false; END IF;
 END IF;
 SELECT * INTO access FROM public.check_judge_access(p_actor_id);
 RETURN access.outcome IS NOT DISTINCT FROM 'allowed';
END $permit$;
REVOKE ALL ON FUNCTION wingward_private.judge_simulated_admitted(uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.check_judge_simulated_admission(p_judge_actor_id uuid,p_user_id uuid,p_room_id uuid DEFAULT NULL,p_meetup_id uuid DEFAULT NULL)
RETURNS TABLE(admitted boolean) LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 SELECT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,p_room_id,p_meetup_id);
$$;
REVOKE ALL ON FUNCTION public.check_judge_simulated_admission(uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.check_judge_simulated_admission(uuid,uuid,uuid,uuid) TO service_role;

CREATE FUNCTION public.judge_simulated_apply_chat_meetup_action(p_judge_actor_id uuid,
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_expected_own_revision integer,
  p_idempotency_key uuid,
  p_request_digest text,
  p_action jsonb
)
RETURNS TABLE (
  outcome text,
  meetup_id uuid,
  status text,
  revision integer,
  own_revision integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $wrapper$
BEGIN
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,p_room_id,NULL::uuid) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_apply_chat_meetup_action(true,p_room_id,p_user_id,p_expected_revision,p_expected_own_revision,p_idempotency_key,p_request_digest,p_action);
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,p_room_id,NULL::uuid) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.judge_simulated_apply_chat_meetup_action(uuid,uuid,uuid,integer,integer,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.judge_simulated_apply_chat_meetup_action(uuid,uuid,uuid,integer,integer,uuid,text,jsonb) TO service_role;

CREATE FUNCTION public.judge_simulated_claim_meetup_arrangement(p_judge_actor_id uuid,
  p_meetup_id uuid,
  p_user_id uuid,
  p_is_retry boolean,
  p_operation_key text
)
RETURNS TABLE (
  meetup_id uuid,
  match_id uuid,
  outcome text,
  status text,
  attempt_number integer,
  billing_source text,
  transitioned boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $wrapper$
BEGIN
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,NULL::uuid,p_meetup_id) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_claim_meetup_arrangement(true,p_meetup_id,p_user_id,p_is_retry,p_operation_key);
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,NULL::uuid,p_meetup_id) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.judge_simulated_claim_meetup_arrangement(uuid,uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.judge_simulated_claim_meetup_arrangement(uuid,uuid,uuid,boolean,text) TO service_role;

CREATE FUNCTION public.judge_simulated_publish_chat_meetup_times(p_judge_actor_id uuid,
  p_room_id uuid,
  p_user_id uuid,
  p_expected_revision integer,
  p_first_private_revision integer,
  p_second_private_revision integer,
  p_candidates jsonb,
  p_unavailable_reason text DEFAULT NULL
)
RETURNS TABLE (outcome text, meetup_id uuid, status text, revision integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $wrapper$
BEGIN
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,p_room_id,NULL::uuid) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_publish_chat_meetup_times(true,p_room_id,p_user_id,p_expected_revision,p_first_private_revision,p_second_private_revision,p_candidates,p_unavailable_reason);
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,p_room_id,NULL::uuid) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.judge_simulated_publish_chat_meetup_times(uuid,uuid,uuid,integer,integer,integer,jsonb,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.judge_simulated_publish_chat_meetup_times(uuid,uuid,uuid,integer,integer,integer,jsonb,text) TO service_role;

CREATE FUNCTION public.judge_simulated_get_meetup_reflection_state(p_judge_actor_id uuid,
  p_meetup_id uuid,
  p_user_id uuid
)
RETURNS TABLE (
  outcome text,
  current_version integer,
  traits jsonb,
  confirmed_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $wrapper$
BEGIN
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,NULL::uuid,p_meetup_id) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_get_meetup_reflection_state(true,p_meetup_id,p_user_id);
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,NULL::uuid,p_meetup_id) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.judge_simulated_get_meetup_reflection_state(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.judge_simulated_get_meetup_reflection_state(uuid,uuid,uuid) TO service_role;

CREATE FUNCTION public.judge_simulated_confirm_meetup_reflection(p_judge_actor_id uuid,
  p_meetup_id uuid,
  p_user_id uuid,
  p_idempotency_key uuid,
  p_expected_version integer,
  p_traits jsonb
)
RETURNS TABLE (
  outcome text,
  version integer,
  confirmed_at timestamptz,
  traits jsonb
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $wrapper$
BEGIN
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,NULL::uuid,p_meetup_id) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT * FROM wingward_private.demo_recording_core_confirm_meetup_reflection(true,p_meetup_id,p_user_id,p_idempotency_key,p_expected_version,p_traits);
 IF NOT wingward_private.judge_simulated_admitted(p_judge_actor_id,p_user_id,NULL::uuid,p_meetup_id) THEN RAISE EXCEPTION 'Judge simulation unavailable' USING ERRCODE='42501'; END IF;
END $wrapper$;
REVOKE ALL ON FUNCTION public.judge_simulated_confirm_meetup_reflection(uuid,uuid,uuid,uuid,integer,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.judge_simulated_confirm_meetup_reflection(uuid,uuid,uuid,uuid,integer,jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.advance_judge_counterpart(p_user_id uuid,p_match_id uuid,p_operation text,p_expected_revision integer,p_idempotency_key uuid)
RETURNS TABLE(outcome text,match_id uuid,room_id uuid,meetup_id uuid,status text,revision integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $advance$
DECLARE a wingward_private.judge_accounts;access record;m public.matches;room public.direct_chat_rooms;request public.chat_requests;
 s public.chat_meetup_sessions;own public.chat_meetup_private_decisions;peer public.chat_meetup_private_decisions;
 availability public.chat_meetup_availability;prior wingward_private.judge_counterpart_operations;
 result record;action jsonb;v_revision integer:=0;v_status text;v_mid uuid;v_now timestamptz;failure text;simulated boolean:=false;
BEGIN
 IF p_user_id IS NULL OR p_match_id IS NULL OR p_idempotency_key IS NULL OR p_expected_revision IS NULL OR p_expected_revision<0
  OR p_operation IS NULL OR p_operation NOT IN('accept','intent','availability','time_approve','simulate_completion') THEN
  RETURN QUERY SELECT 'invalid_input'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;RETURN;
 END IF;
 SELECT * INTO a FROM wingward_private.judge_accounts j WHERE j.actor_user_id=p_user_id FOR UPDATE;
 IF NOT FOUND THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;RETURN;END IF;
 SELECT * INTO access FROM public.check_judge_access(p_user_id);
 IF access.outcome<>'allowed' THEN RETURN QUERY SELECT access.outcome,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;RETURN;END IF;
 -- Ren/Maya/Sora recording scenes are permanently excluded from the new journey.
 IF a.counterpart_user_id IN('96b31c0a-b8c4-4536-ada2-f3537dadd146'::uuid,'9d836fee-7b93-41ce-b577-34a63006aaea'::uuid,'d327a193-9eeb-42b1-bac4-fb5bea3ca21f'::uuid) THEN
  RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;RETURN;
 END IF;
 -- Same profile/block lock ordering as normal chat RPC, before match/room locks.
 IF NOT COALESCE(wingward_private.lock_and_check_mutual_eligibility(p_user_id,a.counterpart_user_id),false) THEN
  RETURN QUERY SELECT 'not_found'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;RETURN;
 END IF;
 SELECT * INTO m FROM public.matches t WHERE t.id=p_match_id FOR UPDATE;
 IF NOT FOUND OR NOT ((m.user_a_id=p_user_id AND m.user_b_id=a.counterpart_user_id) OR (m.user_b_id=p_user_id AND m.user_a_id=a.counterpart_user_id)) THEN
  RETURN QUERY SELECT 'not_found'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;RETURN;
 END IF;
 SELECT * INTO room FROM public.direct_chat_rooms t WHERE t.match_id=p_match_id FOR UPDATE;
 IF FOUND THEN
  IF room.status<>'active' THEN RETURN QUERY SELECT 'invalid_state'::text,p_match_id,room.id,NULL::uuid,NULL::text,0;RETURN;END IF;
  SELECT * INTO s FROM public.chat_meetup_sessions t WHERE t.room_id=room.id ORDER BY t.created_at DESC,t.meetup_id DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN v_revision:=s.revision;v_mid:=s.meetup_id;v_status:=s.status;END IF;
 END IF;
 simulated:=COALESCE(a.access_scope='shipaton-seven-20261001',false); -- gitleaks:allow public cohort identifier, not a credential
 IF simulated AND room.id IS NOT NULL AND NOT wingward_private.judge_simulated_admitted(p_user_id,p_user_id,room.id,v_mid) THEN RETURN QUERY SELECT 'not_found'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;RETURN;END IF;
 -- Recheck deadline after all waits, including exact replay.
 SELECT * INTO access FROM public.check_judge_access(p_user_id);
 IF access.outcome<>'allowed' THEN RETURN QUERY SELECT access.outcome,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;RETURN;END IF;
 SELECT * INTO prior FROM wingward_private.judge_counterpart_operations t WHERE t.actor_user_id=p_user_id AND t.idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF (prior.match_id,prior.operation,prior.expected_revision) IS DISTINCT FROM (p_match_id,p_operation,p_expected_revision) THEN
   RETURN QUERY SELECT 'idempotency_conflict'::text,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;
  ELSE RETURN QUERY SELECT 'replayed'::text,p_match_id,room.id,v_mid,COALESCE(v_status,m.status),v_revision;END IF;
  RETURN;
 END IF;
 IF v_revision<>p_expected_revision THEN RETURN QUERY SELECT 'stale_revision'::text,p_match_id,room.id,v_mid,v_status,v_revision;RETURN;END IF;
 SELECT * INTO result FROM public.consume_judge_request(p_user_id,p_idempotency_key);
 IF result.outcome<>'allowed' THEN RETURN QUERY SELECT result.outcome,NULL::uuid,NULL::uuid,NULL::uuid,NULL::text,0;RETURN;END IF;
 v_now:=clock_timestamp();
 -- Nested subtransaction: any normal-RPC rejection rolls back every mutation here.
 BEGIN
  IF p_operation='accept' THEN
   SELECT * INTO request FROM public.chat_requests t WHERE t.match_id=p_match_id FOR UPDATE;
   IF NOT FOUND OR request.requester_id<>p_user_id OR request.responder_id<>a.counterpart_user_id OR request.status<>'pending'
    OR request.expires_at<=clock_timestamp() OR m.status<>'direct_chat_requested' OR room.id IS NOT NULL THEN
    failure:='invalid_state';RAISE EXCEPTION USING ERRCODE='P0002';
   END IF;
   INSERT INTO public.direct_chat_rooms(match_id) VALUES(p_match_id) RETURNING * INTO room;
   UPDATE public.chat_requests SET status='accepted',responded_at=v_now WHERE id=request.id;
   UPDATE public.matches SET status='direct_chat_active',updated_at=v_now WHERE id=p_match_id;
   v_status:='direct_chat_active';
  ELSE
   IF room.id IS NULL OR m.status<>'direct_chat_active' THEN failure:='invalid_state';RAISE EXCEPTION USING ERRCODE='P0002';END IF;
   SELECT * INTO own FROM public.chat_meetup_private_decisions t WHERE t.match_id=p_match_id AND t.user_id=p_user_id;
   SELECT * INTO peer FROM public.chat_meetup_private_decisions t WHERE t.match_id=p_match_id AND t.user_id=a.counterpart_user_id;
   IF p_operation='intent' THEN
    IF own.intent_value IS DISTINCT FROM true OR s.meetup_id IS NOT NULL THEN failure:='invalid_state';RAISE EXCEPTION USING ERRCODE='P0002';END IF;
    action:=jsonb_build_object('type','intent','value','yes');
   ELSIF p_operation='availability' THEN
    IF s.status IS DISTINCT FROM 'awaiting_availability' THEN failure:='invalid_state';RAISE EXCEPTION USING ERRCODE='P0002';END IF;
    SELECT * INTO availability FROM public.chat_meetup_availability t WHERE t.meetup_id=s.meetup_id AND t.user_id=p_user_id;
    IF NOT FOUND OR availability.expires_at<=clock_timestamp() THEN failure:='invalid_state';RAISE EXCEPTION USING ERRCODE='P0002';END IF;
    action:=jsonb_build_object('type','availability.submit','source',availability.source,'window',jsonb_build_object('starts_at',availability.window_starts_at,'ends_at',availability.window_ends_at),
     CASE WHEN availability.source='calendar' THEN 'busy' ELSE 'available' END,availability.intervals);
   ELSIF p_operation='time_approve' THEN
    IF s.status IS DISTINCT FROM 'time_proposed' OR own.time_choice_id IS NULL OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(s.time_candidates) c WHERE c->>'id'=own.time_choice_id) THEN
     failure:='invalid_state';RAISE EXCEPTION USING ERRCODE='P0002';END IF;
    action:=jsonb_build_object('type','time.approve','candidate_id',own.time_choice_id);
   ELSE
    IF s.status IS DISTINCT FROM 'confirmed' OR s.confirmed_starts_at IS NULL OR s.confirmed_ends_at IS NULL OR s.confirmed_timezone IS DISTINCT FROM 'UTC'
     OR own.time_choice_id IS NULL OR peer.time_choice_id IS DISTINCT FROM own.time_choice_id OR s.selected_time_candidate_id IS DISTINCT FROM own.time_choice_id
     OR EXISTS(SELECT 1 FROM wingward_private.judge_simulated_meetups t WHERE t.meetup_id=s.meetup_id)
     OR (NOT simulated AND (SELECT count(*) FROM public.user_profiles t WHERE t.id IN(p_user_id,a.counterpart_user_id) AND t.identity_verification_status='verified' AND t.identity_verified_at IS NOT NULL)<>2) THEN
     failure:='invalid_state';RAISE EXCEPTION USING ERRCODE='P0002';END IF;
    INSERT INTO wingward_private.judge_simulated_meetups(meetup_id,actor_user_id,original_starts_at,original_ends_at,original_candidate_id)
     VALUES(s.meetup_id,p_user_id,s.confirmed_starts_at,s.confirmed_ends_at,s.selected_time_candidate_id);
    UPDATE public.chat_meetup_sessions SET confirmed_starts_at=v_now-interval '62 minutes',confirmed_ends_at=v_now-interval '2 minutes',updated_at=v_now WHERE chat_meetup_sessions.meetup_id=s.meetup_id;
    UPDATE public.meetups SET confirmed_start_at=v_now-interval '62 minutes',updated_at=v_now WHERE id=s.meetup_id;
    INSERT INTO public.chat_meetup_events(meetup_id,revision,event_key,kind,text) VALUES(s.meetup_id,s.revision,'judge:simulated-meetup','system','Simulated meetup with a fictional counterpart. The original approved time is preserved; no real meeting took place.');
    IF simulated THEN SELECT * INTO result FROM public.judge_simulated_apply_chat_meetup_action(p_user_id,room.id,p_user_id,v_revision,COALESCE(own.private_revision,0),p_idempotency_key,encode(sha256(convert_to('judge-actor-completion:'||p_idempotency_key::text,'UTF8')),'hex'),jsonb_build_object('type','meeting.complete')); ELSE SELECT * INTO result FROM public.apply_chat_meetup_action(room.id,p_user_id,v_revision,COALESCE(own.private_revision,0),p_idempotency_key,encode(sha256(convert_to('judge-actor-completion:'||p_idempotency_key::text,'UTF8')),'hex'),jsonb_build_object('type','meeting.complete')); END IF;
    IF result.outcome<>'ok' THEN failure:=result.outcome;RAISE EXCEPTION USING ERRCODE='P0002';END IF;
    v_revision:=result.revision;action:=jsonb_build_object('type','meeting.complete');
   END IF;
   IF simulated THEN SELECT * INTO result FROM public.judge_simulated_apply_chat_meetup_action(p_user_id,room.id,a.counterpart_user_id,v_revision,COALESCE(peer.private_revision,0),p_idempotency_key,encode(sha256(convert_to('judge-counterpart:'||p_user_id::text||':'||p_operation||':'||p_idempotency_key::text,'UTF8')),'hex'),action); ELSE SELECT * INTO result FROM public.apply_chat_meetup_action(room.id,a.counterpart_user_id,v_revision,COALESCE(peer.private_revision,0),p_idempotency_key,encode(sha256(convert_to('judge-counterpart:'||p_user_id::text||':'||p_operation||':'||p_idempotency_key::text,'UTF8')),'hex'),action); END IF;
   IF result.outcome<>'ok' THEN failure:=result.outcome;RAISE EXCEPTION USING ERRCODE='P0002';END IF;
   v_revision:=result.revision;v_mid:=result.meetup_id;v_status:=result.status;
   IF p_operation='availability' THEN
    -- The judge pays through the unchanged server webhook/quota gate, never the bot.
    UPDATE public.chat_meetup_sessions SET quota_claim_owner_id=p_user_id WHERE chat_meetup_sessions.meetup_id=v_mid AND quota_claim_owner_id=a.counterpart_user_id;
   END IF;
  END IF;
  INSERT INTO wingward_private.judge_counterpart_operations(actor_user_id,idempotency_key,match_id,operation,expected_revision) VALUES(p_user_id,p_idempotency_key,p_match_id,p_operation,p_expected_revision);
 EXCEPTION WHEN SQLSTATE 'P0002' THEN
  RETURN QUERY SELECT COALESCE(failure,'invalid_state'),p_match_id,room.id,s.meetup_id,s.status,p_expected_revision;RETURN;
 END;
 RETURN QUERY SELECT 'ok'::text,p_match_id,room.id,v_mid,v_status,v_revision;
END $advance$;
REVOKE ALL ON FUNCTION public.advance_judge_counterpart(uuid,uuid,text,integer,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.advance_judge_counterpart(uuid,uuid,text,integer,uuid) TO service_role;

-- Same lease, operation policy and budget gates; fictional reflection admission only.
CREATE OR REPLACE FUNCTION wingward_private.reserve_judge_voice_core(p_user_id uuid,p_context_id uuid,p_idempotency_key uuid,p_kind text)
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
  IF EXISTS(SELECT 1 FROM wingward_private.judge_accounts a WHERE a.actor_user_id=p_user_id AND a.access_scope='shipaton-seven-20261001') THEN -- gitleaks:allow public cohort identifier, not a credential
   IF NOT wingward_private.judge_simulated_admitted(p_user_id,p_user_id,NULL,p_context_id) THEN RETURN QUERY SELECT 'denied'::text,NULL::uuid,NULL::integer,NULL::integer,NULL::timestamptz;RETURN;END IF;
   SELECT * INTO state FROM public.judge_simulated_get_meetup_reflection_state(p_user_id,p_context_id,p_user_id);
  ELSE SELECT * INTO state FROM public.get_meetup_reflection_state(p_context_id,p_user_id); END IF;
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
