-- Rename subscription RPC parameters from `_x` to `p_x` so they match the
-- agent-execute dispatch convention (it strips `_`-prefixed agent-internal
-- fields and prefixes the rest with `p_`). Previously every subscription
-- write failed via MCP/FlowPilot because `p_customer_email` never matched
-- the `_customer_email` parameter. Direct callers (cron + admin UI) are
-- updated in the same change to use the new `p_` names.
--
-- CREATE OR REPLACE cannot rename parameters, so we DROP the old signatures
-- first (idempotent), then CREATE with `p_`-prefixed params.

DROP FUNCTION IF EXISTS public.create_manual_subscription(text, text, text, integer, text, text, integer, integer, text, date, text, text, uuid, boolean);
DROP FUNCTION IF EXISTS public.cancel_manual_subscription(uuid, text, date);
DROP FUNCTION IF EXISTS public.generate_subscription_invoice(uuid, numeric, integer);

CREATE OR REPLACE FUNCTION public.create_manual_subscription(
  p_customer_email text,
  p_customer_name text,
  p_product_name text,
  p_unit_amount_cents integer,
  p_currency text DEFAULT 'EUR'::text,
  p_billing_interval text DEFAULT 'month'::text,
  p_billing_interval_count integer DEFAULT 1,
  p_quantity integer DEFAULT 1,
  p_payment_terms text DEFAULT 'invoice_30'::text,
  p_start_date date DEFAULT CURRENT_DATE,
  p_billing_contact_email text DEFAULT NULL::text,
  p_po_number text DEFAULT NULL::text,
  p_product_id uuid DEFAULT NULL::uuid,
  p_auto_finalize boolean DEFAULT false
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _new_id uuid;
BEGIN
  IF NOT has_role(auth.uid(), 'admin'::app_role) THEN
    RAISE EXCEPTION 'Only admins can create manual subscriptions';
  END IF;

  IF p_customer_email IS NULL OR length(trim(p_customer_email)) = 0 THEN
    RAISE EXCEPTION 'customer_email is required';
  END IF;
  IF p_unit_amount_cents IS NULL OR p_unit_amount_cents <= 0 THEN
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
    lower(trim(p_customer_email)), p_customer_name, p_product_name, p_product_id,
    p_unit_amount_cents, lower(p_currency), GREATEST(1, p_quantity),
    lower(p_billing_interval), GREATEST(1, p_billing_interval_count),
    p_payment_terms, p_billing_contact_email, p_po_number,
    'manual', 'active'::subscription_status,
    p_start_date::timestamptz,
    advance_billing_date(p_start_date, p_billing_interval, p_billing_interval_count)::timestamptz,
    p_start_date,
    COALESCE(p_auto_finalize, false),
    jsonb_build_object('created_via', 'create_manual_subscription', 'created_by', auth.uid(), 'auto_finalize', COALESCE(p_auto_finalize, false))
  )
  RETURNING id INTO _new_id;

  PERFORM public.emit_platform_event(
    'subscription.created',
    jsonb_build_object('subscription_id', _new_id, 'provider', 'manual', 'customer_email', p_customer_email, 'auto_finalize', COALESCE(p_auto_finalize, false)),
    'create_manual_subscription'
  );

  RETURN jsonb_build_object('ok', true, 'subscription_id', _new_id, 'next_invoice_date', p_start_date, 'auto_finalize', COALESCE(p_auto_finalize, false));
END $function$;

CREATE OR REPLACE FUNCTION public.cancel_manual_subscription(
  p_subscription_id uuid,
  p_reason text DEFAULT NULL::text,
  p_effective_date date DEFAULT NULL::date
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _eff date := COALESCE(p_effective_date, CURRENT_DATE);
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
      metadata = metadata || jsonb_build_object('cancel_reason', p_reason, 'canceled_by', auth.uid()),
      updated_at = now()
  WHERE id = p_subscription_id AND provider = 'manual';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manual subscription % not found', p_subscription_id;
  END IF;

  PERFORM public.emit_platform_event(
    'subscription.canceled',
    jsonb_build_object('subscription_id', p_subscription_id, 'reason', p_reason, 'effective_date', _eff),
    'cancel_manual_subscription'
  );

  RETURN jsonb_build_object('ok', true, 'subscription_id', p_subscription_id, 'effective_date', _eff);
END $function$;

CREATE OR REPLACE FUNCTION public.generate_subscription_invoice(
  p_subscription_id uuid,
  p_tax_rate numeric DEFAULT NULL::numeric,
  p_due_in_days integer DEFAULT NULL::integer
)
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
  IF NOT (has_role(auth.uid(), 'admin'::app_role) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Only admins or system can generate subscription invoices';
  END IF;

  SELECT * INTO _sub FROM public.subscriptions WHERE id = p_subscription_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription % not found', p_subscription_id;
  END IF;

  IF _sub.provider <> 'manual' THEN
    RAISE EXCEPTION 'generate_subscription_invoice only applies to manual subscriptions (got %)', _sub.provider;
  END IF;

  IF _sub.status <> 'active'::subscription_status THEN
    RAISE EXCEPTION 'Cannot invoice subscription in status %', _sub.status;
  END IF;

  _subtotal := _sub.unit_amount_cents * COALESCE(_sub.quantity, 1);
  _rate := COALESCE(p_tax_rate, 0.25);
  _tax := round(_subtotal * _rate)::integer;
  _total := _subtotal + _tax;

  _due := COALESCE(
    p_due_in_days,
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
  WHERE id = p_subscription_id;

  PERFORM public.emit_platform_event(
    'subscription.invoiced',
    jsonb_build_object(
      'subscription_id', p_subscription_id,
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
        'subscription_id', p_subscription_id,
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
END $function$;
