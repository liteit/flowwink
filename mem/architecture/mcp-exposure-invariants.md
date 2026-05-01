---
name: mcp-exposure-invariants
description: Två invarianter på agent_skills MCP-ytan + utility/operator-internal-klassning så externa operatörer (OpenClaw, ClawThree) kan köra site-migration o.dyl. utan FlowPilot
type: constraint
---

# MCP Exposure Invariants

Två oavvisliga regler som låser MCP-katalogen mot externa operatörer:

## Invariant 1: `mcp_exposed=true → enabled=true`
En skill som syns i `tools/list` MÅSTE vara körbar. Annars får OpenClaw/ClawThree ett kryptiskt runtime-fel istället för en tydlig "tool finns inte"-respons.

## Invariant 2: Utility-skills är ALLTID MCP-exposade
Pure utilities (operator-agnostiska kapabiliteter) måste vara tillgängliga för alla MCP-klienter — inte bara FlowPilot. Site-migration är det tydligaste exemplet: en extern operatör måste kunna köra `migrate_url` → `manage_page` end-to-end utan att FlowPilot är aktiverad.

**Lista (utvidgas vid behov):**
- `migrate_url` — URL → FlowWink-blocks
- `scrape_url` — URL → markdown (Firecrawl/Jina)
- `search_web` — web search
- `extract_pdf_text` — PDF → text
- `process_signal` — Chrome ext / webhook signal-analys
- `sla_check` — kör SLA-policies
- `competitor_monitor` — competitor scan

## Operator-internal undantag (ej MCP)
Dessa är FlowPilots egna peer-comms-primitiver, inte kapabiliteter för externa anropare:

- `a2a_chat`, `a2a_request` — A2A-protokoll mot peers (FlowPilot ÄR peer:n)
- `dispatch_claw_mission` — FlowPilot dispatchar till OpenClaw
- `openclaw_start_session`, `openclaw_end_session`, `openclaw_exchange`, `openclaw_get_status` — FlowPilots OpenClaw-integration
- `queue_beta_test` — intern beta-testkö

Externa operatörer behöver inte dessa — de pratar redan MCP direkt.

## Enforcement
- **Migration:** `20260501123249_*` — initial alignment.
- **Guardrail:** `src/lib/__tests__/mcp-exposure-invariants.guardrails.test.ts` läser live-DB.
- **Bootstrap-default:** `src/lib/module-bootstrap.ts` sätter alltid `enabled=true, mcp_exposed=true` vid skill-seed (rad 123, 136-137). Drift uppstår bara via manuella DB-edits.

## Site Migration Operator-Parity (konkret)
För att en extern operatör ska kunna migrera en sajt till FlowWink utan FlowPilot:

1. `migrate_url` (utility) → returnerar blocks + branding
2. `manage_page` (commerce CRUD-skill) → skapar pages med blocks
3. `scrape_url` (utility) → följer ev. otherPages

Alla tre är `mcp_exposed=true, enabled=true`. Firecrawl-integrationen är en server-side dependency (FIRECRAWL_API_KEY) och påverkar inte MCP-ytan.
