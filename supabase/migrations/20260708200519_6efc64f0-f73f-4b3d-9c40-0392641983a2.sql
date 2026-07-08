
-- ============================================================
-- Contracts parity r13 — auto-invoicing + obligations + reminders
-- Fully idempotent. Reuses invoicing, dunning, email-send.
-- ============================================================

-- ── 1. contracts: billing schedule columns ─────────────────
ALTER TABLE public.contracts
  ADD COLUMN IF NOT EXISTS billing_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS billing_amount_cents bigint,
  ADD COLUMN IF NOT EXISTS billing_interval text CHECK (billing_interval IN ('week','month','quarter','year') OR billing_interval IS NULL),
  ADD COLUMN IF NOT EXISTS billing_interval_count integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS billing_next_date date,
  ADD COLUMN IF NOT EXISTS billing_last_invoice_id uuid,
  ADD COLUMN IF NOT EXISTS billing_tax_rate numeric NOT NULL DEFAULT 0.25,
  ADD COLUMN IF NOT EXISTS billing_due_in_days integer NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS billing_reminder_offsets integer[] NOT NULL DEFAULT ARRAY[-3, 7, 14]::integer[],
  ADD COLUMN IF NOT EXISTS billing_reminders_enabled boolean NOT NULL DEFAULT true;

CREATE INDEX IF NOT EXISTS idx_contracts_billing_due
  ON public.contracts (billing_next_date)
  WHERE billing_enabled = true AND status = 'active';

-- ── 2. invoices: contract_id link ──────────────────────────
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS contract_id uuid REFERENCES public.contracts(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_invoices_contract_id
  ON public.invoices (contract_id) WHERE contract_id IS NOT NULL;

-- ── 3. contract_obligations ────────────────────────────────
CREATE TABLE IF NOT EXISTS public.contract_obligations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES public.contracts(id) ON DELETE CASCADE,
  description text NOT NULL,
  due_date date,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','met','overdue','waived')),
  responsible text,
  met_at timestamptz,
  met_by uuid,
  notes text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.contract_obligations TO authenticated;
GRANT ALL ON public.contract_obligations TO service_role;

ALTER TABLE public.contract_obligations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "obligations_read_auth" ON public.contract_obligations;
CREATE POLICY "obligations_read_auth" ON public.contract_obligations
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "obligations_admin_write" ON public.contract_obligations;
CREATE POLICY "obligations_admin_write" ON public.contract_obligations
  FOR ALL TO authenticated
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));

CREATE INDEX IF NOT EXISTS idx_obligations_contract ON public.contract_obligations(contract_id);
CREATE INDEX IF NOT EXISTS idx_obligations_due ON public.contract_obligations(due_date) WHERE status IN ('pending','overdue');

DROP TRIGGER IF EXISTS trg_obligations_touch ON public.contract_obligations;
CREATE TRIGGER trg_obligations_touch
  BEFORE UPDATE ON public.contract_obligations
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ── 4. contract_invoice_reminders (idempotent send log) ────
CREATE TABLE IF NOT EXISTS public.contract_invoice_reminders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES public.invoices(id) ON DELETE CASCADE,
  contract_id uuid REFERENCES public.contracts(id) ON DELETE CASCADE,
  offset_days integer NOT NULL,
  triggered_by text NOT NULL DEFAULT 'cron',
  channel text NOT NULL DEFAULT 'email',
  recipient text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  sent_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_reminder_invoice_offset
  ON public.contract_invoice_reminders (invoice_id, offset_days);

GRANT SELECT, INSERT ON public.contract_invoice_reminders TO authenticated;
GRANT ALL ON public.contract_invoice_reminders TO service_role;

ALTER TABLE public.contract_invoice_reminders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "reminders_read_auth" ON public.contract_invoice_reminders;
CREATE POLICY "reminders_read_auth" ON public.contract_invoice_reminders
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "reminders_admin_write" ON public.contract_invoice_reminders;
CREATE POLICY "reminders_admin_write" ON public.contract_invoice_reminders
  FOR ALL TO authenticated
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));

-- ── 5. helper: advance a date by interval unit ─────────────
-- Reuses the same shape as advance_billing_date but scoped here to avoid coupling.
CREATE OR REPLACE FUNCTION public.advance_contract_billing_date(_base date, _interval text, _count integer)
RETURNS date
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  RETURN CASE lower(_interval)
    WHEN 'week'    THEN _base + (COALESCE(_count,1) || ' weeks')::interval
    WHEN 'month'   THEN _base + (COALESCE(_count,1) || ' months')::interval
    WHEN 'quarter' THEN _base + (COALESCE(_count,1)*3 || ' months')::interval
    WHEN 'year'    THEN _base + (COALESCE(_count,1) || ' years')::interval
    ELSE _base + '1 month'::interval
  END::date;
END $$;

-- ── 6. RPC: generate_contract_invoice ──────────────────────
CREATE OR REPLACE FUNCTION public.generate_contract_invoice(_contract_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _c public.contracts%ROWTYPE;
  _invoice_id uuid;
  _invoice_number text;
  _subtotal bigint;
  _tax bigint;
  _total bigint;
  _due_date date;
  _period_start date;
  _period_end date;
  _line jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Only admins or system can generate contract invoices';
  END IF;

  SELECT * INTO _c FROM public.contracts WHERE id = _contract_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Contract % not found', _contract_id; END IF;
  IF NOT _c.billing_enabled THEN RAISE EXCEPTION 'Contract % does not have billing enabled', _contract_id; END IF;
  IF _c.status <> 'active' THEN RAISE EXCEPTION 'Contract % is not active (status=%)', _contract_id, _c.status; END IF;
  IF _c.billing_amount_cents IS NULL OR _c.billing_amount_cents <= 0 THEN
    RAISE EXCEPTION 'Contract % has no billing_amount_cents set', _contract_id;
  END IF;
  IF _c.billing_interval IS NULL THEN
    RAISE EXCEPTION 'Contract % has no billing_interval set', _contract_id;
  END IF;
  IF _c.billing_next_date IS NULL THEN
    RAISE EXCEPTION 'Contract % has no billing_next_date set', _contract_id;
  END IF;
  IF _c.billing_next_date > CURRENT_DATE THEN
    RAISE EXCEPTION 'Contract % not due until %', _contract_id, _c.billing_next_date;
  END IF;

  _period_start := _c.billing_next_date;
  _period_end   := public.advance_contract_billing_date(_period_start, _c.billing_interval, _c.billing_interval_count);
  _subtotal     := _c.billing_amount_cents;
  _tax          := round(_subtotal * _c.billing_tax_rate)::bigint;
  _total        := _subtotal + _tax;
  _due_date     := CURRENT_DATE + COALESCE(_c.billing_due_in_days, 30);

  _invoice_number := 'CTR-' || to_char(CURRENT_DATE, 'YYYYMMDD') || '-' ||
                     lpad(floor(random()*100000)::text, 5, '0');

  _line := jsonb_build_array(jsonb_build_object(
    'description', _c.title || ' (' || to_char(_period_start, 'YYYY-MM-DD') || ' → ' || to_char(_period_end, 'YYYY-MM-DD') || ')',
    'quantity', 1,
    'unit_price_cents', _subtotal,
    'total_cents', _subtotal
  ));

  INSERT INTO public.invoices (
    invoice_number, customer_email, customer_name, status, line_items,
    subtotal_cents, tax_rate, tax_cents, total_cents, currency,
    due_date, issue_date, payment_terms, notes, sent_at, contract_id
  ) VALUES (
    _invoice_number, _c.counterparty_email, _c.counterparty_name, 'sent',
    _line, _subtotal, _c.billing_tax_rate, _tax, _total, upper(_c.currency),
    _due_date, CURRENT_DATE, 'Net ' || COALESCE(_c.billing_due_in_days,30) || ' days',
    'Generated from contract ' || _c.id::text, now(), _c.id
  ) RETURNING id INTO _invoice_id;

  UPDATE public.contracts SET
    billing_next_date = _period_end,
    billing_last_invoice_id = _invoice_id,
    updated_at = now()
  WHERE id = _contract_id;

  RETURN jsonb_build_object(
    'ok', true,
    'invoice_id', _invoice_id,
    'invoice_number', _invoice_number,
    'total_cents', _total,
    'currency', upper(_c.currency),
    'next_invoice_date', _period_end
  );
END $$;

REVOKE ALL ON FUNCTION public.generate_contract_invoice(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generate_contract_invoice(uuid) TO authenticated, service_role;

-- ── 7. RPC: mark_contract_obligation_status ────────────────
CREATE OR REPLACE FUNCTION public.mark_contract_obligation_status(
  _obligation_id uuid,
  _status text,
  _notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE _r public.contract_obligations%ROWTYPE;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Only admins or system can update contract obligations';
  END IF;
  IF _status NOT IN ('pending','met','overdue','waived') THEN
    RAISE EXCEPTION 'Invalid status %; expected pending|met|overdue|waived', _status;
  END IF;
  UPDATE public.contract_obligations
     SET status = _status,
         notes = COALESCE(_notes, notes),
         met_at = CASE WHEN _status = 'met' THEN now() ELSE NULL END,
         met_by = CASE WHEN _status = 'met' THEN auth.uid() ELSE NULL END,
         updated_at = now()
   WHERE id = _obligation_id
   RETURNING * INTO _r;
  IF NOT FOUND THEN RAISE EXCEPTION 'Obligation % not found', _obligation_id; END IF;
  RETURN jsonb_build_object('ok', true, 'id', _r.id, 'status', _r.status);
END $$;

REVOKE ALL ON FUNCTION public.mark_contract_obligation_status(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_contract_obligation_status(uuid, text, text) TO authenticated, service_role;

-- ── 8. RPC: log_contract_invoice_reminder (idempotent) ─────
CREATE OR REPLACE FUNCTION public.log_contract_invoice_reminder(
  _invoice_id uuid,
  _offset_days integer,
  _triggered_by text DEFAULT 'cron',
  _recipient text DEFAULT NULL,
  _metadata jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE _row public.contract_invoice_reminders%ROWTYPE; _contract_id uuid;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Only admins or system can log reminders';
  END IF;
  SELECT contract_id INTO _contract_id FROM public.invoices WHERE id = _invoice_id;
  INSERT INTO public.contract_invoice_reminders (invoice_id, contract_id, offset_days, triggered_by, recipient, metadata)
  VALUES (_invoice_id, _contract_id, _offset_days, _triggered_by, _recipient, COALESCE(_metadata,'{}'::jsonb))
  ON CONFLICT (invoice_id, offset_days) DO NOTHING
  RETURNING * INTO _row;
  IF _row.id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'duplicate', true);
  END IF;
  RETURN jsonb_build_object('ok', true, 'reminder_id', _row.id, 'duplicate', false);
END $$;

REVOKE ALL ON FUNCTION public.log_contract_invoice_reminder(uuid, integer, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_contract_invoice_reminder(uuid, integer, text, text, jsonb) TO authenticated, service_role;

-- ── 9. helper view: overdue-flagged obligations (auto-flag) ─
CREATE OR REPLACE VIEW public.contract_obligations_with_status AS
SELECT
  o.*,
  CASE
    WHEN o.status = 'pending' AND o.due_date IS NOT NULL AND o.due_date < CURRENT_DATE THEN true
    ELSE false
  END AS is_overdue
FROM public.contract_obligations o;

GRANT SELECT ON public.contract_obligations_with_status TO authenticated, service_role;
