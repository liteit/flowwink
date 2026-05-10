// @ts-nocheck
(globalThis as any).localStorage = { getItem: () => null, setItem: () => {}, removeItem: () => {} };
(globalThis as any).window = { addEventListener: () => {}, removeEventListener: () => {}, localStorage: (globalThis as any).localStorage };
const { getAllUnifiedModules, getUnifiedSkillNames } = await import('../src/lib/module-def');
await import('../src/lib/modules');
const { createClient } = await import('@supabase/supabase-js');

const sb = createClient(process.env.VITE_SUPABASE_URL!, process.env.VITE_SUPABASE_PUBLISHABLE_KEY!);
const { data } = await sb.from('agent_skills').select('name').eq('enabled', true);
const live = new Set((data ?? []).map((r: any) => r.name));

let totalMissing = 0;
for (const m of getAllUnifiedModules()) {
  const skills = getUnifiedSkillNames(m.id);
  if (!skills.length) continue;
  const missing = skills.filter((s: string) => !live.has(s));
  if (missing.length) {
    console.log(`❌ ${m.id}: missing [${missing.join(', ')}]`);
    totalMissing += missing.length;
  }
}
console.log(`\nTotal missing: ${totalMissing}`);
