-- account_for() requires an ACTIVATED locale pack — empty-until-chosen.
--
-- The first version fell back to 'se-bas2024' when site_settings had no
-- accounting_locale row. That preserved the old implicit behaviour, but the
-- implicit behaviour was the bug: FlowWink is a generic BOS, and an instance
-- where nobody has picked a market must not quietly bookkeep as Swedish.
--
-- With no pack activated, every role lookup now fails with an instruction to
-- activate one. Loud and immediate beats a ledger full of another country's
-- accounts. Safe to ship because every fleet instance had its implicit choice
-- made explicit first (site_settings.accounting_locale = "se-bas2024",
-- 2026-07-21) — this only changes behaviour for installs that never chose.

CREATE OR REPLACE FUNCTION public.account_for(p_role text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _raw jsonb;
  _locale text;
  _code text;
BEGIN
  SELECT value INTO _raw FROM public.site_settings WHERE key = 'accounting_locale' LIMIT 1;
  _locale := COALESCE(
    NULLIF(_raw #>> '{}', ''),      -- value stored as a bare JSON string
    _raw ->> 'id'                   -- or as { "id": "…" }
  );

  IF _locale IS NULL THEN
    RAISE EXCEPTION
      'No accounting locale activated on this instance. Activate a locale pack (admin → Accounting → Locale packs, or set site_settings.accounting_locale) before bookkeeping.';
  END IF;

  SELECT account_code INTO _code
    FROM public.account_roles
   WHERE locale = _locale AND role = p_role;

  IF _code IS NULL THEN
    RAISE EXCEPTION
      'No account mapped to role "%" for accounting locale "%". Activate a locale pack that defines it, or add the mapping in account_roles.',
      p_role, _locale;
  END IF;

  RETURN _code;
END $function$;

GRANT EXECUTE ON FUNCTION public.account_for(text) TO authenticated, service_role;
