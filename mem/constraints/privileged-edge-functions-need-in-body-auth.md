# Privileged edge functions need in-body auth (NOT verify_jwt)

**Class (2026-07 security audit).** A function that (a) is deployed
`--no-verify-jwt` AND (b) runs privileged work with the **service-role client**
(RLS off) MUST authenticate the caller **in-body**, or it is an open,
RLS-exempt, internet-reachable endpoint. `verify_jwt=true` does NOT fix this —
the anon/publishable key is a valid JWT and passes it, so it's not an identity.

**Why in-body / why stay --no-verify-jwt.** Legit callers of the privileged
surface are exactly two: internal edge functions (send `Bearer
<SERVICE_ROLE_KEY>`) and the admin UI (sends the admin session JWT via
`functions.invoke` or a raw fetch of `supabase.auth.getSession().access_token`).
Neither is a plain user JWT flow, so the functions must remain `--no-verify-jwt`.

**The gate.** `supabase/functions/_shared/edge-auth.ts` →
`requireServiceOrRole(req, serviceClient, role='admin')`: accepts the service
key or a JWT resolving to `has_role(admin)`, rejects anon/publishable. 401 via
`unauthorized(corsHeaders)`. Reference inline gates: `newsletter/send`,
`signal-ingest`, `create-user`, and the inline gate in `agent-execute`.

**Fixed (9 functions gated):** agent-execute (was an unauthenticated universal
skill executor — CRITICAL), federation-invite-peer (anon minted `mcp:*` keys —
CRITICAL; + privilege clamp so a peer only grants groups it holds; + admin UI
now sends session JWT not anon key), field-service-skill, reconciliation,
subscriptions (skill path only — checkout/portal/manage keep their own auth),
agent-operate (+ frontend session JWT), ai-task (POST; GET discovery open),
survey-send, sales-profile-setup (company path).

**Guardrail:** `src/lib/__tests__/edge-auth-gate.guardrails.test.ts` asserts the
`MUST_BE_GATED` list keeps a gate. Add new privileged service-role functions to
that list.

**Gotcha that bit us:** the admin UI often sent `Bearer <PUBLISHABLE_KEY>` (the
public anon key) as "auth" — effectively unauthenticated. When gating a function
the admin UI calls via raw fetch, ALSO change the frontend to send
`(await supabase.auth.getSession()).access_token`. `functions.invoke` already
sends the session JWT automatically.

**NOT in scope (must stay open):** genuinely public functions — get-page,
content-api (anon client + RLS), stripe-webhook (signature-verified),
track-page-view, sitemap, llms-txt, blog-rss, and public form/newsletter/
booking submissions. Don't gate these.

## Remaining audit items (follow-up, lower severity)
- **Plaintext API keys at rest:** federation-invite-peer stores `key_raw` +
  `mcp_api_key` (cleartext) alongside the hash; openclaw-responses too. The auth
  path uses `key_hash`, so the cleartext is redundant exposure. Removing it needs
  care — a legacy peer-lookup path (`.eq('mcp_api_key', token)`) reads it.
- **PostgREST `.or()` filter injection:** agent-execute interpolates raw `search`
  args into `.or(\`email.ilike.%${search}%,...\`)` (lines ~930/1412/3094/4353/
  4931/7152/7658). Now behind the auth gate (service/admin only) so blast radius
  is small, but still worth escaping commas / rejecting filter metacharacters.
- **Raw DB errors to callers** on the now-gated functions — lower priority.
