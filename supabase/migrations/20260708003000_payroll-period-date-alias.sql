-- mcp_create_payroll_run ignored p_period_date: the tool_definition documents
-- `period_date`, but operators guessing the RPC param name (the underlying
-- function takes p_period_date) got silently defaulted to CURRENT_DATE —
-- a June call created a July run. Accept both spellings; error loudly on an
-- unparseable date instead of silently running the wrong month.
-- Idempotent + forward-dated for the Lovable-managed migrate runner.

CREATE OR REPLACE FUNCTION public.mcp_create_payroll_run(args jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_raw text;
  v_date date;
BEGIN
  v_raw := COALESCE(args->>'period_date', args->>'p_period_date');
  IF v_raw IS NULL THEN
    v_date := CURRENT_DATE;
  ELSE
    BEGIN
      v_date := v_raw::date;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'period_date must be YYYY-MM-DD, got: %', v_raw;
    END;
  END IF;
  RETURN public.create_payroll_run(v_date);
END; $$;
