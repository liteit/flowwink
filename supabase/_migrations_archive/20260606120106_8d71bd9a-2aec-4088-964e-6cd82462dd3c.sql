
CREATE OR REPLACE FUNCTION public.seed_module_demo(p_module text, p_scenario text DEFAULT 'default')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_run_id uuid;
  v_result jsonb;
  v_module text;
BEGIN
  v_module := lower(trim(p_module));
  INSERT INTO demo_runs (module, scenario, status, created_by)
  VALUES (v_module, p_scenario, 'running', auth.uid())
  RETURNING id INTO v_run_id;

  CASE v_module
    WHEN 'crm', 'leads'       THEN v_result := seed_demo_crm(v_run_id, p_scenario);
    WHEN 'quotes'             THEN v_result := seed_demo_quotes(v_run_id, p_scenario);
    WHEN 'invoices'           THEN v_result := seed_demo_invoices(v_run_id, p_scenario);
    WHEN 'expenses'           THEN v_result := seed_demo_expenses(v_run_id, p_scenario);
    WHEN 'ecommerce'          THEN v_result := seed_demo_ecommerce(v_run_id, p_scenario);
    WHEN 'consultants'        THEN v_result := seed_demo_consultants(v_run_id, p_scenario);
    WHEN 'blog'               THEN v_result := seed_demo_blog(v_run_id, p_scenario);
    WHEN 'kb'                 THEN v_result := seed_demo_kb(v_run_id, p_scenario);
    WHEN 'projects'           THEN v_result := seed_demo_projects(v_run_id, p_scenario);
    WHEN 'hr'                 THEN v_result := seed_demo_hr(v_run_id, p_scenario);
    WHEN 'tickets'            THEN v_result := seed_demo_tickets(v_run_id, p_scenario);
    WHEN 'bookings'           THEN v_result := seed_demo_bookings(v_run_id, p_scenario);
    WHEN 'newsletter'         THEN v_result := seed_demo_newsletter(v_run_id, p_scenario);
    WHEN 'vendors'            THEN v_result := seed_demo_vendors(v_run_id, p_scenario);
    WHEN 'contracts'          THEN v_result := seed_demo_contracts(v_run_id, p_scenario);
    WHEN 'companies'          THEN v_result := seed_demo_companies(v_run_id, p_scenario);
    WHEN 'deals'              THEN v_result := seed_demo_deals(v_run_id, p_scenario);
    WHEN 'recruitment'        THEN v_result := seed_demo_recruitment(v_run_id, p_scenario);
    WHEN 'pricelists'         THEN v_result := seed_demo_pricelists(v_run_id, p_scenario);
    WHEN 'surveys'            THEN v_result := seed_demo_surveys(v_run_id, p_scenario);
    WHEN 'documents'          THEN v_result := seed_demo_documents(v_run_id, p_scenario);
    WHEN 'inventory'          THEN v_result := seed_demo_inventory(v_run_id, p_scenario);
    WHEN 'webinars'           THEN v_result := seed_demo_webinars(v_run_id, p_scenario);
    WHEN 'timesheets'         THEN v_result := seed_demo_timesheets(v_run_id, p_scenario);
    WHEN 'subscriptions'      THEN v_result := seed_demo_subscriptions(v_run_id, p_scenario);
    WHEN 'accounting'         THEN v_result := seed_demo_accounting(v_run_id, p_scenario);
    WHEN 'reconciliation'     THEN v_result := seed_demo_reconciliation(v_run_id, p_scenario);
    WHEN 'pos'                THEN v_result := seed_demo_pos(v_run_id, p_scenario);
    WHEN 'approvals'          THEN v_result := seed_demo_approvals(v_run_id, p_scenario);
    WHEN 'sla'                THEN v_result := seed_demo_sla(v_run_id, p_scenario);
    ELSE
      UPDATE demo_runs SET status='failed', error='Unknown module: '||v_module, finished_at=now() WHERE id=v_run_id;
      RETURN jsonb_build_object('success', false, 'error', 'Unknown module: '||v_module);
  END CASE;

  UPDATE demo_runs SET status='completed', finished_at=now(), result=v_result WHERE id=v_run_id;
  RETURN jsonb_build_object('success', true, 'run_id', v_run_id, 'module', v_module, 'scenario', p_scenario, 'detail', v_result);
END;
$$;

GRANT EXECUTE ON FUNCTION public.seed_module_demo(text, text) TO authenticated, service_role;
