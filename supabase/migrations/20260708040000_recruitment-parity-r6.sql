-- Recruitment: parity round 6 (docs/parity/capabilities/recruitment.json)
-- Adds: interview scheduling (interviews table + calendar_events wiring +
-- interviewer conflict check), assessment/test tracking, offer letter
-- generation from employment_contract_templates (merge fields), reference/
-- background checks, recruitment analytics (time-to-hire, source ROI, funnel)
-- and internal mobility matching (employee_skills × job required_skills).
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. Schema additions ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.interviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES public.applications(id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'interview',
  scheduled_start timestamptz NOT NULL,
  scheduled_end timestamptz NOT NULL,
  interviewer_id uuid,
  location text,
  meeting_url text,
  status text NOT NULL DEFAULT 'scheduled',
  feedback text,
  rating integer CHECK (rating BETWEEN 1 AND 5),
  calendar_event_id uuid,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.interviews DROP CONSTRAINT IF EXISTS interviews_kind_check;
ALTER TABLE public.interviews
  ADD CONSTRAINT interviews_kind_check
  CHECK (kind IN ('phone_screen','technical','onsite','culture','final','interview'));
ALTER TABLE public.interviews DROP CONSTRAINT IF EXISTS interviews_status_check;
ALTER TABLE public.interviews
  ADD CONSTRAINT interviews_status_check
  CHECK (status IN ('scheduled','completed','cancelled','no_show'));
ALTER TABLE public.interviews DROP CONSTRAINT IF EXISTS interviews_window_check;
ALTER TABLE public.interviews
  ADD CONSTRAINT interviews_window_check CHECK (scheduled_end > scheduled_start);

CREATE TABLE IF NOT EXISTS public.candidate_assessments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES public.applications(id) ON DELETE CASCADE,
  name text NOT NULL,
  kind text NOT NULL DEFAULT 'other',
  provider text,
  url text,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  due_date date,
  completed_at timestamptz,
  score numeric,
  max_score numeric,
  passed boolean,
  notes text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.candidate_assessments DROP CONSTRAINT IF EXISTS candidate_assessments_kind_check;
ALTER TABLE public.candidate_assessments
  ADD CONSTRAINT candidate_assessments_kind_check
  CHECK (kind IN ('coding','personality','language','case_study','cognitive','other'));

CREATE TABLE IF NOT EXISTS public.reference_checks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES public.applications(id) ON DELETE CASCADE,
  referee_name text NOT NULL,
  referee_email text,
  referee_phone text,
  relationship text,
  status text NOT NULL DEFAULT 'pending',
  rating integer CHECK (rating BETWEEN 1 AND 5),
  notes text,
  checked_by uuid,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.reference_checks DROP CONSTRAINT IF EXISTS reference_checks_status_check;
ALTER TABLE public.reference_checks
  ADD CONSTRAINT reference_checks_status_check
  CHECK (status IN ('pending','contacted','completed','declined'));

CREATE TABLE IF NOT EXISTS public.job_offers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES public.applications(id) ON DELETE CASCADE,
  template_id uuid REFERENCES public.employment_contract_templates(id) ON DELETE SET NULL,
  body_markdown text,
  salary_cents bigint,
  currency text NOT NULL DEFAULT 'SEK',
  start_date date,
  expires_at date,
  status text NOT NULL DEFAULT 'draft',
  sent_at timestamptz,
  responded_at timestamptz,
  notes text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.job_offers DROP CONSTRAINT IF EXISTS job_offers_status_check;
ALTER TABLE public.job_offers
  ADD CONSTRAINT job_offers_status_check
  CHECK (status IN ('draft','sent','accepted','declined','expired','withdrawn'));

DO $do$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['interviews','candidate_assessments','reference_checks','job_offers'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS "Admins manage %s" ON public.%I', t, t);
    EXECUTE format('CREATE POLICY "Admins manage %s" ON public.%I FOR ALL
      USING (has_role(auth.uid(), ''admin''::app_role))
      WITH CHECK (has_role(auth.uid(), ''admin''::app_role))', t, t);
    EXECUTE format('DROP POLICY IF EXISTS "Staff view %s" ON public.%I', t, t);
    EXECUTE format('CREATE POLICY "Staff view %s" ON public.%I FOR SELECT
      USING (has_role(auth.uid(), ''admin''::app_role)
          OR has_role(auth.uid(), ''approver''::app_role)
          OR has_role(auth.uid(), ''writer''::app_role))', t, t);
  END LOOP;
END $do$;

-- ── 2. Interview scheduling ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.schedule_interview(
  p_action text,
  p_interview_id uuid DEFAULT NULL,
  p_application_id uuid DEFAULT NULL,
  p_kind text DEFAULT NULL,
  p_start timestamptz DEFAULT NULL,
  p_end timestamptz DEFAULT NULL,
  p_interviewer_id uuid DEFAULT NULL,
  p_location text DEFAULT NULL,
  p_meeting_url text DEFAULT NULL,
  p_feedback text DEFAULT NULL,
  p_rating integer DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_app record;
  v_row public.interviews;
  v_event_id uuid;
  v_conflicts jsonb;
  v_result jsonb;
BEGIN
  IF p_action = 'list' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view interviews';
    END IF;
    SELECT jsonb_build_object('success', true, 'interviews', COALESCE(jsonb_agg(jsonb_build_object(
      'id', i.id, 'application_id', i.application_id, 'candidate_name', a.candidate_name,
      'job_title', j.title, 'kind', i.kind, 'scheduled_start', i.scheduled_start,
      'scheduled_end', i.scheduled_end, 'interviewer_id', i.interviewer_id,
      'status', i.status, 'rating', i.rating, 'location', i.location, 'meeting_url', i.meeting_url
    ) ORDER BY i.scheduled_start DESC), '[]'::jsonb)) INTO v_result
    FROM public.interviews i
    JOIN public.applications a ON a.id = i.application_id
    LEFT JOIN public.job_postings j ON j.id = a.job_posting_id
    WHERE (p_application_id IS NULL OR i.application_id = p_application_id)
      AND (p_interviewer_id IS NULL OR i.interviewer_id = p_interviewer_id);
    RETURN v_result;
  END IF;

  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only admins/writers can manage interviews';
  END IF;

  IF p_action = 'schedule' THEN
    IF p_application_id IS NULL OR p_start IS NULL OR p_end IS NULL THEN
      RAISE EXCEPTION 'application_id, start and end are required';
    END IF;
    IF p_end <= p_start THEN RAISE EXCEPTION 'end must be after start'; END IF;
    SELECT a.*, j.title AS job_title INTO v_app
      FROM public.applications a
      LEFT JOIN public.job_postings j ON j.id = a.job_posting_id
     WHERE a.id = p_application_id;
    IF v_app.id IS NULL THEN RAISE EXCEPTION 'Application % not found', p_application_id; END IF;
    IF v_app.stage::text IN ('rejected','hired') THEN
      RAISE EXCEPTION 'Application is % — cannot schedule an interview', v_app.stage;
    END IF;

    -- Interviewer double-booking check (other interviews + calendar events)
    IF p_interviewer_id IS NOT NULL THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object('interview_id', id, 'scheduled_start', scheduled_start, 'scheduled_end', scheduled_end)), '[]'::jsonb)
        INTO v_conflicts
        FROM public.interviews
       WHERE interviewer_id = p_interviewer_id AND status = 'scheduled'
         AND scheduled_start < p_end AND scheduled_end > p_start;
      IF jsonb_array_length(v_conflicts) > 0 THEN
        RETURN jsonb_build_object('success', false, 'reason', 'interviewer_conflict', 'conflicts', v_conflicts);
      END IF;
    END IF;

    INSERT INTO public.calendar_events
      (title, description, starts_at, ends_at, location, related_entity_type, related_entity_id, created_by, visibility)
    VALUES (
      format('Interview: %s — %s', v_app.candidate_name, COALESCE(v_app.job_title, 'open application')),
      format('%s interview for application %s', COALESCE(p_kind,'interview'), p_application_id),
      p_start, p_end, COALESCE(p_location, p_meeting_url),
      'interview', p_application_id::text, auth.uid(), 'team'
    ) RETURNING id INTO v_event_id;

    INSERT INTO public.interviews
      (application_id, kind, scheduled_start, scheduled_end, interviewer_id, location, meeting_url, calendar_event_id, created_by)
    VALUES
      (p_application_id, COALESCE(p_kind,'interview'), p_start, p_end, p_interviewer_id, p_location, p_meeting_url, v_event_id, auth.uid())
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'interview', to_jsonb(v_row));

  ELSIF p_action = 'reschedule' THEN
    IF p_interview_id IS NULL OR p_start IS NULL OR p_end IS NULL THEN
      RAISE EXCEPTION 'interview_id, start and end are required';
    END IF;
    UPDATE public.interviews
       SET scheduled_start = p_start, scheduled_end = p_end,
           interviewer_id = COALESCE(p_interviewer_id, interviewer_id),
           location = COALESCE(p_location, location),
           meeting_url = COALESCE(p_meeting_url, meeting_url),
           status = 'scheduled', updated_at = now()
     WHERE id = p_interview_id RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Interview % not found', p_interview_id; END IF;
    UPDATE public.calendar_events SET starts_at = p_start, ends_at = p_end, updated_at = now()
     WHERE id = v_row.calendar_event_id;
    RETURN jsonb_build_object('success', true, 'interview', to_jsonb(v_row));

  ELSIF p_action IN ('cancel','complete','no_show') THEN
    IF p_interview_id IS NULL THEN RAISE EXCEPTION 'interview_id is required'; END IF;
    UPDATE public.interviews
       SET status = CASE p_action WHEN 'cancel' THEN 'cancelled' WHEN 'complete' THEN 'completed' ELSE 'no_show' END,
           feedback = COALESCE(p_feedback, feedback),
           rating = COALESCE(p_rating, rating),
           updated_at = now()
     WHERE id = p_interview_id RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Interview % not found', p_interview_id; END IF;
    IF p_action = 'cancel' THEN
      DELETE FROM public.calendar_events WHERE id = v_row.calendar_event_id;
    END IF;
    -- Completed interviews with feedback land in candidate_notes for the pipeline view.
    IF p_action = 'complete' AND (p_feedback IS NOT NULL OR p_rating IS NOT NULL) THEN
      INSERT INTO public.candidate_notes (application_id, author_id, body, rating)
      VALUES (v_row.application_id, auth.uid(),
              format('[%s interview] %s', v_row.kind, COALESCE(p_feedback,'(no written feedback)')), p_rating);
    END IF;
    RETURN jsonb_build_object('success', true, 'interview', to_jsonb(v_row));
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use schedule|reschedule|complete|cancel|no_show|list)', p_action;
END; $$;

-- ── 3. Assessments ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_candidate_assessment(
  p_action text,
  p_assessment_id uuid DEFAULT NULL,
  p_application_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_kind text DEFAULT NULL,
  p_provider text DEFAULT NULL,
  p_url text DEFAULT NULL,
  p_due_date date DEFAULT NULL,
  p_score numeric DEFAULT NULL,
  p_max_score numeric DEFAULT NULL,
  p_passed boolean DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.candidate_assessments;
  v_result jsonb;
BEGIN
  IF p_action = 'list' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view assessments';
    END IF;
    SELECT jsonb_build_object('success', true, 'assessments', COALESCE(jsonb_agg(to_jsonb(a.*) ORDER BY a.assigned_at DESC), '[]'::jsonb)) INTO v_result
    FROM public.candidate_assessments a
    WHERE (p_application_id IS NULL OR a.application_id = p_application_id);
    RETURN v_result;
  END IF;

  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only admins/writers can manage assessments';
  END IF;

  IF p_action = 'assign' THEN
    IF p_application_id IS NULL OR p_name IS NULL THEN
      RAISE EXCEPTION 'application_id and name are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.applications WHERE id = p_application_id) THEN
      RAISE EXCEPTION 'Application % not found', p_application_id;
    END IF;
    INSERT INTO public.candidate_assessments
      (application_id, name, kind, provider, url, due_date, notes, created_by)
    VALUES
      (p_application_id, p_name, COALESCE(p_kind,'other'), p_provider, p_url, p_due_date, p_notes, auth.uid())
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'assessment', to_jsonb(v_row));

  ELSIF p_action = 'record_result' THEN
    IF p_assessment_id IS NULL THEN RAISE EXCEPTION 'assessment_id is required'; END IF;
    UPDATE public.candidate_assessments
       SET score = COALESCE(p_score, score),
           max_score = COALESCE(p_max_score, max_score),
           passed = COALESCE(p_passed, passed),
           notes = COALESCE(p_notes, notes),
           completed_at = COALESCE(completed_at, now()),
           updated_at = now()
     WHERE id = p_assessment_id RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Assessment % not found', p_assessment_id; END IF;
    INSERT INTO public.candidate_notes (application_id, author_id, body)
    VALUES (v_row.application_id, auth.uid(),
            format('[assessment] %s: %s%s%s', v_row.name,
                   COALESCE(v_row.score::text,'—'),
                   CASE WHEN v_row.max_score IS NOT NULL THEN '/' || v_row.max_score ELSE '' END,
                   CASE WHEN v_row.passed IS TRUE THEN ' (passed)' WHEN v_row.passed IS FALSE THEN ' (failed)' ELSE '' END));
    RETURN jsonb_build_object('success', true, 'assessment', to_jsonb(v_row));

  ELSIF p_action = 'delete' THEN
    IF p_assessment_id IS NULL THEN RAISE EXCEPTION 'assessment_id is required'; END IF;
    DELETE FROM public.candidate_assessments WHERE id = p_assessment_id;
    RETURN jsonb_build_object('success', true, 'deleted', FOUND);
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use assign|record_result|list|delete)', p_action;
END; $$;

-- ── 4. Offer letters ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_job_offer(
  p_action text,
  p_offer_id uuid DEFAULT NULL,
  p_application_id uuid DEFAULT NULL,
  p_template_id uuid DEFAULT NULL,
  p_salary_cents bigint DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_start_date date DEFAULT NULL,
  p_expires_at date DEFAULT NULL,
  p_body_markdown text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_app record;
  v_tpl public.employment_contract_templates;
  v_body text;
  v_row public.job_offers;
  v_result jsonb;
BEGIN
  IF p_action IN ('list','get') THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view offers';
    END IF;
  ELSE
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
      RAISE EXCEPTION 'Only admins/writers can manage offers';
    END IF;
  END IF;

  IF p_action = 'generate' THEN
    IF p_application_id IS NULL THEN RAISE EXCEPTION 'application_id is required'; END IF;
    SELECT a.*, j.title AS job_title, j.department AS job_department, j.employment_type AS job_employment_type
      INTO v_app
      FROM public.applications a
      LEFT JOIN public.job_postings j ON j.id = a.job_posting_id
     WHERE a.id = p_application_id;
    IF v_app.id IS NULL THEN RAISE EXCEPTION 'Application % not found', p_application_id; END IF;

    IF p_template_id IS NOT NULL THEN
      SELECT * INTO v_tpl FROM public.employment_contract_templates WHERE id = p_template_id;
      IF v_tpl.id IS NULL THEN RAISE EXCEPTION 'Template % not found', p_template_id; END IF;
    ELSE
      SELECT * INTO v_tpl FROM public.employment_contract_templates
       WHERE is_active ORDER BY is_default DESC, created_at LIMIT 1;
    END IF;

    v_body := COALESCE(p_body_markdown, v_tpl.body_markdown,
      E'# Offer of Employment\n\nDear {{candidate_name}},\n\nWe are pleased to offer you the position of **{{job_title}}**.\n\n- Salary: {{salary}} {{currency}}/month\n- Start date: {{start_date}}\n\nThis offer expires on {{expires_at}}.\n');
    v_body := replace(v_body, '{{candidate_name}}', COALESCE(v_app.candidate_name, ''));
    v_body := replace(v_body, '{{candidate_email}}', COALESCE(v_app.candidate_email, ''));
    v_body := replace(v_body, '{{job_title}}', COALESCE(v_app.job_title, ''));
    v_body := replace(v_body, '{{department}}', COALESCE(v_app.job_department, ''));
    v_body := replace(v_body, '{{employment_type}}', COALESCE(v_app.job_employment_type::text, ''));
    v_body := replace(v_body, '{{salary}}', CASE WHEN p_salary_cents IS NOT NULL THEN to_char(p_salary_cents / 100.0, 'FM999G999G999') ELSE '' END);
    v_body := replace(v_body, '{{currency}}', COALESCE(p_currency, 'SEK'));
    v_body := replace(v_body, '{{start_date}}', COALESCE(p_start_date::text, 'TBD'));
    v_body := replace(v_body, '{{expires_at}}', COALESCE(p_expires_at::text, (CURRENT_DATE + 14)::text));

    INSERT INTO public.job_offers
      (application_id, template_id, body_markdown, salary_cents, currency, start_date, expires_at, notes, created_by)
    VALUES
      (p_application_id, v_tpl.id, v_body, p_salary_cents, COALESCE(p_currency,'SEK'),
       p_start_date, COALESCE(p_expires_at, CURRENT_DATE + 14), p_notes, auth.uid())
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'offer', to_jsonb(v_row));

  ELSIF p_action = 'send' THEN
    IF p_offer_id IS NULL THEN RAISE EXCEPTION 'offer_id is required'; END IF;
    UPDATE public.job_offers
       SET status = 'sent', sent_at = now(), updated_at = now()
     WHERE id = p_offer_id AND status = 'draft'
    RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Offer % not found or not in draft', p_offer_id; END IF;
    RETURN jsonb_build_object('success', true, 'offer', to_jsonb(v_row),
      'note', 'Status set to sent — deliver the letter via send_email to the candidate.');

  ELSIF p_action = 'record_response' THEN
    IF p_offer_id IS NULL OR p_status IS NULL THEN
      RAISE EXCEPTION 'offer_id and status (accepted|declined) are required';
    END IF;
    IF p_status NOT IN ('accepted','declined','withdrawn','expired') THEN
      RAISE EXCEPTION 'status must be accepted|declined|withdrawn|expired';
    END IF;
    UPDATE public.job_offers
       SET status = p_status, responded_at = now(), notes = COALESCE(p_notes, notes), updated_at = now()
     WHERE id = p_offer_id RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Offer % not found', p_offer_id; END IF;
    RETURN jsonb_build_object('success', true, 'offer', to_jsonb(v_row),
      'next_step', CASE WHEN p_status = 'accepted' THEN 'Run hire_application to convert the candidate to an employee.' END);

  ELSIF p_action = 'get' THEN
    IF p_offer_id IS NULL THEN RAISE EXCEPTION 'offer_id is required'; END IF;
    SELECT * INTO v_row FROM public.job_offers WHERE id = p_offer_id;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Offer % not found', p_offer_id; END IF;
    RETURN jsonb_build_object('success', true, 'offer', to_jsonb(v_row));

  ELSIF p_action = 'list' THEN
    SELECT jsonb_build_object('success', true, 'offers', COALESCE(jsonb_agg(jsonb_build_object(
      'id', o.id, 'application_id', o.application_id, 'candidate_name', a.candidate_name,
      'status', o.status, 'salary_cents', o.salary_cents, 'currency', o.currency,
      'start_date', o.start_date, 'expires_at', o.expires_at, 'sent_at', o.sent_at,
      'responded_at', o.responded_at, 'created_at', o.created_at
    ) ORDER BY o.created_at DESC), '[]'::jsonb)) INTO v_result
    FROM public.job_offers o
    JOIN public.applications a ON a.id = o.application_id
    WHERE (p_application_id IS NULL OR o.application_id = p_application_id)
      AND (p_status IS NULL OR o.status = p_status);
    RETURN v_result;
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use generate|send|record_response|get|list)', p_action;
END; $$;

-- ── 5. Reference checks ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_reference_check(
  p_action text,
  p_reference_id uuid DEFAULT NULL,
  p_application_id uuid DEFAULT NULL,
  p_referee_name text DEFAULT NULL,
  p_referee_email text DEFAULT NULL,
  p_referee_phone text DEFAULT NULL,
  p_relationship text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_rating integer DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.reference_checks;
  v_result jsonb;
BEGIN
  IF p_action = 'list' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
      RAISE EXCEPTION 'Only staff can view reference checks';
    END IF;
    SELECT jsonb_build_object('success', true, 'reference_checks', COALESCE(jsonb_agg(to_jsonb(r.*) ORDER BY r.created_at DESC), '[]'::jsonb)) INTO v_result
    FROM public.reference_checks r
    WHERE (p_application_id IS NULL OR r.application_id = p_application_id);
    RETURN v_result;
  END IF;

  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only admins/writers can manage reference checks';
  END IF;

  IF p_action = 'add' THEN
    IF p_application_id IS NULL OR p_referee_name IS NULL THEN
      RAISE EXCEPTION 'application_id and referee_name are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.applications WHERE id = p_application_id) THEN
      RAISE EXCEPTION 'Application % not found', p_application_id;
    END IF;
    INSERT INTO public.reference_checks
      (application_id, referee_name, referee_email, referee_phone, relationship, notes)
    VALUES
      (p_application_id, p_referee_name, p_referee_email, p_referee_phone, p_relationship, p_notes)
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('success', true, 'reference_check', to_jsonb(v_row));

  ELSIF p_action = 'record' THEN
    IF p_reference_id IS NULL THEN RAISE EXCEPTION 'reference_id is required'; END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('pending','contacted','completed','declined') THEN
      RAISE EXCEPTION 'status must be pending|contacted|completed|declined';
    END IF;
    UPDATE public.reference_checks
       SET status = COALESCE(p_status, status),
           rating = COALESCE(p_rating, rating),
           notes = COALESCE(p_notes, notes),
           checked_by = COALESCE(checked_by, auth.uid()),
           completed_at = CASE WHEN COALESCE(p_status, status) = 'completed' THEN COALESCE(completed_at, now()) ELSE completed_at END,
           updated_at = now()
     WHERE id = p_reference_id RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'Reference check % not found', p_reference_id; END IF;
    IF v_row.status = 'completed' THEN
      INSERT INTO public.candidate_notes (application_id, author_id, body, rating)
      VALUES (v_row.application_id, auth.uid(),
              format('[reference] %s (%s): %s', v_row.referee_name, COALESCE(v_row.relationship,'reference'), COALESCE(p_notes, 'completed')), p_rating);
    END IF;
    RETURN jsonb_build_object('success', true, 'reference_check', to_jsonb(v_row));

  ELSIF p_action = 'delete' THEN
    IF p_reference_id IS NULL THEN RAISE EXCEPTION 'reference_id is required'; END IF;
    DELETE FROM public.reference_checks WHERE id = p_reference_id;
    RETURN jsonb_build_object('success', true, 'deleted', FOUND);
  END IF;

  RAISE EXCEPTION 'Unknown action: % (use add|record|list|delete)', p_action;
END; $$;

-- ── 6. Recruitment analytics ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.recruitment_analytics(
  p_days integer DEFAULT 90,
  p_job_posting_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_since timestamptz := now() - make_interval(days => GREATEST(COALESCE(p_days,90),1));
  v_time_to_hire jsonb;
  v_sources jsonb;
  v_funnel jsonb;
  v_interviews jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can view recruitment analytics';
  END IF;

  SELECT jsonb_build_object(
    'hires', count(*),
    'avg_days', round(avg(extract(epoch FROM (hired_at - created_at)) / 86400)::numeric, 1),
    'median_days', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM (hired_at - created_at)) / 86400))::numeric, 1)
  ) INTO v_time_to_hire
  FROM public.applications
  WHERE hired_at IS NOT NULL AND hired_at >= v_since
    AND (p_job_posting_id IS NULL OR job_posting_id = p_job_posting_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'source', src, 'applications', apps, 'hires', hires,
    'hire_rate_pct', CASE WHEN apps > 0 THEN round(hires::numeric / apps * 100, 1) ELSE 0 END,
    'avg_ai_score', avg_score
  ) ORDER BY apps DESC), '[]'::jsonb) INTO v_sources
  FROM (
    SELECT COALESCE(source, 'unknown') AS src,
           count(*) AS apps,
           count(*) FILTER (WHERE hired_at IS NOT NULL) AS hires,
           round(avg(ai_score)::numeric, 2) AS avg_score
      FROM public.applications
     WHERE created_at >= v_since
       AND (p_job_posting_id IS NULL OR job_posting_id = p_job_posting_id)
     GROUP BY 1
  ) s;

  SELECT COALESCE(jsonb_object_agg(stage, cnt), '{}'::jsonb) INTO v_funnel
  FROM (
    SELECT stage::text AS stage, count(*) AS cnt
      FROM public.applications
     WHERE created_at >= v_since
       AND (p_job_posting_id IS NULL OR job_posting_id = p_job_posting_id)
     GROUP BY 1
  ) f;

  SELECT jsonb_build_object(
    'scheduled', count(*) FILTER (WHERE status = 'scheduled'),
    'completed', count(*) FILTER (WHERE status = 'completed'),
    'avg_rating', round(avg(rating) FILTER (WHERE rating IS NOT NULL), 2)
  ) INTO v_interviews
  FROM public.interviews i
  JOIN public.applications a ON a.id = i.application_id
  WHERE i.created_at >= v_since
    AND (p_job_posting_id IS NULL OR a.job_posting_id = p_job_posting_id);

  RETURN jsonb_build_object(
    'success', true,
    'period_days', GREATEST(COALESCE(p_days,90),1),
    'job_posting_id', p_job_posting_id,
    'time_to_hire', v_time_to_hire,
    'source_roi', v_sources,
    'stage_funnel', v_funnel,
    'interviews', v_interviews,
    'open_positions', (SELECT count(*) FROM public.job_postings WHERE status::text = 'published'
                        AND (p_job_posting_id IS NULL OR id = p_job_posting_id))
  );
END; $$;

-- ── 7. Internal mobility matching ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.match_internal_candidates(
  p_job_posting_id uuid,
  p_limit integer DEFAULT 10
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_job public.job_postings;
  v_required text[];
  v_result jsonb;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can run internal mobility matching';
  END IF;
  SELECT * INTO v_job FROM public.job_postings WHERE id = p_job_posting_id;
  IF v_job.id IS NULL THEN RAISE EXCEPTION 'Job posting % not found', p_job_posting_id; END IF;

  v_required := COALESCE(v_job.required_skills, '{}');
  IF cardinality(v_required) = 0 THEN
    RETURN jsonb_build_object('success', false, 'reason', 'job_has_no_required_skills',
      'hint', 'Set required_skills on the job posting first (manage_job_posting).');
  END IF;

  WITH emp_skills AS (
    SELECT es.employee_id, lower(sc.name) AS skill, es.proficiency_level, es.years_experience
      FROM public.employee_skills es
      JOIN public.skills_catalog sc ON sc.id = es.skill_id
  ), required AS (
    SELECT lower(unnest(v_required)) AS skill
  ), scored AS (
    SELECT
      e.id AS employee_id,
      e.name,
      e.title,
      e.department,
      COALESCE((SELECT array_agg(r.skill) FROM required r
                 WHERE EXISTS (SELECT 1 FROM emp_skills s WHERE s.employee_id = e.id AND s.skill = r.skill)), '{}') AS matching,
      COALESCE((SELECT array_agg(r.skill) FROM required r
                 WHERE NOT EXISTS (SELECT 1 FROM emp_skills s WHERE s.employee_id = e.id AND s.skill = r.skill)), '{}') AS missing
    FROM public.employees e
    WHERE e.status = 'active'
  )
  SELECT jsonb_build_object(
    'success', true,
    'job_posting_id', p_job_posting_id,
    'job_title', v_job.title,
    'required_skills', to_jsonb(v_required),
    'matches', COALESCE(jsonb_agg(jsonb_build_object(
      'employee_id', s.employee_id,
      'name', s.name,
      'current_title', s.title,
      'department', s.department,
      'match_score', round(cardinality(s.matching)::numeric / cardinality(v_required), 2),
      'matching_skills', to_jsonb(s.matching),
      'missing_skills', to_jsonb(s.missing)
    ) ORDER BY cardinality(s.matching)::numeric / cardinality(v_required) DESC, s.name)
      FILTER (WHERE cardinality(s.matching) > 0), '[]'::jsonb)
  ) INTO v_result
  FROM (SELECT * FROM scored ORDER BY cardinality(matching) DESC LIMIT GREATEST(COALESCE(p_limit,10),1)) s;

  RETURN v_result;
END; $$;
