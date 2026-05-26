
CREATE OR REPLACE FUNCTION public.restock_demo_products()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_updated_stock int := 0;
  v_updated_products int := 0;
BEGIN
  -- Refill product_stock for every tracked product
  WITH upd AS (
    UPDATE public.product_stock ps
    SET quantity_on_hand = GREATEST(50, COALESCE(ps.reorder_point, 5) * 10)
    WHERE COALESCE(ps.reorder_point, 0) >= 0
    RETURNING ps.product_id
  )
  SELECT count(*) INTO v_updated_stock FROM upd;

  -- Mirror to products.stock_quantity so the storefront badges reset too
  WITH upd2 AS (
    UPDATE public.products p
    SET stock_quantity = GREATEST(50, COALESCE(p.low_stock_threshold, 5) * 10)
    WHERE p.track_inventory = true
    RETURNING p.id
  )
  SELECT count(*) INTO v_updated_products FROM upd2;

  RETURN jsonb_build_object(
    'ok', true,
    'product_stock_rows', v_updated_stock,
    'products_rows', v_updated_products,
    'restocked_at', now()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.restock_demo_products() TO service_role;
