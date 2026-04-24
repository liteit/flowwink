---
name: accounting-locale-packs
description: Plugin-arkitektur för accounting (Odoo-style localization addons). Modulerna är accounting-neutral; SE/IFRS/DE/UK/US lever som självständiga paket under src/lib/locale-packs/. Aldrig importera country-specifik data direkt i en modul.
type: feature
---

FlowWink är **accounting-neutral**. All landsspecifik logik (chart, VAT, payroll-format, bank-import) ligger i locale packs under `src/lib/locale-packs/<id>/` som implementerar `AccountingLocalePack`-kontraktet i `types.ts`.

**Registrerade pack idag:** `se-bas2024` (default — BAS 2024, SEK, 25% VAT, PAXml, SIE), `ifrs-generic` (EUR, generisk CSV-payroll, CAMT.053/MT940/OFX).

**Modulkonsumtion:** `accounting-module`, `invoicing-module`, `purchasing-module`, `reconciliation-module` läser via `getActivePack()` — aldrig direkta imports av `bas2024-accounts`/`templates-bas2024`/PAXml etc. AI-instructions injiceras från `pack.ai_instructions.{journal_entry,invoicing,purchasing}`.

**Aktivt pack:** `localStorage['accounting-locale']` (klient) eller `site_settings.accounting_locale` (server). Default = `se-bas2024`. Switch är non-destruktiv (befintliga journal entries behåller sina account_codes).

**Lägga till nytt land (DE/UK/US/...):** Skapa `src/lib/locale-packs/<id>/index.ts` + en rad i registry. Settings-UI och bootstrap-seeding picker upp paketet automatiskt. Se `docs/architecture/accounting-locale-packs.md`.

**Guardrail:** `src/lib/__tests__/locale-packs.guardrails.test.ts` låser kontraktet — varje pack måste ha chart, payroll-adapter, bank-adapter och AI-instructions för alla tre modulerna. SE-paketet måste fortsätta exponera PAXml + SIE.
