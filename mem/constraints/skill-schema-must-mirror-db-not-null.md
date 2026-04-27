---
name: skill-schema-must-mirror-db-not-null
description: All manage_* skills MUST expose AND mark as required (per action) every NOT NULL DB column without default; enforced by guardrail test
type: constraint
---

Every `manage_*` skill backed by `db:<table>`:

1. **MUST expose** all NOT NULL columns (without DB default) as `properties` in `tool_definition.function.parameters`.
2. **MUST mark them as `required`** for every write action (`create`, `insert`, `add`) — either at top-level `required` or inside an `allOf: [{ if: { properties: { action: { const: "create" } } }, then: { required: [...] } }]` branch.
3. **Exemption**: if a column is auto-filled by the handler (e.g. `user_id` from JWT, auto-generated `invoice_number`), list it under `_skill_auto_filled_columns.<skill_name>` in `src/lib/__tests__/fixtures/db-not-null-columns.json`.

**Why:** Hidden NOT NULL columns force MCP clients (FlowPilot, OpenClaw, Claude Code) to discover requirements via cryptic Postgres errors and guess undocumented param names — see `manage_document` regression where `file_url` and `file_name` were both NOT NULL but missing from the schema.

**Enforcement:** `src/lib/__tests__/skill-schema-not-null-coverage.guardrails.test.ts` runs in CI and validates both rules per skill × per write-action. Snapshot of NOT NULL columns lives in `db-not-null-columns.json` — regenerate with `bun run scripts/snapshot-db-not-nulls.ts` whenever schema changes.
