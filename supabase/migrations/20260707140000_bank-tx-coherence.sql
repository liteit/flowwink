-- System-sweep findings #B4 + #B6 (2026-07-07): bank-transaction coherence.
-- Idempotent + forward-dated.

-- #B4: recalc_bank_tx_match_status() recomputes status purely from
-- reconciliation_matches. A transaction booked via the events-to-book queue
-- has journal_entry_id set but NO match rows — any later match insert/delete
-- on it would flip status back to 'unmatched' while it is in fact booked.
-- Keep the single truth: a booked transaction (journal_entry_id IS NOT NULL)
-- never drops below 'matched'.
CREATE OR REPLACE FUNCTION "public"."recalc_bank_tx_match_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_tx_id UUID;
  v_total_matched BIGINT;
  v_tx_amount BIGINT;
  v_journal_entry UUID;
BEGIN
  v_tx_id := COALESCE(NEW.bank_transaction_id, OLD.bank_transaction_id);

  SELECT COALESCE(SUM(ABS(amount_cents)), 0) INTO v_total_matched
  FROM public.reconciliation_matches WHERE bank_transaction_id = v_tx_id;

  SELECT ABS(amount_cents), journal_entry_id INTO v_tx_amount, v_journal_entry
  FROM public.bank_transactions WHERE id = v_tx_id;

  UPDATE public.bank_transactions
  SET matched_amount_cents = v_total_matched,
      status = CASE
        -- Booked via the ledger link ⇒ stays matched regardless of match rows
        WHEN v_journal_entry IS NOT NULL THEN 'matched'
        WHEN v_total_matched = 0 THEN 'unmatched'
        WHEN v_total_matched >= v_tx_amount THEN 'matched'
        ELSE 'partial'
      END,
      updated_at = now()
  WHERE id = v_tx_id;

  RETURN NULL;
END;
$$;

-- #B6: a reconciliation match must carry a positive amount — a negative
-- amount corrupts matched_amount_cents (ABS-sum) and the partial/matched math.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'reconciliation_matches_amount_positive'
  ) THEN
    ALTER TABLE public.reconciliation_matches
      ADD CONSTRAINT reconciliation_matches_amount_positive CHECK (amount_cents > 0);
  END IF;
END $$;
