---
name: MCP Invariant CI Guardrail
description: scripts/verify-mcp-invariant.ts + mcp-regression workflow blockerar deploy om någon skill har mcp_exposed=true men enabled=false (orphan MCP tools)
type: feature
---

# MCP Exposure Invariant — CI Guardrail

**Rule (kodifierad):** En skill med `mcp_exposed = true` MÅSTE ha `enabled = true`.
Annars dyker den upp i MCP `tools/list` men kraschar vid anrop ("skill disabled") för externa agenter.

## Implementation

- **Script:** `scripts/verify-mcp-invariant.ts` — query:ar PostgREST `agent_skills?mcp_exposed=eq.true&enabled=eq.false`. Tomt resultat = exit 0. Orphans = exit 1 + listar dem.
- **npm script:** `npm run verify:mcp-invariant`
- **CI:** Körs i `.github/workflows/mcp-regression.yml` före `test:mcp-regression`. Behöver `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` som GitHub secrets. Triggas vid module-changes + dagligen kl 06:00 UTC.

## Fix-paths när det fail:ar

1. Re-enable skillen: `UPDATE agent_skills SET enabled=true WHERE name='<x>'`
2. Eller dölj från MCP: `UPDATE agent_skills SET mcp_exposed=false WHERE name='<x>'`

## Varför detta inte är underhållsbörda

Invarianten finns redan dokumenterad (`mem://architecture/mcp-exposure-invariants`). Guardrailen flyttar bara verifieringen från manuell rondering till CI. Ingen löpande aktion krävs så länge invarianten respekteras vid skill-edits.
