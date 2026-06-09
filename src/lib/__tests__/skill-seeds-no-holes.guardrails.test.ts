/**
 * Guardrail: a module's `skillSeeds` array must contain no holes or nameless
 * entries.
 *
 * A stray double-comma (`},,`) in a skill array leaves a sparse "hole". `.map`
 * and `.forEach` SKIP holes (so they look fine), but module bootstrap iterates
 * with `for...of`, which yields `undefined` for the hole → it records
 * "Skipped invalid skill seed (missing name)" → the module enable shows a RED
 * toast even though every real skill seeded fine.
 *
 * That exact bug lived in the ecommerce module (products-module.ts) and made
 * enabling FlowPilot (which re-bootstraps every enabled module) toast red.
 * Fixed 2026-06-10. This guardrail iterates by index — like bootstrap — so it
 * catches holes that `.map`/`.forEach` would silently skip.
 */
import { describe, expect, it } from 'vitest';
import '@/lib/modules';
import { getAllUnifiedModules } from '@/lib/module-def';

describe('module skillSeeds have no holes or nameless entries', () => {
  const modules = getAllUnifiedModules();

  it('the module registry is populated', () => {
    expect(modules.length).toBeGreaterThan(10);
  });

  it('every skillSeed is a named object (no `},,` array holes)', () => {
    const offenders: string[] = [];
    for (const m of modules) {
      const seeds = (m.skillSeeds ?? []) as Array<{ name?: string } | null | undefined>;
      // Index access (NOT forEach/map, which skip sparse holes) — mirrors the
      // `for...of` bootstrap loop that actually trips over the hole.
      for (let i = 0; i < seeds.length; i++) {
        const s = seeds[i];
        if (!s || typeof s !== 'object' || !s.name) {
          offenders.push(`${m.id}[${i}]`);
        }
      }
    }
    expect(
      offenders,
      `Hole / nameless skillSeed entries — almost always a stray double-comma ` +
        `("},,") that leaves an undefined slot. Module bootstrap's for...of loop ` +
        `yields it as "invalid skill seed (missing name)" and the enable toast ` +
        `turns red:\n  ${offenders.join('\n  ')}`,
    ).toEqual([]);
  });
});
