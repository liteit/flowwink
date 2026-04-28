-- ============================================================
-- 1. Allow new statuses
-- ============================================================
ALTER TABLE public.expense_reports DROP CONSTRAINT IF EXISTS expense_reports_status_check;
ALTER TABLE public.expense_reports ADD CONSTRAINT expense_reports_status_check
  CHECK (status = ANY (ARRAY['draft','submitted','approved','rejected','booked','paid']));

ALTER TABLE public.expenses DROP CONSTRAINT IF EXISTS expenses_status_check;
ALTER TABLE public.expenses ADD CONSTRAINT expenses_status_check
  CHECK (status = ANY (ARRAY['draft','submitted','approved','rejected','booked','paid']));

-- ============================================================
-- 2. expense_payments table (one row per payout)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.expense_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id uuid NOT NULL REFERENCES public.expense_reports(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  paid_at date NOT NULL DEFAULT CURRENT_DATE,
  amount_cents bigint NOT NULL,
  currency text NOT NULL DEFAULT 'SEK',
  method text NOT NULL DEFAULT 'manual'
    CHECK (method = ANY (ARRAY['manual','sepa','swish','bankgiro','stripe','other'])),
  reference text,
  notes text,
  journal_entry_id uuid REFERENCES public.journal_entries(id),
  recorded_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_expense_payments_report ON public.expense_payments(report_id);
CREATE INDEX IF NOT EXISTS idx_expense_payments_user ON public.expense_payments(user_id);

ALTER TABLE public.expense_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Service role full access expense_payments" ON public.expense_payments;
CREATE POLICY "Service role full access expense_payments" ON public.expense_payments
  TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Users view own expense payments" ON public.expense_payments;
CREATE POLICY "Users view own expense payments" ON public.expense_payments
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Admins manage expense payments" ON public.expense_payments;
CREATE POLICY "Admins manage expense payments" ON public.expense_payments
  FOR ALL TO authenticated
  USING (has_role(auth.uid(), 'admin'))
  WITH CHECK (has_role(auth.uid(), 'admin'));

-- ============================================================
-- 3. Helper: ensure a manual journal exists
-- ============================================================
CREATE OR REPLACE FUNCTION public._ensure_manual_journal()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id FROM journals
   WHERE journal_type = 'manual' OR code = 'GEN'
   ORDER BY (journal_type = 'manual') DESC, created_at ASC
   LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO journals (code, name, journal_type, currency, sequence_prefix, is_active, description)
    VALUES ('GEN', 'General Journal', 'manual', 'SEK', 'V', true, 'Auto-created for expense bookings')
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

-- ============================================================
-- 4. book_expense_report
-- ============================================================
CREATE OR REPLACE FUNCTION public.book_expense_report(
  _report_id uuid,
  _expense_account text DEFAULT '5410',
  _vat_account text DEFAULT '2641',
  _liability_account text DEFAULT '2890',
  _entry_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
  v_user_id uuid;
  v_period text;
  v_currency text;
  v_total_cents bigint;
  v_vat_cents bigint;
  v_net_cents bigint;
  v_journal_id uuid;
  v_entry_id uuid;
  v_entry_date date;
BEGIN
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only admins can book expense reports';
  END IF;

  SELECT status, user_id, period, currency
    INTO v_status, v_user_id, v_period, v_currency
  FROM expense_reports WHERE id = _report_id;

  IF v_status IS NULL THEN RAISE EXCEPTION 'Report not found'; END IF;
  IF v_status <> 'approved' THEN
    RAISE EXCEPTION 'Only approved reports can be booked (current: %)', v_status;
  END IF;

  -- Aggregate amounts from attached expenses
  SELECT
    COALESCE(SUM(amount_cents + COALESCE(vat_cents, 0)), 0),
    COALESCE(SUM(COALESCE(vat_cents, 0)), 0),
    COALESCE(SUM(amount_cents), 0)
  INTO v_total_cents, v_vat_cents, v_net_cents
  FROM expenses WHERE report_id = _report_id;

  IF v_total_cents = 0 THEN
    RAISE EXCEPTION 'Cannot book a report with zero total';
  END IF;

  v_journal_id := _ensure_manual_journal();
  v_entry_date := COALESCE(_entry_date, CURRENT_DATE);

  -- Create journal entry
  INSERT INTO journal_entries (entry_date, description, reference_number, status, source, journal_id, created_by)
  VALUES (
    v_entry_date,
    'Expense report ' || v_period,
    'EXP-' || v_period || '-' || substr(_report_id::text, 1, 8),
    'posted',
    'expense_report',
    v_journal_id,
    auth.uid()
  )
  RETURNING id INTO v_entry_id;

  -- Debit: net expense
  INSERT INTO journal_entry_lines (journal_entry_id, account_code, account_name, debit_cents, credit_cents, description)
  VALUES (v_entry_id, _expense_account, 'Expense', v_net_cents, 0, 'Net expense');

  -- Debit: VAT (only if > 0)
  IF v_vat_cents > 0 THEN
    INSERT INTO journal_entry_lines (journal_entry_id, account_code, account_name, debit_cents, credit_cents, description)
    VALUES (v_entry_id, _vat_account, 'Input VAT', v_vat_cents, 0, 'Input VAT');
  END IF;

  -- Credit: liability to employee
  INSERT INTO journal_entry_lines (journal_entry_id, account_code, account_name, debit_cents, credit_cents, description)
  VALUES (v_entry_id, _liability_account, 'Owed to employee', 0, v_total_cents, 'Owed to employee');

  -- Update report
  UPDATE expense_reports
     SET status = 'booked',
         journal_entry_id = v_entry_id,
         updated_at = now()
   WHERE id = _report_id;

  -- Update expenses
  UPDATE expenses SET status = 'booked', updated_at = now()
   WHERE report_id = _report_id;

  RETURN jsonb_build_object(
    'ok', true,
    'report_id', _report_id,
    'status', 'booked',
    'journal_entry_id', v_entry_id,
    'net_cents', v_net_cents,
    'vat_cents', v_vat_cents,
    'total_cents', v_total_cents
  );
END;
$$;

-- ============================================================
-- 5. mark_expense_report_paid
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_expense_report_paid(
  _report_id uuid,
  _method text DEFAULT 'manual',
  _reference text DEFAULT NULL,
  _paid_at date DEFAULT NULL,
  _bank_account text DEFAULT '1930',
  _liability_account text DEFAULT '2890',
  _notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
  v_user_id uuid;
  v_period text;
  v_currency text;
  v_total_cents bigint;
  v_journal_id uuid;
  v_entry_id uuid;
  v_payment_id uuid;
  v_paid_at date;
BEGIN
  IF NOT has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only admins can record expense payments';
  END IF;

  SELECT status, user_id, period, currency, total_cents
    INTO v_status, v_user_id, v_period, v_currency, v_total_cents
  FROM expense_reports WHERE id = _report_id;

  IF v_status IS NULL THEN RAISE EXCEPTION 'Report not found'; END IF;
  IF v_status <> 'booked' THEN
    RAISE EXCEPTION 'Only booked reports can be marked as paid (current: %)', v_status;
  END IF;
  IF v_total_cents <= 0 THEN
    RAISE EXCEPTION 'Cannot pay a report with zero total';
  END IF;

  v_journal_id := _ensure_manual_journal();
  v_paid_at := COALESCE(_paid_at, CURRENT_DATE);

  -- Payment journal entry: Dt 2890 / Cr 1930
  INSERT INTO journal_entries (entry_date, description, reference_number, status, source, journal_id, created_by)
  VALUES (
    v_paid_at,
    'Expense payout ' || v_period,
    'EXP-PAY-' || v_period || '-' || substr(_report_id::text, 1, 8),
    'posted',
    'expense_payment',
    v_journal_id,
    auth.uid()
  )
  RETURNING id INTO v_entry_id;

  INSERT INTO journal_entry_lines (journal_entry_id, account_code, account_name, debit_cents, credit_cents, description)
  VALUES (v_entry_id, _liability_account, 'Owed to employee', v_total_cents, 0, 'Clear employee liability');

  INSERT INTO journal_entry_lines (journal_entry_id, account_code, account_name, debit_cents, credit_cents, description)
  VALUES (v_entry_id, _bank_account, 'Bank', 0, v_total_cents, 'Payout via ' || _method);

  -- Record payment
  INSERT INTO expense_payments (report_id, user_id, paid_at, amount_cents, currency, method, reference, notes, journal_entry_id, recorded_by)
  VALUES (_report_id, v_user_id, v_paid_at, v_total_cents, v_currency, _method, _reference, _notes, v_entry_id, auth.uid())
  RETURNING id INTO v_payment_id;

  -- Update report + expenses
  UPDATE expense_reports SET status = 'paid', updated_at = now() WHERE id = _report_id;
  UPDATE expenses SET status = 'paid', updated_at = now() WHERE report_id = _report_id;

  RETURN jsonb_build_object(
    'ok', true,
    'report_id', _report_id,
    'status', 'paid',
    'payment_id', v_payment_id,
    'journal_entry_id', v_entry_id,
    'amount_cents', v_total_cents
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.book_expense_report(uuid, text, text, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_expense_report_paid(uuid, text, text, date, text, text, text) TO authenticated;

-- ============================================================
-- 6. Register MCP skills
-- ============================================================
INSERT INTO agent_skills (name, description, category, handler, tool_definition, mcp_exposed, enabled, scope, trust_level)
VALUES
  ('book_expense_report',
   'Admin-only. Posts a balanced journal entry for an approved expense report (Dt expense + VAT / Cr owed-to-employee) and marks the report as booked. Use when: an approved expense report needs to hit the general ledger. NOT for: paying out — use mark_expense_report_paid afterwards.',
   'commerce',
   'rpc:book_expense_report',
   '{"type":"function","function":{"name":"book_expense_report","description":"Post a journal entry for an approved expense report","parameters":{"type":"object","required":["report_id"],"properties":{"report_id":{"type":"string","format":"uuid"},"expense_account":{"type":"string","description":"Default 5410","default":"5410"},"vat_account":{"type":"string","default":"2641"},"liability_account":{"type":"string","description":"Owed-to-employee account, default 2890","default":"2890"},"entry_date":{"type":"string","format":"date"}}}}}'::jsonb,
   true, true, 'internal', 'approve'),
  ('mark_expense_report_paid',
   'Admin-only. Records a payout to the employee for a booked expense report. Posts Dt 2890 / Cr 1930 and creates an expense_payments row. Use when: confirming the bank transfer / Swish / SEPA payout has been made.',
   'commerce',
   'rpc:mark_expense_report_paid',
   '{"type":"function","function":{"name":"mark_expense_report_paid","description":"Record an expense payout","parameters":{"type":"object","required":["report_id"],"properties":{"report_id":{"type":"string","format":"uuid"},"method":{"type":"string","enum":["manual","sepa","swish","bankgiro","stripe","other"],"default":"manual"},"reference":{"type":"string","description":"Bank reference / payout ID"},"paid_at":{"type":"string","format":"date"},"bank_account":{"type":"string","default":"1930"},"liability_account":{"type":"string","default":"2890"},"notes":{"type":"string"}}}}}'::jsonb,
   true, true, 'internal', 'approve')
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description,
      tool_definition = EXCLUDED.tool_definition,
      handler = EXCLUDED.handler,
      mcp_exposed = true,
      enabled = true,
      updated_at = now();