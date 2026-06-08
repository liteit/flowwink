-- auto_mark_invoice_paid had handler `doc:auto_mark_invoice_paid`. agent-execute
-- has no `doc:` dispatch branch, so the skill fell through to "Unknown handler
-- type" — silently broken for every MCP/FlowPilot caller despite the RPC
-- `auto_mark_invoice_paid()` existing and being callable. Repoint to `rpc:`.
UPDATE public.agent_skills
SET handler = 'rpc:auto_mark_invoice_paid'
WHERE name = 'auto_mark_invoice_paid'
  AND handler = 'doc:auto_mark_invoice_paid';

-- list_pos_sales pointed at `edge:agent-execute` — a circular handler that
-- re-enters agent-execute and fails with "skill_id or skill_name required".
-- The pos_sales table is a plain read; route it through generic CRUD instead.
UPDATE public.agent_skills
SET handler = 'db:pos_sales'
WHERE name = 'list_pos_sales'
  AND handler = 'edge:agent-execute';
