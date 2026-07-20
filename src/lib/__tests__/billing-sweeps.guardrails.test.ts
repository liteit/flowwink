import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Guardrail: the billing sweeps must stay loop-safe and idempotent.
 *
 * Context (edge-surface B3): subscription-billing-cron and
 * contract-billing-cron looped in TypeScript — find due rows, call a per-row
 * RPC. An agent_automations row calls ONE skill with STATIC arguments and
 * cannot iterate, so the loops moved into run_subscription_billing() and
 * run_contract_billing() to become schedulable automations. Neither edge
 * function was ever cron-scheduled on any instance, so these sweeps are the
 * first scheduler the logic has had.
 *
 * Two properties carry real money and must not regress:
 *
 * 1. PER-ROW exception handling. The per-row RPCs RAISE on guard violations.
 *    Without an inner BEGIN/EXCEPTION block one bad row aborts the whole
 *    sweep, and every later customer silently goes unbilled — the worst
 *    failure mode available here, because nothing looks broken.
 *
 * 2. A row cap. An unbounded sweep on a large tenant is a runaway.
 */

const root = process.cwd();
const migrations = join(root, 'supabase/migrations');

function sweepSource(fn: string): string {
  const file = readdirSync(migrations)
    .filter((f) => f.endsWith('.sql'))
    .find((f) => readFileSync(join(migrations, f), 'utf8').includes(`FUNCTION public.${fn}()`));
  expect(file, `no migration defines public.${fn}()`).toBeTruthy();
  return readFileSync(join(migrations, file!), 'utf8');
}

const SWEEPS = ['run_subscription_billing', 'run_contract_billing'];

describe('billing sweeps', () => {
  for (const fn of SWEEPS) {
    describe(fn, () => {
      const src = sweepSource(fn);

      it('handles failures PER ROW so one bad row cannot stop the sweep', () => {
        // The loop body must contain its own BEGIN … EXCEPTION … END.
        const loop = src.slice(src.indexOf('LOOP'), src.lastIndexOf('END LOOP'));
        expect(loop).toMatch(/BEGIN/);
        expect(loop).toMatch(/EXCEPTION WHEN OTHERS THEN/);
        // and it must record the failure rather than swallow it
        expect(loop).toMatch(/SQLERRM/);
        expect(loop).toMatch(/'ok', false/);
      });

      it('caps how many rows one run may touch', () => {
        expect(src).toMatch(/LIMIT \d+/);
      });

      it('is agent-callable: service_role escape alongside the admin check', () => {
        // The MCP gateway runs RPC skills with the service key, so auth.uid()
        // is NULL there — without the escape the agent gets "Only admins…".
        expect(src).toMatch(/auth\.role\(\) = 'service_role'/);
        expect(src).toMatch(/has_role\(auth\.uid\(\), 'admin'::app_role\)/);
      });

      it('reports counts the operator can act on', () => {
        for (const k of ['candidates', 'succeeded', 'failed', 'results']) {
          expect(src, `${fn} does not report ${k}`).toContain(`'${k}'`);
        }
      });
    });
  }

  it('both sweeps are seeded as skills AND wired to a cron automation', () => {
    const subs = readFileSync(join(root, 'src/lib/modules/subscriptions-module.ts'), 'utf8');
    const contracts = readFileSync(join(root, 'src/lib/modules/contracts-module.ts'), 'utf8');

    expect(subs).toContain("handler: 'rpc:run_subscription_billing'");
    expect(subs).toMatch(/skill_name: 'run_subscription_billing'/);
    expect(contracts).toContain("handler: 'rpc:run_contract_billing'");
    expect(contracts).toMatch(/skill_name: 'run_contract_billing'/);

    // Both automations must be cron-triggered — an event trigger would never
    // fire for "time has passed".
    for (const [src, name] of [[subs, 'subscription'], [contracts, 'contract']] as const) {
      const block = src.slice(src.indexOf('_AUTOMATIONS'));
      expect(block, `${name} automation is not cron-triggered`).toMatch(/trigger_type: 'cron'/);
    }
  });

  it('the contract sweep does NOT try to send email from SQL', () => {
    // Reminder emails render HTML templates; that belongs in the comms layer.
    // The sweep says so explicitly so nobody "completes" it by adding mail.
    // Strip comments first: the header deliberately NAMES comms-send as the
    // future home of the reminder half, and that prose must not trip the check.
    const code = sweepSource('run_contract_billing')
      .split('\n')
      .filter((l) => !l.trimStart().startsWith('--'))
      .join('\n');
    expect(code).not.toMatch(/net\.http_post|functions\/v1|email-send|comms-send/);
    // …while the file as a whole still explains where reminders live.
    expect(sweepSource('run_contract_billing').toLowerCase()).toMatch(/reminder/);
  });
});
