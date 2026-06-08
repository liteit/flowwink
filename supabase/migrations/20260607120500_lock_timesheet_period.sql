-- lock_timesheet_period was mis-wired: its handler pointed at
-- `rpc:close_accounting_period` (wrong subsystem — that closes the ACCOUNTING
-- period with side effects on journal entries) and its arg names
-- (fiscal_year/period_month) did not match that RPC's params (p_year/p_month).
-- There was no timesheet period-lock mechanism at all.
--
-- This creates a self-contained timesheet period lock: a table that records
-- which (year, month) periods are frozen, an RPC matching the skill's existing
-- arg names, and repoints the skill handler. Locked periods can be checked by
-- timesheet/invoicing code before allowing edits to time_entries in that month.

CREATE TABLE IF NOT EXISTS public.timesheet_period_locks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  fiscal_year integer NOT NULL,
  period_month integer NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  notes text,
  locked_by uuid,
  locked_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (fiscal_year, period_month)
);

ALTER TABLE public.timesheet_period_locks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage timesheet period locks" ON public.timesheet_period_locks;
CREATE POLICY "Admins manage timesheet period locks"
  ON public.timesheet_period_locks FOR ALL
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));

CREATE OR REPLACE FUNCTION public.lock_timesheet_period(
  p_fiscal_year integer,
  p_period_month integer,
  p_notes text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _lock_id uuid;
  _entry_count integer;
BEGIN
  IF NOT (has_role(auth.uid(), 'admin'::app_role) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Only admins can lock timesheet periods';
  END IF;
  IF p_fiscal_year IS NULL OR p_period_month IS NULL THEN
    RAISE EXCEPTION 'fiscal_year and period_month are required';
  END IF;
  IF p_period_month < 1 OR p_period_month > 12 THEN
    RAISE EXCEPTION 'period_month must be 1-12 (got %)', p_period_month;
  END IF;

  INSERT INTO public.timesheet_period_locks (fiscal_year, period_month, notes, locked_by)
  VALUES (p_fiscal_year, p_period_month, p_notes, auth.uid())
  ON CONFLICT (fiscal_year, period_month)
  DO UPDATE SET notes = COALESCE(EXCLUDED.notes, public.timesheet_period_locks.notes),
                locked_at = now(),
                locked_by = auth.uid()
  RETURNING id INTO _lock_id;

  SELECT count(*) INTO _entry_count
  FROM public.time_entries
  WHERE date_part('year', entry_date) = p_fiscal_year
    AND date_part('month', entry_date) = p_period_month;

  PERFORM public.emit_platform_event(
    'timesheet.period_locked',
    jsonb_build_object('fiscal_year', p_fiscal_year, 'period_month', p_period_month, 'entries_locked', _entry_count),
    'lock_timesheet_period'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'lock_id', _lock_id,
    'fiscal_year', p_fiscal_year,
    'period_month', p_period_month,
    'entries_locked', _entry_count
  );
END $function$;

-- Repoint the skill from the wrong handler to the new RPC.
UPDATE public.agent_skills
SET handler = 'rpc:lock_timesheet_period'
WHERE name = 'lock_timesheet_period';
