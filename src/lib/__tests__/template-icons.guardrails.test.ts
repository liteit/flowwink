import { describe, expect, it } from 'vitest';
import { icons } from 'lucide-react';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Guardrail: every icon name a template ships must resolve.
 *
 * Blocks look icons up dynamically — `icons[item.icon]` against lucide's
 * registry. A name that is not a key resolves to undefined and the block
 * renders the card with no icon: no error, no console warning, no fallback
 * glyph. Just a hole where an icon should be.
 *
 * Found 2026-07-21 on the www home page, where six of the 66 module cards had
 * no icon. The names were not typos — they were lucide ALIASES. lucide keeps
 * `FileSignature`, `KanbanSquare`, `CheckCircle`, `BarChart3` and friends as
 * top-level named exports for backwards compatibility, but the `icons`
 * registry only carries canonical names (`FilePen`, `SquareKanban`,
 * `CircleCheck`, `ChartColumn`). So the names look right, import fine in any
 * editor, and silently render nothing at runtime. Ten of them were spread
 * across eight templates.
 */

const root = process.cwd();
const templateDir = join(root, 'src/data/templates');

describe('template icon names', () => {
  it('every PascalCase icon name resolves in the lucide registry', () => {
    const bad: string[] = [];
    for (const file of readdirSync(templateDir).filter((f) => f.endsWith('.ts'))) {
      const src = readFileSync(join(templateDir, file), 'utf8');
      for (const m of src.matchAll(/icon: '([A-Z][A-Za-z0-9]*)'/g)) {
        if (!(m[1] in icons)) bad.push(`${file}: ${m[1]}`);
      }
    }
    expect(
      bad,
      'these names are not keys in lucide\'s registry — most likely a deprecated ' +
        `alias, which renders nothing at all:\n${bad.join('\n')}`,
    ).toEqual([]);
  });

  it('the registry is the thing we check against, not the named exports', () => {
    // The whole trap: an alias exists as an export but not as a registry key.
    // If this ever stops being true, the test above is worthless and should be
    // rewritten against whatever the blocks actually use.
    const lucide = require('lucide-react');
    expect(lucide.FileSignature, 'lucide dropped the alias export').toBeDefined();
    expect('FileSignature' in icons, 'the alias is now a registry key too').toBe(false);
  });

  it('blocks with their own icon map only receive names that map exists for', () => {
    // BadgeBlock and SocialProofBlock keep small curated maps keyed by
    // lowercase names, so a lucide-valid name is not automatically safe there.
    // www asked SocialProofBlock for globe/zap/package, none of which it had.
    const social = readFileSync(
      join(root, 'src/components/public/blocks/SocialProofBlock.tsx'),
      'utf8',
    );
    const declared = social.match(/icon\?: ([^;]+);/)?.[1] ?? '';
    const mapBody = social.slice(social.indexOf('const ICONS'), social.indexOf('};', social.indexOf('const ICONS')));
    const mapKeys = Array.from(mapBody.matchAll(/^\s{2}([a-z]+):/gm)).map((m) => m[1]);

    for (const key of declared.matchAll(/'([a-z]+)'/g)) {
      expect(mapKeys, `SocialProofBlock declares '${key[1]}' but ICONS has no entry`).toContain(
        key[1],
      );
    }
    // and the three that were missing are now present
    for (const k of ['globe', 'zap', 'package']) expect(mapKeys).toContain(k);
  });
});
