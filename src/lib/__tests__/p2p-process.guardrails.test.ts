import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { purchasingModule } from '@/lib/modules/purchasing-module';

/**
 * Guardrails locking the procure-to-pay fixes found by running the chain through the
 * MCP gateway on 2026-07-09. Each `it` pins one defect so it can't silently regress.
 */
describe('P2P process guardrails', () => {
  const migDir = join(__dirname, '../../../supabase/migrations');
  // Exclude the baseline snapshot: it is a frozen historical dump of the schema at a
  // point in time (it still contains pre-fix function bodies), superseded at runtime by
  // the forward-dated fix migrations. These lints guard NEW migrations, not history.
  const sqlFiles = readdirSync(migDir)
    .filter((f) => f.endsWith('.sql') && !f.startsWith('00000000000000'));
  const allSql = sqlFiles.map((f) => readFileSync(join(migDir, f), 'utf8')).join('\n');

  it('no SQL format() uses printf specifiers — Postgres format() only knows %s %I %L %%', () => {
    // format('...%.2f...') / %d / %f throw "unrecognized format() type specifier" at
    // runtime — the bug that made match_po_to_invoice / match_invoice_to_receipt crash
    // on every call. Only %s, %I, %L and the %% literal are valid.
    const offenders: string[] = [];
    for (const f of sqlFiles) {
      const sql = readFileSync(join(migDir, f), 'utf8');
      // Find each format( ... ) argument list and scan its literal for a bad specifier.
      const re = /format\s*\(([\s\S]*?)\)/gi;
      let m: RegExpExecArray | null;
      while ((m = re.exec(sql))) {
        // Bad: % optionally followed by width/precision then a non-(s|I|L|%) letter.
        if (/%[-0-9.]*[a-zA-Z]/.test(m[1].replace(/%%/g, '').replace(/%[sIL]/g, ''))) {
          offenders.push(`${f}: format(${m[1].slice(0, 60)}…)`);
        }
      }
    }
    expect(offenders, `printf-style format() specifiers found:\n${offenders.join('\n')}`).toEqual([]);
  });

  it('agent-callable auth-gated RPCs escape service_role (auth.uid() is NULL under the gateway)', () => {
    // "IF auth.uid() IS NULL THEN RAISE 'Not authenticated'" locks out the MCP agent.
    // Every such gate in a migration must add "AND auth.role() <> 'service_role'".
    const bareGate = /auth\.uid\(\)\s+IS\s+NULL\s+THEN\s+RAISE\s+EXCEPTION\s+'Not authenticated'/gi;
    const matches = allSql.match(bareGate) ?? [];
    expect(matches, 'found auth.uid() IS NULL gate without a service_role escape').toEqual([]);
  });

  it('send_purchase_order is a dedicated RPC, not generic table CRUD', () => {
    // "send" is a status transition the generic db: verb-inference can't infer, so it
    // silently listed instead of transitioning. Must stay on the dedicated RPC.
    const seeds = (purchasingModule as any).skillSeeds ?? (purchasingModule as any).skills ?? [];
    const send = seeds.find((s: any) => s.name === 'send_purchase_order');
    expect(send, 'send_purchase_order seed missing').toBeTruthy();
    expect(send.handler).toBe('rpc:send_purchase_order');
  });

  it('vendor_invoices match_status constraint admits the richer 3-way-match statuses', () => {
    // match_invoice_to_receipt writes over_invoiced/under_invoiced/no_receipt/no_po —
    // the constraint must allow them or the write violates the check.
    for (const v of ['over_invoiced', 'under_invoiced', 'no_receipt', 'no_po']) {
      expect(allSql, `constraint must allow '${v}'`).toContain(`'${v}'`);
    }
  });
});
