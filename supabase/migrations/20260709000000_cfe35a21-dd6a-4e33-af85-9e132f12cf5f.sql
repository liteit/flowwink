-- Robustness-review support RPCs (2026-07-08 review findings M4 + H4).
-- Applied to dev DB directly the same day; this migration persists them for the fleet.

-- M4: atomic template usage increment — the old read-modify-write in
-- agent-execute lost updates under concurrent bookings.
CREATE OR REPLACE FUNCTION public.increment_template_usage(p_template_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  UPDATE public.accounting_templates
  SET usage_count = COALESCE(usage_count, 0) + 1, updated_at = now()
  WHERE id = p_template_id;
$$;

-- H4: aggregated confirmed-booking counts per counterparty. The old client-side
-- count pulled every booked bank_transactions row and silently truncated at
-- PostgREST's row cap (~1000), so the vendor trust ramp (88 + 5×confirmed) and
-- the auto-vs-propose routing were computed from an undercount on mature ledgers.
CREATE OR REPLACE FUNCTION public.booked_counterparty_counts()
RETURNS TABLE(counterparty text, cnt bigint)
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT bt.counterparty, count(*)::bigint AS cnt
  FROM public.bank_transactions bt
  WHERE bt.journal_entry_id IS NOT NULL AND bt.counterparty IS NOT NULL
  GROUP BY bt.counterparty;
$$;
