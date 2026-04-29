-- Migrate expense RPCs from _arg → p_arg convention so agent-execute mapRpcArgs() can reach them.
-- agent-execute strips underscore-prefixed args (treats them as agent-internal) and prefixes
-- remaining args with p_, which broke calls to these functions.
-- Drop old signatures and recreate with p_-prefixed parameters.

DROP FUNCTION IF EXISTS public.submit_expense_report(uuid);
DROP FUNCTION IF EXISTS public.approve_expense_report(uuid);
DROP FUNCTION IF EXISTS public.book_expense_report(uuid, text, text, text, date);
DROP FUNCTION IF EXISTS public.mark_expense_report_paid(uuid, text, text, date, text, text, text);

-- 1) submit_expense_report
CREATE OR REPLACE FUNCTION public.submit_expense_report(p_report_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_report record;
BEGIN
  SELECT * INTO v_report FROM expense_reports WHERE id = p_report_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Report not found');
  END IF;
  IF v_report.status <> 'draft' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only draft reports can be submitted');
  END IF;

  UPDATE expense_reports
  SET status = 'submitted', submitted_at = now()
  WHERE id = p_report_id;

  RETURN jsonb_build_object('success', true, 'report_id', p_report_id, 'status', 'submitted');
END;
$$;

-- 2) approve_expense_report
CREATE OR REPLACE FUNCTION public.approve_expense_report(p_report_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_report record;
BEGIN
  SELECT * INTO v_report FROM expense_reports WHERE id = p_report_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Report not found');
  END IF;
  IF v_report.status <> 'submitted' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only submitted reports can be approved');
  END IF;

  UPDATE expense_reports
  SET status = 'approved', approved_at = now(), approved_by = auth.uid()
  WHERE id = p_report_id;

  RETURN jsonb_build_object('success', true, 'report_id', p_report_id, 'status', 'approved');
END;
$$;

-- 3) book_expense_report
CREATE OR REPLACE FUNCTION public.book_expense_report(
  p_report_id uuid,
  p_expense_account text DEFAULT '5410',
  p_vat_account text DEFAULT '2641',
  p_liability_account text DEFAULT '2890',
  p_entry_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_report record;
  v_total_cents bigint;
  v_vat_cents bigint;
  v_net_cents bigint;
  v_entry_id uuid;
  v_date date;
BEGIN
  SELECT * INTO v_report FROM expense_reports WHERE id = p_report_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Report not found');
  END IF;
  IF v_report.status <> 'approved' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only approved reports can be booked');
  END IF;

  SELECT COALESCE(SUM(amount_cents),0), COALESCE(SUM(vat_cents),0)
  INTO v_total_cents, v_vat_cents
  FROM expenses WHERE report_id = p_report_id;

  v_net_cents := v_total_cents - v_vat_cents;
  v_date := COALESCE(p_entry_date, CURRENT_DATE);

  INSERT INTO journal_entries (entry_date, description, source, source_id, status)
  VALUES (v_date, 'Expense report ' || p_report_id::text, 'expense_report', p_report_id, 'posted')
  RETURNING id INTO v_entry_id;

  INSERT INTO journal_entry_lines (entry_id, account_code, debit_cents, credit_cents, description)
  VALUES
    (v_entry_id, p_expense_account, v_net_cents, 0, 'Expense (net)'),
    (v_entry_id, p_vat_account, v_vat_cents, 0, 'Input VAT'),
    (v_entry_id, p_liability_account, 0, v_total_cents, 'Liability to employee');

  UPDATE expense_reports
  SET status = 'booked', booked_at = now(), journal_entry_id = v_entry_id
  WHERE id = p_report_id;

  RETURN jsonb_build_object('success', true, 'report_id', p_report_id, 'journal_entry_id', v_entry_id, 'total_cents', v_total_cents);
END;
$$;

-- 4) mark_expense_report_paid
CREATE OR REPLACE FUNCTION public.mark_expense_report_paid(
  p_report_id uuid,
  p_method text DEFAULT 'manual',
  p_reference text DEFAULT NULL,
  p_paid_at date DEFAULT NULL,
  p_bank_account text DEFAULT '1930',
  p_liability_account text DEFAULT '2890',
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  INSERT INTO journal_entries (entry_date, description, source, source_id, status)
  VALUES (v_date, 'Payment of expense report ' || p_report_id::text, 'expense_payment', p_report_id, 'posted')
  RETURNING id INTO v_entry_id;

  INSERT INTO journal_entry_lines (entry_id, account_code, debit_cents, credit_cents, description)
  VALUES
    (v_entry_id, p_liability_account, v_total_cents, 0, 'Settle liability'),
    (v_entry_id, p_bank_account, 0, v_total_cents, 'Bank payment');

  INSERT INTO expense_payments (report_id, amount_cents, method, reference, paid_at, journal_entry_id, notes)
  VALUES (p_report_id, v_total_cents, p_method::text, p_reference, v_date, v_entry_id, p_notes)
  RETURNING id INTO v_payment_id;

  UPDATE expense_reports
  SET status = 'paid', paid_at = v_date
  WHERE id = p_report_id;

  RETURN jsonb_build_object('success', true, 'report_id', p_report_id, 'payment_id', v_payment_id, 'journal_entry_id', v_entry_id);
END;
$$;