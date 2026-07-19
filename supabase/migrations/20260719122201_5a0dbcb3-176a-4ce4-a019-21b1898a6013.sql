INSERT INTO public.agent_skills (name, description, category, handler, scope, tool_definition, instructions, enabled, mcp_exposed, origin, trust_level, requires_staging)
VALUES (
  'cron_health_report',
  'Report the real health of this instance''s scheduled jobs — the truth pg_cron''s own status hides. Use when: verifying scheduled work actually runs; investigating "X never happened"; a routine health check. Flags jobs pointing at the WRONG instance (foreign_host), jobs that never ran, stale last-run times, and recent HTTP errors from cron-dispatched calls. NOT for: application error logs; skill failures (run_skill_curator).',
  'system',
  'rpc:cron_health_report',
  'internal',
  '{"type":"function","function":{"name":"cron_health_report","description":"Health of scheduled (pg_cron) jobs: per-job foreign_host/never_ran/last_status/last_run_age + recent HTTP errors. Read-only, no args.","parameters":{"type":"object","properties":{}}}}'::jsonb,
  'Read-only, no arguments. Returns { self_host, jobs, http_errors_recent, flags }. Key signal: foreign_host=true means the job targets another <ref>.supabase.co (hardcoded-URL bug). last_status="succeeded" only means pg_cron dispatched — cross-check http_errors_recent for 4xx/5xx.',
  true, true, 'bundled', 'notify', false
)
ON CONFLICT (name) DO UPDATE SET
  description=EXCLUDED.description,
  category=EXCLUDED.category,
  handler=EXCLUDED.handler,
  scope=EXCLUDED.scope,
  tool_definition=EXCLUDED.tool_definition,
  instructions=EXCLUDED.instructions,
  enabled=true,
  mcp_exposed=true;