ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS email_from_address text,
  ADD COLUMN IF NOT EXISTS email_from_name text,
  ADD COLUMN IF NOT EXISTS email_reply_to text;

COMMENT ON COLUMN public.profiles.email_from_address IS 'Per-user override for outbound email From address. When set, email-send uses this instead of the workspace default. Personal seller address (e.g. seller1@flowwink.com).';
COMMENT ON COLUMN public.profiles.email_from_name IS 'Display name used in the From header when email_from_address is set. Falls back to full_name.';
COMMENT ON COLUMN public.profiles.email_reply_to IS 'Optional Reply-To address for outbound email when sending on behalf of this user.';