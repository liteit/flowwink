
ALTER TABLE public.return_items
  ADD COLUMN IF NOT EXISTS suggested_action text,
  ADD COLUMN IF NOT EXISTS chosen_action text;

DO $$ BEGIN
  ALTER TABLE public.return_items
    ADD CONSTRAINT return_items_chosen_action_chk
    CHECK (chosen_action IS NULL OR chosen_action IN ('restock','refurbish','rtv','scrap'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS public.return_to_vendor (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rtv_number text UNIQUE NOT NULL DEFAULT ('RTV-' || to_char(now(),'YYYYMMDD') || '-' || substr(gen_random_uuid()::text,1,6)),
  rma_id uuid NOT NULL REFERENCES public.returns(id) ON DELETE CASCADE,
  vendor_id uuid REFERENCES public.vendors(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','credited','cancelled')),
  items jsonb NOT NULL DEFAULT '[]'::jsonb,
  expected_credit_cents bigint NOT NULL DEFAULT 0,
  credit_memo_id uuid REFERENCES public.vendor_credit_memos(id) ON DELETE SET NULL,
  notes text,
  sent_at timestamptz,
  credited_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.return_to_vendor TO authenticated;
GRANT ALL ON public.return_to_vendor TO service_role;
ALTER TABLE public.return_to_vendor ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "rtv staff manage" ON public.return_to_vendor;
CREATE POLICY "rtv staff manage" ON public.return_to_vendor
  FOR ALL TO authenticated
  USING (has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse') OR has_role(auth.uid(),'purchasing'))
  WITH CHECK (has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse') OR has_role(auth.uid(),'purchasing'));
CREATE INDEX IF NOT EXISTS idx_rtv_rma ON public.return_to_vendor(rma_id);
CREATE INDEX IF NOT EXISTS idx_rtv_vendor ON public.return_to_vendor(vendor_id);

CREATE TABLE IF NOT EXISTS public.return_pickups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pickup_number text UNIQUE NOT NULL DEFAULT ('PU-' || to_char(now(),'YYYYMMDD') || '-' || substr(gen_random_uuid()::text,1,6)),
  rma_id uuid NOT NULL REFERENCES public.returns(id) ON DELETE CASCADE,
  pickup_date date NOT NULL,
  pickup_window text,
  address_line1 text,
  address_line2 text,
  city text,
  postal_code text,
  country text,
  carrier text,
  tracking_reference text,
  status text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','scheduled','picked_up','failed','cancelled')),
  notes text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.return_pickups TO authenticated;
GRANT ALL ON public.return_pickups TO service_role;
ALTER TABLE public.return_pickups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "pickup staff manage" ON public.return_pickups;
CREATE POLICY "pickup staff manage" ON public.return_pickups
  FOR ALL TO authenticated
  USING (has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse'))
  WITH CHECK (has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse'));
CREATE INDEX IF NOT EXISTS idx_pickup_rma ON public.return_pickups(rma_id);

CREATE OR REPLACE FUNCTION public.touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

DROP TRIGGER IF EXISTS trg_rtv_touch ON public.return_to_vendor;
CREATE TRIGGER trg_rtv_touch BEFORE UPDATE ON public.return_to_vendor
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS trg_pickup_touch ON public.return_pickups;
CREATE TRIGGER trg_pickup_touch BEFORE UPDATE ON public.return_pickups
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE OR REPLACE FUNCTION public.compute_return_item_action() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.suggested_action := CASE lower(coalesce(NEW.condition,''))
    WHEN 'unopened' THEN 'restock'
    WHEN 'new'      THEN 'restock'
    WHEN 'opened'   THEN 'refurbish'
    WHEN 'used'     THEN 'refurbish'
    WHEN 'damaged'  THEN 'rtv'
    WHEN 'defective' THEN 'rtv'
    ELSE 'scrap'
  END;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_return_item_action ON public.return_items;
CREATE TRIGGER trg_return_item_action BEFORE INSERT OR UPDATE OF condition ON public.return_items
  FOR EACH ROW EXECUTE FUNCTION public.compute_return_item_action();

UPDATE public.return_items SET suggested_action = CASE lower(coalesce(condition,''))
    WHEN 'unopened' THEN 'restock' WHEN 'new' THEN 'restock'
    WHEN 'opened' THEN 'refurbish' WHEN 'used' THEN 'refurbish'
    WHEN 'damaged' THEN 'rtv' WHEN 'defective' THEN 'rtv'
    ELSE 'scrap' END
  WHERE suggested_action IS NULL;

CREATE OR REPLACE FUNCTION public.create_rtv(
  p_rma_id uuid,
  p_vendor_id uuid DEFAULT NULL,
  p_items jsonb DEFAULT '[]'::jsonb,
  p_expected_credit_cents bigint DEFAULT 0,
  p_notes text DEFAULT NULL
) RETURNS public.return_to_vendor
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.return_to_vendor;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse') OR has_role(auth.uid(),'purchasing')) THEN
    RAISE EXCEPTION 'Only staff can create RTVs';
  END IF;
  INSERT INTO public.return_to_vendor (rma_id, vendor_id, items, expected_credit_cents, notes, created_by)
    VALUES (p_rma_id, p_vendor_id, coalesce(p_items,'[]'::jsonb), coalesce(p_expected_credit_cents,0), p_notes, auth.uid())
    RETURNING * INTO v_row;
  RETURN v_row;
END $$;

CREATE OR REPLACE FUNCTION public.update_rtv_status(
  p_rtv_id uuid,
  p_status text,
  p_credit_memo_id uuid DEFAULT NULL
) RETURNS public.return_to_vendor
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.return_to_vendor;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse') OR has_role(auth.uid(),'purchasing')) THEN
    RAISE EXCEPTION 'Only staff can update RTVs';
  END IF;
  IF p_status NOT IN ('draft','sent','credited','cancelled') THEN
    RAISE EXCEPTION 'Invalid status %', p_status;
  END IF;
  UPDATE public.return_to_vendor SET
    status = p_status,
    sent_at = CASE WHEN p_status = 'sent' AND sent_at IS NULL THEN now() ELSE sent_at END,
    credited_at = CASE WHEN p_status = 'credited' AND credited_at IS NULL THEN now() ELSE credited_at END,
    credit_memo_id = coalesce(p_credit_memo_id, credit_memo_id)
  WHERE id = p_rtv_id
  RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'RTV % not found', p_rtv_id; END IF;
  RETURN v_row;
END $$;

CREATE OR REPLACE FUNCTION public.schedule_return_pickup(
  p_rma_id uuid,
  p_pickup_date date,
  p_carrier text DEFAULT NULL,
  p_address_line1 text DEFAULT NULL,
  p_address_line2 text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_postal_code text DEFAULT NULL,
  p_country text DEFAULT NULL,
  p_pickup_window text DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS public.return_pickups
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.return_pickups;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse')) THEN
    RAISE EXCEPTION 'Only staff can schedule pickups';
  END IF;
  INSERT INTO public.return_pickups (rma_id, pickup_date, carrier, address_line1, address_line2, city, postal_code, country, pickup_window, notes, created_by)
    VALUES (p_rma_id, p_pickup_date, p_carrier, p_address_line1, p_address_line2, p_city, p_postal_code, p_country, p_pickup_window, p_notes, auth.uid())
    RETURNING * INTO v_row;
  RETURN v_row;
END $$;

CREATE OR REPLACE FUNCTION public.update_return_pickup(
  p_pickup_id uuid,
  p_status text DEFAULT NULL,
  p_tracking_reference text DEFAULT NULL,
  p_pickup_date date DEFAULT NULL
) RETURNS public.return_pickups
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.return_pickups;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse')) THEN
    RAISE EXCEPTION 'Only staff can update pickups';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('requested','scheduled','picked_up','failed','cancelled') THEN
    RAISE EXCEPTION 'Invalid status %', p_status;
  END IF;
  UPDATE public.return_pickups SET
    status = coalesce(p_status, status),
    tracking_reference = coalesce(p_tracking_reference, tracking_reference),
    pickup_date = coalesce(p_pickup_date, pickup_date)
  WHERE id = p_pickup_id
  RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'Pickup % not found', p_pickup_id; END IF;
  RETURN v_row;
END $$;

CREATE OR REPLACE FUNCTION public.set_return_item_action(
  p_return_item_id uuid,
  p_action text
) RETURNS public.return_items
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.return_items;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse')) THEN
    RAISE EXCEPTION 'Only staff can set item action';
  END IF;
  IF p_action NOT IN ('restock','refurbish','rtv','scrap') THEN
    RAISE EXCEPTION 'Invalid action %', p_action;
  END IF;
  UPDATE public.return_items SET chosen_action = p_action
    WHERE id = p_return_item_id
    RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'Return item % not found', p_return_item_id; END IF;
  RETURN v_row;
END $$;

CREATE OR REPLACE FUNCTION public.attach_return_label(
  p_return_id uuid,
  p_label_url text DEFAULT NULL,
  p_tracking_number text DEFAULT NULL,
  p_carrier_code text DEFAULT NULL
) RETURNS public.returns
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row public.returns;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'support') OR has_role(auth.uid(),'warehouse')) THEN
    RAISE EXCEPTION 'Only staff can attach labels';
  END IF;
  UPDATE public.returns SET
    return_label_url = coalesce(p_label_url, return_label_url),
    return_tracking_number = coalesce(p_tracking_number, return_tracking_number),
    return_carrier_code = coalesce(p_carrier_code, return_carrier_code)
  WHERE id = p_return_id
  RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'Return % not found', p_return_id; END IF;
  RETURN v_row;
END $$;

GRANT EXECUTE ON FUNCTION public.create_rtv(uuid,uuid,jsonb,bigint,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_rtv_status(uuid,text,uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.schedule_return_pickup(uuid,date,text,text,text,text,text,text,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_return_pickup(uuid,text,text,date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_return_item_action(uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.attach_return_label(uuid,text,text,text) TO authenticated, service_role;
