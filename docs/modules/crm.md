---
id: crm
name: CRM
manual: true
description: Unified Sales Intelligence + Lead Loop. Lead → Opportunity → Customer with autonomous scoring, Firecrawl enrichment, and full agent operability.
---

# CRM

> **Status:** Flagship module — manually maintained.
> **Source of truth:** `src/lib/modules/crm-module.ts` + this file.
> _The auto-generator skips this file because of `manual: true`._

The CRM module is FlowWink's **sales intelligence layer**. It owns the lead-to-customer lifecycle and is one of the most agent-operable modules in the platform — FlowPilot can prospect, enrich, score, qualify, and convert without human intervention when trust policies allow.

It is built around the **unified lead loop**: every signal (form submission, page view, chat conversation, email reply, calendar booking) feeds the same scoring algorithm, and every outbound action (enrichment, follow-up, qualification call) is a registered skill.

---

## The unified lead loop

```
Signal capture (forms, chat, email, calendar, page analytics)
   ↓
Lead created / updated  (leads table)
   ↓
Auto-enrichment (Firecrawl + company-insights)
   ↓
Scoring algorithm (engagement + fit + intent)
   ↓
Threshold reached → status transition (lead → opportunity → customer)
   ↓
FlowPilot picks next-best action (delegate, follow up, hand to human)
```

See `mem://crm/sales-intelligence-and-lead-loop-unified`.

---

## Status model & alias mapping

The DB enum is **strict**: `lead | opportunity | customer | lost`. External agents and forms often use other vocabularies — these are normalized at the skill boundary:

| Input alias | Maps to |
|---|---|
| `new` | `lead` |
| `qualified` | `opportunity` |
| `won` / `closed-won` | `customer` |
| `disqualified` / `closed-lost` | `lost` |
| `all` | _(no filter)_ |

Enforced by `normalizeLeadStatus()` + `tool_definition.enum` + a guardrail test that locks the contract. See `mem://crm/manage-leads-status-alias-mapping`.

---

## Architecture

### Data model

| Table | Purpose |
|---|---|
| `leads` | Core lead/opportunity/customer record. Polymorphic via `status`. |
| `lead_signals` | Every captured signal (form, page-view, chat, email, calendar). |
| `lead_scores` | Computed scores (engagement, fit, intent) with timestamp. |
| `companies` | Enriched company records (Firecrawl + manual). |
| `company_insights` | Defensive-merged enrichment from multiple sources. See `mem://architecture/business-identity-strategic-hub`. |
| `deals` | Optional pipeline stages on top of opportunity-status leads. |
| `contacts` | People associated with companies. |

### Defensive merge for enrichment

When enrichment data arrives from Firecrawl or a manual edit, the system **never overwrites** existing fields with empty/null values. Each field tracks its source + confidence so manual edits beat automated ones, and recent automated > stale manual. Implemented in `merge_company_insights` SECURITY DEFINER RPC.

---

## Skills (MCP-exposed)

### Core lead operations
| Skill | Purpose |
|---|---|
| `manage_leads` | CRUD + filter + bulk update. Status alias-aware. |
| `create_lead` | Single lead with auto-dedup against `email` + `company_domain`. |
| `update_lead_status` | Transition with side effects (e.g. `customer` → triggers welcome flow). |
| `score_lead` | Recompute score; useful after manual signal injection. |
| `qualify_lead` | Run qualification policy; promotes lead → opportunity if criteria met. |

### Enrichment & intelligence
| Skill | Purpose |
|---|---|
| `enrich_company` | Firecrawl → defensive merge → `company_insights`. |
| `enrich_contact` | Email signature + LinkedIn-style metadata. |
| `lookup_company` | Domain or name → company record (resolves aliases). |
| `summarize_account` | FlowPilot generates an account brief from all signals. |

### Pipeline & deals
| Skill | Purpose |
|---|---|
| `create_deal` | Open deal on an opportunity-status lead. |
| `move_deal_stage` | Pipeline transition with reason. |
| `close_deal` | Won → triggers customer conversion + invoicing handoff. |

### Outreach
| Skill | Purpose |
|---|---|
| `send_followup` | Personalized email via `email` module + KB context. |
| `schedule_meeting` | Hands off to `bookings` / `calendar`. |
| `delegate_research` | Sends company to a federated peer for deeper research. |

---

## Scoring algorithm

A composite score per lead, recomputed on every signal:

```
total_score = (engagement * 0.4) + (fit * 0.4) + (intent * 0.2)
```

| Component | Built from |
|---|---|
| **Engagement** | Page views, time-on-site, returning visits, form fills, chat depth |
| **Fit** | ICP match (industry, size, geography from `company_insights`) |
| **Intent** | High-intent pages (pricing, demo, contact), keyword signals, explicit asks |

Thresholds are per-deployment. Default: 70+ → auto-promote to `opportunity`, 90+ → notify human.

See `mem://crm/sales-intelligence-and-lead-loop-unified`.

---

## End-to-end processes

- **`lead-to-customer`** — owned by this module; spans capture → enrichment → scoring → qualification → conversion
- **`customer-onboarding`** — handoff to `ecommerce` / `subscriptions` / `bookings`
- **`account-expansion`** — recurring scoring on existing customers feeds upsell opportunities

See `docs/processes/` for full E2E diagrams.

---

## Customer model split

FlowWink intentionally separates **e-commerce customers** (anonymous-friendly, transactional) from **B2B customers** (named accounts, contracts, AR). Both share a unified `profiles` row but different downstream tables. See `mem://ecommerce/customer-management-architecture`.

When a CRM lead converts to `customer`:
- B2B path → company + contracts + invoicing
- E-commerce path → profile + order history + subscriptions
- The conversion skill picks the path based on signal pattern (deal_value, contract requested, plan tier, etc.)

---

## Admin UI

`/admin/crm` — pipeline view with kanban, lead list, company browser, scoring inspector.

Key sub-pages:
- `/admin/crm/leads` — full lead list with status alias-aware filters
- `/admin/crm/companies` — company browser with enrichment timeline
- `/admin/crm/pipeline` — deal kanban
- `/admin/crm/insights` — score distribution, conversion funnel, signal heatmap

---

## Extending

### Add a new signal type
1. Insert event into `lead_signals` with source + payload JSON.
2. Update scoring algorithm if signal should affect engagement/intent.
3. Document signal source in `mem://features/browser-control-operator` or appropriate module.

### Add a new enrichment source
1. Implement adapter that returns canonical `CompanyInsightPatch`.
2. Call `merge_company_insights` RPC — never write directly to `company_insights`.
3. Set `source_confidence` so the defensive merge can rank it correctly.

### Add a new qualification policy
1. Define policy in `crm_qualification_policies` table.
2. Implement scoring callback in `qualify_lead` skill.
3. Set per-deployment default policy.

---

## Development context

- **Status enum is strict.** Use `normalizeLeadStatus()` everywhere — never trust raw input. The guardrail test will fail if you bypass it.
- **Defensive merge is mandatory.** Never `UPDATE company_insights SET ... = NULL`. Always go through `merge_company_insights`.
- **Scoring runs on the database.** Avoid client-side scoring — agents and webhooks need the same numbers.
- **Conversion is a skill, not a trigger.** Lead → customer transitions go through `update_lead_status`, which dispatches the right onboarding path. Don't add DB triggers that bypass this. See `mem://ecommerce/logic-over-triggers`.
- **Firecrawl is the default enrichment source.** Other sources (Apollo, Clearbit) are addable but require adapter + secret.

See also: `mem://crm/manage-leads-status-alias-mapping`, `mem://crm/sales-intelligence-and-lead-loop-unified`, `mem://architecture/business-identity-strategic-hub`, `mem://ecommerce/customer-management-architecture`.
