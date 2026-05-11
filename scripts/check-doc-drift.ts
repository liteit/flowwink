/**
 * Doc-drift guardrail
 *
 * Verifies that every registered module has a corresponding docs/modules/<id>.md
 * file. Run via `bun run scripts/check-doc-drift.ts`. CI uses --warn to keep
 * this advisory until the backlog is cleared, then we flip to hard-fail.
 *
 * Exit codes:
 *   0  — no drift (or --warn and only warnings)
 *   1  — hard drift detected and --warn not set
 */
// @ts-nocheck

import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

(globalThis as any).localStorage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };
(globalThis as any).window = { addEventListener: () => {}, removeEventListener: () => {}, localStorage: (globalThis as any).localStorage };

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');

const { getAllUnifiedModules } = await import(resolve(repoRoot, 'src/lib/module-def.ts'));
await import(resolve(repoRoot, 'src/lib/modules/index.ts'));

const warnOnly = process.argv.includes('--warn');

const docsDir = resolve(repoRoot, 'docs/modules');
const missing: string[] = [];
const present: string[] = [];

// Common alias map — some module ids don't 1:1 match doc filenames.
const docAliases: Record<string, string[]> = {
  customer360: ['customer360.md', 'customer-360.md'],
  bookings: ['bookings.md', 'booking.md'],
  workspaceChat: ['workspace-chat.md'],
  fieldService: ['field-service.md'],
  globalBlocks: ['global-blocks.md'],
  companyInsights: ['company-insights.md'],
  liveSupport: ['live-support.md'],
  fixedAssets: ['fixed-assets.md'],
  multiCurrency: ['multi-currency.md'],
  knowledgeBase: ['knowledge-base.md', 'kb.md'],
  kb: ['knowledge-base.md', 'kb.md'],
  salesIntelligence: ['sales-intelligence.md'],
  siteMigration: ['site-migration.md'],
  browserControl: ['browser-control.md'],
};

for (const mod of getAllUnifiedModules()) {
  const id = mod.id as string;
  const candidates = docAliases[id] ?? [`${id}.md`, `${id.replace(/([a-z])([A-Z])/g, '$1-$2').toLowerCase()}.md`];
  const found = candidates.some((c) => existsSync(resolve(docsDir, c)));
  if (found) present.push(id);
  else missing.push(`${id}  (looked for: ${candidates.join(', ')})`);
}

console.log(`✓ ${present.length} modules have docs`);

if (missing.length === 0) {
  console.log('✓ No doc drift detected');
  process.exit(0);
}

const tag = warnOnly ? '⚠ ' : '✗ ';
console.log(`${tag}${missing.length} module(s) missing docs/modules/<id>.md:`);
for (const m of missing) console.log(`   - ${m}`);

if (warnOnly) {
  console.log('\n(running with --warn — exiting 0)');
  process.exit(0);
}
process.exit(1);
