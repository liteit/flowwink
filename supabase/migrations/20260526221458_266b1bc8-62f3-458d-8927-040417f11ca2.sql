
-- =============================================================================
-- Demo Data Platform — seed & reset per module without touching real data
-- =============================================================================

-- 1. Tracking tables
CREATE TABLE IF NOT EXISTS public.demo_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  module text NOT NULL,
  scenario text NOT NULL DEFAULT 'default',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

CREATE TABLE IF NOT EXISTS public.demo_run_items (
  id bigserial PRIMARY KEY,
  run_id uuid NOT NULL REFERENCES public.demo_runs(id) ON DELETE CASCADE,
  table_name text NOT NULL,
  row_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_demo_run_items_run ON public.demo_run_items(run_id);
CREATE INDEX IF NOT EXISTS idx_demo_run_items_table ON public.demo_run_items(table_name);

GRANT SELECT ON public.demo_runs TO authenticated;
GRANT SELECT ON public.demo_run_items TO authenticated;
GRANT ALL ON public.demo_runs TO service_role;
GRANT ALL ON public.demo_run_items TO service_role;
GRANT USAGE, SELECT ON SEQUENCE demo_run_items_id_seq TO authenticated;
GRANT ALL ON SEQUENCE demo_run_items_id_seq TO service_role;

ALTER TABLE public.demo_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.demo_run_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demo_runs admin read" ON public.demo_runs;
CREATE POLICY "demo_runs admin read" ON public.demo_runs
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin'::app_role));

DROP POLICY IF EXISTS "demo_run_items admin read" ON public.demo_run_items;
CREATE POLICY "demo_run_items admin read" ON public.demo_run_items
  FOR SELECT TO authenticated
  USING (has_role(auth.uid(), 'admin'::app_role));

-- 2. Internal helper — register a row as part of a demo run
CREATE OR REPLACE FUNCTION public._demo_register_row(
  p_run_id uuid, p_table_name text, p_row_id uuid
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO public.demo_run_items(run_id, table_name, row_id)
  VALUES (p_run_id, p_table_name, p_row_id);
$$;

-- 3. Per-module seeders
--    Each takes p_run_id, inserts rows, registers them, returns count.

-- CRM: leads
CREATE OR REPLACE FUNCTION public.seed_demo_crm(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count int := 0;
  v_lead_id uuid;
  rec record;
BEGIN
  FOR rec IN
    SELECT * FROM (VALUES
      ('Anna Lindberg',  'anna.lindberg@nordicfin.demo',  'lead',        72),
      ('Erik Sjöberg',   'erik@sjoberg-bygg.demo',        'opportunity', 88),
      ('Maria Holm',     'maria@holm-consulting.demo',    'lead',        45),
      ('Johan Persson',  'johan@persson-tech.demo',       'opportunity', 91),
      ('Sara Eklund',    'sara.eklund@eklundlaw.demo',    'lead',        58)
    ) AS t(name, email, status, score)
  LOOP
    INSERT INTO public.leads (email, name, status, score, source, ai_summary)
    VALUES (
      rec.email, rec.name, rec.status::lead_status, rec.score,
      'demo:' || p_scenario,
      'Demo lead seeded for scenario: ' || p_scenario
    )
    ON CONFLICT (email) DO UPDATE SET
      name = EXCLUDED.name, status = EXCLUDED.status, score = EXCLUDED.score,
      source = EXCLUDED.source, updated_at = now()
    RETURNING id INTO v_lead_id;
    PERFORM public._demo_register_row(p_run_id, 'leads', v_lead_id);
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('table', 'leads', 'inserted', v_count);
END $$;

-- Quotes
CREATE OR REPLACE FUNCTION public.seed_demo_quotes(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count int := 0;
  v_id uuid;
  v_number text;
  rec record;
BEGIN
  FOR rec IN
    SELECT * FROM (VALUES
      ('Acme Demo AB',    'kontakt@acme.demo',     'sent',     45000, 'Implementation package Q1'),
      ('Berg & Co Demo',  'info@bergco.demo',      'draft',    18000, 'Audit retainer 6 months'),
      ('Holm Consulting', 'maria@holm-consulting.demo', 'accepted', 92000, 'Annual subscription')
    ) AS t(customer, email, status, total, title)
  LOOP
    v_number := 'DEMO-Q-' || to_char(now(), 'YYMMDD') || '-' || lpad((v_count+1)::text, 3, '0');
    INSERT INTO public.quotes (
      quote_number, status, customer_name, customer_email,
      title, subtotal_cents, tax_cents, total_cents, currency,
      line_items, notes
    ) VALUES (
      v_number, rec.status::quote_status, rec.customer, rec.email,
      rec.title,
      (rec.total * 0.8)::int, (rec.total * 0.2)::int, rec.total, 'SEK',
      jsonb_build_array(jsonb_build_object(
        'description', rec.title, 'quantity', 1,
        'unit_price_cents', (rec.total * 0.8)::int
      )),
      'demo:' || p_scenario
    ) RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id, 'quotes', v_id);
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('table', 'quotes', 'inserted', v_count);
END $$;

-- Invoices
CREATE OR REPLACE FUNCTION public.seed_demo_invoices(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count int := 0;
  v_id uuid;
  v_number text;
  rec record;
BEGIN
  FOR rec IN
    SELECT * FROM (VALUES
      ('Acme Demo AB',    'kontakt@acme.demo',     'sent',  45000),
      ('Berg & Co Demo',  'info@bergco.demo',      'draft', 18000),
      ('Holm Consulting', 'maria@holm-consulting.demo', 'paid', 92000)
    ) AS t(customer, email, status, total)
  LOOP
    v_number := 'DEMO-INV-' || to_char(now(), 'YYMMDD') || '-' || lpad((v_count+1)::text, 3, '0');
    INSERT INTO public.invoices (
      invoice_number, status, customer_name, customer_email,
      subtotal_cents, tax_cents, total_cents, currency,
      issue_date, due_date, line_items, notes,
      paid_at, paid_amount_cents
    ) VALUES (
      v_number, rec.status::invoice_status, rec.customer, rec.email,
      (rec.total * 0.8)::int, (rec.total * 0.2)::int, rec.total, 'SEK',
      CURRENT_DATE - 10, CURRENT_DATE + 20,
      jsonb_build_array(jsonb_build_object(
        'description', 'Demo services', 'quantity', 1,
        'unit_price_cents', (rec.total * 0.8)::int
      )),
      'demo:' || p_scenario,
      CASE WHEN rec.status = 'paid' THEN now() ELSE NULL END,
      CASE WHEN rec.status = 'paid' THEN rec.total ELSE 0 END
    ) RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id, 'invoices', v_id);
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('table', 'invoices', 'inserted', v_count);
END $$;

-- Expenses (requires a user_id — use the calling admin)
CREATE OR REPLACE FUNCTION public.seed_demo_expenses(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count int := 0;
  v_id uuid;
  v_user uuid;
  rec record;
BEGIN
  v_user := auth.uid();
  IF v_user IS NULL THEN
    -- pick first admin so seeding works from cron / service role too
    SELECT user_id INTO v_user FROM public.user_roles WHERE role = 'admin'::app_role LIMIT 1;
  END IF;
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('table', 'expenses', 'inserted', 0, 'skipped', 'no admin user');
  END IF;

  FOR rec IN
    SELECT * FROM (VALUES
      ('Lunch with prospect Acme', 'travel',        45000,  9000,  'Restaurant Demo'),
      ('Office supplies',           'office',       12000,  2400,  'Demo Office Supply'),
      ('Conference ticket Q1',      'training',     250000, 50000, 'TechConf Demo')
    ) AS t(description, category, amount, vat, vendor)
  LOOP
    INSERT INTO public.expenses (
      user_id, expense_date, description, amount_cents, vat_cents,
      currency, category, vendor
    ) VALUES (
      v_user, CURRENT_DATE - (v_count * 3), rec.description,
      rec.amount, rec.vat, 'SEK', rec.category, rec.vendor || ' [demo:' || p_scenario || ']'
    ) RETURNING id INTO v_id;
    PERFORM public._demo_register_row(p_run_id, 'expenses', v_id);
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('table', 'expenses', 'inserted', v_count);
END $$;

-- 4. Public dispatcher: seed_module_demo
CREATE OR REPLACE FUNCTION public.seed_module_demo(
  p_module text,
  p_scenario text DEFAULT 'default'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_run_id uuid;
  v_result jsonb;
  v_module text;
BEGIN
  -- Require admin
  IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Only admins can seed demo data';
  END IF;

  v_module := lower(trim(p_module));

  INSERT INTO public.demo_runs(module, scenario, created_by)
  VALUES (v_module, p_scenario, auth.uid())
  RETURNING id INTO v_run_id;

  CASE v_module
    WHEN 'crm'      THEN v_result := public.seed_demo_crm(v_run_id, p_scenario);
    WHEN 'quotes'   THEN v_result := public.seed_demo_quotes(v_run_id, p_scenario);
    WHEN 'invoices' THEN v_result := public.seed_demo_invoices(v_run_id, p_scenario);
    WHEN 'expenses' THEN v_result := public.seed_demo_expenses(v_run_id, p_scenario);
    ELSE
      DELETE FROM public.demo_runs WHERE id = v_run_id;
      RAISE EXCEPTION 'Unsupported module: %. Supported: crm, quotes, invoices, expenses', v_module;
  END CASE;

  RETURN jsonb_build_object(
    'success', true,
    'run_id', v_run_id,
    'module', v_module,
    'scenario', p_scenario,
    'detail', v_result
  );
END $$;

GRANT EXECUTE ON FUNCTION public.seed_module_demo(text, text) TO authenticated, service_role;

-- 5. Reset: reset_module_data
--    Hardcoded protected tables (defense in depth — we only ever touch
--    rows registered in demo_run_items, but never the items below)
CREATE OR REPLACE FUNCTION public.reset_module_data(
  p_module text,
  p_dry_run boolean DEFAULT true,
  p_run_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  PROTECTED_TABLES text[] := ARRAY[
    'kb_articles','pages','blog_posts','products','agent_skills',
    'agent_objectives','agent_memory','site_settings','contract_templates',
    'quote_templates','locale_packs','user_roles','profiles'
  ];
  v_module text;
  v_counts jsonb := '{}'::jsonb;
  v_tbl text;
  v_count int;
  v_total int := 0;
  v_sql text;
BEGIN
  IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Only admins can reset demo data';
  END IF;

  v_module := lower(trim(p_module));

  -- Build per-table counts of rows that would be deleted
  FOR v_tbl, v_count IN
    SELECT i.table_name, count(*)::int
    FROM public.demo_run_items i
    JOIN public.demo_runs r ON r.id = i.run_id
    WHERE (v_module = 'all' OR r.module = v_module)
      AND (p_run_id IS NULL OR r.id = p_run_id)
    GROUP BY i.table_name
  LOOP
    IF v_tbl = ANY(PROTECTED_TABLES) THEN
      CONTINUE; -- never touch protected tables, even if registered
    END IF;
    v_counts := v_counts || jsonb_build_object(v_tbl, v_count);
    v_total := v_total + v_count;

    IF NOT p_dry_run THEN
      v_sql := format(
        'DELETE FROM public.%I WHERE id IN (
           SELECT i.row_id FROM public.demo_run_items i
           JOIN public.demo_runs r ON r.id = i.run_id
           WHERE i.table_name = %L
             AND (%L = ''all'' OR r.module = %L)
             AND (%L::uuid IS NULL OR r.id = %L::uuid)
         )',
        v_tbl, v_tbl, v_module, v_module, p_run_id, p_run_id
      );
      EXECUTE v_sql;
    END IF;
  END LOOP;

  -- Clean up empty demo_runs when actually applied
  IF NOT p_dry_run THEN
    DELETE FROM public.demo_runs r
    WHERE (v_module = 'all' OR r.module = v_module)
      AND (p_run_id IS NULL OR r.id = p_run_id);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'dry_run', p_dry_run,
    'module', v_module,
    'run_id', p_run_id,
    'total_rows', v_total,
    'counts_by_table', v_counts
  );
END $$;

GRANT EXECUTE ON FUNCTION public.reset_module_data(text, boolean, uuid) TO authenticated, service_role;

-- 6. Register two MCP-exposed skills
INSERT INTO public.agent_skills (
  name, description, category, scope, handler, mcp_exposed, requires_staging, trust_level,
  tool_definition, instructions
) VALUES
(
  'seed_module_demo',
  'Seeds realistic demo/simulation data into a specific module. Tags every row with a demo run ID so it can be cleanly removed later. Use when: a game-master agent wants to set up a scenario for testing or showcasing a workflow (CRM leads, quote-to-cash, expense booking). NOT for: real customer data.',
  'system'::agent_skill_category,
  'internal'::agent_scope,
  'rpc:seed_module_demo',
  true, false, 'auto'::skill_trust_level,
  jsonb_build_object(
    'type','object',
    'properties', jsonb_build_object(
      'module', jsonb_build_object('type','string','enum',ARRAY['crm','quotes','invoices','expenses'],'description','Module to seed'),
      'scenario', jsonb_build_object('type','string','description','Scenario name (e.g. quiet, busy, lead_storm). Default: default','default','default')
    ),
    'required', jsonb_build_array('module')
  ),
  'Always pick a descriptive scenario name so different demo runs can be told apart in /admin/developer.'
),
(
  'reset_module_data',
  'Removes demo/simulation data previously created by seed_module_demo. Only deletes rows explicitly registered in demo_run_items — never touches templates, KB articles, products, or real customer data. Defaults to dry_run=true (returns counts only). Use module=all to reset everything across modules.',
  'system'::agent_skill_category,
  'internal'::agent_scope,
  'rpc:reset_module_data',
  true, true, 'approve'::skill_trust_level,
  jsonb_build_object(
    'type','object',
    'properties', jsonb_build_object(
      'module', jsonb_build_object('type','string','description','Module name, or "all" to reset every module'),
      'dry_run', jsonb_build_object('type','boolean','description','If true, returns counts without deleting. Default true.','default',true),
      'run_id', jsonb_build_object('type','string','format','uuid','description','Optional: restrict to a specific demo run')
    ),
    'required', jsonb_build_array('module')
  ),
  'Always run with dry_run=true first and report counts to the human. Real deletes (dry_run=false) require approval via the staging queue.'
)
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description,
  tool_definition = EXCLUDED.tool_definition,
  handler = EXCLUDED.handler,
  mcp_exposed = EXCLUDED.mcp_exposed,
  requires_staging = EXCLUDED.requires_staging,
  trust_level = EXCLUDED.trust_level,
  instructions = EXCLUDED.instructions,
  updated_at = now();
