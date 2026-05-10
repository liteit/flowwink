// @ts-nocheck
(globalThis as any).localStorage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };
(globalThis as any).window = { addEventListener: () => {}, removeEventListener: () => {}, localStorage: (globalThis as any).localStorage };
const { getAllUnifiedModules, getUnifiedSkillNames } = await import('../src/lib/module-def');
await import('../src/lib/modules');

const all: Record<string, string[]> = {};
for (const m of getAllUnifiedModules()) {
  const s = getUnifiedSkillNames(m.id);
  if (s.length) all[m.id] = s;
}
console.log(JSON.stringify(all));
