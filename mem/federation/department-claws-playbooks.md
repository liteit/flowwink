---
name: department-claws-playbooks
description: Six department playbooks (marketing/sales/support/success/finance/operations) covering MCP groups, end-to-end loops, approval gating
type: feature
---

Six department playbooks live under `docs/agents/`:

- `marketing-claw-playbook.md` — paid ads + content + research
- `sales-claw-playbook.md` — prospect → deal → quote → contract
- `support-claw-playbook.md` — triage → KB answer → SLA monitor
- `success-claw-playbook.md` — health scan → outreach → expansion → churn save
- `finance-claw-playbook.md` — invoice → bank OCR → reconcile → expense P2P → close
- `operations-claw-playbook.md` — order fulfillment → stock → PO → goods receipt → POS close
- `README.md` — index

Each playbook documents: connect, `?groups=<name>` toolkit, end-to-end JSON-RPC loop, approval gating per skill (notify vs approve), what's NOT exposed (a2a/openclaw/setup_flowpilot), audit & rate limits, related memory.

Pattern: one external claw owns one department per site. FlowPilot = generalist; claws = specialists. All loops use only MCP-exposed skills — no FlowPilot calls required.

Approval-heavy departments: finance (most writes gated), operations (PO send + stock adjust gated). Light: marketing (only `ad_optimize`), sales (drafts only), support (standard CRUD), success (only cancel gated).
