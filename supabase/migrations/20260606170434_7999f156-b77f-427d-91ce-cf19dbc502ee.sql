
-- Idempotent helper: (re)schedules the consultant reindex cron job
-- pointing at the URL supplied by the caller (typically the current
-- Supabase project's functions endpoint). Safe to call repeatedly.
create or replace function public.ensure_consultant_reindex_cron(
  p_url text,
  p_service_key text default null,
  p_schedule text default '*/10 * * * *'
)
returns jsonb
language plpgsql
security definer
set search_path = public, cron, net
as $fn$
declare
  v_job_name constant text := 'reindex-consultant-embeddings';
  v_auth_header text;
  v_command text;
  v_job_id bigint;
begin
  -- Only admins may (re)schedule.
  if not public.has_role(auth.uid(), 'admin') then
    raise exception 'forbidden: admin role required';
  end if;

  if p_url is null or length(trim(p_url)) = 0 then
    raise exception 'p_url is required';
  end if;

  v_auth_header := coalesce(
    'Bearer ' || nullif(p_service_key, ''),
    'Bearer ' || nullif(current_setting('app.settings.service_role_key', true), ''),
    ''
  );

  -- Drop previous schedule (any URL) so we always re-point at the caller.
  begin
    perform cron.unschedule(v_job_name);
  exception when others then null;
  end;

  v_command := format(
    $cmd$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', %L
      ),
      body := jsonb_build_object('action', 'reindex_stale', 'limit', 25)
    );
    $cmd$,
    rtrim(p_url, '/') || '/functions/v1/resume-match',
    v_auth_header
  );

  v_job_id := cron.schedule(v_job_name, p_schedule, v_command);

  return jsonb_build_object(
    'scheduled', true,
    'job_id', v_job_id,
    'job_name', v_job_name,
    'schedule', p_schedule,
    'target_url', rtrim(p_url, '/') || '/functions/v1/resume-match'
  );
end;
$fn$;

revoke all on function public.ensure_consultant_reindex_cron(text, text, text) from public;
grant execute on function public.ensure_consultant_reindex_cron(text, text, text) to authenticated, service_role;

-- Read-only status helper used by the admin UI to show whether the
-- background job is active on this instance.
create or replace function public.consultant_reindex_cron_status()
returns jsonb
language plpgsql
security definer
set search_path = public, cron
as $fn$
declare
  v_row record;
begin
  if not public.has_role(auth.uid(), 'admin') then
    raise exception 'forbidden: admin role required';
  end if;

  select jobid, schedule, command, active
    into v_row
  from cron.job
  where jobname = 'reindex-consultant-embeddings'
  limit 1;

  if not found then
    return jsonb_build_object('scheduled', false);
  end if;

  return jsonb_build_object(
    'scheduled', true,
    'job_id', v_row.jobid,
    'schedule', v_row.schedule,
    'active', v_row.active,
    'command_excerpt', left(v_row.command, 200)
  );
end;
$fn$;

revoke all on function public.consultant_reindex_cron_status() from public;
grant execute on function public.consultant_reindex_cron_status() to authenticated, service_role;
