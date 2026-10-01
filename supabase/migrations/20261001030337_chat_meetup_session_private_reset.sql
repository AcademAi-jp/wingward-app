-- Decisions are match-scoped, but consent and completion belong to one session.
-- Enforce the boundary on the row so historical, current and cloned RPCs share
-- the same rule, including when a later migration replaces a RPC body.
-- Existing RPC locks, authorization, revisions and idempotency remain unchanged.
CREATE FUNCTION wingward_private.reset_chat_meetup_session_decisions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF NEW.meetup_id IS DISTINCT FROM OLD.meetup_id THEN
    NEW.time_choice_id := NULL;
    NEW.cafe_choice_id := NULL;
    NEW.completed_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION wingward_private.reset_chat_meetup_session_decisions()
  FROM PUBLIC, anon, authenticated, service_role;

-- BEFORE UPDATE runs under the existing row lock and changes only NEW. The
-- caller's revision increment/RETURNING stays intact; same-session updates do
-- not erase decisions. NULL is the private pending-intent boundary.
CREATE TRIGGER chat_meetup_session_private_reset
BEFORE UPDATE OF meetup_id ON public.chat_meetup_private_decisions
FOR EACH ROW
EXECUTE FUNCTION wingward_private.reset_chat_meetup_session_decisions();
