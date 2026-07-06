-- Agentic bookkeeping (build round 1): link a booked bank transaction to its
-- journal entry so the "Händelser att bokföra" queue can tell booked from
-- unbooked events.
--   "Events to book" = bank_transactions WHERE journal_entry_id IS NULL
--                      AND status <> 'ignored'.
-- The accept path (manage_journal_entry) sets journal_entry_id after posting.
-- Idempotent + forward-dated so it reaches managed/forked instances.

ALTER TABLE public.bank_transactions
  ADD COLUMN IF NOT EXISTS journal_entry_id uuid
    REFERENCES public.journal_entries(id) ON DELETE SET NULL;

-- Partial index for the queue query (unbooked events, newest first).
CREATE INDEX IF NOT EXISTS idx_bank_transactions_unbooked
  ON public.bank_transactions (transaction_date DESC)
  WHERE journal_entry_id IS NULL;

COMMENT ON COLUMN public.bank_transactions.journal_entry_id IS
  'FK to the journal entry this bank transaction was booked into (agentic bookkeeping). NULL = not yet booked = appears in "Händelser att bokföra".';
