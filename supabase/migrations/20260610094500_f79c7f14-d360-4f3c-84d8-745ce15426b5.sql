-- Fix the schema-drift bug class in the accounting/payroll posting RPCs, found
-- while simulating a year of bookkeeping. The journal schema evolved
-- (journal_entries.source replaced source_type/source_id; journal_entry_lines
-- uses journal_entry_id + a NOT NULL account_name; expense_reports has no
-- paid_at) but several posting functions were never updated, so they aborted at
-- runtime — payroll approval/payment and expense payment never reached the books.
--
-- 1. Systemic safety net: auto-fill journal_entry_lines.account_name from the
--    chart of accounts when a caller omits it (it is a denormalised copy).
-- 2. approve_payroll_run / mark_payroll_paid: journal_entries(... source_type,
--    source_id) -> (... source).
-- 3. mark_expense_report_paid: drop source_id, entry_id -> journal_entry_id,
--    drop the non-existent expense_reports.paid_at.

CREATE OR REPLACE FUNCTION public.fill_journal_line_account_name()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.account_name IS NULL OR NEW.account_name = '' THEN
    SELECT account_name INTO NEW.account_name
      FROM public.chart_of_accounts WHERE account_code = NEW.account_code;
    IF NEW.account_name IS NULL THEN NEW.account_name := NEW.account_code; END IF;
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_fill_journal_line_account_name ON public.journal_entry_lines;
CREATE TRIGGER trg_fill_journal_line_account_name
  BEFORE INSERT ON public.journal_entry_lines
  FOR EACH ROW EXECUTE FUNCTION public.fill_journal_line_account_name();

CREATE OR REPLACE FUNCTION public.approve_payroll_run(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_run public.payroll_runs%ROWTYPE;
  v_je_id UUID;
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN
    RAISE EXCEPTION 'Only admins can approve payroll';
  END IF;

  SELECT * INTO v_run FROM public.payroll_runs WHERE id=p_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Run not found'; END IF;
  IF v_run.status <> 'draft' THEN RAISE EXCEPTION 'Run already %', v_run.status; END IF;

  INSERT INTO public.journal_entries (entry_date, description, status, source)
  VALUES (v_run.period_date, 'Payroll run '||to_char(v_run.period_date,'YYYY-MM'), 'posted', 'payroll')
  RETURNING id INTO v_je_id;

  -- Dt 7210 (lön)
  IF v_run.total_gross_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '7210', v_run.total_gross_cents, 0, 'Löner tjänstemän');
  END IF;
  -- Dt 7510 (arb.giv.avg)
  IF v_run.total_social_fee_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '7510', v_run.total_social_fee_cents, 0, 'Arbetsgivaravgifter');
  END IF;
  -- Cr 2710 (personalskatt)
  IF v_run.total_tax_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '2710', 0, v_run.total_tax_cents, 'Personalens källskatt');
  END IF;
  -- Cr 2731 (arb.giv.avg skuld)
  IF v_run.total_social_fee_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '2731', 0, v_run.total_social_fee_cents, 'Avräkning lagstadgade sociala avgifter');
  END IF;
  -- Cr 2710 (nettolöneskuld) - using 2710 sub or 2890
  IF v_run.total_net_cents > 0 THEN
    INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
    VALUES (v_je_id, '2890', 0, v_run.total_net_cents, 'Nettolöneskuld');
  END IF;

  UPDATE public.payroll_runs
    SET status='approved', approved_at=now(), approval_journal_id=v_je_id
  WHERE id=p_run_id;

  RETURN jsonb_build_object('success',true,'run_id',p_run_id,'journal_entry_id',v_je_id);
END; $function$

;

CREATE OR REPLACE FUNCTION public.mark_payroll_paid(p_run_id uuid, p_payment_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_run public.payroll_runs%ROWTYPE;
  v_je_id UUID;
  v_date DATE;
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN
    RAISE EXCEPTION 'Only admins can mark payroll paid';
  END IF;
  SELECT * INTO v_run FROM public.payroll_runs WHERE id=p_run_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Run not found'; END IF;
  IF v_run.status <> 'approved' THEN RAISE EXCEPTION 'Run must be approved first'; END IF;

  v_date := COALESCE(p_payment_date, CURRENT_DATE);

  INSERT INTO public.journal_entries (entry_date, description, status, source)
  VALUES (v_date, 'Payroll payment '||to_char(v_run.period_date,'YYYY-MM'), 'posted', 'payroll_payment')
  RETURNING id INTO v_je_id;

  INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
  VALUES (v_je_id, '2890', v_run.total_net_cents, 0, 'Utbetald nettolön'),
         (v_je_id, '1930', 0, v_run.total_net_cents, 'Bank');

  UPDATE public.payroll_runs SET status='paid', paid_at=now(), payment_journal_id=v_je_id WHERE id=p_run_id;

  RETURN jsonb_build_object('success',true,'run_id',p_run_id,'journal_entry_id',v_je_id);
END; $function$

;

CREATE OR REPLACE FUNCTION public.mark_expense_report_paid(p_report_id uuid, p_method text DEFAULT 'manual'::text, p_reference text DEFAULT NULL::text, p_paid_at date DEFAULT NULL::date, p_bank_account text DEFAULT '1930'::text, p_liability_account text DEFAULT '2890'::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_report record;
  v_total_cents bigint;
  v_entry_id uuid;
  v_payment_id uuid;
  v_date date;
BEGIN
  SELECT * INTO v_report FROM expense_reports WHERE id = p_report_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Report not found');
  END IF;
  IF v_report.status <> 'booked' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only booked reports can be marked paid');
  END IF;

  SELECT COALESCE(SUM(amount_cents),0) INTO v_total_cents
  FROM expenses WHERE report_id = p_report_id;

  v_date := COALESCE(p_paid_at, CURRENT_DATE);

  INSERT INTO journal_entries (entry_date, description, source, status)
  VALUES (v_date, 'Payment of expense report ' || p_report_id::text, 'expense_payment', 'posted')
  RETURNING id INTO v_entry_id;

  INSERT INTO journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
  VALUES
    (v_entry_id, p_liability_account, v_total_cents, 0, 'Settle liability'),
    (v_entry_id, p_bank_account, 0, v_total_cents, 'Bank payment');

  INSERT INTO expense_payments (report_id, amount_cents, method, reference, paid_at, journal_entry_id, notes)
  VALUES (p_report_id, v_total_cents, p_method::text, p_reference, v_date, v_entry_id, p_notes)
  RETURNING id INTO v_payment_id;

  UPDATE expense_reports
  SET status = 'paid'
  WHERE id = p_report_id;

  RETURN jsonb_build_object('success', true, 'report_id', p_report_id, 'payment_id', v_payment_id, 'journal_entry_id', v_entry_id);
END;
$function$

;

