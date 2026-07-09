-- move_application_stage: transition a recruitment application to a new pipeline stage.
--
-- Process-QA finding 2026-07-09 (hire-to-retire): move_application_stage was wired to
-- the generic db:applications CRUD handler, whose verb-inference does not know "move"
-- (only create/update/delete + the 2026-07-09 create-synonyms) → it silently fell
-- through to 'list' and returned the applications list instead of transitioning the
-- candidate. And even mapped to update it would miss: the generic handler keys on `id`,
-- but the skill passes the natural key `application_id`. So the recruitment pipeline
-- could not be advanced by an agent at all. Dedicated RPC fixes both.
--
-- Idempotent (CREATE OR REPLACE). Service-role escape so the MCP gateway (auth.uid()
-- NULL under the service key) is not blocked.
create or replace function public.move_application_stage(
  p_application_id uuid,
  p_to_stage text,
  p_comment text default null,
  p_rejected_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app public.applications%rowtype;
  v_from text;
  v_stage public.application_stage;
begin
  if not (auth.role() = 'service_role' or public.has_role(auth.uid(), 'admin')) then
    raise exception 'Only admins can move applications';
  end if;
  if p_to_stage is null or length(trim(p_to_stage)) = 0 then
    raise exception 'p_to_stage is required';
  end if;
  -- stage is the application_stage enum, not text: validate before casting so a bad
  -- value gives a clear message (with the valid set) instead of a raw cast error.
  if not exists (select 1 from pg_enum
                 where enumtypid = 'public.application_stage'::regtype
                   and enumlabel = p_to_stage) then
    raise exception 'Invalid stage %. Valid: applied, screened, interview_scheduled, interviewed, offer_sent, hired, rejected, withdrawn', p_to_stage;
  end if;
  v_stage := p_to_stage::public.application_stage;

  select * into v_app from public.applications where id = p_application_id;
  if not found then
    raise exception 'Application % not found', p_application_id;
  end if;
  v_from := v_app.stage::text;

  -- Idempotent: already at the target stage → success no-op.
  if v_app.stage = v_stage then
    return jsonb_build_object('application_id', v_app.id, 'stage', v_app.stage,
      'from_stage', v_from, 'unchanged', true);
  end if;

  update public.applications
     set stage = v_stage,
         rejected_reason = case when v_stage = 'rejected'::public.application_stage
                                then coalesce(p_rejected_reason, rejected_reason)
                                else rejected_reason end,
         updated_at = now()
   where id = p_application_id
  returning * into v_app;

  return jsonb_build_object(
    'application_id', v_app.id,
    'from_stage', v_from,
    'stage', v_app.stage,
    'rejected_reason', v_app.rejected_reason,
    'moved', true
  );
end;
$$;
