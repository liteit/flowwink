## Goal

Inkommande mail i Composio-kopplad Gmail-låda → automatiskt ticket (eller comment på befintligt ticket). Realtid via Gmail Watch (push), inte polling. V1 = en delad "Flowwink-låda", arkitektur klar för flera konton.

## Arkitektur

```text
Gmail (Composio-connected account)
   │ push (Pub/Sub → Composio webhook)
   ▼
composio-webhook  ← NY edge function (publik, ingen JWT)
   │ för varje nytt message_id:
   │   1. Hämta meddelandet via composio-proxy (gmail_get)
   │   2. Bygg payload (from, subject, body, headers, account_id)
   │   3. Emit agent_event 'email.received'
   ▼
event-dispatcher (finns redan)
   │ fan-out till automations med trigger='email.received'
   ▼
automation: email_received → call_skill 'email_to_ticket'
   │
   ▼
email_to_ticket skill (NY, agent-execute handler)
   ├─ Om In-Reply-To/References matchar tickets.metadata.gmail_thread_id
   │   → append ticket_comments
   └─ Annars → INSERT tickets (source='email', source_id=message_id,
                metadata={ gmail_thread_id, gmail_message_id,
                          composio_account_id, from, to })
```

## V1 scope (det vi bygger nu)

1. **Schema** — lägg till `inbound_email_accounts` (planerar för flera konton, V1 har 1 rad)
2. **Edge function `composio-webhook`** — tar emot Composio Pub/Sub-events, idempotent på message_id, emittar `email.received`
3. **composio-proxy** — utöka med:
   - `gmail_watch` (registrerar Gmail Watch på connected account)
   - `gmail_get` (hämta enskilt meddelande med full body + headers)
4. **Skill `email_to_ticket`** — handler i agent-execute, threading via `In-Reply-To`/`References`
5. **Skill `reply_to_ticket_via_email`** — använder composio-proxy `gmail_send` med korrekta threading-headers
6. **Automation** seedad i `emailModule`: trigger=`email.received` → action=`call_skill: email_to_ticket` (default enabled, kan stängas av per site)
7. **UI**:
   - `/admin/integrations` Composio-drawer → ny "Inbound" sektion: visar konfigurerat konto, "Aktivera Gmail Watch"-knapp, status (last received, watch expires_at)
   - `/admin/tickets` — visa kanal-badge ("Email") + ev. öppna originalmail
8. **MCP** — båda nya skills exponerade med `mcp_exposed=true`

## V2-redo (planeras, byggs inte nu)

- Per-user inboxes: `inbound_email_accounts.user_id` finns redan i schema, UI för "koppla min Gmail" kommer i V2
- Smart classifier (`classify_inbound_email` → ticket/lead/ignore) — V1 = allt blir ticket, men automationen är conditional-redo
- Gmail Watch auto-renewal cron (Watch expires efter 7 dagar) — V1 = manuell renew, V2 = daglig cron

## Tekniska detaljer

### Schema: `inbound_email_accounts`
```sql
CREATE TABLE public.inbound_email_accounts (
  id uuid PK default gen_random_uuid(),
  provider text NOT NULL DEFAULT 'composio_gmail',
  composio_account_id text,           -- Composios connected_account_id
  email_address text NOT NULL,         -- info@flowwink.com
  user_id uuid REFERENCES auth.users,  -- NULL för delad företagslåda (V1)
  is_shared boolean NOT NULL DEFAULT true,
  watch_expires_at timestamptz,
  last_history_id text,
  last_received_at timestamptz,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
-- GRANT + RLS: authenticated SELECT, service_role ALL
```

### Tickets — INGEN schemaändring
Allt threading-state ligger i befintlig `metadata jsonb`:
- `metadata.gmail_thread_id`
- `metadata.gmail_message_id`
- `metadata.composio_account_id`
- `metadata.from_email`

`source='email'`, `source_id=<gmail message_id>` finns redan.

### Composio Gmail Watch
```
POST composio-proxy { action: 'gmail_watch', params: { account_id, topic_name } }
→ Composio v3: /api/v3/connected_accounts/{id}/actions/GMAIL_WATCH_USER
```
Composio hanterar Pub/Sub-topic + webhook-leverans åt oss. Vi behöver bara ge dem en callback-URL = vår `composio-webhook`.

### Idempotens
`composio-webhook` slår upp `tickets` på `(source='email' AND source_id=message_id)` innan insert. Composio kan leverera samma event flera gånger.

### Auth
- `composio-webhook` = publik (Composio kallar utifrån). Signaturverifiering med shared secret från Composio webhook config (lagras som `COMPOSIO_WEBHOOK_SECRET`).
- Alla andra anrop går via befintlig service-role i edge functions.

## Filer som påverkas

**Nya:**
- `supabase/migrations/<ts>_inbound_email_accounts.sql`
- `supabase/functions/composio-webhook/index.ts`
- Skill seeds i `src/lib/modules/email-module.ts` (email_to_ticket, reply_to_ticket_via_email)

**Ändras:**
- `supabase/functions/composio-proxy/index.ts` — lägg till `gmail_watch` + `gmail_get`
- `supabase/functions/agent-execute/index.ts` — handlers för nya skills
- `src/components/admin/modules/ComposioPanel.tsx` — Inbound-sektion
- `src/lib/modules/email-module.ts` — automation seed
- `src/components/admin/tickets/*` — kanal-badge

## Out of scope

- Klassificering (allt blir ticket i V1)
- Per-user inbox-UI
- Watch auto-renewal cron
- Bilagor (V1 ignorerar attachments, bara text/html-body till ticket.description)
- Outgoing reply via Gmail från ticket-UI (skill finns, knapp i ticket-detail kommer i V2)
