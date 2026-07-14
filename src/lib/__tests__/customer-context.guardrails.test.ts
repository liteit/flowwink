/**
 * Guardrail: identity-aware chat injects a customer's account data only from a
 * VERIFIED JWT, never from a client-supplied field (conversation-and-retrieval.md
 * Phase 2, rung 2). The whole ladder is data-driven, not claim-driven: a forged
 * `customerEmail` in the body is rung-1 visitor memory at most and must not
 * unlock another person's orders/invoices.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const root = join(__dirname, '../../..');
const read = (p: string) => readFileSync(join(root, p), 'utf-8');

describe('customer-context identity guardrails', () => {
  const helper = read('supabase/functions/_shared/customer-context.ts');
  const chat = read('supabase/functions/chat-completion/index.ts');

  it('resolver rejects the anon key and unverified tokens', () => {
    const fn = helper.slice(helper.indexOf('export async function resolveAuthenticatedCustomer'));
    const body = fn.slice(0, fn.indexOf('\n}\n'));
    // anon key is explicitly NOT a user
    expect(body).toMatch(/token === anonKey\)\s*return null/);
    // identity comes from verified claims, not the request body
    expect(body).toContain('auth.getClaims');
    expect(body).toMatch(/claims\.email/);
  });

  it('chat-completion derives customer context from the resolved JWT, not customerEmail', () => {
    // The injected context must be built from the resolved authed customer…
    expect(chat).toMatch(/buildCustomerContext\(\s*supabase,\s*authedCustomer\.email/);
    // …resolved from the Authorization header, not the body field.
    expect(chat).toMatch(/resolveAuthenticatedCustomer\(\s*req\.headers\.get\('Authorization'\)/);
    // buildCustomerContext must never be called with the forgeable body email.
    expect(chat).not.toMatch(/buildCustomerContext\([^)]*customerEmail/);
  });

  it('the account-data block is only appended when a customer was authenticated', () => {
    // customerContext is empty ('') unless authedCustomer resolved.
    expect(chat).toMatch(/authedCustomer\s*\?\s*await buildCustomerContext/);
    expect(chat).toMatch(/if \(customerContext\) chatPrompt \+= customerContext/);
  });
});
