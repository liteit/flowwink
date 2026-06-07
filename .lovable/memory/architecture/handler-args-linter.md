---
name: Handler Args Linter
description: Static scan that catches the agent-execute _-prefix leak class of bugs across all edge functions
type: feature
---

`scripts/handler-args-lint.ts` — runs via `bun run lint:handler-args` (also part
of `lint:agent-contract` which combines it with the existing skill linter).

**What it catches:** any `.insert/.update/.upsert(...)` in `supabase/functions/`
that passes a raw or tainted args object straight to PostgREST. Without
stripping `_`-prefixed fields (`_caller_api_key_id`, `_caller_user_id`,
`_approved_operation_id`, `_seeded_session_id`), the write fails with
`Could not find the '_caller_api_key_id' column of '<table>' in the schema cache`
— exactly the KB-update bug that slipped past every existing test.

**Detection logic** (two rules):
1. `raw-arg-into-write` — bare `args` or `rest` passed directly: `.update(args)`.
2. `tainted-var-into-write` / `no-args-spread-into-write` — a variable whose
   initial value spreads `args`/`rest`, e.g. `const updates = { ...rest, updated_at }`,
   later passed to a write.

**Safe pattern** (what the linter approves): build a whitelisted object
key-by-key with `if (k.startsWith('_')) continue;` — see `executeKbAction`
update branch and `executeExpenseAction` update branch in `agent-execute/index.ts`.

**Inline opt-out:** put `// args-lint-ignore` within 6 lines above the violation
when the args really is an HTTP request body (not an agent-execute-injected
bag). Used in `supabase/functions/a2a/index.ts` for outbound activity logging.

**Run it before deploying any edge function change.** A clean sweep means no
new instances of this bug class were introduced.
