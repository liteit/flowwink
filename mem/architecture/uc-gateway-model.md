---
name: UC Gateway Model
description: Target architecture for consolidating Chat Widget + Live Support + Email + Voice into a unified UC/Contact Center gateway, inspired by Hermes Agent and OpenClaw, packaged via FlowWink's page+module+integration model.
type: feature
---

# UC / Contact Center Gateway — target model

Consolideringsmål för Chat Widget, Live Support, Email (Outbound), Voice m.fl. → **ett UC-lager** där varje kanal är en plugin-adapter bakom en gemensam gateway. Bygger på samma mönster som Hermes Agent (`NousResearch/hermes-agent` `gateway/`) och OpenClaw (`docs/gateway/*`).

## Kärnkoncept (stulet från Hermes + OpenClaw)

1. **Inbox = channel adapter + config + routing-regel.** Hermes kallar det "platform", OpenClaw "channel". Vi kallar det **inbox**. En inbox = en aktiverad kanalanslutning (t.ex. "Support Email", "Web Chat Widget", "Sales WhatsApp").
2. **Unified `conversation_id`** som spänner kanaler för samma kontakt. Hermes konstruerar `session_key` i `gateway/session.py`. Idag har vi siloed `chat_sessions` per kanal — UC kräver att email-tråd → chat-eskalering → voice-callback hänger ihop på samma kontakt.
3. **Home channel** per objective/kampanj = default outbound. Matchar `outbound`-namnet (mem://architecture/uc-outbound-naming).
4. **Routing/bindings: inbox → executor.** Samma `executor`-fält som platform automations: `platform` | `flowpilot` | `teammate` | `external-claw`. Löser även `with_agent`/`with_teammate`-UI-tvetydigheten — status härleds från executor.
5. **Delivery preferences per kanal**: typing-indicators, chunking, rate-limits, business hours, SLA.
6. **JSON Schema-driven config UI** (OpenClaw-mönster): varje adapter exporterar `channelConfigSchema` → Control-UI byggs dynamiskt, ingen hårdkodad settings-sida per kanal.

## Packetering enligt vår page + module + integration-modell

UC är INTE en monolit. Det är ett paket av vår standardtrio per kanal:

```
                    ┌─────────────────────────────────┐
                    │      UC Gateway (platform)      │
                    │  conversation_id · routing      │
                    │  session policies · delivery    │
                    └────────────┬────────────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
   ┌────▼─────┐            ┌─────▼─────┐            ┌─────▼─────┐
   │ chat     │            │ email     │            │ voice     │
   │ MODULE   │            │ MODULE    │            │ MODULE    │
   └────┬─────┘            └─────┬─────┘            └─────┬─────┘
        │                        │                        │
   ┌────▼─────┐            ┌─────▼─────┐            ┌─────▼─────┐
   │ widget   │            │ smtp /    │            │ twilio /  │
   │ embed    │            │ gmail /   │            │ sip /     │
   │ PAGE     │            │ ms-graph  │            │ webrtc    │
   │          │            │INTEGRATION│            │INTEGRATION│
   └──────────┘            └───────────┘            └───────────┘
```

**Per kanal får vi:**
- **Module** (`src/lib/modules/channels/<name>-module.ts`) — manifest, `channelConfigSchema`, skill-seeds (`send_message`, `mark_resolved`, `escalate`)
- **Integration** — credentials & transport (Gmail OAuth, Twilio API key, SMTP, WhatsApp Cloud API…). Återanvänd existerande integration-mönster.
- **Page/Embed** — den synliga ytan: chat widget på publika siten, public booking-form som spawnar conversation, dedicated landing per inbox vid behov.

**Gemensam plattform-yta** (inte per kanal):
- `/admin/inbox` — unified inbox (ersätter `/admin/chat`, `/admin/communications` etc.)
- `conversations`-tabell med `channel`, `inbox_id`, `executor`, `status`
- `conversation_messages` polymorf på conversation
- Routing-regler & home-channels i `inbox_routing`

## Migrationssteg (när vi tar det)

1. Skapa `conversations` + `conversation_messages` som superset av `chat_sessions`/`chat_messages` (behåll bakåt-kompatibilitet via vyer).
2. Refaktorisera `chat-module` → `channels/web-chat-module` med `channelConfigSchema`.
3. Flytta `communications` (outbound email) → `channels/email-module` (Outbound är bara en home-channel-config).
4. Live Support = inte egen modul, utan **executor=teammate** på vilken inbox som helst.
5. Unified inbox-UI med channel-filter (vi har redan grunden i `/admin/chat`).
6. Voice-modulen (`mem://voice/ai-receptionist-target-architecture`) blir bara ytterligare en channel-adapter.

## Vad det INTE är
- Inte en monolitisk "contact center"-modul. UC är **plattformslagret** + N opt-in channel-moduler.
- Inte en ersättning för FlowPilot-reasoning. FlowPilot är en executor bland flera.
- Inte ett nytt skill-system. Channel-skills (`send_message` etc.) följer samma `agent_skills`/MCP-mönster som alla andra moduler.

## Inspiration / referenser
- Hermes Agent: `NousResearch/hermes-agent/gateway/{run,session,delivery,config}.py` — 20+ platforms i en gateway, multi-profile-stöd.
- OpenClaw: `docs/gateway/configuration-reference.md` + `config-agents.md` — JSON Schema-driven config, `multiAgent.routing` bindings.
- Odysseus: inte relevant för UC-lagret (det är ett workspace, inte en gateway).
