-- Leave allocations: per employee, year, leave_type → total days granted
CREATE TABLE IF NOT EXISTS public.leave_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  leave_type TEXT NOT NULL,
  year INTEGER NOT NULL,
  allocated_days NUMERIC(6,2) NOT NULL DEFAULT 0,
  carried_over_days NUMERIC(6,2) NOT NULL DEFAULT 0,
  notes TEXT,
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (employee_id, leave_type, year)
);

CREATE INDEX IF NOT EXISTS idx_leave_allocations_employee ON public.leave_allocations(employee_id);
CREATE INDEX IF NOT EXISTS idx_leave_allocations_year ON public.leave_allocations(year);

ALTER TABLE public.leave_allocations ENABLE ROW LEVEL SECURITY;

-- Admins can manage everything
DROP POLICY IF EXISTS "Admins manage allocations" ON public.leave_allocations;
CREATE POLICY "Admins manage allocations"
ON public.leave_allocations
FOR ALL
USING (public.has_role(auth.uid(), 'admin'))
WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- Employees can read their own allocation
DROP POLICY IF EXISTS "Employees read own allocations" ON public.leave_allocations;
CREATE POLICY "Employees read own allocations"
ON public.leave_allocations
FOR SELECT
USING (employee_id = public.current_employee_id());

-- Updated-at trigger
DROP TRIGGER IF EXISTS leave_allocations_updated_at ON public.leave_allocations;
CREATE TRIGGER leave_allocations_updated_at
BEFORE UPDATE ON public.leave_allocations
FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- Balance helper: returns allocated/used/pending/remaining for a given employee+type+year
CREATE OR REPLACE FUNCTION public.get_leave_balance(
  p_employee_id UUID,
  p_leave_type TEXT,
  p_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
)
RETURNS TABLE(
  employee_id UUID,
  leave_type TEXT,
  year INTEGER,
  allocated_days NUMERIC,
  carried_over_days NUMERIC,
  used_days NUMERIC,
  pending_days NUMERIC,
  remaining_days NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH alloc AS (
    SELECT
      la.employee_id,
      la.leave_type,
      la.year,
      la.allocated_days,
      la.carried_over_days
    FROM public.leave_allocations la
    WHERE la.employee_id = p_employee_id
      AND la.leave_type = p_leave_type
      AND la.year = p_year
  ),
  usage AS (
    SELECT
      COALESCE(SUM(CASE WHEN lr.status = 'approved' THEN lr.days ELSE 0 END), 0)::NUMERIC AS used_days,
      COALESCE(SUM(CASE WHEN lr.status = 'pending' THEN lr.days ELSE 0 END), 0)::NUMERIC AS pending_days
    FROM public.leave_requests lr
    WHERE lr.employee_id = p_employee_id
      AND lr.leave_type = p_leave_type
      AND EXTRACT(YEAR FROM lr.start_date)::INTEGER = p_year
  )
  SELECT
    p_employee_id,
    p_leave_type,
    p_year,
    COALESCE((SELECT allocated_days FROM alloc), 0),
    COALESCE((SELECT carried_over_days FROM alloc), 0),
    u.used_days,
    u.pending_days,
    (COALESCE((SELECT allocated_days FROM alloc), 0)
      + COALESCE((SELECT carried_over_days FROM alloc), 0)
      - u.used_days
      - u.pending_days) AS remaining_days
  FROM usage u;
$$;

-- Aggregated balances for an employee (all types) for a given year
CREATE OR REPLACE FUNCTION public.get_employee_leave_balances(
  p_employee_id UUID,
  p_year INTEGER DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
)
RETURNS TABLE(
  leave_type TEXT,
  year INTEGER,
  allocated_days NUMERIC,
  carried_over_days NUMERIC,
  used_days NUMERIC,
  pending_days NUMERIC,
  remaining_days NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH types AS (
    SELECT DISTINCT leave_type FROM public.leave_allocations
      WHERE employee_id = p_employee_id AND year = p_year
    UNION
    SELECT DISTINCT leave_type FROM public.leave_requests
      WHERE employee_id = p_employee_id
        AND EXTRACT(YEAR FROM start_date)::INTEGER = p_year
  )
  SELECT
    t.leave_type,
    p_year,
    b.allocated_days,
    b.carried_over_days,
    b.used_days,
    b.pending_days,
    b.remaining_days
  FROM types t
  CROSS JOIN LATERAL public.get_leave_balance(p_employee_id, t.leave_type, p_year) b;
$$;