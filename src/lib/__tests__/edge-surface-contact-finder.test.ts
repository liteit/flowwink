import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Edge-surface refactor B1a, wave 0 — contact_finder edge→internal.
 *
 * The handler moved from the standalone `contact-finder` edge function into
 * `_shared/handlers/contact-finder.ts` (imported by agent-execute as
 * `internal:contact_finder`). These tests pin the RESPONSE CONTRACT: the
 * objects returned must be exactly what the edge function used to return,
 * since agent-execute's edge: dispatch always parsed the JSON body regardless
 * of HTTP status — callers see the same shapes, or the move is not zero-API.
 */
import { executeContactFinder } from '../../../supabase/functions/_shared/handlers/contact-finder.ts';

const denoEnv: Record<string, string | undefined> = {};

beforeEach(() => {
  (globalThis as any).Deno = { env: { get: (k: string) => denoEnv[k] } };
});

afterEach(() => {
  delete (globalThis as any).Deno;
  delete denoEnv.HUNTER_API_KEY;
  vi.unstubAllGlobals();
});

describe('contact_finder internal handler — response contract', () => {
  it('missing domain → same validation error as the edge function', async () => {
    const res = await executeContactFinder({});
    expect(res).toEqual({ success: false, error: 'domain is required' });
  });

  it('missing HUNTER_API_KEY → soft fail with empty contacts (orchestrator continues)', async () => {
    const res = await executeContactFinder({ domain: 'acme.com' });
    expect(res.success).toBe(false);
    expect(res.contacts).toEqual([]);
    expect(String(res.error)).toMatch(/HUNTER_API_KEY/);
  });

  it('email_finder without names → validation error', async () => {
    denoEnv.HUNTER_API_KEY = 'k';
    const res = await executeContactFinder({ action: 'email_finder', domain: 'acme.com' });
    expect(res).toEqual({ success: false, error: 'first_name and last_name required for email_finder' });
  });

  it('domain_search happy path → contacts normalized to the Hunter shape, www. stripped', async () => {
    denoEnv.HUNTER_API_KEY = 'k';
    vi.stubGlobal('fetch', vi.fn(async (url: string) => {
      expect(url).toContain('domain=acme.com'); // www. stripped before the API call
      return {
        ok: true,
        json: async () => ({
          data: {
            total: 1,
            emails: [{ first_name: 'Ada', last_name: null, value: 'ada@acme.com', position: 'CTO', confidence: 97 }],
          },
        }),
      };
    }));

    const res = await executeContactFinder({ domain: 'www.acme.com', limit: 5 });
    expect(res).toEqual({
      success: true,
      action: 'domain_search',
      domain: 'acme.com',
      total_results: 1,
      contacts: [{
        first_name: 'Ada',
        last_name: null,
        email: 'ada@acme.com',
        phone_number: null,
        position: 'CTO',
        department: null,
        confidence: 97,
      }],
    });
  });

  it('Hunter API error → soft error object, never a throw (edge parity)', async () => {
    denoEnv.HUNTER_API_KEY = 'k';
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 429, json: async () => ({}) })));
    const res = await executeContactFinder({ domain: 'acme.com' });
    expect(res).toEqual({ success: false, error: 'Hunter API error: 429', contacts: [] });
  });
});
