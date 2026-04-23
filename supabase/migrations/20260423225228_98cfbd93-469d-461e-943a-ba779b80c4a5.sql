INSERT INTO public.agent_skills (
  name, description, category, handler, scope, tool_definition, instructions, enabled, mcp_exposed
) VALUES (
  'lock_timesheet_period',
  'Lock all time entries in a fiscal month by closing the accounting period. Use when: month-end close, payroll cutoff, "lock timesheets for March". NOT for: deleting individual entries (use log_time).',
  'commerce',
  'rpc:close_accounting_period',
  'internal',
  jsonb_build_object(
    'type','function',
    'function', jsonb_build_object(
      'name','lock_timesheet_period',
      'description','Lock all time entries in a fiscal month by closing the accounting period',
      'parameters', jsonb_build_object(
        'type','object',
        'properties', jsonb_build_object(
          'fiscal_year', jsonb_build_object('type','integer','description','Year, e.g. 2026'),
          'period_month', jsonb_build_object('type','integer','description','Month 1-12'),
          'notes', jsonb_build_object('type','string')
        ),
        'required', jsonb_build_array('fiscal_year','period_month')
      )
    )
  ),
  'Closes the given accounting period via close_accounting_period(p_year, p_month, p_notes). Once closed, the guard_time_entries_period trigger blocks any insert/update/delete on time_entries with entry_date in that month. Swedish: "lås tidrapporter", "stäng månad", "månadsstängning".',
  true,
  true
)
ON CONFLICT (name) DO UPDATE
SET description = EXCLUDED.description,
    tool_definition = EXCLUDED.tool_definition,
    instructions = EXCLUDED.instructions,
    handler = EXCLUDED.handler,
    enabled = true,
    mcp_exposed = true,
    updated_at = now();