GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE ON TABLE public.chat_conversations TO anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.chat_conversations TO authenticated;
GRANT ALL ON TABLE public.chat_conversations TO service_role;

GRANT SELECT, INSERT ON TABLE public.chat_messages TO anon;
GRANT SELECT, INSERT ON TABLE public.chat_messages TO authenticated;
GRANT ALL ON TABLE public.chat_messages TO service_role;

GRANT SELECT, INSERT, UPDATE ON TABLE public.chat_feedback TO anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.chat_feedback TO authenticated;
GRANT ALL ON TABLE public.chat_feedback TO service_role;