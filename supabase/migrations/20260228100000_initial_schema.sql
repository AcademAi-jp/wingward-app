-- WingFox initial schema: user_profiles, quiz, speed_dating, profiles, personas, matches, chats, moderation

-- user_profiles
CREATE TABLE public.user_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  nickname text NOT NULL,
  gender text CHECK (gender IN ('male', 'female', 'other', 'undisclosed')),
  avatar_url text,
  onboarding_status text NOT NULL DEFAULT 'not_started' CHECK (onboarding_status IN (
    'not_started', 'quiz_completed', 'speed_dating_completed', 'profile_generated', 'persona_generated', 'confirmed'
  )),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_user_profiles_auth_user_id ON public.user_profiles(auth_user_id);

-- quiz_questions
CREATE TABLE public.quiz_questions (
  id text PRIMARY KEY,
  category text NOT NULL,
  question_text text NOT NULL,
  options jsonb NOT NULL,
  allow_multiple boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_quiz_questions_sort_order ON public.quiz_questions(sort_order);

-- quiz_answers
CREATE TABLE public.quiz_answers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  question_id text NOT NULL REFERENCES public.quiz_questions(id),
  selected jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, question_id)
);
CREATE INDEX idx_quiz_answers_user_id ON public.quiz_answers(user_id);
CREATE INDEX idx_quiz_answers_question_id ON public.quiz_answers(question_id);

-- persona_section_definitions (before personas - referenced by persona_sections)
CREATE TABLE public.persona_section_definitions (
  id text PRIMARY KEY,
  title text NOT NULL,
  description text NOT NULL,
  generation_prompt text NOT NULL,
  sort_order integer NOT NULL,
  editable boolean NOT NULL DEFAULT true,
  applicable_persona_types text[] NOT NULL DEFAULT ARRAY['wingfox','virtual_similar','virtual_complementary','virtual_discovery'],
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_persona_section_definitions_sort_order ON public.persona_section_definitions(sort_order);

-- personas
CREATE TABLE public.personas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  persona_type text NOT NULL CHECK (persona_type IN ('wingfox', 'virtual_similar', 'virtual_complementary', 'virtual_discovery')),
  name text NOT NULL,
  compiled_document text NOT NULL,
  version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, persona_type)
);
CREATE INDEX idx_personas_user_id ON public.personas(user_id);
CREATE UNIQUE INDEX idx_personas_user_type ON public.personas(user_id, persona_type);
CREATE INDEX idx_personas_wingfox ON public.personas(user_id) WHERE persona_type = 'wingfox';

-- persona_sections
CREATE TABLE public.persona_sections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  persona_id uuid NOT NULL REFERENCES public.personas(id) ON DELETE CASCADE,
  section_id text NOT NULL REFERENCES public.persona_section_definitions(id),
  content text NOT NULL,
  source text NOT NULL DEFAULT 'auto' CHECK (source IN ('auto', 'manual')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(persona_id, section_id)
);
CREATE INDEX idx_persona_sections_persona_id ON public.persona_sections(persona_id);
CREATE INDEX idx_persona_sections_section_id ON public.persona_sections(section_id);

-- speed_dating_sessions
CREATE TABLE public.speed_dating_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  persona_id uuid NOT NULL REFERENCES public.personas(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed')),
  message_count integer NOT NULL DEFAULT 0,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_speed_dating_sessions_user_id ON public.speed_dating_sessions(user_id);
CREATE INDEX idx_speed_dating_sessions_persona_id ON public.speed_dating_sessions(persona_id);

-- speed_dating_messages
CREATE TABLE public.speed_dating_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.speed_dating_sessions(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('user', 'persona')),
  content text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_speed_dating_messages_session_id ON public.speed_dating_messages(session_id);
CREATE INDEX idx_speed_dating_messages_session_created ON public.speed_dating_messages(session_id, created_at);

-- profiles
CREATE TABLE public.profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  basic_info jsonb NOT NULL DEFAULT '{}',
  personality_tags jsonb NOT NULL DEFAULT '[]',
  personality_analysis jsonb NOT NULL DEFAULT '{}',
  interests jsonb NOT NULL DEFAULT '[]',
  values jsonb NOT NULL DEFAULT '{}',
  romance_style jsonb NOT NULL DEFAULT '{}',
  communication_style jsonb NOT NULL DEFAULT '{}',
  lifestyle jsonb NOT NULL DEFAULT '{}',
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'confirmed')),
  version integer NOT NULL DEFAULT 1,
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_profiles_user_id ON public.profiles(user_id);
CREATE INDEX idx_profiles_status ON public.profiles(status) WHERE status = 'confirmed';

-- matches (user_a_id < user_b_id for uniqueness)
CREATE TABLE public.matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  user_b_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  profile_score numeric(5,2),
  conversation_score numeric(5,2),
  final_score numeric(5,2),
  score_details jsonb DEFAULT '{}',
  status text NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending', 'fox_conversation_in_progress', 'fox_conversation_completed', 'partner_chat_started', 'direct_chat_requested', 'direct_chat_active'
  )),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_a_id, user_b_id),
  CHECK (user_a_id < user_b_id)
);
CREATE INDEX idx_matches_user_a_id ON public.matches(user_a_id);
CREATE INDEX idx_matches_user_b_id ON public.matches(user_b_id);
CREATE INDEX idx_matches_final_score ON public.matches(final_score DESC NULLS LAST);
CREATE INDEX idx_matches_scored ON public.matches(final_score DESC NULLS LAST) WHERE final_score IS NOT NULL;

-- fox_conversations
CREATE TABLE public.fox_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id uuid NOT NULL UNIQUE REFERENCES public.matches(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'in_progress', 'completed', 'failed')),
  total_rounds integer NOT NULL DEFAULT 15,
  current_round integer NOT NULL DEFAULT 0,
  conversation_analysis jsonb DEFAULT '{}',
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_fox_conversations_match_id ON public.fox_conversations(match_id);
CREATE INDEX idx_fox_conversations_status ON public.fox_conversations(status) WHERE status IN ('pending', 'in_progress');

-- fox_conversation_messages
CREATE TABLE public.fox_conversation_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.fox_conversations(id) ON DELETE CASCADE,
  speaker_user_id uuid NOT NULL REFERENCES public.user_profiles(id),
  content text NOT NULL,
  round_number integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_fox_conv_messages_conversation_id ON public.fox_conversation_messages(conversation_id);
CREATE INDEX idx_fox_conv_messages_conv_round ON public.fox_conversation_messages(conversation_id, round_number);
CREATE INDEX idx_fox_conv_messages_speaker_user_id ON public.fox_conversation_messages(speaker_user_id);

-- partner_fox_chats
CREATE TABLE public.partner_fox_chats (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id uuid NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  partner_user_id uuid NOT NULL REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(match_id, user_id)
);
CREATE INDEX idx_partner_fox_chats_match_id ON public.partner_fox_chats(match_id);
CREATE INDEX idx_partner_fox_chats_user_id ON public.partner_fox_chats(user_id);
CREATE INDEX idx_partner_fox_chats_partner_user_id ON public.partner_fox_chats(partner_user_id);

-- partner_fox_messages
CREATE TABLE public.partner_fox_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chat_id uuid NOT NULL REFERENCES public.partner_fox_chats(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('user', 'fox')),
  content text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_partner_fox_messages_chat_id ON public.partner_fox_messages(chat_id);
CREATE INDEX idx_partner_fox_messages_chat_created ON public.partner_fox_messages(chat_id, created_at);

-- chat_requests
CREATE TABLE public.chat_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id uuid NOT NULL UNIQUE REFERENCES public.matches(id) ON DELETE CASCADE,
  requester_id uuid NOT NULL REFERENCES public.user_profiles(id),
  responder_id uuid NOT NULL REFERENCES public.user_profiles(id),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired')),
  responded_at timestamptz,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_chat_requests_match_id ON public.chat_requests(match_id);
CREATE INDEX idx_chat_requests_requester_id ON public.chat_requests(requester_id);
CREATE INDEX idx_chat_requests_responder_id ON public.chat_requests(responder_id) WHERE status = 'pending';
CREATE INDEX idx_chat_requests_expires_at ON public.chat_requests(expires_at) WHERE status = 'pending';

-- direct_chat_rooms
CREATE TABLE public.direct_chat_rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  match_id uuid NOT NULL UNIQUE REFERENCES public.matches(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'closed')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_direct_chat_rooms_match_id ON public.direct_chat_rooms(match_id);

-- direct_chat_messages
CREATE TABLE public.direct_chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.direct_chat_rooms(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES public.user_profiles(id),
  content text NOT NULL CHECK (char_length(content) <= 1000),
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_direct_chat_messages_room_id ON public.direct_chat_messages(room_id);
CREATE INDEX idx_direct_chat_messages_sender_id ON public.direct_chat_messages(sender_id);
CREATE INDEX idx_direct_chat_messages_room_created ON public.direct_chat_messages(room_id, created_at DESC);
CREATE INDEX idx_direct_chat_messages_unread ON public.direct_chat_messages(room_id, sender_id) WHERE is_read = false;

-- blocks
CREATE TABLE public.blocks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  blocker_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  blocked_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(blocker_id, blocked_id),
  CHECK (blocker_id != blocked_id)
);
CREATE INDEX idx_blocks_blocker_id ON public.blocks(blocker_id);
CREATE INDEX idx_blocks_blocked_id ON public.blocks(blocked_id);

-- reports
CREATE TABLE public.reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  reported_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  reason text NOT NULL CHECK (reason IN ('harassment', 'inappropriate', 'spam', 'other')),
  description text,
  message_id uuid REFERENCES public.direct_chat_messages(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'resolved')),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_reports_reporter_id ON public.reports(reporter_id);
CREATE INDEX idx_reports_reported_id ON public.reports(reported_id);
CREATE INDEX idx_reports_status ON public.reports(status) WHERE status = 'pending';
CREATE INDEX idx_reports_message_id ON public.reports(message_id) WHERE message_id IS NOT NULL;
