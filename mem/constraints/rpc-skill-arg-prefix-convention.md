---
name: rpc-skill-arg-prefix-convention
description: Alla RPC:er som anropas via agent_skills MUST använda p_-prefix på parametrar, eftersom agent-execute strippar _-prefixerade args och prefixar resten med p_
type: constraint
---

`agent-execute/index.ts` `mapRpcArgs()` hanterar JSON-args från LLM så här:
1. Strippar allt som börjar med `_` (anses agent-internt: `_caller_user_id`, `_approved`, `_bypass_approval`, `_objective_context`)
2. Strippar `trace_id` och `objective_context` på toppnivå
3. Prefixar allt övrigt med `p_` om det inte redan börjar med `p_`

**Konsekvens:**
- En RPC med signaturen `my_fn(_report_id uuid)` är **omöjlig att anropa** via skill — args strippas innan anropet.
- En skill med property `period` mot RPC `my_fn(p_my_period text)` blir `p_period` ≠ `p_my_period` → tyst fel.

**Regler:**
- ALLA nya RPC:er som registreras som `handler: 'rpc:<name>'` MÅSTE använda `p_`-prefix på parametrar.
- Tool-definition properties bör helst också vara `p_`-prefixerade så att schema speglar Postgres-signaturen 1:1 (defensiv tydlighet för MCP-klienter).
- Fix för existerande `_`-RPC:er: drop+recreate funktionen med ny signatur, uppdatera UI-anropare, kör guardrail-test.

**Guardrail:** `src/lib/__tests__/rpc-skill-arg-drift.guardrails.test.ts` läser snapshot `fixtures/rpc-skill-args.json` och felar i CI om någon skill-property inte mappar till en verklig RPC-arg. Snapshot regenereras via `bun run scripts/snapshot-rpc-skill-args.ts`.

**Migrering 2026-04-29:** Migrerade fyra expense-RPC:er + `generate_monthly_expense_report` från `_arg` → `p_arg`. Uppdaterade `useExpenses.ts` och tool_definitions i `agent_skills`.

**Känd kvarvarande drift (att fixa):**
- `lock_timesheet_period` skill deklarerar `fiscal_year, period_month` — mappas till `p_fiscal_year, p_period_month` men `close_accounting_period(p_year, p_month, p_notes)` kräver `p_year, p_month`. Behöver alias-skill eller schema-rename.
- `auto_approve_vendor_invoice`, `auto_generate_purchase_orders`, `bulk_invoice_from_timesheets`, `close_accounting_period`, `hire_application`, `hire_candidate`, `match_po_to_invoice`, `reopen_accounting_period`, `send_dunning_reminders`, `auto_allocate_vacation` — alla har skill-properties utan `p_`-prefix som tursamt mappas korrekt eftersom RPC:n också använder `p_`. Funkar men är inkonsekvent dokumentation.
