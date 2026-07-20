-- run_subscription_billing() — the sweep that subscription-billing-cron did in
-- TypeScript, moved into Postgres so it can run as a cron AUTOMATION.
--
-- Why this exists (edge-surface B3): an agent_automations row calls ONE skill
-- with STATIC arguments and cannot iterate. subscription-billing-cron looped
-- over due subscriptions calling generate_subscription_invoice(id) per row, so
-- it could not be seeded as an automation until the loop lived in SQL. That
-- edge function was never cron-scheduled on any instance, so this is the first
-- time the sweep actually gets a scheduler.
--
-- Faithful port of the edge function's behaviour:
--   1. run_trial_conversions() first — newly-active subscriptions are billed in
--      the same cycle (failures are reported, never fatal, as before).
--   2. provider='manual' AND status='active' AND next_invoice_date <= today,
--      capped at 500 rows per run. Stripe subscriptions are NOT touched —
--      Stripe bills them with its own scheduler.
--   3. One invoice per subscription via generate_subscription_invoice.
--
-- Per-row exception handling is the critical difference from a naive loop:
-- generate_subscription_invoice RAISEs on any guard violation, so without an
-- inner block a single bad row would abort the whole sweep and every later
-- subscription would go unbilled. Each row commits or fails alone.
--
-- Idempotent by construction: the RPC refuses a subscription whose
-- next_invoice_date is in the future, and it rolls the date forward on success,
-- so a second run in the same day bills nobody twice.

CREATE OR REPLACE FUNCTION public.run_subscription_billing()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _trial jsonb;
  _trial_error text := NULL;
  _sub record;
  _res jsonb;
  _results jsonb := '[]'::jsonb;
  _ok integer := 0;
  _failed integer := 0;
  _candidates integer := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Only admins or system can run subscription billing';
  END IF;

  -- 1) Trial conversions — advisory, never fatal (mirrors the edge function's
  --    console.warn path).
  BEGIN
    _trial := public.run_trial_conversions();
  EXCEPTION WHEN OTHERS THEN
    _trial_error := SQLERRM;
  END;

  -- 2) Due manual subscriptions.
  FOR _sub IN
    SELECT id
      FROM public.subscriptions
     WHERE provider = 'manual'
       AND status = 'active'::subscription_status
       AND next_invoice_date <= CURRENT_DATE
     ORDER BY next_invoice_date
     LIMIT 500
  LOOP
    _candidates := _candidates + 1;
    BEGIN
      _res := public.generate_subscription_invoice(_sub.id);
      _ok := _ok + 1;
      _results := _results || jsonb_build_object(
        'subscription_id', _sub.id,
        'ok', true,
        'invoice_id', _res->>'invoice_id',
        'invoice_number', _res->>'invoice_number'
      );
    EXCEPTION WHEN OTHERS THEN
      -- One bad subscription must not stop the rest of the run.
      _failed := _failed + 1;
      _results := _results || jsonb_build_object(
        'subscription_id', _sub.id,
        'ok', false,
        'error', SQLERRM
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'run_at', now(),
    'trial_sweep', _trial,
    'trial_error', _trial_error,
    'candidates', _candidates,
    'succeeded', _ok,
    'failed', _failed,
    'results', _results
  );
END $function$;

GRANT EXECUTE ON FUNCTION public.run_subscription_billing() TO authenticated, service_role;
