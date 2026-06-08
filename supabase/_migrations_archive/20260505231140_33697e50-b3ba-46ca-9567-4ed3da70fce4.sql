
CREATE OR REPLACE FUNCTION public.set_quote_item_selection(
  _accept_token text,
  _item_id uuid,
  _selected boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _quote_id uuid;
  _is_optional boolean;
  _status text;
  _new_subtotal bigint;
  _new_tax bigint;
  _new_total bigint;
  _tax_rate numeric;
BEGIN
  -- locate the quote via token + verify item belongs to it
  SELECT q.id, q.status::text, q.tax_rate, qi.is_optional
    INTO _quote_id, _status, _tax_rate, _is_optional
  FROM quotes q
  JOIN quote_items qi ON qi.quote_id = q.id
  WHERE qi.id = _item_id AND q.accept_token = _accept_token;

  IF _quote_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Quote or item not found');
  END IF;

  IF _status IN ('accepted','rejected','expired') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Quote is finalized');
  END IF;

  IF NOT COALESCE(_is_optional, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Line item is not optional');
  END IF;

  UPDATE quote_items SET selected_by_customer = _selected, updated_at = now()
  WHERE id = _item_id;

  -- recompute quote totals from included lines only
  SELECT COALESCE(SUM(line_subtotal_cents),0), COALESCE(SUM(line_tax_cents),0), COALESCE(SUM(line_total_cents),0)
    INTO _new_subtotal, _new_tax, _new_total
  FROM quote_items
  WHERE quote_id = _quote_id AND (is_optional = false OR selected_by_customer = true);

  UPDATE quotes
     SET subtotal_cents = _new_subtotal,
         tax_cents      = _new_tax,
         total_cents    = _new_total,
         updated_at     = now()
   WHERE id = _quote_id;

  RETURN jsonb_build_object(
    'ok', true,
    'subtotal_cents', _new_subtotal,
    'tax_cents', _new_tax,
    'total_cents', _new_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_quote_item_selection(text, uuid, boolean) TO anon, authenticated;
