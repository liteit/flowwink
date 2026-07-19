-- Edge-surface refactor B5: five FlowPilot lifecycle functions consolidated
-- into flowpilot-lifecycle (dispatch on ?task=), and cron-health folded into
-- instance-health (?check=cron). Repoints existing cron jobs to the new URLs.
--
-- Live inventory 2026-07-19: flowpilot-learn is cron-scheduled on all three
-- fleet instances; flowpilot-followthrough on liteit. Jobnames stay unchanged
-- ('flowpilot-learn' etc.) per the wire-name policy — only the URL moves.
--
-- NB: the postgres role can SELECT cron.job but not UPDATE it directly —
-- repoint via unschedule + re-schedule (pg_cron's own surface). Idempotent;
-- forward-dated for managed ledgers.

DO $$
DECLARE
  r RECORD;
  new_cmd text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    FOR r IN
      SELECT jobid, jobname, schedule, command FROM cron.job
       WHERE command LIKE '%/functions/v1/flowpilot-learn%'
          OR command LIKE '%/functions/v1/flowpilot-followthrough%'
          OR command LIKE '%/functions/v1/flowpilot-briefing%'
          OR command LIKE '%/functions/v1/flowpilot-distill%'
          OR command LIKE '%/functions/v1/skill-curator%'
          OR command LIKE '%/functions/v1/cron-health%'
    LOOP
      new_cmd := replace(replace(replace(replace(replace(replace(r.command,
        '/functions/v1/flowpilot-learn',         '/functions/v1/flowpilot-lifecycle?task=learn'),
        '/functions/v1/flowpilot-followthrough', '/functions/v1/flowpilot-lifecycle?task=followthrough'),
        '/functions/v1/flowpilot-briefing',      '/functions/v1/flowpilot-lifecycle?task=briefing'),
        '/functions/v1/flowpilot-distill',       '/functions/v1/flowpilot-lifecycle?task=distill'),
        '/functions/v1/skill-curator',           '/functions/v1/flowpilot-lifecycle?task=curator'),
        '/functions/v1/cron-health',             '/functions/v1/instance-health?check=cron');
      PERFORM cron.unschedule(r.jobid);
      PERFORM cron.schedule(r.jobname, r.schedule, new_cmd);
      RAISE NOTICE 'repointed cron job % to flowpilot-lifecycle', r.jobname;
    END LOOP;
  END IF;
END $$;
