-- RLS: enable on all tables and add policies (use (select auth.uid()) for performance)

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_answers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.persona_section_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.personas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.persona_sections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.speed_dating_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.speed_dating_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fox_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fox_conversation_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_fox_chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.partner_fox_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_chat_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

-- user_profiles
CREATE POLICY user_profiles_select ON public.user_profiles FOR SELECT USING ((SELECT auth.uid()) = auth_user_id);
CREATE POLICY user_profiles_update ON public.user_profiles FOR UPDATE USING ((SELECT auth.uid()) = auth_user_id);

-- quiz_questions: all authenticated can read
CREATE POLICY quiz_questions_select ON public.quiz_questions FOR SELECT TO authenticated USING (true);

-- quiz_answers
CREATE POLICY quiz_answers_select ON public.quiz_answers FOR SELECT USING (public.get_user_profile_id() = user_id);
CREATE POLICY quiz_answers_insert ON public.quiz_answers FOR INSERT WITH CHECK (public.get_user_profile_id() = user_id);
CREATE POLICY quiz_answers_update ON public.quiz_answers FOR UPDATE USING (public.get_user_profile_id() = user_id);

-- persona_section_definitions
CREATE POLICY persona_section_definitions_select ON public.persona_section_definitions FOR SELECT TO authenticated USING (true);

-- personas
CREATE POLICY personas_select ON public.personas FOR SELECT USING (public.get_user_profile_id() = user_id);

-- persona_sections
CREATE POLICY persona_sections_select ON public.persona_sections FOR SELECT
  USING (public.get_user_profile_id() = (SELECT user_id FROM public.personas WHERE id = persona_id));
CREATE POLICY persona_sections_update ON public.persona_sections FOR UPDATE
  USING (
    public.get_user_profile_id() = (SELECT user_id FROM public.personas WHERE id = persona_id)
    AND ((SELECT editable FROM public.persona_section_definitions WHERE id = section_id) = true)
  );

-- speed_dating_sessions
CREATE POLICY speed_dating_sessions_select ON public.speed_dating_sessions FOR SELECT USING (public.get_user_profile_id() = user_id);
CREATE POLICY speed_dating_sessions_insert ON public.speed_dating_sessions FOR INSERT WITH CHECK (public.get_user_profile_id() = user_id);

-- speed_dating_messages
CREATE POLICY speed_dating_messages_select ON public.speed_dating_messages FOR SELECT
  USING (public.get_user_profile_id() = (SELECT user_id FROM public.speed_dating_sessions WHERE id = session_id));
CREATE POLICY speed_dating_messages_insert ON public.speed_dating_messages FOR INSERT
  WITH CHECK (public.get_user_profile_id() = (SELECT user_id FROM public.speed_dating_sessions WHERE id = session_id));

-- profiles
CREATE POLICY profiles_select ON public.profiles FOR SELECT USING (public.get_user_profile_id() = user_id);
CREATE POLICY profiles_update ON public.profiles FOR UPDATE USING (public.get_user_profile_id() = user_id);

-- matches
CREATE POLICY matches_select ON public.matches FOR SELECT
  USING (public.get_user_profile_id() IN (user_a_id, user_b_id));

-- fox_conversations
CREATE POLICY fox_conversations_select ON public.fox_conversations FOR SELECT
  USING (public.get_user_profile_id() IN (
    SELECT user_a_id FROM public.matches WHERE id = match_id
    UNION ALL
    SELECT user_b_id FROM public.matches WHERE id = match_id
  ));

-- fox_conversation_messages
CREATE POLICY fox_conversation_messages_select ON public.fox_conversation_messages FOR SELECT
  USING (public.get_user_profile_id() IN (
    SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.fox_conversations WHERE id = conversation_id)
    UNION ALL
    SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.fox_conversations WHERE id = conversation_id)
  ));

-- partner_fox_chats
CREATE POLICY partner_fox_chats_select ON public.partner_fox_chats FOR SELECT USING (public.get_user_profile_id() = user_id);
CREATE POLICY partner_fox_chats_insert ON public.partner_fox_chats FOR INSERT WITH CHECK (public.get_user_profile_id() = user_id);

-- partner_fox_messages
CREATE POLICY partner_fox_messages_select ON public.partner_fox_messages FOR SELECT
  USING (public.get_user_profile_id() = (SELECT user_id FROM public.partner_fox_chats WHERE id = chat_id));
CREATE POLICY partner_fox_messages_insert ON public.partner_fox_messages FOR INSERT
  WITH CHECK (public.get_user_profile_id() = (SELECT user_id FROM public.partner_fox_chats WHERE id = chat_id));

-- chat_requests
CREATE POLICY chat_requests_select ON public.chat_requests FOR SELECT
  USING (public.get_user_profile_id() IN (requester_id, responder_id));
CREATE POLICY chat_requests_insert ON public.chat_requests FOR INSERT WITH CHECK (public.get_user_profile_id() = requester_id);
CREATE POLICY chat_requests_update ON public.chat_requests FOR UPDATE
  USING (public.get_user_profile_id() = responder_id);

-- direct_chat_rooms
CREATE POLICY direct_chat_rooms_select ON public.direct_chat_rooms FOR SELECT
  USING (public.get_user_profile_id() IN (
    SELECT user_a_id FROM public.matches WHERE id = match_id
    UNION ALL
    SELECT user_b_id FROM public.matches WHERE id = match_id
  ));

-- direct_chat_messages
CREATE POLICY direct_chat_messages_select ON public.direct_chat_messages FOR SELECT
  USING (public.get_user_profile_id() IN (
    SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.direct_chat_rooms WHERE id = room_id)
    UNION ALL
    SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.direct_chat_rooms WHERE id = room_id)
  ));
CREATE POLICY direct_chat_messages_insert ON public.direct_chat_messages FOR INSERT
  WITH CHECK (public.get_user_profile_id() IN (
    SELECT user_a_id FROM public.matches WHERE id = (SELECT match_id FROM public.direct_chat_rooms WHERE id = room_id)
    UNION ALL
    SELECT user_b_id FROM public.matches WHERE id = (SELECT match_id FROM public.direct_chat_rooms WHERE id = room_id)
  ));

-- blocks
CREATE POLICY blocks_select ON public.blocks FOR SELECT USING (public.get_user_profile_id() = blocker_id);
CREATE POLICY blocks_insert ON public.blocks FOR INSERT WITH CHECK (public.get_user_profile_id() = blocker_id);

-- reports
CREATE POLICY reports_insert ON public.reports FOR INSERT WITH CHECK (public.get_user_profile_id() = reporter_id);
