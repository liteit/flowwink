---
name: Workspace Chat — internal RAG/CAG
description: Authenticated chat for admins/employees that answers questions about FlowWink data (documents, contracts, KB, CRM, HR) with source citations. Read-only utility, parallel to public AI Chat and FlowPilot.
type: feature
---

Workspace Chat is a third chat surface alongside public **AI Chat** and
**FlowPilot**. It lives at `/admin/workspace` and is gated by the
`workspaceChat` module.

## Boundaries (do NOT cross)

- **Read-only.** No tool calls, no mutations. If a user asks to change
  something, the model points them to the relevant admin page.
- **Authenticated only.** Edge function `workspace-chat` requires a valid
  JWT and verifies `admin` / `employee` / `manager` in `user_roles`
  before exposing any internal data.
- **No skill registration.** This is a utility per
  [AI Utility vs Skill](mem://architecture/ai-utility-vs-skill-classification);
  FlowPilot owns business operations.

## Provider routing

Uses the shared `resolveAiConfig()` helper in
`supabase/functions/_shared/ai-config.ts` — same provider as the public
AI Chat (OpenAI / Gemini / Local LLM). Anthropic is not yet supported.

## DB contract

`chat_conversations.scope text NOT NULL DEFAULT 'visitor'` constrained to
`('visitor', 'internal')`. `internal` rows are owned by `user_id =
auth.uid()` with mirror policies on `chat_messages` via the parent
conversation.

## RAG path

v1 = CAG (top-25 records per selected source packed into system prompt
with `[N]` citation markers). Future v2 swaps `buildContext()` for
pgvector search without touching the rest of the stack.
