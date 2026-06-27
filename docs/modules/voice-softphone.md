# Voice / WebRTC Softphone

End-to-end-flöde för 46elks-integrerad mjuktelefon i FlowWink. Verifierat
i produktion (inkommande + utgående + voicemail + callback).

## Arkitektur i ett ögonkast

```
                       +----------------------+
External caller ──DID──▶ elks46-ingest (edge) ──connect──▶ Agent WebRTC user
                       +----------┬-----------+                 │
                                  │ no answer                   ▼ INVITE/SIP
                                  ▼                       Browser JsSIP
                          Voicemail flow                 (Softphone.tsx)
                                  │                            │
                                  ▼                            ▼
                            voice_calls ◀── realtime ─── IncomingCallToaster
```

Softphone är **globalt monterad i `AdminLayout`** — en enda instans följer
agenten över alla admin-vyer. Voice-sidan och Live Support visar bara
historik/listor; själva samtalskontrollerna lever i den flytande widgeten
nere till höger.

## 46elks setup

| Komponent | Vad det är | Webhook |
|---|---|---|
| Publikt DID (`+46…`) | Vanligt Mobile-abonnemang. Det enda numret som externa ringer. | `voice_start` → `elks46-ingest` |
| WebRTC-konto (`46…`) | SIP/WebRTC-user (~30 kr/mån), en per agent. Inget riktigt nummer. | `voice_start` → `elks46-ingest` (krävs bara för grön bock i 46elks UI) |
| `from_number` i `site_settings.integrations.elks46.config` | Caller-ID vid utringning. **Krävs** för outbound. | n/a |

## Inbound

1. `elks46-ingest` får `voice_start` från 46elks → hittar online-agent med
   `voice_enabled=true` i `support_agents`.
2. Returnerar `connect: "+46…"` (telefon-format, **inte** `sip:`-URI —
   46elks avvisar SIP-URI:er som "not one of your allowed servers").
3. 46elks ringer agentens WebRTC-konto → JsSIP triggar `newRTCSession`
   med `originator='remote'` → Softphone visar Answer/Decline.
4. `IncomingCallToaster` (globalt monterad i `AdminLayout`) prenumererar
   på `voice_calls` realtime och visar en toast med **Answer**-knapp som
   dispatchar `window` CustomEvent `softphone:answer`.
5. Vid svar → SIP-session går till `confirmed` → `voice_calls` uppdateras
   till `answered`/`completed`.
6. Vid no-answer (~15s) faller flödet till voicemail (inspelning +
   transkription) som syns under `/admin/voice` → Voicemail.

## Outbound

1. Valfri UI-yta (CallbacksPanel, VoicemailPanel, CRM, manuell dial-in
   i widgeten) dispatchar `window.dispatchEvent(new CustomEvent('softphone:dial', { detail: { number } }))`.
2. Softphone anropar `elks46-ingest` med `{ action: 'call', mode: 'webrtc', to }`.
3. Edge-funktionen initierar två ben: ringer agentens WebRTC först,
   sedan `connect` till `to`. `pendingOutboundRef` auto-svarar agent-benet
   så agenten inte behöver klicka två gånger.
4. `voice_calls` raden loggas med `direction='outbound'` direkt vid
   startCall.
5. Utan `from_number` returnerar edge-funktionen 500 med
   `"Missing caller number (configure from_number)"`. Konfigureras i
   `/admin/integrations` → 46elks-kortet.

## Globala events

Softphone:n exponerar två `window` CustomEvents:

| Event | Detail | Avsändare |
|---|---|---|
| `softphone:dial` | `{ number: string }` | CallbacksPanel, VoicemailPanel, CRM action-menyer |
| `softphone:answer` | — | `IncomingCallToaster` (svara från toast) |

Dessa är medvetet löst kopplade — vilken vy som helst kan trigga ett
samtal utan att importera Softphone-komponenten.

## Recording playback

Inspelningar (voicemail) ligger bakom Basic Auth hos 46elks. Klienten
spelar **aldrig** upp direkt från 46elks-URL:en — vi går via
`voice-recording` edge-funktionen som autentiserar server-side och
streamar tillbaka ljudet.

## Felsökning

| Symtom | Trolig orsak |
|---|---|
| Samtal går rakt till voicemail | Toast klickades men widgeten svarade inte. Använd nu **Answer**-knappen — `softphone:answer`-eventet hanterar SIP-acceptet. |
| `This SIP server is not allowed` | `connect`-targeten är `sip:…` istället för `+46…`. Routing måste vara telefon-format. |
| Outbound 500 `Missing caller number` | `from_number` saknas i `site_settings.integrations.elks46.config`. |
| Softphone-pill saknas | Voice-modulen är inte aktiverad, eller agenten har inte `voice_enabled=true` + SIP-credentials. |
| Två softphones samtidigt | Ska inte längre hända — local mounts i `VoicePage` och `LiveSupportPage` är borttagna. Endast `AdminLayout` monterar Softphone. |

## Filer

- `src/components/admin/voice/Softphone.tsx` — JsSIP-klient, floating widget, event-bus.
- `src/components/admin/voice/IncomingCallToaster.tsx` — global ring-listener + toast.
- `src/components/admin/AdminLayout.tsx` — global mount-punkt.
- `supabase/functions/elks46-ingest/index.ts` — webhook-router + outbound starter.
- `supabase/functions/voice-recording/index.ts` — recording playback proxy.
- `mem/voice/webrtc-softphone-flow.md` — kort minnesfil för agenten.
