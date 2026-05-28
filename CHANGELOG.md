# Changelog

All notable changes to FlowWink will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2026-05-28

### Added
- **Demo Data Platform**: Safe module reset & simulation data seeding (`seed_module_demo`, `reset_module_data`) with `demo_runs`/`demo_run_items` tracking
- **Order Tracking**: Public `/track/:id` page + admin fulfillment view with full event audit log
- **Platform Tests**: Unified `/admin/platform-tests` replacing smoke tests with module-aware suites, CI guardrails, and instance health dashboard
- **User Role Guardrails**: Automated test suite preventing role assignment regressions in `handle_new_user` trigger and edge functions
- **Demo Mode**: Toggle in `/admin/settings/general` controlling hourly `demo-cycle` reset job; demo login banner on auth page
- **Workspace Chat**: Internal RAG-powered chat over documents/contracts/knowledge base with citations
- **Expense Procure-to-Pay Loop**: Full lifecycle (draft→submitted→approved→booked→paid) with BAS 2024 defaults
- **OCR Bank Statement Import**: Vision-based preview→commit flow via `reconciliation-import-image` edge function
- **POS v2 (Odoo-style)**: Barcode support, split tender payments, session-based batch journal on close
- **Stock Event Listener**: Automatic inventory movement on POS sales via `stock.movement` platform events
- **Invoice-driven Subscriptions**: Manual subscription billing with daily cron invoice generation
- **Staged Operations Envelope**: Human-in-the-loop approval for sensitive skills (journal entries, expense booking, period close)
- **Voucher Integrity**: Auto-assigned voucher numbers with gap detection and explanation tools
- **Year-End Readiness**: 6-point checklist RPC for accounting period closure
- **Contract Templates**: 4 seeded templates + `create_contract_from_template` with anti-hallucination guards
- **Unified Sales Lead Loop**: Firecrawl-enriched lead scoring with normalized status aliases
- **Agent Document Upload**: MCP-exposed skill for peers to upload text/PDF to the document vault
- **Document Shadow Markdown**: Extracted text shadow for full-text search in workspace chat
- **Marketing Claw Department Pattern**: Composite MCP groups for external marketing agent operation
- **Federation Directional Connections**: Multi-channel peer architecture (MCP, A2A, /v1/responses)
- **HR Auto-Contract Loop**: `hire_application` RPC — application→employee + draft contract + onboarding checklist in one transaction
- **Timesheet Period Lock**: Accounting period close also locks time entries
- **HR Vacation Auto-Allocation**: Yearly vacation day allocation with audit logging
- **Unsplash Config Hint**: Admin alert when image API key is missing during block editing
- **Integration Status Truth**: `resolveIntegrationStatus` single source of truth; backend verification errors surfaced in UI

### Changed
- **Removed Clawable module**: Simplified architecture — single FlowWink instance, no multi-agent chat surface
- **Federation cleanup**: Reduced operator missions to 5 core categories aligned with external-agent-as-operator pivot
- **Smoke tests**: Skip disabled modules instead of false failures
- **Database migrations**: Consolidated baseline for cleaner fresh installs
- **Trust levels**: Outbound communication skills now require `approve` instead of `auto`

### Fixed
- **check-secrets edge function**: 403 errors for multi-role users resolved by explicit `admin` role filtering
- **handle_new_user trigger**: No longer assigns redundant `writer` role when `signup_type: "admin"` is specified
- **Demo template**: Fixed demo email credential display (`demo@flowwink.com`)
- **Fresh install UX**: Default modules disabled by default (opt-in); fewer confusing empty states
- **Edge function timeouts**: Fire-and-forget pattern for long-running operations bypassing 60s limits
- **CI**: `skill-linter` exits gracefully without DB URL on GitHub Actions

## [1.2.0] - 2026-02-20

### Added
- **Live Agent Chat Avatars**: Agent profile photos now display in chat widget for personalized support experience
- **Sentiment Detection**: Real-time AI-powered sentiment analysis during conversations
  - Automatic frustration detection (caps, repeated questions, negative words)
  - Configurable threshold (1-10 scale) for human handoff triggers
  - Visual sentiment indicator on Live Support page (green/yellow/red)
- **Human Handoff Improvements**: Enhanced escalation with explicit "speak to human" detection
- **Live Support Dashboard Widget**: New admin dashboard widget showing:
  - Active and waiting conversations
  - Online agent count
  - Average sentiment metrics
  - Quick access to support queue

### Changed
- Support agents table now has public read access for chat widget avatar display
- Improved agent presence detection in chat conversations

### Fixed
- Agent avatars now correctly display for anonymous chat visitors (RLS policy update)
- Profile avatar URL properly fetched from profiles_public view

## [1.1.0] - 2026-01-16

### Added
- **Self-Hosting Setup Script**: Complete CLI-driven setup (`./scripts/setup-supabase.sh`)
  - Automatic Supabase login with interactive prompts
  - Project selection with numbered list
  - Deploy all 33 edge functions automatically
  - Run database migrations
  - Create admin user with proper role assignment
  - Output environment variables for deployment
  - `--fresh` flag for agencies setting up multiple sites
  - `--env` flag to only display environment variables
- **Secrets Configuration Script**: Interactive secrets setup (`./scripts/configure-secrets.sh`)
  - Resend (email)
  - Stripe (payments)
  - OpenAI (AI features)
  - Google Gemini (AI alternative)
  - Firecrawl (web scraping)
  - Unsplash (stock photos)
  - Local LLM (self-hosted AI)
  - N8N (workflow automation)

### Changed
- Auth page branding updated to FlowWink
- Setup documentation rewritten for CLI-first workflow
- Improved error handling in setup scripts

### Fixed
- Environment variables now fetched via `supabase projects api-keys`
- Admin user creation uses Supabase Admin API directly
- Project selection handles deleted projects gracefully

## [1.0.0] - 2026-01-09

### Added

#### Core CMS
- Block-based page builder with 20+ block types
- Visual drag-and-drop block reordering
- Block animation controls and spacing settings
- Page versioning with restore functionality
- SEO meta settings per page
- Scheduled publishing
- Global header and footer blocks
- Menu ordering system

#### Blog Module
- Full blog engine with posts, categories, and tags
- Featured posts support
- Author profiles with avatars
- Reading time calculation
- RSS feed generation
- SEO-optimized blog pages

#### Newsletter Module
- Subscriber management with GDPR compliance
- Email campaigns with tracking (opens, clicks)
- Double opt-in support
- Export functionality
- Unsubscribe handling

#### CRM Modules
- **Leads**: Lead capture, scoring, AI qualification, status tracking
- **Deals**: Kanban board, pipeline stages, activity tracking
- **Companies**: Company profiles, domain enrichment, lead association
- **Products**: Product catalog with pricing (one-time and recurring)
- CSV import/export for leads and companies

#### Knowledge Base
- Hierarchical categories with icons
- FAQ-style articles
- AI Chat integration with context
- Helpful/not helpful voting
- Featured articles

#### Integrations
- Webhook system with event triggers
- N8N workflow templates
- Unsplash image picker
- AI text generation (expand, improve, translate, summarize)
- Brand guide analyzer

#### User Management
- Role-based access control (Writer, Approver, Admin)
- User profiles with avatars
- Activity logging

#### Public Website
- Responsive design with dark/light mode
- Cookie consent banner
- Contact forms with submissions
- Booking forms (Cal.com integration ready)
- Chat widget

### Security
- Row Level Security (RLS) on all tables
- Secure authentication flow
- GDPR-compliant data handling

---

## Upgrade Instructions

See [docs/UPGRADING.md](docs/UPGRADING.md) for detailed upgrade instructions.

## Contributing

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for contribution guidelines.
