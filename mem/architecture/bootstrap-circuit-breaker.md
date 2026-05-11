---
name: Bootstrap Circuit Breaker
description: bootstrap_runs-tabell + 3-strikes degraded state förhindrar oändliga repair-loopar och gör module-bootstrap observerbar
type: feature
---

`module-bootstrap.ts` skriver varje körning till `bootstrap_runs` (module_id, status, errors, config_hash, duration_ms, triggered_by). 

**Circuit breaker:** `bootstrapModule()` anropar `get_bootstrap_health(module)` SECURITY DEFINER-RPC innan körning. Om `failure_streak >= 3` → returnerar `{ degraded: true }` utan att köra. Admin kan tvinga retry via `bootstrapModule(id, modules, { force: true })` eller "Force retry"-knappen i toast.

**UI:** `BootstrapHealthCard` (i `ModuleDetailSheet` → right panel) visar senaste 5 körningarna per modul + degraded-badge. `ReBootstrapButton` invaliderar `['bootstrap-runs', moduleId]` + `['bootstrap-health', moduleId]` queries efter körning.

**Config hash:** SHA-256 av sorterade skill+automation-namn (16 tecken). Drift mellan kod och DB syns som hash-mismatch i historiken.

Tester: `src/lib/module-bootstrap.test.ts` (4 tester — success record, degraded-blockering, force override, empty-history defaults).
