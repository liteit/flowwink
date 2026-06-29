
ALTER TABLE public.outbound_communications
  ADD COLUMN IF NOT EXISTS direction text NOT NULL DEFAULT 'outbound',
  ADD COLUMN IF NOT EXISTS thread_id text,
  ADD COLUMN IF NOT EXISTS message_id_header text,
  ADD COLUMN IF NOT EXISTS in_reply_to text,
  ADD COLUMN IF NOT EXISTS sender text;

ALTER TABLE public.outbound_communications
  DROP CONSTRAINT IF EXISTS outbound_communications_direction_check;
ALTER TABLE public.outbound_communications
  ADD CONSTRAINT outbound_communications_direction_check
  CHECK (direction IN ('inbound','outbound'));

CREATE INDEX IF NOT EXISTS idx_outbound_comm_direction
  ON public.outbound_communications (direction, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_outbound_comm_thread
  ON public.outbound_communications (thread_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_outbound_comm_msgid
  ON public.outbound_communications (message_id_header)
  WHERE message_id_header IS NOT NULL;
