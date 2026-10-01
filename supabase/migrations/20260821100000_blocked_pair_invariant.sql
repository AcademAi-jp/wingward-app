-- Makes "two users who have blocked each other do not interact" an invariant
-- the DATABASE enforces, rather than something each call site remembers.
--
-- Codex raised two P0s on PR #31 round 11, both the same shape: the block
-- check and the write it protects are separated by several round trips, so a
-- block committing in between still lets the write through.
--
--   * POST /api/chat-requests checks `blocks`, then runs three more queries
--     before its INSERT.
--   * executeDailyMatching snapshots `blocks` once and then runs the whole
--     scoring loop and a bulk `matches` INSERT against that stale set.
--
-- Neither is an error-handling bug — every query succeeds, the snapshot simply
-- goes out of date — so no application-level check closes the class. Moving
-- the check later only shrinks the gap, and every future call site has to
-- remember to have one at all. PR #31 spent five review rounds moving checks
-- around inside that gap; this is the structural answer instead.
--
-- WHAT THIS DOES AND DOES NOT GUARANTEE. A trigger reads `blocks` in the
-- inserting transaction, so under READ COMMITTED a block that commits between
-- this read and the insert's own commit is still not seen. The window shrinks
-- from "several application round trips" to "inside one statement", which is
-- the practical fix; closing it entirely would require serialising every
-- block insert against every match/chat_request insert, at a cost out of all
-- proportion to a race whose outcome is one row the blocker can see and
-- decline. The application-level checks are deliberately KEPT: they give the
-- caller a clean NOT_FOUND instead of a raised exception, and they stop the
-- work earlier. This is the backstop, not a replacement.

CREATE OR REPLACE FUNCTION public.reject_blocked_pair()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  first_party uuid;
  second_party uuid;
BEGIN
  -- Both guarded tables name their two participants in different columns, so
  -- the trigger takes them as arguments rather than guessing per table. This
  -- keeps one function for both, and forces whoever attaches it to a third
  -- table to state which columns hold the pair.
  first_party := to_jsonb(NEW) ->> TG_ARGV[0];
  second_party := to_jsonb(NEW) ->> TG_ARGV[1];

  IF first_party IS NULL OR second_party IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks
    WHERE (blocker_id = first_party AND blocked_id = second_party)
       OR (blocker_id = second_party AND blocked_id = first_party)
  ) THEN
    RAISE EXCEPTION 'blocked pair: % and % cannot be connected', first_party, second_party
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

-- SECURITY DEFINER because it must read `blocks` regardless of the inserting
-- role's own visibility of that table. M10's rule applies: on hosted Supabase
-- anon and authenticated hold their own default EXECUTE grants that a REVOKE
-- on PUBLIC does not touch, so the roles are named. Nothing should ever call
-- this directly — it is only meaningful as a trigger.
REVOKE ALL ON FUNCTION public.reject_blocked_pair() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER matches_reject_blocked_pair
  BEFORE INSERT ON public.matches
  FOR EACH ROW EXECUTE FUNCTION public.reject_blocked_pair('user_a_id', 'user_b_id');

CREATE TRIGGER chat_requests_reject_blocked_pair
  BEFORE INSERT ON public.chat_requests
  FOR EACH ROW EXECUTE FUNCTION public.reject_blocked_pair('requester_id', 'responder_id');

-- The trigger just installed turns a client-reachable INSERT into an oracle
-- for the thing it is supposed to hide. `chat_requests_insert`
-- (20260228100002_rls.sql) let the `authenticated` role INSERT chat_requests
-- directly through PostgREST, checking only that the caller is the named
-- requester. Before this migration that INSERT always succeeded (or failed
-- for reasons unrelated to blocks); now it fails with 23514 specifically when
-- the responder has blocked the requester (or vice versa) — a distinguishable
-- error a client can use to learn "this person blocked me", which is exactly
-- what POST /api/chat-requests deliberately hides behind an indistinguishable
-- NOT_FOUND (apps/api/src/routes/chat-requests.ts). The trigger cannot be
-- selective about who sees its exception, so the fix is to remove the path
-- that lets an untrusted client reach it directly.
--
-- This does not affect the real write path: apps/api writes with the
-- service_role key (apps/api/src/db/client.ts, getSupabaseClient), which
-- bypasses RLS entirely and was never gated by this policy.
--
-- It is also strictly a tightening, not a new restriction traded for safety:
-- `chat_requests_insert` never checked that the requester was actually a
-- participant in the named match, only that `requester_id` matched the
-- caller's own profile id. Removing it closes an information leak and does
-- not open one — there was no legitimate direct-INSERT use of this policy to
-- preserve.
--
-- `matches` needs no equivalent change: it has no INSERT policy at all (see
-- the RLS migration), so it was already unreachable for `authenticated`
-- before this trigger existed, and remains so.
DROP POLICY IF EXISTS chat_requests_insert ON public.chat_requests;

-- ─────────────────────────────────────────────────────────────────────────
-- HOLE 1: chat_requests participant columns are mutable.
--
-- `chat_requests_update` (20260228100002_rls.sql) is
-- `USING (public.get_user_profile_id() = responder_id)` with no WITH CHECK on
-- any other column. A signed-in responder can therefore PostgREST-UPDATE an
-- existing row they own and rewrite `requester_id` (or `match_id`) to name
-- someone else entirely — including a pair the trigger above would have
-- rejected on INSERT. The trigger is BEFORE INSERT ONLY; it never runs on
-- this path, so the UPDATE forges a row the INSERT trigger exists to prevent.
--
-- The fix is column immutability, NOT a block re-check on UPDATE. Those are
-- not the same fix and the difference is the whole point: a blocked pair's
-- existing chat request must remain declinable. `PUT /api/chat-requests/:id`
-- with action "decline" is an UPDATE on this row (status -> 'declined'), and
-- that has to keep working even when the pair is blocked — that is exactly
-- the case the blocker needs to be able to close out. A trigger that
-- re-ran the block check on every UPDATE would make declining a blocked
-- pair's request impossible, trading one bug for a worse one. So this
-- trigger checks only that the three participant-identifying columns do not
-- change; it has no opinion on `blocks` at all.
CREATE OR REPLACE FUNCTION public.freeze_chat_request_participants()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NEW.requester_id IS DISTINCT FROM OLD.requester_id
     OR NEW.responder_id IS DISTINCT FROM OLD.responder_id
     OR NEW.match_id IS DISTINCT FROM OLD.match_id THEN
    RAISE EXCEPTION 'chat_requests participant columns are immutable'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

-- SECURITY DEFINER for the same reason as reject_blocked_pair: it must
-- behave the same way regardless of the updating role's own grants. Nothing
-- should call this directly. The API only ever updates `status` and
-- `responded_at` (apps/api/src/routes/chat-requests.ts, both the decline and
-- accept branches), so the service_role write path this function guards is
-- unaffected by it — this only ever fires to stop a row the API itself would
-- never have produced.
REVOKE ALL ON FUNCTION public.freeze_chat_request_participants() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER chat_requests_freeze_participants
  BEFORE UPDATE ON public.chat_requests
  FOR EACH ROW EXECUTE FUNCTION public.freeze_chat_request_participants();

-- ─────────────────────────────────────────────────────────────────────────
-- HOLE 2: accepting a request creates a room after a block.
--
-- `PUT /api/chat-requests/:id` with action "accept"
-- (apps/api/src/routes/chat-requests.ts) inserts into `direct_chat_rooms`
-- with no `blocks` check of its own. The chat_requests trigger above is
-- INSERT-only on chat_requests and does not fire for a direct_chat_rooms
-- insert. The block route closes rooms that already exist at the moment the
-- block is recorded, so a room created afterwards is never closed. Same two
-- layers as the rest of this migration: a database backstop plus an earlier
-- application check that returns a clean error.
CREATE OR REPLACE FUNCTION public.reject_blocked_pair_by_match()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  match_id_value uuid;
  first_party uuid;
  second_party uuid;
BEGIN
  -- direct_chat_rooms names its pair indirectly, via matches, so this
  -- function resolves the participants itself instead of taking them as
  -- trigger arguments the way reject_blocked_pair does. TG_ARGV[0] names
  -- which column on NEW holds the match id.
  match_id_value := to_jsonb(NEW) ->> TG_ARGV[0];

  IF match_id_value IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT user_a_id, user_b_id INTO first_party, second_party
  FROM public.matches
  WHERE id = match_id_value;

  IF first_party IS NULL OR second_party IS NULL THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.blocks
    WHERE (blocker_id = first_party AND blocked_id = second_party)
       OR (blocker_id = second_party AND blocked_id = first_party)
  ) THEN
    RAISE EXCEPTION 'blocked pair: % and % cannot open a direct chat room', first_party, second_party
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_blocked_pair_by_match() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER direct_chat_rooms_reject_blocked_pair
  BEFORE INSERT ON public.direct_chat_rooms
  FOR EACH ROW EXECUTE FUNCTION public.reject_blocked_pair_by_match('match_id');

-- ─────────────────────────────────────────────────────────────────────────
-- HOLE 3: a blocked user can still send direct messages.
--
-- `POST /api/direct-chats/:id/messages` (apps/api/src/routes/direct-chats.ts)
-- checks match membership only, never `blocks`, and never the room's
-- `status`. `direct_chat_messages_insert` (20260228100002_rls.sql) is
-- membership-only too. This closes the `blocks` gap the same way as HOLE 2;
-- the room `status = 'closed'` case is a separate state-machine bug and is
-- deliberately out of scope here.
CREATE OR REPLACE FUNCTION public.reject_blocked_pair_by_room()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  room_id_value uuid;
  match_id_value uuid;
  first_party uuid;
  second_party uuid;
BEGIN
  room_id_value := to_jsonb(NEW) ->> TG_ARGV[0];

  IF room_id_value IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT match_id INTO match_id_value
  FROM public.direct_chat_rooms
  WHERE id = room_id_value;

  IF match_id_value IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT user_a_id, user_b_id INTO first_party, second_party
  FROM public.matches
  WHERE id = match_id_value;

  IF first_party IS NULL OR second_party IS NULL THEN
    RETURN NEW;
  END IF;

  -- `blocks` is covered by UNIQUE(blocker_id, blocked_id) and
  -- idx_blocks_blocked_id, so both arms of this OR are indexed lookups —
  -- this costs two indexed reads per message insert, not a scan.
  IF EXISTS (
    SELECT 1 FROM public.blocks
    WHERE (blocker_id = first_party AND blocked_id = second_party)
       OR (blocker_id = second_party AND blocked_id = first_party)
  ) THEN
    RAISE EXCEPTION 'blocked pair: % and % cannot exchange direct messages', first_party, second_party
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_blocked_pair_by_room() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER direct_chat_messages_reject_blocked_pair
  BEFORE INSERT ON public.direct_chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.reject_blocked_pair_by_room('room_id');

-- Same reason as the chat_requests drop above: the trigger's 23514 is a
-- distinguishable answer where the API returns a generic FORBIDDEN, so a
-- client-reachable INSERT policy on the guarded table turns the trigger into
-- an oracle for "did this person block me". `direct_chat_messages_insert`
-- (20260228100002_rls.sql) let `authenticated` INSERT directly through
-- PostgREST, checking only room membership. `direct_chat_messages_select` is
-- deliberately KEPT: apps/web's Realtime subscription to this table depends
-- on it (it never inserts), and reading is not the leak here, writing is.
-- apps/api writes with the service_role key and bypasses RLS, so it is
-- unaffected by this drop. With this, none of the four tables guarded by a
-- blocked-pair trigger (matches, chat_requests, direct_chat_rooms,
-- direct_chat_messages) has a client-reachable INSERT policy left.
DROP POLICY IF EXISTS direct_chat_messages_insert ON public.direct_chat_messages;
