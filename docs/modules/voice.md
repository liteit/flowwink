# Voice Module

Inbound + outbound voice calls via pluggable providers (46elks native, Twilio stub,
Telnyx/Vonage planned) plus an AI receptionist (Gemini Live) for after-hours.

## Use cases

| # | Status agent | Visitor action | System response |
|---|---|---|---|
| 1 | Inloggad + voice_enabled | Ringer | WebRTC ringer i admin (`Softphone.tsx`, JsSIP mot 46elks WSS) → agent svarar → samtal bryggas via SIP |
| 2 | Inloggad men upptagen / svarar ej inom timeout | Ringer | Voicemail: greeting → record → missed-call-kö → manuell callback |
| 3 | Utloggad (alla agenter offline) + AI receptionist av | Ringer | Samma som UC2 |
| 4 | Utloggad (alla agenter offline) + AI receptionist på | Ringer | Gemini Live svarar. Tools preview kan boka via booking-skills; om tools-modellen nekas faller samtalet tillbaka till native-audio och sparas som callback request. |

## Arkitektur

Modulen är **provider-agnostisk**. Adapter-kontraktet `VoiceProvider` (i `src/lib/voice-providers/types.ts`) gör att samma UI, routing, voicemail-kö och callback-flöde fungerar med valfri provider.

```
incoming call ──► provider (46elks/Twilio) ──► POST /voice-ingest
                                                    │
                                                    ▼
                                       parseIncoming() normaliserar
                                                    │
                                                    ▼
                                       decideAction() läser support_agents
                                                    │
                                          ┌─────────┼─────────┐
                                          ▼         ▼         ▼
                                       SIP-bridge  Forward   Voicemail
                                       (WebRTC)   (mobil)   (record)
                                                    │
                                                    ▼
                                       persistCall() → voice_calls
                                                    │
                                                    ▼
                                       serializeAction() → provider-format
```

### Inbyggda providers

| Provider | Regioner | WebRTC | Status |
|---|---|---|---|
| `elks46` | SE/DK/FI/NO/UK | ✅ native SIP-WSS | implementerad |
| `twilio` | global | ✅ Voice JS SDK | stub (kontrakt bevisad) |
| `telnyx` | global | ✅ | planerad |
| `vonage` | global | ✅ | planerad |

Lägg till ny provider genom att skapa `src/lib/voice-providers/<id>.ts` som implementerar `VoiceProvider`, registrera den i `src/lib/voice-providers/index.ts`, och lägg till provider-grenen i `supabase/functions/voice-ingest/index.ts`.

## Database

- `voice_calls` — call log (en rad per samtal, oavsett provider)
- `support_agents.voice_enabled` — agent vill ta voice-samtal
- `support_agents.voice_sip_username/password/uri` — SIP-credentials för WebRTC-klienten
- `support_agents.voice_mobile_number` — fallback för forward-to-mobile när SIP saknas
- `support_agents.voice_provider` — vilken adapter agenten är registrerad mot

## Skills

- `list_voice_calls` — filtrera på status/direction/callback_status
- `schedule_voice_callback` — planera in återuppringning
- `mark_voice_callback_done` — markera callback som klar

Alla MCP-exponerade och provider-agnostiska (skill-koden bryr sig inte om vilken provider som ligger bakom).

## Edge functions

**+1 ny:** `voice-ingest` — hanterar alla callbacks från alla providers (parsing, routing-beslut, persistence, serialisering).

Återanvänder:
- `chat-completion` — voicemail-transkription via OpenAI/Gemini/local provider through `ai-call.ts`
- `event-dispatcher` — fan-out av `voice.call.received` / `voice.call.missed` events
- `agent-execute` — generic CRUD för `voice_calls` via skills

## Decoupling från Live Support

Voice-modulen **importerar inte** live-support och vice versa. Kommunikation sker via platform event bus:

- Voice emittar `voice.call.received`, `voice.call.missed`, `voice.voicemail.recorded`
- Live Support kan lyssna för att visa i agent-dashboard
- Om voice-modulen är av → inga events → live-support funkar oförändrat

## Fas-plan

**Fas 1 (klar):**
- Schema (`voice_calls`, `support_agents.voice_*`), modul-registrering
- Edge function `voice-ingest` (provider-agnostisk router)
- 46elks-adapter (komplett), Twilio-stub
- 3 MCP-skills (`list_voice_calls`, `schedule_voice_callback`, `mark_voice_callback_done`)
- **Admin-UI `/admin/voice`** med 5 tabs: All / Missed / Voicemail / Callbacks / Settings
- Provider-väljare, ring-timeout, voicemail-greeting, AI receptionist settings
- Call-detalj-dialog: lyssna på recording/transkript, schemalägg callback, markera klar, `tel:` call-back

**Fas 2 (klar):**
- Browser WebRTC-klient i admin (`Softphone.tsx`, JsSIP mot 46elks WSS) — knapp i sidebar för agent som är voice_enabled. Se [`voice-softphone.md`](./voice-softphone.md).
- Voicemail-transkription via STT (`chat-completion` / `ai-call.ts`).
- Voicemail-audio proxy via `voice-recording` edge function (injicerar 46elks Basic Auth server-side så `<audio>` inte får login-popup).
- Callback-flöde: `voice_calls.callback_status` (`pending` → `scheduled` → `completed`) + admin-UI-tab i Live Support.
- Master switch `smsReplyEnabled` styr all utgående SMS (voicemail-reply, callback-notiser).

## AI Receptionist (Gemini Live)

När alla agenter är offline och receptionist är på tar Gemini Live över samtalet
via WebSocket-brygga från 46elks (`voice-ingest`). Två drift-lägen väljs i
`/admin/voice` → Settings:

| Mode | Model | Tools | Beteende |
|---|---|---|---|
| **Native audio** | `models/gemini-2.5-flash-native-audio-latest` | ❌ | Bäst röst/språkkvalitet på svenska. Kan inte boka — instrueras att samla info och lova återuppringning. |
| **Half-cascade (live tools + fallback)** | `models/gemini-3.1-flash-live-preview` | ✅ | Har `lookup_customer_by_phone`, `browse_services`, `check_availability`, `book_appointment`. Om Google stänger WS (1007/1008) återansluter bryggan mot native-audio-modellen så samtalet inte tappas. |

Rekommenderat val i UI: **Half-cascade — Live tools with native-audio fallback**.

### Digital Secretary-pattern

Systempromptet instruerar agenten att först försöka lösa ärendet (info,
bokning, kundlookup). Först om ett tool-call misslyckas eller inte finns
erbjuds återuppringning. Alla AI-hanterade samtal flaggas automatiskt med
`callback_status='pending'` så admin kan review i Callbacks-tabben — även om
booking gick igenom (för kvalitetsuppföljning under MVP).

### Live transcript & summering

`voice-ingest` skriver kontinuerligt in transkriberade turns i
`voice_calls.live_transcript` och genererar en `ai_summary` när samtalet slutar
(fallback: sista N turns om Gemini inte returnerar summary-token). Visas i
`VoicePage.tsx` → call detail.

### Kontext till agenten

Agenten får per samtal: `first_greeting`, systemprompt (identity + språkregler +
mode-specifika instruktioner om tools/callback), och caller ID (A-nummer).
Business identity kommer från `company_profile` (default: *Flowwink Business
Operating System*).

### Kända begränsningar / backlog

- Tool-calling på Gemini Live `v1beta` är instabilt — därför fallback-loopen.
- Provider-agnostisk routing: mycket 46elks-specifik logik ligger idag i
  `voice-ingest`. Ska flyttas till adaptern under Fas 3. Se
  [`.lovable/memory/backlog/voice-agent-routing-provider-abstraction.md`](../../.lovable/memory/backlog/voice-agent-routing-provider-abstraction.md).
- Gemini credits/quota-visibility i integrations-vyn — backlog.

**Fas 3:**
- Multi-provider realtime voice (OpenAI Realtime som alternativ till Gemini).
- Twilio adapter full implementation.
- Telnyx, Vonage adapters.
- Provider-agnostisk agent-routing (flyttas ur `voice-ingest`).

