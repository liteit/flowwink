
-- Add source and action_payload columns to chat_messages for proactive FlowPilot messages
ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'user',
  ADD COLUMN IF NOT EXISTS action_payload jsonb DEFAULT NULL;
