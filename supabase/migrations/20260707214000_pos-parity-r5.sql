-- POS: parity round 5 (docs/parity/capabilities/pos.json)
-- Adds: loyalty/points program (accounts + ledger + auto-earn on sale),
-- refund/return workflow (negative sale linked via refund_of, restock events),
-- receipt→invoice linking (pos_sale_to_invoice), branded receipt templates
-- (per-register header/footer + render_pos_receipt), and table/seat
-- management for F&B (pos_tables + manage_pos_table).
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. Schema additions ──────────────────────────────────────────────────────
ALTER TABLE public.pos_sales
  ADD COLUMN IF NOT EXISTS invoice_id uuid REFERENCES public.invoices(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS table_id uuid,
  ADD COLUMN IF NOT EXISTS refund_reason text;

ALTER TABLE public.pos_registers
  ADD COLUMN IF NOT EXISTS receipt_header text,
  ADD COLUMN IF NOT EXISTS receipt_footer text;

-- Refund payments are negative rows — the old CHECK (amount_cents > 0) blocked them.
ALTER TABLE public.pos_payments DROP CONSTRAINT IF EXISTS pos_payments_amount_cents_check;
ALTER TABLE public.pos_payments
  ADD CONSTRAINT pos_payments_amount_cents_check CHECK (amount_cents <> 0);

-- Allow partial-refund status on sales
ALTER TABLE public.pos_sales DROP CONSTRAINT IF EXISTS pos_sales_status_check;
ALTER TABLE public.pos_sales
  ADD CONSTRAINT pos_sales_status_check
  CHECK (status = ANY (ARRAY['completed'::text, 'refunded'::text, 'partially_refunded'::text, 'voided'::text]));

CREATE TABLE IF NOT EXISTS public.pos_tables (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  area text,
  seats integer NOT NULL DEFAULT 4,
  status text NOT NULL DEFAULT 'free' CHECK (status IN ('free','occupied','reserved')),
  current_sale_id uuid REFERENCES public.pos_sales(id) ON DELETE SET NULL,
  register_id uuid REFERENCES public.pos_registers(id) ON DELETE SET NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.pos_sales DROP CONSTRAINT IF EXISTS pos_sales_table_id_fkey;
ALTER TABLE public.pos_sales
  ADD CONSTRAINT pos_sales_table_id_fkey
  FOREIGN KEY (table_id) REFERENCES public.pos_tables(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.loyalty_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_email text NOT NULL,
  customer_name text,
  customer_id uuid,
  points_balance integer NOT NULL DEFAULT 0,
  lifetime_points integer NOT NULL DEFAULT 0,
  tier text NOT NULL DEFAULT 'bronze' CHECK (tier IN ('bronze','silver','gold')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS loyalty_accounts_email_key
  ON public.loyalty_accounts (lower(customer_email));

CREATE TABLE IF NOT EXISTS public.loyalty_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.loyalty_accounts(id) ON DELETE CASCADE,
  sale_id uuid REFERENCES public.pos_sales(id) ON DELETE SET NULL,
  points integer NOT NULL,
  kind text NOT NULL CHECK (kind IN ('earn','redeem','adjust')),
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS loyalty_transactions_account_idx
  ON public.loyalty_transactions (account_id, created_at DESC);

-- RLS
ALTER TABLE public.pos_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.loyalty_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.loyalty_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage pos_tables" ON public.pos_tables;
CREATE POLICY "Admins manage pos_tables" ON public.pos_tables
  FOR ALL USING (has_role(auth.uid(),'admin'::app_role)) WITH CHECK (has_role(auth.uid(),'admin'::app_role));
DROP POLICY IF EXISTS "Staff view pos_tables" ON public.pos_tables;
CREATE POLICY "Staff view pos_tables" ON public.pos_tables
  FOR SELECT USING (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'writer'::app_role) OR has_role(auth.uid(),'approver'::app_role));

DROP POLICY IF EXISTS "Admins manage loyalty_accounts" ON public.loyalty_accounts;
CREATE POLICY "Admins manage loyalty_accounts" ON public.loyalty_accounts
  FOR ALL USING (has_role(auth.uid(),'admin'::app_role)) WITH CHECK (has_role(auth.uid(),'admin'::app_role));
DROP POLICY IF EXISTS "Staff view loyalty_accounts" ON public.loyalty_accounts;
CREATE POLICY "Staff view loyalty_accounts" ON public.loyalty_accounts
  FOR SELECT USING (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'writer'::app_role) OR has_role(auth.uid(),'approver'::app_role));

DROP POLICY IF EXISTS "Admins manage loyalty_transactions" ON public.loyalty_transactions;
CREATE POLICY "Admins manage loyalty_transactions" ON public.loyalty_transactions
  FOR ALL USING (has_role(auth.uid(),'admin'::app_role)) WITH CHECK (has_role(auth.uid(),'admin'::app_role));
DROP POLICY IF EXISTS "Staff view loyalty_transactions" ON public.loyalty_transactions;
CREATE POLICY "Staff view loyalty_transactions" ON public.loyalty_transactions
  FOR SELECT USING (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'writer'::app_role) OR has_role(auth.uid(),'approver'::app_role));

-- ── 2. Loyalty program ────────────────────────────────────────────────────────
-- Points model: 1 point per full 10 currency units spent (floor(total_cents/1000)).
-- Tiers on lifetime points: bronze < 5000 <= silver < 15000 <= gold.
CREATE OR REPLACE FUNCTION public.loyalty_tier_for(p_lifetime integer)
RETURNS text LANGUAGE sql IMMUTABLE
AS $$ SELECT CASE WHEN p_lifetime >= 15000 THEN 'gold' WHEN p_lifetime >= 5000 THEN 'silver' ELSE 'bronze' END $$;

CREATE OR REPLACE FUNCTION public.manage_loyalty(
  p_action text,
  p_customer_email text DEFAULT NULL,
  p_customer_name text DEFAULT NULL,
  p_points integer DEFAULT NULL,
  p_sale_id uuid DEFAULT NULL,
  p_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_acct public.loyalty_accounts%ROWTYPE;
  v_rows jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only staff can manage loyalty';
  END IF;

  IF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.points_balance DESC), '[]'::jsonb) INTO v_rows
    FROM public.loyalty_accounts a WHERE a.active;
    RETURN jsonb_build_object('success', true, 'accounts', v_rows);
  END IF;

  IF p_customer_email IS NULL THEN RAISE EXCEPTION 'customer_email is required'; END IF;
  SELECT * INTO v_acct FROM public.loyalty_accounts
   WHERE lower(customer_email) = lower(p_customer_email) FOR UPDATE;

  IF p_action = 'enroll' THEN
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'account_id', v_acct.id,
        'already_enrolled', true, 'points_balance', v_acct.points_balance, 'tier', v_acct.tier);
    END IF;
    INSERT INTO public.loyalty_accounts (customer_email, customer_name)
    VALUES (lower(p_customer_email), p_customer_name)
    RETURNING * INTO v_acct;
    RETURN jsonb_build_object('success', true, 'account_id', v_acct.id,
      'points_balance', 0, 'tier', 'bronze');
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No loyalty account for % — enroll first (p_action=enroll)', p_customer_email;
  END IF;

  IF p_action = 'get' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC), '[]'::jsonb) INTO v_rows
    FROM (SELECT * FROM public.loyalty_transactions WHERE account_id = v_acct.id ORDER BY created_at DESC LIMIT 20) t;
    RETURN jsonb_build_object('success', true, 'account', to_jsonb(v_acct), 'recent_transactions', v_rows);

  ELSIF p_action IN ('earn','redeem','adjust') THEN
    IF p_points IS NULL OR p_points = 0 THEN RAISE EXCEPTION 'points (non-zero) is required'; END IF;
    IF p_action = 'earn' AND p_points < 0 THEN RAISE EXCEPTION 'earn requires positive points'; END IF;
    IF p_action = 'redeem' THEN
      IF p_points < 0 THEN RAISE EXCEPTION 'redeem takes positive points to spend'; END IF;
      IF v_acct.points_balance < p_points THEN
        RAISE EXCEPTION 'Insufficient points: balance %, requested %', v_acct.points_balance, p_points;
      END IF;
    END IF;
    UPDATE public.loyalty_accounts
       SET points_balance = points_balance + CASE WHEN p_action = 'redeem' THEN -p_points ELSE p_points END,
           lifetime_points = lifetime_points + CASE WHEN p_action = 'earn' THEN p_points ELSE 0 END,
           tier = public.loyalty_tier_for(lifetime_points + CASE WHEN p_action = 'earn' THEN p_points ELSE 0 END),
           updated_at = now()
     WHERE id = v_acct.id
    RETURNING * INTO v_acct;
    INSERT INTO public.loyalty_transactions (account_id, sale_id, points, kind, note)
    VALUES (v_acct.id, p_sale_id,
            CASE WHEN p_action = 'redeem' THEN -p_points ELSE p_points END,
            p_action, p_note);
    RETURN jsonb_build_object('success', true, 'account_id', v_acct.id,
      'points_balance', v_acct.points_balance, 'lifetime_points', v_acct.lifetime_points, 'tier', v_acct.tier);

  ELSE
    RAISE EXCEPTION 'action must be enroll | get | list | earn | redeem | adjust (got %)', p_action;
  END IF;
END;
$function$;

-- Auto-earn on completed sales for enrolled customers (opt-in via enroll).
CREATE OR REPLACE FUNCTION public.loyalty_earn_on_pos_sale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_acct_id uuid;
  v_points integer;
  v_lifetime integer;
BEGIN
  IF NEW.customer_email IS NULL OR NEW.status <> 'completed' OR NEW.refund_of IS NOT NULL THEN
    RETURN NEW;
  END IF;
  v_points := floor(GREATEST(NEW.total_cents, 0) / 1000.0)::integer;
  IF v_points <= 0 THEN RETURN NEW; END IF;

  SELECT id INTO v_acct_id FROM public.loyalty_accounts
   WHERE lower(customer_email) = lower(NEW.customer_email) AND active;
  IF v_acct_id IS NULL THEN RETURN NEW; END IF;

  UPDATE public.loyalty_accounts
     SET points_balance = points_balance + v_points,
         lifetime_points = lifetime_points + v_points,
         tier = public.loyalty_tier_for(lifetime_points + v_points),
         updated_at = now()
   WHERE id = v_acct_id
  RETURNING lifetime_points INTO v_lifetime;

  INSERT INTO public.loyalty_transactions (account_id, sale_id, points, kind, note)
  VALUES (v_acct_id, NEW.id, v_points, 'earn', 'Auto-earn on sale ' || NEW.receipt_number);
  RETURN NEW;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'loyalty_earn_on_pos_sale failed: %', SQLERRM;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_pos_sales_loyalty_earn ON public.pos_sales;
CREATE TRIGGER trg_pos_sales_loyalty_earn
  AFTER INSERT ON public.pos_sales
  FOR EACH ROW EXECUTE FUNCTION public.loyalty_earn_on_pos_sale();

-- ── 3. Refund / return workflow ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.refund_pos_sale(
  p_sale_id uuid,
  p_lines jsonb DEFAULT NULL,        -- [{sale_line_id, quantity}] or NULL = full remaining refund
  p_reason text DEFAULT NULL,
  p_method text DEFAULT NULL,        -- tender for refund payment; default = original payment_method
  p_session_id uuid DEFAULT NULL     -- open session to book the refund against (optional)
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sale public.pos_sales%ROWTYPE;
  v_line public.pos_sale_lines%ROWTYPE;
  v_req jsonb;
  v_qty numeric;
  v_already numeric;
  v_refund_id uuid;
  v_receipt text;
  v_subtotal integer := 0;
  v_tax integer := 0;
  v_total integer := 0;
  v_line_subtotal integer;
  v_line_tax integer;
  v_method text;
  v_refunded_before integer;
  v_count int := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only staff can refund POS sales';
  END IF;

  SELECT * INTO v_sale FROM public.pos_sales WHERE id = p_sale_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale % not found', p_sale_id; END IF;
  IF v_sale.refund_of IS NOT NULL THEN RAISE EXCEPTION 'Sale % is itself a refund', p_sale_id; END IF;
  IF v_sale.status NOT IN ('completed','refunded','partially_refunded') THEN
    RAISE EXCEPTION 'Only completed sales can be refunded (status %)', v_sale.status;
  END IF;

  v_method := COALESCE(p_method, CASE WHEN v_sale.payment_method = 'split' THEN 'cash' ELSE v_sale.payment_method END, 'cash');
  v_receipt := 'RF-' || to_char(now(), 'YYYYMMDD') || '-' || lpad((EXTRACT(EPOCH FROM now())::bigint % 100000)::text, 5, '0');

  -- Total already refunded (positive number)
  SELECT COALESCE(-SUM(total_cents), 0) INTO v_refunded_before
  FROM public.pos_sales WHERE refund_of = p_sale_id;

  INSERT INTO public.pos_sales
    (receipt_number, register_id, session_id, customer_id, customer_email,
     subtotal_cents, tax_cents, discount_cents, total_cents, currency,
     payment_method, status, refund_of, refund_reason, metadata)
  VALUES
    (v_receipt, v_sale.register_id, p_session_id, v_sale.customer_id, v_sale.customer_email,
     0, 0, 0, 0, v_sale.currency, v_method, 'completed', p_sale_id, p_reason,
     jsonb_build_object('original_receipt', v_sale.receipt_number))
  RETURNING id INTO v_refund_id;

  FOR v_line IN SELECT * FROM public.pos_sale_lines WHERE sale_id = p_sale_id
  LOOP
    v_qty := NULL;
    IF p_lines IS NULL THEN
      v_qty := v_line.quantity;
    ELSE
      SELECT (r->>'quantity')::numeric INTO v_qty
      FROM jsonb_array_elements(p_lines) r
      WHERE (r->>'sale_line_id')::uuid = v_line.id;
    END IF;
    CONTINUE WHEN v_qty IS NULL OR v_qty <= 0;

    -- Cap at what remains refundable for this line
    SELECT COALESCE(-SUM(rl.quantity), 0) INTO v_already
    FROM public.pos_sale_lines rl
    JOIN public.pos_sales rs ON rs.id = rl.sale_id
    WHERE rs.refund_of = p_sale_id
      AND rl.product_name = v_line.product_name
      AND COALESCE(rl.product_id::text,'') = COALESCE(v_line.product_id::text,'')
      AND rl.sale_id <> v_refund_id;
    IF v_qty > v_line.quantity - v_already THEN
      RAISE EXCEPTION 'Refund quantity % exceeds remaining % for line "%"',
        v_qty, v_line.quantity - v_already, v_line.product_name;
    END IF;

    v_line_subtotal := -round((v_line.unit_price_cents * v_qty)
                       - (COALESCE(v_line.discount_cents,0) * v_qty / v_line.quantity))::integer;
    v_line_tax := round(v_line_subtotal * COALESCE(v_line.tax_rate,0) / 100.0)::integer;

    INSERT INTO public.pos_sale_lines
      (sale_id, product_id, product_name, sku, quantity, unit_price_cents, discount_cents, tax_rate, line_total_cents)
    VALUES
      (v_refund_id, v_line.product_id, v_line.product_name, v_line.sku, -v_qty,
       v_line.unit_price_cents, 0, v_line.tax_rate, v_line_subtotal + v_line_tax);

    v_subtotal := v_subtotal + v_line_subtotal;
    v_tax := v_tax + v_line_tax;
    v_total := v_total + v_line_subtotal + v_line_tax;
    v_count := v_count + 1;

    -- Restock returned goods
    IF v_line.product_id IS NOT NULL THEN
      PERFORM public.emit_platform_event(
        'stock.movement',
        jsonb_build_object(
          'product_id', v_line.product_id,
          'qty_delta', v_qty,
          'quantity', v_qty,
          'reason', 'pos_refund',
          'reference_type', 'pos_sale',
          'reference_id', v_refund_id,
          'sku', v_line.sku
        ),
        'pos');
    END IF;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Nothing to refund — no matching lines (already fully refunded?)';
  END IF;
  IF v_refunded_before - v_total > v_sale.total_cents THEN
    RAISE EXCEPTION 'Refund exceeds original sale total: original %, already refunded %, this refund %',
      v_sale.total_cents, v_refunded_before, -v_total;
  END IF;

  UPDATE public.pos_sales
     SET subtotal_cents = v_subtotal, tax_cents = v_tax, total_cents = v_total
   WHERE id = v_refund_id;

  INSERT INTO public.pos_payments (sale_id, method, amount_cents, reference)
  VALUES (v_refund_id, v_method, v_total, 'refund of ' || v_sale.receipt_number);

  -- Reverse loyalty points earned on the refunded portion
  UPDATE public.loyalty_accounts a
     SET points_balance = points_balance - floor(-v_total / 1000.0)::integer,
         updated_at = now()
   WHERE lower(a.customer_email) = lower(COALESCE(v_sale.customer_email,''))
     AND floor(-v_total / 1000.0)::integer > 0;

  UPDATE public.pos_sales
     SET status = CASE WHEN v_refunded_before - v_total >= total_cents THEN 'refunded' ELSE 'partially_refunded' END
   WHERE id = p_sale_id;

  IF p_session_id IS NOT NULL THEN
    UPDATE public.pos_sessions
       SET total_sales_cents = total_sales_cents + v_total
     WHERE id = p_session_id AND status = 'open';
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'refund_sale_id', v_refund_id,
    'receipt_number', v_receipt,
    'refund_total_cents', v_total,
    'original_sale_id', p_sale_id,
    'original_status', (SELECT status FROM public.pos_sales WHERE id = p_sale_id),
    'lines_refunded', v_count
  );
END;
$function$;

-- ── 4. Receipt → invoice linking ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pos_sale_to_invoice(
  p_sale_id uuid,
  p_customer_name text DEFAULT NULL,
  p_customer_email text DEFAULT NULL,
  p_due_in_days integer DEFAULT 30
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sale public.pos_sales%ROWTYPE;
  v_email text;
  v_invoice_id uuid;
  v_invoice_number text;
  v_lines jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only staff can create invoices from POS sales';
  END IF;
  SELECT * INTO v_sale FROM public.pos_sales WHERE id = p_sale_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale % not found', p_sale_id; END IF;
  IF v_sale.invoice_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'invoice_id', v_sale.invoice_id,
      'already_linked', true,
      'invoice_number', (SELECT invoice_number FROM public.invoices WHERE id = v_sale.invoice_id));
  END IF;
  IF v_sale.refund_of IS NOT NULL THEN RAISE EXCEPTION 'Cannot invoice a refund sale'; END IF;

  v_email := COALESCE(p_customer_email, v_sale.customer_email);
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'customer_email is required (sale has none on record)';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'description', l.product_name || CASE WHEN l.sku IS NOT NULL THEN ' (' || l.sku || ')' ELSE '' END,
      'quantity', l.quantity,
      'unit_price_cents', l.unit_price_cents,
      'total_cents', l.line_total_cents
    )), '[]'::jsonb)
  INTO v_lines
  FROM public.pos_sale_lines l WHERE l.sale_id = p_sale_id;

  v_invoice_number := 'POS-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || lpad(floor(random()*100000)::text, 5, '0');

  INSERT INTO public.invoices
    (invoice_number, customer_email, customer_name, status, line_items,
     subtotal_cents, tax_rate, tax_cents, total_cents, currency,
     due_date, issue_date, payment_terms, notes)
  VALUES
    (v_invoice_number, v_email, p_customer_name, 'draft', v_lines,
     v_sale.subtotal_cents, CASE WHEN v_sale.subtotal_cents > 0 THEN round(v_sale.tax_cents::numeric / v_sale.subtotal_cents, 4) ELSE 0 END,
     v_sale.tax_cents, v_sale.total_cents, COALESCE(v_sale.currency,'SEK'),
     CURRENT_DATE + COALESCE(p_due_in_days,30), CURRENT_DATE,
     'Net ' || COALESCE(p_due_in_days,30) || ' days',
     'Generated from POS receipt ' || v_sale.receipt_number)
  RETURNING id INTO v_invoice_id;

  UPDATE public.pos_sales SET invoice_id = v_invoice_id WHERE id = p_sale_id;

  RETURN jsonb_build_object('success', true, 'invoice_id', v_invoice_id,
    'invoice_number', v_invoice_number, 'sale_id', p_sale_id,
    'total_cents', v_sale.total_cents);
END;
$function$;

-- ── 5. Branded receipt rendering ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.render_pos_receipt(p_sale_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sale public.pos_sales%ROWTYPE;
  v_register public.pos_registers%ROWTYPE;
  v_lines jsonb;
  v_payments jsonb;
  v_branding jsonb;
  v_general jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can render receipts';
  END IF;
  SELECT * INTO v_sale FROM public.pos_sales WHERE id = p_sale_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Sale % not found', p_sale_id; END IF;
  SELECT * INTO v_register FROM public.pos_registers WHERE id = v_sale.register_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'product_name', l.product_name, 'sku', l.sku, 'quantity', l.quantity,
      'unit_price_cents', l.unit_price_cents, 'discount_cents', l.discount_cents,
      'tax_rate', l.tax_rate, 'line_total_cents', l.line_total_cents
    ) ORDER BY l.created_at), '[]'::jsonb)
  INTO v_lines FROM public.pos_sale_lines l WHERE l.sale_id = p_sale_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'method', p.method, 'amount_cents', p.amount_cents, 'reference', p.reference
    ) ORDER BY p.created_at), '[]'::jsonb)
  INTO v_payments FROM public.pos_payments p WHERE p.sale_id = p_sale_id;

  SELECT value INTO v_branding FROM public.site_settings WHERE key = 'branding';
  SELECT value INTO v_general FROM public.site_settings WHERE key = 'general';

  RETURN jsonb_build_object(
    'success', true,
    'receipt', jsonb_build_object(
      'receipt_number', v_sale.receipt_number,
      'created_at', v_sale.created_at,
      'is_refund', v_sale.refund_of IS NOT NULL,
      'refund_of_sale_id', v_sale.refund_of,
      'refund_reason', v_sale.refund_reason,
      'currency', v_sale.currency,
      'lines', v_lines,
      'payments', v_payments,
      'subtotal_cents', v_sale.subtotal_cents,
      'discount_cents', v_sale.discount_cents,
      'tax_cents', v_sale.tax_cents,
      'tip_cents', COALESCE(v_sale.tip_cents, 0),
      'total_cents', v_sale.total_cents,
      'grand_total_cents', v_sale.total_cents + COALESCE(v_sale.tip_cents, 0),
      'invoice_number', (SELECT invoice_number FROM public.invoices WHERE id = v_sale.invoice_id),
      'table', (SELECT name FROM public.pos_tables WHERE id = v_sale.table_id)
    ),
    'template', jsonb_build_object(
      'header', v_register.receipt_header,
      'footer', v_register.receipt_footer,
      'register_name', v_register.name,
      'register_location', v_register.location,
      'site_branding', v_branding,
      'site_general', v_general
    )
  );
END;
$function$;

-- ── 6. Table / seat management (F&B) ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_pos_table(
  p_action text,
  p_table_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_area text DEFAULT NULL,
  p_seats integer DEFAULT NULL,
  p_register_id uuid DEFAULT NULL,
  p_sale_id uuid DEFAULT NULL,
  p_status text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_table public.pos_tables%ROWTYPE;
  v_rows jsonb;
  v_id uuid;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only staff can manage POS tables';
  END IF;

  IF p_action = 'create' THEN
    IF p_name IS NULL THEN RAISE EXCEPTION 'name is required'; END IF;
    INSERT INTO public.pos_tables (name, area, seats, register_id)
    VALUES (p_name, p_area, COALESCE(p_seats, 4), p_register_id)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('success', true, 'table_id', v_id);

  ELSIF p_action = 'update' THEN
    IF p_table_id IS NULL THEN RAISE EXCEPTION 'table_id is required'; END IF;
    UPDATE public.pos_tables
       SET name = COALESCE(p_name, name), area = COALESCE(p_area, area),
           seats = COALESCE(p_seats, seats), register_id = COALESCE(p_register_id, register_id),
           status = COALESCE(p_status, status), updated_at = now()
     WHERE id = p_table_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Table % not found', p_table_id; END IF;
    RETURN jsonb_build_object('success', true, 'table_id', p_table_id);

  ELSIF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'area', t.area, 'seats', t.seats,
        'status', t.status, 'register_id', t.register_id,
        'current_sale_id', t.current_sale_id,
        'current_receipt', (SELECT receipt_number FROM public.pos_sales WHERE id = t.current_sale_id)
      ) ORDER BY t.area NULLS LAST, t.name), '[]'::jsonb)
    INTO v_rows FROM public.pos_tables t WHERE t.active;
    RETURN jsonb_build_object('success', true, 'tables', v_rows);

  ELSIF p_action = 'delete' THEN
    IF p_table_id IS NULL THEN RAISE EXCEPTION 'table_id is required'; END IF;
    UPDATE public.pos_tables SET active = false, updated_at = now() WHERE id = p_table_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Table % not found', p_table_id; END IF;
    RETURN jsonb_build_object('success', true, 'deactivated', p_table_id);

  ELSIF p_action = 'seat' THEN
    IF p_table_id IS NULL THEN RAISE EXCEPTION 'table_id is required'; END IF;
    SELECT * INTO v_table FROM public.pos_tables WHERE id = p_table_id AND active FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Table % not found', p_table_id; END IF;
    IF v_table.status = 'occupied' THEN RAISE EXCEPTION 'Table % is already occupied', v_table.name; END IF;
    UPDATE public.pos_tables
       SET status = 'occupied', current_sale_id = p_sale_id, updated_at = now()
     WHERE id = p_table_id;
    IF p_sale_id IS NOT NULL THEN
      UPDATE public.pos_sales SET table_id = p_table_id WHERE id = p_sale_id;
    END IF;
    RETURN jsonb_build_object('success', true, 'table_id', p_table_id, 'status', 'occupied', 'sale_id', p_sale_id);

  ELSIF p_action = 'release' THEN
    IF p_table_id IS NULL THEN RAISE EXCEPTION 'table_id is required'; END IF;
    UPDATE public.pos_tables
       SET status = 'free', current_sale_id = NULL, updated_at = now()
     WHERE id = p_table_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Table % not found', p_table_id; END IF;
    RETURN jsonb_build_object('success', true, 'table_id', p_table_id, 'status', 'free');

  ELSE
    RAISE EXCEPTION 'action must be create | update | list | delete | seat | release (got %)', p_action;
  END IF;
END;
$function$;
