---
name: Contract Lifecycle Management
description: Contracts = strukturerad post med Google Docs-känsla i editorn. body_markdown är källan, TipTap WYSIWYG ger Docs-UX, documents-modulen håller bilagor (PDF). Sign extraheras till egen modul när 3+ entities behöver det.
type: feature
---

## Arkitekturbeslut (2026-04-21): "Strukturerad post + Docs-känsla"

Contracts är **hybrid**, medvetet:
- **Strukturerad post** — `contracts`-tabell äger metadata (counterparty, status, dates, value, version, signatures)
- **Editerbart dokument** — `body_markdown` är källan, TipTap-editorn ska kännas som **Google Docs** (clean canvas, fokus på text, autosave, inline formatering, inga distraktioner)
- **Bilagor** — `documents`-modulen (polymorft filarkiv) håller uppladdade PDF:er, signerade original, attachments via `related_entity_type='contract'`

### Skiljelinje mot `documents`-modulen
| | `contracts.body_markdown` | `documents` |
|---|---|---|
| Typ | Editerbar text (Google Docs-style) | Filer (PDF/DOCX/bilder) |
| Innehåll | Läsbart, sökbart, MCP-exponerat | Opakt — vi serverar bara filen |
| Editor | TipTap WYSIWYG inline | Ingen — bara upload/preview |
| Sökning | pg_trgm GIN på markdown | Filnamn + metadata |
| Versioner | `contract_versions` snapshots | Filversion via re-upload |

### Google Docs-UX — krav på editorn
- Stor clean canvas, ingen visuell brus runtomkring
- Inline-toolbar (sticky), inte modal/sidebar
- Autosave med tyst "Saved"-indikator (ingen "Save"-knapp som primary action)
- Tangentbordsgenvägar (Cmd+B/I/U, headings via #, ##)
- Placeholder som vägleder ("Skriv avtalet här…")
- Prose-styling som påminner om dokument, inte form-fält

## Scope idag
- `contracts.body_markdown` är source of truth (TipTap → Turndown → markdown)
- Public signing `/contract/:token` mirrors `/quote/:token` UX
- `contract_versions` snapshots vid send-for-signature
- `contract_signatures` audit log (view + accept/reject + IP/UA)
- `pg_trgm` GIN på title + body_markdown för LLM-driven sökning

## MCP skills (Scenario B — ClawWink som operator)
- `manage_contract` — CRUD
- `get_contract_content` — full markdown body, LLM-friendly
- `search_contracts` — pg_trgm fuzzy search
- `send_contract_for_signature` — genererar signing token
- `contract_renewal_check` — daglig cron (08:00 weekdays)
- `list_contract_documents` — bilagor via documents vault

## Edge function
`contract-sign` — public, no JWT — atomic accept/reject, status flip till active, audit insert.

## När bryta ut till "docs"-modul (Väg B)?
**Inte nu.** Trigger: när 3+ entities behöver fri editerbar text + templates + comments (t.ex. proposals, SOWs, policies, KB-artiklar med rich editing). Då polymorft `docs`-table med `entity_type` + `entity_id`.

**Varför vänta:** Quotes är strukturerad data (line items), inte fri text. Contracts är ensam idag — abstraktion = premature.

## Sign som standalone module (planerat, ej implementerat)
Se `mem://features/signature-module` för full extraktionsplan. Trigger: 3:e signable entity (employment offers, PO approvals).
