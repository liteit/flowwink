-- Shipping: parity round 6 (docs/parity/capabilities/shipping.json)
-- Adds: delivery-date estimation (business-day transit windows per carrier),
-- carrier pickup scheduling, proof-of-delivery capture, return shipping
-- labels, batch label printing, multi-carrier failover selection, address
-- validation (per-country postal rules), and international/customs handling
-- (customs fields + CN22-style declaration generation).
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. Schema additions ──────────────────────────────────────────────────────
ALTER TABLE public.carriers
  ADD COLUMN IF NOT EXISTS priority integer NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS transit_days_min integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS transit_days_max integer NOT NULL DEFAULT 3;

CREATE TABLE IF NOT EXISTS public.shipping_pickups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  carrier_id uuid NOT NULL REFERENCES public.carriers(id) ON DELETE CASCADE,
  pickup_date date NOT NULL,
  window_start time,
  window_end time,
  address text,
  contact_name text,
  contact_phone text,
  instructions text,
  status text NOT NULL DEFAULT 'requested',
  confirmation_ref text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.shipping_pickups DROP CONSTRAINT IF EXISTS shipping_pickups_status_check;
ALTER TABLE public.shipping_pickups
  ADD CONSTRAINT shipping_pickups_status_check
  CHECK (status IN ('requested','confirmed','completed','cancelled'));

ALTER TABLE public.shipping_pickups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage shipping_pickups" ON public.shipping_pickups;
CREATE POLICY "Admins manage shipping_pickups" ON public.shipping_pickups
  FOR ALL
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
DROP POLICY IF EXISTS "Staff view shipping_pickups" ON public.shipping_pickups;
CREATE POLICY "Staff view shipping_pickups" ON public.shipping_pickups
  FOR SELECT
  USING (has_role(auth.uid(), 'admin'::app_role)
      OR has_role(auth.uid(), 'approver'::app_role)
      OR has_role(auth.uid(), 'writer'::app_role));

ALTER TABLE public.shipments
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'outbound',
  ADD COLUMN IF NOT EXISTS return_of_shipment_id uuid REFERENCES public.shipments(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pickup_id uuid REFERENCES public.shipping_pickups(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pod_signature_url text,
  ADD COLUMN IF NOT EXISTS pod_signed_by text,
  ADD COLUMN IF NOT EXISTS pod_signed_at timestamptz,
  ADD COLUMN IF NOT EXISTS pod_photo_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS pod_notes text,
  ADD COLUMN IF NOT EXISTS destination_country text,
  ADD COLUMN IF NOT EXISTS customs_value_cents bigint,
  ADD COLUMN IF NOT EXISTS customs_currency text,
  ADD COLUMN IF NOT EXISTS incoterm text,
  ADD COLUMN IF NOT EXISTS contents_type text,
  ADD COLUMN IF NOT EXISTS customs_items jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS customs_declaration jsonb,
  ADD COLUMN IF NOT EXISTS customs_declared_at timestamptz;

ALTER TABLE public.shipments DROP CONSTRAINT IF EXISTS shipments_kind_check;
ALTER TABLE public.shipments
  ADD CONSTRAINT shipments_kind_check CHECK (kind IN ('outbound','return'));

-- Per-country postal-code validation rules (extensible reference data).
CREATE TABLE IF NOT EXISTS public.postal_code_rules (
  country text PRIMARY KEY,
  pattern text NOT NULL,
  example text
);
ALTER TABLE public.postal_code_rules ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can read postal_code_rules" ON public.postal_code_rules;
CREATE POLICY "Anyone can read postal_code_rules" ON public.postal_code_rules
  FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admins manage postal_code_rules" ON public.postal_code_rules;
CREATE POLICY "Admins manage postal_code_rules" ON public.postal_code_rules
  FOR ALL
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));

INSERT INTO public.postal_code_rules (country, pattern, example) VALUES
  ('SE', '^\d{3} ?\d{2}$',            '114 55'),
  ('NO', '^\d{4}$',                   '0150'),
  ('DK', '^\d{4}$',                   '2100'),
  ('FI', '^\d{5}$',                   '00100'),
  ('DE', '^\d{5}$',                   '10115'),
  ('NL', '^\d{4} ?[A-Za-z]{2}$',      '1012 AB'),
  ('FR', '^\d{5}$',                   '75001'),
  ('ES', '^\d{5}$',                   '28001'),
  ('IT', '^\d{5}$',                   '00100'),
  ('AT', '^\d{4}$',                   '1010'),
  ('BE', '^\d{4}$',                   '1000'),
  ('CH', '^\d{4}$',                   '8001'),
  ('PL', '^\d{2}-\d{3}$',             '00-001'),
  ('GB', '^[A-Za-z]{1,2}\d[A-Za-z\d]? ?\d[A-Za-z]{2}$', 'SW1A 1AA'),
  ('US', '^\d{5}(-\d{4})?$',          '10001'),
  ('CA', '^[A-Za-z]\d[A-Za-z] ?\d[A-Za-z]\d$', 'K1A 0B1')
ON CONFLICT (country) DO NOTHING;

-- ── 2. Delivery-date estimation ──────────────────────────────────────────────
-- Business-day transit: skip weekends + business_holidays (shared with SLA).
CREATE OR REPLACE FUNCTION public.next_business_day(p_from date)
RETURNS date
LANGUAGE plpgsql STABLE
SET search_path TO 'public'
AS $$
DECLARE
  v_day date := p_from;
BEGIN
  WHILE extract(isodow FROM v_day) IN (6,7)
     OR EXISTS (SELECT 1 FROM public.business_holidays WHERE day = v_day)
  LOOP
    v_day := v_day + 1;
  END LOOP;
  RETURN v_day;
END; $$;

CREATE OR REPLACE FUNCTION public.add_business_days(p_from date, p_days integer)
RETURNS date
LANGUAGE plpgsql STABLE
SET search_path TO 'public'
AS $$
DECLARE
  v_day date := p_from;
  v_left integer := GREATEST(p_days, 0);
BEGIN
  WHILE v_left > 0 LOOP
    v_day := public.next_business_day(v_day + 1);
    v_left := v_left - 1;
  END LOOP;
  RETURN v_day;
END; $$;

CREATE OR REPLACE FUNCTION public.estimate_delivery_date(
  p_carrier_id uuid,
  p_ship_date date DEFAULT CURRENT_DATE
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_carrier record;
  v_ships_on date;
BEGIN
  SELECT * INTO v_carrier FROM public.carriers WHERE id = p_carrier_id;
  IF v_carrier.id IS NULL THEN
    RAISE EXCEPTION 'Carrier % not found', p_carrier_id;
  END IF;
  IF NOT v_carrier.is_active THEN
    RETURN jsonb_build_object('success', false, 'reason', 'carrier_inactive');
  END IF;

  v_ships_on := public.next_business_day(COALESCE(p_ship_date, CURRENT_DATE));

  RETURN jsonb_build_object(
    'success', true,
    'carrier_code', v_carrier.code,
    'carrier_name', v_carrier.name,
    'ships_on', v_ships_on,
    'earliest_delivery', public.add_business_days(v_ships_on, v_carrier.transit_days_min),
    'latest_delivery', public.add_business_days(v_ships_on, v_carrier.transit_days_max),
    'transit_days', jsonb_build_object('min', v_carrier.transit_days_min, 'max', v_carrier.transit_days_max)
  );
END; $$;

-- ── 3. Carrier pickup scheduling ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_carrier_pickup(
  p_action text,
  p_pickup_id uuid DEFAULT NULL,
  p_carrier_id uuid DEFAULT NULL,
  p_pickup_date date DEFAULT NULL,
  p_window_start text DEFAULT NULL,
  p_window_end text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_contact_name text DEFAULT NULL,
  p_contact_phone text DEFAULT NULL,
  p_instructions text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_confirmation_ref text DEFAULT NULL,
  p_shipment_ids uuid[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.shipping_pickups;
  v_result jsonb;
  v_assigned integer := 0;
BEGIN
  IF p_action IN ('list','get') THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view pickups';
    END IF;
  ELSE
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
      RAISE EXCEPTION 'Only admins/writers can manage pickups';
    END IF;
  END IF;

  IF p_action = 'request' THEN
    IF p_carrier_id IS NULL OR p_pickup_date IS NULL THEN
      RAISE EXCEPTION 'carrier_id and pickup_date are required';
    END IF;
    IF p_pickup_date < CURRENT_DATE THEN
      RAISE EXCEPTION 'pickup_date cannot be in the past';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.carriers WHERE id = p_carrier_id AND is_active) THEN
      RAISE EXCEPTION 'Carrier % not found or inactive', p_carrier_id;
    END IF;
    INSERT INTO public.shipping_pickups
      (carrier_id, pickup_date, window_start, window_end, address, contact_name, contact_phone, instructions, created_by)
    VALUES
      (p_carrier_id, p_pickup_date, p_window_start::time, p_window_end::time, p_address, p_contact_name, p_contact_phone, p_instructions, auth.uid())
    RETURNING * INTO v_row;

    IF p_shipment_ids IS NOT NULL THEN
      UPDATE public.shipments SET pickup_id = v_row.id, updated_at = now()
       WHERE id = ANY(p_shipment_ids);
      GET DIAGNOSTICS v_assigned = ROW_COUNT;
    END IF;
    RETURN jsonb_build_object('success', true, 'pickup', to_jsonb(v_row), 'shipments_assigned', v_assigned);

  ELSIF p_action = 'assign_shipments' THEN
    IF p_pickup_id IS NULL OR p_shipment_ids IS NULL THEN
      RAISE EXCEPTION 'pickup_id and shipment_ids are required';
    END IF;
    UPDATE public.shipments SET pickup_id = p_pickup_id, updated_at = now()
     WHERE id = ANY(p_shipment_ids);
    GET DIAGNOSTICS v_assigned = ROW_COUNT;
    RETURN jsonb_build_object('success', true, 'shipments_assigned', v_assigned);

  ELSIF p_action = 'update_status' THEN
    IF p_pickup_id IS NULL OR p_status IS NULL THEN
      RAISE EXCEPTION 'pickup_id and status are required';
    END IF;
    UPDATE public.shipping_pickups
       SET status = p_status,
           confirmation_ref = COALESCE(p_confirmation_ref, confirmation_ref),
           updated_at = now()
     WHERE id = p_pickup_id
    RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Pickup % not found', p_pickup_id; END IF;
    RETURN jsonb_build_object('success', true, 'pickup', to_jsonb(v_row));

  ELSIF p_action = 'cancel' THEN
    IF p_pickup_id IS NULL THEN RAISE EXCEPTION 'pickup_id is required'; END IF;
    UPDATE public.shipping_pickups SET status = 'cancelled', updated_at = now()
     WHERE id = p_pickup_id RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Pickup % not found', p_pickup_id; END IF;
    UPDATE public.shipments SET pickup_id = NULL, updated_at = now() WHERE pickup_id = p_pickup_id;
    RETURN jsonb_build_object('success', true, 'pickup', to_jsonb(v_row));

  ELSIF p_action = 'get' THEN
    IF p_pickup_id IS NULL THEN RAISE EXCEPTION 'pickup_id is required'; END IF;
    SELECT jsonb_build_object(
      'success', true,
      'pickup', to_jsonb(p.*),
      'shipments', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'tracking_number', s.tracking_number, 'status', s.status)) FROM public.shipments s WHERE s.pickup_id = p.id), '[]'::jsonb)
    ) INTO v_result
    FROM public.shipping_pickups p WHERE p.id = p_pickup_id;
    IF v_result IS NULL THEN RAISE EXCEPTION 'Pickup % not found', p_pickup_id; END IF;
    RETURN v_result;

  ELSIF p_action = 'list' THEN
    SELECT jsonb_build_object(
      'success', true,
      'pickups', COALESCE(jsonb_agg(jsonb_build_object(
        'id', p.id, 'carrier_code', c.code, 'pickup_date', p.pickup_date,
        'window_start', p.window_start, 'window_end', p.window_end,
        'status', p.status, 'confirmation_ref', p.confirmation_ref,
        'shipment_count', (SELECT count(*) FROM public.shipments s WHERE s.pickup_id = p.id)
      ) ORDER BY p.pickup_date DESC), '[]'::jsonb)
    ) INTO v_result
    FROM public.shipping_pickups p
    JOIN public.carriers c ON c.id = p.carrier_id
    WHERE (p_carrier_id IS NULL OR p.carrier_id = p_carrier_id)
      AND (p_status IS NULL OR p.status = p_status);
    RETURN v_result;
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use request|assign_shipments|update_status|cancel|get|list)', p_action;
END; $$;

-- ── 4. Proof of delivery ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_delivery_proof(
  p_shipment_id uuid,
  p_signature_url text DEFAULT NULL,
  p_signed_by text DEFAULT NULL,
  p_photo_urls text[] DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_ship public.shipments;
  v_all_delivered boolean;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only admins/writers can record delivery proof';
  END IF;
  IF p_signature_url IS NULL AND p_signed_by IS NULL AND (p_photo_urls IS NULL OR array_length(p_photo_urls,1) IS NULL) THEN
    RAISE EXCEPTION 'At least one of signature_url, signed_by, photo_urls is required';
  END IF;

  UPDATE public.shipments
     SET pod_signature_url = COALESCE(p_signature_url, pod_signature_url),
         pod_signed_by = COALESCE(p_signed_by, pod_signed_by),
         pod_signed_at = COALESCE(pod_signed_at, CASE WHEN p_signature_url IS NOT NULL OR p_signed_by IS NOT NULL THEN now() END),
         pod_photo_urls = CASE WHEN p_photo_urls IS NOT NULL
           THEN pod_photo_urls || to_jsonb(p_photo_urls) ELSE pod_photo_urls END,
         pod_notes = COALESCE(p_notes, pod_notes),
         status = 'delivered',
         delivered_at = COALESCE(delivered_at, now()),
         updated_at = now()
   WHERE id = p_shipment_id
  RETURNING * INTO v_ship;
  IF v_ship.id IS NULL THEN RAISE EXCEPTION 'Shipment % not found', p_shipment_id; END IF;

  -- Bubble to the order when every outbound parcel is delivered.
  IF v_ship.order_id IS NOT NULL THEN
    SELECT bool_and(s.status = 'delivered') INTO v_all_delivered
      FROM public.shipments s
     WHERE s.order_id = v_ship.order_id AND s.kind = 'outbound';
    IF v_all_delivered THEN
      UPDATE public.orders
         SET delivered_at = COALESCE(delivered_at, now()),
             fulfillment_status = 'delivered',
             updated_at = now()
       WHERE id = v_ship.order_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'shipment', to_jsonb(v_ship), 'order_marked_delivered', COALESCE(v_all_delivered, false));
END; $$;

-- ── 5. Return shipping labels ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_return_label(
  p_shipment_id uuid DEFAULT NULL,
  p_order_id uuid DEFAULT NULL,
  p_carrier_id uuid DEFAULT NULL,
  p_weight_grams integer DEFAULT NULL,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_orig public.shipments;
  v_order public.orders;
  v_carrier public.carriers;
  v_new public.shipments;
  v_tracking text;
  v_label jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only admins/writers can create return labels';
  END IF;

  IF p_shipment_id IS NOT NULL THEN
    SELECT * INTO v_orig FROM public.shipments WHERE id = p_shipment_id;
    IF v_orig.id IS NULL THEN RAISE EXCEPTION 'Shipment % not found', p_shipment_id; END IF;
    IF v_orig.kind = 'return' THEN RAISE EXCEPTION 'Cannot create a return for a return shipment'; END IF;
  ELSIF p_order_id IS NULL THEN
    RAISE EXCEPTION 'shipment_id or order_id is required';
  END IF;

  IF COALESCE(v_orig.order_id, p_order_id) IS NOT NULL THEN
    SELECT * INTO v_order FROM public.orders WHERE id = COALESCE(v_orig.order_id, p_order_id);
    IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order % not found', p_order_id; END IF;
  END IF;

  SELECT * INTO v_carrier FROM public.carriers
   WHERE id = COALESCE(p_carrier_id, v_orig.carrier_id) AND is_active;
  IF v_carrier.id IS NULL THEN
    -- failover: highest-priority active carrier
    SELECT * INTO v_carrier FROM public.carriers WHERE is_active ORDER BY priority, created_at LIMIT 1;
  END IF;
  IF v_carrier.id IS NULL THEN RAISE EXCEPTION 'No active carrier available'; END IF;

  v_tracking := 'RET-' || upper(substr(md5(gen_random_uuid()::text), 1, 10));
  v_label := jsonb_build_object(
    'type', 'return',
    'reason', p_reason,
    'from', jsonb_build_object(
      'name', COALESCE(v_order.shipping_name, v_order.customer_name),
      'address_line1', v_order.shipping_address_line1,
      'address_line2', v_order.shipping_address_line2,
      'postal_code', v_order.shipping_postal_code,
      'city', v_order.shipping_city,
      'country', v_order.shipping_country
    ),
    'to', 'merchant',
    'carrier', v_carrier.code,
    'tracking_number', v_tracking
  );

  INSERT INTO public.shipments
    (order_id, carrier_id, carrier_code, kind, return_of_shipment_id, tracking_number,
     tracking_url, weight_grams, status, metadata)
  VALUES
    (v_order.id, v_carrier.id, v_carrier.code, 'return', v_orig.id, v_tracking,
     CASE WHEN v_carrier.tracking_url_template IS NOT NULL
          THEN replace(v_carrier.tracking_url_template, '{tracking_number}', v_tracking) END,
     COALESCE(p_weight_grams, v_orig.weight_grams),
     'labeled',
     jsonb_build_object('return_label', v_label))
  RETURNING * INTO v_new;

  RETURN jsonb_build_object('success', true, 'return_shipment', to_jsonb(v_new), 'label', v_label);
END; $$;

-- ── 6. Batch label printing ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.batch_shipping_labels(
  p_shipment_ids uuid[] DEFAULT NULL,
  p_carrier_id uuid DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 100
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_labels jsonb;
  v_missing jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can batch-print labels';
  END IF;

  WITH sel AS (
    SELECT s.*
      FROM public.shipments s
     WHERE (p_shipment_ids IS NULL OR s.id = ANY(p_shipment_ids))
       AND (p_carrier_id IS NULL OR s.carrier_id = p_carrier_id)
       AND (p_status IS NULL OR s.status = p_status)
       AND (p_shipment_ids IS NOT NULL OR p_carrier_id IS NOT NULL OR p_status IS NOT NULL
            OR s.status IN ('pending','labeled'))
     ORDER BY s.created_at
     LIMIT GREATEST(COALESCE(p_limit,100),1)
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'shipment_id', id, 'kind', kind, 'carrier_code', carrier_code,
      'tracking_number', tracking_number, 'label_url', label_url,
      'weight_grams', weight_grams, 'order_id', order_id
    )) FILTER (WHERE label_url IS NOT NULL OR COALESCE(metadata,'{}'::jsonb) ? 'return_label'), '[]'::jsonb),
    COALESCE(jsonb_agg(id) FILTER (WHERE label_url IS NULL AND NOT (COALESCE(metadata,'{}'::jsonb) ? 'return_label')), '[]'::jsonb)
  INTO v_labels, v_missing
  FROM sel;

  RETURN jsonb_build_object(
    'success', true,
    'labels', v_labels,
    'count', jsonb_array_length(v_labels),
    'missing_label_shipment_ids', v_missing
  );
END; $$;

-- ── 7. Multi-carrier failover selection ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.select_shipping_carrier(
  p_weight_grams numeric,
  p_country text DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_preferred_carrier_id uuid DEFAULT NULL,
  p_preferred_carrier_code text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_carrier record;
  v_rate record;
  v_attempted jsonb := '[]'::jsonb;
  v_preferred_id uuid := p_preferred_carrier_id;
  v_fallback boolean := false;
BEGIN
  IF p_weight_grams IS NULL OR p_weight_grams <= 0 THEN
    RAISE EXCEPTION 'weight_grams must be positive';
  END IF;
  IF v_preferred_id IS NULL AND p_preferred_carrier_code IS NOT NULL THEN
    SELECT id INTO v_preferred_id FROM public.carriers WHERE lower(code) = lower(p_preferred_carrier_code);
  END IF;

  FOR v_carrier IN
    SELECT * FROM public.carriers
     WHERE is_active
     ORDER BY (id = v_preferred_id) DESC NULLS LAST, priority, created_at
  LOOP
    SELECT r.* INTO v_rate
      FROM public.shipping_rates r
     WHERE r.carrier_id = v_carrier.id
       AND r.is_active
       AND r.min_weight_grams <= p_weight_grams
       AND (r.max_weight_grams IS NULL OR r.max_weight_grams >= p_weight_grams)
       AND (p_currency IS NULL OR r.currency = p_currency)
       AND (
         (r.countries IS NULL OR cardinality(r.countries) = 0)
         OR (p_country IS NOT NULL AND upper(p_country) = ANY (SELECT upper(unnest) FROM unnest(r.countries)))
       )
     ORDER BY r.price_cents
     LIMIT 1;

    IF v_rate.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', true,
        'carrier_id', v_carrier.id,
        'carrier_code', v_carrier.code,
        'carrier_name', v_carrier.name,
        'rate_id', v_rate.id,
        'rate_name', v_rate.name,
        'price_cents', v_rate.price_cents,
        'currency', v_rate.currency,
        'fallback_used', v_fallback,
        'attempted', v_attempted
      );
    END IF;

    v_attempted := v_attempted || jsonb_build_object('carrier_code', v_carrier.code, 'reason', 'no_matching_rate');
    IF v_preferred_id IS NOT NULL AND v_carrier.id = v_preferred_id THEN
      v_fallback := true; -- preferred failed; everything after is failover
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', false, 'reason', 'no_carrier_available', 'attempted', v_attempted);
END; $$;

-- ── 8. Address validation ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.validate_address(
  p_country text,
  p_postal_code text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_street text DEFAULT NULL,
  p_name text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_issues jsonb := '[]'::jsonb;
  v_rule public.postal_code_rules;
  v_country text := upper(trim(COALESCE(p_country,'')));
  v_postal text := trim(COALESCE(p_postal_code,''));
BEGIN
  IF v_country = '' THEN
    v_issues := v_issues || to_jsonb('country is required'::text);
  ELSIF length(v_country) <> 2 THEN
    v_issues := v_issues || to_jsonb('country must be an ISO-3166 alpha-2 code (e.g. SE)'::text);
  END IF;
  IF v_postal = '' THEN
    v_issues := v_issues || to_jsonb('postal_code is required'::text);
  END IF;
  IF COALESCE(trim(p_city),'') = '' THEN
    v_issues := v_issues || to_jsonb('city is required'::text);
  END IF;
  IF COALESCE(trim(p_street),'') = '' THEN
    v_issues := v_issues || to_jsonb('street is required'::text);
  END IF;

  SELECT * INTO v_rule FROM public.postal_code_rules WHERE country = v_country;
  IF v_rule.country IS NOT NULL AND v_postal <> '' AND v_postal !~ v_rule.pattern THEN
    v_issues := v_issues || to_jsonb(format('postal_code %s does not match the %s format (e.g. %s)', v_postal, v_country, v_rule.example));
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'valid', jsonb_array_length(v_issues) = 0,
    'issues', v_issues,
    'postal_format_known', v_rule.country IS NOT NULL,
    'normalized', jsonb_build_object(
      'country', v_country,
      'postal_code', upper(v_postal),
      'city', trim(COALESCE(p_city,'')),
      'street', trim(COALESCE(p_street,'')),
      'name', NULLIF(trim(COALESCE(p_name,'')),'')
    )
  );
END; $$;

-- ── 9. International / customs handling ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_shipment_customs(
  p_action text,
  p_shipment_id uuid,
  p_customs_value_cents bigint DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_incoterm text DEFAULT NULL,
  p_contents_type text DEFAULT NULL,
  p_destination_country text DEFAULT NULL,
  p_items jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_ship public.shipments;
  v_item jsonb;
  v_missing text[] := '{}';
  v_total bigint := 0;
  v_decl jsonb;
BEGIN
  IF p_action = 'get' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view customs data';
    END IF;
  ELSE
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
      RAISE EXCEPTION 'Only admins/writers can manage customs data';
    END IF;
  END IF;

  SELECT * INTO v_ship FROM public.shipments WHERE id = p_shipment_id;
  IF v_ship.id IS NULL THEN RAISE EXCEPTION 'Shipment % not found', p_shipment_id; END IF;

  IF p_action = 'set' THEN
    IF p_incoterm IS NOT NULL AND upper(p_incoterm) NOT IN ('DAP','DDP','DDU','EXW','FOB','CIF','CIP','FCA') THEN
      RAISE EXCEPTION 'Unknown incoterm % (use DAP|DDP|DDU|EXW|FOB|CIF|CIP|FCA)', p_incoterm;
    END IF;
    IF p_contents_type IS NOT NULL AND lower(p_contents_type) NOT IN ('merchandise','gift','documents','sample','return','other') THEN
      RAISE EXCEPTION 'Unknown contents_type % (use merchandise|gift|documents|sample|return|other)', p_contents_type;
    END IF;
    IF p_items IS NOT NULL AND jsonb_typeof(p_items) <> 'array' THEN
      RAISE EXCEPTION 'items must be an array of {description, quantity, value_cents, weight_grams, hs_code, origin_country}';
    END IF;

    UPDATE public.shipments
       SET customs_value_cents = COALESCE(p_customs_value_cents, customs_value_cents),
           customs_currency = COALESCE(upper(p_currency), customs_currency),
           incoterm = COALESCE(upper(p_incoterm), incoterm),
           contents_type = COALESCE(lower(p_contents_type), contents_type),
           destination_country = COALESCE(upper(p_destination_country), destination_country),
           customs_items = COALESCE(p_items, customs_items),
           updated_at = now()
     WHERE id = p_shipment_id
    RETURNING * INTO v_ship;
    RETURN jsonb_build_object('success', true, 'shipment_id', v_ship.id,
      'customs', jsonb_build_object(
        'value_cents', v_ship.customs_value_cents, 'currency', v_ship.customs_currency,
        'incoterm', v_ship.incoterm, 'contents_type', v_ship.contents_type,
        'destination_country', v_ship.destination_country, 'items', v_ship.customs_items));

  ELSIF p_action = 'declare' THEN
    IF v_ship.destination_country IS NULL THEN v_missing := v_missing || 'destination_country'; END IF;
    IF v_ship.contents_type IS NULL THEN v_missing := v_missing || 'contents_type'; END IF;
    IF v_ship.customs_items IS NULL OR jsonb_array_length(v_ship.customs_items) = 0 THEN
      v_missing := v_missing || 'customs_items';
    ELSE
      FOR v_item IN SELECT * FROM jsonb_array_elements(v_ship.customs_items) LOOP
        IF COALESCE(v_item->>'description','') = '' OR (v_item->>'value_cents') IS NULL OR (v_item->>'quantity') IS NULL THEN
          v_missing := v_missing || 'items[].description/quantity/value_cents';
          EXIT;
        END IF;
        v_total := v_total + ((v_item->>'value_cents')::bigint * COALESCE((v_item->>'quantity')::int,1));
      END LOOP;
    END IF;
    IF array_length(v_missing,1) IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'reason', 'incomplete_customs_data', 'missing', to_jsonb(v_missing));
    END IF;

    v_decl := jsonb_build_object(
      'declaration_type', 'CN22',
      'shipment_id', v_ship.id,
      'tracking_number', v_ship.tracking_number,
      'destination_country', v_ship.destination_country,
      'contents_type', v_ship.contents_type,
      'incoterm', COALESCE(v_ship.incoterm, 'DAP'),
      'currency', COALESCE(v_ship.customs_currency, 'SEK'),
      'declared_value_cents', COALESCE(v_ship.customs_value_cents, v_total),
      'items_total_cents', v_total,
      'items', v_ship.customs_items,
      'gross_weight_grams', v_ship.weight_grams,
      'declared_at', now()
    );
    UPDATE public.shipments
       SET customs_declaration = v_decl,
           customs_declared_at = now(),
           customs_value_cents = COALESCE(customs_value_cents, v_total),
           updated_at = now()
     WHERE id = p_shipment_id;
    RETURN jsonb_build_object('success', true, 'declaration', v_decl);

  ELSIF p_action = 'get' THEN
    RETURN jsonb_build_object('success', true, 'shipment_id', v_ship.id,
      'customs', jsonb_build_object(
        'value_cents', v_ship.customs_value_cents, 'currency', v_ship.customs_currency,
        'incoterm', v_ship.incoterm, 'contents_type', v_ship.contents_type,
        'destination_country', v_ship.destination_country, 'items', v_ship.customs_items,
        'declaration', v_ship.customs_declaration, 'declared_at', v_ship.customs_declared_at));
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use set|declare|get)', p_action;
END; $$;
