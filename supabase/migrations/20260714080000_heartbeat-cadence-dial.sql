-- Heartbeat cadence dial (cost control — lever 2 of the token-cost finding).
-- Observed on dev: hourly heartbeats × tier 'reasoning' ≈ 3M prompt tokens/day.
-- New DEFAULT cadence is every 3 hours; instances dial up/down per workload
-- via set_flowpilot_heartbeat_cadence (admin/service gated).
--
-- Companion dial (lever 1) lives in code: heartbeat_overrides.tier
-- ('fast' default, 'reasoning' to dial up) — see flowpilot-heartbeat/index.ts.

-- ── 1. The dial ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_flowpilot_heartbeat_cadence(
  p_schedule text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog', 'extensions'
AS $$
DECLARE
  v_jobid bigint;
BEGIN
  IF NOT (auth.role() = 'service_role' OR public.has_role(auth.uid(), 'admin')) THEN
    RAISE EXCEPTION 'Only admins can change the heartbeat cadence';
  END IF;

  -- Loose 5-field cron sanity check; cron.alter_job validates for real.
  IF p_schedule !~ '^\S+\s+\S+\s+\S+\s+\S+\s+\S+$' THEN
    RAISE EXCEPTION 'Invalid cron schedule %', p_schedule;
  END IF;

  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'flowpilot-heartbeat';
  IF v_jobid IS NULL THEN
    RETURN jsonb_build_object('heartbeat_cadence', 'job_not_registered');
  END IF;

  PERFORM cron.alter_job(v_jobid, schedule => p_schedule);
  RETURN jsonb_build_object('heartbeat_cadence', p_schedule);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_flowpilot_heartbeat_cadence(text)
  TO authenticated, service_role;

-- ── 2. Apply the new default — ONLY where the old default is still in place ──
-- An instance that already tuned its cadence keeps its custom schedule.
DO $$
DECLARE
  v_jobid bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    SELECT jobid INTO v_jobid
    FROM cron.job
    WHERE jobname = 'flowpilot-heartbeat' AND schedule = '0 * * * *';
    IF v_jobid IS NOT NULL THEN
      PERFORM cron.alter_job(v_jobid, schedule => '0 */3 * * *');
    END IF;
  END IF;
END $$;
