-- record_invoice_payment: make it idempotent via a caller-supplied reference key.
--
-- Edge-case QA 2026-07-10: the payment path had no idempotency guard — recording the SAME
-- payment twice (an agent retry, a double-click, a webhook redelivery) accumulated
-- paid_amount_cents twice (40000 + 40000 → 80000 on a single real 40000 payment). The
-- amount>remaining guard only caps the TOTAL; within the balance, duplicates silently
-- double-count and corrupt the books/reconciliation. This is the "idempotency on every
-- side-effect" core principle for agent-operated money movement.
--
-- Fix: an optional p_reference (external payment id / idempotency key). When provided, if a
-- payment with the same reference was already recorded for this invoice, return the current
-- state as a no-op instead of applying it again. The reference is stored in the audit_logs
-- metadata (there is no per-payment table; paid_amount_cents + audit_logs are the record).
-- Callers should pass a stable reference (Stripe PI id, a client-generated uuid, etc.) to
-- make retries safe. p_reference defaults NULL → old behaviour, BUT adding a 5th arg makes
-- a new overload — drop the old 4-arg signature first so PostgREST doesn't see two
-- candidates (PGRST203 ambiguity) when called with a subset of named args.
DROP FUNCTION IF EXISTS public.record_invoice_payment(uuid, bigint, text, timestamp with time zone);

CREATE OR REPLACE FUNCTION public.record_invoice_payment(p_invoice_id uuid, p_amount_cents bigint, p_method text DEFAULT 'manual'::text, p_paid_at timestamp with time zone DEFAULT now(), p_reference text DEFAULT NULL::text)
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

  -- Idempotency: a payment already recorded under this reference for this invoice is a no-op.
  IF p_reference IS NOT NULL AND EXISTS (
    SELECT 1 FROM audit_logs
     WHERE action = 'invoice.payment_recorded' AND entity_type = 'invoice' AND entity_id = p_invoice_id
       AND metadata->>'reference' = p_reference
  ) THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'invoice_id', p_invoice_id,
      'paid_amount_cents', v_inv.paid_amount_cents,
      'remaining_cents', GREATEST(0, v_inv.total_cents - v_inv.paid_amount_cents),
      'fully_paid', v_inv.paid_amount_cents >= v_inv.total_cents, 'status', v_inv.status::text);
  END IF;

  v_remaining := GREATEST(0, v_inv.total_cents - v_inv.paid_amount_cents);
  IF p_amount_cents > v_remaining THEN RAISE EXCEPTION 'Payment % exceeds remaining balance %', p_amount_cents, v_remaining; END IF;
  v_new_paid := v_inv.paid_amount_cents + p_amount_cents;
  v_fully := (v_new_paid >= v_inv.total_cents);
  v_new_status := CASE
    WHEN v_fully THEN 'paid'::invoice_status
    WHEN v_inv.status = 'overdue'::invoice_status THEN 'overdue'::invoice_status
    WHEN v_new_paid > 0 THEN 'partially_paid'::invoice_status
    ELSE v_inv.status END;
  UPDATE invoices SET paid_amount_cents = v_new_paid, status = v_new_status, paid_at = CASE WHEN v_fully THEN COALESCE(paid_at, p_paid_at) ELSE paid_at END WHERE id = p_invoice_id;
  INSERT INTO audit_logs (action, entity_type, entity_id, user_id, metadata)
  VALUES ('invoice.payment_recorded', 'invoice', p_invoice_id, auth.uid(),
    jsonb_build_object('amount_cents', p_amount_cents, 'method', p_method, 'paid_amount_cents', v_new_paid, 'fully_paid', v_fully, 'reference', p_reference));
  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'amount_cents', p_amount_cents, 'paid_amount_cents', v_new_paid, 'remaining_cents', GREATEST(0, v_inv.total_cents - v_new_paid), 'fully_paid', v_fully, 'status', v_new_status::text);
END; $function$;
