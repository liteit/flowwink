-- Scheduled-job health detector (hardening #1, layer 1 — "make the silent loud").
CREATE OR REPLACE FUNCTION public.cron_health_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, cron, net
AS $fn$
DECLARE
  v_self_host   text;
  v_indexer_cmd text;
  v_jobs        jsonb := '[]'::jsonb;
  v_http_errors jsonb := '[]'::jsonb;
  v_has_queue   boolean := to_regclass('net.http_request_queue') IS NOT NULL;
BEGIN
  IF NOT (auth.role() = 'service_role' OR public.has_role(auth.uid(), 'admin')) THEN
    RAISE EXCEPTION 'cron_health_report: admin or service_role required';
  END IF;

  IF to_regclass('cron.job') IS NULL THEN
    RETURN jsonb_build_object(
      'checked_at', now(),
      'cron_available', false,
      'self_host', NULL,
      'jobs', '[]'::jsonb,
      'http_errors_recent', '[]'::jsonb,
      'flags', jsonb_build_object('jobs_total', 0, 'jobs_never_ran', 0,
                                  'jobs_foreign_host', 0, 'http_errors_24h', 0)
    );
  END IF;

  SELECT command INTO v_indexer_cmd FROM cron.job WHERE jobname = 'knowledge-indexer';
  v_self_host := substring(coalesce(v_indexer_cmd, '') from 'https://[a-z0-9]+\.supabase\.co');

  IF to_regclass('cron.job_run_details') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(j ORDER BY j->>'jobname'), '[]'::jsonb) INTO v_jobs
    FROM (
      SELECT jsonb_build_object(
        'jobname', jb.jobname,
        'schedule', jb.schedule,
        'active', jb.active,
        'target_host', substring(jb.command from 'https://[a-z0-9]+\.supabase\.co'),
        'foreign_host', (
          v_self_host IS NOT NULL
          AND substring(jb.command from 'https://[a-z0-9]+\.supabase\.co') IS NOT NULL
          AND substring(jb.command from 'https://[a-z0-9]+\.supabase\.co') <> v_self_host
        ),
        'never_ran', (lr.status IS NULL),
        'last_status', lr.status,
        'last_run', lr.start_time,
        'last_run_age_seconds', CASE WHEN lr.start_time IS NULL THEN NULL
                                     ELSE extract(epoch FROM (now() - lr.start_time))::bigint END
      ) AS j
      FROM cron.job jb
      LEFT JOIN LATERAL (
        SELECT d.status, d.start_time
        FROM cron.job_run_details d
        WHERE d.jobid = jb.jobid
        ORDER BY d.start_time DESC NULLS LAST
        LIMIT 1
      ) lr ON true
    ) q;
  ELSE
    SELECT coalesce(jsonb_agg(jsonb_build_object(
      'jobname', jb.jobname, 'schedule', jb.schedule, 'active', jb.active,
      'target_host', substring(jb.command from 'https://[a-z0-9]+\.supabase\.co'),
      'foreign_host', (
        v_self_host IS NOT NULL
        AND substring(jb.command from 'https://[a-z0-9]+\.supabase\.co') IS NOT NULL
        AND substring(jb.command from 'https://[a-z0-9]+\.supabase\.co') <> v_self_host
      ),
      'never_ran', true, 'last_status', NULL, 'last_run', NULL, 'last_run_age_seconds', NULL
    ) ORDER BY jb.jobname), '[]'::jsonb) INTO v_jobs
    FROM cron.job jb;
  END IF;

  IF to_regclass('net._http_response') IS NOT NULL THEN
    BEGIN
      IF v_has_queue THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'id', r.id, 'status_code', r.status_code, 'created', r.created,
          'url', q.url, 'error', r.error_msg
        ) ORDER BY r.created DESC), '[]'::jsonb) INTO v_http_errors
        FROM net._http_response r
        LEFT JOIN net.http_request_queue q ON q.id = r.id
        WHERE r.created > now() - interval '24 hours'
          AND (r.status_code IS NULL OR r.status_code >= 400 OR r.error_msg IS NOT NULL);
      ELSE
        SELECT coalesce(jsonb_agg(jsonb_build_object(
          'id', r.id, 'status_code', r.status_code, 'created', r.created,
          'url', NULL, 'error', r.error_msg
        ) ORDER BY r.created DESC), '[]'::jsonb) INTO v_http_errors
        FROM net._http_response r
        WHERE r.created > now() - interval '24 hours'
          AND (r.status_code IS NULL OR r.status_code >= 400 OR r.error_msg IS NOT NULL);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_http_errors := '[]'::jsonb;
      RAISE NOTICE 'cron_health_report: http-error scan skipped (%).', SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'checked_at', now(),
    'cron_available', true,
    'self_host', v_self_host,
    'jobs', v_jobs,
    'http_errors_recent', v_http_errors,
    'flags', jsonb_build_object(
      'jobs_total', jsonb_array_length(v_jobs),
      'jobs_never_ran', (SELECT count(*) FROM jsonb_array_elements(v_jobs) e WHERE (e->>'never_ran')::boolean),
      'jobs_foreign_host', (SELECT count(*) FROM jsonb_array_elements(v_jobs) e WHERE (e->>'foreign_host')::boolean),
      'http_errors_24h', jsonb_array_length(v_http_errors)
    )
  );
END
$fn$;

GRANT EXECUTE ON FUNCTION public.cron_health_report() TO anon, authenticated, service_role;