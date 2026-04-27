
# Workspace Chat — intern RAG-chat mot din FlowWink-data

En ny intern chatyta där inloggade admins/employees kan ställa frågor om sina egna dokument, kontrakt, KB-artiklar, leads, employees och pages. Använder samma AI-provider som extern chat (Integrations), men med interna källor och källhänvisningar i svaren. Ingen mutation — ren läs-RAG. FlowPilot förblir den autonoma operatören; Workspace Chat är "fråga-din-data".

## Mental modell

Tre tydliga ytor:

| Yta | Vem | Syfte | Mutation |
|-----|-----|-------|----------|
| AI Chat (`/chat`, ChatBlock) | Besökare | Försäljning, support, KB | Nej |
| **Workspace Chat (NY)** | **Inloggad admin/employee** | **Fråga din interna data** | **Nej** |
| FlowPilot (`/admin/flowpilot`) | Admin (när modul på) | Autonom operatör | Ja |

## Vad som byggs

### 1. Ny route + sida
- `/admin/workspace` (eller `/admin/cowork`) — auth-krävd, registreras i `App.tsx` + `adminNavigation.ts`
- Layout: vänster sidopanel (källfilter + tidigare konversationer), centerpanel (chat), höger drawer (citerade källor för senaste svar)
- Återanvänder `UnifiedChat`-komponenten med ny `scope: 'internal'`

### 2. Ny edge function `workspace-chat`
- Verifierar JWT (admin/employee-roll via `has_role`)
- Tar emot `messages[]`, `sources[]` (filter), `conversation_id`
- Bygger CAG-kontext genom att läsa internt:
  - **Documents** (signed URL-titlar + notes + senaste 30)
  - **Contracts** + **employment_contracts** (status, parter, renewal-datum)
  - **Knowledge base articles** (titel + excerpt)
  - **Pages** (titel + slug + summary)
  - **Leads / Deals / Employees** (top-N senaste, namn + status)
- Anropar `resolveAiConfig()` → samma provider som extern chat
- Streamar SSE tillbaka via samma pattern som `chat-completion`
- Returnerar `citations[]` separat så UI kan visa källor

### 3. Källfilter (chips i UI)
Toggla av/på vad som inkluderas i context: `Documents`, `Contracts`, `KB`, `Pages`, `CRM`, `Employees`. Skickas som `sources` till edge function.

### 4. Konversationer & historik
Återanvänd `chat_conversations` + `chat_messages` med ny kolumn:
- `chat_conversations.scope` (text, default `'visitor'`, ny värde `'internal'`)
- RLS: `internal`-konversationer syns bara för inloggade admins/employees och bara egna (`user_id = auth.uid()`)

### 5. Källhänvisningar i svar
- Edge function bygger en `sources_index` (`[{id, type, title, url}]`) av allt som skickas in i prompt
- Modellen instrueras att referera med `[1]`, `[2]` etc.
- UI renderar referenser som klickbara chips → öppnar dokument/kontrakt/KB i ny panel eller route

### 6. CAG nu, RAG senare
- **v1 (denna plan):** CAG — packa in top-N entiteter direkt i system-prompt. Räcker för små/medelstora deployments.
- **v2 (framtida):** pgvector embeddings på `documents.content`, `contracts.notes`, `kb_articles.body` när datavolymen kräver det. Koden struktureras så `buildContext()` är en bytbar funktion.

### 7. Inga skills, inga mutationer
- Workspace Chat anropar **inte** `agent-execute`
- Inga tool calls
- Användaren vill ändra data → öppnar respektive admin-sida (länk i citat-chip)
- Vill man ha mutationer → slå på FlowPilot-modulen

## Tekniska detaljer

**Filer som skapas:**
- `supabase/functions/workspace-chat/index.ts` — ny edge function (CAG + SSE-stream)
- `supabase/migrations/<timestamp>_workspace_chat.sql` — `ALTER TABLE chat_conversations ADD COLUMN scope text DEFAULT 'visitor'` + RLS-update
- `src/pages/admin/WorkspaceChatPage.tsx` — sidlayout
- `src/components/admin/workspace/SourceFilterPanel.tsx` — vänsterpanel
- `src/components/admin/workspace/CitationsDrawer.tsx` — högerpanel
- `src/hooks/useWorkspaceChat.ts` — egen hook (kopia av `useChat` med scope=internal + citations state)
- `src/lib/modules/workspace-chat-module.ts` — modul-manifest (per [New Module Checklist](mem://development/new-module-checklist))
- `docs/modules/workspace-chat.md` — modul-docs (manuell)
- `mem://features/workspace-chat-internal-rag.md` — memory

**Filer som ändras:**
- `src/App.tsx` — ny route
- `src/components/admin/adminNavigation.ts` — ny nav-entry "Workspace" med `moduleId: 'workspace-chat'`
- `supabase/config.toml` — ingen ändring krävs (`verify_jwt=false` default, vi validerar i kod)

**Edge function flow (workspace-chat):**
```text
1. CORS + OPTIONS
2. Validera JWT → user_id, role (admin/employee?)
3. Parse body: { messages, sources[], conversation_id }
4. buildContext(supabase, user_id, sources) → { systemPromptAddon, citations[] }
5. resolveAiConfig() → { apiKey, apiUrl, model }
6. Skicka till provider med stream:true
7. Pipe SSE tillbaka, prepend ett första event med citations
```

**RLS för internal-conversations:**
```sql
CREATE POLICY "Users see own internal conversations"
ON chat_conversations FOR SELECT TO authenticated
USING (scope = 'internal' AND user_id = auth.uid());
```

**Modulens manifest:**
- `id: 'workspace-chat'`, `requiresAI: true`, `requiresFlowPilot: false`, `enhancedByFlowPilot: false`
- `skillSeeds: []` — modulen exponerar inga skills (det är en human-only yta)
- Slås av/på som vanlig modul; UI gracefully degraderar med upsell när AI saknas

## Vad som INTE ingår (medvetet)

- Inga embeddings/pgvector i v1 (CAG först)
- Ingen tool calling / mutation
- Ingen multi-user delning av konversationer
- Ingen integration med FlowPilot-objectives — separat yta
- Ingen voice input i v1 (kan läggas till senare med samma pattern som extern chat)

## Glide-path till framtid

- **När FlowPilot är på:** lägg till en "Agent mode"-toggle på Workspace Chat som growth-path. Av = ren RAG. På = full agent (samma UI, byter bara endpoint till `chat-completion` + skills aktiverade).
- **När data växer:** byt ut `buildContext()` mot pgvector-search, behåll allt annat.
- **Multi-modal:** lägg till PDF-uppladdning i chatten → docs-modulen → automatiskt indexerat.

## Acceptance criteria

- [ ] Ny route `/admin/workspace` syns i admin-nav när modulen är på
- [ ] Inloggad admin kan ställa fråga om existerande dokument och få svar med citation
- [ ] Källfilter ändrar vad som skickas i context (verifierbart i edge function logs)
- [ ] Konversationer sparas med `scope='internal'` och syns i sidopanelen
- [ ] Fungerar med OpenAI, Gemini OCH Local LLM (samma `resolveAiConfig` som extern chat)
- [ ] Modul kan slås av → sida gracefully redirectar / upsell
- [ ] FlowPilot förblir orörd och fortsätter fungera oberoende
- [ ] `docs/modules/workspace-chat.md` skriven, memory sparad

Säg till om du vill justera scope (t.ex. börja bara med Documents+Contracts+KB i v1 och utöka leads/employees senare), annars kör jag på hela paketet ovan när du godkänner.
