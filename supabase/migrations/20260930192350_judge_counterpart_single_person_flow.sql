-- New empty judge-only operation ledger. Ordinary RPC bodies/ACL/RLS remain unchanged.
CREATE TABLE wingward_private.judge_counterpart_operations (
 actor_user_id uuid NOT NULL REFERENCES wingward_private.judge_accounts(actor_user_id),
 idempotency_key uuid NOT NULL,
 match_id uuid NOT NULL REFERENCES public.matches(id),
 operation text NOT NULL CHECK(operation IN('accept','intent','availability','time_approve','simulate_completion')),
 expected_revision integer NOT NULL CHECK(expected_revision>=0),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(actor_user_id,idempotency_key)
);
CREATE TABLE wingward_private.judge_simulated_meetups (
 meetup_id uuid PRIMARY KEY REFERENCES public.chat_meetup_sessions(meetup_id),
 actor_user_id uuid NOT NULL REFERENCES wingward_private.judge_accounts(actor_user_id),
 original_starts_at timestamptz NOT NULL,
 original_ends_at timestamptz NOT NULL,
 original_candidate_id text NOT NULL,
 simulated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 CHECK(original_ends_at>original_starts_at)
);
ALTER TABLE wingward_private.judge_counterpart_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE wingward_private.judge_simulated_meetups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE wingward_private.judge_counterpart_operations,wingward_private.judge_simulated_meetups FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.advance_judge_counterpart(p_user_id uuid,p_match_id uuid,p_operation text,p_expected_revision integer,p_idempotency_key uuid)
RETURNS TABLE(outcome text,match_id uuid,room_id uuid,meetup_id uuid,status text,revision integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $advance$
DECLARE a wingward_private.judge_accounts;access record;m public.matches;room public.direct_chat_rooms;request public.chat_requests;
 s public.chat_meetup_sessions;own public.chat_meetup_private_decisions;peer public.chat_meetup_private_decisions;
 availability public.chat_meetup_availability;prior wingward_private.judge_counterpart_operations;
 result record;action jsonb;v_revision integer:=0;v_status text;v_mid uuid;v_now timestamptz;failure text;
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
     OR (SELECT count(*) FROM public.user_profiles t WHERE t.id IN(p_user_id,a.counterpart_user_id) AND t.identity_verification_status='verified' AND t.identity_verified_at IS NOT NULL)<>2 THEN
     failure:='invalid_state';RAISE EXCEPTION USING ERRCODE='P0002';END IF;
    INSERT INTO wingward_private.judge_simulated_meetups(meetup_id,actor_user_id,original_starts_at,original_ends_at,original_candidate_id)
     VALUES(s.meetup_id,p_user_id,s.confirmed_starts_at,s.confirmed_ends_at,s.selected_time_candidate_id);
    UPDATE public.chat_meetup_sessions SET confirmed_starts_at=v_now-interval '62 minutes',confirmed_ends_at=v_now-interval '2 minutes',updated_at=v_now WHERE chat_meetup_sessions.meetup_id=s.meetup_id;
    UPDATE public.meetups SET confirmed_start_at=v_now-interval '62 minutes',updated_at=v_now WHERE id=s.meetup_id;
    INSERT INTO public.chat_meetup_events(meetup_id,revision,event_key,kind,text) VALUES(s.meetup_id,s.revision,'judge:simulated-meetup','system','Simulated meetup with a fictional counterpart. The original approved time is preserved; no real meeting took place.');
    SELECT * INTO result FROM public.apply_chat_meetup_action(room.id,p_user_id,v_revision,COALESCE(own.private_revision,0),p_idempotency_key,encode(sha256(convert_to('judge-actor-completion:'||p_idempotency_key::text,'UTF8')),'hex'),jsonb_build_object('type','meeting.complete'));
    IF result.outcome<>'ok' THEN failure:=result.outcome;RAISE EXCEPTION USING ERRCODE='P0002';END IF;
    v_revision:=result.revision;action:=jsonb_build_object('type','meeting.complete');
   END IF;
   SELECT * INTO result FROM public.apply_chat_meetup_action(room.id,a.counterpart_user_id,v_revision,COALESCE(peer.private_revision,0),p_idempotency_key,encode(sha256(convert_to('judge-counterpart:'||p_user_id::text||':'||p_operation||':'||p_idempotency_key::text,'UTF8')),'hex'),action);
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
