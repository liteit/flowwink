# Accounting Locale Packs

> FlowWink's bookkeeping core is **accounting-neutral**. Country/standard-specific
> behaviour lives in *locale packs* — pluggable bundles that supply a chart of
> accounts, VAT rules, payroll formats and bank-statement importers.
> Inspired by Odoo's localization addons.

## Why

Without packs, the platform was hard-locked to BAS 2024 / SEK / 25% VAT / PAXml /
SIE. Every new market required scattered edits across `accounting-module`,
`invoicing-module`, `purchasing-module`, `usePayroll`, etc.

With packs, **adding a new market is a single new directory** under
`src/lib/locale-packs/<id>/` plus one line in the registry.

## Architecture

```
src/lib/locale-packs/
├── types.ts              ← AccountingLocalePack contract
├── index.ts              ← Registry + getActivePack()
├── se/index.ts           ← Sweden (BAS 2024, PAXml, SIE)
└── generic/index.ts      ← IFRS baseline (CSV payroll, CAMT/MT940/OFX)
```

A pack supplies:

| Field                  | Purpose                                               |
| ---------------------- | ----------------------------------------------------- |
| `chart`                | Chart of accounts seeded into `chart_of_accounts`     |
| `templates`            | Booking templates seeded into `accounting_templates`  |
| `currency`             | ISO code, symbol, decimals, Intl locale               |
| `vat`                  | Default rate + all available rates with VAT accounts  |
| `payroll_adapters[]`   | File generators (PAXml, CSV, BACS, ADP-CSV, …)        |
| `bank_import_adapters[]` | Format metadata (SIE, CAMT.053, MT940, OFX, CSV)    |
| `tax_return_adapters[]` | Optional VAT-return / year-end edge functions        |
| `ai_instructions`      | Prompt fragments injected into skill `instructions`   |

## How modules consume it

```ts
import { getActivePack } from '@/lib/locale-packs';

const pack = getActivePack();
//   pack.currency.code        → 'SEK'
//   pack.vat.default_rate     → 0.25
//   pack.ai_instructions.invoicing → "Default currency SEK. Default VAT 25%..."
```

`accounting-module`, `invoicing-module`, `purchasing-module` and
`reconciliation-module` already read from the active pack. **Never import
country-specific data files (`bas2024-accounts`, `templates-bas2024`, etc.)
directly from a module.**

## Adding a new market (e.g. Germany — SKR04)

1. Create the data
   ```
   src/lib/locale-packs/de/index.ts
   ```
   ```ts
   import type { AccountingLocalePack } from '../types';
   import { SKR04_ACCOUNTS } from './skr04-accounts';
   import { SKR04_TEMPLATES } from './skr04-templates';

   export const dePack: AccountingLocalePack = {
     id: 'de-skr04',
     label: 'Germany — SKR04',
     description: 'German SKR04 chart, 19% VAT default, DATEV export, MT940 import.',
     countries: ['DE'],
     currency: { code: 'EUR', symbol: '€', decimals: 2, intl_locale: 'de-DE' },
     vat: {
       default_rate: 0.19,
       rates: [
         { label: 'Standard 19%', rate: 0.19, output_account: '3806', input_account: '1576' },
         { label: 'Reduced 7%',   rate: 0.07, output_account: '3803', input_account: '1571' },
         { label: 'Zero',         rate: 0 },
       ],
     },
     chart: SKR04_ACCOUNTS,
     templates: SKR04_TEMPLATES,
     payroll_adapters: [datevLohnAdapter],
     bank_import_adapters: [mt940, camt053, csvBank],
     tax_return_adapters: [{ id: 'de-ust', label: 'Umsatzsteuer-Voranmeldung', period: 'monthly' }],
     ai_instructions: {
       journal_entry: 'Use SKR04 4-digit account codes. Standard VAT 19% (account 3806). ...',
       invoicing:     'Default currency EUR. Default VAT 19%. Invoice numbering: RE-XXXXX.',
       purchasing:    'Default tax_rate 19% for German vendors. Reduced 7% for books/food.',
     },
   };
   ```

2. Register it
   ```ts
   // src/lib/locale-packs/index.ts
   import { dePack } from './de';
   export const LOCALE_PACKS = { ...existing, [dePack.id]: dePack };
   ```

3. Done.
   - Settings → Accounting now lists "Germany — SKR04" automatically.
   - The guardrail test (`locale-packs.guardrails.test.ts`) verifies the contract.
   - Modules pick it up the moment a user activates it.

## Switching locale at runtime

The active pack is read from `localStorage['accounting-locale']` (set via
Settings → Accounting). Existing journal entries keep their original
`account_code` references — switching is non-destructive.

For server/edge code, read from `site_settings.accounting_locale` instead of
localStorage.

## Guardrails

`src/lib/__tests__/locale-packs.guardrails.test.ts` enforces:
- Default SE pack + generic IFRS pack are always registered
- Every registered pack has chart, templates, payroll adapter, bank adapter,
  AI instructions for journal/invoicing/purchasing
- SE pack still exposes PAXml + SIE (regression guard for Swedish customers)
- Generic pack does NOT leak Swedish-specific formats
