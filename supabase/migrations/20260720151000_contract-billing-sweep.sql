-- run_contract_billing() — the INVOICING half of contract-billing-cron, moved
-- into Postgres so it can run as a cron AUTOMATION (edge-surface B3).
--
-- contract-billing-cron does two things:
--   1. invoice active billing_enabled contracts whose billing_next_date is due
--      → ported here, because an automation calls one skill with static args
--        and cannot loop over rows
--   2. email payment reminders per contract.billing_reminder_offsets, with HTML
--      templates, delivered through the email pipeline
--      → deliberately NOT ported. Rendering HTML and sending mail is the comms
--        layer's job, not a billing sweep's; SQL is the wrong place for
--        templates. That half stays in the edge function until it moves to
--        comms-send as its own kind.
--
-- Same due criteria as the edge function: status='active', billing_enabled,
-- billing_next_date IS NOT NULL AND <= today, capped at 500 rows.
--
-- Per-row exception handling matters here for the same reason as the
-- subscription sweep: generate_contract_invoice RAISEs on guard violations,
-- and one bad contract must not leave every later contract unbilled.
--
-- Idempotency is owned by generate_contract_invoice, which rolls
-- billing_next_date forward — re-running the same day bills nobody twice.

CREATE OR REPLACE FUNCTION public.run_contract_billing()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _c record;
  _res jsonb;
  _results jsonb := '[]'::jsonb;
  _ok integer := 0;
  _failed integer := 0;
  _candidates integer := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin'::app_role) OR auth.uid() IS NULL) THEN
    RAISE EXCEPTION 'Only admins or system can run contract billing';
  END IF;

  FOR _c IN
    SELECT id, title
      FROM public.contracts
     WHERE status = 'active'
       AND billing_enabled IS TRUE
       AND billing_next_date IS NOT NULL
       AND billing_next_date <= CURRENT_DATE
     ORDER BY billing_next_date
     LIMIT 500
  LOOP
    _candidates := _candidates + 1;
    BEGIN
      _res := public.generate_contract_invoice(_c.id);
      _ok := _ok + 1;
      _results := _results || jsonb_build_object(
        'contract_id', _c.id,
        'title', _c.title,
        'ok', true,
        'invoice_id', _res->>'invoice_id',
        'invoice_number', _res->>'invoice_number'
      );
    EXCEPTION WHEN OTHERS THEN
      _failed := _failed + 1;
      _results := _results || jsonb_build_object(
        'contract_id', _c.id,
        'title', _c.title,
        'ok', false,
        'error', SQLERRM
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'run_at', now(),
    'candidates', _candidates,
    'succeeded', _ok,
    'failed', _failed,
    'results', _results,
    'note', 'Invoicing only. Payment reminders still run from the contract-billing-cron edge function (HTML templates + email delivery).'
  );
END $function$;

GRANT EXECUTE ON FUNCTION public.run_contract_billing() TO authenticated, service_role;
