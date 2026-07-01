-- Seed the currencies lookup table so multi-currency FKs resolve.
--
-- `mcp_set_exchange_rate` (and the exchange_rates from/to-currency FKs) reference
-- currencies(code), but the table ships EMPTY on a fresh/managed instance — so
-- set_exchange_rate always failed with a foreign-key violation over the operator
-- surface (OpenClaw finding). Same "lookup table never seeded" class. Idempotent
-- seed of common ISO-4217 currencies; leaves is_base alone (the site chooses its
-- base currency), so re-running never clobbers an instance's configured base.
INSERT INTO public.currencies (code, name, symbol, decimals) VALUES
  ('USD', 'US Dollar',           '$',   2),
  ('EUR', 'Euro',                '€',   2),
  ('SEK', 'Swedish Krona',       'kr',  2),
  ('NOK', 'Norwegian Krone',     'kr',  2),
  ('DKK', 'Danish Krone',        'kr',  2),
  ('GBP', 'British Pound',       '£',   2),
  ('CHF', 'Swiss Franc',         'CHF', 2),
  ('JPY', 'Japanese Yen',        '¥',   0),
  ('CAD', 'Canadian Dollar',     '$',   2),
  ('AUD', 'Australian Dollar',   '$',   2),
  ('PLN', 'Polish Zloty',        'zł',  2),
  ('CNY', 'Chinese Yuan',        '¥',   2),
  ('INR', 'Indian Rupee',        '₹',   2),
  ('BRL', 'Brazilian Real',      'R$',  2),
  ('ZAR', 'South African Rand',  'R',   2)
ON CONFLICT (code) DO NOTHING;
