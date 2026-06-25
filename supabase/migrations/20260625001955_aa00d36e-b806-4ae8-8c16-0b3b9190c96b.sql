CREATE TABLE IF NOT EXISTS public.inbound_email_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL DEFAULT 'composio_gmail',
  composio_account_id text,
  email_address text NOT NULL,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  is_shared boolean NOT NULL DEFAULT true,
  watch_expires_at timestamptz,
  last_history_id text,
  last_received_at timestamptz,
  enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS inbound_email_accounts_email_unique
  ON public.inbound_email_accounts (lower(email_address));

CREATE INDEX IF NOT EXISTS inbound_email_accounts_composio_idx
  ON public.inbound_email_accounts (composio_account_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.inbound_email_accounts TO authenticated;
GRANT ALL ON public.inbound_email_accounts TO service_role;

ALTER TABLE public.inbound_email_accounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage inbound email accounts" ON public.inbound_email_accounts;
CREATE POLICY "Admins manage inbound email accounts"
  ON public.inbound_email_accounts
  FOR ALL
  TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "Authenticated users can read inbound email accounts" ON public.inbound_email_accounts;
CREATE POLICY "Authenticated users can read inbound email accounts"
  ON public.inbound_email_accounts
  FOR SELECT
  TO authenticated
  USING (true);

DROP TRIGGER IF EXISTS update_inbound_email_accounts_updated_at ON public.inbound_email_accounts;
CREATE TRIGGER update_inbound_email_accounts_updated_at
  BEFORE UPDATE ON public.inbound_email_accounts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();