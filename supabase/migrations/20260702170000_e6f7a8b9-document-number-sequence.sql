-- Gapless, race-safe document numbering for invoices and quotes.
--
-- Both used `SELECT count(*) + 1` in the client: two concurrent creates read the
-- same count → duplicate INV-0007, and deleting a document lowered the count so
-- the next create REUSED an existing number. For a Swedish accounting system
-- that violates the unique/sequential numbering requirement (Bokföringslagen).
--
-- Fix: a monotonic counter table (never decremented by deletes) + an atomic
-- allocator. Seeded from the current MAX so the sequence continues rather than
-- restarting. Idempotent.
CREATE TABLE IF NOT EXISTS public.document_counters (
  kind text PRIMARY KEY,
  last_value integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Seed continuation points from existing data (digits of the current max number).
INSERT INTO public.document_counters (kind, last_value)
SELECT 'invoice', COALESCE(MAX(NULLIF(regexp_replace(invoice_number, '\D', '', 'g'), '')::int), 0)
FROM public.invoices
ON CONFLICT (kind) DO NOTHING;

INSERT INTO public.document_counters (kind, last_value)
SELECT 'quote', COALESCE(MAX(NULLIF(regexp_replace(quote_number, '\D', '', 'g'), '')::int), 0)
FROM public.quotes
ON CONFLICT (kind) DO NOTHING;

-- Atomic allocator: one UPSERT increments and returns the new value under the
-- row lock, so concurrent callers can never get the same number. Format matches
-- the existing PREFIX-0000 style (no year) to avoid changing issued numbers.
CREATE OR REPLACE FUNCTION public.next_document_number(p_kind text, p_prefix text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_seq integer;
BEGIN
  INSERT INTO public.document_counters (kind, last_value)
  VALUES (p_kind, 1)
  ON CONFLICT (kind)
  DO UPDATE SET last_value = document_counters.last_value + 1, updated_at = now()
  RETURNING last_value INTO v_seq;
  RETURN p_prefix || '-' || lpad(v_seq::text, 4, '0');
END;
$$;

GRANT EXECUTE ON FUNCTION public.next_document_number(text, text) TO service_role, authenticated, anon;
