-- Agent audit trail for autonomous accounting actions
CREATE TABLE IF NOT EXISTS public.agent_audit_trail (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  agent_type TEXT,                    -- 'openclaw', 'flowpilot', 'composio', etc.
  caller_user_id UUID,
  caller_api_key_id UUID,
  conversation_id TEXT,
  trace_id TEXT,
  skill_id UUID,
  skill_name TEXT,
  table_name TEXT NOT NULL,
  crud_action TEXT NOT NULL,           -- create | update | delete | get | list
  entity_id UUID,
  request_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  request_payload_sha256 TEXT NOT NULL,
  before_snapshot JSONB,
  after_snapshot JSONB,
  diff JSONB,                          -- { field: { before, after } }
  success BOOLEAN NOT NULL DEFAULT true,
  error_message TEXT,
  retention_until DATE,                -- when row may be purged (default 7y for accounting)
  exported_at TIMESTAMPTZ,             -- when included in a retention export
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_trail_table_time ON public.agent_audit_trail(table_name, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_trail_actor ON public.agent_audit_trail(agent_type, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_trail_entity ON public.agent_audit_trail(table_name, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_trail_retention ON public.agent_audit_trail(retention_until) WHERE retention_until IS NOT NULL;

ALTER TABLE public.agent_audit_trail ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read audit trail" ON public.agent_audit_trail;
CREATE POLICY "Admins read audit trail" ON public.agent_audit_trail
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin'::app_role));

DROP POLICY IF EXISTS "Service inserts audit trail" ON public.agent_audit_trail;
CREATE POLICY "Service inserts audit trail" ON public.agent_audit_trail
  FOR INSERT TO authenticated
  WITH CHECK (true);

-- Block updates/deletes by anyone except service role (RLS bypassed by service role)
DROP POLICY IF EXISTS "No client updates audit trail" ON public.agent_audit_trail;
CREATE POLICY "No client updates audit trail" ON public.agent_audit_trail
  FOR UPDATE TO authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS "No client deletes audit trail" ON public.agent_audit_trail;
CREATE POLICY "No client deletes audit trail" ON public.agent_audit_trail
  FOR DELETE TO authenticated USING (false);

COMMENT ON TABLE public.agent_audit_trail IS 'Immutable audit trail for autonomous agent actions on accounting/ERP tables. 7-year retention default.';