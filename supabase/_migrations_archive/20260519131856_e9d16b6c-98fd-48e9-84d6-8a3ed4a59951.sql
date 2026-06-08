
CREATE OR REPLACE FUNCTION public.propose_accruals(p_year integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_year_end date := make_date(p_year, 12, 31);
  v_invoices jsonb := '[]'::jsonb;
  v_expenses jsonb := '[]'::jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'source','invoice','source_id',i.id,'reference',i.invoice_number,
    'issue_date',i.issue_date,'due_date',i.due_date,
    'amount_cents',i.total_cents - COALESCE(i.paid_amount_cents,0),
    'suggested_action', CASE WHEN i.due_date > v_year_end THEN 'defer_revenue' ELSE 'accrue_receivable' END
  )), '[]'::jsonb) INTO v_invoices
  FROM public.invoices i
  WHERE EXTRACT(YEAR FROM i.issue_date) = p_year
    AND i.status::text NOT IN ('paid','cancelled','void')
    AND (i.total_cents - COALESCE(i.paid_amount_cents,0)) > 0;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'source','expense_report','source_id',er.id,
    'amount_cents',er.total_cents,'status',er.status,
    'suggested_action','accrue_payable'
  )), '[]'::jsonb) INTO v_expenses
  FROM public.expense_reports er
  WHERE er.status IN ('approved','booked') AND er.total_cents > 0;

  RETURN jsonb_build_object(
    'year', p_year, 'year_end', v_year_end,
    'proposals', v_invoices || v_expenses,
    'proposal_count', jsonb_array_length(v_invoices) + jsonb_array_length(v_expenses),
    'note', 'Universal accrual scan. Locale packs add country-specific proposals via year_end_proposals callback.'
  );
END; $$;
GRANT EXECUTE ON FUNCTION public.propose_accruals(integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.propose_annual_depreciation(p_year integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_year_end date := make_date(p_year, 12, 31);
  v_proposals jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'asset_id', fa.id, 'asset_name', fa.name,
    'depreciation_account', fa.depreciation_account,
    'accumulated_account', fa.accumulated_account,
    'method', fa.depreciation_method,
    'annual_amount_cents', CASE
      WHEN fa.depreciation_method = 'straight_line'
        THEN (fa.cost_cents - fa.salvage_cents) / fa.useful_life_months * 12
      WHEN fa.depreciation_method = 'declining' AND fa.declining_rate IS NOT NULL
        THEN ROUND((fa.cost_cents - fa.accumulated_cents) * fa.declining_rate)::bigint
      ELSE 0 END,
    'remaining_after_cents', fa.cost_cents - fa.accumulated_cents
  )), '[]'::jsonb) INTO v_proposals
  FROM public.fixed_assets fa
  WHERE fa.status = 'active' AND fa.in_service_date <= v_year_end
    AND fa.accumulated_cents < (fa.cost_cents - fa.salvage_cents);

  RETURN jsonb_build_object(
    'year', p_year, 'asset_count', jsonb_array_length(v_proposals),
    'proposals', v_proposals,
    'note', 'Post via manage_journal_entry per asset (staged for approval).'
  );
END; $$;
GRANT EXECUTE ON FUNCTION public.propose_annual_depreciation(integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.run_year_end(p_year integer, p_confirm boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN jsonb_build_object(
    'year', p_year, 'confirm', p_confirm,
    'readiness', public.year_end_readiness(p_year),
    'accruals', public.propose_accruals(p_year),
    'depreciation', public.propose_annual_depreciation(p_year),
    'next_steps', jsonb_build_array(
      'Resolve any failing readiness checks',
      'Call manage_journal_entry per accrual proposal (staged for approval)',
      'Call manage_journal_entry per depreciation proposal (staged for approval)',
      'Call close_accounting_period for final period (staged)',
      'Optionally invoke locale-pack year_end_proposals callback'
    ),
    'note', 'Read-only orchestration. All writes go through staged skills.'
  );
END; $$;
GRANT EXECUTE ON FUNCTION public.run_year_end(integer, boolean) TO authenticated, service_role;

INSERT INTO public.agent_skills (name, description, category, handler, tool_definition, enabled, mcp_exposed, requires_staging)
VALUES
  ('propose_accruals',
   'Scan for unpaid invoices and approved-but-unpaid expense reports that may need year-end accrual entries. Returns proposals with suggested_action (defer_revenue, accrue_receivable, accrue_payable). Use when: closing a fiscal year and need periodiseringar. NOT for: posting accruals — call manage_journal_entry per proposal.',
   'commerce'::agent_skill_category, 'rpc:propose_accruals',
   jsonb_build_object('type','object',
     'properties', jsonb_build_object('p_year', jsonb_build_object('type','integer','description','Fiscal year, e.g. 2025')),
     'required', jsonb_build_array('p_year')),
   true, true, false),
  ('propose_annual_depreciation',
   'Compute proposed annual depreciation for all active fixed assets. Supports straight_line and declining methods. Returns one proposal per asset with account codes and amount. Use when: running year-end close. NOT for: monthly depreciation (different schedule).',
   'commerce'::agent_skill_category, 'rpc:propose_annual_depreciation',
   jsonb_build_object('type','object',
     'properties', jsonb_build_object('p_year', jsonb_build_object('type','integer','description','Fiscal year, e.g. 2025')),
     'required', jsonb_build_array('p_year')),
   true, true, false),
  ('run_year_end',
   'Orchestrate year-end close: runs year_end_readiness + propose_accruals + propose_annual_depreciation and returns a consolidated report with next-step instructions. Read-only; actual posting requires follow-up staged calls to manage_journal_entry. Use when: starting bokslut for a fiscal year. NOT for: posting entries directly.',
   'commerce'::agent_skill_category, 'rpc:run_year_end',
   jsonb_build_object('type','object',
     'properties', jsonb_build_object(
       'p_year', jsonb_build_object('type','integer','description','Fiscal year, e.g. 2025'),
       'p_confirm', jsonb_build_object('type','boolean','description','Reserved for future use','default',false)),
     'required', jsonb_build_array('p_year')),
   true, true, false)
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      tool_definition = EXCLUDED.tool_definition,
      handler = EXCLUDED.handler,
      enabled = true,
      mcp_exposed = true;
