-- Edge-surface refactor B2: eleven transactional-comms functions consolidated
-- into comms-send (dispatch on ?kind=). The standalone functions are deleted,
-- so any cron job still POSTing to their URLs would silently 404 on every tick
-- (pg_net reports success regardless — the exact silent-degradation class from
-- the 2026-07-17 cron-parser incident).
--
-- NB: the postgres role can SELECT cron.job but not UPDATE it directly
-- (permission denied — found live on the fleet). Repoint by
-- unschedule + re-schedule with the same jobname/schedule, which goes through
-- pg_cron's own SECURITY DEFINER surface. Idempotent: only touches jobs whose
-- command still references an old URL. Forward-dated for managed ledgers.

DO $$
DECLARE
  r RECORD;
  new_cmd text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    FOR r IN
      SELECT jobid, jobname, schedule, command FROM cron.job
       WHERE command LIKE '%/functions/v1/send-booking-reminders%'
          OR command LIKE '%/functions/v1/send-calendar-reminders%'
          OR command LIKE '%/functions/v1/csat-dispatch%'
          OR command LIKE '%/functions/v1/send-webinar-reminders%'
          OR command LIKE '%/functions/v1/survey-send%'
          OR command LIKE '%/functions/v1/send-order-confirmation%'
    LOOP
      new_cmd := replace(replace(replace(replace(replace(replace(r.command,
        '/functions/v1/send-booking-reminders',  '/functions/v1/comms-send?kind=booking_reminders'),
        '/functions/v1/send-calendar-reminders', '/functions/v1/comms-send?kind=calendar_reminders'),
        '/functions/v1/csat-dispatch',           '/functions/v1/comms-send?kind=csat_dispatch'),
        '/functions/v1/send-webinar-reminders',  '/functions/v1/comms-send?kind=webinar_reminders'),
        '/functions/v1/survey-send',             '/functions/v1/comms-send?kind=survey_send'),
        '/functions/v1/send-order-confirmation', '/functions/v1/comms-send?kind=order_confirmation');
      PERFORM cron.unschedule(r.jobid);
      PERFORM cron.schedule(r.jobname, r.schedule, new_cmd);
      RAISE NOTICE 'repointed cron job % to comms-send', r.jobname;
    END LOOP;
  END IF;
END $$;
