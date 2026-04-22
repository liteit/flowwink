ALTER TABLE public.applications
  ADD COLUMN IF NOT EXISTS match_breakdown jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS recommendation text,
  ADD COLUMN IF NOT EXISTS confidence_level text;