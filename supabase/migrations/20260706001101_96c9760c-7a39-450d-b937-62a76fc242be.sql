-- Seed four missing SE-BAS 2024 accounts referenced by posted journal_entry_lines
-- but absent from chart_of_accounts, causing balance_sheet (which joins on
-- chart_of_accounts.account_type) to silently drop those lines and imbalance.
-- Idempotent: ON CONFLICT (account_code) refreshes classification but preserves
-- the row identity.

INSERT INTO public.chart_of_accounts
  (account_code, account_name, account_type, account_category, normal_balance, is_active, locale)
VALUES
  ('1210', 'Maskiner och andra tekniska anläggningar', 'asset',     'tillgångar',   'debit',  true, 'se-bas2024'),
  ('2090', 'Balanserad vinst eller förlust',           'equity',    'eget kapital', 'credit', true, 'se-bas2024'),
  ('2641', 'Debiterad ingående moms',                   'asset',     'tillgångar',   'debit',  true, 'se-bas2024'),
  ('7970', 'Förlust vid avyttring av immateriella och materiella anläggningstillgångar',
                                                        'expense',   'kostnader',    'debit',  true, 'se-bas2024')
ON CONFLICT (account_code) DO UPDATE
SET account_name     = EXCLUDED.account_name,
    account_type     = EXCLUDED.account_type,
    account_category = EXCLUDED.account_category,
    normal_balance   = EXCLUDED.normal_balance,
    is_active        = true;