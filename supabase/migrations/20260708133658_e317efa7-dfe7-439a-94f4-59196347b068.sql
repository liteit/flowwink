
-- =============================================================
-- Deals parity R11
-- =============================================================

-- 1. Deal teams
CREATE TABLE IF NOT EXISTS public.deal_teams (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.deal_teams TO authenticated;
GRANT ALL ON public.deal_teams TO service_role;
ALTER TABLE public.deal_teams ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "deal_teams read" ON public.deal_teams;
CREATE POLICY "deal_teams read" ON public.deal_teams FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "deal_teams admin" ON public.deal_teams;
CREATE POLICY "deal_teams admin" ON public.deal_teams
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'approver'))
  WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'approver'));

CREATE TABLE IF NOT EXISTS public.deal_team_members (
  team_id uuid NOT NULL REFERENCES public.deal_teams(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  role text NOT NULL DEFAULT 'member',
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, user_id)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.deal_team_members TO authenticated;
GRANT ALL ON public.deal_team_members TO service_role;
ALTER TABLE public.deal_team_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "deal_team_members read" ON public.deal_team_members;
CREATE POLICY "deal_team_members read" ON public.deal_team_members FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "deal_team_members admin" ON public.deal_team_members;
CREATE POLICY "deal_team_members admin" ON public.deal_team_members
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'approver'))
  WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'approver'));

-- 2. deals.team_id
ALTER TABLE public.deals ADD COLUMN IF NOT EXISTS team_id uuid;
ALTER TABLE public.deals ADD COLUMN IF NOT EXISTS owner_id uuid;
CREATE INDEX IF NOT EXISTS idx_deals_team_id ON public.deals(team_id);
CREATE INDEX IF NOT EXISTS idx_deals_owner_id ON public.deals(owner_id);
DO $$ BEGIN
  ALTER TABLE public.deals
    ADD CONSTRAINT deals_team_id_fkey FOREIGN KEY (team_id)
    REFERENCES public.deal_teams(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 3. Deal change history
CREATE TABLE IF NOT EXISTS public.deal_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deal_id uuid NOT NULL REFERENCES public.deals(id) ON DELETE CASCADE,
  field text NOT NULL,
  old_value text,
  new_value text,
  changed_by uuid,
  changed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_deal_history_deal ON public.deal_history(deal_id, changed_at DESC);
GRANT SELECT, INSERT ON public.deal_history TO authenticated;
GRANT ALL ON public.deal_history TO service_role;
ALTER TABLE public.deal_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "deal_history read" ON public.deal_history;
CREATE POLICY "deal_history read" ON public.deal_history FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "deal_history insert" ON public.deal_history;
CREATE POLICY "deal_history insert" ON public.deal_history FOR INSERT TO authenticated WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.tg_log_deal_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_field text;
  v_old text;
  v_new text;
BEGIN
  FOREACH v_field IN ARRAY ARRAY['stage','stage_id','value_cents','currency','lead_id','product_id','team_id','owner_id','expected_close','notes','lost_reason']
  LOOP
    EXECUTE format('SELECT ($1).%I::text, ($2).%I::text', v_field, v_field)
      INTO v_old, v_new USING OLD, NEW;
    IF v_old IS DISTINCT FROM v_new THEN
      INSERT INTO public.deal_history(deal_id, field, old_value, new_value, changed_by)
      VALUES (NEW.id, v_field, v_old, v_new, v_uid);
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_log_deal_history ON public.deals;
CREATE TRIGGER trg_log_deal_history
  AFTER UPDATE ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public.tg_log_deal_history();

-- 4. Deal templates
CREATE TABLE IF NOT EXISTS public.deal_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  default_product_id uuid,
  default_stage_id uuid,
  default_stage text,
  default_value_cents bigint NOT NULL DEFAULT 0,
  default_currency text NOT NULL DEFAULT 'SEK',
  default_notes text,
  default_team_id uuid REFERENCES public.deal_teams(id) ON DELETE SET NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.deal_templates TO authenticated;
GRANT ALL ON public.deal_templates TO service_role;
ALTER TABLE public.deal_templates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "deal_templates read" ON public.deal_templates;
CREATE POLICY "deal_templates read" ON public.deal_templates FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS "deal_templates admin" ON public.deal_templates;
CREATE POLICY "deal_templates admin" ON public.deal_templates
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'approver'))
  WITH CHECK (public.has_role(auth.uid(),'admin') OR public.has_role(auth.uid(),'approver'));

CREATE OR REPLACE FUNCTION public.tg_touch_updated_at_generic()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;
DROP TRIGGER IF EXISTS trg_touch_deal_templates ON public.deal_templates;
CREATE TRIGGER trg_touch_deal_templates BEFORE UPDATE ON public.deal_templates
  FOR EACH ROW EXECUTE FUNCTION public.tg_touch_updated_at_generic();
DROP TRIGGER IF EXISTS trg_touch_deal_teams ON public.deal_teams;
CREATE TRIGGER trg_touch_deal_teams BEFORE UPDATE ON public.deal_teams
  FOR EACH ROW EXECUTE FUNCTION public.tg_touch_updated_at_generic();

CREATE OR REPLACE FUNCTION public.create_deal_from_template(
  p_template_id uuid,
  p_lead_id uuid,
  p_override_value_cents bigint DEFAULT NULL,
  p_override_currency text DEFAULT NULL,
  p_expected_close date DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  t public.deal_templates;
  v_id uuid;
  v_stage text;
BEGIN
  IF NOT (auth.role() = 'service_role'
          OR has_role(v_uid,'admin') OR has_role(v_uid,'approver')) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  SELECT * INTO t FROM public.deal_templates WHERE id = p_template_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'template not found'; END IF;

  v_stage := COALESCE(t.default_stage, 'proposal');

  INSERT INTO public.deals (
    lead_id, product_id, stage, stage_id, value_cents, currency, notes,
    team_id, expected_close, created_by
  ) VALUES (
    p_lead_id,
    t.default_product_id,
    v_stage::deal_stage,
    t.default_stage_id,
    COALESCE(p_override_value_cents, t.default_value_cents),
    COALESCE(p_override_currency, t.default_currency),
    t.default_notes,
    t.default_team_id,
    p_expected_close,
    v_uid
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.create_deal_from_template(uuid, uuid, bigint, text, date)
  TO authenticated, service_role;

-- 5. FX conversion helper — uses latest exchange_rates
CREATE OR REPLACE FUNCTION public.convert_amount_to_base(
  p_amount_cents bigint,
  p_from_currency text,
  p_to_currency text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql STABLE SET search_path = public AS $$
DECLARE
  v_to text := COALESCE(
    p_to_currency,
    (SELECT code FROM public.currencies WHERE is_base = true LIMIT 1),
    'SEK'
  );
  v_rate numeric;
BEGIN
  IF p_amount_cents IS NULL THEN RETURN NULL; END IF;
  IF p_from_currency IS NULL OR upper(p_from_currency) = upper(v_to) THEN
    RETURN p_amount_cents;
  END IF;

  -- Direct rate from → to
  SELECT rate INTO v_rate
    FROM public.exchange_rates
   WHERE upper(base_currency) = upper(p_from_currency)
     AND upper(quote_currency) = upper(v_to)
   ORDER BY rate_date DESC LIMIT 1;

  IF v_rate IS NULL THEN
    -- Try inverse
    SELECT 1/rate INTO v_rate
      FROM public.exchange_rates
     WHERE upper(base_currency) = upper(v_to)
       AND upper(quote_currency) = upper(p_from_currency)
     ORDER BY rate_date DESC LIMIT 1;
  END IF;

  IF v_rate IS NULL THEN RETURN NULL; END IF;
  RETURN round(p_amount_cents::numeric * v_rate)::bigint;
END;
$$;
GRANT EXECUTE ON FUNCTION public.convert_amount_to_base(bigint, text, text)
  TO anon, authenticated, service_role;
