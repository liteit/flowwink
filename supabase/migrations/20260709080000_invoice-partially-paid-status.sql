-- Add a 'partially_paid' invoice status and set it when a payment is recorded but the
-- balance is not yet cleared.
--
-- Invoice-to-cash QA 2026-07-09: record_invoice_payment tracked paid_amount_cents /
-- remaining but left status unchanged on a partial payment — so a draft/sent invoice
-- that was, say, 40% paid still showed "draft"/"sent". For an SMB that lives on cash
-- flow, "which invoices are part-paid and how much is still out" is exactly the view
-- that was missing. Now a partial payment surfaces as partially_paid (unless the invoice
-- is already overdue — that urgency is preserved), full payment still flips to paid.
--
-- ALTER TYPE ... ADD VALUE cannot run inside a transaction block, so this must be applied
-- in autocommit (plain psql / standalone) — idempotent via IF NOT EXISTS.
ALTER TYPE public.invoice_status ADD VALUE IF NOT EXISTS 'partially_paid' BEFORE 'paid';

CREATE OR REPLACE FUNCTION public.record_invoice_payment(p_invoice_id uuid, p_amount_cents bigint, p_method text DEFAULT 'manual'::text, p_paid_at timestamp with time zone DEFAULT now())
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_inv RECORD; v_remaining bigint; v_new_paid bigint; v_fully boolean; v_new_status invoice_status;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin') OR has_role(auth.uid(), 'approver')) THEN RAISE EXCEPTION 'Not authorized to record payments'; END IF;
  IF p_amount_cents <= 0 THEN RAISE EXCEPTION 'p_amount_cents must be positive'; END IF;
  SELECT id, total_cents, COALESCE(paid_amount_cents,0) AS paid_amount_cents, status, invoice_type INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice % not found', p_invoice_id; END IF;
  IF v_inv.status::text = 'cancelled' THEN RAISE EXCEPTION 'Cannot pay a cancelled invoice'; END IF;
  IF COALESCE(v_inv.invoice_type,'invoice') <> 'invoice' THEN RAISE EXCEPTION 'Cannot pay a credit note'; END IF;
  v_remaining := GREATEST(0, v_inv.total_cents - v_inv.paid_amount_cents);
  IF p_amount_cents > v_remaining THEN RAISE EXCEPTION 'Payment % exceeds remaining balance %', p_amount_cents, v_remaining; END IF;
  v_new_paid := v_inv.paid_amount_cents + p_amount_cents;
  v_fully := (v_new_paid >= v_inv.total_cents);
  -- Status: fully paid → paid; otherwise reflect the partial payment as partially_paid,
  -- but keep 'overdue' if it was already overdue (a part payment doesn't clear the lateness).
  v_new_status := CASE
    WHEN v_fully THEN 'paid'::invoice_status
    WHEN v_inv.status = 'overdue'::invoice_status THEN 'overdue'::invoice_status
    WHEN v_new_paid > 0 THEN 'partially_paid'::invoice_status
    ELSE v_inv.status END;
  UPDATE invoices SET paid_amount_cents = v_new_paid, status = v_new_status, paid_at = CASE WHEN v_fully THEN COALESCE(paid_at, p_paid_at) ELSE paid_at END WHERE id = p_invoice_id;
  INSERT INTO audit_logs (action, entity_type, entity_id, user_id, metadata)
  VALUES ('invoice.payment_recorded', 'invoice', p_invoice_id, auth.uid(), jsonb_build_object('amount_cents', p_amount_cents, 'method', p_method, 'paid_amount_cents', v_new_paid, 'fully_paid', v_fully));
  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'amount_cents', p_amount_cents, 'paid_amount_cents', v_new_paid, 'remaining_cents', GREATEST(0, v_inv.total_cents - v_new_paid), 'fully_paid', v_fully, 'status', v_new_status::text);
END; $function$;
