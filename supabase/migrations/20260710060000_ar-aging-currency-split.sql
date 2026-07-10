-- ar_aging_report: never sum cents across currencies.
--
-- Multi-currency seam QA 2026-07-10: the report grouped per customer with MAX(currency)
-- and summed outstanding_cents across ALL currencies — a customer with a 1250 EUR and a
-- 1250 SEK open invoice showed total_outstanding 250000 "SEK" (EUR-cents + SEK-öre added
-- raw). 1250 EUR ≈ 14000 SEK, so receivables were garbage whenever a non-SEK invoice
-- existed. Reports must group per currency; presentation-currency conversion is
-- consolidation_report's job, not silent addition.
--
-- Fix: group per (customer, currency) — one row per currency, the row's currency field is
-- now exact (the UI already formats each row by its currency). Top-level `buckets` keeps its
-- shape for the existing UI but sums ONLY the dominant currency (tagged with `currency` and
-- `mixed_currencies`), and a new `buckets_by_currency` array carries the full picture.
-- Idempotent CREATE OR REPLACE.
CREATE OR REPLACE FUNCTION public.ar_aging_report(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_customers jsonb; v_by_currency jsonb; v_buckets jsonb; v_dominant text; v_mixed boolean;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin') OR has_role(auth.uid(), 'approver')) THEN
    RAISE EXCEPTION 'Not authorized to view the AR aging report';
  END IF;

  WITH open_invoices AS (
    SELECT
      i.id,
      COALESCE(l.name, NULLIF(i.customer_name, ''), 'Unknown customer') AS customer_name,
      COALESCE(l.email, i.customer_email, '') AS customer_email,
      i.lead_id,
      UPPER(COALESCE(i.currency, 'SEK')) AS currency,
      GREATEST(0, i.total_cents - COALESCE(i.paid_amount_cents, 0))::bigint AS outstanding_cents,
      (p_as_of - COALESCE(i.due_date, i.issue_date)) AS days_overdue
    FROM invoices i
    LEFT JOIN leads l ON l.id = i.lead_id
    WHERE i.invoice_type = 'invoice'
      AND i.status::text <> 'cancelled'
      AND (i.total_cents - COALESCE(i.paid_amount_cents, 0)) > 0
  ),
  per_customer AS (
    SELECT
      customer_name, customer_email, lead_id, currency,
      SUM(CASE WHEN days_overdue <= 0 THEN outstanding_cents ELSE 0 END) AS current_cents,
      SUM(CASE WHEN days_overdue BETWEEN 1 AND 30 THEN outstanding_cents ELSE 0 END) AS overdue_1_30_cents,
      SUM(CASE WHEN days_overdue BETWEEN 31 AND 60 THEN outstanding_cents ELSE 0 END) AS overdue_31_60_cents,
      SUM(CASE WHEN days_overdue BETWEEN 61 AND 90 THEN outstanding_cents ELSE 0 END) AS overdue_61_90_cents,
      SUM(CASE WHEN days_overdue > 90 THEN outstanding_cents ELSE 0 END) AS overdue_90_plus_cents,
      SUM(outstanding_cents) AS total_outstanding_cents,
      COUNT(*) AS invoice_count
    FROM open_invoices
    GROUP BY customer_name, customer_email, lead_id, currency
  ),
  per_currency AS (
    SELECT currency,
      SUM(current_cents) AS current_cents,
      SUM(overdue_1_30_cents) AS overdue_1_30_cents,
      SUM(overdue_31_60_cents) AS overdue_31_60_cents,
      SUM(overdue_61_90_cents) AS overdue_61_90_cents,
      SUM(overdue_90_plus_cents) AS overdue_90_plus_cents,
      SUM(total_outstanding_cents) AS total_outstanding_cents,
      SUM(invoice_count) AS invoice_count
    FROM per_customer GROUP BY currency
  )
  SELECT
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'customer_name', customer_name, 'customer_email', customer_email, 'lead_id', lead_id,
      'currency', currency,
      'current_cents', current_cents, 'overdue_1_30_cents', overdue_1_30_cents,
      'overdue_31_60_cents', overdue_31_60_cents, 'overdue_61_90_cents', overdue_61_90_cents,
      'overdue_90_plus_cents', overdue_90_plus_cents,
      'total_outstanding_cents', total_outstanding_cents, 'invoice_count', invoice_count
    ) ORDER BY total_outstanding_cents DESC) FROM per_customer), '[]'::jsonb),
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'currency', currency,
      'current_cents', current_cents, 'overdue_1_30_cents', overdue_1_30_cents,
      'overdue_31_60_cents', overdue_31_60_cents, 'overdue_61_90_cents', overdue_61_90_cents,
      'overdue_90_plus_cents', overdue_90_plus_cents,
      'total_outstanding_cents', total_outstanding_cents
    ) ORDER BY total_outstanding_cents DESC) FROM per_currency), '[]'::jsonb),
    (SELECT currency FROM per_currency ORDER BY invoice_count DESC, total_outstanding_cents DESC LIMIT 1),
    (SELECT COUNT(*) > 1 FROM per_currency)
  INTO v_customers, v_by_currency, v_dominant, v_mixed;

  SELECT jsonb_build_object(
    'currency', v_dominant,
    'mixed_currencies', COALESCE(v_mixed, false),
    'current_cents', COALESCE((c->>'current_cents')::bigint, 0),
    'overdue_1_30_cents', COALESCE((c->>'overdue_1_30_cents')::bigint, 0),
    'overdue_31_60_cents', COALESCE((c->>'overdue_31_60_cents')::bigint, 0),
    'overdue_61_90_cents', COALESCE((c->>'overdue_61_90_cents')::bigint, 0),
    'overdue_90_plus_cents', COALESCE((c->>'overdue_90_plus_cents')::bigint, 0),
    'total_outstanding_cents', COALESCE((c->>'total_outstanding_cents')::bigint, 0)
  ) INTO v_buckets
  FROM (SELECT jsonb_array_elements(v_by_currency) AS c) x
  WHERE x.c->>'currency' = v_dominant;

  RETURN jsonb_build_object(
    'success', true,
    'as_of', p_as_of,
    'buckets', COALESCE(v_buckets, jsonb_build_object('currency', COALESCE(v_dominant,'SEK'), 'mixed_currencies', false,
      'current_cents', 0, 'overdue_1_30_cents', 0, 'overdue_31_60_cents', 0, 'overdue_61_90_cents', 0,
      'overdue_90_plus_cents', 0, 'total_outstanding_cents', 0)),
    'buckets_by_currency', v_by_currency,
    'customers', v_customers
  );
END;
$function$;
