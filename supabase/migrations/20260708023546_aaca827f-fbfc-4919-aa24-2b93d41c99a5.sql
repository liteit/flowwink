
-- Expense rate tables (Skatteverket schablon for mileage & per-diem)
CREATE TABLE IF NOT EXISTS public.expense_rate_tables (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('mileage','per_diem')),
  label TEXT NOT NULL,
  rate_cents BIGINT NOT NULL CHECK (rate_cents >= 0),
  unit TEXT NOT NULL,            -- e.g. 'km', 'mil', 'day', 'night'
  currency TEXT NOT NULL DEFAULT 'SEK',
  account_code TEXT,             -- BAS accounting code (7331 milersättning, 7321 traktamente)
  valid_from DATE NOT NULL DEFAULT CURRENT_DATE,
  active BOOLEAN NOT NULL DEFAULT true,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (code, valid_from)
);

GRANT SELECT ON public.expense_rate_tables TO authenticated;
GRANT ALL ON public.expense_rate_tables TO service_role;

ALTER TABLE public.expense_rate_tables ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Authenticated view expense_rate_tables" ON public.expense_rate_tables;
CREATE POLICY "Authenticated view expense_rate_tables"
  ON public.expense_rate_tables FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Admins manage expense_rate_tables" ON public.expense_rate_tables;
CREATE POLICY "Admins manage expense_rate_tables"
  ON public.expense_rate_tables FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin'::app_role))
  WITH CHECK (public.has_role(auth.uid(), 'admin'::app_role));

-- updated_at trigger
DROP TRIGGER IF EXISTS trg_expense_rate_tables_updated_at ON public.expense_rate_tables;
CREATE TRIGGER trg_expense_rate_tables_updated_at
  BEFORE UPDATE ON public.expense_rate_tables
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Seed Skatteverket 2025 tax-free rates (idempotent via UNIQUE + ON CONFLICT)
INSERT INTO public.expense_rate_tables
  (code, kind, label, rate_cents, unit, currency, account_code, valid_from, notes)
VALUES
  ('mileage_car_se',   'mileage',  'Milersättning – egen bil i tjänst (Skatteverket)', 2500, 'mil', 'SEK', '7331', DATE '2025-01-01', 'Skattefri schablon 25 kr/mil'),
  ('per_diem_full_se', 'per_diem', 'Traktamente – helt dygn inrikes (Skatteverket)',   29000, 'day', 'SEK', '7321', DATE '2025-01-01', 'Skattefri schablon 290 kr/dygn'),
  ('per_diem_half_se', 'per_diem', 'Traktamente – halvt dygn inrikes (Skatteverket)',  14500, 'day', 'SEK', '7321', DATE '2025-01-01', 'Skattefri schablon 145 kr'),
  ('per_diem_night_se','per_diem', 'Nattschablon inrikes (Skatteverket)',              14500, 'night','SEK', '7321', DATE '2025-01-01', 'Skattefri nattschablon 145 kr')
ON CONFLICT (code, valid_from) DO NOTHING;

-- Extend expenses with rate reference (nullable — legacy rows unaffected)
ALTER TABLE public.expenses
  ADD COLUMN IF NOT EXISTS rate_code TEXT,
  ADD COLUMN IF NOT EXISTS quantity NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS unit TEXT;

-- Helper: resolve active rate at a date (returns most recent valid_from <= p_date)
CREATE OR REPLACE FUNCTION public.get_expense_rate(p_code TEXT, p_date DATE DEFAULT CURRENT_DATE)
RETURNS public.expense_rate_tables
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT *
  FROM public.expense_rate_tables
  WHERE code = p_code
    AND active = true
    AND valid_from <= p_date
  ORDER BY valid_from DESC
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_expense_rate(TEXT, DATE) TO authenticated, service_role;
