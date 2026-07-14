-- Heartbeat cadence dial
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