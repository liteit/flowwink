---
name: Voice agent routing — provider abstraction debt
description: MVP har 46elks-specifik logik i agent routing / AI receptionist bridge / callback scheduler / SMS reply. Ska lyftas till VoiceProvider-adaptern när provider #2 (Twilio/Sinch/Telnyx) onboardas.
type: constraint
---

## Debt

Agent routing, callback auto-schedule, AI-receptionist-bridge och SMS-reply lever idag i `supabase/functions/elks46-ingest/` och `supabase/functions/voice-ingest/`. Mycket är 46elks-shaped:

- Webhook payload shape (46elks-JSON)
- Action-serialisering (`{connect: "+46…"}`, `{play: url}`, `{ivr: …}`)
- Realtime-audio-format för Gemini Live (PCM-parametrar bundlade med 46elks stream-handshake)
- DID → WebRTC-account bridging (46elks-specifikt)
- SMS-fallback (46elks SMS-endpoint, mobil-only-filter)

## Regel

När provider #2 onboardas (Twilio, Sinch, Telnyx, Vonage):

1. Lyft **provider-agnostisk** logik till `_shared/voice/` eller ny `voice-router` edge:
   - Agent presence/availability-lookup
   - Callback-slot-finder (`elks46-ingest/index.ts` L102–142)
   - AI-receptionist-gating (agents offline → route till `voice-ingest`)
   - `smsReplyEnabled` master switch
   - Voicemail-transkriberings-trigger
2. Behåll **provider-specifikt** i respektive integration-edge:
   - Webhook signature verification
   - Action-serialisering (46elks JSON vs TwiML XML vs Sinch SVAML)
   - Audio-codec/format-förhandling för realtime-streams
   - DID↔account-bridging
3. Utöka `VoiceProvider`-interfacet i `src/lib/voice-providers/types.ts` med `getAgentRoute()`, `serializeConnect()`, `getRealtimeAudioFormat()`, `sendSms()` — istället för att kopiera routing-flödet per provider.

## Why not now

MVP prioriterade end-to-end på 46elks (funkar). Vi refaktorerar INTE preemptivt — abstraktion mot endast ett exempel = fel abstraktion.

## Trigger

Ny provider-integration skapas (t.ex. `twilio-ingest`) → gör refaktorn samtidigt, inte innan.
