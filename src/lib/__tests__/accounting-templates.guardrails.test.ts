/**
 * Guardrail: every BAS-2024 accounting template must be bookable.
 *
 * An agent books via template percentage-expansion (manage_journal_entry
 * {template_id, amount_cents}) — a template whose lines don't balance books an
 * unbalanced verifikat, and one referencing an account code missing from the
 * chart produces journal lines pointing at nothing (the year-end stub shipped
 * with 8811/2125/8850 while the chart had none of them — this class).
 *
 * Checks:
 *  - sum(debit_pct) === sum(credit_pct) for every template
 *  - every account_code exists in BAS_2024_ACCOUNTS
 *  - account_name matches the chart's name for that code (agents read both;
 *    a mismatch is confusing at best, silently wrong at worst)
 *  - keywords non-empty (the matching engine scores on keywords)
 *  - template names unique per locale (the seeding top-up dedupes by name)
 *  - the sePack year_end proposals reference only chart accounts
 */
import { describe, expect, it } from 'vitest';
import { BAS_2024_ACCOUNTS } from '@/data/bas2024-accounts';
import { BAS_2024_TEMPLATES } from '@/data/templates-bas2024';
import { sePack } from '@/lib/locale-packs/se';

const chart = new Map(
  (BAS_2024_ACCOUNTS as Array<{ account_code: string; account_name: string }>).map(
    (a) => [a.account_code, a.account_name],
  ),
);

interface TplLine {
  account_code: string;
  account_name: string;
  debit_pct: number;
  credit_pct: number;
}
interface Tpl {
  template_name: string;
  keywords?: string[];
  template_lines: TplLine[];
}

const templates = BAS_2024_TEMPLATES as unknown as Tpl[];

describe('BAS 2024 accounting templates guardrails', () => {
  it('has a meaningful template library (sanity)', () => {
    expect(templates.length).toBeGreaterThanOrEqual(80);
  });

  it('template names are unique (seed top-up dedupes by name)', () => {
    const names = templates.map((t) => t.template_name);
    const dupes = names.filter((n, i) => names.indexOf(n) !== i);
    expect(dupes, `Duplicate template names: ${dupes.join(', ')}`).toEqual([]);
  });

  for (const tpl of templates) {
    describe(`[${tpl.template_name}]`, () => {
      it('balances (Σ debit_pct === Σ credit_pct)', () => {
        const d = tpl.template_lines.reduce((s, l) => s + (l.debit_pct || 0), 0);
        const c = tpl.template_lines.reduce((s, l) => s + (l.credit_pct || 0), 0);
        expect(
          Math.abs(d - c) < 0.001,
          `Unbalanced template: debit ${d} ≠ credit ${c} — booking it creates an unbalanced verifikat.`,
        ).toBe(true);
      });

      it('references only chart accounts, with matching names', () => {
        for (const l of tpl.template_lines) {
          expect(
            chart.has(l.account_code),
            `Account ${l.account_code} (“${l.account_name}”) is not in BAS_2024_ACCOUNTS — add it to the chart or fix the code.`,
          ).toBe(true);
          expect(
            chart.get(l.account_code),
            `account_name mismatch for ${l.account_code}: template says “${l.account_name}”, chart says “${chart.get(l.account_code)}”.`,
          ).toBe(l.account_name);
        }
      });

      it('has keywords for the matching engine', () => {
        expect((tpl.keywords ?? []).length).toBeGreaterThan(0);
      });
    });
  }

  it('sePack year-end proposals reference only chart accounts', async () => {
    const proposals = await sePack.year_end_proposals!(2026);
    for (const p of proposals) {
      for (const l of p.lines) {
        expect(
          chart.has(l.account_code),
          `year_end proposal “${p.id}” references ${l.account_code} which is not in the chart.`,
        ).toBe(true);
      }
    }
  });
});
