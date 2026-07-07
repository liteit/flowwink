-- Payroll: parity round 7 (docs/parity/capabilities/payroll.json)
-- Adds: salary structure config (salary_structures + components, wired into
-- run creation), multi-country payroll (payroll_country_profiles driving
-- employer social fee + default tax per employee country), salary advances
-- (JE Dt 1610 / Cr 1930 on grant, auto-deducted on the next run, settled
-- Cr 1610 on approve), tax corrections on draft runs, structured payslips
-- with employee self-service access (get_payslip), year-end certification
-- summary (KU-style), and tax-authority integration via AGI XML export
-- (arbetsgivardeklaration på individnivå).
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. Schema additions ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.payroll_country_profiles (
  country_code text PRIMARY KEY,
  name text NOT NULL,
  employer_social_pct numeric NOT NULL,
  default_tax_pct numeric NOT NULL,
  currency text NOT NULL DEFAULT 'SEK',
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.payroll_country_profiles (country_code, name, employer_social_pct, default_tax_pct, currency, notes) VALUES
  ('SE', 'Sweden',  31.42, 30.00, 'SEK', 'Arbetsgivaravgift 31.42%, PAYE schablon 30%'),
  ('NO', 'Norway',  14.10, 34.00, 'NOK', 'Arbeidsgiveravgift sone 1; verify per year'),
  ('DK', 'Denmark',  1.05, 38.00, 'DKK', 'ATP/AUB/AES approximation — DK social costs are mostly employee-side'),
  ('FI', 'Finland', 19.61, 25.00, 'EUR', 'TyEL + sava approximation; verify per year'),
  ('DE', 'Germany', 20.65, 35.00, 'EUR', 'Employer share SV approximation; verify per year')
ON CONFLICT (country_code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.salary_structures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  description text,
  base_salary_cents bigint,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.salary_structure_components (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  structure_id uuid NOT NULL REFERENCES public.salary_structures(id) ON DELETE CASCADE,
  label text NOT NULL,
  component_type text NOT NULL DEFAULT 'salary',
  amount_cents bigint NOT NULL DEFAULT 0,
  pct_of_base numeric,
  taxable boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.salary_structure_components DROP CONSTRAINT IF EXISTS salary_structure_components_type_check;
ALTER TABLE public.salary_structure_components
  ADD CONSTRAINT salary_structure_components_type_check
  CHECK (component_type IN ('salary','bonus','overtime','benefit','deduction'));

CREATE TABLE IF NOT EXISTS public.salary_advances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  granted_date date NOT NULL DEFAULT CURRENT_DATE,
  reason text,
  status text NOT NULL DEFAULT 'open',
  journal_id uuid,
  repayment_run_id uuid,
  repaid_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.salary_advances DROP CONSTRAINT IF EXISTS salary_advances_status_check;
ALTER TABLE public.salary_advances
  ADD CONSTRAINT salary_advances_status_check
  CHECK (status IN ('open','repaying','repaid','cancelled'));

ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS payroll_country text NOT NULL DEFAULT 'SE';
ALTER TABLE public.employees ADD COLUMN IF NOT EXISTS salary_structure_id uuid REFERENCES public.salary_structures(id) ON DELETE SET NULL;
ALTER TABLE public.employees DROP CONSTRAINT IF EXISTS employees_payroll_country_fk;
ALTER TABLE public.employees
  ADD CONSTRAINT employees_payroll_country_fk FOREIGN KEY (payroll_country)
  REFERENCES public.payroll_country_profiles(country_code) ON UPDATE CASCADE;

ALTER TABLE public.payroll_lines ADD COLUMN IF NOT EXISTS advance_deduction_cents bigint NOT NULL DEFAULT 0;
ALTER TABLE public.payroll_lines ADD COLUMN IF NOT EXISTS tax_correction_cents bigint NOT NULL DEFAULT 0;
ALTER TABLE public.payroll_runs ADD COLUMN IF NOT EXISTS total_advances_cents bigint NOT NULL DEFAULT 0;

DO $do$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['payroll_country_profiles','salary_structures','salary_structure_components','salary_advances'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS "Admins manage %s" ON public.%I', t, t);
    EXECUTE format('CREATE POLICY "Admins manage %s" ON public.%I FOR ALL
      USING (has_role(auth.uid(), ''admin''::app_role))
      WITH CHECK (has_role(auth.uid(), ''admin''::app_role))', t, t);
  END LOOP;
END $do$;

-- ── 2. Country profiles skill ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_payroll_country(
  p_action text,
  p_country_code text DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_employer_social_pct numeric DEFAULT NULL,
  p_default_tax_pct numeric DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.payroll_country_profiles;
  v_rows jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can manage payroll country profiles';
  END IF;

  IF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.country_code), '[]'::jsonb) INTO v_rows
    FROM public.payroll_country_profiles p;
    RETURN jsonb_build_object('success', true, 'profiles', v_rows);

  ELSIF p_action = 'upsert' THEN
    IF p_country_code IS NULL THEN RAISE EXCEPTION 'upsert requires p_country_code'; END IF;
    INSERT INTO public.payroll_country_profiles (country_code, name, employer_social_pct, default_tax_pct, currency, notes)
    VALUES (upper(p_country_code), COALESCE(p_name, upper(p_country_code)),
      COALESCE(p_employer_social_pct, 31.42), COALESCE(p_default_tax_pct, 30.00),
      upper(COALESCE(p_currency,'SEK')), p_notes)
    ON CONFLICT (country_code) DO UPDATE SET
      name = COALESCE(p_name, payroll_country_profiles.name),
      employer_social_pct = COALESCE(p_employer_social_pct, payroll_country_profiles.employer_social_pct),
      default_tax_pct = COALESCE(p_default_tax_pct, payroll_country_profiles.default_tax_pct),
      currency = COALESCE(upper(p_currency), payroll_country_profiles.currency),
      notes = COALESCE(p_notes, payroll_country_profiles.notes),
      updated_at = now()
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'profile', to_jsonb(v_row));

  ELSIF p_action = 'delete' THEN
    IF upper(p_country_code) = 'SE' THEN RAISE EXCEPTION 'Cannot delete the SE default profile'; END IF;
    DELETE FROM public.payroll_country_profiles WHERE country_code = upper(p_country_code);
    RETURN jsonb_build_object('success', true, 'deleted', upper(p_country_code));

  ELSIF p_action = 'assign_employee' THEN
    IF p_employee_id IS NULL OR p_country_code IS NULL THEN
      RAISE EXCEPTION 'assign_employee requires p_employee_id and p_country_code';
    END IF;
    UPDATE public.employees SET payroll_country = upper(p_country_code) WHERE id = p_employee_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Employee % not found', p_employee_id; END IF;
    RETURN jsonb_build_object('success', true, 'employee_id', p_employee_id,
      'payroll_country', upper(p_country_code));

  ELSE
    RAISE EXCEPTION 'Unknown action %. Use upsert|list|delete|assign_employee', p_action;
  END IF;
END;
$$;

-- ── 3. Salary structures skill ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_salary_structure(
  p_action text,
  p_structure_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_base_salary_cents bigint DEFAULT NULL,
  p_active boolean DEFAULT NULL,
  p_component_id uuid DEFAULT NULL,
  p_label text DEFAULT NULL,
  p_component_type text DEFAULT NULL,
  p_amount_cents bigint DEFAULT NULL,
  p_pct_of_base numeric DEFAULT NULL,
  p_taxable boolean DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.salary_structures;
  v_comp public.salary_structure_components;
  v_rows jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can manage salary structures';
  END IF;

  IF p_action = 'create' THEN
    IF p_name IS NULL THEN RAISE EXCEPTION 'create requires p_name'; END IF;
    INSERT INTO public.salary_structures (name, description, base_salary_cents)
    VALUES (p_name, p_description, p_base_salary_cents)
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'structure', to_jsonb(v_row));

  ELSIF p_action = 'update' THEN
    UPDATE public.salary_structures SET
      name = COALESCE(p_name, name),
      description = COALESCE(p_description, description),
      base_salary_cents = COALESCE(p_base_salary_cents, base_salary_cents),
      active = COALESCE(p_active, active),
      updated_at = now()
    WHERE id = p_structure_id
    RETURNING * INTO v_row;
    IF NOT FOUND THEN RAISE EXCEPTION 'Structure % not found', p_structure_id; END IF;
    RETURN jsonb_build_object('success', true, 'structure', to_jsonb(v_row));

  ELSIF p_action = 'delete' THEN
    UPDATE public.employees SET salary_structure_id = NULL WHERE salary_structure_id = p_structure_id;
    DELETE FROM public.salary_structures WHERE id = p_structure_id;
    RETURN jsonb_build_object('success', true, 'deleted', p_structure_id);

  ELSIF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(s_data ORDER BY s_data->>'name'), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT to_jsonb(s) || jsonb_build_object(
        'components', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sort_order, c.created_at), '[]'::jsonb)
                       FROM public.salary_structure_components c WHERE c.structure_id = s.id),
        'assigned_employees', (SELECT COUNT(*) FROM public.employees e WHERE e.salary_structure_id = s.id)
      ) AS s_data
      FROM public.salary_structures s
    ) x;
    RETURN jsonb_build_object('success', true, 'structures', v_rows);

  ELSIF p_action = 'get' THEN
    SELECT * INTO v_row FROM public.salary_structures WHERE id = p_structure_id OR (p_structure_id IS NULL AND name = p_name);
    IF NOT FOUND THEN RAISE EXCEPTION 'Structure not found'; END IF;
    RETURN jsonb_build_object('success', true, 'structure', to_jsonb(v_row) || jsonb_build_object(
      'components', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.sort_order, c.created_at), '[]'::jsonb)
                     FROM public.salary_structure_components c WHERE c.structure_id = v_row.id)));

  ELSIF p_action = 'add_component' THEN
    IF p_structure_id IS NULL OR p_label IS NULL THEN
      RAISE EXCEPTION 'add_component requires p_structure_id and p_label';
    END IF;
    IF p_amount_cents IS NULL AND p_pct_of_base IS NULL THEN
      RAISE EXCEPTION 'add_component requires p_amount_cents or p_pct_of_base';
    END IF;
    INSERT INTO public.salary_structure_components (structure_id, label, component_type, amount_cents, pct_of_base, taxable)
    VALUES (p_structure_id, p_label, COALESCE(p_component_type,'salary'),
      COALESCE(p_amount_cents,0), p_pct_of_base, COALESCE(p_taxable,true))
    RETURNING * INTO v_comp;
    RETURN jsonb_build_object('success', true, 'component', to_jsonb(v_comp));

  ELSIF p_action = 'update_component' THEN
    UPDATE public.salary_structure_components SET
      label = COALESCE(p_label, label),
      component_type = COALESCE(p_component_type, component_type),
      amount_cents = COALESCE(p_amount_cents, amount_cents),
      pct_of_base = COALESCE(p_pct_of_base, pct_of_base),
      taxable = COALESCE(p_taxable, taxable)
    WHERE id = p_component_id
    RETURNING * INTO v_comp;
    IF NOT FOUND THEN RAISE EXCEPTION 'Component % not found', p_component_id; END IF;
    RETURN jsonb_build_object('success', true, 'component', to_jsonb(v_comp));

  ELSIF p_action = 'remove_component' THEN
    DELETE FROM public.salary_structure_components WHERE id = p_component_id;
    RETURN jsonb_build_object('success', true, 'deleted', p_component_id);

  ELSIF p_action = 'assign' THEN
    IF p_employee_id IS NULL OR p_structure_id IS NULL THEN
      RAISE EXCEPTION 'assign requires p_employee_id and p_structure_id';
    END IF;
    UPDATE public.employees SET salary_structure_id = p_structure_id WHERE id = p_employee_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Employee % not found', p_employee_id; END IF;
    RETURN jsonb_build_object('success', true, 'employee_id', p_employee_id, 'structure_id', p_structure_id);

  ELSIF p_action = 'unassign' THEN
    UPDATE public.employees SET salary_structure_id = NULL WHERE id = p_employee_id;
    RETURN jsonb_build_object('success', true, 'employee_id', p_employee_id, 'structure_id', NULL);

  ELSE
    RAISE EXCEPTION 'Unknown action %. Use create|update|delete|list|get|add_component|update_component|remove_component|assign|unassign', p_action;
  END IF;
END;
$$;

-- ── 4. Salary advances skill ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_salary_advance(
  p_action text,
  p_advance_id uuid DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL,
  p_amount_cents bigint DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_granted_date date DEFAULT NULL,
  p_post_journal boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.salary_advances;
  v_rows jsonb;
  v_je uuid;
  v_name text;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can manage salary advances';
  END IF;

  IF p_action = 'grant' THEN
    IF p_employee_id IS NULL OR p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
      RAISE EXCEPTION 'grant requires p_employee_id and a positive p_amount_cents';
    END IF;
    SELECT name INTO v_name FROM public.employees WHERE id = p_employee_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Employee % not found', p_employee_id; END IF;

    IF COALESCE(p_post_journal, true) THEN
      INSERT INTO public.journal_entries (entry_date, description, status, source)
      VALUES (COALESCE(p_granted_date, CURRENT_DATE), 'Löneförskott ' || v_name, 'posted', 'payroll')
      RETURNING id INTO v_je;
      INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
      VALUES (v_je, '1610', p_amount_cents, 0, 'Kortfristig fordran hos anställd'),
             (v_je, '1930', 0, p_amount_cents, 'Utbetalt löneförskott');
    END IF;

    INSERT INTO public.salary_advances (employee_id, amount_cents, granted_date, reason, journal_id, created_by)
    VALUES (p_employee_id, p_amount_cents, COALESCE(p_granted_date, CURRENT_DATE), p_reason, v_je, auth.uid())
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'advance', to_jsonb(v_row), 'journal_entry_id', v_je,
      'note', 'The advance is deducted from net pay on the next payroll run created for this employee.');

  ELSIF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(a_data ORDER BY a_data->>'granted_date' DESC), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT to_jsonb(a) || jsonb_build_object('employee_name', e.name) AS a_data
      FROM public.salary_advances a JOIN public.employees e ON e.id = a.employee_id
      WHERE (p_employee_id IS NULL OR a.employee_id = p_employee_id)
      LIMIT 200
    ) x;
    RETURN jsonb_build_object('success', true, 'advances', v_rows);

  ELSIF p_action = 'cancel' THEN
    SELECT * INTO v_row FROM public.salary_advances WHERE id = p_advance_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Advance % not found', p_advance_id; END IF;
    IF v_row.status <> 'open' THEN
      RAISE EXCEPTION 'Only open advances can be cancelled (status: %)', v_row.status;
    END IF;
    IF v_row.journal_id IS NOT NULL THEN
      SELECT name INTO v_name FROM public.employees WHERE id = v_row.employee_id;
      INSERT INTO public.journal_entries (entry_date, description, status, source)
      VALUES (CURRENT_DATE, 'Återfört löneförskott ' || COALESCE(v_name,''), 'posted', 'payroll')
      RETURNING id INTO v_je;
      INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
      VALUES (v_je, '1930', v_row.amount_cents, 0, 'Återbetalt löneförskott'),
             (v_je, '1610', 0, v_row.amount_cents, 'Avräkning löneförskott');
    END IF;
    UPDATE public.salary_advances SET status='cancelled', updated_at=now() WHERE id = p_advance_id
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'advance', to_jsonb(v_row), 'reversal_journal_id', v_je);

  ELSE
    RAISE EXCEPTION 'Unknown action %. Use grant|list|cancel', p_action;
  END IF;
END;
$$;

-- ── 5. Run creation v2: structures, country profiles, advance deduction ─────
CREATE OR REPLACE FUNCTION public.create_payroll_run(p_period_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_run_id UUID; v_emp RECORD;
  v_base BIGINT; v_earn BIGINT; v_benefits BIGINT; v_deductions BIGINT;
  v_s_earn BIGINT; v_s_benefits BIGINT; v_s_deductions BIGINT;
  v_taxable BIGINT; v_tax BIGINT; v_social BIGINT; v_net BIGINT; v_gross BIGINT;
  v_components JSONB; v_s_components JSONB;
  v_social_pct numeric; v_adv BIGINT; v_adv_skipped BIGINT := 0;
  v_total_gross BIGINT := 0; v_total_tax BIGINT := 0; v_total_social BIGINT := 0;
  v_total_net BIGINT := 0; v_total_adv BIGINT := 0;
  v_lines INT := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin')) THEN
    RAISE EXCEPTION 'Only admins can create payroll runs';
  END IF;
  INSERT INTO public.payroll_runs (period_date, status)
  VALUES (date_trunc('month', p_period_date)::date, 'draft')
  RETURNING id INTO v_run_id;
  FOR v_emp IN
    SELECT id, COALESCE(monthly_salary_cents,0) AS base, COALESCE(tax_rate_pct,30.00) AS tax_pct,
           COALESCE(payroll_country,'SE') AS country, salary_structure_id
    FROM public.employees WHERE COALESCE(status,'active') = 'active'
  LOOP
    -- Country profile drives the employer social fee (SE default 31.42).
    SELECT employer_social_pct INTO v_social_pct
    FROM public.payroll_country_profiles WHERE country_code = v_emp.country;
    v_social_pct := COALESCE(v_social_pct, 31.42);

    -- Base salary: employee salary, else the assigned structure's base.
    v_base := v_emp.base;
    IF v_base = 0 AND v_emp.salary_structure_id IS NOT NULL THEN
      SELECT COALESCE(base_salary_cents, 0) INTO v_base
      FROM public.salary_structures WHERE id = v_emp.salary_structure_id AND active;
      v_base := COALESCE(v_base, 0);
    END IF;

    -- Per-employee recurring components (unchanged behaviour).
    SELECT
      COALESCE(SUM(CASE WHEN component_type IN ('salary','bonus','overtime') AND taxable THEN amount_cents ELSE 0 END),0),
      COALESCE(SUM(CASE WHEN component_type='benefit' THEN amount_cents ELSE 0 END),0),
      COALESCE(SUM(CASE WHEN component_type='deduction' THEN amount_cents ELSE 0 END),0),
      COALESCE(jsonb_agg(jsonb_build_object('type',component_type,'label',label,'amount_cents',amount_cents,'taxable',taxable)),'[]'::jsonb)
    INTO v_earn, v_benefits, v_deductions, v_components
    FROM (SELECT component_type, label, amount_cents, taxable FROM public.payroll_components
          WHERE employee_id = v_emp.id AND active AND recurring) c;

    -- Salary-structure components (fixed or % of base).
    v_s_earn := 0; v_s_benefits := 0; v_s_deductions := 0; v_s_components := '[]'::jsonb;
    IF v_emp.salary_structure_id IS NOT NULL THEN
      SELECT
        COALESCE(SUM(CASE WHEN component_type IN ('salary','bonus','overtime') AND taxable THEN amt ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN component_type='benefit' THEN amt ELSE 0 END),0),
        COALESCE(SUM(CASE WHEN component_type='deduction' THEN amt ELSE 0 END),0),
        COALESCE(jsonb_agg(jsonb_build_object('type',component_type,'label',label,'amount_cents',amt,'taxable',taxable,'source','structure')),'[]'::jsonb)
      INTO v_s_earn, v_s_benefits, v_s_deductions, v_s_components
      FROM (
        SELECT component_type, label, taxable,
               CASE WHEN pct_of_base IS NOT NULL THEN ROUND(v_base * pct_of_base / 100.0)::bigint
                    ELSE amount_cents END AS amt
        FROM public.salary_structure_components sc
        JOIN public.salary_structures s ON s.id = sc.structure_id AND s.active
        WHERE sc.structure_id = v_emp.salary_structure_id
      ) sx;
    END IF;

    v_gross := COALESCE(v_base,0) + COALESCE(v_earn,0) + COALESCE(v_s_earn,0);
    v_benefits := COALESCE(v_benefits,0) + COALESCE(v_s_benefits,0);
    v_deductions := COALESCE(v_deductions,0) + COALESCE(v_s_deductions,0);
    v_components := COALESCE(v_components,'[]'::jsonb) || COALESCE(v_s_components,'[]'::jsonb);
    v_taxable := v_gross + v_benefits - v_deductions;
    v_tax := ROUND(v_taxable * v_emp.tax_pct / 100.0);
    v_social := ROUND(v_taxable * v_social_pct / 100.0);
    v_net := v_taxable - v_tax;

    -- Open salary advances are deducted from net (post-tax) and settled on approve.
    SELECT COALESCE(SUM(amount_cents),0) INTO v_adv
    FROM public.salary_advances WHERE employee_id = v_emp.id AND status = 'open';
    IF v_adv > 0 AND v_adv <= v_net THEN
      v_net := v_net - v_adv;
      v_components := v_components || jsonb_build_array(jsonb_build_object(
        'type','advance_repayment','label','Löneförskott avdrag','amount_cents',v_adv,'taxable',false));
      UPDATE public.salary_advances SET status='repaying', repayment_run_id=v_run_id, updated_at=now()
      WHERE employee_id = v_emp.id AND status = 'open';
    ELSE
      IF v_adv > 0 THEN v_adv_skipped := v_adv_skipped + v_adv; END IF;
      v_adv := 0;
    END IF;

    INSERT INTO public.payroll_lines (run_id, employee_id, gross_cents, benefits_cents, deductions_cents,
      taxable_cents, tax_cents, social_fee_cents, net_cents, components, advance_deduction_cents)
    VALUES (v_run_id, v_emp.id, v_gross, v_benefits, v_deductions, v_taxable, v_tax, v_social, v_net,
      v_components, v_adv);
    v_total_gross := v_total_gross + v_gross; v_total_tax := v_total_tax + v_tax;
    v_total_social := v_total_social + v_social; v_total_net := v_total_net + v_net;
    v_total_adv := v_total_adv + v_adv;
    v_lines := v_lines + 1;
  END LOOP;
  UPDATE public.payroll_runs
    SET total_gross_cents=v_total_gross, total_tax_cents=v_total_tax,
        total_social_fee_cents=v_total_social, total_net_cents=v_total_net,
        total_advances_cents=v_total_adv
  WHERE id = v_run_id;
  RETURN jsonb_build_object('success',true,'run_id',v_run_id,'lines',v_lines,
    'total_gross_cents',v_total_gross,'total_tax_cents',v_total_tax,
    'total_social_fee_cents',v_total_social,'total_net_cents',v_total_net,
    'total_advances_deducted_cents',v_total_adv,
    'advances_skipped_cents',v_adv_skipped);
END; $function$;

-- ── 6. Approve v2: settle advance receivable (Cr 1610) ───────────────────────
CREATE OR REPLACE FUNCTION public.approve_payroll_run(p_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_run public.payroll_runs%ROWTYPE;
  v_je_id UUID;
  v_pension_total BIGINT;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin')) THEN
    RAISE EXCEPTION 'Only admins can approve payroll';
  END IF;

  SELECT * INTO v_run FROM public.payroll_runs WHERE id=p_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Run not found'; END IF;
  IF v_run.status <> 'draft' THEN RAISE EXCEPTION 'Run already %', v_run.status; END IF;

  INSERT INTO public.journal_entries (entry_date, description, status, source)
  VALUES (v_run.period_date, 'Payroll run '||to_char(v_run.period_date,'YYYY-MM'), 'posted', 'payroll')
  RETURNING id INTO v_je_id;

  IF v_run.total_gross_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '7210', v_run.total_gross_cents, 0, 'Löner tjänstemän');
  END IF;
  IF v_run.total_social_fee_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '7510', v_run.total_social_fee_cents, 0, 'Arbetsgivaravgifter');
  END IF;
  IF COALESCE(v_run.total_pension_employer_cents,0) > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '7410', v_run.total_pension_employer_cents, 0, 'Pensionsförsäkringspremier');
  END IF;
  IF v_run.total_tax_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '2710', 0, v_run.total_tax_cents, 'Personalens källskatt');
  END IF;
  IF v_run.total_social_fee_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '2731', 0, v_run.total_social_fee_cents, 'Avräkning lagstadgade sociala avgifter');
  END IF;
  v_pension_total := COALESCE(v_run.total_pension_employer_cents,0) + COALESCE(v_run.total_pension_employee_cents,0);
  IF v_pension_total > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '2950', 0, v_pension_total, 'Upplupna pensionskostnader');
  END IF;
  IF COALESCE(v_run.total_advances_cents,0) > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '1610', 0, v_run.total_advances_cents, 'Avräkning löneförskott');
  END IF;
  IF v_run.total_net_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '2890', 0, v_run.total_net_cents, 'Nettolöneskuld');
  END IF;

  UPDATE public.salary_advances SET status='repaid', repaid_at=now(), updated_at=now()
  WHERE repayment_run_id = p_run_id AND status = 'repaying';

  UPDATE public.payroll_runs
    SET status='approved', approved_at=now(), approval_journal_id=v_je_id
  WHERE id=p_run_id;

  RETURN jsonb_build_object('success',true,'run_id',p_run_id,'journal_entry_id',v_je_id,
    'pension_posted_cents',v_pension_total,
    'advances_settled_cents',COALESCE(v_run.total_advances_cents,0));
END; $function$;

-- ── 7. Sick pay v2: respects advance deduction + country social pct ─────────
CREATE OR REPLACE FUNCTION public.apply_sick_pay(
  p_run_id uuid, p_employee_id uuid, p_sick_days integer, p_work_days_per_month integer DEFAULT 21
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_status text;
  v_line public.payroll_lines%ROWTYPE;
  v_monthly bigint; v_tax_pct numeric; v_social_pct numeric;
  v_calc jsonb; v_sick bigint; v_daily numeric; v_deduction bigint;
  v_base_gross bigint; v_base_taxable bigint;
  v_gross bigint; v_taxable bigint; v_tax bigint; v_social bigint; v_net bigint;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin')) THEN
    RAISE EXCEPTION 'Only admins can apply sick pay';
  END IF;
  IF p_sick_days IS NULL OR p_sick_days < 0 THEN
    RAISE EXCEPTION 'sick_days must be >= 0';
  END IF;
  IF COALESCE(p_work_days_per_month, 0) <= 0 THEN
    RAISE EXCEPTION 'work_days_per_month must be > 0';
  END IF;

  SELECT status INTO v_status FROM payroll_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payroll run % not found', p_run_id; END IF;
  IF v_status <> 'draft' THEN
    RAISE EXCEPTION 'Run % is % — sick pay can only be applied to a draft', p_run_id, v_status;
  END IF;

  SELECT * INTO v_line FROM payroll_lines
   WHERE run_id = p_run_id AND employee_id = p_employee_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No payroll line for employee % on run %', p_employee_id, p_run_id;
  END IF;

  SELECT COALESCE(e.monthly_salary_cents,0), COALESCE(e.tax_rate_pct,30.00),
         COALESCE(p.employer_social_pct, 31.42)
    INTO v_monthly, v_tax_pct, v_social_pct
    FROM employees e
    LEFT JOIN payroll_country_profiles p ON p.country_code = COALESCE(e.payroll_country,'SE')
    WHERE e.id = p_employee_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee % not found', p_employee_id; END IF;

  v_base_gross   := v_line.gross_cents   + v_line.sick_deduction_cents - v_line.sick_pay_cents;
  v_base_taxable := v_line.taxable_cents + v_line.sick_deduction_cents - v_line.sick_pay_cents;

  v_daily := v_monthly::numeric / p_work_days_per_month;
  v_deduction := LEAST(ROUND(v_daily * p_sick_days)::bigint, v_base_gross);
  v_calc := public.calc_sick_pay(v_monthly, p_sick_days, p_work_days_per_month);
  v_sick := COALESCE((v_calc->>'sick_pay_cents')::bigint, 0);

  v_gross   := v_base_gross   - v_deduction + v_sick;
  v_taxable := v_base_taxable - v_deduction + v_sick;
  v_tax     := ROUND(v_taxable * v_tax_pct / 100.0)::bigint + v_line.tax_correction_cents;
  v_social  := ROUND(v_taxable * v_social_pct / 100.0)::bigint;
  v_net     := v_taxable - v_tax - v_line.pension_employee_cents - v_line.advance_deduction_cents;

  UPDATE payroll_lines SET
    gross_cents = v_gross, taxable_cents = v_taxable, tax_cents = v_tax,
    social_fee_cents = v_social, net_cents = v_net,
    sick_days = p_sick_days, sick_deduction_cents = v_deduction, sick_pay_cents = v_sick
  WHERE id = v_line.id;

  UPDATE payroll_runs SET
    total_gross_cents      = (SELECT COALESCE(SUM(gross_cents),0)      FROM payroll_lines WHERE run_id = p_run_id),
    total_tax_cents        = (SELECT COALESCE(SUM(tax_cents),0)        FROM payroll_lines WHERE run_id = p_run_id),
    total_social_fee_cents = (SELECT COALESCE(SUM(social_fee_cents),0) FROM payroll_lines WHERE run_id = p_run_id),
    total_net_cents        = (SELECT COALESCE(SUM(net_cents),0)        FROM payroll_lines WHERE run_id = p_run_id)
  WHERE id = p_run_id;

  RETURN jsonb_build_object('success', true, 'run_id', p_run_id, 'employee_id', p_employee_id,
    'sick_days', p_sick_days,
    'salary_deduction_cents', v_deduction,
    'sick_pay_cents', v_sick,
    'karensavdrag_cents', COALESCE((v_calc->>'karensavdrag_cents')::bigint, 0),
    'paid_sick_days', COALESCE((v_calc->>'paid_sick_days')::int, 0),
    'new_gross_cents', v_gross, 'new_tax_cents', v_tax, 'new_net_cents', v_net,
    'note', CASE WHEN v_line.pension_employer_cents > 0 OR v_line.pension_employee_cents > 0
                 THEN 'Pension amounts were computed on the previous gross — re-run apply_pension to refresh them.'
                 ELSE NULL END);
END; $function$;

-- ── 8. Tax corrections on draft runs ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.apply_tax_correction(
  p_run_id uuid,
  p_employee_id uuid,
  p_tax_delta_cents bigint,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_status text;
  v_line public.payroll_lines%ROWTYPE;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can apply tax corrections';
  END IF;
  IF p_tax_delta_cents IS NULL OR p_tax_delta_cents = 0 THEN
    RAISE EXCEPTION 'p_tax_delta_cents must be non-zero (positive = withhold more, negative = refund)';
  END IF;
  SELECT status INTO v_status FROM public.payroll_runs WHERE id = p_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payroll run % not found', p_run_id; END IF;
  IF v_status <> 'draft' THEN
    RAISE EXCEPTION 'Run % is % — tax corrections can only be applied to a draft. For a posted run, correct on the next month''s run.', p_run_id, v_status;
  END IF;
  SELECT * INTO v_line FROM public.payroll_lines
  WHERE run_id = p_run_id AND employee_id = p_employee_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No payroll line for employee % on run %', p_employee_id, p_run_id; END IF;

  UPDATE public.payroll_lines SET
    tax_cents = tax_cents + p_tax_delta_cents,
    net_cents = net_cents - p_tax_delta_cents,
    tax_correction_cents = tax_correction_cents + p_tax_delta_cents,
    components = components || jsonb_build_array(jsonb_build_object(
      'type','tax_correction','label',COALESCE(p_reason,'Tax correction'),
      'amount_cents',p_tax_delta_cents,'taxable',false))
  WHERE id = v_line.id;

  UPDATE public.payroll_runs SET
    total_tax_cents = (SELECT COALESCE(SUM(tax_cents),0) FROM public.payroll_lines WHERE run_id = p_run_id),
    total_net_cents = (SELECT COALESCE(SUM(net_cents),0) FROM public.payroll_lines WHERE run_id = p_run_id)
  WHERE id = p_run_id;

  RETURN jsonb_build_object('success', true, 'run_id', p_run_id, 'employee_id', p_employee_id,
    'tax_delta_cents', p_tax_delta_cents,
    'cumulative_correction_cents', v_line.tax_correction_cents + p_tax_delta_cents,
    'note', 'Corrections are cumulative — each call adds its delta.');
END;
$$;

-- ── 9. Payslips (admin + employee self-service) ──────────────────────────────
CREATE OR REPLACE FUNCTION public.get_payslip(
  p_run_id uuid DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_admin boolean;
  v_emp public.employees%ROWTYPE;
  v_line public.payroll_lines%ROWTYPE;
  v_run public.payroll_runs%ROWTYPE;
  v_rows jsonb;
  v_ytd jsonb;
  v_employer text;
  v_social_pct numeric;
BEGIN
  v_admin := auth.role() = 'service_role' OR has_role(auth.uid(),'admin');

  IF NOT v_admin THEN
    SELECT * INTO v_emp FROM public.employees WHERE user_id = auth.uid() LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'No employee record linked to your account'; END IF;
    IF p_employee_id IS NOT NULL AND p_employee_id <> v_emp.id THEN
      RAISE EXCEPTION 'You can only view your own payslips';
    END IF;
    p_employee_id := v_emp.id;
  ELSE
    IF p_employee_id IS NULL THEN
      RAISE EXCEPTION 'p_employee_id is required (admins must pick an employee)';
    END IF;
    SELECT * INTO v_emp FROM public.employees WHERE id = p_employee_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Employee % not found', p_employee_id; END IF;
  END IF;

  -- No run: list available payslips for the employee.
  IF p_run_id IS NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'run_id', r.id, 'period', to_char(r.period_date,'YYYY-MM'), 'status', r.status,
      'gross_cents', l.gross_cents, 'net_cents', l.net_cents)
      ORDER BY r.period_date DESC), '[]'::jsonb)
    INTO v_rows
    FROM public.payroll_lines l
    JOIN public.payroll_runs r ON r.id = l.run_id
    WHERE l.employee_id = p_employee_id
      AND (v_admin OR r.status IN ('approved','paid'));
    RETURN jsonb_build_object('success', true, 'employee_id', p_employee_id,
      'employee_name', v_emp.name, 'payslips', v_rows);
  END IF;

  SELECT * INTO v_run FROM public.payroll_runs WHERE id = p_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payroll run % not found', p_run_id; END IF;
  IF NOT v_admin AND v_run.status NOT IN ('approved','paid') THEN
    RAISE EXCEPTION 'Payslip not available until the run is approved';
  END IF;
  SELECT * INTO v_line FROM public.payroll_lines
  WHERE run_id = p_run_id AND employee_id = p_employee_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'No payroll line for this employee on run %', p_run_id; END IF;

  SELECT NULLIF(trim(both '"' from value::text), '') INTO v_employer
  FROM public.site_settings WHERE key = 'site_name' LIMIT 1;
  SELECT employer_social_pct INTO v_social_pct
  FROM public.payroll_country_profiles WHERE country_code = COALESCE(v_emp.payroll_country,'SE');

  SELECT jsonb_build_object(
    'gross_cents', COALESCE(SUM(l.gross_cents),0),
    'taxable_cents', COALESCE(SUM(l.taxable_cents),0),
    'tax_cents', COALESCE(SUM(l.tax_cents),0),
    'net_cents', COALESCE(SUM(l.net_cents),0),
    'pension_employee_cents', COALESCE(SUM(l.pension_employee_cents),0),
    'months', COUNT(*))
  INTO v_ytd
  FROM public.payroll_lines l
  JOIN public.payroll_runs r ON r.id = l.run_id
  WHERE l.employee_id = p_employee_id
    AND r.status IN ('approved','paid')
    AND date_trunc('year', r.period_date) = date_trunc('year', v_run.period_date)
    AND r.period_date <= v_run.period_date;

  RETURN jsonb_build_object('success', true,
    'employer', jsonb_build_object('name', COALESCE(v_employer, 'FlowWink')),
    'employee', jsonb_build_object('id', v_emp.id, 'name', v_emp.name, 'email', v_emp.email,
      'title', v_emp.title, 'department', v_emp.department,
      'payroll_country', COALESCE(v_emp.payroll_country,'SE')),
    'period', to_char(v_run.period_date,'YYYY-MM'),
    'run_id', v_run.id,
    'status', v_run.status,
    'components', v_line.components,
    'amounts', jsonb_build_object(
      'gross_cents', v_line.gross_cents,
      'benefits_cents', v_line.benefits_cents,
      'deductions_cents', v_line.deductions_cents,
      'taxable_cents', v_line.taxable_cents,
      'tax_cents', v_line.tax_cents,
      'tax_correction_cents', v_line.tax_correction_cents,
      'social_fee_cents', v_line.social_fee_cents,
      'employer_social_pct', COALESCE(v_social_pct, 31.42),
      'pension_employer_cents', v_line.pension_employer_cents,
      'pension_employee_cents', v_line.pension_employee_cents,
      'sick_days', v_line.sick_days,
      'sick_deduction_cents', v_line.sick_deduction_cents,
      'sick_pay_cents', v_line.sick_pay_cents,
      'advance_deduction_cents', v_line.advance_deduction_cents,
      'net_cents', v_line.net_cents),
    'ytd', v_ytd);
END;
$$;

-- ── 10. Year-end certification summary (KU-style) ────────────────────────────
CREATE OR REPLACE FUNCTION public.year_end_payroll_summary(
  p_year integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_year integer := COALESCE(p_year, EXTRACT(YEAR FROM CURRENT_DATE)::integer);
  v_rows jsonb;
  v_totals jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can generate year-end summaries';
  END IF;

  SELECT COALESCE(jsonb_agg(e ORDER BY e.employee_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT emp.name AS employee_name, emp.id AS employee_id,
           emp.personal_number,
           COALESCE(emp.payroll_country,'SE') AS payroll_country,
           COUNT(*) AS months,
           SUM(l.gross_cents) AS gross_cents,
           SUM(l.benefits_cents) AS benefits_cents,
           SUM(l.taxable_cents) AS taxable_cents,
           SUM(l.tax_cents) AS tax_withheld_cents,
           SUM(l.social_fee_cents) AS employer_social_cents,
           SUM(l.pension_employer_cents) AS pension_employer_cents,
           SUM(l.pension_employee_cents) AS pension_employee_cents,
           SUM(l.net_cents) AS net_cents
    FROM public.payroll_lines l
    JOIN public.payroll_runs r ON r.id = l.run_id
    JOIN public.employees emp ON emp.id = l.employee_id
    WHERE r.status IN ('approved','paid')
      AND EXTRACT(YEAR FROM r.period_date)::integer = v_year
    GROUP BY emp.id, emp.name, emp.personal_number, emp.payroll_country
  ) e;

  SELECT jsonb_build_object(
    'gross_cents', COALESCE(SUM(l.gross_cents),0),
    'tax_withheld_cents', COALESCE(SUM(l.tax_cents),0),
    'employer_social_cents', COALESCE(SUM(l.social_fee_cents),0),
    'net_cents', COALESCE(SUM(l.net_cents),0))
  INTO v_totals
  FROM public.payroll_lines l
  JOIN public.payroll_runs r ON r.id = l.run_id
  WHERE r.status IN ('approved','paid')
    AND EXTRACT(YEAR FROM r.period_date)::integer = v_year;

  RETURN jsonb_build_object('success', true, 'year', v_year,
    'employees', v_rows, 'totals', v_totals,
    'note', 'Per-employee annual gross and withheld tax — the data set for kontrolluppgifter/income statements. Monthly AGI (generate_agi) is the primary Skatteverket reporting channel since 2019.');
END;
$$;

-- ── 11. Tax-authority integration: AGI XML export ────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_agi(
  p_period date DEFAULT CURRENT_DATE
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_month date := date_trunc('month', p_period)::date;
  v_period text := to_char(date_trunc('month', p_period), 'YYYYMM');
  v_org text;
  v_xml text;
  v_iu text := '';
  v_row record;
  v_count integer := 0;
  v_gross bigint := 0;
  v_tax bigint := 0;
  v_social bigint := 0;
  v_idx integer := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can generate AGI declarations';
  END IF;

  SELECT NULLIF(trim(both '"' from value::text), '') INTO v_org
  FROM public.site_settings WHERE key = 'org_number' LIMIT 1;

  FOR v_row IN
    SELECT emp.name, emp.personal_number,
           SUM(l.gross_cents) AS gross_cents,
           SUM(l.tax_cents) AS tax_cents,
           SUM(l.social_fee_cents) AS social_cents
    FROM public.payroll_lines l
    JOIN public.payroll_runs r ON r.id = l.run_id
    JOIN public.employees emp ON emp.id = l.employee_id
    WHERE r.period_date = v_month AND r.status IN ('approved','paid')
    GROUP BY emp.id, emp.name, emp.personal_number
    ORDER BY emp.name
  LOOP
    v_idx := v_idx + 1;
    v_count := v_count + 1;
    v_gross := v_gross + v_row.gross_cents;
    v_tax := v_tax + v_row.tax_cents;
    v_social := v_social + v_row.social_cents;
    v_iu := v_iu || format(
      E'    <agd:IU>\n'
      || E'      <agd:RedovisningsPeriod faltkod="006">%s</agd:RedovisningsPeriod>\n'
      || E'      <agd:Specifikationsnummer faltkod="570">%s</agd:Specifikationsnummer>\n'
      || E'      <agd:BetalningsmottagareId faltkod="215">%s</agd:BetalningsmottagareId>\n'
      || E'      <agd:KontantErsattningUlagAG faltkod="011">%s</agd:KontantErsattningUlagAG>\n'
      || E'      <agd:AvdrPrelSkatt faltkod="001">%s</agd:AvdrPrelSkatt>\n'
      || E'    </agd:IU>\n',
      v_period, v_idx, COALESCE(v_row.personal_number, 'SAKNAS'),
      ROUND(v_row.gross_cents / 100.0), ROUND(v_row.tax_cents / 100.0));
  END LOOP;

  IF v_count = 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_data',
      'message', 'No approved/paid payroll run for ' || to_char(v_month,'YYYY-MM')
        || ' — approve the run before generating the AGI declaration.');
  END IF;

  v_xml :=
    E'<?xml version="1.0" encoding="UTF-8"?>\n'
    || E'<Skatteverket omrade="Arbetsgivardeklaration" xmlns="http://xmls.skatteverket.se/se/skatteverket/da/instans/schema/1.1"\n'
    || E'  xmlns:agd="http://xmls.skatteverket.se/se/skatteverket/da/komponent/schema/1.1">\n'
    || E'  <agd:Avsandare><agd:Programnamn>FlowWink Payroll</agd:Programnamn><agd:Organisationsnummer>' || COALESCE(v_org,'SAKNAS') || E'</agd:Organisationsnummer></agd:Avsandare>\n'
    || E'  <agd:Blankettgemensamt><agd:Arbetsgivare><agd:AgRegistreradId>' || COALESCE(v_org,'SAKNAS') || E'</agd:AgRegistreradId></agd:Arbetsgivare></agd:Blankettgemensamt>\n'
    || E'  <agd:Blankett>\n'
    || E'    <agd:HU>\n'
    || E'      <agd:RedovisningsPeriod faltkod="006">' || v_period || E'</agd:RedovisningsPeriod>\n'
    || E'      <agd:SummaArbAvgSlf faltkod="487">' || ROUND(v_social / 100.0) || E'</agd:SummaArbAvgSlf>\n'
    || E'      <agd:SummaSkatteavdr faltkod="497">' || ROUND(v_tax / 100.0) || E'</agd:SummaSkatteavdr>\n'
    || E'    </agd:HU>\n'
    || v_iu
    || E'  </agd:Blankett>\n'
    || E'</Skatteverket>\n';

  RETURN jsonb_build_object('success', true,
    'period', to_char(v_month,'YYYY-MM'),
    'employees', v_count,
    'totals', jsonb_build_object('gross_cents', v_gross, 'tax_cents', v_tax, 'employer_social_cents', v_social),
    'xml', v_xml,
    'note', 'Simplified AGI (arbetsgivardeklaration på individnivå) XML — upload to Skatteverket''s file transfer service. Set site_settings key org_number for a complete file.');
END;
$$;
