---
name: marketing-claw-department-pattern
description: Composite MCP group `marketing` + playbook som låter en extern claw köra hela paid-growth/content/research-loopen utan FlowPilot. Mall för fler department-claws (sales, operations).
type: feature
---

# Marketing Claw Department Pattern

En extern MCP-claw kan ta över ett helt funktionsområde i FlowWink utan att FlowPilot är aktiverad. Mönstret etablerat med "marketing" som första department.

## Composite groups (mcp-server)
`COMPOSITE_GROUPS` i `supabase/functions/mcp-server/index.ts`:
- `marketing` → growth + content + search + analytics + automation
- `sales` → crm + search + analytics + automation
- `operations` → commerce + analytics + automation

`?groups=marketing` expanderar via `resolveGroupTokens()` till underliggande kategorier. Visas i `/rest/groups` som `composite_groups[]` med live `tool_count`.

## Marketing-loopen (alla skills mcp_exposed=true, enabled=true)
1. `search_web` / `scrape_url` / `competitor_monitor` — research
2. `migrate_url` + `manage_page` — landing
3. `ad_campaign_create` (draft, kräver approval) — kampanj
4. `ad_creative_generate` — A/B-variants
5. `ad_performance_check` — metrics efter 24–72h
6. `ad_optimize` (analyze → act) — pause/scale/rebalance
7. `manage_blog_post` / `manage_kb_article` — rapport tillbaka

## Boundaries
- Budget-skills är `requires_approval=true` på DB-nivå — paid spend gatas alltid.
- Meta/Google Ads-API är INTE conf:at ännu. Skills jobbar mot interna tabeller (`ad_campaigns`, `ad_creatives`). När live-sync läggs till = ingen kontraktsändring för claws.
- FlowPilots peer-comms-skills (a2a_*, openclaw_*, dispatch_claw_mission) förblir ej-MCP — claws ÄR peers, behöver inte dispatcha till sig själva.

## Mall för nya departments
För att lägga till t.ex. `support` eller `hr` claw:
1. Lägg en rad i `COMPOSITE_GROUPS` med relevanta kategorier
2. Skriv playbook i `docs/agents/<dept>-claw-playbook.md`
3. Verifiera `/rest/groups` returnerar `tool_count > 0` för composite

## Filer
- `supabase/functions/mcp-server/index.ts` (rad ~213-245 COMPOSITE_GROUPS + resolveGroupTokens)
- `docs/agents/marketing-claw-playbook.md`
- `docs/modules/paid-growth.md`
