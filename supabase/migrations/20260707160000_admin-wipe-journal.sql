-- Dev/iteration utility (Magnus, 2026-07-07): "Delete all" in the Journal's
-- overflow menu. One coherent wipe that handles the whole FK web + period
-- locks (everything we tripped on doing this by hand). Admin-only via UI —
-- deliberately NOT registered as an agent skill.
-- Idempotent + forward-dated.

CREATE OR REPLACE FUNCTION public.admin_wipe_journal(p_delete_bank_events boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entries int;
  v_lines int;
  v_events int;
  v_periods int;
BEGIN
  -- Service-role escape + admin guard (fleet lesson: agent-callable SECURITY
  -- DEFINER functions need auth.role() check; this one is UI/admin only).
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(), 'admin')) THEN
    RAISE EXCEPTION 'Only admins can wipe the journal';
  END IF;

  -- Closed periods block entry deletion via guard_journal_entries_period();
  -- a full wipe implies reopening them (reported in the result).
  UPDATE accounting_periods SET status = 'open' WHERE status <> 'open';
  GET DIAGNOSTICS v_periods = ROW_COUNT;

  -- Clear every FK that references journal_entries.
  UPDATE expense_payments SET journal_entry_id = NULL WHERE journal_entry_id IS NOT NULL;
  UPDATE expense_reports SET journal_entry_id = NULL WHERE journal_entry_id IS NOT NULL;
  UPDATE payment_reconciliations SET journal_entry_id = NULL, reversal_journal_entry_id = NULL
    WHERE journal_entry_id IS NOT NULL OR reversal_journal_entry_id IS NOT NULL;
  UPDATE payroll_runs SET approval_journal_id = NULL, payment_journal_id = NULL
    WHERE approval_journal_id IS NOT NULL OR payment_journal_id IS NOT NULL;
  DELETE FROM analytic_lines;
  DELETE FROM accounting_corrections;
  DELETE FROM journal_entry_line_taxes;

  DELETE FROM journal_entry_lines;
  GET DIAGNOSTICS v_lines = ROW_COUNT;

  IF p_delete_bank_events THEN
    DELETE FROM reconciliation_matches;
    DELETE FROM bank_transactions;
    GET DIAGNOSTICS v_events = ROW_COUNT;
  ELSE
    -- Reset events to unbooked so the events-to-book queue refills — the
    -- iterate-on-proposals loop.
    DELETE FROM reconciliation_matches;
    UPDATE bank_transactions
      SET journal_entry_id = NULL, status = 'unmatched', matched_amount_cents = 0
      WHERE journal_entry_id IS NOT NULL OR status <> 'unmatched';
    GET DIAGNOSTICS v_events = ROW_COUNT;
  END IF;

  DELETE FROM journal_entries;
  GET DIAGNOSTICS v_entries = ROW_COUNT;

  RETURN jsonb_build_object(
    'entries_deleted', v_entries,
    'lines_deleted', v_lines,
    'bank_events', v_events,
    'bank_events_deleted', p_delete_bank_events,
    'periods_reopened', v_periods
  );
END;
$$;
