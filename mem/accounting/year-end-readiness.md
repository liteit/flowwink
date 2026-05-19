---
name: year-end-readiness
description: 4 read-only RPCs (year_end_readiness/propose_accruals/propose_annual_depreciation/run_year_end) + pack.year_end_proposals callback för land-specifika dispositioner; locale-neutral orchestration
type: feature
---

# Year-End Readiness & Orchestration

**Lager:** Accounting neutral core + locale-pack callback.

## Core RPCs (MCP-skills i kategori `commerce`)
- `year_end_readiness(p_year)` → 6-punkts checklista: `periods_closed`, `no_drafts`, `voucher_integrity`, `reconciliations_cleared`, `invoices_settled`, `expenses_settled`. Saknad tabell returnerar `n/a`.
- `propose_accruals(p_year)` → scan av fakturor/expenses med leveransdatum före årsskifte men ingen betalning före — föreslår periodiseringar.
- `propose_annual_depreciation(p_year)` → kör straight-line/declining över `fixed_assets`.
- `run_year_end(p_year, p_confirm)` → orchestrator som returnerar konsoliderad readiness + proposals; med `p_confirm=true` stagar varje proposal via `pending_operations` (faller in i staged-envelope-flödet).

## Locale-pack callback
```ts
// src/lib/locale-packs/types.ts
year_end_proposals?: (year: number) => Promise<AccrualProposal[]>
```

Core anropar `pack.year_end_proposals?.(year)` om definierad och stagar resultatet. Pack äger reglerna, core äger orchestration.

### SE-implementation (stub)
`src/lib/locale-packs/se/index.ts` returnerar `se-periodiseringsfond` (max 25% av skattemässigt resultat → konto 8811/2125) och `se-overavskrivningar` (planmässig vs skattemässig → 8850/2150). Idag = stubs med 0-belopp + confidence 0.2; riktig tax-result-beräkning kommer när underliggande RPC finns.

### Framtida pack
- DE: `de-rueckstellungen` (Garantierückstellungen, Urlaubsrückstellung)
- US: `us-deferred-tax` (FAS 109 / ASC 740 adjustments)
- IFRS-generic: defaultar till tom array — pack-callback är optional.

## UI
`/admin/accounting → Year-End` (`YearEndTab.tsx`) — kör readiness, visa proposals, knapp för `run_year_end(confirm=true)` som skapar pending operations.

## Guardrail
`src/lib/__tests__/locale-packs.guardrails.test.ts` verifierar att SE-packen exponerar `year_end_proposals` och att alla proposals har `id`/`label`/`lines`. `voucher-gaps.guardrails.test.ts` verifierar att `year_end_readiness`-skillen är enabled+mcp_exposed.

## Varför neutralt
Orchestration-skalet är universellt. Bara dispositioner/Rückstellungen/deferred-tax skiljer per land — och de bor i pack-callbacks, inte i core.
