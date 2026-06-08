-- 1) bank_accounts table
CREATE TABLE IF NOT EXISTS public.bank_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  account_number TEXT,
  currency TEXT NOT NULL DEFAULT 'SEK',
  gl_account TEXT NOT NULL DEFAULT '1930',
  stripe_account_id TEXT,
  is_default BOOLEAN NOT NULL DEFAULT false,
  archived BOOLEAN NOT NULL DEFAULT false,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS bank_accounts_one_default
  ON public.bank_accounts (is_default) WHERE is_default = true AND archived = false;

ALTER TABLE public.bank_accounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins manage bank_accounts" ON public.bank_accounts;
CREATE POLICY "Admins manage bank_accounts"
  ON public.bank_accounts
  FOR ALL
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP TRIGGER IF EXISTS update_bank_accounts_updated_at ON public.bank_accounts;
CREATE TRIGGER update_bank_accounts_updated_at
  BEFORE UPDATE ON public.bank_accounts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 2) Seed a default account if none exists
INSERT INTO public.bank_accounts (name, currency, gl_account, is_default)
SELECT 'Main bank', 'SEK', '1930', true
WHERE NOT EXISTS (SELECT 1 FROM public.bank_accounts);

-- 3) Add bank_account_id to bank_transactions
ALTER TABLE public.bank_transactions
  ADD COLUMN IF NOT EXISTS bank_account_id UUID REFERENCES public.bank_accounts(id) ON DELETE SET NULL;

-- 4) Backfill existing rows to the default account
UPDATE public.bank_transactions bt
SET bank_account_id = (SELECT id FROM public.bank_accounts WHERE is_default = true LIMIT 1)
WHERE bt.bank_account_id IS NULL;

CREATE INDEX IF NOT EXISTS bank_transactions_bank_account_idx
  ON public.bank_transactions (bank_account_id);
