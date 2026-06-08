-- Add rich logging columns to agent_activity
-- These are nullable — existing rows get NULL, no breaking changes.
-- log_type: semantic category (thought, tool_call, tool_result, summary, error, etc.)
-- log_message: free-form human-readable description of what the agent did

ALTER TABLE public.agent_activity
  ADD COLUMN IF NOT EXISTS log_type TEXT,
  ADD COLUMN IF NOT EXISTS log_message TEXT;
