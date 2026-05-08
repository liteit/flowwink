
-- Repoint payroll skills to the real p_-arg RPCs (mcp_* wrappers expect a single jsonb 'args')
UPDATE agent_skills SET handler = 'rpc:create_payroll_run'   WHERE name = 'create_payroll_run'   AND handler = 'rpc:mcp_create_payroll_run';
UPDATE agent_skills SET handler = 'rpc:approve_payroll_run'  WHERE name = 'approve_payroll_run'  AND handler = 'rpc:mcp_approve_payroll_run';
UPDATE agent_skills SET handler = 'rpc:mark_payroll_paid'    WHERE name = 'mark_payroll_paid'    AND handler = 'rpc:mcp_mark_payroll_paid';
UPDATE agent_skills SET handler = 'rpc:list_payroll_runs'    WHERE name = 'list_payroll_runs'    AND handler = 'rpc:mcp_list_payroll_runs';
UPDATE agent_skills SET handler = 'rpc:list_payroll_lines'   WHERE name = 'list_payroll_lines'   AND handler = 'rpc:mcp_list_payroll_lines';

-- FX revalue: same fix, props already align (revaluation_date / fx_*_account / ar_account / ap_account)
UPDATE agent_skills SET handler = 'rpc:revalue_open_balances' WHERE name = 'revalue_open_balances' AND handler = 'rpc:mcp_revalue_open_balances';

-- set_exchange_rate: repoint AND rename props base_currency→base, quote_currency→quote to match RPC signature
UPDATE agent_skills
SET handler = 'rpc:set_exchange_rate',
    tool_definition = jsonb_set(
      jsonb_set(
        tool_definition #- '{function,parameters,properties,base_currency}'
                       #- '{function,parameters,properties,quote_currency}',
        '{function,parameters,properties,base}',
        COALESCE(tool_definition #> '{function,parameters,properties,base_currency}', '{"type":"string","description":"Base currency code (e.g. SEK)"}'::jsonb)
      ),
      '{function,parameters,properties,quote}',
      COALESCE(tool_definition #> '{function,parameters,properties,quote_currency}', '{"type":"string","description":"Quote currency code (e.g. EUR)"}'::jsonb)
    )
WHERE name = 'set_exchange_rate' AND handler = 'rpc:mcp_set_exchange_rate';

-- Also patch the required[] array if it referenced the old names
UPDATE agent_skills
SET tool_definition = jsonb_set(
  tool_definition,
  '{function,parameters,required}',
  (
    SELECT jsonb_agg(
      CASE elem::text
        WHEN '"base_currency"' THEN '"base"'::jsonb
        WHEN '"quote_currency"' THEN '"quote"'::jsonb
        ELSE elem
      END
    )
    FROM jsonb_array_elements(tool_definition #> '{function,parameters,required}') elem
  )
)
WHERE name = 'set_exchange_rate'
  AND tool_definition #> '{function,parameters,required}' IS NOT NULL;
