-- Template provenance on journal entries (Magnus, 2026-07-07): a booked entry
-- records WHICH template produced it and how it was matched. Closes the
-- template-registry curation loop: corrections can be tied back to the
-- originating template (error rate per template → agent proposes registry
-- fixes: sharpen keywords, split templates, adjust VAT, retire unused).
-- Idempotent + forward-dated.

ALTER TABLE public.journal_entries
  ADD COLUMN IF NOT EXISTS template_id uuid
    REFERENCES public.accounting_templates(id) ON DELETE SET NULL;

ALTER TABLE public.journal_entries
  ADD COLUMN IF NOT EXISTS match_source text; -- 'vendor-default' | 'keyword' | 'manual' | null (pre-provenance)

CREATE INDEX IF NOT EXISTS idx_journal_entries_template
  ON public.journal_entries (template_id) WHERE template_id IS NOT NULL;

COMMENT ON COLUMN public.journal_entries.template_id IS
  'Provenance: the accounting_template that produced this entry (agentic bookkeeping). NULL = manual lines or pre-provenance.';
