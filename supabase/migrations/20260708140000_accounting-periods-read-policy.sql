-- Fiscal-year selector showed every year as "Upcoming" (Magnus, 2026-07-08).
-- Root cause: accounting_periods had only an "Admins manage [ALL]" RLS policy,
-- so the FiscalYearSelector's read returned empty for any context where the
-- admin-role check didn't resolve → statusFor([]) = 'upcoming' for all years.
-- Period status (open/closed) is reference data reports & selectors read; it is
-- not sensitive. Allow authenticated reads; writes stay admin-only.
-- Idempotent + forward-dated.

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename='accounting_periods'
      AND policyname='Authenticated can read accounting periods'
  ) THEN
    CREATE POLICY "Authenticated can read accounting periods"
      ON public.accounting_periods FOR SELECT TO authenticated USING (true);
  END IF;
END $$;
