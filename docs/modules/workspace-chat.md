# Workspace Chat

Internal authenticated chat for admins and employees to ask questions about
their own FlowWink data — documents, contracts, KB, pages, CRM and HR.

## What it is

| Surface | Audience | Purpose | Mutates data? |
|---------|----------|---------|---------------|
| AI Chat (`/chat`, `ChatBlock`) | Public visitors | Sales / support / KB lookup | No |
| **Workspace Chat (`/admin/workspace`)** | **Admin / employee** | **Fact-finding across internal data** | **No** |
| FlowPilot (`/admin/flowpilot`) | Admin (when on) | Autonomous operator | Yes |

Workspace Chat is intentionally **read-only**. If you want autonomous
mutations (assign leads, send emails, trigger workflows), enable FlowPilot.

## How it works

1. User opens `/admin/workspace` (auth required, admin/employee/manager role).
2. Selects which sources to ground answers in (Documents, Contracts, KB,
   Pages, CRM, Employees).
3. Sends a question.
4. Frontend calls `workspace-chat` edge function with their JWT.
5. Edge function:
   - Verifies the JWT and the user's role.
   - Builds a CAG (Context-Augmented Generation) prompt from the selected
     sources, packing top-N entities directly into the system message.
   - Calls the AI provider configured under **Integrations** (OpenAI,
     Gemini or Local LLM) using the same `resolveAiConfig()` helper that
     powers the public AI Chat.
   - Streams the response back as SSE, prepending one `event: citations`
     frame so the UI can show source chips alongside the answer.
6. UI renders the streaming markdown answer and the citations drawer.

## Architecture

- **Page**: `src/pages/admin/WorkspaceChatPage.tsx`
- **Hook**: `src/hooks/useWorkspaceChat.ts` (SSE parser + history state +
  custom `event: citations` handling)
- **Components**:
  - `src/components/admin/workspace/SourceFilterPanel.tsx`
  - `src/components/admin/workspace/CitationsDrawer.tsx`
- **Edge function**: `supabase/functions/workspace-chat/index.ts`
- **Module manifest**: `src/lib/modules/workspace-chat-module.ts` (id:
  `workspaceChat`, no skills, no MCP exposure)
- **DB**: `chat_conversations` gained a `scope` column (`'visitor'` |
  `'internal'`) and a `user_id` FK; RLS policies restrict `internal` rows
  to the owning user.

### Why no skills?

Per the [Skill Generalization Principle](../../mem/philosophy/skill-generalization-principle.md)
and the [AI Utility vs Skill](../../mem/architecture/ai-utility-vs-skill-classification.md)
contract, Workspace Chat is a **utility surface** — it transforms structured
data into a natural-language answer. It performs no business operations,
so it registers no skills and is not exposed via MCP. FlowPilot (when
enabled) keeps its full skill catalog as the autonomy layer.

## CAG today, RAG tomorrow

v1 packs top-N records of each source type (limit 25 each) directly into
the prompt. This works well for small/medium deployments.

When data volumes grow, swap `buildContext()` in `workspace-chat/index.ts`
for a pgvector similarity search over `documents.content`,
`contracts.notes`, and `kb_articles.body`. The interface (sources →
`{ contextText, citations }`) stays identical.

## Operating notes

- Anthropic provider is **not** supported in v1 (different API shape).
  Use OpenAI, Gemini or Local LLM.
- The function uses the service-role client to read across all tables,
  but only after explicitly verifying the caller has `admin`, `employee`
  or `manager` in `user_roles`.
- Citations are rendered as `[N]` references the model is instructed to
  use; the side panel maps each `[N]` back to the source record.
- The module gracefully degrades — if disabled the page shows an upsell
  card linking to `/admin/modules`.
