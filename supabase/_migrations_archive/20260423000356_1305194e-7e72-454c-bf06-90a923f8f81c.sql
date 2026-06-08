UPDATE public.agent_skills
SET enabled = true, mcp_exposed = true
WHERE name IN ('manage_employee', 'manage_invoice', 'parse_resume');

INSERT INTO public.agent_skills (name, handler, enabled, mcp_exposed, category, tool_definition)
SELECT v.name, v.handler, v.enabled, v.mcp_exposed, v.category::agent_skill_category, v.tool_definition
FROM (VALUES
  ('list_contract_documents', 'db:contracts', true, true, 'commerce',
   jsonb_build_object('type','function','function',
     jsonb_build_object('name','list_contract_documents',
       'description','List all documents linked to a specific contract.',
       'parameters', jsonb_build_object('type','object',
         'properties', jsonb_build_object('contract_id', jsonb_build_object('type','string')),
         'required', jsonb_build_array('contract_id'))))),
  ('log_time', 'db:timesheets', true, true, 'crm',
   jsonb_build_object('type','function','function',
     jsonb_build_object('name','log_time',
       'description','Log billable or internal hours against a project/task for an employee.',
       'parameters', jsonb_build_object('type','object',
         'properties', jsonb_build_object(
           'employee_id', jsonb_build_object('type','string'),
           'project_id', jsonb_build_object('type','string'),
           'task_id', jsonb_build_object('type','string'),
           'date', jsonb_build_object('type','string'),
           'hours', jsonb_build_object('type','number'),
           'description', jsonb_build_object('type','string')),
         'required', jsonb_build_array('hours'))))),
  ('timesheet_summary', 'db:timesheets', true, true, 'analytics',
   jsonb_build_object('type','function','function',
     jsonb_build_object('name','timesheet_summary',
       'description','Aggregate logged hours per employee/project for a date range.',
       'parameters', jsonb_build_object('type','object',
         'properties', jsonb_build_object(
           'from_date', jsonb_build_object('type','string'),
           'to_date', jsonb_build_object('type','string'),
           'employee_id', jsonb_build_object('type','string'),
           'project_id', jsonb_build_object('type','string'))))))
) AS v(name, handler, enabled, mcp_exposed, category, tool_definition)
WHERE NOT EXISTS (SELECT 1 FROM public.agent_skills s WHERE s.name = v.name);