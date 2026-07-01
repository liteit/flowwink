---
name: Voice agent routing — provider abstraction debt
description: MVP has 46elks-specific logic bleeding into agent routing / AI receptionist bridge; should move to VoiceProvider adapter layer when a second provider (Twilio/Sinch/Telnyx) is onboarded
type: constraint
---

## Debt

Agent routing, callback auto-scheduling, AI receptionist bridge and SMS reply logic currently live in `supabase/functions/elks46-ingest/` and `supabase/functions/voice-ingest/` — much of it 46elks-shaped (webhook payload shape, `connect`/`play`/`ivr` action serialization, WebSocket audio format for Gemini Live, DID→WebRTC bridging).

## Rule

When onboarding a second voice provider (Twilio, Sinch, Telnyx, Vonage):

1. Lyft **provider-agnostisk** logik till `voice-router` edge function eller `_shared/voice/`:
   - Agent presence/availability lookup
   - Callback slot finder (`elks46-ingest/index.ts` L102–142)
   - AI receptionist gating (offline → route to `voice-ingest`)
   - SMS reply gating (`smsReplyEnabled` master switch)
   - Voicemail transcription trigger
2. Behåll **provider-specifikt** i respektive integration edge:
   - Webhook signature verification
   - Action serialization (46elks JSON vs TwiML XML vs Sinch SVAML)
   - Audio codec/format negotiation för realtime streams
   - DID↔account bridging (46elks WebRTC vs Twilio Voice SDK)
3. `VoiceProvider`-interfacet i `src/lib/voice-providers/types.ts` finns redan — utöka det med `getAgentRoute()`, `serializeConnect()`, `getRealtimeAudioFormat()` istället för att kopiera flödet per provider.

## Why

MVP prioriterade end-to-end på 46elks (funkar). Refaktorn görs INTE preemptivt — vänta tills provider #2 faktiskt onboardas, annars bygger vi abstraktion mot bara ett exempel.

## Trigger

Skapa ny provider-integration (t.ex. `twilio-ingest`) → gör refaktorn samtidigt, inte innan.
