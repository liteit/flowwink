-- Projects: parity round 6 (docs/parity/capabilities/projects.json)
-- Adds: project templates (snapshot + instantiate), team/stakeholder roles
-- skill over the existing project_members table, cost forecasting / burn
-- rate, stage-workflow gating (config + enforcement trigger), task
-- dependencies with cycle detection, Gantt-ready schedule computation, and
-- resource/capacity reporting.
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. Schema additions ──────────────────────────────────────────────────────
ALTER TABLE public.projects
  ADD COLUMN IF NOT EXISTS task_workflow jsonb;

ALTER TABLE public.project_tasks
  ADD COLUMN IF NOT EXISTS start_date date;

CREATE TABLE IF NOT EXISTS public.project_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  -- {tasks:[{title,description,priority,estimated_hours,offset_days,duration_days,subtasks:[…]}],
  --  milestones:[{name,description,offset_days}], defaults:{hourly_rate_cents,currency,is_billable,budget_hours}}
  spec jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.project_templates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage project_templates" ON public.project_templates;
CREATE POLICY "Admins manage project_templates" ON public.project_templates
  FOR ALL
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
DROP POLICY IF EXISTS "Staff view project_templates" ON public.project_templates;
CREATE POLICY "Staff view project_templates" ON public.project_templates
  FOR SELECT
  USING (has_role(auth.uid(), 'admin'::app_role)
      OR has_role(auth.uid(), 'approver'::app_role)
      OR has_role(auth.uid(), 'writer'::app_role));

CREATE TABLE IF NOT EXISTS public.project_task_dependencies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id uuid NOT NULL REFERENCES public.project_tasks(id) ON DELETE CASCADE,
  depends_on_task_id uuid NOT NULL REFERENCES public.project_tasks(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);
ALTER TABLE public.project_task_dependencies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins manage project_task_dependencies" ON public.project_task_dependencies;
CREATE POLICY "Admins manage project_task_dependencies" ON public.project_task_dependencies
  FOR ALL
  USING (has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
DROP POLICY IF EXISTS "Staff view project_task_dependencies" ON public.project_task_dependencies;
CREATE POLICY "Staff view project_task_dependencies" ON public.project_task_dependencies
  FOR SELECT
  USING (has_role(auth.uid(), 'admin'::app_role)
      OR has_role(auth.uid(), 'approver'::app_role)
      OR has_role(auth.uid(), 'writer'::app_role));

-- ── 2. Stage-workflow gating ─────────────────────────────────────────────────
-- projects.task_workflow: {"transitions":{"todo":["in_progress"],…},
--   "require_subtasks_done":true, "enforce_dependencies":true}
-- No config on the project = no gating (fail-forward).
CREATE OR REPLACE FUNCTION public.enforce_task_workflow()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_wf jsonb;
  v_allowed jsonb;
  v_open_subtasks integer;
  v_blocking text;
BEGIN
  IF TG_OP <> 'UPDATE' OR NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT task_workflow INTO v_wf FROM public.projects WHERE id = NEW.project_id;
  IF v_wf IS NULL THEN RETURN NEW; END IF;

  -- Allowed-transition gate
  v_allowed := v_wf->'transitions'->(OLD.status::text);
  IF v_allowed IS NOT NULL AND NOT (v_allowed ? NEW.status::text) THEN
    RAISE EXCEPTION 'Workflow gate: % → % is not allowed for this project (allowed: %)',
      OLD.status, NEW.status, v_allowed;
  END IF;

  -- Sub-task completion gate
  IF COALESCE((v_wf->>'require_subtasks_done')::boolean, false) AND NEW.status::text = 'done' THEN
    SELECT count(*) INTO v_open_subtasks
      FROM public.project_tasks t
     WHERE t.parent_task_id = NEW.id AND t.status::text <> 'done';
    IF v_open_subtasks > 0 THEN
      RAISE EXCEPTION 'Workflow gate: % open sub-task(s) must be done first', v_open_subtasks;
    END IF;
  END IF;

  -- Dependency gate
  IF COALESCE((v_wf->>'enforce_dependencies')::boolean, false)
     AND NEW.status::text IN ('in_progress','review','done') THEN
    SELECT string_agg(t.title, ', ') INTO v_blocking
      FROM public.project_task_dependencies d
      JOIN public.project_tasks t ON t.id = d.depends_on_task_id
     WHERE d.task_id = NEW.id AND t.status::text <> 'done';
    IF v_blocking IS NOT NULL THEN
      RAISE EXCEPTION 'Workflow gate: blocked by unfinished dependencies: %', v_blocking;
    END IF;
  END IF;

  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_enforce_task_workflow ON public.project_tasks;
CREATE TRIGGER trg_enforce_task_workflow
  BEFORE UPDATE ON public.project_tasks
  FOR EACH ROW EXECUTE FUNCTION public.enforce_task_workflow();

CREATE OR REPLACE FUNCTION public.manage_task_workflow(
  p_action text,
  p_project_id uuid,
  p_transitions jsonb DEFAULT NULL,
  p_require_subtasks_done boolean DEFAULT NULL,
  p_enforce_dependencies boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_wf jsonb;
  v_key text;
BEGIN
  IF p_action = 'get' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view workflow config';
    END IF;
  ELSE
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
      RAISE EXCEPTION 'Only admins can change workflow config';
    END IF;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.projects WHERE id = p_project_id) THEN
    RAISE EXCEPTION 'Project % not found', p_project_id;
  END IF;

  IF p_action = 'set' THEN
    IF p_transitions IS NOT NULL THEN
      IF jsonb_typeof(p_transitions) <> 'object' THEN
        RAISE EXCEPTION 'transitions must be an object like {"todo":["in_progress"]}';
      END IF;
      FOR v_key IN SELECT jsonb_object_keys(p_transitions) LOOP
        IF v_key NOT IN ('todo','in_progress','review','done') THEN
          RAISE EXCEPTION 'Unknown status % in transitions (valid: todo|in_progress|review|done)', v_key;
        END IF;
      END LOOP;
    END IF;
    SELECT task_workflow INTO v_wf FROM public.projects WHERE id = p_project_id;
    v_wf := COALESCE(v_wf, '{}'::jsonb);
    IF p_transitions IS NOT NULL THEN v_wf := jsonb_set(v_wf, '{transitions}', p_transitions); END IF;
    IF p_require_subtasks_done IS NOT NULL THEN v_wf := jsonb_set(v_wf, '{require_subtasks_done}', to_jsonb(p_require_subtasks_done)); END IF;
    IF p_enforce_dependencies IS NOT NULL THEN v_wf := jsonb_set(v_wf, '{enforce_dependencies}', to_jsonb(p_enforce_dependencies)); END IF;
    UPDATE public.projects SET task_workflow = v_wf, updated_at = now() WHERE id = p_project_id;
    RETURN jsonb_build_object('success', true, 'project_id', p_project_id, 'task_workflow', v_wf);

  ELSIF p_action = 'clear' THEN
    UPDATE public.projects SET task_workflow = NULL, updated_at = now() WHERE id = p_project_id;
    RETURN jsonb_build_object('success', true, 'project_id', p_project_id, 'task_workflow', NULL);

  ELSIF p_action = 'get' THEN
    SELECT task_workflow INTO v_wf FROM public.projects WHERE id = p_project_id;
    RETURN jsonb_build_object('success', true, 'project_id', p_project_id, 'task_workflow', v_wf);
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use set|clear|get)', p_action;
END; $$;

-- ── 3. Task dependencies + schedule (Gantt backend) ──────────────────────────
CREATE OR REPLACE FUNCTION public.manage_task_dependency(
  p_action text,
  p_task_id uuid DEFAULT NULL,
  p_depends_on_task_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_a public.project_tasks;
  v_b public.project_tasks;
  v_cycle boolean;
  v_result jsonb;
BEGIN
  IF p_action = 'list' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view dependencies';
    END IF;
    SELECT jsonb_build_object('success', true, 'dependencies', COALESCE(jsonb_agg(jsonb_build_object(
      'id', d.id, 'task_id', d.task_id, 'task_title', t1.title,
      'depends_on_task_id', d.depends_on_task_id, 'depends_on_title', t2.title,
      'depends_on_status', t2.status
    )), '[]'::jsonb)) INTO v_result
    FROM public.project_task_dependencies d
    JOIN public.project_tasks t1 ON t1.id = d.task_id
    JOIN public.project_tasks t2 ON t2.id = d.depends_on_task_id
    WHERE (p_task_id IS NULL OR d.task_id = p_task_id)
      AND (p_project_id IS NULL OR t1.project_id = p_project_id);
    RETURN v_result;
  END IF;

  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only admins/writers can manage dependencies';
  END IF;
  IF p_task_id IS NULL OR p_depends_on_task_id IS NULL THEN
    RAISE EXCEPTION 'task_id and depends_on_task_id are required';
  END IF;

  IF p_action = 'add' THEN
    SELECT * INTO v_a FROM public.project_tasks WHERE id = p_task_id;
    SELECT * INTO v_b FROM public.project_tasks WHERE id = p_depends_on_task_id;
    IF v_a.id IS NULL OR v_b.id IS NULL THEN RAISE EXCEPTION 'Task not found'; END IF;
    IF v_a.project_id <> v_b.project_id THEN
      RAISE EXCEPTION 'Dependencies must stay within one project';
    END IF;

    -- Cycle check: is p_task_id already (transitively) a prerequisite of p_depends_on_task_id?
    WITH RECURSIVE chain AS (
      SELECT depends_on_task_id FROM public.project_task_dependencies WHERE task_id = p_depends_on_task_id
      UNION
      SELECT d.depends_on_task_id
        FROM public.project_task_dependencies d
        JOIN chain c ON d.task_id = c.depends_on_task_id
    )
    SELECT EXISTS (SELECT 1 FROM chain WHERE depends_on_task_id = p_task_id) INTO v_cycle;
    IF v_cycle THEN
      RAISE EXCEPTION 'Dependency would create a cycle';
    END IF;

    INSERT INTO public.project_task_dependencies (task_id, depends_on_task_id)
    VALUES (p_task_id, p_depends_on_task_id)
    ON CONFLICT (task_id, depends_on_task_id) DO NOTHING;
    RETURN jsonb_build_object('success', true, 'task_id', p_task_id, 'depends_on_task_id', p_depends_on_task_id);

  ELSIF p_action = 'remove' THEN
    DELETE FROM public.project_task_dependencies
     WHERE task_id = p_task_id AND depends_on_task_id = p_depends_on_task_id;
    RETURN jsonb_build_object('success', true, 'removed', FOUND);
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use add|remove|list)', p_action;
END; $$;

-- Gantt-ready schedule: tasks + dependency edges + topological depth.
CREATE OR REPLACE FUNCTION public.get_project_schedule(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_tasks jsonb;
  v_deps jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can view the schedule';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.projects WHERE id = p_project_id) THEN
    RAISE EXCEPTION 'Project % not found', p_project_id;
  END IF;

  WITH RECURSIVE depth AS (
    SELECT t.id, 0 AS lvl
      FROM public.project_tasks t
     WHERE t.project_id = p_project_id
       AND NOT EXISTS (SELECT 1 FROM public.project_task_dependencies d WHERE d.task_id = t.id)
    UNION ALL
    SELECT d.task_id, depth.lvl + 1
      FROM public.project_task_dependencies d
      JOIN depth ON d.depends_on_task_id = depth.id
      JOIN public.project_tasks t2 ON t2.id = d.task_id AND t2.project_id = p_project_id
  ), maxdepth AS (
    SELECT id, max(lvl) AS lvl FROM depth GROUP BY id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', t.id,
    'title', t.title,
    'status', t.status,
    'priority', t.priority,
    'assigned_to', t.assigned_to,
    'parent_task_id', t.parent_task_id,
    'milestone_id', t.milestone_id,
    'start_date', COALESCE(t.start_date, t.created_at::date),
    'due_date', t.due_date,
    'estimated_hours', t.estimated_hours,
    'depth', COALESCE(md.lvl, 0),
    'depends_on', COALESCE((SELECT jsonb_agg(d.depends_on_task_id) FROM public.project_task_dependencies d WHERE d.task_id = t.id), '[]'::jsonb)
  ) ORDER BY COALESCE(md.lvl,0), COALESCE(t.start_date, t.created_at::date), t.sort_order), '[]'::jsonb)
  INTO v_tasks
  FROM public.project_tasks t
  LEFT JOIN maxdepth md ON md.id = t.id
  WHERE t.project_id = p_project_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('task_id', d.task_id, 'depends_on_task_id', d.depends_on_task_id)), '[]'::jsonb)
  INTO v_deps
  FROM public.project_task_dependencies d
  JOIN public.project_tasks t ON t.id = d.task_id
  WHERE t.project_id = p_project_id;

  RETURN jsonb_build_object(
    'success', true,
    'project_id', p_project_id,
    'tasks', v_tasks,
    'dependencies', v_deps,
    'milestones', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'due_date', m.due_date, 'is_reached', m.is_reached) ORDER BY m.due_date NULLS LAST)
      FROM public.project_milestones m WHERE m.project_id = p_project_id), '[]'::jsonb)
  );
END; $$;

-- ── 4. Team / stakeholder roles ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_project_member(
  p_action text,
  p_project_id uuid DEFAULT NULL,
  p_member_id uuid DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_role text DEFAULT NULL,
  p_hourly_rate_override_cents integer DEFAULT NULL,
  p_tracks_time boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.project_members;
  v_result jsonb;
BEGIN
  IF p_action = 'list' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view project members';
    END IF;
    SELECT jsonb_build_object('success', true, 'members', COALESCE(jsonb_agg(jsonb_build_object(
      'id', m.id, 'project_id', m.project_id, 'user_id', m.user_id, 'role', m.role,
      'hourly_rate_override_cents', m.hourly_rate_override_cents, 'tracks_time', m.tracks_time,
      'employee_name', e.name
    ) ORDER BY m.created_at), '[]'::jsonb)) INTO v_result
    FROM public.project_members m
    LEFT JOIN public.employees e ON e.user_id = m.user_id
    WHERE (p_project_id IS NULL OR m.project_id = p_project_id);
    RETURN v_result;
  END IF;

  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only admins/writers can manage project members';
  END IF;

  IF p_action = 'add' THEN
    IF p_project_id IS NULL OR p_user_id IS NULL OR p_role IS NULL THEN
      RAISE EXCEPTION 'project_id, user_id and role are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.projects WHERE id = p_project_id) THEN
      RAISE EXCEPTION 'Project % not found', p_project_id;
    END IF;
    IF EXISTS (SELECT 1 FROM public.project_members WHERE project_id = p_project_id AND user_id = p_user_id) THEN
      RAISE EXCEPTION 'User is already a member of this project (use update)';
    END IF;
    INSERT INTO public.project_members (project_id, user_id, role, hourly_rate_override_cents, tracks_time)
    VALUES (p_project_id, p_user_id, p_role, p_hourly_rate_override_cents, COALESCE(p_tracks_time, true))
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'member', to_jsonb(v_row));

  ELSIF p_action = 'update' THEN
    IF p_member_id IS NULL THEN RAISE EXCEPTION 'member_id is required'; END IF;
    UPDATE public.project_members
       SET role = COALESCE(p_role, role),
           hourly_rate_override_cents = COALESCE(p_hourly_rate_override_cents, hourly_rate_override_cents),
           tracks_time = COALESCE(p_tracks_time, tracks_time)
     WHERE id = p_member_id
    RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Member % not found', p_member_id; END IF;
    RETURN jsonb_build_object('success', true, 'member', to_jsonb(v_row));

  ELSIF p_action = 'remove' THEN
    DELETE FROM public.project_members
     WHERE id = p_member_id OR (p_member_id IS NULL AND project_id = p_project_id AND user_id = p_user_id);
    RETURN jsonb_build_object('success', true, 'removed', FOUND);
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use add|update|remove|list)', p_action;
END; $$;

-- ── 5. Cost forecasting / burn rate ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.project_cost_forecast(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_proj public.projects;
  v_hours_logged numeric := 0;
  v_cost_cents numeric := 0;
  v_recent_hours numeric := 0;
  v_burn numeric := 0;
  v_remaining numeric;
  v_weeks_left numeric;
  v_est_open numeric := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can view cost forecasts';
  END IF;
  SELECT * INTO v_proj FROM public.projects WHERE id = p_project_id;
  IF v_proj.id IS NULL THEN RAISE EXCEPTION 'Project % not found', p_project_id; END IF;

  -- Hours + cost (member rate overrides win over the project rate)
  SELECT
    COALESCE(sum(te.hours), 0),
    COALESCE(sum(te.hours * COALESCE(m.hourly_rate_override_cents, v_proj.hourly_rate_cents, 0)), 0)
  INTO v_hours_logged, v_cost_cents
  FROM public.time_entries te
  LEFT JOIN public.project_members m ON m.project_id = te.project_id AND m.user_id = te.user_id
  WHERE te.project_id = p_project_id;

  -- Burn rate: hours/week over the last 28 days
  SELECT COALESCE(sum(hours), 0) INTO v_recent_hours
    FROM public.time_entries
   WHERE project_id = p_project_id AND entry_date >= CURRENT_DATE - 28;
  v_burn := round(v_recent_hours / 4.0, 2);

  -- Open estimated work
  SELECT COALESCE(sum(estimated_hours), 0) INTO v_est_open
    FROM public.project_tasks
   WHERE project_id = p_project_id AND status::text <> 'done';

  v_remaining := CASE WHEN v_proj.budget_hours IS NOT NULL THEN v_proj.budget_hours - v_hours_logged END;
  v_weeks_left := CASE WHEN v_remaining IS NOT NULL AND v_burn > 0 THEN round(v_remaining / v_burn, 1) END;

  RETURN jsonb_build_object(
    'success', true,
    'project_id', p_project_id,
    'project_name', v_proj.name,
    'currency', COALESCE(v_proj.currency, 'SEK'),
    'hourly_rate_cents', v_proj.hourly_rate_cents,
    'budget_hours', v_proj.budget_hours,
    'hours_logged', v_hours_logged,
    'cost_cents', round(v_cost_cents),
    'budget_consumed_pct', CASE WHEN COALESCE(v_proj.budget_hours,0) > 0
      THEN round(v_hours_logged / v_proj.budget_hours * 100, 1) END,
    'burn_rate_hours_per_week', v_burn,
    'remaining_budget_hours', v_remaining,
    'weeks_until_budget_exhausted', v_weeks_left,
    'estimated_open_task_hours', v_est_open,
    'forecast_total_hours', v_hours_logged + v_est_open,
    'over_budget_risk', CASE
      WHEN v_proj.budget_hours IS NULL THEN NULL
      ELSE (v_hours_logged + v_est_open) > v_proj.budget_hours END,
    'deadline', v_proj.deadline,
    'deadline_at_current_burn', CASE WHEN v_weeks_left IS NOT NULL
      THEN (CURRENT_DATE + (v_weeks_left * 7)::int) END
  );
END; $$;

-- ── 6. Project templates ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_project_template(
  p_action text,
  p_template_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_spec jsonb DEFAULT NULL,
  p_client_name text DEFAULT NULL,
  p_start_date date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_tpl public.project_templates;
  v_proj public.projects;
  v_new_project_id uuid;
  v_base date;
  v_task jsonb;
  v_ms jsonb;
  v_task_count integer := 0;
  v_ms_count integer := 0;
  v_result jsonb;
BEGIN
  IF p_action IN ('list','get') THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view project templates';
    END IF;
  ELSE
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
      RAISE EXCEPTION 'Only admins/writers can manage project templates';
    END IF;
  END IF;

  IF p_action = 'create' THEN
    IF p_name IS NULL THEN RAISE EXCEPTION 'name is required'; END IF;
    INSERT INTO public.project_templates (name, description, spec, created_by)
    VALUES (p_name, p_description, COALESCE(p_spec, '{}'::jsonb), auth.uid())
    RETURNING * INTO v_tpl;
    RETURN jsonb_build_object('success', true, 'template', to_jsonb(v_tpl));

  ELSIF p_action = 'create_from_project' THEN
    IF p_project_id IS NULL THEN RAISE EXCEPTION 'project_id is required'; END IF;
    SELECT * INTO v_proj FROM public.projects WHERE id = p_project_id;
    IF v_proj.id IS NULL THEN RAISE EXCEPTION 'Project % not found', p_project_id; END IF;

    INSERT INTO public.project_templates (name, description, created_by, spec)
    VALUES (
      COALESCE(p_name, v_proj.name || ' (template)'),
      COALESCE(p_description, 'Snapshot of project ' || v_proj.name),
      auth.uid(),
      jsonb_build_object(
        'defaults', jsonb_build_object(
          'hourly_rate_cents', v_proj.hourly_rate_cents,
          'currency', v_proj.currency,
          'is_billable', v_proj.is_billable,
          'budget_hours', v_proj.budget_hours
        ),
        'tasks', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'title', t.title,
            'description', t.description,
            'priority', t.priority,
            'estimated_hours', t.estimated_hours,
            'offset_days', GREATEST(COALESCE(t.due_date - v_proj.created_at::date, 0), 0)
          ) ORDER BY t.sort_order, t.created_at)
          FROM public.project_tasks t
          WHERE t.project_id = p_project_id AND t.parent_task_id IS NULL
        ), '[]'::jsonb),
        'milestones', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'name', m.name,
            'description', m.description,
            'offset_days', GREATEST(COALESCE(m.due_date - v_proj.created_at::date, 0), 0)
          ) ORDER BY m.sort_order)
          FROM public.project_milestones m
          WHERE m.project_id = p_project_id
        ), '[]'::jsonb)
      )
    ) RETURNING * INTO v_tpl;
    RETURN jsonb_build_object('success', true, 'template', to_jsonb(v_tpl));

  ELSIF p_action = 'instantiate' THEN
    IF p_template_id IS NULL THEN RAISE EXCEPTION 'template_id is required'; END IF;
    SELECT * INTO v_tpl FROM public.project_templates WHERE id = p_template_id;
    IF v_tpl.id IS NULL THEN RAISE EXCEPTION 'Template % not found', p_template_id; END IF;
    v_base := COALESCE(p_start_date, CURRENT_DATE);

    INSERT INTO public.projects (name, client_name, description, hourly_rate_cents, currency, is_billable, budget_hours, is_active, status, created_by)
    VALUES (
      COALESCE(p_name, v_tpl.name),
      p_client_name,
      v_tpl.description,
      (v_tpl.spec->'defaults'->>'hourly_rate_cents')::integer,
      COALESCE(v_tpl.spec->'defaults'->>'currency', 'SEK'),
      COALESCE((v_tpl.spec->'defaults'->>'is_billable')::boolean, true),
      (v_tpl.spec->'defaults'->>'budget_hours')::numeric,
      true, 'active', auth.uid()
    ) RETURNING id INTO v_new_project_id;

    FOR v_task IN SELECT * FROM jsonb_array_elements(COALESCE(v_tpl.spec->'tasks','[]'::jsonb)) LOOP
      INSERT INTO public.project_tasks (project_id, title, description, priority, estimated_hours, due_date, status, sort_order)
      VALUES (
        v_new_project_id,
        v_task->>'title',
        v_task->>'description',
        COALESCE(v_task->>'priority','medium')::project_task_priority,
        (v_task->>'estimated_hours')::numeric,
        CASE WHEN v_task ? 'offset_days' THEN v_base + COALESCE((v_task->>'offset_days')::int,0) END,
        'todo', v_task_count
      );
      v_task_count := v_task_count + 1;
    END LOOP;

    FOR v_ms IN SELECT * FROM jsonb_array_elements(COALESCE(v_tpl.spec->'milestones','[]'::jsonb)) LOOP
      INSERT INTO public.project_milestones (project_id, name, description, due_date, sort_order, created_by)
      VALUES (
        v_new_project_id,
        v_ms->>'name',
        v_ms->>'description',
        CASE WHEN v_ms ? 'offset_days' THEN v_base + COALESCE((v_ms->>'offset_days')::int,0) END,
        v_ms_count, auth.uid()
      );
      v_ms_count := v_ms_count + 1;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'project_id', v_new_project_id,
      'tasks_created', v_task_count, 'milestones_created', v_ms_count);

  ELSIF p_action = 'list' THEN
    SELECT jsonb_build_object('success', true, 'templates', COALESCE(jsonb_agg(jsonb_build_object(
      'id', t.id, 'name', t.name, 'description', t.description,
      'task_count', jsonb_array_length(COALESCE(t.spec->'tasks','[]'::jsonb)),
      'milestone_count', jsonb_array_length(COALESCE(t.spec->'milestones','[]'::jsonb)),
      'created_at', t.created_at
    ) ORDER BY t.created_at DESC), '[]'::jsonb)) INTO v_result
    FROM public.project_templates t;
    RETURN v_result;

  ELSIF p_action = 'get' THEN
    IF p_template_id IS NULL THEN RAISE EXCEPTION 'template_id is required'; END IF;
    SELECT * INTO v_tpl FROM public.project_templates WHERE id = p_template_id;
    IF v_tpl.id IS NULL THEN RAISE EXCEPTION 'Template % not found', p_template_id; END IF;
    RETURN jsonb_build_object('success', true, 'template', to_jsonb(v_tpl));

  ELSIF p_action = 'delete' THEN
    IF p_template_id IS NULL THEN RAISE EXCEPTION 'template_id is required'; END IF;
    DELETE FROM public.project_templates WHERE id = p_template_id;
    RETURN jsonb_build_object('success', true, 'deleted', FOUND);
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use create|create_from_project|instantiate|list|get|delete)', p_action;
END; $$;

-- ── 7. Resource / capacity planning ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resource_capacity_report(
  p_project_id uuid DEFAULT NULL,
  p_weeks integer DEFAULT 4,
  p_capacity_hours_per_week numeric DEFAULT 40
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_result jsonb;
  v_since date := CURRENT_DATE - (GREATEST(COALESCE(p_weeks,4),1) * 7);
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can view capacity reports';
  END IF;

  WITH people AS (
    SELECT DISTINCT u AS user_id FROM (
      SELECT assigned_to AS u FROM public.project_tasks
        WHERE assigned_to IS NOT NULL AND status::text <> 'done'
          AND (p_project_id IS NULL OR project_id = p_project_id)
      UNION
      SELECT user_id FROM public.project_members
        WHERE user_id IS NOT NULL AND (p_project_id IS NULL OR project_id = p_project_id)
      UNION
      SELECT user_id FROM public.time_entries
        WHERE user_id IS NOT NULL AND entry_date >= v_since
          AND (p_project_id IS NULL OR project_id = p_project_id)
    ) x WHERE u IS NOT NULL
  ), stats AS (
    SELECT
      p.user_id,
      e.name AS employee_name,
      (SELECT count(*) FROM public.project_tasks t
        WHERE t.assigned_to = p.user_id AND t.status::text <> 'done'
          AND (p_project_id IS NULL OR t.project_id = p_project_id)) AS open_tasks,
      (SELECT COALESCE(sum(t.estimated_hours),0) FROM public.project_tasks t
        WHERE t.assigned_to = p.user_id AND t.status::text <> 'done'
          AND (p_project_id IS NULL OR t.project_id = p_project_id)) AS open_estimated_hours,
      (SELECT COALESCE(sum(te.hours),0) FROM public.time_entries te
        WHERE te.user_id = p.user_id AND te.entry_date >= v_since
          AND (p_project_id IS NULL OR te.project_id = p_project_id)) AS hours_logged
    FROM people p
    LEFT JOIN public.employees e ON e.user_id = p.user_id
  )
  SELECT jsonb_build_object(
    'success', true,
    'project_id', p_project_id,
    'window_weeks', GREATEST(COALESCE(p_weeks,4),1),
    'capacity_hours_per_week', p_capacity_hours_per_week,
    'resources', COALESCE(jsonb_agg(jsonb_build_object(
      'user_id', s.user_id,
      'name', COALESCE(s.employee_name, 'Unknown'),
      'open_tasks', s.open_tasks,
      'open_estimated_hours', s.open_estimated_hours,
      'hours_logged_in_window', s.hours_logged,
      'utilization_pct', round(s.hours_logged / (p_capacity_hours_per_week * GREATEST(COALESCE(p_weeks,4),1)) * 100, 1),
      'weeks_of_backlog', CASE WHEN p_capacity_hours_per_week > 0
        THEN round(s.open_estimated_hours / p_capacity_hours_per_week, 1) END,
      'overloaded', s.open_estimated_hours > p_capacity_hours_per_week * GREATEST(COALESCE(p_weeks,4),1)
    ) ORDER BY s.open_estimated_hours DESC), '[]'::jsonb)
  ) INTO v_result
  FROM stats s;

  RETURN v_result;
END; $$;
