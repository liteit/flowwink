CREATE OR REPLACE FUNCTION public.lookup_order_tracking(
  p_order_id uuid,
  p_email text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_order record;
  v_items jsonb;
BEGIN
  IF p_order_id IS NULL OR p_email IS NULL OR length(trim(p_email)) = 0 THEN
    RETURN jsonb_build_object('found', false, 'reason', 'missing_params');
  END IF;

  SELECT id, customer_email, customer_name, status, fulfillment_status,
         total_cents, currency, created_at,
         picked_at, packed_at, shipped_at, delivered_at,
         tracking_number, tracking_url
    INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND lower(customer_email) = lower(trim(p_email))
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false, 'reason', 'not_found');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product_name', product_name,
           'quantity', quantity,
           'price_cents', price_cents
         ) ORDER BY product_name), '[]'::jsonb)
    INTO v_items
  FROM public.order_items
  WHERE order_id = v_order.id;

  RETURN jsonb_build_object(
    'found', true,
    'order', jsonb_build_object(
      'id', v_order.id,
      'customer_name', v_order.customer_name,
      'customer_email', v_order.customer_email,
      'status', v_order.status,
      'fulfillment_status', COALESCE(v_order.fulfillment_status, 'unfulfilled'),
      'total_cents', v_order.total_cents,
      'currency', v_order.currency,
      'created_at', v_order.created_at,
      'picked_at', v_order.picked_at,
      'packed_at', v_order.packed_at,
      'shipped_at', v_order.shipped_at,
      'delivered_at', v_order.delivered_at,
      'tracking_number', v_order.tracking_number,
      'tracking_url', v_order.tracking_url
    ),
    'items', v_items
  );
END $$;

GRANT EXECUTE ON FUNCTION public.lookup_order_tracking(uuid, text) TO anon, authenticated, service_role;