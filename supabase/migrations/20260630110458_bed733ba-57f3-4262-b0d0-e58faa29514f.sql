
-- ============= 20260628200000 returns RMA + refund_return ==============
DROP FUNCTION IF EXISTS "public"."refund_return"("uuid", integer, "text");

CREATE OR REPLACE FUNCTION "public"."refund_return"(
  "p_return_id" "uuid",
  "p_refund_cents" integer,
  "p_method" "text" DEFAULT 'manual'::"text",
  "p_final" boolean DEFAULT false
) RETURNS "jsonb"
LANGUAGE "plpgsql" SECURITY DEFINER SET "search_path" TO 'public' AS $$
DECLARE
  v_ret RECORD;
  v_expected bigint;
  v_new_total bigint;
  v_done boolean;
BEGIN
  SELECT * INTO v_ret FROM returns WHERE id = p_return_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Return % not found', p_return_id; END IF;
  IF v_ret.status NOT IN ('received','approved') THEN
    RAISE EXCEPTION 'Return not in refundable state (status %)', v_ret.status;
  END IF;
  IF p_refund_cents IS NULL OR p_refund_cents <= 0 THEN
    RAISE EXCEPTION 'refund_cents must be positive';
  END IF;

  SELECT COALESCE(SUM(quantity * unit_refund_cents), 0) - v_ret.restocking_fee_cents
  INTO v_expected FROM return_items WHERE return_id = p_return_id;
  IF v_expected < 0 THEN v_expected := 0; END IF;

  v_new_total := COALESCE(v_ret.refund_amount_cents, 0) + p_refund_cents;
  IF v_expected > 0 AND v_new_total > v_expected THEN
    RAISE EXCEPTION 'Refund % would exceed expected total % (items − restocking fee %)',
      v_new_total, v_expected, v_ret.restocking_fee_cents;
  END IF;

  v_done := p_final OR (v_expected > 0 AND v_new_total >= v_expected);

  UPDATE returns
     SET refund_amount_cents = v_new_total,
         refund_method = p_method,
         refund_processed_at = now(),
         status = CASE WHEN v_done THEN 'refunded' ELSE status END
   WHERE id = p_return_id;

  RETURN jsonb_build_object('success', true, 'return_id', p_return_id,
    'refunded_cents', v_new_total, 'expected_cents', v_expected,
    'remaining_cents', GREATEST(v_expected - v_new_total, 0),
    'status', CASE WHEN v_done THEN 'refunded' ELSE v_ret.status END);
END $$;

GRANT ALL ON FUNCTION "public"."refund_return"("uuid", integer, "text", boolean)
  TO "anon", "authenticated", "service_role";

CREATE OR REPLACE FUNCTION "public"."tg_returns_set_rma_number"() RETURNS "trigger"
LANGUAGE "plpgsql" SET "search_path" TO 'public' AS $$
BEGIN
  IF NEW.rma_number IS NULL OR btrim(NEW.rma_number) = '' THEN
    NEW.rma_number := public.generate_rma_number();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS "trg_returns_set_rma_number" ON "public"."returns";
CREATE TRIGGER "trg_returns_set_rma_number"
  BEFORE INSERT ON "public"."returns"
  FOR EACH ROW EXECUTE FUNCTION "public"."tg_returns_set_rma_number"();

-- ============= 20260628210000 service-role escape pt1 ==============
CREATE OR REPLACE FUNCTION public.create_manual_subscription(_customer_email text, _customer_name text, _product_name text, _unit_amount_cents integer, _currency text DEFAULT 'EUR'::text, _billing_interval text DEFAULT 'month'::text, _billing_interval_count integer DEFAULT 1, _quantity integer DEFAULT 1, _payment_terms text DEFAULT 'invoice_30'::text, _start_date date DEFAULT CURRENT_DATE, _billing_contact_email text DEFAULT NULL::text, _po_number text DEFAULT NULL::text, _product_id uuid DEFAULT NULL::uuid, _auto_finalize boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE _new_id uuid;
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
    auto_finalize, metadata
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
  ) RETURNING id INTO _new_id;
  PERFORM public.emit_platform_event(
    'subscription.created',
    jsonb_build_object('subscription_id', _new_id, 'provider', 'manual', 'customer_email', _customer_email, 'auto_finalize', COALESCE(_auto_finalize, false)),
    'create_manual_subscription'
  );
  RETURN jsonb_build_object('ok', true, 'subscription_id', _new_id, 'next_invoice_date', _start_date, 'auto_finalize', COALESCE(_auto_finalize, false));
END $function$;

CREATE OR REPLACE FUNCTION public.create_payroll_run(p_period_date date)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_run_id UUID; v_emp RECORD;
  v_gross BIGINT; v_benefits BIGINT; v_deductions BIGINT;
  v_taxable BIGINT; v_tax BIGINT; v_social BIGINT; v_net BIGINT;
  v_components JSONB;
  v_total_gross BIGINT := 0; v_total_tax BIGINT := 0; v_total_social BIGINT := 0; v_total_net BIGINT := 0;
  v_lines INT := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin')) THEN
    RAISE EXCEPTION 'Only admins can create payroll runs';
  END IF;
  INSERT INTO public.payroll_runs (period_date, status)
  VALUES (date_trunc('month', p_period_date)::date, 'draft')
  RETURNING id INTO v_run_id;
  FOR v_emp IN
    SELECT id, COALESCE(monthly_salary_cents,0) AS base, COALESCE(tax_rate_pct,30.00) AS tax_pct
    FROM public.employees WHERE COALESCE(status,'active') = 'active'
  LOOP
    v_gross := v_emp.base; v_benefits := 0; v_deductions := 0; v_components := '[]'::jsonb;
    SELECT
      COALESCE(SUM(CASE WHEN component_type IN ('salary','bonus','overtime') AND taxable THEN amount_cents ELSE 0 END),0),
      COALESCE(SUM(CASE WHEN component_type='benefit' THEN amount_cents ELSE 0 END),0),
      COALESCE(SUM(CASE WHEN component_type='deduction' THEN amount_cents ELSE 0 END),0),
      COALESCE(jsonb_agg(jsonb_build_object('type',component_type,'label',label,'amount_cents',amount_cents,'taxable',taxable)),'[]'::jsonb)
    INTO v_gross, v_benefits, v_deductions, v_components
    FROM (SELECT component_type, label, amount_cents, taxable FROM public.payroll_components
          WHERE employee_id = v_emp.id AND active AND recurring) c;
    v_gross := COALESCE(v_emp.base,0) + COALESCE(v_gross,0);
    v_taxable := v_gross + v_benefits - v_deductions;
    v_tax := ROUND(v_taxable * v_emp.tax_pct / 100.0);
    v_social := ROUND(v_taxable * 31.42 / 100.0);
    v_net := v_taxable - v_tax;
    INSERT INTO public.payroll_lines (run_id, employee_id, gross_cents, benefits_cents, deductions_cents, taxable_cents, tax_cents, social_fee_cents, net_cents, components)
    VALUES (v_run_id, v_emp.id, v_gross, v_benefits, v_deductions, v_taxable, v_tax, v_social, v_net, v_components);
    v_total_gross := v_total_gross + v_gross; v_total_tax := v_total_tax + v_tax;
    v_total_social := v_total_social + v_social; v_total_net := v_total_net + v_net;
    v_lines := v_lines + 1;
  END LOOP;
  UPDATE public.payroll_runs
    SET total_gross_cents=v_total_gross, total_tax_cents=v_total_tax,
        total_social_fee_cents=v_total_social, total_net_cents=v_total_net
  WHERE id = v_run_id;
  RETURN jsonb_build_object('success',true,'run_id',v_run_id,'lines',v_lines,
    'total_gross_cents',v_total_gross,'total_tax_cents',v_total_tax,
    'total_social_fee_cents',v_total_social,'total_net_cents',v_total_net);
END; $function$;

-- ============= 20260629120000 mo_number autogen ==============
CREATE OR REPLACE FUNCTION "public"."tg_mo_set_mo_number"() RETURNS "trigger"
LANGUAGE "plpgsql" SET "search_path" TO 'public' AS $$
BEGIN
  IF NEW.mo_number IS NULL OR btrim(NEW.mo_number) = '' THEN
    NEW.mo_number := public.next_mo_number();
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "trg_mo_set_mo_number" ON "public"."manufacturing_orders";
CREATE TRIGGER "trg_mo_set_mo_number"
  BEFORE INSERT ON "public"."manufacturing_orders"
  FOR EACH ROW EXECUTE FUNCTION "public"."tg_mo_set_mo_number"();

-- ============= 20260630120000 job_postings slug autogen ==============
CREATE OR REPLACE FUNCTION "public"."tg_job_postings_set_slug"() RETURNS "trigger"
LANGUAGE "plpgsql" SET "search_path" TO 'public' AS $$
DECLARE base text; cand text; n int := 0;
BEGIN
  IF NEW.slug IS NOT NULL AND btrim(NEW.slug) <> '' THEN RETURN NEW; END IF;
  base := btrim(lower(regexp_replace(COALESCE(NEW.title, ''), '[^a-z0-9]+', '-', 'gi')), '-');
  IF base = '' THEN base := 'job'; END IF;
  cand := base;
  WHILE EXISTS (SELECT 1 FROM job_postings WHERE slug = cand) LOOP
    n := n + 1; cand := base || '-' || n;
  END LOOP;
  NEW.slug := cand;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS "trg_job_postings_set_slug" ON "public"."job_postings";
CREATE TRIGGER "trg_job_postings_set_slug"
  BEFORE INSERT ON "public"."job_postings"
  FOR EACH ROW EXECUTE FUNCTION "public"."tg_job_postings_set_slug"();

-- ============= 20260630130000 summarize_candidate_pipeline ==============
DROP FUNCTION IF EXISTS "public"."summarize_candidate_pipeline"(int);
CREATE OR REPLACE FUNCTION "public"."summarize_candidate_pipeline"(
  "p_job_id" "uuid" DEFAULT NULL, "p_stuck_threshold_days" int DEFAULT 7
) RETURNS "jsonb"
LANGUAGE "plpgsql" STABLE SECURITY DEFINER SET "search_path" TO 'public' AS $$
DECLARE v_by_stage jsonb; v_stuck jsonb; v_top jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_by_stage FROM (
    SELECT jp.title AS job, a.stage::text AS stage, count(*) AS n
    FROM applications a LEFT JOIN job_postings jp ON jp.id = a.job_posting_id
    WHERE (p_job_id IS NULL OR a.job_posting_id = p_job_id)
    GROUP BY jp.title, a.stage ORDER BY jp.title, a.stage) x;
  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_stuck FROM (
    SELECT a.id, a.candidate_name, a.stage::text AS stage,
           EXTRACT(DAY FROM now() - a.updated_at)::int AS days_in_stage
    FROM applications a
    WHERE (p_job_id IS NULL OR a.job_posting_id = p_job_id)
      AND a.hired_at IS NULL AND a.rejected_reason IS NULL
      AND a.updated_at < now() - make_interval(days => GREATEST(p_stuck_threshold_days, 1))
    ORDER BY a.updated_at ASC LIMIT 50) x;
  SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) INTO v_top FROM (
    SELECT a.id, a.candidate_name, a.ai_score, a.stage::text AS stage
    FROM applications a
    WHERE (p_job_id IS NULL OR a.job_posting_id = p_job_id)
      AND a.ai_score IS NOT NULL AND a.hired_at IS NULL AND a.rejected_reason IS NULL
    ORDER BY a.ai_score DESC LIMIT 10) x;
  RETURN jsonb_build_object('success', true, 'stuck_threshold_days', p_stuck_threshold_days,
    'totals_by_stage', v_by_stage, 'stuck_applications', v_stuck, 'top_unreviewed', v_top);
END $$;
GRANT EXECUTE ON FUNCTION "public"."summarize_candidate_pipeline"("uuid", int)
  TO "anon", "authenticated", "service_role";

-- ============= 20260630140000 weekly_business_digest ==============
CREATE OR REPLACE FUNCTION "public"."weekly_business_digest"(
  "p_period" "text" DEFAULT 'week', "p_format" "text" DEFAULT 'json'
) RETURNS "jsonb"
LANGUAGE "plpgsql" STABLE SECURITY DEFINER SET "search_path" TO 'public' AS $$
DECLARE v_since timestamptz;
BEGIN
  v_since := now() - CASE lower(COALESCE(p_period,'week'))
    WHEN 'today' THEN interval '1 day'
    WHEN 'day' THEN interval '1 day'
    WHEN 'month' THEN interval '30 days'
    ELSE interval '7 days' END;
  RETURN jsonb_build_object('success', true, 'period', COALESCE(p_period,'week'), 'since', v_since,
    'page_views', (SELECT count(*) FROM page_views WHERE created_at >= v_since),
    'new_leads', (SELECT count(*) FROM leads WHERE created_at >= v_since),
    'bookings', (SELECT count(*) FROM bookings WHERE created_at >= v_since),
    'orders', (SELECT count(*) FROM orders WHERE created_at >= v_since),
    'order_revenue_cents', (SELECT COALESCE(SUM(total_cents),0) FROM orders WHERE created_at >= v_since AND status = 'paid'),
    'invoices', (SELECT count(*) FROM invoices WHERE created_at >= v_since),
    'invoiced_cents', (SELECT COALESCE(SUM(total_cents),0) FROM invoices WHERE created_at >= v_since),
    'new_deals', (SELECT count(*) FROM deals WHERE created_at >= v_since),
    'deal_value_cents', (SELECT COALESCE(SUM(value_cents),0) FROM deals WHERE created_at >= v_since));
END $$;
GRANT EXECUTE ON FUNCTION "public"."weekly_business_digest"("text","text")
  TO "anon", "authenticated", "service_role";

NOTIFY pgrst, 'reload schema';
