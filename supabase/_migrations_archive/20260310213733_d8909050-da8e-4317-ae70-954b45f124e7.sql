-- Allow admins to delete any chat conversation
CREATE POLICY "Admins can delete any conversation"
ON public.chat_conversations
FOR DELETE
TO authenticated
USING (has_role(auth.uid(), 'admin'::app_role));