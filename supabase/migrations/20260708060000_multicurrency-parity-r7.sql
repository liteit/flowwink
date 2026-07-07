-- Multi-currency: parity round 7 (docs/parity/capabilities/multi-currency.json)
-- Adds: bulk historical rate import, FX hedging/forward contracts (with
-- mark-to-market and settlement posting realized gain/loss to BAS 3960/7960),
-- local-currency subsidiary ledgers (subsidiaries + journal_entries.subsidiary_id
-- + per-account local ledger report), and consolidation currency translation
-- (per-entity trial balance translated at closing rate).
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. FX rate helper ────────────────────────────────────────────────────────
-- Latest known rate from → to on/before p_at. 1.0 for same currency; falls
-- back to the inverse pair. NULL when no rate is known.
CREATE OR REPLACE FUNCTION public.fx_rate_at(p_from text, p_to text, p_at date DEFAULT CURRENT_DATE)
RETURNS numeric
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_rate numeric;
BEGIN
  IF upper(p_from) = upper(p_to) THEN RETURN 1.0; END IF;
  SELECT rate INTO v_rate FROM public.exchange_rates
  WHERE base_currency = upper(p_from) AND quote_currency = upper(p_to) AND rate_date <= p_at
  ORDER BY rate_date DESC LIMIT 1;
  IF v_rate IS NOT NULL THEN RETURN v_rate; END IF;
  SELECT rate INTO v_rate FROM public.exchange_rates
  WHERE base_currency = upper(p_to) AND quote_currency = upper(p_from) AND rate_date <= p_at
  ORDER BY rate_date DESC LIMIT 1;
  IF v_rate IS NOT NULL AND v_rate <> 0 THEN RETURN 1.0 / v_rate; END IF;
  RETURN NULL;
END;
$$;

-- ── 2. Bulk historical rate import ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.import_exchange_rates(
  p_rates jsonb,
  p_source text DEFAULT 'import'
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row jsonb;
  v_imported integer := 0;
  v_skipped integer := 0;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can import exchange rates';
  END IF;
  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'array' THEN
    RAISE EXCEPTION 'p_rates must be a JSON array of {base_currency, quote_currency, rate, rate_date}';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rates)
  LOOP
    BEGIN
      IF v_row->>'base_currency' IS NULL OR v_row->>'quote_currency' IS NULL
         OR (v_row->>'rate')::numeric IS NULL OR (v_row->>'rate')::numeric <= 0
         OR (v_row->>'rate_date')::date IS NULL THEN
        RAISE EXCEPTION 'missing/invalid fields';
      END IF;
      INSERT INTO public.exchange_rates (base_currency, quote_currency, rate, rate_date, source)
      VALUES (upper(v_row->>'base_currency'), upper(v_row->>'quote_currency'),
              (v_row->>'rate')::numeric, (v_row->>'rate_date')::date,
              COALESCE(v_row->>'source', p_source))
      ON CONFLICT (base_currency, quote_currency, rate_date)
      DO UPDATE SET rate = EXCLUDED.rate, source = EXCLUDED.source;
      v_imported := v_imported + 1;
    EXCEPTION WHEN others THEN
      v_skipped := v_skipped + 1;
      IF jsonb_array_length(v_errors) < 5 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object('row', v_row, 'error', SQLERRM));
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'imported', v_imported,
    'skipped', v_skipped, 'errors', v_errors);
END;
$$;

-- ── 3. FX forward contracts ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.fx_forward_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_ref text,
  direction text NOT NULL DEFAULT 'buy',
  base_currency text NOT NULL,
  quote_currency text NOT NULL DEFAULT 'SEK',
  amount_cents bigint NOT NULL,
  forward_rate numeric NOT NULL,
  trade_date date NOT NULL DEFAULT CURRENT_DATE,
  value_date date NOT NULL,
  counterparty text,
  status text NOT NULL DEFAULT 'open',
  settled_rate numeric,
  settled_at timestamptz,
  realized_gain_cents bigint,
  journal_id uuid,
  notes text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.fx_forward_contracts DROP CONSTRAINT IF EXISTS fx_forward_contracts_direction_check;
ALTER TABLE public.fx_forward_contracts
  ADD CONSTRAINT fx_forward_contracts_direction_check CHECK (direction IN ('buy','sell'));
ALTER TABLE public.fx_forward_contracts DROP CONSTRAINT IF EXISTS fx_forward_contracts_status_check;
ALTER TABLE public.fx_forward_contracts
  ADD CONSTRAINT fx_forward_contracts_status_check CHECK (status IN ('open','settled','cancelled'));
ALTER TABLE public.fx_forward_contracts DROP CONSTRAINT IF EXISTS fx_forward_contracts_amount_check;
ALTER TABLE public.fx_forward_contracts
  ADD CONSTRAINT fx_forward_contracts_amount_check CHECK (amount_cents > 0);

ALTER TABLE public.fx_forward_contracts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage fx forwards" ON public.fx_forward_contracts;
CREATE POLICY "Admins manage fx forwards" ON public.fx_forward_contracts FOR ALL
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));

CREATE OR REPLACE FUNCTION public.manage_fx_forward(
  p_action text,
  p_contract_id uuid DEFAULT NULL,
  p_direction text DEFAULT NULL,
  p_base_currency text DEFAULT NULL,
  p_quote_currency text DEFAULT NULL,
  p_amount_cents bigint DEFAULT NULL,
  p_forward_rate numeric DEFAULT NULL,
  p_value_date date DEFAULT NULL,
  p_counterparty text DEFAULT NULL,
  p_settled_rate numeric DEFAULT NULL,
  p_contract_ref text DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_c public.fx_forward_contracts;
  v_rows jsonb;
  v_spot numeric;
  v_gain bigint;
  v_je uuid;
  v_total bigint := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can manage FX forwards';
  END IF;

  IF p_action = 'create' THEN
    IF p_base_currency IS NULL OR p_amount_cents IS NULL OR p_forward_rate IS NULL OR p_value_date IS NULL THEN
      RAISE EXCEPTION 'create requires p_base_currency, p_amount_cents, p_forward_rate, p_value_date';
    END IF;
    INSERT INTO public.fx_forward_contracts (contract_ref, direction, base_currency, quote_currency,
      amount_cents, forward_rate, value_date, counterparty, notes, created_by)
    VALUES (COALESCE(p_contract_ref, 'FWD-' || to_char(now(),'YYYYMMDD') || '-' || substr(gen_random_uuid()::text,1,4)),
      COALESCE(p_direction,'buy'), upper(p_base_currency), upper(COALESCE(p_quote_currency,'SEK')),
      p_amount_cents, p_forward_rate, p_value_date, p_counterparty, p_notes, auth.uid())
    RETURNING * INTO v_c;
    RETURN jsonb_build_object('success', true, 'contract', to_jsonb(v_c));

  ELSIF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.value_date), '[]'::jsonb) INTO v_rows
    FROM public.fx_forward_contracts c;
    RETURN jsonb_build_object('success', true, 'contracts', v_rows);

  ELSIF p_action = 'get' THEN
    SELECT * INTO v_c FROM public.fx_forward_contracts WHERE id = p_contract_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Contract % not found', p_contract_id; END IF;
    RETURN jsonb_build_object('success', true, 'contract', to_jsonb(v_c));

  ELSIF p_action = 'cancel' THEN
    UPDATE public.fx_forward_contracts SET status='cancelled', updated_at=now()
    WHERE id = p_contract_id AND status = 'open'
    RETURNING * INTO v_c;
    IF NOT FOUND THEN RAISE EXCEPTION 'Contract % not found or not open', p_contract_id; END IF;
    RETURN jsonb_build_object('success', true, 'contract', to_jsonb(v_c));

  ELSIF p_action = 'mark_to_market' THEN
    SELECT COALESCE(jsonb_agg(row_data), '[]'::jsonb),
           COALESCE(SUM((row_data->>'unrealized_gain_cents')::bigint), 0)
    INTO v_rows, v_total
    FROM (
      SELECT jsonb_build_object(
        'contract_id', c.id, 'contract_ref', c.contract_ref, 'direction', c.direction,
        'pair', c.base_currency || '/' || c.quote_currency,
        'amount_cents', c.amount_cents, 'forward_rate', c.forward_rate,
        'spot_rate', public.fx_rate_at(c.base_currency, c.quote_currency, CURRENT_DATE),
        'value_date', c.value_date,
        'unrealized_gain_cents',
          CASE WHEN public.fx_rate_at(c.base_currency, c.quote_currency, CURRENT_DATE) IS NULL THEN NULL
               ELSE ROUND(c.amount_cents *
                 (public.fx_rate_at(c.base_currency, c.quote_currency, CURRENT_DATE) - c.forward_rate)
                 * CASE WHEN c.direction = 'buy' THEN 1 ELSE -1 END)::bigint
          END
      ) AS row_data
      FROM public.fx_forward_contracts c WHERE c.status = 'open'
    ) m;
    RETURN jsonb_build_object('success', true, 'contracts', v_rows,
      'total_unrealized_gain_cents', v_total,
      'note', 'gain is in quote-currency cents (positive = gain)');

  ELSIF p_action = 'settle' THEN
    SELECT * INTO v_c FROM public.fx_forward_contracts WHERE id = p_contract_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Contract % not found', p_contract_id; END IF;
    IF v_c.status <> 'open' THEN RAISE EXCEPTION 'Contract % is %', p_contract_id, v_c.status; END IF;
    v_spot := COALESCE(p_settled_rate, public.fx_rate_at(v_c.base_currency, v_c.quote_currency, v_c.value_date));
    IF v_spot IS NULL THEN
      RAISE EXCEPTION 'No spot rate known for %/% — pass p_settled_rate', v_c.base_currency, v_c.quote_currency;
    END IF;
    v_gain := ROUND(v_c.amount_cents * (v_spot - v_c.forward_rate)
              * CASE WHEN v_c.direction = 'buy' THEN 1 ELSE -1 END)::bigint;

    IF v_gain <> 0 THEN
      INSERT INTO public.journal_entries (entry_date, description, status, source)
      VALUES (LEAST(v_c.value_date, CURRENT_DATE),
        'FX forward settlement ' || v_c.contract_ref || ' (' || v_c.base_currency || '/' || v_c.quote_currency || ')',
        'posted', 'multi-currency')
      RETURNING id INTO v_je;
      IF v_gain > 0 THEN
        INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
        VALUES (v_je, '1930', v_gain, 0, 'FX forward gain ' || v_c.contract_ref),
               (v_je, '3960', 0, v_gain, 'Valutakursvinster');
      ELSE
        INSERT INTO public.journal_entry_lines (journal_entry_id, account_code, debit_cents, credit_cents, description)
        VALUES (v_je, '7960', -v_gain, 0, 'Valutakursförluster'),
               (v_je, '1930', 0, -v_gain, 'FX forward loss ' || v_c.contract_ref);
      END IF;
    END IF;

    UPDATE public.fx_forward_contracts
    SET status='settled', settled_rate=v_spot, settled_at=now(),
        realized_gain_cents=v_gain, journal_id=v_je, updated_at=now()
    WHERE id = p_contract_id
    RETURNING * INTO v_c;
    RETURN jsonb_build_object('success', true, 'contract', to_jsonb(v_c),
      'realized_gain_cents', v_gain, 'journal_entry_id', v_je);

  ELSE
    RAISE EXCEPTION 'Unknown action %. Use create|list|get|settle|cancel|mark_to_market', p_action;
  END IF;
END;
$$;

-- ── 4. Subsidiaries + local-currency ledgers ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.subsidiaries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  name text NOT NULL,
  currency text NOT NULL,
  country text,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.subsidiaries ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage subsidiaries" ON public.subsidiaries;
CREATE POLICY "Admins manage subsidiaries" ON public.subsidiaries FOR ALL
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));

ALTER TABLE public.journal_entries ADD COLUMN IF NOT EXISTS subsidiary_id uuid REFERENCES public.subsidiaries(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS journal_entries_subsidiary_idx ON public.journal_entries (subsidiary_id) WHERE subsidiary_id IS NOT NULL;

-- Convention: journal lines on a subsidiary-tagged entry are denominated in
-- the subsidiary's local (functional) currency; untagged entries are HQ base.
CREATE OR REPLACE FUNCTION public.manage_subsidiary(
  p_action text,
  p_subsidiary_id uuid DEFAULT NULL,
  p_code text DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_country text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_journal_entry_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.subsidiaries;
  v_rows jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can manage subsidiaries';
  END IF;

  IF p_action = 'create' THEN
    IF p_code IS NULL OR p_name IS NULL OR p_currency IS NULL THEN
      RAISE EXCEPTION 'create requires p_code, p_name, p_currency';
    END IF;
    INSERT INTO public.subsidiaries (code, name, currency, country, notes)
    VALUES (upper(p_code), p_name, upper(p_currency), p_country, p_notes)
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'subsidiary', to_jsonb(v_row));

  ELSIF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.code), '[]'::jsonb) INTO v_rows FROM public.subsidiaries s;
    RETURN jsonb_build_object('success', true, 'subsidiaries', v_rows);

  ELSIF p_action = 'update' THEN
    UPDATE public.subsidiaries SET
      name = COALESCE(p_name, name),
      currency = COALESCE(upper(p_currency), currency),
      country = COALESCE(p_country, country),
      notes = COALESCE(p_notes, notes),
      is_active = COALESCE(p_is_active, is_active),
      updated_at = now()
    WHERE id = p_subsidiary_id OR (p_subsidiary_id IS NULL AND code = upper(p_code))
    RETURNING * INTO v_row;
    IF NOT FOUND THEN RAISE EXCEPTION 'Subsidiary not found'; END IF;
    RETURN jsonb_build_object('success', true, 'subsidiary', to_jsonb(v_row));

  ELSIF p_action = 'tag_entry' THEN
    IF p_journal_entry_id IS NULL THEN RAISE EXCEPTION 'tag_entry requires p_journal_entry_id'; END IF;
    SELECT * INTO v_row FROM public.subsidiaries
    WHERE id = p_subsidiary_id OR (p_subsidiary_id IS NULL AND code = upper(p_code));
    IF NOT FOUND THEN RAISE EXCEPTION 'Subsidiary not found'; END IF;
    UPDATE public.journal_entries SET subsidiary_id = v_row.id WHERE id = p_journal_entry_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Journal entry % not found', p_journal_entry_id; END IF;
    RETURN jsonb_build_object('success', true, 'journal_entry_id', p_journal_entry_id,
      'subsidiary', v_row.code);

  ELSE
    RAISE EXCEPTION 'Unknown action %. Use create|list|update|tag_entry', p_action;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.subsidiary_ledger_report(
  p_subsidiary_code text,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sub public.subsidiaries;
  v_accounts jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can read subsidiary ledgers';
  END IF;
  SELECT * INTO v_sub FROM public.subsidiaries WHERE code = upper(p_subsidiary_code);
  IF NOT FOUND THEN RAISE EXCEPTION 'Subsidiary % not found', p_subsidiary_code; END IF;

  SELECT COALESCE(jsonb_agg(a ORDER BY a.account_code), '[]'::jsonb)
  INTO v_accounts
  FROM (
    SELECT l.account_code,
           MAX(l.account_name) AS account_name,
           SUM(l.debit_cents) AS debit_cents,
           SUM(l.credit_cents) AS credit_cents,
           SUM(l.debit_cents - l.credit_cents) AS net_cents,
           COUNT(DISTINCT e.id) AS entry_count
    FROM public.journal_entry_lines l
    JOIN public.journal_entries e ON e.id = l.journal_entry_id
    WHERE e.subsidiary_id = v_sub.id
      AND e.status = 'posted'
      AND (p_from IS NULL OR e.entry_date >= p_from)
      AND (p_to IS NULL OR e.entry_date <= p_to)
    GROUP BY l.account_code
  ) a;

  RETURN jsonb_build_object('success', true,
    'subsidiary', jsonb_build_object('code', v_sub.code, 'name', v_sub.name, 'currency', v_sub.currency),
    'from', p_from, 'to', p_to,
    'currency', v_sub.currency,
    'note', 'amounts are in the subsidiary local currency',
    'accounts', v_accounts);
END;
$$;

-- ── 5. Consolidation currency translation ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.consolidation_report(
  p_presentation_currency text DEFAULT NULL,
  p_as_of date DEFAULT CURRENT_DATE
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_pres text;
  v_base text;
  v_entities jsonb := '[]'::jsonb;
  v_entity jsonb;
  v_sub record;
  v_rate numeric;
  v_accounts jsonb;
  v_local bigint;
  v_translated bigint;
  v_total bigint := 0;
  v_missing text[] := '{}';
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
    RAISE EXCEPTION 'Only admins can run consolidation';
  END IF;
  SELECT code INTO v_base FROM public.currencies WHERE is_base LIMIT 1;
  v_base := COALESCE(v_base, 'SEK');
  v_pres := upper(COALESCE(p_presentation_currency, v_base));

  FOR v_sub IN
    SELECT s.id, s.code, s.name, s.currency FROM public.subsidiaries s WHERE s.is_active
    UNION ALL
    SELECT NULL::uuid, 'HQ', 'Headquarters (base ledger)', v_base
    ORDER BY 2
  LOOP
    v_rate := public.fx_rate_at(v_sub.currency, v_pres, p_as_of);
    IF v_rate IS NULL THEN
      v_missing := array_append(v_missing, v_sub.currency || '->' || v_pres);
    END IF;

    SELECT COALESCE(jsonb_agg(a ORDER BY a.account_code), '[]'::jsonb),
           COALESCE(SUM(a.net_local_cents), 0),
           COALESCE(SUM(a.net_translated_cents), 0)
    INTO v_accounts, v_local, v_translated
    FROM (
      SELECT l.account_code,
             MAX(l.account_name) AS account_name,
             SUM(l.debit_cents - l.credit_cents) AS net_local_cents,
             CASE WHEN v_rate IS NULL THEN NULL
                  ELSE ROUND(SUM(l.debit_cents - l.credit_cents) * v_rate)::bigint END AS net_translated_cents
      FROM public.journal_entry_lines l
      JOIN public.journal_entries e ON e.id = l.journal_entry_id
      WHERE e.status = 'posted'
        AND e.entry_date <= p_as_of
        AND (e.subsidiary_id = v_sub.id OR (v_sub.id IS NULL AND e.subsidiary_id IS NULL))
      GROUP BY l.account_code
    ) a;

    v_entity := jsonb_build_object(
      'code', v_sub.code, 'name', v_sub.name, 'currency', v_sub.currency,
      'closing_rate', v_rate,
      'net_local_cents', v_local,
      'net_translated_cents', v_translated,
      'accounts', v_accounts);
    v_entities := v_entities || jsonb_build_array(v_entity);
    v_total := v_total + COALESCE(v_translated, 0);
  END LOOP;

  RETURN jsonb_build_object('success', true,
    'as_of', p_as_of,
    'presentation_currency', v_pres,
    'method', 'closing-rate translation of net per account (trial-balance level)',
    'entities', v_entities,
    'consolidated_net_cents', v_total,
    'missing_rates', to_jsonb(v_missing));
END;
$$;
