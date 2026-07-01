# Flowtable Module

> Airtable-inspired flexible database. Bases → Tables → JSONB records, with CSV import/export and CRM mapping.

## Purpose

Flowtable gives operators (and agents) a schemaless-but-structured way to model
data that doesn't warrant a dedicated module. Think of it as "spreadsheets that
speak the platform" — every base/table is queryable by FlowPilot skills and can
map fields back into first-class CRM objects (leads, contacts, companies).

## Concepts

| Concept | Storage | Notes |
|---|---|---|
| **Base** | `flowtable_bases` | Top-level workspace (e.g. "Marketing 2026") |
| **Table** | `flowtable_tables` | A collection of records under a base. Owns a `columns` JSONB describing the schema. |
| **Record** | `flowtable_records` | JSONB `fields` bag. No column DDL — schema lives on the parent table. |
| **View** | derived | Filters/sorts applied client-side over records. |

Columns are typed (`text`, `number`, `date`, `select`, `checkbox`, `link`, `email`,
`phone`, `currency`). The renderer picks the right cell editor per type.

## UI

- `/admin/flowtable` — main workspace.
- **Bases panel** — collapsible left sidebar (minimizable to icon rail).
- **Table grid** — Airtable-style rows/cells with inline editing.
- **CSV Import / Export** — top-right per table. Auto-detects delimiter
  (`,` / `;` / `\t`) and quotes.
- **CRM mapping** — pick a record → "Convert to lead / contact / company" and
  map Flowtable columns to CRM fields once; mapping is remembered per table.

## Skills

Flowtable exposes MCP skills so agents can build tables and populate them
without human intervention (e.g. FlowPilot storing a lead-scoring experiment).
See `src/lib/modules/flowtable-module.ts` for the current seed list.

## File Map

| Purpose | Path |
|---|---|
| Module definition | `src/lib/modules/flowtable-module.ts` |
| Admin page | `src/pages/admin/FlowtablePage.tsx` |
| CSV import/export helpers | `src/lib/flowtable/csv.ts` |

## See also

- [Accounting Journal CSV](../../mem/features/accounting-journal-csv-integration.md) — same discreet CSV pattern reused in accounting journal entries.
