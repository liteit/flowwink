-- Pricelists: parity round 7 (docs/parity/capabilities/pricelists.json)
-- Adds: time-based dynamic pricing (day-of-week + time-window rules),
-- customer-segment/country pricing (companies.tags / companies.country),
-- formula (cost+margin) pricing, supplier price resolution over the existing
-- vendor_products tiers, pricelist version history (audit trigger), and
-- pricelist application to POS (record_pos_sale_v2 resolves omitted line
-- prices) and subscriptions (create_manual_subscription resolves the unit
-- amount from the customer's pricelist when omitted).
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. Schema additions ──────────────────────────────────────────────────────
ALTER TABLE public.pricelists ADD COLUMN IF NOT EXISTS segment text;
ALTER TABLE public.pricelists ADD COLUMN IF NOT EXISTS country text;
ALTER TABLE public.companies  ADD COLUMN IF NOT EXISTS country text;

ALTER TABLE public.pricelist_items ADD COLUMN IF NOT EXISTS days_of_week integer[];
ALTER TABLE public.pricelist_items ADD COLUMN IF NOT EXISTS time_start time;
ALTER TABLE public.pricelist_items ADD COLUMN IF NOT EXISTS time_end time;
ALTER TABLE public.pricelist_items ADD COLUMN IF NOT EXISTS formula_base text;
ALTER TABLE public.pricelist_items ADD COLUMN IF NOT EXISTS margin_pct numeric;
ALTER TABLE public.pricelist_items ADD COLUMN IF NOT EXISTS surcharge_cents bigint;
ALTER TABLE public.pricelist_items ADD COLUMN IF NOT EXISTS rounding_cents integer;

-- Widen the pre-existing "fixed OR discount" rule to admit formula rows.
ALTER TABLE public.pricelist_items DROP CONSTRAINT IF EXISTS pricelist_items_price_or_discount;
ALTER TABLE public.pricelist_items
  ADD CONSTRAINT pricelist_items_price_or_discount
  CHECK (fixed_price_cents IS NOT NULL OR discount_pct IS NOT NULL OR formula_base IS NOT NULL);
ALTER TABLE public.pricelist_items DROP CONSTRAINT IF EXISTS pricelist_items_formula_base_check;
ALTER TABLE public.pricelist_items
  ADD CONSTRAINT pricelist_items_formula_base_check
  CHECK (formula_base IS NULL OR formula_base IN ('cost','list'));
ALTER TABLE public.pricelist_items DROP CONSTRAINT IF EXISTS pricelist_items_time_window_check;
ALTER TABLE public.pricelist_items
  ADD CONSTRAINT pricelist_items_time_window_check
  CHECK ((time_start IS NULL) = (time_end IS NULL));

-- ── 2. Version history ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.pricelist_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pricelist_id uuid,
  item_id uuid,
  table_name text NOT NULL,
  action text NOT NULL,
  snapshot jsonb NOT NULL,
  changed_by uuid,
  changed_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pricelist_revisions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins view pricelist revisions" ON public.pricelist_revisions;
CREATE POLICY "Admins view pricelist revisions" ON public.pricelist_revisions FOR SELECT
  USING (has_role(auth.uid(), 'admin'::app_role));
CREATE INDEX IF NOT EXISTS pricelist_revisions_pricelist_idx
  ON public.pricelist_revisions (pricelist_id, changed_at DESC);

CREATE OR REPLACE FUNCTION public.log_pricelist_revision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row jsonb;
BEGIN
  v_row := to_jsonb(COALESCE(NEW, OLD));
  INSERT INTO public.pricelist_revisions (pricelist_id, item_id, table_name, action, snapshot, changed_by)
  VALUES (
    CASE WHEN TG_TABLE_NAME = 'pricelists' THEN COALESCE(NEW.id, OLD.id)
         ELSE (v_row->>'pricelist_id')::uuid END,
    CASE WHEN TG_TABLE_NAME = 'pricelist_items' THEN (v_row->>'id')::uuid ELSE NULL END,
    TG_TABLE_NAME, lower(TG_OP), v_row, auth.uid()
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_pricelists_revision ON public.pricelists;
CREATE TRIGGER trg_pricelists_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.pricelists
  FOR EACH ROW EXECUTE FUNCTION public.log_pricelist_revision();
DROP TRIGGER IF EXISTS trg_pricelist_items_revision ON public.pricelist_items;
CREATE TRIGGER trg_pricelist_items_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.pricelist_items
  FOR EACH ROW EXECUTE FUNCTION public.log_pricelist_revision();

CREATE OR REPLACE FUNCTION public.get_pricelist_history(
  p_pricelist_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 50
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_rows jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can view pricelist history';
  END IF;
  SELECT COALESCE(jsonb_agg(r ORDER BY r.changed_at DESC), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT id, pricelist_id, item_id, table_name, action, snapshot, changed_by, changed_at
    FROM public.pricelist_revisions
    WHERE p_pricelist_id IS NULL OR pricelist_id = p_pricelist_id
    ORDER BY changed_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit,50),1),200)
  ) r;
  RETURN jsonb_build_object('success', true, 'revisions', v_rows);
END;
$$;

-- ── 3. Resolution v3: time windows, segment/country, formula pricing ─────────
-- Signature grows by p_at_time — drop the old 6-arg overload so PostgREST
-- named-arg dispatch stays unambiguous.
DROP FUNCTION IF EXISTS public.resolve_pricelist_price(uuid, uuid, uuid, numeric, date, text);

CREATE OR REPLACE FUNCTION public.resolve_pricelist_price(
  p_product_id uuid,
  p_lead_id uuid DEFAULT NULL,
  p_company_id uuid DEFAULT NULL,
  p_quantity numeric DEFAULT 1,
  p_at date DEFAULT CURRENT_DATE,
  p_currency text DEFAULT 'SEK',
  p_at_time time DEFAULT NULL
) RETURNS TABLE(price_cents integer, pricelist_id uuid, pricelist_name text, source text)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_base_price integer;
  v_cost bigint;
  v_company uuid;
  v_country text;
  v_tags text[];
  v_time time;
  v_dow integer;
BEGIN
  -- Qualify to avoid clash with the RETURNS TABLE column also named price_cents
  SELECT COALESCE(p.price_cents, 0), p.cost_cents INTO v_base_price, v_cost
  FROM public.products p
  WHERE p.id = p_product_id;

  v_company := COALESCE(p_company_id, (SELECT l.company_id FROM public.leads l WHERE l.id = p_lead_id));
  IF v_company IS NOT NULL THEN
    SELECT c.country, c.tags INTO v_country, v_tags FROM public.companies c WHERE c.id = v_company;
  END IF;
  -- Time-limited rules only match when we know the wall-clock time:
  -- explicit p_at_time, or "now" when resolving for today.
  v_time := COALESCE(p_at_time, CASE WHEN p_at = CURRENT_DATE THEN LOCALTIME ELSE NULL END);
  v_dow := EXTRACT(ISODOW FROM p_at)::integer;

  RETURN QUERY
  WITH candidates AS (
    SELECT pl.id, pl.name,
      CASE
        WHEN pli.fixed_price_cents IS NOT NULL THEN pli.fixed_price_cents
        WHEN pli.discount_pct IS NOT NULL THEN GREATEST(0, ROUND(v_base_price * (1 - pli.discount_pct/100.0))::int)
        WHEN pli.formula_base IS NOT NULL THEN GREATEST(0, (
          CASE WHEN COALESCE(pli.rounding_cents,0) > 0
            THEN (ROUND((
              (CASE WHEN pli.formula_base = 'cost' THEN COALESCE(v_cost, v_base_price) ELSE v_base_price END)
              * (1 + COALESCE(pli.margin_pct,0)/100.0) + COALESCE(pli.surcharge_cents,0)
            ) / pli.rounding_cents) * pli.rounding_cents)::int
            ELSE ROUND(
              (CASE WHEN pli.formula_base = 'cost' THEN COALESCE(v_cost, v_base_price) ELSE v_base_price END)
              * (1 + COALESCE(pli.margin_pct,0)/100.0) + COALESCE(pli.surcharge_cents,0)
            )::int
          END))
        ELSE v_base_price
      END AS resolved_price,
      (CASE WHEN pl.lead_id = p_lead_id THEN 1000 ELSE 0 END
       + CASE WHEN pl.company_id = v_company THEN 500 ELSE 0 END
       + CASE WHEN pl.segment IS NOT NULL THEN 300 ELSE 0 END
       + CASE WHEN pl.country IS NOT NULL THEN 200 ELSE 0 END
       + CASE WHEN pli.product_id = p_product_id THEN 100 ELSE 0 END
       + CASE WHEN pli.time_start IS NOT NULL OR pli.days_of_week IS NOT NULL THEN 50 ELSE 0 END
       - pl.priority) AS specificity,
      pli.min_quantity AS qty_break
    FROM public.pricelists pl
    JOIN public.pricelist_items pli ON pli.pricelist_id = pl.id
    WHERE pl.is_active AND pl.currency = p_currency
      AND (pl.valid_from IS NULL OR pl.valid_from <= p_at)
      AND (pl.valid_until IS NULL OR pl.valid_until >= p_at)
      AND (pli.product_id = p_product_id OR pli.product_id IS NULL)
      AND p_quantity >= pli.min_quantity
      AND ((pl.lead_id IS NULL AND pl.company_id IS NULL)
        OR (p_lead_id IS NOT NULL AND pl.lead_id = p_lead_id)
        OR (v_company IS NOT NULL AND pl.company_id = v_company))
      AND (pl.segment IS NULL OR (v_tags IS NOT NULL AND pl.segment = ANY(v_tags)))
      AND (pl.country IS NULL OR (v_country IS NOT NULL AND upper(pl.country) = upper(v_country)))
      AND (pli.days_of_week IS NULL OR v_dow = ANY(pli.days_of_week))
      AND (pli.time_start IS NULL
        OR (v_time IS NOT NULL AND v_time >= pli.time_start AND v_time < pli.time_end))
  )
  SELECT resolved_price, id, name, 'pricelist'::text
  FROM candidates ORDER BY specificity DESC, qty_break DESC, resolved_price ASC LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT v_base_price, NULL::uuid, NULL::text, 'product_base'::text;
  END IF;
END;
$function$;

-- ── 4. Supplier/vendor price resolution over vendor_products ────────────────
CREATE OR REPLACE FUNCTION public.resolve_vendor_price(
  p_product_id uuid,
  p_quantity numeric DEFAULT 1,
  p_vendor_id uuid DEFAULT NULL,
  p_at date DEFAULT CURRENT_DATE
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_best record;
  v_alts jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')
          OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Not authorized to read vendor prices';
  END IF;

  SELECT vp.id, vp.vendor_id, v.name AS vendor_name, vp.unit_price_cents, vp.currency,
         vp.lead_time_days, vp.min_order_quantity, vp.vendor_sku, vp.is_preferred,
         COALESCE(vp.price_tier_min_qty, 1) AS tier_min_qty
  INTO v_best
  FROM public.vendor_products vp
  JOIN public.vendors v ON v.id = vp.vendor_id AND v.is_active
  WHERE vp.product_id = p_product_id
    AND (p_vendor_id IS NULL OR vp.vendor_id = p_vendor_id)
    AND (vp.valid_from IS NULL OR vp.valid_from <= p_at)
    AND (vp.valid_until IS NULL OR vp.valid_until >= p_at)
    AND COALESCE(vp.price_tier_min_qty, 1) <= p_quantity
  ORDER BY vp.is_preferred DESC, COALESCE(vp.price_tier_min_qty,1) DESC, vp.unit_price_cents ASC
  LIMIT 1;

  IF v_best IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_vendor_price',
      'message', 'No valid vendor price for this product/quantity/date');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'vendor_id', a.vendor_id, 'vendor_name', a.vendor_name,
           'unit_price_cents', a.unit_price_cents, 'currency', a.currency,
           'lead_time_days', a.lead_time_days, 'tier_min_qty', a.tier_min_qty,
           'is_preferred', a.is_preferred)), '[]'::jsonb)
  INTO v_alts
  FROM (
    SELECT DISTINCT ON (vp.vendor_id) vp.vendor_id, v.name AS vendor_name, vp.unit_price_cents,
           vp.currency, vp.lead_time_days, COALESCE(vp.price_tier_min_qty,1) AS tier_min_qty, vp.is_preferred
    FROM public.vendor_products vp
    JOIN public.vendors v ON v.id = vp.vendor_id AND v.is_active
    WHERE vp.product_id = p_product_id
      AND vp.vendor_id <> v_best.vendor_id
      AND (vp.valid_from IS NULL OR vp.valid_from <= p_at)
      AND (vp.valid_until IS NULL OR vp.valid_until >= p_at)
      AND COALESCE(vp.price_tier_min_qty, 1) <= p_quantity
    ORDER BY vp.vendor_id, COALESCE(vp.price_tier_min_qty,1) DESC, vp.unit_price_cents ASC
  ) a;

  RETURN jsonb_build_object('success', true,
    'vendor_id', v_best.vendor_id, 'vendor_name', v_best.vendor_name,
    'unit_price_cents', v_best.unit_price_cents, 'currency', v_best.currency,
    'lead_time_days', v_best.lead_time_days, 'min_order_quantity', v_best.min_order_quantity,
    'vendor_sku', v_best.vendor_sku, 'is_preferred', v_best.is_preferred,
    'tier_min_qty', v_best.tier_min_qty, 'alternatives', v_alts);
END;
$$;

CREATE OR REPLACE FUNCTION public.manage_vendor_price(
  p_action text,
  p_id uuid DEFAULT NULL,
  p_vendor_id uuid DEFAULT NULL,
  p_product_id uuid DEFAULT NULL,
  p_unit_price_cents integer DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_lead_time_days integer DEFAULT NULL,
  p_min_order_quantity integer DEFAULT NULL,
  p_price_tier_min_qty integer DEFAULT NULL,
  p_vendor_sku text DEFAULT NULL,
  p_is_preferred boolean DEFAULT NULL,
  p_valid_from date DEFAULT NULL,
  p_valid_until date DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.vendor_products;
  v_rows jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can manage vendor prices';
  END IF;

  IF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.unit_price_cents), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT vp.*, v.name AS vendor_name FROM public.vendor_products vp
      JOIN public.vendors v ON v.id = vp.vendor_id
      WHERE (p_product_id IS NULL OR vp.product_id = p_product_id)
        AND (p_vendor_id IS NULL OR vp.vendor_id = p_vendor_id)
      LIMIT 200
    ) r;
    RETURN jsonb_build_object('success', true, 'vendor_prices', v_rows);

  ELSIF p_action = 'create' THEN
    IF p_vendor_id IS NULL OR p_product_id IS NULL OR p_unit_price_cents IS NULL THEN
      RAISE EXCEPTION 'create requires p_vendor_id, p_product_id, p_unit_price_cents';
    END IF;
    INSERT INTO public.vendor_products (vendor_id, product_id, unit_price_cents, currency,
      lead_time_days, min_order_quantity, price_tier_min_qty, vendor_sku, is_preferred,
      valid_from, valid_until, notes)
    VALUES (p_vendor_id, p_product_id, p_unit_price_cents, COALESCE(p_currency,'SEK'),
      p_lead_time_days, COALESCE(p_min_order_quantity,1), p_price_tier_min_qty, p_vendor_sku,
      COALESCE(p_is_preferred,false), p_valid_from, p_valid_until, p_notes)
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'vendor_price', to_jsonb(v_row));

  ELSIF p_action = 'update' THEN
    IF p_id IS NULL THEN RAISE EXCEPTION 'update requires p_id'; END IF;
    UPDATE public.vendor_products SET
      unit_price_cents = COALESCE(p_unit_price_cents, unit_price_cents),
      currency = COALESCE(p_currency, currency),
      lead_time_days = COALESCE(p_lead_time_days, lead_time_days),
      min_order_quantity = COALESCE(p_min_order_quantity, min_order_quantity),
      price_tier_min_qty = COALESCE(p_price_tier_min_qty, price_tier_min_qty),
      vendor_sku = COALESCE(p_vendor_sku, vendor_sku),
      is_preferred = COALESCE(p_is_preferred, is_preferred),
      valid_from = COALESCE(p_valid_from, valid_from),
      valid_until = COALESCE(p_valid_until, valid_until),
      notes = COALESCE(p_notes, notes),
      updated_at = now()
    WHERE id = p_id
    RETURNING * INTO v_row;
    IF NOT FOUND THEN RAISE EXCEPTION 'vendor price % not found', p_id; END IF;
    RETURN jsonb_build_object('success', true, 'vendor_price', to_jsonb(v_row));

  ELSIF p_action = 'delete' THEN
    IF p_id IS NULL THEN RAISE EXCEPTION 'delete requires p_id'; END IF;
    DELETE FROM public.vendor_products WHERE id = p_id;
    RETURN jsonb_build_object('success', true, 'deleted', p_id);

  ELSE
    RAISE EXCEPTION 'Unknown action %. Use create|update|list|delete', p_action;
  END IF;
END;
$$;

-- ── 5. POS: resolve omitted line prices from pricelists ──────────────────────
-- Lines may now omit unit_price_cents when product_id is present — the sale
-- resolves the customer-specific price (pos_sales.customer_id is a lead id).
CREATE OR REPLACE FUNCTION public.record_pos_sale_v2(
  p_register_id uuid, p_session_id uuid, p_lines jsonb, p_payments jsonb,
  p_customer_id uuid DEFAULT NULL::uuid, p_customer_email text DEFAULT NULL::text,
  p_discount_cents integer DEFAULT 0, p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sale_id uuid;
  v_receipt text;
  v_subtotal integer := 0;
  v_tax integer := 0;
  v_total integer := 0;
  v_paid integer := 0;
  v_line jsonb;
  v_payment jsonb;
  v_register_currency text;
  v_default_tax numeric;
  v_line_subtotal integer;
  v_line_tax integer;
  v_line_total integer;
  v_tax_rate numeric;
  v_product record;
  v_payment_summary text;
  v_lines jsonb := '[]'::jsonb;
  v_unit integer;
  v_resolved record;
BEGIN
  -- Validate session is open
  IF NOT EXISTS (
    SELECT 1 FROM public.pos_sessions
     WHERE id = p_session_id AND register_id = p_register_id AND status = 'open'
  ) THEN
    RAISE EXCEPTION 'Session % is not open for register %', p_session_id, p_register_id;
  END IF;

  SELECT currency, default_tax_rate
    INTO v_register_currency, v_default_tax
    FROM public.pos_registers WHERE id = p_register_id;

  -- Normalize lines: resolve omitted unit prices from the pricelist engine.
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_unit := (v_line->>'unit_price_cents')::integer;
    IF v_unit IS NULL THEN
      IF (v_line->>'product_id') IS NULL THEN
        RAISE EXCEPTION 'Line without product_id must carry unit_price_cents';
      END IF;
      SELECT r.price_cents, r.pricelist_id INTO v_resolved
      FROM public.resolve_pricelist_price(
        (v_line->>'product_id')::uuid, p_customer_id, NULL,
        COALESCE((v_line->>'quantity')::numeric, 1), CURRENT_DATE, v_register_currency) r;
      v_unit := v_resolved.price_cents;
      IF v_unit IS NULL THEN
        RAISE EXCEPTION 'Could not resolve a price for product %', v_line->>'product_id';
      END IF;
      v_line := v_line || jsonb_build_object('unit_price_cents', v_unit,
        'pricelist_id', v_resolved.pricelist_id);
    END IF;
    v_lines := v_lines || jsonb_build_array(v_line);
  END LOOP;

  -- Generate receipt
  v_receipt := 'R-' || to_char(now(), 'YYYYMMDD') || '-' || lpad((EXTRACT(EPOCH FROM now())::bigint % 100000)::text, 5, '0');

  -- Calculate totals + validate products
  FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines)
  LOOP
    v_tax_rate := COALESCE((v_line->>'tax_rate')::numeric, v_default_tax, 0);
    v_line_subtotal := ((v_line->>'unit_price_cents')::integer * (v_line->>'quantity')::numeric)::integer
                       - COALESCE((v_line->>'discount_cents')::integer, 0);
    v_line_tax := round(v_line_subtotal * v_tax_rate / 100.0)::integer;
    v_line_total := v_line_subtotal + v_line_tax;

    v_subtotal := v_subtotal + v_line_subtotal;
    v_tax := v_tax + v_line_tax;
    v_total := v_total + v_line_total;

    -- If product_id given, ensure it's POS-enabled
    IF (v_line->>'product_id') IS NOT NULL THEN
      SELECT id, name, available_in_pos INTO v_product
        FROM public.products WHERE id = (v_line->>'product_id')::uuid;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product % not found', v_line->>'product_id';
      END IF;
      IF NOT v_product.available_in_pos THEN
        RAISE EXCEPTION 'Product % is not available in POS', v_product.name;
      END IF;
    END IF;
  END LOOP;

  v_total := v_total - COALESCE(p_discount_cents, 0);

  -- Validate payments cover the total
  FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments)
  LOOP
    v_paid := v_paid + (v_payment->>'amount_cents')::integer;
  END LOOP;

  IF v_paid < v_total THEN
    RAISE EXCEPTION 'Insufficient payment: paid %, total %', v_paid, v_total;
  END IF;

  -- Determine payment_method label (split if >1)
  IF jsonb_array_length(p_payments) > 1 THEN
    v_payment_summary := 'split';
  ELSE
    v_payment_summary := COALESCE(p_payments->0->>'method', 'cash');
  END IF;

  -- Create sale
  INSERT INTO public.pos_sales (
    receipt_number, register_id, session_id, customer_id, customer_email,
    subtotal_cents, tax_cents, discount_cents, total_cents, currency,
    payment_method, status, metadata
  )
  VALUES (
    v_receipt, p_register_id, p_session_id, p_customer_id, p_customer_email,
    v_subtotal, v_tax, COALESCE(p_discount_cents, 0), v_total, v_register_currency,
    v_payment_summary, 'completed', p_metadata
  )
  RETURNING id INTO v_sale_id;

  -- Insert lines
  FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines)
  LOOP
    v_tax_rate := COALESCE((v_line->>'tax_rate')::numeric, v_default_tax, 0);
    v_line_subtotal := ((v_line->>'unit_price_cents')::integer * (v_line->>'quantity')::numeric)::integer
                       - COALESCE((v_line->>'discount_cents')::integer, 0);
    v_line_tax := round(v_line_subtotal * v_tax_rate / 100.0)::integer;

    INSERT INTO public.pos_sale_lines (
      sale_id, product_id, product_name, sku, quantity,
      unit_price_cents, discount_cents, tax_rate, line_total_cents
    )
    VALUES (
      v_sale_id,
      NULLIF(v_line->>'product_id','')::uuid,
      v_line->>'product_name',
      v_line->>'sku',
      (v_line->>'quantity')::numeric,
      (v_line->>'unit_price_cents')::integer,
      COALESCE((v_line->>'discount_cents')::integer, 0),
      v_tax_rate,
      v_line_subtotal + v_line_tax
    );

    -- Stock event (fire-and-forget — stock module listens)
    IF (v_line->>'product_id') IS NOT NULL THEN
      PERFORM public.emit_platform_event(
        'stock.movement',
        jsonb_build_object(
          'product_id', v_line->>'product_id',
          'quantity', -((v_line->>'quantity')::numeric),
          'reason', 'pos_sale',
          'reference_type', 'pos_sale',
          'reference_id', v_sale_id,
          'sku', v_line->>'sku'
        ),
        'pos'
      );
    END IF;
  END LOOP;

  -- Insert payments
  FOR v_payment IN SELECT * FROM jsonb_array_elements(p_payments)
  LOOP
    INSERT INTO public.pos_payments (sale_id, method, amount_cents, reference, metadata)
    VALUES (
      v_sale_id,
      v_payment->>'method',
      (v_payment->>'amount_cents')::integer,
      v_payment->>'reference',
      COALESCE(v_payment->'metadata', '{}'::jsonb)
    );
  END LOOP;

  -- Update session totals
  UPDATE public.pos_sessions
     SET total_sales_cents = total_sales_cents + v_total,
         sales_count = sales_count + 1
   WHERE id = p_session_id;

  RETURN jsonb_build_object(
    'sale_id', v_sale_id,
    'receipt_number', v_receipt,
    'total_cents', v_total,
    'tax_cents', v_tax,
    'change_cents', v_paid - v_total
  );
END;
$function$;

-- ── 6. Subscriptions: resolve omitted unit amount from pricelists ────────────
-- _unit_amount_cents becomes optional: when NULL and _product_id is given, the
-- customer's pricelist price (lead matched by email) is resolved at start date.
DROP FUNCTION IF EXISTS public.create_manual_subscription(text, text, text, integer, text, text, integer, integer, text, date, text, text, uuid, boolean);

CREATE OR REPLACE FUNCTION public.create_manual_subscription(
  _customer_email text, _customer_name text, _product_name text,
  _unit_amount_cents integer DEFAULT NULL,
  _currency text DEFAULT 'EUR'::text, _billing_interval text DEFAULT 'month'::text,
  _billing_interval_count integer DEFAULT 1, _quantity integer DEFAULT 1,
  _payment_terms text DEFAULT 'invoice_30'::text, _start_date date DEFAULT CURRENT_DATE,
  _billing_contact_email text DEFAULT NULL::text, _po_number text DEFAULT NULL::text,
  _product_id uuid DEFAULT NULL::uuid, _auto_finalize boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _new_id uuid;
  _amount integer := _unit_amount_cents;
  _lead record;
  _resolved record;
  _pricelist uuid;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) THEN
    RAISE EXCEPTION 'Only admins can create manual subscriptions';
  END IF;
  IF _customer_email IS NULL OR length(trim(_customer_email)) = 0 THEN
    RAISE EXCEPTION 'customer_email is required';
  END IF;
  IF _amount IS NULL THEN
    IF _product_id IS NULL THEN
      RAISE EXCEPTION 'unit_amount_cents is required unless product_id is given (pricelist resolution)';
    END IF;
    SELECT l.id, l.company_id INTO _lead
    FROM public.leads l WHERE lower(l.email) = lower(trim(_customer_email))
    ORDER BY l.created_at DESC LIMIT 1;
    SELECT r.price_cents, r.pricelist_id INTO _resolved
    FROM public.resolve_pricelist_price(_product_id, _lead.id, _lead.company_id,
      GREATEST(1,_quantity)::numeric, _start_date, upper(_currency)) r;
    _amount := _resolved.price_cents;
    _pricelist := _resolved.pricelist_id;
    IF _amount IS NULL OR _amount <= 0 THEN
      RAISE EXCEPTION 'Could not resolve a positive price for product % in currency %', _product_id, upper(_currency);
    END IF;
  END IF;
  IF _amount IS NULL OR _amount <= 0 THEN
    RAISE EXCEPTION 'unit_amount_cents must be > 0';
  END IF;
  INSERT INTO public.subscriptions (
    customer_email, customer_name, product_name, product_id,
    unit_amount_cents, currency, quantity,
    billing_interval, billing_interval_count,
    payment_terms, billing_contact_email, po_number,
    provider, status,
    current_period_start, current_period_end, next_invoice_date,
    auto_finalize, metadata
  ) VALUES (
    lower(trim(_customer_email)), _customer_name, _product_name, _product_id,
    _amount, lower(_currency), GREATEST(1, _quantity),
    lower(_billing_interval), GREATEST(1, _billing_interval_count),
    _payment_terms, _billing_contact_email, _po_number,
    'manual', 'active'::subscription_status,
    _start_date::timestamptz,
    advance_billing_date(_start_date, _billing_interval, _billing_interval_count)::timestamptz,
    _start_date,
    COALESCE(_auto_finalize, false),
    jsonb_build_object('created_via', 'create_manual_subscription', 'created_by', auth.uid(),
      'auto_finalize', COALESCE(_auto_finalize, false))
      || CASE WHEN _pricelist IS NOT NULL
           THEN jsonb_build_object('pricelist_id', _pricelist, 'price_source', 'pricelist')
           ELSE '{}'::jsonb END
  ) RETURNING id INTO _new_id;
  PERFORM public.emit_platform_event(
    'subscription.created',
    jsonb_build_object('subscription_id', _new_id, 'provider', 'manual', 'customer_email', _customer_email, 'auto_finalize', COALESCE(_auto_finalize, false)),
    'create_manual_subscription'
  );
  RETURN jsonb_build_object('ok', true, 'subscription_id', _new_id, 'next_invoice_date', _start_date,
    'auto_finalize', COALESCE(_auto_finalize, false),
    'unit_amount_cents', _amount,
    'pricelist_id', _pricelist);
END $function$;
