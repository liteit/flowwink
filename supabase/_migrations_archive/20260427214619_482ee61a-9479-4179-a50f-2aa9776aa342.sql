-- 1. Add scope + user_id columns (idempotent)
ALTER TABLE public.chat_conversations
  ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT 'visitor';

ALTER TABLE public.chat_conversations
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE;

-- Constrain scope values
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chat_conversations_scope_check'
  ) THEN
    ALTER TABLE public.chat_conversations
      ADD CONSTRAINT chat_conversations_scope_check
      CHECK (scope IN ('visitor', 'internal'));
  END IF;
END$$;

CREATE INDEX IF NOT EXISTS idx_chat_conversations_scope_user
  ON public.chat_conversations(scope, user_id);

-- 2. Ensure RLS is enabled
ALTER TABLE public.chat_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

-- 3. Internal-scope policies for chat_conversations
DROP POLICY IF EXISTS "Users see own internal conversations" ON public.chat_conversations;
CREATE POLICY "Users see own internal conversations"
ON public.chat_conversations
FOR SELECT
TO authenticated
USING (scope = 'internal' AND user_id = auth.uid());

DROP POLICY IF EXISTS "Users create own internal conversations" ON public.chat_conversations;
CREATE POLICY "Users create own internal conversations"
ON public.chat_conversations
FOR INSERT
TO authenticated
WITH CHECK (scope = 'internal' AND user_id = auth.uid());

DROP POLICY IF EXISTS "Users update own internal conversations" ON public.chat_conversations;
CREATE POLICY "Users update own internal conversations"
ON public.chat_conversations
FOR UPDATE
TO authenticated
USING (scope = 'internal' AND user_id = auth.uid())
WITH CHECK (scope = 'internal' AND user_id = auth.uid());

DROP POLICY IF EXISTS "Users delete own internal conversations" ON public.chat_conversations;
CREATE POLICY "Users delete own internal conversations"
ON public.chat_conversations
FOR DELETE
TO authenticated
USING (scope = 'internal' AND user_id = auth.uid());

-- 4. Mirror policies for chat_messages of internal conversations
DROP POLICY IF EXISTS "Users see own internal messages" ON public.chat_messages;
CREATE POLICY "Users see own internal messages"
ON public.chat_messages
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.chat_conversations c
    WHERE c.id = chat_messages.conversation_id
      AND c.scope = 'internal'
      AND c.user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Users insert own internal messages" ON public.chat_messages;
CREATE POLICY "Users insert own internal messages"
ON public.chat_messages
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.chat_conversations c
    WHERE c.id = chat_messages.conversation_id
      AND c.scope = 'internal'
      AND c.user_id = auth.uid()
  )
);