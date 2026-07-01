-- Auto-fill journal_entry_lines.account_name from the chart of accounts.
--
-- journal_entry_lines.account_name is NOT NULL, but several posting functions
-- (register_fixed_asset among them) insert lines with only account_code +
-- amounts — so the line fails with "null value in column account_name violates
-- not-null constraint" (OpenClaw fixed-asset finding). Rather than patch each
-- writer, populate account_name defensively at the row level: resolve it from
-- chart_of_accounts by account_code, falling back to the code itself when the
-- account isn't on file. Fail-forward (Law 4) — any journal writer that omits
-- account_name now succeeds. Idempotent (CREATE OR REPLACE + DROP/CREATE trigger).
CREATE OR REPLACE FUNCTION public.fill_journal_line_account_name()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.account_name IS NULL OR NEW.account_name = '' THEN
    IF NEW.account_code IS NOT NULL THEN
      SELECT account_name INTO NEW.account_name
      FROM public.chart_of_accounts
      WHERE account_code = NEW.account_code
      LIMIT 1;
    END IF;
    -- Fall back to the code (or a placeholder) so the NOT NULL constraint holds
    -- even when the account isn't in the chart of accounts yet.
    NEW.account_name := COALESCE(NULLIF(NEW.account_name, ''), NEW.account_code, 'Unspecified');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS fill_journal_line_account_name ON public.journal_entry_lines;
CREATE TRIGGER fill_journal_line_account_name
  BEFORE INSERT OR UPDATE ON public.journal_entry_lines
  FOR EACH ROW
  EXECUTE FUNCTION public.fill_journal_line_account_name();
