/**
 * flowpilot-simulate.ts — fast-forward the autonomous operator locally.
 *
 * Normally the heartbeat fires twice a day. This harness drives many heartbeat
 * "ticks" back-to-back against the LOCAL stack and (optionally) advances a
 * simulated clock between them, so you can watch FlowPilot operate over "N days"
 * in a couple of minutes and see whether it actually follows its objectives.
 *
 * Each tick:
 *   1. releases the `heartbeat` concurrency lock (so the next tick isn't skipped)
 *   2. (sim-clock) backdates the agent's own activity log + heartbeat_state by
 *      `--day-step` hours, so the operator perceives a fresh day and re-evaluates
 *      its daily objectives (e.g. "write a blog every day")
 *   3. POSTs the local flowpilot-heartbeat function (one full reason() cycle)
 *   4. reports what the operator DID this tick (skills executed, content created,
 *      objectives advanced, idle/active, tokens)
 *
 * Prereqs (see docs/operators/local-development.md):
 *   - `supabase start` is up (DB on 54322, functions on 54321)
 *   - `supabase functions serve --no-verify-jwt --env-file supabase/functions/.env`
 *     is running with an AI provider key in that .env (ANTHROPIC_API_KEY /
 *     OPENAI_API_KEY / GEMINI_API_KEY) — otherwise reason() has no LLM to call.
 *
 * Usage:
 *   bun run scripts/flowpilot-simulate.ts --ticks=5
 *   bun run scripts/flowpilot-simulate.ts --ticks=10 --day-step=24
 *   bun run scripts/flowpilot-simulate.ts --ticks=3 --no-clock   # same-day, repeated
 *
 * Local data is throwaway — backdating + write-skills are safe here, never on prod.
 */
import { Client } from 'pg';

// ── Config ────────────────────────────────────────────────────────────────
const DB =
  process.env.DATABASE_URL ||
  'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const HEARTBEAT_URL =
  process.env.HEARTBEAT_URL ||
  'http://127.0.0.1:54321/functions/v1/flowpilot-heartbeat';
// serve runs --no-verify-jwt locally, so any bearer is accepted.
const BEARER = process.env.LOCAL_BEARER || 'local-sim';

function arg(name: string, def: string): string {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.split('=')[1] : def;
}
const TICKS = parseInt(arg('ticks', '5'), 10);
const DAY_STEP_HOURS = parseInt(arg('day-step', '24'), 10);
const SIM_CLOCK = !process.argv.includes('--no-clock');
const PER_TICK_TIMEOUT_MS = parseInt(arg('timeout', '180000'), 10);

const c = new Client({ connectionString: DB });

// ── Helpers ───────────────────────────────────────────────────────────────
const hr = (s = '━') => s.repeat(72);
async function q<T = any>(sql: string, params: any[] = []): Promise<T[]> {
  try {
    return (await c.query(sql, params)).rows as T[];
  } catch {
    return [];
  }
}

async function preflight() {
  console.log(hr());
  console.log('FlowPilot fast-forward simulation');
  console.log(`  ticks=${TICKS}  sim-clock=${SIM_CLOCK ? `on (+${DAY_STEP_HOURS}h/tick)` : 'off'}  db=${DB.split('@')[1]}`);
  console.log(hr());

  // 1. flowpilot module must be enabled, else heartbeat early-exits on the gate.
  const mod = await q("SELECT value FROM site_settings WHERE key='modules'");
  const modules = (mod[0]?.value as any) || {};
  const fp = modules.flowpilot;
  const enabled = fp && typeof fp === 'object' ? fp.enabled : fp;
  if (!enabled) {
    const next = { ...modules, flowpilot: { ...(typeof fp === 'object' ? fp : {}), enabled: true } };
    await q("UPDATE site_settings SET value=$1 WHERE key='modules'", [next]);
    console.log('  flowpilot module: was OFF → enabled for the sim');
  } else {
    console.log('  flowpilot module: enabled ✓');
  }

  // 2. Objectives — what is the operator supposed to be doing?
  const objs = await q(
    "SELECT goal AS title, status FROM agent_objectives ORDER BY created_at",
  );
  if (!objs.length) {
    console.log('  ⚠ no agent_objectives — operator has nothing to pursue. Seed objectives first (setup-flowpilot / admin UI).');
  } else {
    console.log(`  objectives (${objs.length}):`);
    for (const o of objs) console.log(`    • [${o.status}]  ${o.title}`);
  }

  // 3. AI provider — reason() can't run without one.
  const ai = await q("SELECT value FROM site_settings WHERE key='system_ai'");
  const cfg = ai[0]?.value as any;
  if (cfg?.provider) console.log(`  ai provider: ${cfg.provider}${cfg.model ? ` (${cfg.model})` : ''} ✓`);
  else console.log('  ⚠ no system_ai in site_settings — relying on env-var fallback (ANTHROPIC/OPENAI/GEMINI_API_KEY). If a tick errors on the LLM call, that key is missing from functions-serve env.');

  console.log(hr());
}

interface TickResult {
  n: number;
  ok: boolean;
  directive: string | null;
  skipped?: string;
  skills: { name: string; status: string }[];
  created: string[];
  tokens: number;
  ms: number;
  error?: string;
}

async function tick(n: number): Promise<TickResult> {
  // 1. release the heartbeat lock so we aren't told "concurrent_heartbeat"
  await q("DELETE FROM agent_locks WHERE lane='heartbeat'");

  // 2. advance the simulated clock: backdate the agent's memory of its own
  //    actions so "yesterday's" work looks a day old and daily objectives re-fire.
  if (SIM_CLOCK) {
    await q(`UPDATE agent_activity SET created_at = created_at - ($1 || ' hours')::interval`, [DAY_STEP_HOURS]);
    await q(`UPDATE heartbeat_state SET last_run = last_run - ($1 || ' hours')::interval WHERE last_run IS NOT NULL`, [DAY_STEP_HOURS]);
    // content the operator may check for "did I already post today?"
    await q(`UPDATE blog_posts SET created_at = created_at - ($1 || ' hours')::interval`, [DAY_STEP_HOURS]);
  }

  const marker = new Date().toISOString();
  const t0 = Date.now();

  // 3. one full heartbeat reasoning cycle
  let body: any = {};
  let error: string | undefined;
  try {
    const ctrl = new AbortController();
    const to = setTimeout(() => ctrl.abort(), PER_TICK_TIMEOUT_MS);
    const res = await fetch(HEARTBEAT_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${BEARER}` },
      body: JSON.stringify({ time: marker, source: 'fast-sim' }),
      signal: ctrl.signal,
    });
    clearTimeout(to);
    body = await res.json().catch(() => ({}));
    if (!res.ok) error = `HTTP ${res.status}: ${JSON.stringify(body).slice(0, 160)}`;
  } catch (e: any) {
    error = e?.name === 'AbortError' ? `timeout after ${PER_TICK_TIMEOUT_MS}ms` : String(e?.message || e);
  }
  const ms = Date.now() - t0;

  if (body?.skipped) {
    return { n, ok: true, directive: null, skipped: body.reason, skills: [], created: [], tokens: 0, ms };
  }

  // 4. what did it actually do? — skill rows logged during this cycle
  const rows = await q(
    `SELECT skill_name, status, output FROM agent_activity
       WHERE created_at >= $1 AND skill_name <> 'heartbeat'
       ORDER BY created_at`,
    [marker],
  );
  const skills = rows.map((r) => ({ name: r.skill_name, status: r.status }));

  // content artifacts created this tick (across the common operator outputs)
  const created: string[] = [];
  for (const [table, label, col] of [
    ['blog_posts', 'blog', 'title'],
    ['kb_articles', 'kb', 'title'],
    ['pages', 'page', 'title'],
    ['agent_memories', 'memory', 'content'],
  ] as const) {
    const made = await q(`SELECT ${col} v FROM ${table} WHERE created_at >= $1 ORDER BY created_at`, [marker]);
    for (const m of made) created.push(`${label}: ${String(m.v || '').slice(0, 60)}`);
  }

  return {
    n,
    ok: !error,
    directive: body?.directive ?? null,
    skills,
    created,
    tokens: body?.tokenUsage?.total_tokens || body?.token_usage?.total_tokens || 0,
    ms,
    error,
  };
}

function printTick(r: TickResult) {
  const tag = `day ${String(r.n).padStart(2, ' ')}`;
  if (r.skipped) {
    console.log(`${tag}  ⏭  skipped (${r.skipped})  ${r.ms}ms`);
    return;
  }
  if (r.error) {
    console.log(`${tag}  ❌ ${r.error}  ${r.ms}ms`);
    return;
  }
  const mood = r.directive === 'NO_REPLY' ? '😴 idle' : '⚡ active';
  console.log(`${tag}  ${mood}  ${r.skills.length} skill(s)  ${r.tokens} tok  ${(r.ms / 1000).toFixed(1)}s`);
  for (const s of r.skills) console.log(`        ↳ ${s.status === 'success' ? '✓' : '✗'} ${s.name}`);
  for (const made of r.created) console.log(`        + ${made}`);
}

async function main() {
  await c.connect();
  await preflight();

  const results: TickResult[] = [];
  for (let n = 1; n <= TICKS; n++) {
    const r = await tick(n);
    results.push(r);
    printTick(r);
  }

  // ── Final report ──────────────────────────────────────────────────────────
  console.log(hr());
  const active = results.filter((r) => !r.skipped && !r.error && r.directive !== 'NO_REPLY').length;
  const idle = results.filter((r) => r.directive === 'NO_REPLY').length;
  const skipped = results.filter((r) => r.skipped).length;
  const errored = results.filter((r) => r.error).length;
  const totalSkills = results.reduce((a, r) => a + r.skills.length, 0);
  const totalCreated = results.reduce((a, r) => a + r.created.length, 0);
  const totalTokens = results.reduce((a, r) => a + r.tokens, 0);
  console.log(`Summary over ${TICKS} simulated day(s):`);
  console.log(`  active=${active}  idle=${idle}  skipped=${skipped}  errored=${errored}`);
  console.log(`  skills executed=${totalSkills}  artifacts created=${totalCreated}  tokens=${totalTokens}`);

  const objs = await q("SELECT goal AS title, status FROM agent_objectives ORDER BY created_at");
  if (objs.length) {
    console.log('  objective state after sim:');
    for (const o of objs) console.log(`    • [${o.status}]  ${o.title}`);
  }
  console.log(hr());
  if (errored) console.log('Errors present — most likely the AI provider key is missing from functions-serve env (see preflight notes).');
  else if (active === 0) console.log('Operator never acted — check objectives are active + unlocked, and the heartbeat protocol/soul. This is the "not following objectives" symptom to dig into.');
  else console.log('Operator acted autonomously across the simulated days. ✅');

  await c.end();
}

main().catch(async (e) => {
  console.error('simulate failed:', e?.message || e);
  try { await c.end(); } catch { /* noop */ }
  process.exit(1);
});
