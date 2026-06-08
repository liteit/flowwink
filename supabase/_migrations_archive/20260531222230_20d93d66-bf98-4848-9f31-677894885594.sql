-- Demo cycle cron management RPCs.
-- Idempotent. Assumes pg_cron + pg_net are already installed (they are on
-- Lovable Cloud / Supabase Cloud). For self-hosted instances missing them,
-- run `create extension pg_cron; create extension pg_net;` manually once.

create or replace function public.enable_demo_cycle_cron(
  p_function_url text,
  p_anon_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_job_id bigint;
  v_command text;
begin
  if not has_role(auth.uid(), 'admin') then
    raise exception 'admin role required';
  end if;
  if p_function_url is null or length(p_function_url) = 0 then
    raise exception 'p_function_url required';
  end if;
  if p_anon_key is null or length(p_anon_key) = 0 then
    raise exception 'p_anon_key required';
  end if;

  v_command := format(
    $cmd$select net.http_post(
      url := %L,
      headers := %L::jsonb,
      body := jsonb_build_object('triggered_at', now())
    );$cmd$,
    p_function_url,
    jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', p_anon_key,
      'Authorization', 'Bearer ' || p_anon_key
    )::text
  );

  if exists (select 1 from cron.job where jobname = 'demo-cycle-hourly') then
    perform cron.unschedule('demo-cycle-hourly');
  end if;

  select cron.schedule('demo-cycle-hourly', '0 * * * *', v_command) into v_job_id;

  return jsonb_build_object(
    'scheduled', true,
    'jobname', 'demo-cycle-hourly',
    'job_id', v_job_id,
    'schedule', '0 * * * *'
  );
end;
$$;

create or replace function public.disable_demo_cycle_cron()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_existed boolean;
begin
  if not has_role(auth.uid(), 'admin') then
    raise exception 'admin role required';
  end if;

  select exists(select 1 from cron.job where jobname = 'demo-cycle-hourly') into v_existed;
  if v_existed then
    perform cron.unschedule('demo-cycle-hourly');
  end if;

  return jsonb_build_object('unscheduled', v_existed);
end;
$$;

create or replace function public.demo_cycle_cron_status()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row record;
  v_last record;
begin
  select jobid, schedule, active into v_row
  from cron.job
  where jobname = 'demo-cycle-hourly'
  limit 1;

  if not found then
    return jsonb_build_object('scheduled', false);
  end if;

  begin
    select start_time, status, return_message into v_last
    from cron.job_run_details
    where jobid = v_row.jobid
    order by start_time desc
    limit 1;
  exception when others then
    v_last := null;
  end;

  return jsonb_build_object(
    'scheduled', true,
    'jobname', 'demo-cycle-hourly',
    'schedule', v_row.schedule,
    'active', v_row.active,
    'last_run_at', v_last.start_time,
    'last_status', v_last.status,
    'last_message', v_last.return_message
  );
end;
$$;

grant execute on function public.enable_demo_cycle_cron(text, text) to authenticated;
grant execute on function public.disable_demo_cycle_cron() to authenticated;
grant execute on function public.demo_cycle_cron_status() to authenticated, anon;