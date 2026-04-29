---
name: agent-contract-integrity
description: Paraplyprincip — varje skill som exponeras mot agenter (FlowPilot/MCP/A2A) har ett kontrakt mot DB/handler som MÅSTE vara verifierat av guardrail-test innan release. Samlar alla befintliga guardrails under en enda mental modell.
type: constraint
---

# Agent Contract Integrity

**Mental modell:** En skill är ett **publikt API mot autonoma agenter**. Agenten ser bara `tool_definition` — den kan inte gissa vad DB/handlern faktiskt kräver. Varje gap mellan skill-schema och verklig backend = tyst körfel i produktion som är osynligt för agenten (den får ett kryptiskt Postgres-fel och ger upp eller hallucinerar argument).

Därför: **innan en skill seedas eller släpps via MCP måste fyra kontraktslager vara verifierade.**

## De fyra kontraktslagren

### 1. Argument-mappning (skill props ↔ handler-args)
Agent-execute strippar `_`-prefixerade args + `trace_id`/`objective_context`, prefixar resten med `p_`. Skill-properties måste landa på riktiga RPC-args efter den transformen.

- **Regel:** RPC:er bakom `rpc:*`-handlers MÅSTE använda `p_`-prefix. Se `mem://constraints/rpc-skill-arg-prefix-convention`.
- **Guardrail:** `src/lib/__tests__/rpc-skill-arg-drift.guardrails.test.ts` (live snapshot från `pg_proc`)
- **Snapshot-script:** `scripts/snapshot-rpc-skill-args.ts`
- **Mappnings-test:** `src/lib/__tests__/agent-execute-rpc-arg-mapping.test.ts`

### 2. Schema-täckning (alla NOT NULL exponerade)
Om DB kräver en kolumn måste skill-schemat antingen exponera den ELLER deklarera att handlern auto-fyller den.

- **Regel:** Se `mem://constraints/skill-schema-must-mirror-db-not-null`.
- **Guardrail:** `src/lib/__tests__/skill-schema-not-null-coverage.guardrails.test.ts`
- **Snapshot-script:** `scripts/snapshot-db-not-nulls.ts`
- **Auto-fill-undantag:** `src/lib/__tests__/fixtures/db-not-null-columns.json` → `_skill_auto_filled_columns`

### 3. Värde-domän (enums & status-aliaser)
Agenter använder naturliga ord (`new`, `won`, `all`) — DB har strikta enums. Mappning ska vara explicit, inte tyst svälja okända värden.

- **Regel:** Se `mem://crm/manage-leads-status-alias-mapping` (mönster för andra status-fält).
- **Guardrail-mönster:** Lås kontraktet i ett dedikerat test som listar tillåtna alias → kanonisk enum.

### 4. Modul-registrering (skill ↔ modul ↔ MCP)
En skill måste tillhöra en aktiv modul, vara seeded med rätt `mcp_exposed`, och dess modul måste vara exporterad/registrerad korrekt.

- **Regel:** Se `mem://architecture/modules-as-real-saas-not-simulations` + `mem://architecture/mcp-as-platform-not-flowpilot-feature`.
- **Guardrail:** `src/lib/__tests__/module-registry.guardrails.test.ts`, `mcp-contract.guardrails.test.ts`, `hr-suite-mcp-registry.guardrails.test.ts`

## Pre-release-checklista (innan en ny skill mergas)

Kör denna mentalt vid varje ny `rpc:*` / `db:*` / `edge:*` / `internal:*`-skill:

1. **Handler finns och är callable** — RPC i migration ELLER edge function deployad ELLER `internal:` case i agent-execute.
2. **Argument-prefix korrekt** — `p_*` på alla RPC-params (om `rpc:*`).
3. **Schema speglar DB** — alla NOT NULL utan default exponerade, eller listade i auto-fill-undantag.
4. **Per-action `required`** — `create`/`update`/`delete` har rätt obligatoriska fält i `allOf/if/then`.
5. **Beskrivning har `Use when:` / `NOT for:`** — annars rankar scoring-algoritmen den fel (Law 2).
6. **Modul deklarerar skill i `skillSeeds`** — inte bara seedad direkt i DB (annars försvinner den vid module-reset).
7. **Snapshots regenererade** — `bun run scripts/snapshot-rpc-skill-args.ts` + `snapshot-db-not-nulls.ts`.
8. **Guardrail-tests gröna** — `npx vitest run src/lib/__tests__/*.guardrails.test.ts`.

## Varför det här mönstret existerar

FlowPilot, OpenClaw och externa peers (Jan/ClawThree) ser bara `tool_definition`. Varje fel där = agenten gissar, hallucinerar eller ger upp tyst. **Kontraktsintegritet är inte en kvalitetsfråga utan en autonomifråga** — utan den kan agenter inte exekvera utan mänsklig debugging i loopen.

## Kända kvarvarande drift-poster
Se `mem://constraints/rpc-skill-arg-prefix-convention` → "Känd kvarvarande drift" (lock_timesheet_period m.fl.).
