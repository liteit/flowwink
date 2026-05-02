---
name: SLA Monitor & Compliance
description: SLA-modul äger 3 skills (sla_check, manage_sla_policy, list_sla_violations) — alla MCP-exposade. sla_check förblir global utility-skill. orders-module raderad — duplicerade place_order.
type: feature
---

**SLA-modul (`src/lib/modules/sla-module.ts`)** äger nu fulla SkillSeeds:
- `sla_check` (edge:sla-check) — global utility, alltid MCP-exposed (per mcp-exposure-invariants)
- `manage_sla_policy` (db:sla_policies) — CRUD via generic agent-execute
- `list_sla_violations` (db:sla_violations) — read-only listing

Tabeller: `sla_policies` (entity_type + metric + threshold_minutes + priority) och `sla_violations` (med auto-resolve via resolved_at).

**Default thresholds (SMB):** ticket first_response 60min, ticket resolution 1440min, order fulfillment 2880min, lead first_response 240min, chat first_response 5min.

**orders-module raderad:** Funktionalitet duplicerad av `place_order` i products-module. Inga runtime-callers fanns. `OrderModuleInput`-typer kvar i `module-contracts.ts` (används ev. av tester).
