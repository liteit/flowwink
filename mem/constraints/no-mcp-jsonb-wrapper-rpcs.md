---
name: No mcp_*(args jsonb) wrapper RPCs as skill handlers
description: Skill-handlers `rpc:mcp_X` där RPC har signaturen (args jsonb) är ALLTID trasiga — agent-execute spreader p_-prefixade fält, inte ett jsonb-objekt. Peka skills på underliggande p_-arg RPC istället.
type: constraint
---

# Constraint: never point a skill at an `mcp_X(args jsonb)` wrapper

`agent-execute` (rpc:-handler) konverterar skill-args till `p_<name>` och anropar
`supabase.rpc(fn, { p_x: ..., p_y: ... })`. En RPC som tar `args jsonb` får då
`p_x` som okänd parameter → `function ... does not exist`-fel. Skillen blir
osynligt obrukbar — varken FlowPilot eller externa MCP-klienter kan kalla den.

**Why:** Vi har två parallella RPC-stilar i DB:n:

- `do_thing(p_id uuid, p_when date) RETURNS jsonb` — agent-execute-kompatibel ✅
- `mcp_do_thing(args jsonb) RETURNS jsonb` — bara för raw HTTP MCP där hela payload kommer som ett jsonb-objekt ❌ för agent-execute

**Rule:** Skill-handlers MÅSTE peka på den första varianten. `mcp_*`-wrappers är
implementation-detalj för en separat MCP-server och får inte exponeras som
`agent_skills.handler`.

**Caught by:** `bun run lint:skills` (Layer 1 arg-mapping) + guardrail-test
`rpc-skill-arg-drift.guardrails.test.ts` efter `bun run scripts/snapshot-rpc-skill-args.ts`.

**Historisk fix (2026-05-08):** 7 skills (5 payroll + revalue_open_balances +
set_exchange_rate) pekade alla på `mcp_*`-wrappers och var helt obrukbara via
FlowPilot/MCP. Repointades till underliggande `p_*`-arg RPCs i samma migration.
