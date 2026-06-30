-- Make weekly_business_digest actually aggregate.
--
-- The skill was wired to db:agent_activity (generic CRUD list), so "generate a
-- cross-module business summary" returned raw activity rows instead of the
-- digest. Same dead-handler class as research_content / content_proposal /
-- summarize_candidate_pipeline. This RPC aggregates views/leads/bookings/orders/
-- invoices/deals for the period; the handler is flipped to
-- rpc:weekly_business_digest. Read-only (STABLE). Idempotent + forward-dated.

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
