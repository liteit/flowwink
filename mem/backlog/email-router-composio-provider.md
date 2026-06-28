---
name: Email Router — Composio/Gmail as provider
description: Backlog (high prio): consolidate Composio Gmail + Gmail OAuth into email-send router so all outbound mail logs to outbound_communications
type: feature
---

## Problem
`email-send` är abstraktionslagret men stödjer bara `resend` + `smtp`.
Composio Gmail och Gmail OAuth går egna vägar → loggas INTE i `outbound_communications` → tom Communications-vy trots aktiva sändningar.

## Fix
Utöka provider-enum i `supabase/functions/email-send/index.ts`:
```
provider = "resend" | "smtp" | "composio" | "gmail-oauth"
```
- `composio`-grenen anropar `composio-proxy` internt (Gmail send action).
- `gmail-oauth`-grenen använder lagrad refresh token per user.
- Alla grenar går genom `logComm()` → enhetlig logg.

## Prio
HIGH — utan detta är Communications-loggen ofullständig och vi kan inte revidera utgående mail-trafik.

## Touchpoints
- `supabase/functions/email-send/index.ts` (router)
- `supabase/functions/composio-proxy/index.ts` (Gmail send wrapper)
- `site_settings.integrations.composio.config.emailConfig.provider` (UI val)
- Migrera ev. direktanrop till composio-proxy från andra functions → gå via email-send istället.
