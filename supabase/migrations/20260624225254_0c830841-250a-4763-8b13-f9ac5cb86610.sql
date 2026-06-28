
-- 1. Register run_daily_briefing skill (idempotent)
INSERT INTO public.agent_skills (
  name, description, category, scope, handler, enabled, mcp_exposed, trust_level, origin, tool_definition, instructions
) VALUES (
  'run_daily_briefing',
  'Generate the daily business briefing: health score, key metrics (visitors, leads, orders, revenue), AI summary and action items. Writes to flowpilot_briefings + admin FlowChat. Use when: scheduled daily run; admin requests today''s briefing. NOT for: weekly review (weekly_business_digest); ad-hoc analytics (analyze_analytics).',
  'analytics',
  'internal',
  'edge:flowpilot-briefing',
  true,
  true,
  'auto',
  'bundled',
  '{"type":"function","function":{"name":"run_daily_briefing","description":"Generate the daily business briefing as a platform SaaS automation. Deterministic metric aggregation + a single LLM summary. NOT a ReAct loop.","parameters":{"type":"object","properties":{"source":{"type":"string","description":"Trigger source label (cron, manual, automation)."}}}}}'::jsonb,
  '## run_daily_briefing
Platform SaaS automation. Aggregates metrics, asks LLM for narrative summary, persists to flowpilot_briefings, posts a system message into the admin''s today-session FlowChat, emails the owner.

Schedule: daily 07:00 UTC via the "Daily Briefing" automation in /admin/automations. NOT a FlowPilot ReAct skill.'
)
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description,
  handler = EXCLUDED.handler,
  tool_definition = EXCLUDED.tool_definition,
  instructions = EXCLUDED.instructions,
  enabled = true,
  mcp_exposed = true,
  updated_at = now();

-- 2. Insert/update the Daily Briefing automation row (platform executor)
INSERT INTO public.agent_automations (
  name, description, trigger_type, trigger_config,
  skill_id, skill_name, skill_arguments, enabled, executor
)
SELECT
  'Daily Briefing',
  'Platform automation. Generates the daily business briefing every morning at 07:00 UTC and posts it to admin FlowChat. Runs deterministically (no ReAct).',
  'cron',
  '{"cron":"0 7 * * *","expression":"0 7 * * *","timezone":"UTC"}'::jsonb,
  s.id,
  'run_daily_briefing',
  '{"source":"automation"}'::jsonb,
  true,
  'platform'
FROM public.agent_skills s
WHERE s.name = 'run_daily_briefing'
ON CONFLICT DO NOTHING;

-- If a row already exists with this name, ensure schedule + executor are correct
UPDATE public.agent_automations
SET
  trigger_type = 'cron',
  trigger_config = '{"cron":"0 7 * * *","expression":"0 7 * * *","timezone":"UTC"}'::jsonb,
  skill_name = 'run_daily_briefing',
  skill_id = (SELECT id FROM public.agent_skills WHERE name = 'run_daily_briefing'),
  executor = 'platform',
  enabled = true,
  updated_at = now()
WHERE name = 'Daily Briefing';

-- 3. Remove the old pg_cron job so the briefing isn't double-triggered
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flowpilot-daily-briefing') THEN
    PERFORM cron.unschedule('flowpilot-daily-briefing');
  END IF;
END $$;
