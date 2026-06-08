
-- Skill Gating: Add requires column for prerequisite checks
ALTER TABLE public.agent_skills ADD COLUMN IF NOT EXISTS requires jsonb DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.agent_skills.requires IS 'Array of prerequisite conditions: [{"type":"skill","name":"..."}, {"type":"integration","key":"..."}, {"type":"module","id":"..."}]';

-- Visitor Persistence: Add visitor_profile JSONB to chat_conversations
ALTER TABLE public.chat_conversations ADD COLUMN IF NOT EXISTS visitor_profile jsonb DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.chat_conversations.visitor_profile IS 'Accumulated visitor context: preferences, interests, past interactions summary';
