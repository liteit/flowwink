-- Procure-to-pay QA fixes 2026-07-09 (found by running the chain via the MCP gateway).
-- All idempotent (CREATE OR REPLACE / DROP..IF EXISTS + ADD), forward-dated so managed
-- forks apply them (a below-HEAD timestamp is silently skipped).
--
-- 1. match_po_to_invoice: auth.uid() gate blocked the service-role agent, and format()
--    used printf specifiers (%.2f) which Postgres format() does not support → the
--    function threw 'unrecognized format() type specifier' on EVERY match. Both fixed.
-- 2. match_invoice_to_receipt: same printf-format bug in three notes strings; it is the
--    canonical 3-way match wired to the invoice.registered automation, so the automated
--    matching path was crashing in production. Fixed to round()+%s.
-- 3. vendor_invoices_match_status_check was ['unmatched','matched','partial','variance']
--    but match_invoice_to_receipt writes the richer statuses its own description promises
--    (over_invoiced / under_invoiced / no_receipt / no_po) → constraint violation on real
--    invoices. Widened to include them.
-- 4. hire_candidate_from_application: auth.uid() gate blocked the service-role agent
--    (hire-to-retire) — added the service_role escape.

create or replace function public.match_po_to_invoice(p_invoice_id uuid, p_variance_tolerance_pct numeric default 2.0)
returns vendor_invoices language plpgsql security definer set search_path to 'public' as $function$
DECLARE
  v_inv public.vendor_invoices; v_po public.purchase_orders;
  v_received_total BIGINT := 0; v_variance BIGINT; v_variance_pct NUMERIC;
  v_match_status TEXT; v_new_status TEXT; v_notes TEXT;
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_inv FROM public.vendor_invoices WHERE id = p_invoice_id FOR UPDATE;
  IF v_inv.id IS NULL THEN RAISE EXCEPTION 'Vendor invoice not found'; END IF;
  IF v_inv.purchase_order_id IS NULL THEN RAISE EXCEPTION 'Invoice has no linked purchase order'; END IF;
  SELECT * INTO v_po FROM public.purchase_orders WHERE id = v_inv.purchase_order_id;
  IF v_po.id IS NULL THEN RAISE EXCEPTION 'Linked purchase order not found'; END IF;
  SELECT COALESCE(SUM(pol.received_quantity * pol.unit_price_cents), 0) INTO v_received_total
    FROM public.purchase_order_lines pol WHERE pol.purchase_order_id = v_po.id;
  v_variance := v_inv.total_cents - v_received_total;
  v_variance_pct := CASE WHEN v_received_total = 0 THEN 100 ELSE ABS(v_variance)::NUMERIC / v_received_total * 100 END;
  IF v_received_total = 0 THEN v_match_status := 'unmatched'; v_new_status := 'variance'; v_notes := 'No goods receipts recorded against PO';
  ELSIF v_variance_pct <= p_variance_tolerance_pct THEN v_match_status := 'matched'; v_new_status := 'matched';
    v_notes := format('3-way match OK (variance %s%% within %s%%)', round(v_variance_pct,2), round(p_variance_tolerance_pct,2));
  ELSE v_match_status := 'variance'; v_new_status := 'variance';
    v_notes := format('Variance %s%% exceeds tolerance %s%% (invoice %s vs received %s)', round(v_variance_pct,2), round(p_variance_tolerance_pct,2), v_inv.total_cents, v_received_total);
  END IF;
  UPDATE public.vendor_invoices SET match_status = v_match_status, status = v_new_status,
      variance_cents = v_variance, variance_notes = v_notes, updated_at = now()
  WHERE id = p_invoice_id RETURNING * INTO v_inv;
  RETURN v_inv;
END; $function$;

create or replace function public.match_invoice_to_receipt(p_invoice_id uuid, p_tolerance_pct numeric default 2.0)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
DECLARE
  v_inv record; v_po_total bigint; v_received_value bigint; v_variance bigint;
  v_variance_pct numeric; v_match_status text; v_notes text;
BEGIN
  SELECT * INTO v_inv FROM vendor_invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice % not found', p_invoice_id; END IF;
  IF v_inv.purchase_order_id IS NULL THEN
    UPDATE vendor_invoices SET match_status = 'no_po', variance_cents = 0,
      variance_notes = 'Invoice not linked to any PO', updated_at = now() WHERE id = p_invoice_id;
    RETURN jsonb_build_object('success', true, 'match_status', 'no_po');
  END IF;
  SELECT COALESCE(SUM(grl.quantity_received * pol.unit_price_cents), 0)::bigint INTO v_received_value
  FROM goods_receipt_lines grl
  JOIN goods_receipts gr ON gr.id = grl.goods_receipt_id
  JOIN purchase_order_lines pol ON pol.id = grl.po_line_id
  WHERE gr.purchase_order_id = v_inv.purchase_order_id;
  SELECT total_cents INTO v_po_total FROM purchase_orders WHERE id = v_inv.purchase_order_id;
  v_variance := v_inv.subtotal_cents - v_received_value;
  v_variance_pct := CASE WHEN v_received_value > 0 THEN abs(v_variance)::numeric / v_received_value * 100 ELSE 100 END;
  IF v_received_value = 0 THEN v_match_status := 'no_receipt'; v_notes := 'No goods received yet against this PO';
  ELSIF v_variance_pct <= p_tolerance_pct THEN v_match_status := 'matched';
    v_notes := format('Within %s%% tolerance', round(p_tolerance_pct,2));
  ELSIF v_variance > 0 THEN v_match_status := 'over_invoiced';
    v_notes := format('Invoice %s cents > received value %s cents (%s%% variance)', v_inv.subtotal_cents, v_received_value, round(v_variance_pct,2));
  ELSE v_match_status := 'under_invoiced';
    v_notes := format('Invoice %s cents < received value %s cents (%s%% variance)', v_inv.subtotal_cents, v_received_value, round(v_variance_pct,2));
  END IF;
  UPDATE vendor_invoices SET match_status = v_match_status, variance_cents = v_variance,
    variance_notes = v_notes, updated_at = now() WHERE id = p_invoice_id;
  PERFORM public.emit_platform_event('invoice.matched',
    jsonb_build_object('invoice_id', p_invoice_id, 'purchase_order_id', v_inv.purchase_order_id,
      'match_status', v_match_status, 'variance_cents', v_variance, 'variance_pct', round(v_variance_pct, 2)),
    'match_invoice_to_receipt');
  RETURN jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'match_status', v_match_status,
    'variance_cents', v_variance, 'variance_pct', round(v_variance_pct, 2),
    'received_value_cents', v_received_value, 'po_total_cents', v_po_total, 'notes', v_notes);
END; $function$;

alter table public.vendor_invoices drop constraint if exists vendor_invoices_match_status_check;
alter table public.vendor_invoices add constraint vendor_invoices_match_status_check
  check (match_status = any (array['unmatched','matched','partial','variance','over_invoiced','under_invoiced','no_receipt','no_po']::text[]));

create or replace function public.hire_candidate_from_application(p_application_id uuid, p_start_date date default null::date, p_employment_type text default 'full_time'::text, p_department text default null::text)
 returns jsonb language plpgsql security definer set search_path to 'public' as $function$
DECLARE v_app RECORD; v_job RECORD; v_employee_id UUID; v_checklist_id UUID; v_user_id UUID;
BEGIN
  IF auth.uid() IS NULL AND auth.role() <> 'service_role' THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_app FROM public.applications WHERE id = p_application_id;
  IF v_app.id IS NULL THEN RAISE EXCEPTION 'Application not found'; END IF;
  IF v_app.employee_id IS NOT NULL THEN RAISE EXCEPTION 'Application already hired (employee_id: %)', v_app.employee_id; END IF;
  SELECT * INTO v_job FROM public.job_postings WHERE id = v_app.job_posting_id;
  INSERT INTO public.employees (name, email, phone, title, department, employment_type, start_date, status)
  VALUES (COALESCE(v_app.candidate_name, 'New Hire'), v_app.candidate_email, v_app.candidate_phone, v_job.title,
    COALESCE(p_department, v_job.department), p_employment_type, COALESCE(p_start_date, CURRENT_DATE), 'active')
  RETURNING id INTO v_employee_id;
  UPDATE public.applications SET employee_id = v_employee_id, stage = 'hired', hired_at = now(), updated_at = now() WHERE id = p_application_id;
  INSERT INTO public.onboarding_checklists (employee_id, items) VALUES (v_employee_id, jsonb_build_array(
      jsonb_build_object('title', 'IT setup (laptop, accounts, email)', 'done', false),
      jsonb_build_object('title', 'Access cards & office tour', 'done', false),
      jsonb_build_object('title', 'Welcome meeting with team', 'done', false),
      jsonb_build_object('title', 'Sign employment contract', 'done', false),
      jsonb_build_object('title', 'Review company policies & handbook', 'done', false),
      jsonb_build_object('title', 'Assign onboarding buddy', 'done', false)))
  RETURNING id INTO v_checklist_id;
  v_user_id := public.link_employee_to_auth_user(v_employee_id);
  RETURN jsonb_build_object('success', true, 'employee_id', v_employee_id, 'application_id', p_application_id,
    'checklist_id', v_checklist_id, 'user_id', v_user_id, 'needs_invite', v_user_id IS NULL);
END; $function$;
