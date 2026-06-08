CREATE TABLE IF NOT EXISTS public.vendor_invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number TEXT NOT NULL,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE RESTRICT,
  purchase_order_id UUID REFERENCES public.purchase_orders(id) ON DELETE SET NULL,
  invoice_date DATE NOT NULL DEFAULT CURRENT_DATE,
  due_date DATE,
  subtotal_cents BIGINT NOT NULL DEFAULT 0,
  tax_cents BIGINT NOT NULL DEFAULT 0,
  total_cents BIGINT NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'SEK',
  status TEXT NOT NULL DEFAULT 'received'
    CHECK (status IN ('received','matched','variance','approved','rejected','paid')),
  match_status TEXT NOT NULL DEFAULT 'unmatched'
    CHECK (match_status IN ('unmatched','matched','partial','variance')),
  variance_cents BIGINT NOT NULL DEFAULT 0,
  variance_notes TEXT,
  approved_by UUID REFERENCES auth.users(id),
  approved_at TIMESTAMPTZ,
  paid_at TIMESTAMPTZ,
  notes TEXT,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (vendor_id, invoice_number)
);
CREATE INDEX IF NOT EXISTS idx_vendor_invoices_po ON public.vendor_invoices(purchase_order_id);
CREATE INDEX IF NOT EXISTS idx_vendor_invoices_status ON public.vendor_invoices(status);
ALTER TABLE public.vendor_invoices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage vendor invoices" ON public.vendor_invoices;
CREATE POLICY "Admins manage vendor invoices" ON public.vendor_invoices
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'::public.app_role))
  WITH CHECK (public.has_role(auth.uid(), 'admin'::public.app_role));
DROP POLICY IF EXISTS "Writers view vendor invoices" ON public.vendor_invoices;
CREATE POLICY "Writers view vendor invoices" ON public.vendor_invoices
  FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'writer'::public.app_role) OR public.has_role(auth.uid(), 'approver'::public.app_role));
DROP TRIGGER IF EXISTS trg_vendor_invoices_updated_at ON public.vendor_invoices;
CREATE TRIGGER trg_vendor_invoices_updated_at
  BEFORE UPDATE ON public.vendor_invoices
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE OR REPLACE FUNCTION public.match_po_to_invoice(
  p_invoice_id UUID, p_variance_tolerance_pct NUMERIC DEFAULT 2.0
) RETURNS public.vendor_invoices
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_inv public.vendor_invoices;
  v_po public.purchase_orders;
  v_received_total BIGINT := 0;
  v_variance BIGINT;
  v_variance_pct NUMERIC;
  v_match_status TEXT; v_new_status TEXT; v_notes TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_inv FROM public.vendor_invoices WHERE id = p_invoice_id FOR UPDATE;
  IF v_inv.id IS NULL THEN RAISE EXCEPTION 'Vendor invoice not found'; END IF;
  IF v_inv.purchase_order_id IS NULL THEN RAISE EXCEPTION 'Invoice has no linked purchase order'; END IF;
  SELECT * INTO v_po FROM public.purchase_orders WHERE id = v_inv.purchase_order_id;
  IF v_po.id IS NULL THEN RAISE EXCEPTION 'Linked purchase order not found'; END IF;
  SELECT COALESCE(SUM(pol.received_quantity * pol.unit_price_cents), 0) INTO v_received_total
    FROM public.purchase_order_lines pol WHERE pol.purchase_order_id = v_po.id;
  v_variance := v_inv.total_cents - v_received_total;
  v_variance_pct := CASE WHEN v_received_total = 0 THEN 100
                         ELSE ABS(v_variance)::NUMERIC / v_received_total * 100 END;
  IF v_received_total = 0 THEN
    v_match_status := 'unmatched'; v_new_status := 'variance';
    v_notes := 'No goods receipts recorded against PO';
  ELSIF v_variance_pct <= p_variance_tolerance_pct THEN
    v_match_status := 'matched'; v_new_status := 'matched';
    v_notes := format('3-way match OK (variance %.2f%% within %.2f%%)', v_variance_pct, p_variance_tolerance_pct);
  ELSE
    v_match_status := 'variance'; v_new_status := 'variance';
    v_notes := format('Variance %.2f%% exceeds tolerance %.2f%% (invoice %s vs received %s)',
      v_variance_pct, p_variance_tolerance_pct, v_inv.total_cents, v_received_total);
  END IF;
  UPDATE public.vendor_invoices
  SET match_status = v_match_status, status = v_new_status,
      variance_cents = v_variance, variance_notes = v_notes, updated_at = now()
  WHERE id = p_invoice_id RETURNING * INTO v_inv;
  RETURN v_inv;
END; $$;

CREATE OR REPLACE FUNCTION public.auto_approve_vendor_invoice(p_invoice_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_inv public.vendor_invoices; v_rule RECORD; v_request_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_inv FROM public.vendor_invoices WHERE id = p_invoice_id;
  IF v_inv.id IS NULL THEN RAISE EXCEPTION 'Vendor invoice not found'; END IF;
  IF v_inv.match_status <> 'matched' THEN
    RETURN jsonb_build_object('auto_approved', false,
      'reason', 'Invoice is not in matched state',
      'match_status', v_inv.match_status, 'status', v_inv.status);
  END IF;
  SELECT * INTO v_rule FROM public.evaluate_approval_required('vendor_invoice', v_inv.total_cents, v_inv.currency);
  IF v_rule.rule_id IS NULL THEN
    UPDATE public.vendor_invoices
    SET status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
    WHERE id = p_invoice_id;
    RETURN jsonb_build_object('auto_approved', true, 'reason', 'No approval rule matched threshold');
  END IF;
  INSERT INTO public.approval_requests (
    entity_type, entity_id, amount_cents, currency, required_role, rule_id, requested_by, status, payload
  ) VALUES (
    'vendor_invoice', p_invoice_id, v_inv.total_cents, v_inv.currency,
    v_rule.required_role, v_rule.rule_id, auth.uid(), 'pending',
    jsonb_build_object('invoice_number', v_inv.invoice_number, 'vendor_id', v_inv.vendor_id)
  ) RETURNING id INTO v_request_id;
  RETURN jsonb_build_object('auto_approved', false,
    'approval_request_id', v_request_id,
    'required_role', v_rule.required_role,
    'rule_name', v_rule.rule_name);
END; $$;

CREATE OR REPLACE FUNCTION public.sync_vendor_invoice_on_approval()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.entity_type = 'vendor_invoice' AND NEW.status IN ('approved','rejected') AND OLD.status = 'pending' THEN
    UPDATE public.vendor_invoices
    SET status = NEW.status::text,
        approved_by = NEW.resolved_by,
        approved_at = NEW.resolved_at,
        updated_at = now()
    WHERE id = NEW.entity_id;
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_sync_vendor_invoice_approval ON public.approval_requests;
CREATE TRIGGER trg_sync_vendor_invoice_approval
  AFTER UPDATE ON public.approval_requests
  FOR EACH ROW EXECUTE FUNCTION public.sync_vendor_invoice_on_approval();

INSERT INTO public.approval_rules (name, entity_type, amount_threshold_cents, currency, required_role, priority, is_active)
SELECT 'Vendor invoice > 50.000 SEK', 'vendor_invoice', 5000000, 'SEK', 'admin'::public.app_role, 100, true
WHERE NOT EXISTS (SELECT 1 FROM public.approval_rules WHERE entity_type = 'vendor_invoice');

-- Seed skills (delete then insert; name has no UNIQUE)
DELETE FROM public.agent_skills WHERE name IN
  ('register_vendor_invoice','match_po_to_invoice','auto_approve_vendor_invoice','flag_invoice_variance');

INSERT INTO public.agent_skills (name, description, category, handler, scope, tool_definition, mcp_exposed, enabled) VALUES
  ('register_vendor_invoice',
   'Register an incoming vendor invoice (AP inbox). Use when: a vendor bill arrives that needs 3-way matching against a PO before payment. NOT for: customer invoices (use create_invoice).',
   'commerce', 'db:vendor_invoices', 'internal',
   jsonb_build_object('type','function','function', jsonb_build_object(
     'name','register_vendor_invoice',
     'description','Register an incoming vendor invoice for 3-way matching',
     'parameters', jsonb_build_object('type','object',
       'properties', jsonb_build_object(
         'vendor_id', jsonb_build_object('type','string'),
         'invoice_number', jsonb_build_object('type','string'),
         'purchase_order_id', jsonb_build_object('type','string'),
         'invoice_date', jsonb_build_object('type','string'),
         'due_date', jsonb_build_object('type','string'),
         'subtotal_cents', jsonb_build_object('type','number'),
         'tax_cents', jsonb_build_object('type','number'),
         'total_cents', jsonb_build_object('type','number'),
         'currency', jsonb_build_object('type','string')),
       'required', jsonb_build_array('vendor_id','invoice_number','total_cents')))),
   true, true),
  ('match_po_to_invoice',
   '3-way match a vendor invoice against its PO and goods receipts. Use when: a registered vendor invoice needs validation before approval. Compares PO ↔ received goods ↔ invoice within tolerance. NOT for: customer reconciliation.',
   'commerce', 'rpc:match_po_to_invoice', 'internal',
   jsonb_build_object('type','function','function', jsonb_build_object(
     'name','match_po_to_invoice',
     'description','Run 3-way match for a vendor invoice',
     'parameters', jsonb_build_object('type','object',
       'properties', jsonb_build_object(
         'invoice_id', jsonb_build_object('type','string'),
         'variance_tolerance_pct', jsonb_build_object('type','number','default',2.0)),
       'required', jsonb_build_array('invoice_id')))),
   true, true),
  ('auto_approve_vendor_invoice',
   'Auto-approve a matched vendor invoice if amount is below threshold, otherwise create approval request for required role. Use when: invoice has passed 3-way match and needs the approval gate.',
   'commerce', 'rpc:auto_approve_vendor_invoice', 'internal',
   jsonb_build_object('type','function','function', jsonb_build_object(
     'name','auto_approve_vendor_invoice',
     'description','Auto-approve matched invoice or escalate to approver',
     'parameters', jsonb_build_object('type','object',
       'properties', jsonb_build_object('invoice_id', jsonb_build_object('type','string')),
       'required', jsonb_build_array('invoice_id')))),
   true, true),
  ('flag_invoice_variance',
   'List vendor invoices flagged with price/quantity variance against their PO that need manual review. Use when: admin wants to see what failed automated 3-way matching.',
   'commerce', 'db:vendor_invoices', 'internal',
   jsonb_build_object('type','function','function', jsonb_build_object(
     'name','flag_invoice_variance',
     'description','List vendor invoices with variance issues',
     'parameters', jsonb_build_object('type','object','properties', jsonb_build_object()))),
   true, true);