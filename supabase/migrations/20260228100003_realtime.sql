-- Supabase Realtime: add tables to publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.direct_chat_messages;
ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_requests;
ALTER PUBLICATION supabase_realtime ADD TABLE public.matches;
ALTER PUBLICATION supabase_realtime ADD TABLE public.fox_conversations;
