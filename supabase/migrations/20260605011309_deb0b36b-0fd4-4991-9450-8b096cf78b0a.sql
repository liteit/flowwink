
CREATE OR REPLACE FUNCTION public.seed_demo_projects(p_run_id uuid, p_scenario text DEFAULT 'default')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_project_id uuid;
  v_task_id uuid;
  v_projects_created int := 0;
  v_tasks_created int := 0;
  v_members_added int := 0;
  v_suffix text := substring(p_run_id::text, 1, 6);
  v_member_ids uuid[];
  v_member_count int;
  prec record;
  trec record;
  v_idx int;
  v_assignee uuid;
BEGIN
  -- Pick up to 3 employees that have a real auth user_id (skip demo-only employees)
  SELECT COALESCE(array_agg(user_id), ARRAY[]::uuid[])
    INTO v_member_ids
  FROM (
    SELECT user_id FROM public.employees
    WHERE user_id IS NOT NULL AND status = 'active'
    ORDER BY created_at ASC
    LIMIT 3
  ) e;
  v_member_count := array_length(v_member_ids, 1);

  FOR prec IN
    SELECT * FROM (VALUES
      ('Demo: Website Relaunch ('||v_suffix||')',        'Acme Retail AB',     '#6366f1', 160000, 40, (current_date + 120)::date),
      ('Demo: ERP Integration ('||v_suffix||')',         'Sundsvall Tech',     '#10b981', 200000, 60, (current_date + 165)::date),
      ('Demo: Q3 Reporting Automation ('||v_suffix||')', 'Malmö Finans Group', '#f59e0b', 220000, 30, (current_date + 90)::date)
    ) AS t(p_name, p_client, p_color, p_rate, p_budget, p_deadline)
  LOOP
    INSERT INTO public.projects (name, client_name, description, color, hourly_rate_cents, currency, is_billable, is_active, budget_hours, deadline)
    VALUES (prec.p_name, prec.p_client, 'Demo project seeded for the FlowWink showcase.', prec.p_color, prec.p_rate, 'SEK', true, true, prec.p_budget, prec.p_deadline)
    RETURNING id INTO v_project_id;

    PERFORM public._demo_register_row(p_run_id, 'projects', v_project_id);
    v_projects_created := v_projects_created + 1;

    -- Add team members (cascade-cleaned on project delete)
    IF v_member_count IS NOT NULL AND v_member_count > 0 THEN
      FOR v_idx IN 1..v_member_count LOOP
        INSERT INTO public.project_members (project_id, user_id, role, tracks_time)
        VALUES (v_project_id, v_member_ids[v_idx],
                CASE WHEN v_idx = 1 THEN 'lead' ELSE 'member' END, true)
        ON CONFLICT (project_id, user_id) DO NOTHING;
        v_members_added := v_members_added + 1;
      END LOOP;
    END IF;

    v_idx := 0;
    FOR trec IN
      SELECT * FROM (VALUES
        ('Kickoff workshop',            'done',         'medium', 0),
        ('Discovery & requirements',    'done',         'high',   1),
        ('Design system & wireframes',  'in_progress',  'high',   2),
        ('Backend integration',         'todo',         'high',   3),
        ('QA & launch checklist',       'todo',         'medium', 4)
      ) AS t(p_title, p_status, p_priority, p_sort)
    LOOP
      v_assignee := NULL;
      IF v_member_count IS NOT NULL AND v_member_count > 0 THEN
        v_assignee := v_member_ids[(v_idx % v_member_count) + 1];
      END IF;

      INSERT INTO public.project_tasks (project_id, title, status, priority, sort_order, completed_at, estimated_hours, assigned_to)
      VALUES (
        v_project_id,
        trec.p_title,
        trec.p_status::project_task_status,
        trec.p_priority::project_task_priority,
        trec.p_sort,
        CASE WHEN trec.p_status = 'done' THEN now() - ((5 - trec.p_sort) || ' days')::interval ELSE NULL END,
        4 + trec.p_sort,
        v_assignee
      )
      RETURNING id INTO v_task_id;

      PERFORM public._demo_register_row(p_run_id, 'project_tasks', v_task_id);
      v_tasks_created := v_tasks_created + 1;
      v_idx := v_idx + 1;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'projects_created', v_projects_created,
    'tasks_created', v_tasks_created,
    'members_added', v_members_added,
    'team_size', COALESCE(v_member_count, 0)
  );
END $$;
