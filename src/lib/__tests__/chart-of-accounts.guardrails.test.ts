import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { BAS_2024_ACCOUNTS } from '@/data/bas2024-accounts';

/**
 * Guardrail: an install must never run with a chart of accounts that the
 * bookkeeping RPCs post outside of.
 *
 * Live finding (demo clean install, 2026-07-20): chart_of_accounts held FIVE
 * rows — exactly the ones two migrations happen to INSERT ad hoc for their own
 * needs. Meanwhile mark_expense_report_paid, dispose_fixed_asset and the
 * payroll bank posting hardcode 1930/2890/3970/7970 as defaults. Account 1930
 * was present in journal_entry_lines (from fixed_asset_register) but absent
 * from the chart, so the balance sheet could not classify it and reported
 * balanced:false.
 *
 * The data was never missing — src/data/bas2024-accounts.ts has ~250 accounts
 * and the SE pack points at them. The SEEDING was unreachable:
 * topUpLocalePackSeeds() runs from useTenantLocalePack(), which was mounted
 * only on Accounting → Settings and the Locale Packs page. "Boot-time top-up"
 * in practice meant "if an admin happens to open one of two pages".
 *
 * Two properties are locked here. Both are cheap; neither was checked before.
 */

const root = process.cwd();

/**
 * Every account code the SE pack maps a ROLE to.
 *
 * This used to scan migrations for hardcoded `DEFAULT '1930'` parameters and
 * assert each one existed in BAS_2024_ACCOUNTS. That test did real work at the
 * time — it is how the eleven missing accounts were found — but it encoded
 * "the platform is Swedish" and would have blocked the move to account roles.
 * The RPCs no longer name accounts at all; the pack does, through
 * account_roles. So the question becomes: does every account this pack
 * PROMISES actually exist in the chart it ships?
 *
 * The country-neutrality half now lives in account-roles.guardrails.test.ts.
 */
function packRoleAccounts(): Map<string, string[]> {
  const dir = join(root, 'supabase/migrations');
  const f = readdirSync(dir).find((x) => x.includes('account-roles'));
  expect(f, 'the account-roles migration is gone').toBeTruthy();
  const sql = readFileSync(join(dir, f!), 'utf8');
  const found = new Map<string, string[]>();
  for (const m of sql.matchAll(/'se-bas2024',\s*'([a-z_]+)',\s*'(\d{4})'/g)) {
    found.set(m[2], [...(found.get(m[2]) ?? []), `role ${m[1]}`]);
  }
  return found;
}

describe('chart of accounts', () => {
  const codes = new Set(BAS_2024_ACCOUNTS.map((a) => a.account_code));

  it('the SE pack ships a real chart, not a handful of accounts', () => {
    // 5 rows on a fresh install is the failure this test exists for.
    expect(BAS_2024_ACCOUNTS.length).toBeGreaterThan(100);
  });

  it('every account the pack maps a role to exists in the chart it ships', () => {
    // A role pointing at a code the chart lacks is the same failure as before,
    // one level up: bookkeeping posts somewhere the balance sheet cannot
    // classify. It is now a pack-completeness question, which is exactly where
    // a country's problems should live.
    const missing: string[] = [];
    for (const [code, roles] of packRoleAccounts()) {
      if (!codes.has(code)) missing.push(`${code} (${roles.join(', ')})`);
    }
    expect(
      missing,
      'these role targets are not in BAS_2024_ACCOUNTS — the pack promises an ' +
        'account it does not ship',
    ).toEqual([]);
  });

  it('the seed runs for every admin session, not just the accounting pages', () => {
    // The bug was reachability, so pin the mount point rather than the seeding
    // logic (which was correct all along).
    const layout = readFileSync(join(root, 'src/components/admin/AdminLayout.tsx'), 'utf8');
    expect(layout).toContain('useLocalePackBootstrap');

    const hook = readFileSync(join(root, 'src/hooks/useTenantLocalePack.ts'), 'utf8');
    expect(hook).toMatch(/export function useLocalePackBootstrap/);
    // A swallowed warn is invisible in production; this failure must not be.
    expect(hook).toMatch(/logger\.error\('\[locale-pack\] boot top-up failed'/);
  });

  it('every template line posts to an account its OWN pack ships', () => {
    // The bookkeeping templates are what propose_bookkeeping matches bank
    // events against — the layer that lets an agent book correctly. A template
    // line pointing outside its pack's chart books to an account the balance
    // sheet cannot classify. Checked per pack: the generic pack's templates
    // must not lean on Swedish BAS accounts, and vice versa.
    const artifact = JSON.parse(
      readFileSync(join(root, 'supabase/seed/locale-packs.json'), 'utf8'),
    );
    expect(artifact.packs.length).toBeGreaterThan(0);
    const bad: string[] = [];
    for (const pack of artifact.packs) {
      const chart = new Set(pack.accounts.map((a: any) => a.account_code));
      expect(
        pack.templates?.length ?? 0,
        `${pack.id} ships no templates — the artifact lost them (liteit ran a ` +
          'proof week on 15 of 98 the last time this path was silently missing)',
      ).toBeGreaterThan(0);
      for (const t of pack.templates) {
        for (const line of t.template_lines ?? []) {
          if (line.account_code && !chart.has(line.account_code)) {
            bad.push(`${pack.id} / "${t.template_name}" → ${line.account_code}`);
          }
        }
      }
    }
    expect(bad, `template lines outside their pack's chart:\n${bad.join('\n')}`).toEqual([]);
  });

  it('chart rows carry the fields the balance sheet classifies on', () => {
    // A row without account_type is what produced balanced:false.
    const bad = BAS_2024_ACCOUNTS.filter(
      (a) => !a.account_code || !a.account_type || !a.normal_balance,
    );
    expect(bad.map((a) => a.account_code)).toEqual([]);
  });
});
