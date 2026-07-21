import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Guardrail: the bookkeeping engine must not name a country's accounts.
 *
 * Until 2026-07-21, eleven SECURITY DEFINER functions carried BAS 2024 numbers
 * as parameter defaults — p_bank_account '1930', p_ar_account '1510',
 * p_revenue_account '3001', 24 in all. The engine did not branch on country,
 * it ASSUMED one, which is harder to spot than an `if (country = 'SE')`: a
 * German instance with a German pack activated still posted to 1930 and 3970.
 *
 * The model is the one Magnus named — a WordPress language pack. Core calls a
 * lookup; the pack supplies the value. Defaults are now NULL and resolve
 * through account_for(role) against the instance's active locale. An explicit
 * code still wins, because "post this one to 1930" is a real need.
 *
 * Proven live on demo: the same register_fixed_asset() call posted 1210/1930
 * under se-bas2024 and 0420/1200 under a throwaway de-skr03 pack, with no
 * account arguments passed.
 *
 * NOTE this replaces the account-existence half of
 * chart-of-accounts.guardrails.test.ts, which asserted every RPC default
 * appeared in BAS_2024_ACCOUNTS — a test that encoded "the platform is
 * Swedish" and would have blocked exactly this work.
 */

const root = process.cwd();
const migrations = join(root, 'supabase/migrations');
const BASELINE = '00000000000000_baseline.sql';

/** The latest definition of each function, in migration order. */
function latestDefinitions(): Map<string, string> {
  const out = new Map<string, string>();
  for (const f of readdirSync(migrations).filter((x) => x.endsWith('.sql') && x !== BASELINE).sort()) {
    const sql = readFileSync(join(migrations, f), 'utf8');
    for (const m of sql.matchAll(
      /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?"?([A-Za-z_][A-Za-z0-9_]*)"?\s*\(/gi,
    )) {
      // Capture from the name to the end of the argument list.
      let i = m.index! + m[0].length - 1;
      let depth = 0;
      let end = i;
      for (; i < sql.length; i++) {
        if (sql[i] === '(') depth++;
        else if (sql[i] === ')') {
          depth--;
          if (depth === 0) { end = i; break; }
        }
      }
      out.set(m[1], sql.slice(m.index!, end + 1));
    }
  }
  return out;
}

describe('account roles', () => {
  it('no function defaults a parameter to a literal account number', () => {
    const offenders: string[] = [];
    for (const [name, def] of latestDefinitions()) {
      // Comments are stripped first: the role migration's header quotes the
      // old signatures on purpose, and that prose must not trip the check.
      const code = def.replace(/--[^\n]*/g, '');
      for (const m of code.matchAll(/(\w+)\s+text\s+DEFAULT\s+'(\d{4})'/gi)) {
        offenders.push(`${name}.${m[1]} → '${m[2]}'`);
      }
    }
    expect(
      offenders,
      'a country\'s account numbers belong in the locale pack, not in a function ' +
        `signature — use DEFAULT NULL + account_for(role):\n${offenders.join('\n')}`,
    ).toEqual([]);
  });

  it('the resolver exists and fails loudly on an unmapped role', () => {
    const f = readdirSync(migrations).find((x) => x.includes('account-roles'));
    expect(f, 'the account-roles migration is gone').toBeTruthy();
    const sql = readFileSync(join(migrations, f!), 'utf8');

    expect(sql).toContain('CREATE TABLE IF NOT EXISTS public.account_roles');
    expect(sql).toMatch(/UNIQUE \(locale, role\)/);
    expect(sql).toMatch(/FUNCTION public\.account_for\(p_role text\)/);
    // Returning NULL would let a caller post to nowhere and look fine doing it.
    expect(sql).toMatch(/RAISE EXCEPTION[\s\S]{0,120}No account mapped to role/);
  });

  it('every role the RPCs resolve is mapped in the shipped pack', () => {
    const conv = readdirSync(migrations).find((x) => x.includes('rpcs-resolve-account-roles'));
    expect(conv, 'the RPC conversion migration is gone').toBeTruthy();
    const used = new Set(
      Array.from(
        readFileSync(join(migrations, conv!), 'utf8').matchAll(/account_for\('([a-z_]+)'\)/g),
      ).map((m) => m[1]),
    );
    expect(used.size, 'no roles resolved — the conversion was undone').toBeGreaterThan(10);

    const rolesFile = readdirSync(migrations).find((x) => x.includes('account-roles'))!;
    const seeded = new Set(
      Array.from(
        readFileSync(join(migrations, rolesFile), 'utf8').matchAll(/'se-bas2024',\s*'([a-z_]+)'/g),
      ).map((m) => m[1]),
    );

    const unmapped = [...used].filter((r) => !seeded.has(r));
    expect(
      unmapped,
      `these roles are resolved by an RPC but no pack defines them:\n${unmapped.join('\n')}`,
    ).toEqual([]);
  });

  it('an explicit account argument still wins over the role', () => {
    // The point is a sane DEFAULT, not removing the caller's control.
    const conv = readdirSync(migrations).find((x) => x.includes('rpcs-resolve-account-roles'))!;
    const sql = readFileSync(join(migrations, conv), 'utf8');
    const coalesces = sql.match(/(\w+) := COALESCE\(\1, public\.account_for\('[a-z_]+'\)\)/g) ?? [];
    expect(coalesces.length, 'resolution is not COALESCE-guarded').toBeGreaterThan(20);
  });
});
