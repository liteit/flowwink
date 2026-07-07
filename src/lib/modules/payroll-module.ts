/**
 * Payroll Module (SE-locale MVP)
 *
 * Manages monthly payroll runs:
 *  - create_payroll_run: snapshot active employees + recurring components into draft lines
 *  - apply_pension / apply_sick_pay: draft-run adjustments (idempotent, replace-not-compound)
 *  - approve_payroll_run: post wage journal (Dt 7210/7410/7510, Cr 2710/2731/2890/2950)
 *  - mark_payroll_paid: post bank disbursement (Dt 2890 / Cr 1930)
 *
 * Defaults: 31.42% employer social fee, 30% PAYE schablon (override per employee).
 * Multi-locale, AGI export, FORA, and pension files come in later iterations.
 */
import { z } from 'zod';
import { defineModule } from '@/lib/module-def';
import type { SkillSeed } from '@/lib/module-bootstrap';

const inputSchema = z.object({
  action: z.enum(['create_run', 'approve', 'mark_paid', 'list_runs', 'list_lines']),
});
const outputSchema = z.object({ success: z.boolean(), result: z.unknown().optional() });
type Input = z.infer<typeof inputSchema>;
type Output = z.infer<typeof outputSchema>;

const SKILLS: SkillSeed[] = [
  {
    name: 'create_payroll_run',
    description:
      'Create a draft payroll run for one month. Snapshots all active employees with their monthly_salary_cents + recurring payroll_components into payroll_lines. Computes gross, taxable, PAYE tax, employer social fee (31.42%), and net per employee. Use when: starting month-end payroll. NOT for: ad-hoc bonuses (use a one-off non-recurring component first).',
    category: 'commerce',
    handler: 'rpc:mcp_create_payroll_run',
    scope: 'internal',
    trust_level: 'notify',
    tool_definition: {
      type: 'function',
      function: {
        name: 'create_payroll_run',
        description: 'Create a draft payroll run for the given period.',
        parameters: {
          type: 'object',
          properties: {
            period_date: { type: 'string', description: 'YYYY-MM-DD anywhere in the target month. Defaults to current month.' },
          },
        },
      },
    },
  },
  {
    name: 'approve_payroll_run',
    description:
      'Approve a draft payroll run and post the wage journal entry (Dt 7210 wages, Dt 7510 social fees, Dt 7410 employer pension / Cr 2710 PAYE, Cr 2731 social fee liability, Cr 2950 pension liability, Cr 2890 net wage liability). Use when: payroll has been reviewed and is ready for posting. Requires admin.',
    category: 'commerce',
    handler: 'rpc:mcp_approve_payroll_run',
    scope: 'internal',
    trust_level: 'approve',
    tool_definition: {
      type: 'function',
      function: {
        name: 'approve_payroll_run',
        description: 'Post the wage journal for an approved run.',
        parameters: {
          type: 'object',
          properties: { run_id: { type: 'string', description: 'UUID of the payroll run.' } },
          required: ['run_id'],
        },
      },
    },
  },
  {
    name: 'mark_payroll_paid',
    description:
      'Mark an approved payroll run as paid and post the bank disbursement (Dt 2890 / Cr 1930). Use when: net wages have been transferred from the bank. NOT for: PAYE/social fee payment to Skatteverket (separate entry against 2710/2731).',
    category: 'commerce',
    handler: 'rpc:mcp_mark_payroll_paid',
    scope: 'internal',
    trust_level: 'approve',
    tool_definition: {
      type: 'function',
      function: {
        name: 'mark_payroll_paid',
        description: 'Post bank payment for net wages.',
        parameters: {
          type: 'object',
          properties: {
            run_id: { type: 'string' },
            payment_date: { type: 'string', description: 'YYYY-MM-DD. Defaults today.' },
          },
          required: ['run_id'],
        },
      },
    },
  },
  {
    name: 'list_payroll_runs',
    description: 'List recent payroll runs with status and totals. Use when: viewing payroll history or generating reports.',
    category: 'commerce',
    handler: 'rpc:mcp_list_payroll_runs',
    scope: 'internal',
    trust_level: 'auto',
    tool_definition: {
      type: 'function',
      function: {
        name: 'list_payroll_runs',
        description: 'List payroll runs.',
        parameters: { type: 'object', properties: { limit: { type: 'integer', default: 24 } } },
      },
    },
  },
  {
    name: 'list_payroll_lines',
    description: 'List per-employee payroll lines for a specific run. Use when: reviewing or auditing a payroll run.',
    category: 'commerce',
    handler: 'rpc:mcp_list_payroll_lines',
    scope: 'internal',
    trust_level: 'auto',
    tool_definition: {
      type: 'function',
      function: {
        name: 'list_payroll_lines',
        description: 'List payroll lines for a run.',
        parameters: { type: 'object', properties: { run_id: { type: 'string' } }, required: ['run_id'] },
      },
    },
  },
  {
    name: 'apply_pension',
    description: 'Apply occupational pension to a DRAFT payroll run (employer contribution + optional employee deduction, as a % of gross). Use when: adding tjänstepension before approving a run. NOT for: a posted/approved run (immutable). Idempotent — re-run to change the rate.',
    category: 'system',
    handler: 'rpc:apply_pension',
    scope: 'internal',
    tool_definition: {
      type: 'function',
      function: {
        name: 'apply_pension',
        description: 'Per-line pension on gross for a draft run. Employee % reduces net; recomputes run totals (total_pension_employer/employee_cents). Re-running replaces (no compounding).',
        parameters: {
          type: 'object',
          required: ['p_run_id', 'p_employer_pct'],
          properties: {
            p_run_id: { type: 'string', format: 'uuid' },
            p_employer_pct: { type: 'number', description: 'Employer pension % of gross (e.g. 4.5)' },
            p_employee_pct: { type: 'number', description: 'Employee pension % of gross, deducted from net (default 0)' },
          },
        },
      },
    },
    instructions: 'Only valid on a draft run. Employer pension is an additional cost (not part of net); employee pension is deducted from net. Idempotent: re-running with a new pct restores net from the prior employee pension first. Admin/service-role only.',
  },
  {
    name: 'apply_sick_pay',
    description:
      'Apply Swedish statutory sick pay (sjuklön) as an adjustment on one employee\'s line in a DRAFT payroll run: deducts ordinary salary for the sick days, adds 80% sick pay for the employer period (days 1–14) minus one karensavdrag, and recomputes tax, social fee and net. Use when: an employee was sick during the payroll month. NOT for: estimating amounts without writing (calc_sick_pay); approved/paid runs (immutable). Idempotent — re-run with a new day count to replace, 0 to reset.',
    category: 'system',
    handler: 'rpc:apply_sick_pay',
    scope: 'internal',
    trust_level: 'notify',
    tool_definition: {
      type: 'function',
      function: {
        name: 'apply_sick_pay',
        description:
          'Adjust one employee\'s draft payroll line for sick days: −(daily × sick_days) salary deduction, +sjuklön via calc_sick_pay; recomputes tax/social/net and run totals. Re-running replaces (no compounding).',
        parameters: {
          type: 'object',
          required: ['p_run_id', 'p_employee_id', 'p_sick_days'],
          properties: {
            p_run_id: { type: 'string', format: 'uuid', description: 'Draft payroll run id' },
            p_employee_id: { type: 'string', format: 'uuid', description: 'Employee whose line to adjust' },
            p_sick_days: { type: 'number', description: 'Sick days in the period (0 resets the adjustment)' },
            p_work_days_per_month: { type: 'number', description: 'Default 21' },
          },
        },
      },
    },
    instructions:
      'Only valid on a draft run; the employee must have a line on it. Uses the employee\'s monthly_salary_cents and tax_rate_pct. Apply sick pay BEFORE apply_pension — pension is a % of gross, so re-run apply_pension afterwards if it was already applied (the result carries a reminder note). Admin/service-role only.',
  },
  {
    name: 'calc_sick_pay',
    description: 'Compute Swedish statutory sick pay (sjuklön) for the employer period (days 1–14) at 80% with one karensavdrag. Use when: estimating sick pay for a payroll adjustment. Pure calculator — does not write.',
    category: 'system',
    handler: 'rpc:calc_sick_pay',
    scope: 'internal',
    tool_definition: {
      type: 'function',
      function: {
        name: 'calc_sick_pay',
        description: '80% × daily salary × min(sick_days,14) − one karensavdrag (20% of a 5-day 80% week). Returns sick_pay_cents + breakdown.',
        parameters: {
          type: 'object',
          required: ['p_monthly_salary_cents', 'p_sick_days'],
          properties: {
            p_monthly_salary_cents: { type: 'number' },
            p_sick_days: { type: 'number' },
            p_work_days_per_month: { type: 'number', description: 'Default 21' },
          },
        },
      },
    },
    instructions: 'Statutory model: employer pays days 1–14 (cap), 80% of daily salary, minus one karensavdrag (= 0.8 × daily). Returns sick_pay_cents (net), gross_sick_pay_cents, karensavdrag_cents, paid_sick_days, capped. Read-only.',
  },
  {
    name: 'manage_salary_structure',
    description:
      'Configure reusable salary structures (base salary + components: fixed or % of base, earning/benefit/deduction) and assign them to employees. Assigned structures are applied automatically on the next payroll run. Use when: standardizing pay packages (e.g. "Senior Engineer" = base + 5% bonus + car benefit). NOT for: one-off per-employee items (payroll_components table via manage_employee flows).',
    category: 'system',
    handler: 'rpc:manage_salary_structure',
    scope: 'internal',
    tool_definition: {
      type: 'function',
      function: {
        name: 'manage_salary_structure',
        description: 'create/update/delete/list/get structures; add_component/update_component/remove_component; assign/unassign employees. Components: p_amount_cents fixed OR p_pct_of_base.',
        parameters: {
          type: 'object',
          required: ['p_action'],
          properties: {
            p_action: { type: 'string', enum: ['create', 'update', 'delete', 'list', 'get', 'add_component', 'update_component', 'remove_component', 'assign', 'unassign'] },
            p_structure_id: { type: 'string', format: 'uuid' },
            p_name: { type: 'string', description: 'Structure name (create; also resolves get)' },
            p_description: { type: 'string' },
            p_base_salary_cents: { type: 'integer', description: 'Fallback base when the employee has no monthly_salary_cents' },
            p_active: { type: 'boolean' },
            p_component_id: { type: 'string', format: 'uuid' },
            p_label: { type: 'string', description: 'Component label, e.g. "Performance bonus"' },
            p_component_type: { type: 'string', enum: ['salary', 'bonus', 'overtime', 'benefit', 'deduction'] },
            p_amount_cents: { type: 'integer', description: 'Fixed component amount' },
            p_pct_of_base: { type: 'number', description: 'Percentage of the base salary (overrides p_amount_cents)' },
            p_taxable: { type: 'boolean', default: true },
            p_employee_id: { type: 'string', format: 'uuid', description: 'assign/unassign target' },
          },
        },
      },
    },
    instructions:
      'Structure components are added on top of the employee\'s own salary and recurring payroll_components at create_payroll_run time (tagged source:"structure" on the line). The structure\'s base_salary_cents is only used when the employee\'s monthly_salary_cents is 0. Admin/service-role only.',
  },
  {
    name: 'manage_payroll_country',
    description:
      'Multi-country payroll: manage per-country statutory profiles (employer social fee %, default tax %, currency) and assign a payroll country to employees. Seeded with SE/NO/DK/FI/DE. Use when: employing staff outside Sweden, adjusting statutory rates for a new year. NOT for: per-employee tax overrides (employees.tax_rate_pct wins).',
    category: 'system',
    handler: 'rpc:manage_payroll_country',
    scope: 'internal',
    tool_definition: {
      type: 'function',
      function: {
        name: 'manage_payroll_country',
        description: 'upsert/list/delete payroll_country_profiles; assign_employee sets employees.payroll_country. The profile drives the employer social fee on run creation and sick pay.',
        parameters: {
          type: 'object',
          required: ['p_action'],
          properties: {
            p_action: { type: 'string', enum: ['upsert', 'list', 'delete', 'assign_employee'] },
            p_country_code: { type: 'string', description: 'ISO-2, e.g. NO' },
            p_name: { type: 'string' },
            p_employer_social_pct: { type: 'number', description: 'Employer social fee % of taxable pay' },
            p_default_tax_pct: { type: 'number', description: 'Default PAYE % for employees in this country' },
            p_currency: { type: 'string' },
            p_notes: { type: 'string' },
            p_employee_id: { type: 'string', format: 'uuid', description: 'assign_employee target' },
          },
        },
      },
    },
    instructions:
      'create_payroll_run reads the employee\'s payroll_country profile for the employer social fee (SE 31.42% fallback). The per-employee tax_rate_pct still wins over the country default. SE cannot be deleted. Admin/service-role only.',
  },
  {
    name: 'manage_salary_advance',
    description:
      'Salary advances/loans: grant an advance (posts Dt 1610 / Cr 1930), list per employee, cancel (posts the reversal). Open advances are deducted from net pay on the next payroll run and settled (Cr 1610) when the run is approved. Use when: an employee requests part of their salary early. NOT for: expense advances (expenses module).',
    category: 'system',
    handler: 'rpc:manage_salary_advance',
    scope: 'internal',
    trust_level: 'approve',
    tool_definition: {
      type: 'function',
      function: {
        name: 'manage_salary_advance',
        description: 'grant/list/cancel salary_advances. Lifecycle: open → repaying (deducted on a draft run) → repaid (run approved). Only open advances can be cancelled.',
        parameters: {
          type: 'object',
          required: ['p_action'],
          properties: {
            p_action: { type: 'string', enum: ['grant', 'list', 'cancel'] },
            p_advance_id: { type: 'string', format: 'uuid' },
            p_employee_id: { type: 'string', format: 'uuid' },
            p_amount_cents: { type: 'integer', description: 'grant: advance amount (> 0)' },
            p_reason: { type: 'string' },
            p_granted_date: { type: 'string', description: 'YYYY-MM-DD (default today)' },
            p_post_journal: { type: 'boolean', default: true, description: 'grant: post the disbursement journal' },
          },
        },
      },
    },
    instructions:
      'The full open amount is deducted from net on the next created run (skipped with advances_skipped_cents when it exceeds the month\'s net — cancel and re-grant a smaller advance for partial repayment). Approving the run marks the advance repaid and credits 1610. Admin/service-role only.',
  },
  {
    name: 'apply_tax_correction',
    description:
      'Apply a preliminary-tax correction to one employee\'s line on a DRAFT payroll run (positive delta withholds more, negative refunds too-much-withheld tax). Use when: fixing a wrong tax table, jämkning decisions, retro corrections carried into the current month. NOT for: posted runs (correct on next month\'s draft) or changing the standing rate (employees.tax_rate_pct).',
    category: 'system',
    handler: 'rpc:apply_tax_correction',
    scope: 'internal',
    trust_level: 'notify',
    tool_definition: {
      type: 'function',
      function: {
        name: 'apply_tax_correction',
        description: 'tax_cents += delta, net_cents −= delta on the employee\'s draft line; run totals recomputed; correction logged in components and tax_correction_cents. Cumulative per call.',
        parameters: {
          type: 'object',
          required: ['p_run_id', 'p_employee_id', 'p_tax_delta_cents'],
          properties: {
            p_run_id: { type: 'string', format: 'uuid', description: 'Draft payroll run' },
            p_employee_id: { type: 'string', format: 'uuid' },
            p_tax_delta_cents: { type: 'integer', description: 'Positive = withhold more, negative = refund' },
            p_reason: { type: 'string', description: 'Shown on the payslip' },
          },
        },
      },
    },
    instructions:
      'Corrections are cumulative — each call adds its delta (send the opposite delta to undo). Draft runs only. Survives apply_sick_pay recomputes (tracked in tax_correction_cents). Admin/service-role only.',
  },
  {
    name: 'get_payslip',
    description:
      'Structured payslip for one employee+run (employer, period, all components, gross→net breakdown incl. pension/sick pay/advances/tax corrections, YTD totals) — or, without a run id, the list of available payslips. Employees can fetch their OWN payslips (self-service via employees.user_id); admins can fetch anyone\'s. Use when: an employee asks for their payslip, rendering the payslip view, portal self-service. NOT for: run-level auditing (list_payroll_lines).',
    category: 'system',
    handler: 'rpc:get_payslip',
    scope: 'internal',
    trust_level: 'auto',
    tool_definition: {
      type: 'function',
      function: {
        name: 'get_payslip',
        description: 'Payslip JSON for run+employee, or the employee\'s payslip list when p_run_id is omitted. Non-admin callers are locked to their own employee record and to approved/paid runs.',
        parameters: {
          type: 'object',
          properties: {
            p_run_id: { type: 'string', format: 'uuid', description: 'Omit to list available payslips' },
            p_employee_id: { type: 'string', format: 'uuid', description: 'Required for admins; ignored/own for employees' },
          },
        },
      },
    },
    instructions:
      'Self-service resolves the employee via employees.user_id = auth.uid(). YTD covers approved/paid runs in the same calendar year up to the requested period. Render with amounts in cents; employer block comes from site_settings site_name.',
  },
  {
    name: 'year_end_payroll_summary',
    description:
      'Year-end tax certification data: per-employee annual gross, benefits, withheld tax, employer social fees, pension and net over all approved/paid runs of a year (KU/kontrolluppgift-style income statements). Use when: closing the payroll year, answering "what did we pay X in 2026". NOT for: the monthly Skatteverket declaration (generate_agi_export).',
    category: 'system',
    handler: 'rpc:year_end_payroll_summary',
    scope: 'internal',
    trust_level: 'auto',
    tool_definition: {
      type: 'function',
      function: {
        name: 'year_end_payroll_summary',
        description: 'Per-employee + total annual payroll aggregates for a calendar year.',
        parameters: {
          type: 'object',
          properties: {
            p_year: { type: 'integer', description: 'Calendar year (default: current year)' },
          },
        },
      },
    },
  },
  {
    name: 'generate_agi_export',
    description:
      'Tax-authority integration: generate the monthly AGI declaration (arbetsgivardeklaration på individnivå) as Skatteverket-style XML — HU totals (social fees FK487, withheld tax FK497) plus one IU per employee (FK215/FK011/FK001). Use when: monthly employer declaration after approving payroll. NOT for: bank/Fortnox salary files (Fortnox CSV + PAXML export) or year-end summaries (year_end_payroll_summary).',
    category: 'system',
    handler: 'rpc:generate_agi',
    scope: 'internal',
    trust_level: 'notify',
    tool_definition: {
      type: 'function',
      function: {
        name: 'generate_agi_export',
        description: 'AGI XML + totals for the approved/paid run(s) of one month. Fails with reason no_data until the run is approved.',
        parameters: {
          type: 'object',
          properties: {
            p_period: { type: 'string', description: 'YYYY-MM-DD anywhere in the target month (default: current month)' },
          },
        },
      },
    },
    instructions:
      'Amounts are whole SEK (öre rounded) per AGI convention. Set site_settings key org_number for a complete file; employees without personal_number are marked SAKNAS — fix and regenerate before filing. Upload the XML via Skatteverket\'s file transfer service.',
  },
];

export const payrollModule = defineModule<Input, Output>({
  id: 'payroll',
  name: 'Payroll',
  version: '1.0.0',
  processes: ['hire-to-retire', 'record-to-report'],
  maturity: 'L4',
  description:
    'Monthly payroll runs: snapshots employees + recurring components + salary structures, per-country statutory profiles (SE default: 31.42% social fee), pension (tjänstepension), statutory sick pay (sjuklön), tax corrections and salary advances on draft runs, wage journals (BAS 7210/7410/7510/1610/2710/2731/2890/2950), payslips with employee self-service, year-end certification summaries, and AGI XML export to Skatteverket.',
  requires: ['hr'],
  capabilities: ['data:read', 'data:write'],
  tier: 'extended',
  inputSchema,
  outputSchema,
  skills: ['create_payroll_run', 'approve_payroll_run', 'mark_payroll_paid', 'list_payroll_runs', 'list_payroll_lines', 'apply_pension', 'apply_sick_pay', 'calc_sick_pay', 'manage_salary_structure', 'manage_payroll_country', 'manage_salary_advance', 'apply_tax_correction', 'get_payslip', 'year_end_payroll_summary', 'generate_agi_export'],
  data: {
    tables: ['payroll_export_lines', 'payroll_exports', 'payroll_lines', 'payroll_runs', 'payroll_components', 'salary_structure_components', 'salary_structures', 'salary_advances', 'payroll_country_profiles'],
  },
  skillSeeds: SKILLS,
  // No publish() — Payroll exposes its behaviour exclusively through MCP skills
  // (mcp_create_payroll_run, mcp_approve_payroll_run, mcp_mark_payroll_paid).
  // The registry returns a clear "no_publish_handler" error for direct calls.
});
