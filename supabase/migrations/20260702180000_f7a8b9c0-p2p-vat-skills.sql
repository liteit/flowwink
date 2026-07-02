-- Process-gap skills: pay_vendor_invoice (P2P payment step) + prepare_vat_return
-- (R2R tax-reporting step). Both were happy-path stallers — an agent could reach
-- the step but had no callable skill to perform it. Idempotent.

-- ── pay_vendor_invoice ───────────────────────────────────────────────────────
-- Records the OUTGOING payment of an approved vendor invoice: posts Dt 2440
-- (leverantörsskuld) / Cr <bank> and marks the invoice paid. Mirror of the AR
-- record_invoice_payment but for the payable side (which had no skill).
CREATE OR REPLACE FUNCTION public.pay_vendor_invoice(
  p_vendor_invoice_id uuid,
  p_pay_date date DEFAULT CURRENT_DATE,
  p_bank_account text DEFAULT '1930'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_inv public.vendor_invoices;
  v_je_id uuid;
BEGIN
  SELECT * INTO v_inv FROM public.vendor_invoices WHERE id = p_vendor_invoice_id;
  IF v_inv.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendor invoice not found');
  END IF;
  IF v_inv.paid_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendor invoice already paid', 'paid_at', v_inv.paid_at);
  END IF;
  IF COALESCE(v_inv.total_cents, 0) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendor invoice has no positive total');
  END IF;

  INSERT INTO public.journal_entries (entry_date, description, status, source, vendor_id)
  VALUES (p_pay_date, 'Betalning leverantörsfaktura ' || COALESCE(v_inv.invoice_number, ''), 'posted', 'vendor_payment', v_inv.vendor_id)
  RETURNING id INTO v_je_id;

  -- account_name is auto-filled by the fill_journal_line_account_name trigger.
  INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description) VALUES
    (v_je_id, '2440', v_inv.total_cents, 0, 'Leverantörsskuld'),
    (v_je_id, p_bank_account, 0, v_inv.total_cents, 'Utbetalning');

  UPDATE public.vendor_invoices SET status = 'paid', paid_at = p_pay_date WHERE id = v_inv.id;

  RETURN jsonb_build_object(
    'success', true, 'vendor_invoice_id', v_inv.id, 'journal_entry_id', v_je_id,
    'total_cents', v_inv.total_cents, 'paid_at', p_pay_date, 'bank_account', p_bank_account
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.pay_vendor_invoice(uuid, date, text) TO service_role, authenticated;

-- ── prepare_vat_return ───────────────────────────────────────────────────────
-- Summarizes output/input VAT from the ledger for a period into the boxes that
-- make up a Swedish momsdeklaration. Read-only; accounting_reports gave BS/P&L
-- but no VAT summary, so the reporting step had no callable skill.
CREATE OR REPLACE FUNCTION public.prepare_vat_return(
  p_from date,
  p_to date
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_out_25 bigint; v_out_12 bigint; v_out_6 bigint; v_out_rc bigint;
  v_input bigint; v_output bigint; v_net bigint;
BEGIN
  SELECT
    COALESCE(SUM(CASE WHEN l.account_code = '2610' THEN l.credit_cents - l.debit_cents ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN l.account_code = '2620' THEN l.credit_cents - l.debit_cents ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN l.account_code = '2630' THEN l.credit_cents - l.debit_cents ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN l.account_code = '2611' THEN l.credit_cents - l.debit_cents ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN l.account_code IN ('2640','2645') THEN l.debit_cents - l.credit_cents ELSE 0 END), 0)
  INTO v_out_25, v_out_12, v_out_6, v_out_rc, v_input
  FROM public.journal_entry_lines l
  JOIN public.journal_entries e ON e.id = l.journal_entry_id
  WHERE e.entry_date BETWEEN p_from AND p_to
    AND e.status = 'posted';

  v_output := v_out_25 + v_out_12 + v_out_6 + v_out_rc;
  v_net := v_output - v_input;

  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'output_vat_cents', jsonb_build_object(
      'standard_25', v_out_25, 'reduced_12', v_out_12, 'reduced_6', v_out_6,
      'reverse_charge', v_out_rc, 'total', v_output
    ),
    'input_vat_cents', v_input,
    'net_to_pay_cents', v_net,
    'net_to_pay_sek', round(v_net / 100.0, 2),
    'direction', CASE WHEN v_net >= 0 THEN 'pay_to_skatteverket' ELSE 'refund_from_skatteverket' END,
    'note', 'Sums posted journal lines on the VAT accounts (2610/2620/2630 output, 2611 reverse-charge, 2640/2645 input). Verify against the VAT control account (2650) before filing.'
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.prepare_vat_return(date, date) TO service_role, authenticated;
