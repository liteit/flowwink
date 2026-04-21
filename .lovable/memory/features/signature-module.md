---
name: Signature Module (planned extraction)
description: E-signering är idag inbäddat i quotes + contracts (SES-nivå, eIDAS-giltig). Planerad extraktion till en horisontell modul à la Odoo Sign när 3:e entity behöver signering. Beskriver nuvarande implementation, juridisk nivå, och målarkitektur.
type: feature
---

## Status: **Embedded, not yet extracted** (2026-04-21)

Signering finns idag som inbäddad funktionalitet i två moduler:
- **Quotes** (`/quote/:token` + `quote-accept` edge function)
- **Contracts** (`/contract/:token` + `contract-sign` edge function)

Båda flödena delar samma mönster men har separata tabeller (`quote_signatures` / `contract_signatures`). Extraktion till en standalone `signatures`-modul är **planerad men medvetet uppskjuten** tills en 3:e entity behöver signering (premature abstraction-risk).

## Nuvarande implementation (Embedded SES)

### Flow
1. **Generera link** — admin trycker "Send for signature" → unik `accept_token` (24 bytes base64url) genereras → status flippar till `pending_signature` → snapshot i `*_versions`-tabell
2. **Publik visning** — motpart öppnar `/quote/:token` eller `/contract/:token` (ingen auth, ingen JWT) → view loggas i `*_signatures`-tabell
3. **Accept/Decline** — edge function (`quote-accept` eller `contract-sign`, båda `--no-verify-jwt`) skriver atomärt:
   - Signatur-rad (`signer_name`, `signer_email`, `ip_address`, `user_agent`, `comment`, `action`)
   - Entity-status → `active`/`accepted` eller `terminated`/`rejected`
   - Final version-snapshot
   - `audit_logs`-rad
   - Bekräftelse-mail (motpart + admins) via `email-send`

### Tabeller (per entity, parallell struktur)
```
contract_signatures: id, contract_id, action(view|accept|reject), signer_name,
                     signer_email, signature_data, comment, ip_address,
                     user_agent, created_at
quote_signatures:    id, quote_id,    action,                signer_name, ...
```

### Hooks & UI
- `useContractWorkflow.ts` / `useQuoteWorkflow.ts` — `useSendContract()`, `useSignContract()`, `usePublicContract()`, `markContractViewed()`
- `PublicContractPage.tsx` / `PublicQuotePage.tsx` — identisk UX (Accept & Sign / Decline + name/email/comment fields)

### MCP-exponering
- `send_contract_for_signature` — genererar token + URL
- `send_quote_for_signature` — samma för quotes
- ClawWink (Scenario B operator) kan autonomt skicka avtal/offerter för signering

## Juridisk nivå: **SES (Simple Electronic Signature)**

Enligt **eIDAS Article 25**: SES får inte nekas rättslig verkan enbart för att den är elektronisk.

**Vad som samlas in räcker för SES:**
- ✅ Signer name + email (identitetspåstående)
- ✅ IP-adress + User-Agent (teknisk identifierare)
- ✅ Server-side timestamp (`signed_at`)
- ✅ Snapshot av exakt dokumentversion vid signering
- ✅ Audit log (`audit_logs` + `*_signatures` view-events)
- ✅ Token-baserad åtkomst (bevisar att signer hade unik länk)

**Räcker för** (i Sverige/EU):
- B2B-avtal, NDA, samarbetsavtal
- Offerter & accepter
- Anställningsavtal (kollektivavtal kan kräva mer)
- Allmänna villkor / SaaS-prenumerationer

**Räcker INTE för:**
- Fastighetsköp (kräver QES + notarius)
- Bolagsbildning (vissa former kräver BankID/notarius)
- Konsumentkrediter (kräver oftast AES)
- Testamenten, äktenskapsförord (kräver fysisk signatur)

## Saknas idag

| Feature | Beskrivning | Prio |
|---|---|---|
| **PDF-export** | Render signerad version + audit-sida som nedladdningsbar PDF | Hög — kunder vill ha "intyg" |
| **BankID/AES** | Step-up till BankID/Freja/SMS-OTP före accept | Medel — kommer krävas för konsumentavtal |
| **Multi-signer** | Sekventiell eller parallell signering av flera parter | Medel — frequent för 3-parts-avtal |
| **Webhook-mottagare** | Endpoint för externa leverantörer (Scrive/DocuSign) som postar event tillbaka | Låg — bara om vi integrerar extern QES |
| **Signature image / drawn** | Faktisk ritad signatur (canvas) lagrad som `signature_data` blob | Låg — visuell feel, ingen juridisk skillnad |
| **Reminders** | Auto-mail till icke-signerade efter X dagar | Medel |
| **Decline-with-changes** | Motpart föreslår ändringar istället för rakt avslag | Låg |

## Planerad extraktion (när 3:e entity dyker upp)

**Trigger:** När employment offers, PO approvals, eller annan entity behöver signering.

### Målarkitektur — polymorf signatur-tabell
```sql
CREATE TABLE signature_requests (
  id UUID PRIMARY KEY,
  signable_type TEXT NOT NULL,        -- 'contract' | 'quote' | 'employment_offer' | ...
  signable_id UUID NOT NULL,
  accept_token TEXT UNIQUE NOT NULL,
  required_signers JSONB NOT NULL,    -- [{name, email, role, order}]
  status TEXT,                         -- pending | partially_signed | completed | declined | expired
  expires_at TIMESTAMPTZ,
  created_by UUID,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE signatures (
  id UUID PRIMARY KEY,
  request_id UUID REFERENCES signature_requests(id),
  signer_name TEXT, signer_email TEXT,
  action TEXT,                         -- view | accept | reject
  signature_data TEXT,                 -- typed name OR base64 drawn signature
  ip_address INET, user_agent TEXT,
  signed_at TIMESTAMPTZ DEFAULT now()
);
```

### Återanvändbara komponenter
- `<PublicSignaturePage>` — generic page, dispatcher hämtar rätt renderer per `signable_type`
- `useSignatureRequest(token)` — generic hook
- MCP-skill: `request_signature(entity_type, entity_id, signers[])` — fungerar på vilken som helst signable entity

### Migration från embedded → modul
1. Skapa nya tabellerna med data-migration från `contract_signatures` + `quote_signatures`
2. Behåll gamla tabellerna som views över nya tabellen (bakåtkomp för hooks)
3. Refaktorera hooks stegvis till `useSignatureRequest()`
4. Deprecate `contract-sign` + `quote-accept` → ny generisk `signature-respond` edge function
5. Markera signature som egen modul i `ModulesSettings` (kan slås av om kund inte vill ha signering)

## Beslut: vänta med extraktion

Premature abstraction = teknisk skuld. Två entity är inte tillräckligt för att veta vad som faktiskt är gemensamt vs entity-specifikt. När en 3:e signable entity konkret behövs (kanske employment offers under HR-modulen, eller PO-approvals under Purchasing) — då gör vi extraktionen med riktig data om vilka mönster som upprepas.

**Tills dess:** dokumentation här fungerar som design-spec så vi inte glömmer beslutet eller målarkitekturen.
