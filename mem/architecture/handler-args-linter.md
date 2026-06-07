---
name: Handler Args Linter
description: Static scan that catches the agent-execute _-prefix leak class of bugs across all edge functions
type: feature
---

`scripts/handler-args-lint.ts` — run via `bun run lint:handler-args` (or
`lint:agent-contract` to combine with the existing skill linter).

**What it catches:** any `.insert/.update/.upsert(...)` in `supabase/functions/`
that passes a raw or tainted agent-args object straight to PostgREST. Without
stripping `_`-prefixed fields (`_caller_api_key_id`, `_caller_user_id`,
`_approved_operation_id`, `_seeded_session_id`), the write fails with
`Could not find the '_caller_api_key_id' column of '<table>' in the schema cache`
— the silent KB-update bug that slipped past every existing test.

**Detection logic** (two rules):
1. `raw-arg-into-write` — bare `args` or `rest` passed directly: `.update(args)`.
2. `tainted-var-into-write` / `no-args-spread-into-write` — a variable whose
   initial value spreads `args`/`rest`, e.g. `const updates = { ...rest, updated_at }`,
   later passed to a write.

**Safe pattern** the linter approves: build a whitelisted object key-by-key
with `if (k.startsWith('_')) continue;` — see `executeKbAction` update and
`executeExpenseAction` update branches in `agent-execute/index.ts`.

**Inline opt-out:** `// args-lint-ignore` within 6 lines above the violation,
for cases where `args` is a raw HTTP request body (not an agent-execute bag).
Used in `supabase/functions/a2a/index.ts` outbound activity logging.

**Run before deploying any edge function change.** A clean sweep means no new
instances of this bug class slipped in.
