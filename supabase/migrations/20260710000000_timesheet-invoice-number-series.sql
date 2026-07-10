-- bulk_invoice_from_timesheets: mint the canonical INV-YYYY-NNNNN invoice series.
--
-- Invoice-numbering sweep, round 2 (timesheet-to-invoice QA 2026-07-10). This RPC (called
-- by invoice_from_timesheets AND bulk_invoice_from_timesheets) minted 'INV-'||count(*)+1
-- — the same doubly-wrong scheme fixed earlier in send_invoice_for_order and quote-sign:
-- a divergent format (no year) AND counting EVERY invoice row (SUB-/CN-/POS-/CTR- series)
-- as the basis, so it collided with and diverged from the real customer series
-- (INV-YYYY-NNNNN) — a sequential-numbering hazard (SE fortlöpande fakturanummer).
-- This was the THIRD independent site; grep every generator when touching invoice numbers.
--
-- Fix: last INV-YYYY-% + 1, 5-digit pad — identical to the other invoice-creation paths.
-- Idempotent CREATE OR REPLACE; only the number-generation block changed.
CREATE OR REPLACE FUNCTION public.bulk_invoice_from_timesheets(p_project_id uuid, p_start_date date, p_end_date date, p_group_by text DEFAULT 'entry'::text, p_due_days integer DEFAULT 30)
 RETURNS TABLE(invoice_id uuid, invoice_number text, line_count integer, total_cents bigint, hours_billed numeric)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_project public.projects; v_invoice_id UUID; v_invoice_num TEXT; v_line_items JSONB := '[]'::jsonb;
  v_subtotal BIGINT := 0; v_tax_rate NUMERIC := 0.25; v_tax_cents BIGINT; v_total_hours NUMERIC := 0;
  v_line_count INTEGER := 0; v_entry RECORD; v_entry_ids UUID[] := '{}';
  v_yr INT := EXTRACT(YEAR FROM CURRENT_DATE)::int; v_last TEXT; v_nextnum INT := 1;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::public.app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver'::public.app_role))) THEN RAISE EXCEPTION 'Only admins/approvers can bulk-invoice timesheets'; END IF;
  SELECT * INTO v_project FROM public.projects WHERE id = p_project_id;
  IF v_project.id IS NULL THEN RAISE EXCEPTION 'Project not found'; END IF;
  IF NOT v_project.is_billable THEN RAISE EXCEPTION 'Project is not billable'; END IF;
  IF COALESCE(v_project.hourly_rate_cents, 0) <= 0 THEN RAISE EXCEPTION 'Project has no hourly rate set'; END IF;
  IF p_group_by = 'user' THEN
    FOR v_entry IN SELECT te.user_id, COALESCE(e.name, 'User') AS user_name, SUM(te.hours) AS total_hours, ARRAY_AGG(te.id) AS ids
      FROM public.time_entries te LEFT JOIN public.employees e ON e.user_id = te.user_id
      WHERE te.project_id = p_project_id AND te.entry_date BETWEEN p_start_date AND p_end_date AND te.is_billable = true AND te.is_invoiced = false GROUP BY te.user_id, e.name LOOP
      v_line_items := v_line_items || jsonb_build_object('description', v_entry.user_name || ' — hours ' || to_char(p_start_date,'YYYY-MM-DD') || ' to ' || to_char(p_end_date,'YYYY-MM-DD'), 'qty', v_entry.total_hours, 'unit_price_cents', v_project.hourly_rate_cents);
      v_subtotal := v_subtotal + ROUND(v_entry.total_hours * v_project.hourly_rate_cents); v_total_hours := v_total_hours + v_entry.total_hours; v_line_count := v_line_count + 1; v_entry_ids := v_entry_ids || v_entry.ids;
    END LOOP;
  ELSIF p_group_by = 'week' THEN
    FOR v_entry IN SELECT date_trunc('week', te.entry_date)::date AS week_start, SUM(te.hours) AS total_hours, ARRAY_AGG(te.id) AS ids
      FROM public.time_entries te WHERE te.project_id = p_project_id AND te.entry_date BETWEEN p_start_date AND p_end_date AND te.is_billable = true AND te.is_invoiced = false GROUP BY date_trunc('week', te.entry_date) ORDER BY week_start LOOP
      v_line_items := v_line_items || jsonb_build_object('description', 'Week of ' || to_char(v_entry.week_start, 'YYYY-MM-DD'), 'qty', v_entry.total_hours, 'unit_price_cents', v_project.hourly_rate_cents);
      v_subtotal := v_subtotal + ROUND(v_entry.total_hours * v_project.hourly_rate_cents); v_total_hours := v_total_hours + v_entry.total_hours; v_line_count := v_line_count + 1; v_entry_ids := v_entry_ids || v_entry.ids;
    END LOOP;
  ELSE
    FOR v_entry IN SELECT te.id, te.entry_date, te.hours, te.description FROM public.time_entries te WHERE te.project_id = p_project_id AND te.entry_date BETWEEN p_start_date AND p_end_date AND te.is_billable = true AND te.is_invoiced = false ORDER BY te.entry_date LOOP
      v_line_items := v_line_items || jsonb_build_object('description', to_char(v_entry.entry_date,'YYYY-MM-DD') || ' — ' || COALESCE(v_entry.description, 'Hours'), 'qty', v_entry.hours, 'unit_price_cents', v_project.hourly_rate_cents);
      v_subtotal := v_subtotal + ROUND(v_entry.hours * v_project.hourly_rate_cents); v_total_hours := v_total_hours + v_entry.hours; v_line_count := v_line_count + 1; v_entry_ids := v_entry_ids || v_entry.id;
    END LOOP;
  END IF;
  IF v_line_count = 0 THEN RAISE EXCEPTION 'No billable, uninvoiced hours found for project in given period'; END IF;
  v_tax_cents := ROUND(v_subtotal * v_tax_rate);
  -- Canonical INV-YYYY-NNNNN series (matches manage_invoice / quote / order / send paths).
  SELECT i.invoice_number INTO v_last FROM public.invoices i WHERE i.invoice_number ILIKE 'INV-' || v_yr || '-%' ORDER BY i.invoice_number DESC LIMIT 1;
  IF v_last IS NOT NULL THEN v_nextnum := COALESCE((substring(v_last from 'INV-\d{4}-(\d+)'))::int, 0) + 1; END IF;
  v_invoice_num := 'INV-' || v_yr || '-' || LPAD(v_nextnum::text, 5, '0');
  INSERT INTO public.invoices (invoice_number, customer_name, project_id, line_items, subtotal_cents, tax_rate, tax_cents, total_cents, currency, issue_date, due_date, status, created_by, notes)
  VALUES (v_invoice_num, COALESCE(v_project.client_name, v_project.name), p_project_id, v_line_items, v_subtotal, v_tax_rate, v_tax_cents, v_subtotal + v_tax_cents, v_project.currency, CURRENT_DATE, CURRENT_DATE + p_due_days, 'draft', auth.uid(), 'Auto-generated from timesheets ' || p_start_date || ' → ' || p_end_date)
  RETURNING id INTO v_invoice_id;
  UPDATE public.time_entries SET is_invoiced = true, invoice_id = v_invoice_id, updated_at = now() WHERE id = ANY(v_entry_ids);
  invoice_id := v_invoice_id; invoice_number := v_invoice_num; line_count := v_line_count; total_cents := v_subtotal + v_tax_cents; hours_billed := v_total_hours;
  RETURN NEXT;
END; $function$;
