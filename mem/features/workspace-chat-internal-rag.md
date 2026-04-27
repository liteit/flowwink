---
name: Cowork Chat — blended internal assistant
description: Authenticated /admin/workspace chat (module id `workspaceChat`, brand "Cowork Chat") that blends workspace CAG (docs, contracts, KB, pages, CRM, HR) with the model's own knowledge and optional Firecrawl web_search. Two modes — 'cowork' (default) blends all three; 'strict' refuses anything not in workspace data. Settings live in site_settings.cowork_chat.
type: feature
---

Cowork Chat is the third chat surface alongside public **AI Chat** and
**FlowPilot**. Lives at `/admin/workspace`, gated by module `workspaceChat`.
The internal id is **kept** for backward compat — only the user-facing brand
changed from "Workspace Chat" → "Cowork Chat".

## Modes

- **cowork** (default): grounds in workspace context first, then may use
  the model's training knowledge AND a `web_search` tool (Firecrawl).
  Workspace facts cited with `[N]`, web results as markdown links.
- **strict**: refuses anything not in the workspace context. No world
  knowledge, no web search. Use for compliance-sensitive deployments.

## Settings (`site_settings.cowork_chat`)

```json
{
  "mode": "cowork" | "strict",
  "allowWorldKnowledge": true,
  "allowWebSearch": true,
  "defaultSources": ["documents","contracts","kb","pages","crm","employees"]
}
```

UI: `<CoworkSettingsPanel/>` opens a Sheet on the page header. Per-conversation
source toggles live in the left panel and don't override saved defaults.

## Edge function contract

`POST /functions/v1/workspace-chat` (name unchanged):
```json
{ "messages": [...], "sources": [...], "mode": "cowork" | "strict" }
```
Returns SSE: first frame is `event: citations\ndata: [...]`, then
OpenAI-style `data: {choices:[{delta:{content}}]}` chunks. When tool calls
are needed, the function does a non-streaming tool loop (max 2 rounds) and
emits the final answer as a single SSE delta to keep the client parser
identical.

## Web search

Reuses `firecrawl-search` edge function. Tool description tells the model
to use it ONLY when the answer isn't in the workspace context. Disabled
automatically if `FIRECRAWL_API_KEY` is missing, regardless of the setting.

## Boundaries (unchanged)

- Read-only — no skills, no MCP, no mutations.
- Auth-gated — admin/employee/manager required.
- Per [AI Utility vs Skill](mem://architecture/ai-utility-vs-skill-classification),
  this is a utility surface — FlowPilot still owns business operations.
