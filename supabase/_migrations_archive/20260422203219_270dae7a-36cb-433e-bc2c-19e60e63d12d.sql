CREATE OR REPLACE FUNCTION public.hire_candidate_from_application(
  p_application_id UUID,
  p_start_date DATE DEFAULT NULL,
  p_employment_type TEXT DEFAULT 'full_time',
  p_department TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_app RECORD;
  v_job RECORD;
  v_employee_id UUID;
  v_checklist_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT * INTO v_app FROM public.applications WHERE id = p_application_id;
  IF v_app.id IS NULL THEN
    RAISE EXCEPTION 'Application not found';
  END IF;

  IF v_app.employee_id IS NOT NULL THEN
    RAISE EXCEPTION 'Application already hired (employee_id: %)', v_app.employee_id;
  END IF;

  SELECT * INTO v_job FROM public.job_postings WHERE id = v_app.job_posting_id;

  INSERT INTO public.employees (
    name, email, phone, title, department,
    employment_type, start_date, status
  )
  VALUES (
    COALESCE(v_app.candidate_name, 'New Hire'),
    v_app.candidate_email,
    v_app.candidate_phone,
    v_job.title,
    COALESCE(p_department, v_job.department),
    p_employment_type,
    COALESCE(p_start_date, CURRENT_DATE),
    'active'
  )
  RETURNING id INTO v_employee_id;

  UPDATE public.applications
  SET employee_id = v_employee_id,
      stage = 'hired',
      hired_at = now(),
      updated_at = now()
  WHERE id = p_application_id;

  INSERT INTO public.onboarding_checklists (employee_id, items)
  VALUES (
    v_employee_id,
    jsonb_build_array(
      jsonb_build_object('title', 'IT setup (laptop, accounts, email)', 'done', false),
      jsonb_build_object('title', 'Access cards & office tour', 'done', false),
      jsonb_build_object('title', 'Welcome meeting with team', 'done', false),
      jsonb_build_object('title', 'Sign employment contract', 'done', false),
      jsonb_build_object('title', 'Review company policies & handbook', 'done', false),
      jsonb_build_object('title', 'Assign onboarding buddy', 'done', false)
    )
  )
  RETURNING id INTO v_checklist_id;

  RETURN jsonb_build_object(
    'success', true,
    'employee_id', v_employee_id,
    'application_id', p_application_id,
    'checklist_id', v_checklist_id
  );
END;
$$;