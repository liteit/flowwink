-- Consultants (resume): parity round 5 (docs/parity/capabilities/resume.json)
-- Adds: consultant contract/SOW tracking + utilization/assignment tracking
-- (consultant_assignments + manage_consultant_assignment +
-- consultant_utilization_report) and a per-skill hourly-rate matrix
-- (consultant_skill_rates + manage_consultant_rates).
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. Schema ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.consultant_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consultant_id uuid NOT NULL REFERENCES public.consultant_profiles(id) ON DELETE CASCADE,
  client_name text NOT NULL,
  company_id uuid REFERENCES public.companies(id) ON DELETE SET NULL,
  project_id uuid,
  contract_id uuid REFERENCES public.contracts(id) ON DELETE SET NULL,
  role_title text,
  start_date date NOT NULL DEFAULT CURRENT_DATE,
  end_date date,
  allocation_pct integer NOT NULL DEFAULT 100 CHECK (allocation_pct BETWEEN 1 AND 100),
  hourly_rate_cents integer,
  currency text NOT NULL DEFAULT 'SEK',
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('planned','active','ended')),
  sow_url text,
  notes text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS consultant_assignments_consultant_idx
  ON public.consultant_assignments (consultant_id, status);

CREATE TABLE IF NOT EXISTS public.consultant_skill_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consultant_id uuid NOT NULL REFERENCES public.consultant_profiles(id) ON DELETE CASCADE,
  skill text NOT NULL,
  level text CHECK (level IS NULL OR level IN ('junior','mid','senior','expert')),
  hourly_rate_cents integer NOT NULL CHECK (hourly_rate_cents >= 0),
  currency text NOT NULL DEFAULT 'SEK',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (consultant_id, skill)
);

ALTER TABLE public.consultant_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.consultant_skill_rates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage consultant_assignments" ON public.consultant_assignments;
CREATE POLICY "Admins manage consultant_assignments" ON public.consultant_assignments
  FOR ALL USING (has_role(auth.uid(),'admin'::app_role)) WITH CHECK (has_role(auth.uid(),'admin'::app_role));
DROP POLICY IF EXISTS "Staff view consultant_assignments" ON public.consultant_assignments;
CREATE POLICY "Staff view consultant_assignments" ON public.consultant_assignments
  FOR SELECT USING (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'writer'::app_role) OR has_role(auth.uid(),'approver'::app_role));

DROP POLICY IF EXISTS "Admins manage consultant_skill_rates" ON public.consultant_skill_rates;
CREATE POLICY "Admins manage consultant_skill_rates" ON public.consultant_skill_rates
  FOR ALL USING (has_role(auth.uid(),'admin'::app_role)) WITH CHECK (has_role(auth.uid(),'admin'::app_role));
DROP POLICY IF EXISTS "Staff view consultant_skill_rates" ON public.consultant_skill_rates;
CREATE POLICY "Staff view consultant_skill_rates" ON public.consultant_skill_rates
  FOR SELECT USING (has_role(auth.uid(),'admin'::app_role) OR has_role(auth.uid(),'writer'::app_role) OR has_role(auth.uid(),'approver'::app_role));

-- ── 2. Assignments (utilization + contract/SOW tracking) ─────────────────────
CREATE OR REPLACE FUNCTION public.manage_consultant_assignment(
  p_action text,
  p_assignment_id uuid DEFAULT NULL,
  p_consultant_id uuid DEFAULT NULL,
  p_client_name text DEFAULT NULL,
  p_company_id uuid DEFAULT NULL,
  p_contract_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL,
  p_role_title text DEFAULT NULL,
  p_start_date date DEFAULT NULL,
  p_end_date date DEFAULT NULL,
  p_allocation_pct integer DEFAULT NULL,
  p_hourly_rate_cents integer DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_sow_url text DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
  v_rows jsonb;
  v_asg public.consultant_assignments%ROWTYPE;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only staff can manage consultant assignments';
  END IF;

  IF p_action = 'create' THEN
    IF p_consultant_id IS NULL OR p_client_name IS NULL THEN
      RAISE EXCEPTION 'consultant_id and client_name are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.consultant_profiles WHERE id = p_consultant_id) THEN
      RAISE EXCEPTION 'Consultant % not found', p_consultant_id;
    END IF;
    IF p_contract_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.contracts WHERE id = p_contract_id) THEN
      RAISE EXCEPTION 'Contract % not found', p_contract_id;
    END IF;
    INSERT INTO public.consultant_assignments
      (consultant_id, client_name, company_id, contract_id, project_id, role_title,
       start_date, end_date, allocation_pct, hourly_rate_cents, currency, status,
       sow_url, notes, created_by)
    VALUES
      (p_consultant_id, p_client_name, p_company_id, p_contract_id, p_project_id, p_role_title,
       COALESCE(p_start_date, CURRENT_DATE), p_end_date, COALESCE(p_allocation_pct, 100),
       COALESCE(p_hourly_rate_cents, (SELECT hourly_rate_cents FROM public.consultant_profiles WHERE id = p_consultant_id)),
       COALESCE(p_currency, 'SEK'), COALESCE(p_status, 'active'), p_sow_url, p_notes, auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('success', true, 'assignment_id', v_id);

  ELSIF p_action = 'update' THEN
    IF p_assignment_id IS NULL THEN RAISE EXCEPTION 'assignment_id is required'; END IF;
    IF p_contract_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.contracts WHERE id = p_contract_id) THEN
      RAISE EXCEPTION 'Contract % not found', p_contract_id;
    END IF;
    UPDATE public.consultant_assignments
       SET client_name = COALESCE(p_client_name, client_name),
           company_id = COALESCE(p_company_id, company_id),
           contract_id = COALESCE(p_contract_id, contract_id),
           project_id = COALESCE(p_project_id, project_id),
           role_title = COALESCE(p_role_title, role_title),
           start_date = COALESCE(p_start_date, start_date),
           end_date = COALESCE(p_end_date, end_date),
           allocation_pct = COALESCE(p_allocation_pct, allocation_pct),
           hourly_rate_cents = COALESCE(p_hourly_rate_cents, hourly_rate_cents),
           currency = COALESCE(p_currency, currency),
           status = COALESCE(p_status, status),
           sow_url = COALESCE(p_sow_url, sow_url),
           notes = COALESCE(p_notes, notes),
           updated_at = now()
     WHERE id = p_assignment_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Assignment % not found', p_assignment_id; END IF;
    RETURN jsonb_build_object('success', true, 'assignment_id', p_assignment_id);

  ELSIF p_action = 'end' THEN
    IF p_assignment_id IS NULL THEN RAISE EXCEPTION 'assignment_id is required'; END IF;
    UPDATE public.consultant_assignments
       SET status = 'ended', end_date = COALESCE(p_end_date, CURRENT_DATE), updated_at = now()
     WHERE id = p_assignment_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Assignment % not found', p_assignment_id; END IF;
    RETURN jsonb_build_object('success', true, 'assignment_id', p_assignment_id, 'status', 'ended');

  ELSIF p_action = 'get' THEN
    IF p_assignment_id IS NULL THEN RAISE EXCEPTION 'assignment_id is required'; END IF;
    SELECT * INTO v_asg FROM public.consultant_assignments WHERE id = p_assignment_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Assignment % not found', p_assignment_id; END IF;
    RETURN jsonb_build_object('success', true, 'assignment', to_jsonb(v_asg),
      'consultant_name', (SELECT name FROM public.consultant_profiles WHERE id = v_asg.consultant_id),
      'contract_title', (SELECT title FROM public.contracts WHERE id = v_asg.contract_id));

  ELSIF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', a.id, 'consultant_id', a.consultant_id,
        'consultant_name', cp.name,
        'client_name', a.client_name, 'role_title', a.role_title,
        'contract_id', a.contract_id,
        'contract_title', (SELECT title FROM public.contracts WHERE id = a.contract_id),
        'start_date', a.start_date, 'end_date', a.end_date,
        'allocation_pct', a.allocation_pct, 'hourly_rate_cents', a.hourly_rate_cents,
        'currency', a.currency, 'status', a.status, 'sow_url', a.sow_url
      ) ORDER BY a.start_date DESC), '[]'::jsonb)
    INTO v_rows
    FROM public.consultant_assignments a
    JOIN public.consultant_profiles cp ON cp.id = a.consultant_id
    WHERE (p_consultant_id IS NULL OR a.consultant_id = p_consultant_id)
      AND (p_status IS NULL OR a.status = p_status);
    RETURN jsonb_build_object('success', true, 'assignments', v_rows);

  ELSE
    RAISE EXCEPTION 'action must be create | update | end | get | list (got %)', p_action;
  END IF;
END;
$function$;

-- ── 3. Utilization report ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.consultant_utilization_report(
  p_from date DEFAULT date_trunc('month', CURRENT_DATE)::date,
  p_to date DEFAULT (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date,
  p_consultant_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_days numeric;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer') OR has_role(auth.uid(),'approver')) THEN
    RAISE EXCEPTION 'Only staff can view utilization reports';
  END IF;
  IF p_to < p_from THEN RAISE EXCEPTION 'to must be >= from'; END IF;
  v_days := (p_to - p_from + 1)::numeric;

  SELECT COALESCE(jsonb_agg(row_json ORDER BY (row_json->>'utilization_pct')::numeric DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'consultant_id', cp.id,
      'consultant_name', cp.name,
      'title', cp.title,
      'availability', cp.availability,
      'utilization_pct', COALESCE(u.util_pct, 0),
      'assignments', COALESCE(u.assignments, '[]'::jsonb)
    ) AS row_json
    FROM public.consultant_profiles cp
    LEFT JOIN LATERAL (
      SELECT
        round(SUM(
          a.allocation_pct
          * (LEAST(COALESCE(a.end_date, p_to), p_to) - GREATEST(a.start_date, p_from) + 1)
        ) / v_days, 1) AS util_pct,
        jsonb_agg(jsonb_build_object(
          'assignment_id', a.id, 'client_name', a.client_name,
          'allocation_pct', a.allocation_pct,
          'start_date', a.start_date, 'end_date', a.end_date, 'status', a.status
        )) AS assignments
      FROM public.consultant_assignments a
      WHERE a.consultant_id = cp.id
        AND a.status <> 'planned'
        AND a.start_date <= p_to
        AND COALESCE(a.end_date, p_to) >= p_from
    ) u ON true
    WHERE cp.is_active
      AND (p_consultant_id IS NULL OR cp.id = p_consultant_id)
  ) sub;

  RETURN jsonb_build_object('success', true,
    'from', p_from, 'to', p_to, 'window_days', v_days,
    'consultants', v_rows);
END;
$function$;

-- ── 4. Skill / hourly-rate matrix ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_consultant_rates(
  p_action text,
  p_consultant_id uuid DEFAULT NULL,
  p_skill text DEFAULT NULL,
  p_level text DEFAULT NULL,
  p_hourly_rate_cents integer DEFAULT NULL,
  p_currency text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_id uuid;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR has_role(auth.uid(),'writer')) THEN
    RAISE EXCEPTION 'Only staff can manage consultant rates';
  END IF;

  IF p_action = 'set' THEN
    IF p_consultant_id IS NULL OR p_skill IS NULL OR p_hourly_rate_cents IS NULL THEN
      RAISE EXCEPTION 'consultant_id, skill and hourly_rate_cents are required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.consultant_profiles WHERE id = p_consultant_id) THEN
      RAISE EXCEPTION 'Consultant % not found', p_consultant_id;
    END IF;
    INSERT INTO public.consultant_skill_rates (consultant_id, skill, level, hourly_rate_cents, currency)
    VALUES (p_consultant_id, p_skill, p_level, p_hourly_rate_cents, COALESCE(p_currency,'SEK'))
    ON CONFLICT (consultant_id, skill)
    DO UPDATE SET level = COALESCE(EXCLUDED.level, consultant_skill_rates.level),
                  hourly_rate_cents = EXCLUDED.hourly_rate_cents,
                  currency = EXCLUDED.currency,
                  updated_at = now()
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('success', true, 'rate_id', v_id,
      'consultant_id', p_consultant_id, 'skill', p_skill, 'hourly_rate_cents', p_hourly_rate_cents);

  ELSIF p_action = 'delete' THEN
    IF p_consultant_id IS NULL OR p_skill IS NULL THEN
      RAISE EXCEPTION 'consultant_id and skill are required';
    END IF;
    DELETE FROM public.consultant_skill_rates
     WHERE consultant_id = p_consultant_id AND skill = p_skill;
    IF NOT FOUND THEN RAISE EXCEPTION 'No rate for consultant % / skill %', p_consultant_id, p_skill; END IF;
    RETURN jsonb_build_object('success', true, 'deleted', p_skill);

  ELSIF p_action = 'list' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.skill), '[]'::jsonb) INTO v_rows
    FROM public.consultant_skill_rates r
    WHERE (p_consultant_id IS NULL OR r.consultant_id = p_consultant_id);
    RETURN jsonb_build_object('success', true, 'rates', v_rows);

  ELSIF p_action = 'matrix' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'consultant_id', cp.id,
        'consultant_name', cp.name,
        'default_hourly_rate_cents', cp.hourly_rate_cents,
        'currency', COALESCE(cp.currency, 'SEK'),
        'rates', COALESCE((
          SELECT jsonb_object_agg(r.skill, r.hourly_rate_cents)
          FROM public.consultant_skill_rates r WHERE r.consultant_id = cp.id
        ), '{}'::jsonb)
      ) ORDER BY cp.name), '[]'::jsonb)
    INTO v_rows
    FROM public.consultant_profiles cp
    WHERE cp.is_active;
    RETURN jsonb_build_object('success', true,
      'skills', (SELECT COALESCE(jsonb_agg(DISTINCT skill), '[]'::jsonb) FROM public.consultant_skill_rates),
      'matrix', v_rows);

  ELSE
    RAISE EXCEPTION 'action must be set | delete | list | matrix (got %)', p_action;
  END IF;
END;
$function$;
