import { describe, expect, it } from 'vitest';
import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Guardrail: no pre-rebrand product name may reach a user-visible surface.
 *
 * Live finding (2026-07-20): the v3.0.0 GitHub release published as
 * "Pezcms v3.0.0" — the pre-rebrand name was hardcoded in
 * .github/workflows/release.yml. It survived the rebrand because v1.x and
 * v2.0.0 were released by hand; v3.0.0 was the first release the WORKFLOW
 * built, so the stale string had never once been exercised. Two more copies
 * were hiding in .env.example and supabase/schema.sql — and the schema one
 * seeds `seo.siteTitle`, so a template-less install would have shown the old
 * brand as its site title.
 *
 * That is the shape of the bug: a name nothing points at, on a path that runs
 * rarely. A grep is the only thing that finds it, so run the grep in CI.
 */

const root = process.cwd();

/** Names this product has shipped under before. Add to this list, never remove. */
const LEGACY_NAMES = ['pezcms'];

describe('legacy brand names', () => {
  it('appear nowhere in tracked files', () => {
    // Search tracked files only — node_modules/dist/git history are not ours to
    // police, and history must keep saying what it said at the time.
    const hits = LEGACY_NAMES.flatMap((name) => {
      let out = '';
      try {
        out = execSync(`git grep -In -i -- ${name}`, { cwd: root, encoding: 'utf8' });
      } catch {
        return []; // git grep exits 1 when there are no matches
      }
      return out
        .split('\n')
        .filter(Boolean)
        // This guardrail necessarily names the thing it forbids.
        .filter((line) => !line.startsWith('src/lib/__tests__/brand.guardrails.test.ts'));
    });

    expect(hits, `pre-rebrand name found:\n${hits.join('\n')}`).toEqual([]);
  });

  it('the release workflow derives the product name instead of spelling it out', () => {
    const wf = readFileSync(join(root, '.github/workflows/release.yml'), 'utf8');
    const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));

    // package.json is the single source of truth for the display name…
    expect(pkg.displayName, 'package.json lost its displayName').toBeTruthy();
    // …and the release title must READ it, so the next rebrand is one edit.
    expect(wf).toMatch(/require\('\.\/package\.json'\)\.displayName/);
    expect(wf).toMatch(/name: \$\{\{ steps\.product\.outputs\.NAME \}\} v/);
  });

  it('the schema seeds the current brand as the default site title', () => {
    // seo.siteTitle is user-visible on any install that does not apply a
    // template, which is exactly the install nobody tests.
    const schema = readFileSync(join(root, 'supabase/schema.sql'), 'utf8');
    const seo = schema.slice(schema.indexOf("'seo'"), schema.indexOf("'seo'") + 600);
    const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
    expect(seo).toContain(`"siteTitle": "${pkg.displayName}"`);
  });
});
