-- Open 34 skill-exposed admin RPCs to the gateway-authenticated service path.
-- Each is an agent skill (handler rpc:*) gated by has_role(auth.uid(),'admin'),
-- but agent execution runs with the SERVICE key (auth.uid() = NULL), so the gate
-- ALWAYS raised — these skills could never run for FlowPilot/MCP/automations
-- (manufacturing, picking, webinars, subscriptions, procurement, period close,
-- timesheet locks, …). The skill surface's trust boundary is the gateway (API
-- keys + per-skill trust_level), the same boundary the other ~250 skills pass.
-- Gate becomes (auth.role() = 'service_role' OR has_role(auth.uid(), <role>)).
-- Human/anon sessions keep the EXACT old requirement. Generated from live
-- definitions; idempotent CREATE OR REPLACE. (Owner-authorized 2026-06-10.)


-- adjust_quant
CREATE OR REPLACE FUNCTION public.adjust_quant(p_product_id uuid, p_location_id uuid, p_qty_delta numeric, p_lot_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT 'manual_adjustment'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_move uuid;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer'::app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role))) THEN RAISE EXCEPTION 'Insufficient privileges'; END IF;
  IF p_qty_delta = 0 THEN RAISE EXCEPTION 'Delta cannot be zero'; END IF;
  PERFORM _upsert_quant(p_product_id, p_location_id, p_lot_id, p_qty_delta);
  INSERT INTO stock_moves (product_id, quantity, move_type, to_location_id, lot_id, notes, created_by, state)
  VALUES (p_product_id, ABS(p_qty_delta)::int, 'adjustment', p_location_id, p_lot_id, p_reason, auth.uid(), 'done')
  RETURNING id INTO v_move;
  RETURN v_move;
END; $function$

;

-- allocate_picking
CREATE OR REPLACE FUNCTION public.allocate_picking(p_order_id uuid, p_source_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_picking_id UUID;
  v_order RECORD;
  v_item RECORD;
  v_line_id UUID;
  v_reservation_id UUID;
  v_source_location UUID;
  v_short_count INT := 0;
  v_total_count INT := 0;
  v_lines JSONB := '[]'::JSONB;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'employee')) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % not found', p_order_id;
  END IF;

  -- Pick default source location if not given
  v_source_location := COALESCE(
    p_source_location_id,
    (SELECT id FROM public.stock_locations WHERE location_type = 'internal' AND is_active = true ORDER BY created_at LIMIT 1)
  );

  -- Idempotency: reuse open picking_order for this order if exists
  SELECT id INTO v_picking_id
  FROM public.picking_orders
  WHERE order_id = p_order_id AND status IN ('draft','ready','in_progress')
  LIMIT 1;

  IF v_picking_id IS NULL THEN
    INSERT INTO public.picking_orders (order_id, source_location_id, status, ship_to_name, ship_to_address, created_by, allocated_at)
    VALUES (
      p_order_id,
      v_source_location,
      'ready',
      COALESCE(v_order.customer_name, v_order.shipping_address->>'name'),
      v_order.shipping_address,
      auth.uid(),
      now()
    )
    RETURNING id INTO v_picking_id;
  END IF;

  -- Iterate order_items
  FOR v_item IN
    SELECT oi.*, p.name AS p_name, p.sku AS p_sku
    FROM public.order_items oi
    LEFT JOIN public.products p ON p.id = oi.product_id
    WHERE oi.order_id = p_order_id
  LOOP
    v_total_count := v_total_count + 1;
    v_reservation_id := NULL;

    -- Try reserve
    BEGIN
      v_reservation_id := public.reserve_stock(
        v_item.product_id,
        v_source_location,
        v_item.quantity,
        'picking_order',
        v_picking_id
      );
    EXCEPTION WHEN OTHERS THEN
      v_short_count := v_short_count + 1;
    END;

    INSERT INTO public.picking_lines (
      picking_order_id, product_id, product_sku, product_name,
      qty_requested, reservation_id, status
    )
    VALUES (
      v_picking_id, v_item.product_id, v_item.p_sku, COALESCE(v_item.p_name, 'Product'),
      v_item.quantity, v_reservation_id,
      CASE WHEN v_reservation_id IS NOT NULL THEN 'reserved' ELSE 'short' END
    )
    RETURNING id INTO v_line_id;

    v_lines := v_lines || jsonb_build_object(
      'line_id', v_line_id,
      'product_id', v_item.product_id,
      'qty', v_item.quantity,
      'reserved', v_reservation_id IS NOT NULL
    );
  END LOOP;

  -- Audit
  INSERT INTO public.audit_logs (action, entity_type, entity_id, user_id, metadata)
  VALUES ('picking.allocated', 'picking_order', v_picking_id, auth.uid(),
    jsonb_build_object('order_id', p_order_id, 'lines', v_total_count, 'short', v_short_count));

  RETURN jsonb_build_object(
    'success', true,
    'picking_order_id', v_picking_id,
    'lines_total', v_total_count,
    'lines_short', v_short_count,
    'lines', v_lines
  );
END;
$function$

;

-- approve_procurement_suggestion
CREATE OR REPLACE FUNCTION public.approve_procurement_suggestion(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE s procurement_suggestions%ROWTYPE; v_po_id uuid; v_po_number text; v_unit_price integer; v_total integer; v_bom uuid; v_mo uuid;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) THEN RAISE EXCEPTION 'Only admins can approve procurement suggestions'; END IF;
  SELECT * INTO s FROM procurement_suggestions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Suggestion not found'; END IF;
  IF s.status <> 'pending' THEN RAISE EXCEPTION 'Suggestion already %', s.status; END IF;
  IF s.procurement_method = 'buy' THEN
    IF s.preferred_vendor_id IS NULL THEN RAISE EXCEPTION 'No preferred vendor; cannot create PO'; END IF;
    v_po_number := 'PO-' || to_char(now(),'YYYYMMDD') || '-' || substr(gen_random_uuid()::text,1,6);
    SELECT COALESCE(price_cents,0) INTO v_unit_price FROM products WHERE id = s.product_id;
    v_total := COALESCE(v_unit_price,0) * s.suggested_qty::int;
    INSERT INTO purchase_orders (po_number, vendor_id, status, order_date, expected_delivery, subtotal_cents, total_cents, created_by)
    VALUES (v_po_number, s.preferred_vendor_id, 'draft', CURRENT_DATE, s.needed_by, v_total, v_total, auth.uid())
    RETURNING id INTO v_po_id;
    INSERT INTO purchase_order_lines (purchase_order_id, product_id, quantity, unit_price_cents, total_cents)
    VALUES (v_po_id, s.product_id, s.suggested_qty::int, COALESCE(v_unit_price,0), v_total);
    UPDATE procurement_suggestions SET status='materialized', resolved_at=now(), resolved_by=auth.uid(),
      materialized_ref_type='purchase_order', materialized_ref_id=v_po_id WHERE id=p_id;
    RETURN jsonb_build_object('type','purchase_order','id',v_po_id,'po_number',v_po_number);
  ELSIF s.procurement_method = 'manufacture' THEN
    SELECT id INTO v_bom FROM bom_headers WHERE product_id = s.product_id AND is_active = true LIMIT 1;
    IF v_bom IS NULL THEN RAISE EXCEPTION 'No active BOM for product %', s.product_id; END IF;
    v_mo := create_manufacturing_order(v_bom, s.suggested_qty::int, s.needed_by);
    UPDATE procurement_suggestions SET status='materialized', resolved_at=now(), resolved_by=auth.uid(),
      materialized_ref_type='manufacturing_order', materialized_ref_id=v_mo WHERE id=p_id;
    RETURN jsonb_build_object('type','manufacturing_order','id',v_mo);
  END IF;
  RAISE EXCEPTION 'Unknown procurement_method %', s.procurement_method;
END; $function$

;

-- auto_allocate_vacation
CREATE OR REPLACE FUNCTION public.auto_allocate_vacation(p_year integer, p_dry_run boolean DEFAULT false)
 RETURNS TABLE(employee_id uuid, employee_name text, allocated_days integer, carried_over_days numeric, action text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_emp RECORD;
  v_days INTEGER;
  v_max_carry INTEGER;
  v_prev_remaining NUMERIC;
  v_carry NUMERIC;
  v_existing UUID;
  v_action TEXT;
  v_run_id UUID := gen_random_uuid();
  v_total INTEGER := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) THEN
    RAISE EXCEPTION 'Only admins can auto-allocate vacation';
  END IF;

  FOR v_emp IN
    SELECT id, name FROM public.employees WHERE status = 'active' ORDER BY name
  LOOP
    v_days := public.calculate_vacation_days(v_emp.id, p_year);

    SELECT max_carry_over_days INTO v_max_carry
    FROM public.vacation_policies
    WHERE is_active = true
    ORDER BY priority DESC LIMIT 1;
    v_max_carry := COALESCE(v_max_carry, 5);

    SELECT GREATEST(0,
      COALESCE(la.allocated_days, 0) + COALESCE(la.carried_over_days, 0)
      - COALESCE((
        SELECT SUM(days) FROM public.leave_requests
        WHERE employee_id = v_emp.id AND leave_type = 'vacation' AND status = 'approved'
          AND EXTRACT(YEAR FROM start_date)::INTEGER = p_year - 1
      ), 0)
    )
    INTO v_prev_remaining
    FROM public.leave_allocations la
    WHERE la.employee_id = v_emp.id AND la.leave_type = 'vacation' AND la.year = p_year - 1;

    v_carry := LEAST(COALESCE(v_prev_remaining, 0), v_max_carry);

    SELECT id INTO v_existing FROM public.leave_allocations
    WHERE employee_id = v_emp.id AND leave_type = 'vacation' AND year = p_year;

    v_action := CASE
      WHEN v_existing IS NOT NULL THEN (CASE WHEN p_dry_run THEN 'would_update' ELSE 'updated' END)
      ELSE (CASE WHEN p_dry_run THEN 'would_create' ELSE 'created' END)
    END;

    IF NOT p_dry_run THEN
      INSERT INTO public.leave_allocations (
        employee_id, leave_type, year, allocated_days, carried_over_days, notes
      ) VALUES (
        v_emp.id, 'vacation', p_year, v_days, v_carry,
        'Auto-allocated ' || to_char(now(), 'YYYY-MM-DD')
      )
      ON CONFLICT (employee_id, leave_type, year) DO UPDATE
      SET allocated_days = EXCLUDED.allocated_days,
          carried_over_days = EXCLUDED.carried_over_days,
          notes = EXCLUDED.notes,
          updated_at = now();

      INSERT INTO public.audit_logs (action, entity_type, entity_id, user_id, metadata)
      VALUES (
        'vacation.auto_allocated',
        'employee',
        v_emp.id,
        auth.uid(),
        jsonb_build_object(
          'run_id', v_run_id,
          'year', p_year,
          'employee_name', v_emp.name,
          'allocated_days', v_days,
          'carried_over_days', v_carry,
          'max_carry_over_cap', v_max_carry,
          'previous_year_remaining', v_prev_remaining,
          'action', v_action
        )
      );
      v_total := v_total + 1;
    END IF;

    employee_id := v_emp.id;
    employee_name := v_emp.name;
    allocated_days := v_days;
    carried_over_days := v_carry;
    action := v_action;
    RETURN NEXT;
  END LOOP;

  IF NOT p_dry_run AND v_total > 0 THEN
    INSERT INTO public.audit_logs (action, entity_type, user_id, metadata)
    VALUES (
      'vacation.auto_allocate_run',
      'leave_allocation',
      auth.uid(),
      jsonb_build_object('run_id', v_run_id, 'year', p_year, 'employees_processed', v_total)
    );
  END IF;
END;
$function$

;

-- auto_generate_purchase_orders
CREATE OR REPLACE FUNCTION public.auto_generate_purchase_orders(p_dry_run boolean DEFAULT false)
 RETURNS TABLE(po_id uuid, po_number text, vendor_id uuid, vendor_name text, line_count integer, total_cents bigint, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_vendor RECORD; v_line RECORD;
  v_po_id UUID; v_po_number TEXT;
  v_subtotal BIGINT; v_tax BIGINT;
  v_line_count INTEGER; v_skipped_count INTEGER;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::public.app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver'::public.app_role))) THEN
    RAISE EXCEPTION 'Only admins/approvers can auto-generate purchase orders';
  END IF;

  SELECT COUNT(*) INTO v_skipped_count
  FROM public.list_reorder_candidates() c WHERE c.vendor_id IS NULL;

  IF v_skipped_count > 0 THEN
    po_id := NULL; po_number := NULL; vendor_id := NULL;
    vendor_name := v_skipped_count::TEXT || ' product(s) skipped — no preferred vendor';
    line_count := 0; total_cents := 0; status := 'skipped';
    RETURN NEXT;
  END IF;

  FOR v_vendor IN
    SELECT c.vendor_id AS v_id, MAX(c.vendor_name) AS v_name
    FROM public.list_reorder_candidates() c
    WHERE c.vendor_id IS NOT NULL
    GROUP BY c.vendor_id
  LOOP
    v_subtotal := 0; v_tax := 0; v_line_count := 0;

    IF NOT p_dry_run THEN
      INSERT INTO public.purchase_orders (vendor_id, status, order_date, notes, created_by)
      VALUES (v_vendor.v_id, 'draft', CURRENT_DATE,
              'Auto-generated by inventory reorder loop on ' || CURRENT_DATE, auth.uid())
      RETURNING id, purchase_orders.po_number INTO v_po_id, v_po_number;

      FOR v_line IN
        SELECT * FROM public.list_reorder_candidates() c WHERE c.vendor_id = v_vendor.v_id
      LOOP
        INSERT INTO public.purchase_order_lines (
          purchase_order_id, product_id, description, quantity, unit_price_cents, tax_rate, total_cents)
        VALUES (
          v_po_id, v_line.product_id, v_line.product_name,
          v_line.reorder_quantity, v_line.unit_price_cents, 25.00,
          v_line.reorder_quantity * v_line.unit_price_cents);
        v_subtotal := v_subtotal + v_line.estimated_cost_cents;
        v_line_count := v_line_count + 1;
      END LOOP;

      v_tax := ROUND(v_subtotal * 0.25);
      UPDATE public.purchase_orders
      SET subtotal_cents = v_subtotal, tax_cents = v_tax,
          total_cents = v_subtotal + v_tax, updated_at = now()
      WHERE id = v_po_id;
    ELSE
      v_po_id := NULL;
      v_po_number := '(dry-run)';
      SELECT COUNT(*), COALESCE(SUM(c.estimated_cost_cents), 0)
        INTO v_line_count, v_subtotal
      FROM public.list_reorder_candidates() c WHERE c.vendor_id = v_vendor.v_id;
      v_tax := ROUND(v_subtotal * 0.25);
    END IF;

    po_id := v_po_id;
    po_number := v_po_number;
    vendor_id := v_vendor.v_id;
    vendor_name := v_vendor.v_name;
    line_count := v_line_count;
    total_cents := v_subtotal + v_tax;
    status := CASE WHEN p_dry_run THEN 'preview' ELSE 'created' END;
    RETURN NEXT;
  END LOOP;
END;
$function$

;

-- bulk_invoice_from_timesheets
CREATE OR REPLACE FUNCTION public.bulk_invoice_from_timesheets(p_project_id uuid, p_start_date date, p_end_date date, p_group_by text DEFAULT 'entry'::text, p_due_days integer DEFAULT 30)
 RETURNS TABLE(invoice_id uuid, invoice_number text, line_count integer, total_cents bigint, hours_billed numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_project public.projects;
  v_invoice_id UUID;
  v_invoice_num TEXT;
  v_line_items JSONB := '[]'::jsonb;
  v_subtotal BIGINT := 0;
  v_tax_rate NUMERIC := 0.25;
  v_tax_cents BIGINT;
  v_total_hours NUMERIC := 0;
  v_line_count INTEGER := 0;
  v_count INTEGER;
  v_entry RECORD;
  v_entry_ids UUID[] := '{}';
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::public.app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver'::public.app_role))) THEN
    RAISE EXCEPTION 'Only admins/approvers can bulk-invoice timesheets';
  END IF;

  SELECT * INTO v_project FROM public.projects WHERE id = p_project_id;
  IF v_project.id IS NULL THEN RAISE EXCEPTION 'Project not found'; END IF;
  IF NOT v_project.is_billable THEN RAISE EXCEPTION 'Project is not billable'; END IF;
  IF COALESCE(v_project.hourly_rate_cents, 0) <= 0 THEN RAISE EXCEPTION 'Project has no hourly rate set'; END IF;

  IF p_group_by = 'user' THEN
    FOR v_entry IN
      SELECT te.user_id, COALESCE(e.name, 'User') AS user_name, SUM(te.hours) AS total_hours, ARRAY_AGG(te.id) AS ids
      FROM public.time_entries te
      LEFT JOIN public.employees e ON e.user_id = te.user_id
      WHERE te.project_id = p_project_id AND te.entry_date BETWEEN p_start_date AND p_end_date
        AND te.is_billable = true AND te.is_invoiced = false
      GROUP BY te.user_id, e.name
    LOOP
      v_line_items := v_line_items || jsonb_build_object(
        'description', v_entry.user_name || ' — hours ' || to_char(p_start_date,'YYYY-MM-DD') || ' to ' || to_char(p_end_date,'YYYY-MM-DD'),
        'qty', v_entry.total_hours, 'unit_price_cents', v_project.hourly_rate_cents);
      v_subtotal := v_subtotal + ROUND(v_entry.total_hours * v_project.hourly_rate_cents);
      v_total_hours := v_total_hours + v_entry.total_hours;
      v_line_count := v_line_count + 1;
      v_entry_ids := v_entry_ids || v_entry.ids;
    END LOOP;
  ELSIF p_group_by = 'week' THEN
    FOR v_entry IN
      SELECT date_trunc('week', te.entry_date)::date AS week_start, SUM(te.hours) AS total_hours, ARRAY_AGG(te.id) AS ids
      FROM public.time_entries te
      WHERE te.project_id = p_project_id AND te.entry_date BETWEEN p_start_date AND p_end_date
        AND te.is_billable = true AND te.is_invoiced = false
      GROUP BY date_trunc('week', te.entry_date) ORDER BY week_start
    LOOP
      v_line_items := v_line_items || jsonb_build_object(
        'description', 'Week of ' || to_char(v_entry.week_start, 'YYYY-MM-DD'),
        'qty', v_entry.total_hours, 'unit_price_cents', v_project.hourly_rate_cents);
      v_subtotal := v_subtotal + ROUND(v_entry.total_hours * v_project.hourly_rate_cents);
      v_total_hours := v_total_hours + v_entry.total_hours;
      v_line_count := v_line_count + 1;
      v_entry_ids := v_entry_ids || v_entry.ids;
    END LOOP;
  ELSE
    FOR v_entry IN
      SELECT te.id, te.entry_date, te.hours, te.description
      FROM public.time_entries te
      WHERE te.project_id = p_project_id AND te.entry_date BETWEEN p_start_date AND p_end_date
        AND te.is_billable = true AND te.is_invoiced = false
      ORDER BY te.entry_date
    LOOP
      v_line_items := v_line_items || jsonb_build_object(
        'description', to_char(v_entry.entry_date,'YYYY-MM-DD') || ' — ' || COALESCE(v_entry.description, 'Hours'),
        'qty', v_entry.hours, 'unit_price_cents', v_project.hourly_rate_cents);
      v_subtotal := v_subtotal + ROUND(v_entry.hours * v_project.hourly_rate_cents);
      v_total_hours := v_total_hours + v_entry.hours;
      v_line_count := v_line_count + 1;
      v_entry_ids := v_entry_ids || v_entry.id;
    END LOOP;
  END IF;

  IF v_line_count = 0 THEN
    RAISE EXCEPTION 'No billable, uninvoiced hours found for project in given period';
  END IF;

  v_tax_cents := ROUND(v_subtotal * v_tax_rate);
  SELECT COUNT(*) INTO v_count FROM public.invoices;
  v_invoice_num := 'INV-' || LPAD((v_count + 1)::TEXT, 5, '0');

  INSERT INTO public.invoices (
    invoice_number, customer_name, project_id, line_items,
    subtotal_cents, tax_rate, tax_cents, total_cents,
    currency, issue_date, due_date, status, created_by, notes)
  VALUES (
    v_invoice_num, COALESCE(v_project.client_name, v_project.name), p_project_id, v_line_items,
    v_subtotal, v_tax_rate, v_tax_cents, v_subtotal + v_tax_cents,
    v_project.currency, CURRENT_DATE, CURRENT_DATE + p_due_days, 'draft', auth.uid(),
    'Auto-generated from timesheets ' || p_start_date || ' → ' || p_end_date)
  RETURNING id INTO v_invoice_id;

  UPDATE public.time_entries
  SET is_invoiced = true, invoice_id = v_invoice_id, updated_at = now()
  WHERE id = ANY(v_entry_ids);

  invoice_id := v_invoice_id;
  invoice_number := v_invoice_num;
  line_count := v_line_count;
  total_cents := v_subtotal + v_tax_cents;
  hours_billed := v_total_hours;
  RETURN NEXT;
END;
$function$

;

-- cancel_manual_subscription
CREATE OR REPLACE FUNCTION public.cancel_manual_subscription(_subscription_id uuid, _reason text DEFAULT NULL::text, _effective_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _eff date := COALESCE(_effective_date, CURRENT_DATE);
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) THEN
    RAISE EXCEPTION 'Only admins can cancel manual subscriptions';
  END IF;

  UPDATE public.subscriptions
  SET status = 'canceled'::subscription_status,
      canceled_at = now(),
      ended_at = _eff::timestamptz,
      cancel_at = _eff::timestamptz,
      next_invoice_date = NULL,
      metadata = metadata || jsonb_build_object('cancel_reason', _reason, 'canceled_by', auth.uid()),
      updated_at = now()
  WHERE id = _subscription_id AND provider = 'manual';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manual subscription % not found', _subscription_id;
  END IF;

  PERFORM public.emit_platform_event(
    'subscription.canceled',
    jsonb_build_object('subscription_id', _subscription_id, 'reason', _reason, 'effective_date', _eff),
    'cancel_manual_subscription'
  );

  RETURN jsonb_build_object('ok', true, 'subscription_id', _subscription_id, 'effective_date', _eff);
END $function$

;

-- cancel_mo
CREATE OR REPLACE FUNCTION public.cancel_mo(p_mo_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status public.mo_status;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT status INTO v_status FROM public.manufacturing_orders WHERE id = p_mo_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MO % not found', p_mo_id; END IF;

  IF v_status IN ('done', 'cancelled') THEN
    RETURN jsonb_build_object('success', true, 'mo_id', p_mo_id, 'note', 'already terminal: ' || v_status);
  END IF;

  UPDATE public.manufacturing_orders
     SET status = 'cancelled',
         cancelled_at = now(),
         notes = COALESCE(notes, '') || E'\n[cancelled] ' || COALESCE(p_reason, 'no reason'),
         updated_at = now()
   WHERE id = p_mo_id;

  BEGIN
    PERFORM public.emit_platform_event(
      'mo.cancelled',
      jsonb_build_object('mo_id', p_mo_id, 'reason', p_reason),
      'manufacturing'
    );
  EXCEPTION WHEN undefined_function THEN NULL; END;

  RETURN jsonb_build_object('success', true, 'mo_id', p_mo_id, 'status', 'cancelled');
END;
$function$

;

-- cancel_picking
CREATE OR REPLACE FUNCTION public.cancel_picking(p_picking_order_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_line RECORD;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'employee'))) THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  -- Release reservations
  FOR v_line IN SELECT * FROM public.picking_lines WHERE picking_order_id = p_picking_order_id AND reservation_id IS NOT NULL LOOP
    BEGIN
      PERFORM public.cancel_reservation(v_line.reservation_id);
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;

  UPDATE public.picking_lines
  SET status = 'cancelled'
  WHERE picking_order_id = p_picking_order_id AND status NOT IN ('picked','cancelled');

  UPDATE public.picking_orders
  SET status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason
  WHERE id = p_picking_order_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, user_id, metadata)
  VALUES ('picking.cancelled', 'picking_order', p_picking_order_id, auth.uid(),
    jsonb_build_object('reason', p_reason));

  RETURN jsonb_build_object('success', true, 'picking_order_id', p_picking_order_id);
END;
$function$

;

-- cancel_reservation
CREATE OR REPLACE FUNCTION public.cancel_reservation(p_reservation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r stock_reservations%ROWTYPE;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer'::app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role))) THEN RAISE EXCEPTION 'Insufficient privileges'; END IF;
  SELECT * INTO r FROM stock_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF r.state <> 'reserved' THEN RAISE EXCEPTION 'Reservation not in reserved state (%)', r.state; END IF;
  UPDATE stock_reservations SET state='cancelled', cancelled_at=now() WHERE id=p_reservation_id;
  UPDATE stock_quants SET reserved_quantity = GREATEST(0, COALESCE(reserved_quantity,0) - r.quantity), updated_at = now()
    WHERE product_id = r.product_id AND location_id = r.location_id AND (lot_id IS NOT DISTINCT FROM r.lot_id);
END; $function$

;

-- cancel_webinar
CREATE OR REPLACE FUNCTION public.cancel_webinar(p_webinar_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row webinars%ROWTYPE;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  UPDATE webinars SET status='cancelled', updated_at=now() WHERE id=p_webinar_id AND status NOT IN ('completed','cancelled') RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'webinar % cannot be cancelled', p_webinar_id; END IF;
  PERFORM emit_platform_event('webinar.cancelled', jsonb_build_object('webinar_id',v_row.id,'title',v_row.title,'reason',p_reason), 'webinars');
  RETURN jsonb_build_object('success',true,'id',v_row.id,'status',v_row.status);
END $function$

;

-- close_accounting_period
CREATE OR REPLACE FUNCTION public.close_accounting_period(p_year integer, p_month integer, p_notes text DEFAULT NULL::text)
 RETURNS accounting_periods
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row public.accounting_periods;
  v_start DATE;
  v_end DATE;
  v_total_debit BIGINT;
  v_total_credit BIGINT;
  v_count INTEGER;
  v_unposted INTEGER;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::public.app_role)) THEN
    RAISE EXCEPTION 'Only admins can close accounting periods';
  END IF;

  IF p_month NOT BETWEEN 1 AND 12 THEN
    RAISE EXCEPTION 'Invalid month: %', p_month;
  END IF;

  v_start := make_date(p_year, p_month, 1);
  v_end := (v_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE;

  -- Block close if any draft entries remain
  SELECT COUNT(*) INTO v_unposted
  FROM public.journal_entries
  WHERE entry_date BETWEEN v_start AND v_end
    AND status <> 'posted';
  IF v_unposted > 0 THEN
    RAISE EXCEPTION 'Cannot close: % unposted journal entries in %-%', v_unposted, p_year, p_month;
  END IF;

  -- Aggregate snapshot
  SELECT COALESCE(SUM(jel.debit_cents), 0),
         COALESCE(SUM(jel.credit_cents), 0),
         COUNT(DISTINCT je.id)
  INTO v_total_debit, v_total_credit, v_count
  FROM public.journal_entries je
  LEFT JOIN public.journal_entry_lines jel ON jel.journal_entry_id = je.id
  WHERE je.entry_date BETWEEN v_start AND v_end;

  -- Upsert
  INSERT INTO public.accounting_periods (
    fiscal_year, period_month, status,
    closed_by, closed_at,
    total_debit_cents, total_credit_cents, entry_count, notes
  )
  VALUES (
    p_year, p_month, 'closed',
    auth.uid(), now(),
    v_total_debit, v_total_credit, v_count, p_notes
  )
  ON CONFLICT (fiscal_year, period_month) DO UPDATE
  SET status = 'closed',
      closed_by = auth.uid(),
      closed_at = now(),
      reopened_by = NULL,
      reopened_at = NULL,
      total_debit_cents = EXCLUDED.total_debit_cents,
      total_credit_cents = EXCLUDED.total_credit_cents,
      entry_count = EXCLUDED.entry_count,
      notes = COALESCE(EXCLUDED.notes, public.accounting_periods.notes),
      updated_at = now()
  WHERE public.accounting_periods.status <> 'locked'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Period %-% is locked and cannot be closed again', p_year, p_month;
  END IF;

  RETURN v_row;
END;
$function$

;

-- complete_mo
CREATE OR REPLACE FUNCTION public.complete_mo(p_mo_id uuid, p_actual_qty numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mo         public.manufacturing_orders%ROWTYPE;
  v_qty        numeric;
  v_consumed   int := 0;
  v_comp       record;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT * INTO v_mo FROM public.manufacturing_orders WHERE id = p_mo_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MO % not found', p_mo_id; END IF;

  IF v_mo.status = 'done' THEN
    RETURN jsonb_build_object('success', true, 'mo_id', p_mo_id, 'note', 'already done');
  END IF;
  IF v_mo.status <> 'in_progress' THEN
    RAISE EXCEPTION 'MO must be in_progress to complete (current: %)', v_mo.status;
  END IF;

  v_qty := COALESCE(p_actual_qty, v_mo.quantity);

  -- Consume components: post negative stock_moves and decrement product_stock
  FOR v_comp IN SELECT component_product_id, qty_required FROM public.mo_components WHERE mo_id = p_mo_id
  LOOP
    INSERT INTO public.stock_moves (product_id, quantity, move_type, reference_type, reference_id, mo_id, created_by, notes)
    VALUES (v_comp.component_product_id, -CEIL(v_comp.qty_required)::int, 'mo_consumption',
            'manufacturing_order', p_mo_id::text, p_mo_id, auth.uid(),
            'Consumed for MO ' || v_mo.mo_number);

    UPDATE public.product_stock
       SET quantity_on_hand = GREATEST(quantity_on_hand - CEIL(v_comp.qty_required)::int, 0),
           updated_at = now()
     WHERE product_id = v_comp.component_product_id;

    UPDATE public.mo_components SET qty_consumed = v_comp.qty_required
     WHERE mo_id = p_mo_id AND component_product_id = v_comp.component_product_id;

    v_consumed := v_consumed + 1;
  END LOOP;

  -- Produce finished good
  INSERT INTO public.stock_moves (product_id, quantity, move_type, reference_type, reference_id, mo_id, created_by, notes)
  VALUES (v_mo.product_id, CEIL(v_qty)::int, 'mo_production',
          'manufacturing_order', p_mo_id::text, p_mo_id, auth.uid(),
          'Produced by MO ' || v_mo.mo_number);

  INSERT INTO public.product_stock (product_id, quantity_on_hand)
  VALUES (v_mo.product_id, CEIL(v_qty)::int)
  ON CONFLICT (product_id) DO UPDATE
    SET quantity_on_hand = public.product_stock.quantity_on_hand + EXCLUDED.quantity_on_hand,
        updated_at = now();

  UPDATE public.manufacturing_orders
     SET status = 'done', completed_at = now(), updated_at = now()
   WHERE id = p_mo_id;

  -- Emit event
  BEGIN
    PERFORM public.emit_platform_event(
      'mo.completed',
      jsonb_build_object('mo_id', p_mo_id, 'qty_produced', v_qty, 'components_consumed', v_consumed),
      'manufacturing'
    );
  EXCEPTION WHEN undefined_function THEN NULL; END;

  RETURN jsonb_build_object('success', true, 'mo_id', p_mo_id, 'qty_produced', v_qty, 'components_consumed', v_consumed);
END;
$function$

;

-- complete_webinar
CREATE OR REPLACE FUNCTION public.complete_webinar(p_webinar_id uuid, p_recording_url text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row webinars%ROWTYPE;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  UPDATE webinars SET status='completed', recording_url=COALESCE(p_recording_url,recording_url), updated_at=now()
   WHERE id=p_webinar_id AND status IN ('live','published') RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'webinar % cannot be completed', p_webinar_id; END IF;
  PERFORM emit_platform_event('webinar.completed', jsonb_build_object('webinar_id',v_row.id,'title',v_row.title,'recording_url',v_row.recording_url), 'webinars');
  RETURN jsonb_build_object('success',true,'id',v_row.id,'status',v_row.status);
END $function$

;

-- confirm_mo
CREATE OR REPLACE FUNCTION public.confirm_mo(p_mo_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_mo         public.manufacturing_orders%ROWTYPE;
  v_bom_id     uuid;
  v_bom_qty    numeric;
  v_factor     numeric;
  v_shortages  jsonb := '[]'::jsonb;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT * INTO v_mo FROM public.manufacturing_orders WHERE id = p_mo_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MO % not found', p_mo_id; END IF;

  IF v_mo.status NOT IN ('draft', 'planned') THEN
    -- Idempotent re-check
    PERFORM public.check_mo_availability(p_mo_id);
    RETURN jsonb_build_object('success', true, 'mo_id', p_mo_id, 'status', v_mo.status, 'note', 'already confirmed');
  END IF;

  -- Resolve BOM (use stored bom_id, else active)
  v_bom_id := v_mo.bom_id;
  IF v_bom_id IS NULL THEN
    SELECT id, quantity_produced INTO v_bom_id, v_bom_qty
      FROM public.bom_headers
     WHERE product_id = v_mo.product_id AND is_active = true
     LIMIT 1;
    IF v_bom_id IS NULL THEN
      RAISE EXCEPTION 'No active BOM for product %', v_mo.product_id;
    END IF;
    UPDATE public.manufacturing_orders SET bom_id = v_bom_id WHERE id = p_mo_id;
  ELSE
    SELECT quantity_produced INTO v_bom_qty FROM public.bom_headers WHERE id = v_bom_id;
  END IF;

  v_factor := v_mo.quantity / NULLIF(v_bom_qty, 0);

  -- Snapshot components
  DELETE FROM public.mo_components WHERE mo_id = p_mo_id;
  INSERT INTO public.mo_components (mo_id, component_product_id, qty_required, availability)
  SELECT p_mo_id,
         bl.component_product_id,
         ROUND(bl.quantity * v_factor * (1 + bl.scrap_pct / 100.0), 4),
         'unknown'
    FROM public.bom_lines bl
   WHERE bl.bom_id = v_bom_id;

  UPDATE public.manufacturing_orders
     SET status = 'confirmed', updated_at = now()
   WHERE id = p_mo_id;

  -- Compute availability now
  v_shortages := (public.check_mo_availability(p_mo_id))->'shortages';

  -- Emit event (best-effort; helper exists per memory)
  BEGIN
    PERFORM public.emit_platform_event(
      'mo.confirmed',
      jsonb_build_object('mo_id', p_mo_id, 'shortages', v_shortages),
      'manufacturing'
    );
  EXCEPTION WHEN undefined_function THEN NULL; END;

  RETURN jsonb_build_object(
    'success', true,
    'mo_id', p_mo_id,
    'bom_id', v_bom_id,
    'shortages', v_shortages
  );
END;
$function$

;

-- consume_reservation
CREATE OR REPLACE FUNCTION public.consume_reservation(p_reservation_id uuid, p_to_location_code text DEFAULT 'WH/CUSTOMERS'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r stock_reservations%ROWTYPE; v_to uuid; v_move uuid;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer'::app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role))) THEN RAISE EXCEPTION 'Insufficient privileges'; END IF;
  SELECT * INTO r FROM stock_reservations WHERE id = p_reservation_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reservation not found'; END IF;
  IF r.state <> 'reserved' THEN RAISE EXCEPTION 'Reservation not in reserved state'; END IF;
  SELECT id INTO v_to FROM stock_locations WHERE code = p_to_location_code;
  IF v_to IS NULL THEN RAISE EXCEPTION 'Destination location % not found', p_to_location_code; END IF;
  UPDATE stock_quants SET reserved_quantity = GREATEST(0, COALESCE(reserved_quantity,0) - r.quantity), updated_at = now()
    WHERE product_id = r.product_id AND location_id = r.location_id AND (lot_id IS NOT DISTINCT FROM r.lot_id);
  PERFORM _upsert_quant(r.product_id, r.location_id, r.lot_id, -r.quantity);
  PERFORM _upsert_quant(r.product_id, v_to, r.lot_id, r.quantity);
  INSERT INTO stock_moves (product_id, quantity, move_type, from_location_id, to_location_id, lot_id, reference_type, reference_id, created_by, state)
  VALUES (r.product_id, r.quantity::int, 'reservation_consumed', r.location_id, v_to, r.lot_id, r.reference_type, r.reference_id, auth.uid(), 'done')
  RETURNING id INTO v_move;
  UPDATE stock_reservations SET state='consumed', consumed_at=now() WHERE id=p_reservation_id;
  RETURN v_move;
END; $function$

;

-- create_bom
CREATE OR REPLACE FUNCTION public.create_bom(p_product_id uuid, p_lines jsonb, p_version text DEFAULT NULL::text, p_quantity_produced numeric DEFAULT 1, p_routing_notes text DEFAULT NULL::text, p_activate boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_bom_id  uuid;
  v_version text;
  v_line    jsonb;
  v_pos     int := 0;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  IF p_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id is required';
  END IF;
  IF p_lines IS NULL OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'lines must contain at least one component';
  END IF;

  -- Auto-version: v1, v2, ...
  IF p_version IS NULL OR trim(p_version) = '' THEN
    SELECT 'v' || (COALESCE(COUNT(*), 0) + 1)::text
      INTO v_version
      FROM public.bom_headers WHERE product_id = p_product_id;
  ELSE
    v_version := p_version;
  END IF;

  -- Deactivate other versions if activating this one
  IF p_activate THEN
    UPDATE public.bom_headers SET is_active = false WHERE product_id = p_product_id AND is_active = true;
  END IF;

  INSERT INTO public.bom_headers (product_id, version, is_active, quantity_produced, routing_notes, created_by)
  VALUES (p_product_id, v_version, p_activate, COALESCE(p_quantity_produced, 1), p_routing_notes, auth.uid())
  RETURNING id INTO v_bom_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_pos := v_pos + 1;
    INSERT INTO public.bom_lines (bom_id, component_product_id, quantity, unit, scrap_pct, position)
    VALUES (
      v_bom_id,
      (v_line->>'component_product_id')::uuid,
      (v_line->>'quantity')::numeric,
      v_line->>'unit',
      COALESCE((v_line->>'scrap_pct')::numeric, 0),
      COALESCE((v_line->>'position')::int, v_pos)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'bom_id', v_bom_id,
    'version', v_version,
    'line_count', jsonb_array_length(p_lines)
  );
END;
$function$

;

-- create_manual_subscription
CREATE OR REPLACE FUNCTION public.create_manual_subscription(_customer_email text, _customer_name text, _product_name text, _unit_amount_cents integer, _currency text DEFAULT 'EUR'::text, _billing_interval text DEFAULT 'month'::text, _billing_interval_count integer DEFAULT 1, _quantity integer DEFAULT 1, _payment_terms text DEFAULT 'invoice_30'::text, _start_date date DEFAULT CURRENT_DATE, _billing_contact_email text DEFAULT NULL::text, _po_number text DEFAULT NULL::text, _product_id uuid DEFAULT NULL::uuid, _auto_finalize boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _new_id uuid;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) THEN
    RAISE EXCEPTION 'Only admins can create manual subscriptions';
  END IF;

  IF _customer_email IS NULL OR length(trim(_customer_email)) = 0 THEN
    RAISE EXCEPTION 'customer_email is required';
  END IF;
  IF _unit_amount_cents IS NULL OR _unit_amount_cents <= 0 THEN
    RAISE EXCEPTION 'unit_amount_cents must be > 0';
  END IF;

  INSERT INTO public.subscriptions (
    customer_email, customer_name, product_name, product_id,
    unit_amount_cents, currency, quantity,
    billing_interval, billing_interval_count,
    payment_terms, billing_contact_email, po_number,
    provider, status,
    current_period_start, current_period_end, next_invoice_date,
    auto_finalize,
    metadata
  ) VALUES (
    lower(trim(_customer_email)), _customer_name, _product_name, _product_id,
    _unit_amount_cents, lower(_currency), GREATEST(1, _quantity),
    lower(_billing_interval), GREATEST(1, _billing_interval_count),
    _payment_terms, _billing_contact_email, _po_number,
    'manual', 'active'::subscription_status,
    _start_date::timestamptz,
    advance_billing_date(_start_date, _billing_interval, _billing_interval_count)::timestamptz,
    _start_date,
    COALESCE(_auto_finalize, false),
    jsonb_build_object('created_via', 'create_manual_subscription', 'created_by', auth.uid(), 'auto_finalize', COALESCE(_auto_finalize, false))
  )
  RETURNING id INTO _new_id;

  PERFORM public.emit_platform_event(
    'subscription.created',
    jsonb_build_object('subscription_id', _new_id, 'provider', 'manual', 'customer_email', _customer_email, 'auto_finalize', COALESCE(_auto_finalize, false)),
    'create_manual_subscription'
  );

  RETURN jsonb_build_object('ok', true, 'subscription_id', _new_id, 'next_invoice_date', _start_date, 'auto_finalize', COALESCE(_auto_finalize, false));
END $function$

;

-- generate_subscription_invoice
CREATE OR REPLACE FUNCTION public.generate_subscription_invoice(_subscription_id uuid, _tax_rate numeric DEFAULT NULL::numeric, _due_in_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _sub public.subscriptions%ROWTYPE;
  _invoice_id uuid;
  _invoice_number text;
  _subtotal integer;
  _tax integer;
  _total integer;
  _rate numeric;
  _due integer;
  _due_date date;
  _next date;
  _line jsonb;
  _status invoice_status;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Only admins or system can generate subscription invoices';
  END IF;

  SELECT * INTO _sub FROM public.subscriptions WHERE id = _subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription % not found', _subscription_id;
  END IF;

  IF _sub.provider <> 'manual' THEN
    RAISE EXCEPTION 'generate_subscription_invoice only applies to manual subscriptions (got %)', _sub.provider;
  END IF;

  IF _sub.status <> 'active'::subscription_status THEN
    RAISE EXCEPTION 'Cannot invoice subscription in status %', _sub.status;
  END IF;

  _subtotal := _sub.unit_amount_cents * COALESCE(_sub.quantity, 1);
  _rate := COALESCE(_tax_rate, 0.25);
  _tax := round(_subtotal * _rate)::integer;
  _total := _subtotal + _tax;

  _due := COALESCE(
    _due_in_days,
    CASE _sub.payment_terms
      WHEN 'invoice_30' THEN 30
      WHEN 'invoice_14' THEN 14
      WHEN 'invoice_7'  THEN 7
      ELSE 30
    END
  );
  _due_date := CURRENT_DATE + _due;

  _invoice_number := 'SUB-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || lpad(floor(random()*100000)::text, 5, '0');

  _line := jsonb_build_array(jsonb_build_object(
    'description', _sub.product_name || ' (' ||
      to_char(COALESCE(_sub.current_period_start, now()), 'YYYY-MM-DD') || ' → ' ||
      to_char(COALESCE(_sub.current_period_end, now()), 'YYYY-MM-DD') || ')',
    'quantity', _sub.quantity,
    'unit_price_cents', _sub.unit_amount_cents,
    'total_cents', _subtotal
  ));

  -- Honor auto_finalize: if true, issue invoice as 'sent' immediately
  _status := CASE WHEN COALESCE(_sub.auto_finalize, false) THEN 'sent'::invoice_status ELSE 'draft'::invoice_status END;

  INSERT INTO public.invoices (
    invoice_number, customer_email, customer_name,
    status, line_items, subtotal_cents, tax_rate, tax_cents, total_cents,
    currency, due_date, issue_date, payment_terms, notes,
    sent_at
  ) VALUES (
    _invoice_number, _sub.customer_email, _sub.customer_name,
    _status, _line, _subtotal, _rate, _tax, _total,
    upper(_sub.currency), _due_date, CURRENT_DATE,
    'Net ' || _due || ' days',
    'Generated from subscription ' || _sub.id::text ||
      CASE WHEN _sub.po_number IS NOT NULL THEN E'\nPO: ' || _sub.po_number ELSE '' END,
    CASE WHEN _status = 'sent'::invoice_status THEN now() ELSE NULL END
  )
  RETURNING id INTO _invoice_id;

  _next := advance_billing_date(CURRENT_DATE, _sub.billing_interval, _sub.billing_interval_count);

  UPDATE public.subscriptions
  SET last_invoice_id = _invoice_id,
      current_period_start = COALESCE(current_period_end, now()),
      current_period_end = _next::timestamptz,
      next_invoice_date = _next,
      updated_at = now()
  WHERE id = _subscription_id;

  PERFORM public.emit_platform_event(
    'subscription.invoiced',
    jsonb_build_object(
      'subscription_id', _subscription_id,
      'invoice_id', _invoice_id,
      'invoice_number', _invoice_number,
      'total_cents', _total,
      'currency', upper(_sub.currency),
      'auto_finalized', COALESCE(_sub.auto_finalize, false),
      'status', _status
    ),
    'generate_subscription_invoice'
  );

  IF _status = 'sent'::invoice_status THEN
    PERFORM public.emit_platform_event(
      'invoice.finalized',
      jsonb_build_object(
        'invoice_id', _invoice_id,
        'invoice_number', _invoice_number,
        'subscription_id', _subscription_id,
        'total_cents', _total,
        'currency', upper(_sub.currency),
        'source', 'subscription_auto_finalize'
      ),
      'generate_subscription_invoice'
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'invoice_id', _invoice_id,
    'invoice_number', _invoice_number,
    'status', _status,
    'auto_finalized', COALESCE(_sub.auto_finalize, false),
    'total_cents', _total,
    'next_invoice_date', _next
  );
END $function$

;

-- hire_application
CREATE OR REPLACE FUNCTION public.hire_application(p_application_id uuid, p_start_date date DEFAULT NULL::date, p_monthly_salary_cents bigint DEFAULT NULL::bigint, p_contract_template_id uuid DEFAULT NULL::uuid, p_onboarding_template_id uuid DEFAULT NULL::uuid, p_department text DEFAULT NULL::text, p_manager_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(application_id uuid, employee_id uuid, employment_contract_id uuid, onboarding_checklist_id uuid, contract_status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_app public.applications;
  v_job public.job_postings;
  v_emp_id UUID;
  v_contract_id UUID;
  v_onboard_id UUID;
  v_template public.employment_contract_templates;
  v_onb_template UUID;
  v_start_date DATE;
  v_salary BIGINT;
  v_dept TEXT;
  v_emp_type TEXT;
  v_body TEXT;
  v_probation_end DATE;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::public.app_role))
       OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver'::public.app_role))) THEN
    RAISE EXCEPTION 'Only admins/approvers can hire candidates';
  END IF;

  SELECT * INTO v_app FROM public.applications WHERE id = p_application_id FOR UPDATE;
  IF v_app.id IS NULL THEN RAISE EXCEPTION 'Application not found'; END IF;
  IF v_app.employee_id IS NOT NULL THEN
    RAISE EXCEPTION 'Application already hired (employee_id=%)', v_app.employee_id;
  END IF;

  SELECT * INTO v_job FROM public.job_postings WHERE id = v_app.job_posting_id;

  v_start_date := COALESCE(p_start_date, CURRENT_DATE + INTERVAL '14 days');
  v_dept := COALESCE(p_department, v_job.department, 'General');
  v_emp_type := COALESCE(v_job.employment_type::TEXT, 'full_time');
  v_salary := COALESCE(p_monthly_salary_cents,
    NULLIF((COALESCE(v_job.salary_min_cents,0) + COALESCE(v_job.salary_max_cents,0)) / 2, 0),
    v_job.salary_min_cents);

  INSERT INTO public.employees (
    name, email, phone, title, department, employment_type,
    start_date, status, manager_id, created_by
  ) VALUES (
    v_app.candidate_name, v_app.candidate_email, v_app.candidate_phone,
    COALESCE(v_job.title, 'Employee'), v_dept, v_emp_type,
    v_start_date, 'active', p_manager_id, auth.uid()
  ) RETURNING id INTO v_emp_id;

  IF p_contract_template_id IS NOT NULL THEN
    SELECT * INTO v_template FROM public.employment_contract_templates WHERE id = p_contract_template_id;
  ELSE
    SELECT * INTO v_template FROM public.employment_contract_templates
    WHERE is_active = true AND is_default = true LIMIT 1;
    IF v_template.id IS NULL THEN
      SELECT * INTO v_template FROM public.employment_contract_templates
      WHERE is_active = true ORDER BY created_at LIMIT 1;
    END IF;
  END IF;

  v_body := COALESCE(v_template.body_markdown, '# Employment Agreement' || E'\n\nEmployee: ' || v_app.candidate_name);
  v_body := REPLACE(v_body, '{{employee_name}}', v_app.candidate_name);
  v_body := REPLACE(v_body, '{{title}}', COALESCE(v_job.title, ''));
  v_body := REPLACE(v_body, '{{department}}', v_dept);
  v_body := REPLACE(v_body, '{{start_date}}', to_char(v_start_date, 'YYYY-MM-DD'));
  v_body := REPLACE(v_body, '{{monthly_salary}}', COALESCE((v_salary / 100)::TEXT, 'TBD'));

  v_probation_end := v_start_date + (COALESCE(v_template.default_probation_months, 6) || ' months')::INTERVAL;

  INSERT INTO public.employment_contracts (
    employee_id, template_id, title, employment_type,
    start_date, probation_end_date, notice_period_days,
    monthly_salary_cents, currency, body_markdown, status, created_by, metadata
  ) VALUES (
    v_emp_id, v_template.id,
    'Employment Agreement — ' || v_app.candidate_name,
    COALESCE(v_template.employment_type, 'permanent'),
    v_start_date, v_probation_end,
    COALESCE(v_template.default_notice_period_days, 30),
    v_salary, COALESCE(v_job.currency, 'SEK'), v_body, 'draft', auth.uid(),
    jsonb_build_object('source','auto_hire','application_id',p_application_id,'job_posting_id',v_app.job_posting_id)
  ) RETURNING id INTO v_contract_id;

  v_onb_template := p_onboarding_template_id;
  IF v_onb_template IS NULL THEN
    SELECT id INTO v_onb_template FROM public.onboarding_templates
    WHERE is_active = true
      AND (department IS NULL OR department = v_dept)
      AND (employment_type IS NULL OR employment_type = v_emp_type)
    ORDER BY (department = v_dept) DESC NULLS LAST,
             (employment_type = v_emp_type) DESC NULLS LAST,
             is_default DESC, created_at LIMIT 1;
  END IF;

  IF v_onb_template IS NOT NULL THEN
    INSERT INTO public.onboarding_checklists (employee_id, title, items, created_by)
    SELECT v_emp_id, name, items, auth.uid()
    FROM public.onboarding_templates WHERE id = v_onb_template
    RETURNING id INTO v_onboard_id;
  END IF;

  UPDATE public.applications
  SET employee_id = v_emp_id, hired_at = now(), stage = 'hired', updated_at = now()
  WHERE id = p_application_id;

  application_id := p_application_id;
  employee_id := v_emp_id;
  employment_contract_id := v_contract_id;
  onboarding_checklist_id := v_onboard_id;
  contract_status := 'draft';
  RETURN NEXT;
END;
$function$

;

-- lock_timesheet_period
CREATE OR REPLACE FUNCTION public.lock_timesheet_period(p_fiscal_year integer, p_period_month integer, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _lock_id uuid;
  _entry_count integer;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Only admins can lock timesheet periods';
  END IF;
  IF p_fiscal_year IS NULL OR p_period_month IS NULL THEN
    RAISE EXCEPTION 'fiscal_year and period_month are required';
  END IF;
  IF p_period_month < 1 OR p_period_month > 12 THEN
    RAISE EXCEPTION 'period_month must be 1-12 (got %)', p_period_month;
  END IF;

  INSERT INTO public.timesheet_period_locks (fiscal_year, period_month, notes, locked_by)
  VALUES (p_fiscal_year, p_period_month, p_notes, auth.uid())
  ON CONFLICT (fiscal_year, period_month)
  DO UPDATE SET notes = COALESCE(EXCLUDED.notes, public.timesheet_period_locks.notes),
                locked_at = now(),
                locked_by = auth.uid()
  RETURNING id INTO _lock_id;

  SELECT count(*) INTO _entry_count
  FROM public.time_entries
  WHERE date_part('year', entry_date) = p_fiscal_year
    AND date_part('month', entry_date) = p_period_month;

  PERFORM public.emit_platform_event(
    'timesheet.period_locked',
    jsonb_build_object('fiscal_year', p_fiscal_year, 'period_month', p_period_month, 'entries_locked', _entry_count),
    'lock_timesheet_period'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'lock_id', _lock_id,
    'fiscal_year', p_fiscal_year,
    'period_month', p_period_month,
    'entries_locked', _entry_count
  );
END $function$

;

-- mark_webinar_attendance
CREATE OR REPLACE FUNCTION public.mark_webinar_attendance(p_registration_id uuid, p_attended boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_reg webinar_registrations%ROWTYPE;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  UPDATE webinar_registrations SET attended=p_attended WHERE id=p_registration_id RETURNING * INTO v_reg;
  IF NOT FOUND THEN RAISE EXCEPTION 'registration % not found', p_registration_id; END IF;
  IF p_attended AND v_reg.lead_id IS NOT NULL THEN
    UPDATE leads SET score = COALESCE(score,0) + 10, updated_at=now() WHERE id = v_reg.lead_id;
  END IF;
  PERFORM emit_platform_event('webinar.attended', jsonb_build_object('webinar_id',v_reg.webinar_id,'registration_id',v_reg.id,'lead_id',v_reg.lead_id,'attended',p_attended), 'webinars');
  RETURN jsonb_build_object('success',true,'id',v_reg.id,'attended',p_attended);
END $function$

;

-- procurement_run
CREATE OR REPLACE FUNCTION public.procurement_run()
 RETURNS TABLE(suggestions_created integer, rules_evaluated integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rule record; v_on_hand numeric; v_reserved numeric; v_incoming numeric; v_virtual numeric; v_qty_to_order numeric; v_count integer := 0; v_evaluated integer := 0;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer'::app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role))) THEN RAISE EXCEPTION 'Insufficient privileges'; END IF;
  FOR v_rule IN SELECT * FROM reorder_rules WHERE is_active = true LOOP
    v_evaluated := v_evaluated + 1;
    SELECT COALESCE(SUM(quantity),0), COALESCE(SUM(reserved_quantity),0) INTO v_on_hand, v_reserved
      FROM stock_quants WHERE product_id = v_rule.product_id AND location_id = v_rule.location_id;
    SELECT COALESCE(SUM(pol.quantity - COALESCE(pol.received_quantity,0)),0) INTO v_incoming
      FROM purchase_order_lines pol JOIN purchase_orders po ON po.id = pol.purchase_order_id
      WHERE pol.product_id = v_rule.product_id AND po.status IN ('draft','sent','confirmed','partial');
    v_virtual := v_on_hand - v_reserved + COALESCE(v_incoming,0);
    IF v_virtual < v_rule.min_qty THEN
      v_qty_to_order := COALESCE(NULLIF(v_rule.reorder_qty,0), v_rule.max_qty - v_virtual);
      IF v_qty_to_order <= 0 THEN v_qty_to_order := v_rule.min_qty - v_virtual; END IF;
      IF NOT EXISTS (SELECT 1 FROM procurement_suggestions WHERE product_id = v_rule.product_id AND location_id = v_rule.location_id AND status = 'pending') THEN
        INSERT INTO procurement_suggestions (product_id, location_id, suggested_qty, procurement_method, preferred_vendor_id, needed_by, reasoning)
        VALUES (v_rule.product_id, v_rule.location_id, v_qty_to_order, v_rule.procurement_method, v_rule.preferred_vendor_id,
          (CURRENT_DATE + (v_rule.lead_time_days || ' days')::interval)::date,
          jsonb_build_object('on_hand', v_on_hand, 'reserved', v_reserved, 'incoming', v_incoming, 'virtual', v_virtual, 'min_qty', v_rule.min_qty, 'max_qty', v_rule.max_qty));
        v_count := v_count + 1;
      END IF;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_count, v_evaluated;
END; $function$

;

-- publish_webinar
CREATE OR REPLACE FUNCTION public.publish_webinar(p_webinar_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row webinars%ROWTYPE;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  UPDATE webinars SET status='published', updated_at=now() WHERE id=p_webinar_id AND status='draft' RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'webinar % not found or not in draft', p_webinar_id; END IF;
  PERFORM emit_platform_event('webinar.published', jsonb_build_object('webinar_id',v_row.id,'title',v_row.title,'date',v_row.date), 'webinars');
  RETURN jsonb_build_object('success',true,'id',v_row.id,'status',v_row.status);
END $function$

;

-- reject_procurement_suggestion
CREATE OR REPLACE FUNCTION public.reject_procurement_suggestion(p_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) THEN RAISE EXCEPTION 'Only admins can reject suggestions'; END IF;
  UPDATE procurement_suggestions SET status='rejected', resolved_at=now(), resolved_by=auth.uid(),
    reasoning = COALESCE(reasoning,'{}'::jsonb) || jsonb_build_object('rejection_reason', p_reason)
    WHERE id = p_id AND status = 'pending';
END; $function$

;

-- reopen_accounting_period
CREATE OR REPLACE FUNCTION public.reopen_accounting_period(p_year integer, p_month integer, p_reason text DEFAULT NULL::text)
 RETURNS accounting_periods
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row public.accounting_periods;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::public.app_role)) THEN
    RAISE EXCEPTION 'Only admins can reopen accounting periods';
  END IF;

  UPDATE public.accounting_periods
  SET status = 'open',
      reopened_by = auth.uid(),
      reopened_at = now(),
      notes = CASE WHEN p_reason IS NOT NULL
                   THEN COALESCE(notes, '') || E'\n[reopened] ' || p_reason
                   ELSE notes END,
      updated_at = now()
  WHERE fiscal_year = p_year
    AND period_month = p_month
    AND status = 'closed'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Period %-% not found, already open, or permanently locked', p_year, p_month;
  END IF;

  RETURN v_row;
END;
$function$

;

-- reserve_stock
CREATE OR REPLACE FUNCTION public.reserve_stock(p_product_id uuid, p_location_id uuid, p_quantity numeric, p_reference_type text DEFAULT NULL::text, p_reference_id text DEFAULT NULL::text, p_lot_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_avail numeric; v_reserved numeric;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer'::app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role))) THEN RAISE EXCEPTION 'Insufficient privileges'; END IF;
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;
  SELECT COALESCE(quantity,0), COALESCE(reserved_quantity,0) INTO v_avail, v_reserved
    FROM stock_quants WHERE product_id = p_product_id AND location_id = p_location_id AND (lot_id IS NOT DISTINCT FROM p_lot_id);
  IF (COALESCE(v_avail,0) - COALESCE(v_reserved,0)) < p_quantity THEN
    RAISE EXCEPTION 'Insufficient available stock to reserve (free %, need %)', (COALESCE(v_avail,0) - COALESCE(v_reserved,0)), p_quantity;
  END IF;
  INSERT INTO stock_reservations (product_id, location_id, lot_id, quantity, reference_type, reference_id, reserved_by, notes)
  VALUES (p_product_id, p_location_id, p_lot_id, p_quantity, p_reference_type, p_reference_id, auth.uid(), p_notes) RETURNING id INTO v_id;
  UPDATE stock_quants SET reserved_quantity = COALESCE(reserved_quantity,0) + p_quantity, updated_at = now()
    WHERE product_id = p_product_id AND location_id = p_location_id AND (lot_id IS NOT DISTINCT FROM p_lot_id);
  RETURN v_id;
END; $function$

;

-- reset_module_data
CREATE OR REPLACE FUNCTION public.reset_module_data(p_module text, p_dry_run boolean DEFAULT true, p_run_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  PROTECTED_TABLES text[] := ARRAY[
    'pages','agent_skills','agent_objectives','agent_memory','site_settings','contract_templates',
    'quote_templates','locale_packs','user_roles','profiles'
  ];
  v_module text;
  v_counts jsonb := '{}'::jsonb;
  v_tbl text;
  v_count int;
  v_total int := 0;
  v_sql text;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) THEN
    RAISE EXCEPTION 'Only admins can reset demo data';
  END IF;

  v_module := lower(trim(p_module));

  FOR v_tbl, v_count IN
    SELECT i.table_name, count(*)::int
    FROM public.demo_run_items i
    JOIN public.demo_runs r ON r.id = i.run_id
    WHERE (v_module = 'all' OR r.module = v_module)
      AND (p_run_id IS NULL OR r.id = p_run_id)
    GROUP BY i.table_name
  LOOP
    IF v_tbl = ANY(PROTECTED_TABLES) THEN
      CONTINUE;
    END IF;
    v_counts := v_counts || jsonb_build_object(v_tbl, v_count);
    v_total := v_total + v_count;

    IF NOT p_dry_run THEN
      v_sql := format(
        'DELETE FROM public.%I WHERE id IN (
           SELECT i.row_id FROM public.demo_run_items i
           JOIN public.demo_runs r ON r.id = i.run_id
           WHERE i.table_name = %L
             AND (%L = ''all'' OR r.module = %L)
             AND (%L::uuid IS NULL OR r.id = %L::uuid)
         )',
        v_tbl, v_tbl, v_module, v_module, p_run_id, p_run_id
      );
      EXECUTE v_sql;
    END IF;
  END LOOP;

  IF NOT p_dry_run THEN
    DELETE FROM public.demo_runs r
    WHERE (v_module = 'all' OR r.module = v_module)
      AND (p_run_id IS NULL OR r.id = p_run_id);
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'dry_run', p_dry_run,
    'module', v_module,
    'run_id', p_run_id,
    'total_rows', v_total,
    'counts_by_table', v_counts
  );
END $function$

;

-- send_dunning_reminders
CREATE OR REPLACE FUNCTION public.send_dunning_reminders(p_dry_run boolean DEFAULT false)
 RETURNS TABLE(invoice_id uuid, invoice_number text, customer_email text, days_overdue integer, dunning_step text, total_cents bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_inv RECORD; v_step TEXT; v_days INTEGER;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::public.app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver'::public.app_role))) THEN
    RAISE EXCEPTION 'Only admins/approvers can send dunning reminders';
  END IF;

  FOR v_inv IN
    SELECT i.id, i.invoice_number, i.customer_email, i.due_date, i.total_cents, i.status
    FROM public.invoices i
    WHERE i.status IN ('sent', 'overdue') AND i.due_date < CURRENT_DATE AND i.paid_at IS NULL
    ORDER BY i.due_date ASC
  LOOP
    v_days := (CURRENT_DATE - v_inv.due_date)::INTEGER;
    v_step := CASE
      WHEN v_days >= 30 THEN 'final_notice'
      WHEN v_days >= 14 THEN 'formal_reminder'
      WHEN v_days >= 7  THEN 'friendly_reminder'
      ELSE 'pre_reminder' END;

    IF NOT p_dry_run THEN
      UPDATE public.invoices SET status = 'overdue', updated_at = now()
      WHERE id = v_inv.id AND status = 'sent';

      INSERT INTO public.dunning_actions (invoice_id, step_name, action_type, status, executed_at, metadata)
      SELECT v_inv.id, v_step, 'email', 'sent', now(),
             jsonb_build_object('days_overdue', v_days, 'auto', true)
      WHERE NOT EXISTS (
        SELECT 1 FROM public.dunning_actions
        WHERE invoice_id = v_inv.id AND step_name = v_step AND executed_at::date = CURRENT_DATE
      );
    END IF;

    invoice_id := v_inv.id;
    invoice_number := v_inv.invoice_number;
    customer_email := v_inv.customer_email;
    days_overdue := v_days;
    dunning_step := v_step;
    total_cents := v_inv.total_cents;
    RETURN NEXT;
  END LOOP;
END;
$function$

;

-- ship_picking
CREATE OR REPLACE FUNCTION public.ship_picking(p_picking_order_id uuid, p_tracking_number text DEFAULT NULL::text, p_carrier text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_po RECORD;
  v_line RECORD;
  v_consumed INT := 0;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'employee'))) THEN
    RAISE EXCEPTION 'Insufficient permissions';
  END IF;

  SELECT * INTO v_po FROM public.picking_orders WHERE id = p_picking_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Picking order % not found', p_picking_order_id; END IF;
  IF v_po.status = 'shipped' THEN
    RETURN jsonb_build_object('success', true, 'already_shipped', true);
  END IF;
  IF v_po.status = 'cancelled' THEN
    RAISE EXCEPTION 'Cannot ship cancelled picking_order';
  END IF;

  -- Consume each reserved line
  FOR v_line IN SELECT * FROM public.picking_lines WHERE picking_order_id = p_picking_order_id AND status = 'picked' LOOP
    IF v_line.reservation_id IS NOT NULL THEN
      BEGIN
        PERFORM public.consume_reservation(v_line.reservation_id, v_line.qty_picked);
        v_consumed := v_consumed + 1;
      EXCEPTION WHEN OTHERS THEN
        -- log but continue
        INSERT INTO public.audit_logs (action, entity_type, entity_id, user_id, metadata)
        VALUES ('picking.consume_failed', 'picking_line', v_line.id, auth.uid(),
          jsonb_build_object('error', SQLERRM));
      END;
    END IF;
  END LOOP;

  UPDATE public.picking_orders
  SET status = 'shipped',
      shipped_at = now(),
      tracking_number = COALESCE(p_tracking_number, tracking_number),
      carrier = COALESCE(p_carrier, carrier)
  WHERE id = p_picking_order_id;

  -- Update underlying order status
  IF v_po.order_id IS NOT NULL THEN
    UPDATE public.orders SET status = 'shipped', updated_at = now()
    WHERE id = v_po.order_id;
  END IF;

  -- Emit platform event if helper exists
  BEGIN
    PERFORM public.emit_platform_event(
      'picking.shipped',
      jsonb_build_object(
        'picking_order_id', p_picking_order_id,
        'order_id', v_po.order_id,
        'tracking_number', p_tracking_number,
        'consumed_lines', v_consumed
      ),
      'pick_pack'
    );
  EXCEPTION WHEN OTHERS THEN NULL; END;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, user_id, metadata)
  VALUES ('picking.shipped', 'picking_order', p_picking_order_id, auth.uid(),
    jsonb_build_object('order_id', v_po.order_id, 'tracking_number', p_tracking_number, 'consumed', v_consumed));

  RETURN jsonb_build_object('success', true, 'picking_order_id', p_picking_order_id, 'consumed_lines', v_consumed);
END;
$function$

;

-- start_mo
CREATE OR REPLACE FUNCTION public.start_mo(p_mo_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status public.mo_status;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT status INTO v_status FROM public.manufacturing_orders WHERE id = p_mo_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MO % not found', p_mo_id; END IF;

  IF v_status = 'in_progress' THEN
    RETURN jsonb_build_object('success', true, 'mo_id', p_mo_id, 'note', 'already in_progress');
  END IF;
  IF v_status <> 'confirmed' THEN
    RAISE EXCEPTION 'MO must be confirmed before starting (current: %)', v_status;
  END IF;

  UPDATE public.manufacturing_orders
     SET status = 'in_progress', started_at = now(), updated_at = now()
   WHERE id = p_mo_id;

  RETURN jsonb_build_object('success', true, 'mo_id', p_mo_id, 'status', 'in_progress');
END;
$function$

;

-- start_webinar
CREATE OR REPLACE FUNCTION public.start_webinar(p_webinar_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row webinars%ROWTYPE;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'approver')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  UPDATE webinars SET status='live', updated_at=now() WHERE id=p_webinar_id AND status IN ('draft','published') RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'webinar % cannot be started', p_webinar_id; END IF;
  PERFORM emit_platform_event('webinar.live', jsonb_build_object('webinar_id',v_row.id,'title',v_row.title), 'webinars');
  RETURN jsonb_build_object('success',true,'id',v_row.id,'status',v_row.status);
END $function$

;

-- transfer_stock
CREATE OR REPLACE FUNCTION public.transfer_stock(p_product_id uuid, p_from_location_id uuid, p_to_location_id uuid, p_quantity numeric, p_lot_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_move_id uuid; v_available numeric;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer'::app_role)) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role))) THEN RAISE EXCEPTION 'Insufficient privileges'; END IF;
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;
  SELECT COALESCE(quantity,0) INTO v_available FROM stock_quants
    WHERE product_id = p_product_id AND location_id = p_from_location_id AND (lot_id IS NOT DISTINCT FROM p_lot_id);
  IF COALESCE(v_available,0) < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock at source (have %, need %)', COALESCE(v_available,0), p_quantity;
  END IF;
  PERFORM _upsert_quant(p_product_id, p_from_location_id, p_lot_id, -p_quantity);
  PERFORM _upsert_quant(p_product_id, p_to_location_id, p_lot_id, p_quantity);
  INSERT INTO stock_moves (product_id, quantity, move_type, from_location_id, to_location_id, lot_id, notes, created_by, state)
  VALUES (p_product_id, p_quantity::int, 'transfer', p_from_location_id, p_to_location_id, p_lot_id, p_notes, auth.uid(), 'done')
  RETURNING id INTO v_move_id;
  RETURN v_move_id;
END; $function$

;

-- trigger_procurement_for_mo
CREATE OR REPLACE FUNCTION public.trigger_procurement_for_mo(p_mo_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_short  record;
  v_po_ids jsonb := '[]'::jsonb;
  v_skipped int := 0;
  v_short_qty numeric;
  v_existing uuid;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'writer')) OR (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'))) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  -- Make sure availability is fresh
  PERFORM public.check_mo_availability(p_mo_id);

  FOR v_short IN
    SELECT mc.component_product_id, mc.qty_required,
           COALESCE(ps.quantity_on_hand, 0) AS on_hand
      FROM public.mo_components mc
      LEFT JOIN public.product_stock ps ON ps.product_id = mc.component_product_id
     WHERE mc.mo_id = p_mo_id AND mc.availability = 'short'
  LOOP
    v_short_qty := v_short.qty_required - v_short.on_hand;

    -- Skip if an open PO already exists for this MO + component
    SELECT po.id INTO v_existing
      FROM public.purchase_orders po
      JOIN public.purchase_order_lines pol ON pol.po_id = po.id
     WHERE po.source_type = 'manufacturing'
       AND po.source_id = p_mo_id
       AND pol.product_id = v_short.component_product_id
       AND po.status IN ('draft', 'sent', 'confirmed')
     LIMIT 1;

    IF v_existing IS NOT NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    -- Mark as awaiting_po regardless of whether we can create the PO
    UPDATE public.mo_components
       SET availability = 'awaiting_po'
     WHERE mo_id = p_mo_id AND component_product_id = v_short.component_product_id;

    v_po_ids := v_po_ids || jsonb_build_object(
      'component_product_id', v_short.component_product_id,
      'qty_short', v_short_qty,
      'note', 'PO creation deferred — call create_purchase_order skill with source_type=manufacturing, source_id=' || p_mo_id::text
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'mo_id', p_mo_id,
    'requests', v_po_ids,
    'skipped_existing', v_skipped
  );
END;
$function$

;
