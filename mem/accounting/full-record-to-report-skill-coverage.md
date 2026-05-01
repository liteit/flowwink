---
name: Full Record-to-Report Skill Coverage
description: Status över hur expense P2P + reconciliation-skills är registrerade i modul-manifesten vs SQL-migrationer. Källkoden är nu sanningen — alla skillSeeds bor i sin modul.
type: feature
---

**Källkoden är sanningen.** Alla expense P2P-skills är nu fulla `SkillSeed`-objekt i `expenses-module.ts → EXPENSE_SKILLS` (handler `rpc:*`). Module reset (disable→enable) återinstallerar dem korrekt utan att behöva köra om migrationen.

**Expenses (i `EXPENSE_SKILLS` + `skills[]`):**
- `manage_expenses`, `analyze_receipt`
- `generate_monthly_expense_report` (auto), `submit_expense_report` (notify)
- `approve_expense_report`, `book_expense_report`, `mark_expense_report_paid` (alla approve)
- `list_expense_reports` (notify)

**Reconciliation (i `RECONCILIATION_SKILLS` + `skills[]`):**
- `import_bank_image` (full seed)
- `sync_stripe_payouts`, `import_bank_file`, `auto_match_transactions` — bara namn i `skills[]`, fortfarande seedade via legacy-bootstrap. TODO: lyft in som fulla SkillSeed-objekt.

**Accounting äger:** `manage_journal_entry`, `tag_journal_entry_analytics` — inte reconciliation eller expenses.

**Lärdom:** SQL-migration som seedar agent_skills är en engångsbootstrap. Sanningen ska bo i modulens `skillSeeds[]`. När du upptäcker en skill som finns i DB men inte i seeds → flytta in den, ta inte bara med namnet i `skills[]`.
