# Record-to-Report

> From transaction to financial report. Bookkeeping + period-end close.

**Maturity level:** L3 — Operational (period lock + reconciliation live)
**Status:** ✅ Double-entry bookkeeping, period lock, bank file/image OCR import; ⚠️ no tax filings

---

## Modules involved

| Module | Role in the process |
|--------|---------------------|
| **Accounting** | Chart of accounts (BAS 2024 / IFRS / US GAAP via locale packs), journal entries, templates, period lock, export adapters (SIE 4 / SAF-T) |
| **Reconciliation** | Stripe payouts sync, bank file/image (OCR) import, auto-matching |
| **Invoicing** | Source for AR bookings |
| **Expenses** | Source for AP / expense bookings (auto-booked on approval) |
| **Analytics** | Financial KPI reports |
| **Documents** | Voucher / supporting document archive |

---

## Step-by-step flow

```
Business event (invoice, expense, payroll run)
       ↓
suggest_accounting_template → matches against template
       ↓
Journal entry created (manage_journal_entry)
       ↓
Review (manual)
       ↓
Booking saved
       ↓
[Periodic] Reconciliations
       ↓
[Periodic] Period-end close
       ↓
accounting_reports (BS, P&L, general ledger)
```

---

## Agent coverage

| Step | 👤 Manual | 🤖 FlowPilot | 🔗 External agent |
|------|----------|-------------|-------------------|
| Chart of accounts setup | ✅ | ✅ (`manage_chart_of_accounts`) | — |
| Template management | ✅ | ✅ (`manage_accounting_template`) | — |
| Booking suggestion | — | ✅ (`suggest_accounting_template`) | — |
| Journal entries | ✅ | ✅ (`manage_journal_entry`) | — |
| Opening balances | ✅ | ✅ (`manage_opening_balances`) | — |
| Reconciliations | ✅ | ⚠️ Partial (autonomous reconciliation) | — |
| Reports | ✅ | ✅ (`accounting_reports`) | — |
| Period-end close | ✅ | ✅ (`close_accounting_period`, `reopen_accounting_period`) | — |
| Tax reporting | ❌ Missing | — | — |

---

## Known gaps (missing for L4+)

- ✅ **Period-end close workflow** — `close_accounting_period` locks JE + JE-lines + time_entries via guard triggers
- ❌ Tax reporting (VAT, employer reports, K10)
- ✅ SIE export — pluggable adapters per locale pack (SE → SIE 4, generic → SAF-T + CSV)
- ✅ Bank feed / reconciliation — `import_bank_file`, `import_bank_image` (OCR), `sync_stripe_payouts`, `auto_match_transactions`
- ❌ Multi-currency revaluation
- ⚠️ Cost center / project-level — `manage_analytic_account` + `tag_journal_entry_analytics` exist; reporting limited
- ❌ Consolidation (multi-entity)

---

## Period close & lock

When `close_accounting_period(year, month)` is called (skill `close_accounting_period`, or via `lock_timesheet_period`):

| Table | Guard trigger | Effect |
|-------|---------------|--------|
| `journal_entries` | `guard_journal_entries_period` | Insert/update/delete blocked for entry_date in closed period |
| `journal_entry_lines` | `guard_journal_entry_lines_period` | Same, propagated through parent entry |
| `time_entries` | `guard_time_entries_period` ✨ | Insert/update/delete blocked — protects payroll & invoicing cutoffs |

Reopen via `reopen_accounting_period(year, month)` (admin only). Periods in `locked` state cannot be reopened.

---

## Webhook events

`invoice.created`, `invoice.paid`, `expense.status_changed`

---

## Best for

Smaller companies that want internal visibility into their finances, complementing an external accountant for filings.

## Not for

Companies looking to fully replace Fortnox/Visma — we are not a complete accounting system yet. Position us as "operational finance" rather than "filings".
