-- 1. Columns
ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS payment_terms text NOT NULL DEFAULT 'prepaid_card',
  ADD COLUMN IF NOT EXISTS next_invoice_date date,
  ADD COLUMN IF NOT EXISTS billing_interval_count integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS billing_contact_email text,
  ADD COLUMN IF NOT EXISTS po_number text,
  ADD COLUMN IF NOT EXISTS last_invoice_id uuid REFERENCES public.invoices(id) ON DELETE SET NULL;

ALTER TABLE public.subscriptions
  DROP CONSTRAINT IF EXISTS subscriptions_payment_terms_chk;
ALTER TABLE public.subscriptions
  ADD CONSTRAINT subscriptions_payment_terms_chk
  CHECK (payment_terms IN ('prepaid_card','invoice_30','invoice_14','invoice_7','direct_debit','manual'));

CREATE INDEX IF NOT EXISTS idx_subscriptions_next_invoice
  ON public.subscriptions (next_invoice_date)
  WHERE provider = 'manual' AND status = 'active';

-- 2. Helper: advance a date by interval
CREATE OR REPLACE FUNCTION public.advance_billing_date(_from date, _interval text, _count integer)
RETURNS date
LANGUAGE sql IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE lower(_interval)
    WHEN 'day'    THEN _from + (_count || ' days')::interval
    WHEN 'week'   THEN _from + (_count || ' weeks')::interval
    WHEN 'month'  THEN _from + (_count || ' months')::interval
    WHEN 'year'   THEN _from + (_count || ' years')::interval
    ELSE _from + (_count || ' months')::interval
  END::date
$$;

-- 3. create_manual_subscription
CREATE OR REPLACE FUNCTION public.create_manual_subscription(
  _customer_email text,
  _customer_name text,
  _product_name text,
  _unit_amount_cents integer,
  _currency text DEFAULT 'EUR',
  _billing_interval text DEFAULT 'month',
  _billing_interval_count integer DEFAULT 1,
  _quantity integer DEFAULT 1,
  _payment_terms text DEFAULT 'invoice_30',
  _start_date date DEFAULT CURRENT_DATE,
  _billing_contact_email text DEFAULT NULL,
  _po_number text DEFAULT NULL,
  _product_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _new_id uuid;
BEGIN
  IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
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
    jsonb_build_object('created_via', 'create_manual_subscription', 'created_by', auth.uid())
  )
  RETURNING id INTO _new_id;

  PERFORM public.emit_platform_event(
    'subscription.created',
    jsonb_build_object('subscription_id', _new_id, 'provider', 'manual', 'customer_email', _customer_email),
    'create_manual_subscription'
  );

  RETURN jsonb_build_object('ok', true, 'subscription_id', _new_id, 'next_invoice_date', _start_date);
END $$;

-- 4. generate_subscription_invoice
CREATE OR REPLACE FUNCTION public.generate_subscription_invoice(
  _subscription_id uuid,
  _tax_rate numeric DEFAULT NULL,
  _due_in_days integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
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
BEGIN
  IF NOT (has_role(auth.uid(), 'admin'::app_role) OR auth.uid() IS NULL) THEN
    -- allow service_role (auth.uid() NULL) and admins; cron runs as service role
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

  INSERT INTO public.invoices (
    invoice_number, customer_email, customer_name,
    status, line_items, subtotal_cents, tax_rate, tax_cents, total_cents,
    currency, due_date, issue_date, payment_terms, notes
  ) VALUES (
    _invoice_number, _sub.customer_email, _sub.customer_name,
    'draft'::invoice_status, _line, _subtotal, _rate, _tax, _total,
    upper(_sub.currency), _due_date, CURRENT_DATE,
    'Net ' || _due || ' days',
    'Generated from subscription ' || _sub.id::text ||
      CASE WHEN _sub.po_number IS NOT NULL THEN E'\nPO: ' || _sub.po_number ELSE '' END
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
      'currency', upper(_sub.currency)
    ),
    'generate_subscription_invoice'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'invoice_id', _invoice_id,
    'invoice_number', _invoice_number,
    'total_cents', _total,
    'next_invoice_date', _next
  );
END $$;

-- 5. cancel_manual_subscription
CREATE OR REPLACE FUNCTION public.cancel_manual_subscription(
  _subscription_id uuid,
  _reason text DEFAULT NULL,
  _effective_date date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _eff date := COALESCE(_effective_date, CURRENT_DATE);
BEGIN
  IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
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
END $$;

-- 6. Grants
GRANT EXECUTE ON FUNCTION public.create_manual_subscription(text,text,text,integer,text,text,integer,integer,text,date,text,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_subscription_invoice(uuid,numeric,integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_manual_subscription(uuid,text,date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.advance_billing_date(date,text,integer) TO authenticated, service_role;