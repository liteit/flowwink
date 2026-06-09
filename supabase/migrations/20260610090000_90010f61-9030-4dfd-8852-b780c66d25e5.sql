-- Fix get_bootstrap_health: count CONSECUTIVE bootstrap failures, not the total
-- number of failures in the last 10 runs.
--
-- The previous body counted every 'failed' row among the last 10 runs (despite
-- its own "consecutive" comment). That made the bootstrap circuit breaker STICKY:
-- once a module had failed 3+ times, a successful re-bootstrap could NOT clear the
-- degraded state, because the old failures were still inside the 10-run window.
-- So even after the underlying bug was fixed, enabling FlowPilot — which
-- re-bootstraps every enabled module — kept showing a red "N error(s)" toast,
-- and the only escape was deleting bootstrap_runs rows by hand.
--
-- (Hit on the `ecommerce` module: a stray double-comma `},,` in its skillSeeds
-- left an array hole that bootstrap's for...of reported as "invalid skill seed",
-- degrading the module. Fixed 2026-06-10.)
--
-- Now: walk runs newest-first and stop at the first success — the streak is the
-- run of consecutive failures ending at the most recent run. A single successful
-- (re-)bootstrap after a fix resets the streak to 0 and clears `is_degraded`, so
-- the circuit breaker self-heals fleet-wide. Idempotent (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION public.get_bootstrap_health(_module_id text)
 RETURNS TABLE(last_status text, last_run_at timestamp with time zone, last_hash text, failure_streak integer, is_degraded boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _streak INTEGER := 0;
  _last_status TEXT;
  _last_run_at TIMESTAMPTZ;
  _last_hash TEXT;
  _rec RECORD;
BEGIN
  SELECT status, created_at, config_hash
    INTO _last_status, _last_run_at, _last_hash
  FROM public.bootstrap_runs
  WHERE module_id = _module_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF _last_status IS NULL THEN
    RETURN QUERY SELECT NULL::TEXT, NULL::TIMESTAMPTZ, NULL::TEXT, 0, FALSE;
    RETURN;
  END IF;

  -- CONSECUTIVE failures from the most recent run backwards; the first success
  -- breaks the streak (so a fix-and-retry success un-degrades the module).
  FOR _rec IN
    SELECT status
    FROM public.bootstrap_runs
    WHERE module_id = _module_id
    ORDER BY created_at DESC
    LIMIT 50
  LOOP
    IF _rec.status = 'failed' THEN
      _streak := _streak + 1;
    ELSE
      EXIT;
    END IF;
  END LOOP;

  RETURN QUERY SELECT
    _last_status,
    _last_run_at,
    _last_hash,
    _streak,
    (_streak >= 3);
END;
$function$;
