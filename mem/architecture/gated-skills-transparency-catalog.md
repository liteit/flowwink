---
name: Gated Skills Transparency Catalog
description: /admin/approvals → Gated Skills tab listar alla agent_skills med trust_level approve/notify, grupperar per ägande modul från defineModule()-registret, och visar pending + 30d användning per skill
type: feature
---

`useGatedSkills` joinar `agent_skills` (där trust_level IN ('approve','notify')) med `getAllUnifiedModules()` från `module-def.ts`. Skills upptäcks via `module.skills[]` ELLER `module.skillSeeds[].name`.

**Kritiskt för transparens:** Om en gated skill seedas direkt via SQL-migration (utan `skillSeeds[]`) MÅSTE den ändå deklareras i modulens `skills[]`-array för att ägarskap ska visas i UI:t. Annars hamnar den under "— Core / unowned —" med orphan-varning.

Exempel som följt detta mönster:
- `expenses` → declarear `approve_expense_report`, `book_expense_report`, `mark_expense_report_paid` i `skills[]` (seedade via migration per Full Record-to-Report Skill Coverage)
- `companies` → `update_company_profile`
- `globalBlocks` → `manage_global_blocks`
- `hr` → `auto_allocate_vacation`

UI sorterar "Core / unowned" först så orphans är omedelbart synliga. Räknare visar approve/notify/total + amber-varning vid orphans.
