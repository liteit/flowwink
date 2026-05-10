---
name: ai-task pattern (Klass 2a — context-aware AI skills, FlowWink SaaS layer)
description: Skills med handler `ai-task:<name>` är intelligenta endpoints i FlowWink SaaS. De laddar DB-context, kör en strukturerad LLM tool-call och skriver tillbaka. Inte FlowPilot-beroende — kallbara från UI, automations (executor=platform), MCP, eller FlowPilot.
type: design
---

# `ai-task:` — Klass 2a AI-skills (FlowWink SaaS)

## Vad det är

`ai-task:<name>` är ett handler-prefix i `agent-execute` som routar till `supabase/functions/ai-task/`. Varje task = en `TaskSpec` i `ai-task/tasks.ts` med:

- `inputSchema` (zod) — validera caller-args
- `load(input, supabase)` — hämta DB-context (entity-rader, KB-index, m.m.)
- `system` / `user` — promptbyggare som får merged input + loaded context
- `tool` — strukturerad output via tool-calling (alltid att föredra över JSON-mode)
- `apply(input, result, supabase)` — skriv tillbaka till DB
- `tier` — `fast` / `reasoning` / `multimodal` (resolveAiConfig väljer modell)

## Lagerplacering

| Lager | Vad det är | Behöver FlowPilot? |
|---|---|---|
| **Klass 1 — Utility** (text-transforms via `chat-completion`) | LLM utan business-context | Nej — alltid på |
| **Klass 2a — `ai-task:` skill** | LLM + Flowwink-data, deterministisk in/ut, EN tool-call | **Nej** — SaaS, MCP-exposed |
| **Klass 2b — Operator reasoning** (heartbeat, objectives, multi-step ReAct) | LLM som driver sig själv över tid | Ja — FlowPilot |

## Konsumenter

Samma `ai-task:` skill kan kallas av:
- En knapp i admin-UI (`/admin/tickets` → "AI-triagea")
- En automation (`executor='platform'`, `trigger=ticket.created`)
- Extern MCP-klient (OpenClaw, Claude Desktop, ClawWink)
- FlowPilot (om aktiverad) som ett verktyg i sin större plan

Alla får samma resultat. Ingen specialväg för FlowPilot.

## Konventioner

1. **`apply` är idempotent** — kör flera gånger ⇒ samma slutläge.
2. **`load` är defensiv** — kasta om entity inte finns. Aldrig "fail forward" på saknad input.
3. **Filtrera modell-output mot DB i `apply`** — modellen kan hallucinera ids; verifiera mot kända värden (se `ticket_triage` filtrering av `suggested_kb_article_ids`).
4. **Aldrig intent-routing i task-registret** (Lag 1). Caller anropar explicit task-namn.
5. **Skill-seed registreras i modulen** med `handler: 'ai-task:<name>'`, `category: '<närmsta domän-kategori>'`, `scope: 'both'`, `trust_level: 'auto'` för läs-task / `'notify'` för skrivtask.

## Befintliga tasks (2026-05)

- `score_candidate` — Recruitment, scorar kandidat mot job posting, skriver tillbaka.
- `analyze_receipt` — Expenses, OCR + kategorisering av kvitto-bild.
- `qualify_lead_summary` — CRM, 1-2 meningars engagement-sammanfattning.
- `generate_blog_from_webinar` — Webinars, drar webinar-metadata, skapar blog-draft.
- `ticket_triage` — Tickets, klassificerar priority/category, kopplar KB-artiklar.

## Mall för nästa ai-task

```ts
// 1. tasks.ts
const xInput = z.object({ entity_id: z.string().uuid() });
const xTask: TaskSpec<z.infer<typeof xInput>, any> = {
  name: "x",
  description: "...",
  tier: "fast",
  inputSchema: xInput,
  load: async (input, supabase) => { /* hämta entity + context */ },
  system: () => `...`,
  user: (input) => `## Entity\n${JSON.stringify(input.entity)}`,
  tool: { name: "submit_x", description: "...", parameters: { /* JSON schema */ } },
  apply: async (input, result, supabase) => { /* skriv tillbaka */ },
};
TASKS.x = xTask;

// 2. modul-fil — skillSeeds-array
{
  name: 'x',
  handler: 'ai-task:x',
  category: '<domän>',
  scope: 'both',
  trust_level: 'auto', // eller 'notify' om skriver känsliga fält
  tool_definition: { /* MCP-tool def med entity_id */ },
}
```

Se även: `mem://architecture/ai-utility-vs-skill-classification`, `mem://architecture/flowpilot-as-optional-operator-layer`, `mem://architecture/platform-modules-operators-layering`.
