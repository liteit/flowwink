-- 20260705150000 + 20260705160000
CREATE OR REPLACE FUNCTION public.generate_subscription_invoice(_subscription_id uuid, _tax_rate numeric DEFAULT NULL::numeric, _due_in_days integer DEFAULT NULL::integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _sub public.subscriptions%ROWTYPE; _invoice_id uuid; _invoice_number text; _subtotal integer; _tax integer; _total integer; _rate numeric; _due integer; _due_date date; _base date; _next date; _line jsonb; _status invoice_status;
BEGIN
  IF NOT ((auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role)) OR auth.uid() IS NULL) THEN RAISE EXCEPTION 'Only admins or system can generate subscription invoices'; END IF;
  SELECT * INTO _sub FROM public.subscriptions WHERE id = _subscription_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Subscription % not found', _subscription_id; END IF;
  IF _sub.provider <> 'manual' THEN RAISE EXCEPTION 'generate_subscription_invoice only applies to manual subscriptions (got %)', _sub.provider; END IF;
  IF _sub.status <> 'active'::subscription_status THEN RAISE EXCEPTION 'Cannot invoice subscription in status %', _sub.status; END IF;
  IF _sub.next_invoice_date IS NOT NULL AND _sub.next_invoice_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'Subscription % is not due: next invoice date is % (already invoiced through the current period)', _subscription_id, _sub.next_invoice_date;
  END IF;
  _subtotal := _sub.unit_amount_cents * COALESCE(_sub.quantity, 1);
  _rate := COALESCE(_tax_rate, 0.25);
  _tax := round(_subtotal * _rate)::integer;
  _total := _subtotal + _tax;
  _due := COALESCE(_due_in_days, CASE _sub.payment_terms WHEN 'invoice_30' THEN 30 WHEN 'invoice_14' THEN 14 WHEN 'invoice_7' THEN 7 ELSE 30 END);
  _due_date := CURRENT_DATE + _due;
  _invoice_number := 'SUB-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' || lpad(floor(random()*100000)::text, 5, '0');
  _line := jsonb_build_array(jsonb_build_object('description', _sub.product_name || ' (' || to_char(COALESCE(_sub.current_period_start, now()), 'YYYY-MM-DD') || ' → ' || to_char(COALESCE(_sub.current_period_end, now()), 'YYYY-MM-DD') || ')', 'quantity', _sub.quantity, 'unit_price_cents', _sub.unit_amount_cents, 'total_cents', _subtotal));
  _status := CASE WHEN COALESCE(_sub.auto_finalize, false) THEN 'sent'::invoice_status ELSE 'draft'::invoice_status END;
  INSERT INTO public.invoices (invoice_number, customer_email, customer_name, status, line_items, subtotal_cents, tax_rate, tax_cents, total_cents, currency, due_date, issue_date, payment_terms, notes, sent_at)
  VALUES (_invoice_number, _sub.customer_email, _sub.customer_name, _status, _line, _subtotal, _rate, _tax, _total, upper(_sub.currency), _due_date, CURRENT_DATE, 'Net ' || _due || ' days', 'Generated from subscription ' || _sub.id::text || CASE WHEN _sub.po_number IS NOT NULL THEN E'\nPO: ' || _sub.po_number ELSE '' END, CASE WHEN _status = 'sent'::invoice_status THEN now() ELSE NULL END)
  RETURNING id INTO _invoice_id;
  _base := COALESCE(_sub.next_invoice_date, CURRENT_DATE);
  _next := advance_billing_date(_base, _sub.billing_interval, _sub.billing_interval_count);
  UPDATE public.subscriptions SET last_invoice_id = _invoice_id, current_period_start = COALESCE(current_period_end, now()), current_period_end = _next::timestamptz, next_invoice_date = _next, updated_at = now() WHERE id = _subscription_id;
  PERFORM public.emit_platform_event('subscription.invoiced', jsonb_build_object('subscription_id', _subscription_id, 'invoice_id', _invoice_id, 'invoice_number', _invoice_number, 'total_cents', _total, 'currency', upper(_sub.currency), 'auto_finalized', COALESCE(_sub.auto_finalize, false), 'status', _status), 'generate_subscription_invoice');
  IF _status = 'sent'::invoice_status THEN
    PERFORM public.emit_platform_event('invoice.finalized', jsonb_build_object('invoice_id', _invoice_id, 'invoice_number', _invoice_number, 'subscription_id', _subscription_id, 'total_cents', _total, 'currency', upper(_sub.currency), 'source', 'subscription_auto_finalize'), 'generate_subscription_invoice');
  END IF;
  RETURN jsonb_build_object('ok', true, 'invoice_id', _invoice_id, 'invoice_number', _invoice_number, 'status', _status, 'auto_finalized', COALESCE(_sub.auto_finalize, false), 'total_cents', _total, 'next_invoice_date', _next);
END $function$;

INSERT INTO public.agent_skills (
  name, description, category, scope, handler, enabled, mcp_exposed, trust_level, origin, tool_definition, instructions
) VALUES (
  'send_webinar_reminders',
  'Sweep webinar registrations and send the due reminder emails: registration confirmation, T-24h, T-1h, and post-webinar follow-up (thanks vs missed-you, with recording link when set). Each reminder is sent at most once per registration (marker columns). Use when: running the periodic webinar-reminder sweep (cron). NOT for: registering attendees (register_webinar) or the webinar lifecycle (publish/start/complete_webinar).',
  'communication',
  'internal',
  'edge:send-webinar-reminders',
  true,
  true,
  'auto',
  'bundled',
  '{"type":"function","function":{"name":"send_webinar_reminders","description":"Send due webinar reminder emails (confirm, T-24h, T-1h, post) and stamp the per-registration markers","parameters":{"type":"object","properties":{}}}}'::jsonb,
  'Runs as a scheduled sweep, no arguments needed. Four reminder kinds, each deduped via its marker column on webinar_registrations: confirm (any unconfirmed registration on a non-cancelled webinar), t24 (webinar starts in 23-25h), t1 (starts in 40-90 min), post (completed webinar, 30+ min after end; variant thanks/missed_you based on attended, includes recording_url when set). Emails go through the email-send pipeline; results are returned per kind as {sent, skipped} plus per-registration errors.'
)
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description,
  handler = EXCLUDED.handler,
  tool_definition = EXCLUDED.tool_definition,
  instructions = EXCLUDED.instructions,
  enabled = true,
  mcp_exposed = true,
  updated_at = now();

INSERT INTO public.agent_automations (
  name, description, trigger_type, trigger_config,
  skill_id, skill_name, skill_arguments, enabled, executor
)
SELECT
  'Webinar Reminders',
  'Platform automation. Sends due webinar reminder emails (confirmation, T-24h, T-1h, post-webinar follow-up) every 15 minutes.',
  'cron',
  '{"cron":"*/15 * * * *","expression":"*/15 * * * *","timezone":"UTC"}'::jsonb,
  s.id,
  'send_webinar_reminders',
  '{}'::jsonb,
  true,
  'platform'
FROM public.agent_skills s
WHERE s.name = 'send_webinar_reminders'
  AND NOT EXISTS (
    SELECT 1 FROM public.agent_automations a WHERE a.name = 'Webinar Reminders'
  );