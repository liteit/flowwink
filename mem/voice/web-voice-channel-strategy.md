---
name: Web Voice Channel Strategy
description: Push-to-talk / web-voice as channel adapter in UC-gateway, with swappable STT→LLM→TTS providers (ElevenLabs, OpenAI Realtime, self-hosted Whisper)
type: feature
---

## Position in architecture
Web voice is **not** a separate module — it's a **channel adapter** in the UC-gateway model (see `mem://architecture/uc-gateway-model`). Same `conversation_id`, same `executor` routing (`flowpilot` for AI, `teammate` for live human pickup), same inbox UI in `/admin/inbox`.

Packaging follows the standard page+module+integration model:
- **Module:** `src/lib/modules/channels/voice-web-module.ts` — `aiRealtime` (or `voiceWeb`) feature flag
- **Integration:** provider creds (ElevenLabs API key, OpenAI API key, or self-hosted endpoint URL)
- **Page/Embed:** push-to-talk button block + floating widget, embeddable on any public page

## Provider abstraction (swappable)
Three tiers, all behind the same `VoiceProvider` interface (extend `src/lib/voice-providers/types.ts`):

| Tier | STT | LLM | TTS | Use case |
|---|---|---|---|---|
| **Cloud (low-latency)** | OpenAI Realtime (one socket) | OpenAI Realtime | OpenAI Realtime | Quick prototypes, English-heavy |
| **Cloud (best voice)** | ElevenLabs Scribe Realtime | FlowPilot `chat-completion` | ElevenLabs TTS streaming | Best voice quality, multilingual |
| **Self-hosted (GDPR)** | Whisper (private server, streaming) | Lokal LLM via `chat-completion` provider=local | Piper / XTTS (private) | Healthcare, EU patient data, dentist vertical |

The module config UI (JSON-schema-driven, OpenClaw pattern) picks provider per-inbox. Switching providers = config change, not code change.

## UX patterns to support
1. **Push-to-talk button** on any page block — visitor holds, speaks, releases → transcript + voice reply
2. **Floating voice widget** — always-available "talk to us" affordance (mic-permission only requested on press)
3. **Live escalation** — if `executor=teammate`, the call ringer hands off to softphone (see existing 46elks softphone path); otherwise FlowPilot answers
4. **Hybrid fallback** — if voice fails, drop to text chat in same `conversation_id`

## Why a module, not hardcoded
- Voice ≠ universal need. Many sites want only text chat. Opt-in via module toggle.
- Per-inbox provider choice (Cloud for marketing site, self-hosted for healthcare portal in same org)
- FlowPilot integration is automatic: voice is just another inbox feeding the same reasoning engine

## Credentials
- `ELEVENLABS_API_KEY` — already a standard connector; sync via `standard_connectors`
- `OPENAI_API_KEY` — existing AI provider key
- Self-hosted: `VOICE_LOCAL_STT_URL` + `VOICE_LOCAL_TTS_URL` (configured per-instance, not via Lovable secrets — this is a self-hosted project)

Never hardcode provider choice. The module reads `ai_config` + per-inbox override.

## Relation to existing voice work
- Replaces nothing in `mem://voice/ai-receptionist-target-architecture` (that's the **phone/46elks** channel — different adapter, same model)
- Both phone-voice and web-voice are sibling channel adapters under the UC-gateway umbrella
- Shared provider abstraction in `src/lib/voice-providers/` — both adapters consume the same `VoiceProvider` interface

## FlowPilot's effect on voice (vs chat)

Voice är **per definition reaktivt** + lever på <500ms latensbudget. FlowPilots stora värde (heartbeat, proaktivitet, ReAct över många skills) gäller därför **mycket mindre** i samtalsögonblicket än i text-chat.

| Capability | Chat → agent | Voice → agent |
|---|---|---|
| Soul + KB + skills + business context | Ja (via `chat-completion`) | Ja (samma endpoint) |
| ReAct multi-step planning | Ja, gärna 3–5 steg | **Nej** — `maxSteps=1` (max 2) annars tysta pauser |
| Heartbeat / proaktivitet | FlowPilot-värde | Inte i samtal (separat outbound-flöde) |
| Long-term memory | FlowPilot-värde | Skrivs efter samtal, läses som context |
| Objectives-bias i system-prompt | FlowPilot-värde | FlowPilot-värde (gratis, ingen latens) |

**Regel för voice-adaptern:** tvinga `maxSteps=1` oavsett operator-läge. FlowPilot bidrar med memory + objectives-injection i prompten, INTE med djupare reasoning-loopar under pågående samtal. Voice utan FlowPilot fungerar fullt ut via FlowChat-loopen — samma soul, samma skills.

## Lego, inte monolit — så här undviker vi UC-svällning

UC-paraplyet växer lätt till en monolit. Bygg det som **lego** med tre lager per kanal:

```
Integration  →  Module  →  Page/Embed
(credentials    (skills,    (visitor-facing
 + transport)    config,     surface)
                 routing)
```

**Regler för att hålla det modulärt:**

1. **En adapter per kanal**, aldrig delade. Web-voice ≠ phone-voice ≠ chat ≠ email. Varje fil under `src/lib/modules/channels/<name>-module.ts` står på egna ben och kan disablas utan att UC går sönder.
2. **Integrationer återanvänds över adaptrar.** ElevenLabs-integrationen är samma oavsett om den används av `voice-web` eller en framtida `voice-phone-tts`. Bind aldrig en integration till en specifik modul.
3. **Pages är opt-in per kanal.** Push-to-talk-knapp = block, floating widget = block, embeddable per page. Ingen kanal får tvinga sin UI på andra moduler.
4. **Skill-seeds per modul.** Voice-modulen seedar bara voice-specifika skills (`start_voice_session`, `transfer_to_human`); generiska skills (`send_message`, `mark_resolved`) ärvs från UC-platformlagret.
5. **Config-schema per adapter.** JSON Schema → Control-UI byggs dynamiskt. Aldrig en `VoiceSettings.tsx`-sida som känner till alla providers.
6. **Provider abstraction inne i modulen.** ElevenLabs/OpenAI/Whisper är NOT egna moduler — de är providers bakom `VoiceProvider`-interfacet inom `voice-web-module`. Annars sväller modullistan med pseudo-moduler.

**Test för "är detta en egen modul?"**
- Egen affärsförmåga + egen admin-yta + egna skills → ✅ modul
- Bara en provider-implementation bakom en interface → ❌ inte modul, läggs under befintlig modul
- Bara credentials till ett externt system → ❌ inte modul, det är en integration

## Docs
- `docs/modules/voice.md` exists — extend with a "Web voice" section when implementing
- New module entry: `docs/modules/voice-web.md` (or merge into `voice.md` as "Phone vs Web" subsections)
