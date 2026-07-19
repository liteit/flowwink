import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Edge-surface refactor B1a, wave 1 — six CRM/sales/FX skills edge→internal.
 * Pins response contracts + the auth-semantics delta in sales_profile_setup.
 */
import { executeFetchFxRates, parseEcbXml } from '../../../supabase/functions/_shared/handlers/fetch-fx-rates.ts';
import { executeQualifyLead } from '../../../supabase/functions/_shared/handlers/qualify-lead.ts';
import { executeEnrichCompany } from '../../../supabase/functions/_shared/handlers/enrich-company.ts';
import { executeProspectFitAnalysis } from '../../../supabase/functions/_shared/handlers/prospect-fit-analysis.ts';
import { executeSalesProfileSetup } from '../../../supabase/functions/_shared/handlers/sales-profile-setup.ts';
import { executeProspectResearch } from '../../../supabase/functions/_shared/handlers/prospect-research.ts';

const ctx = { supabaseUrl: 'http://local', serviceKey: 'sk', callerUserId: null as string | null };

beforeEach(() => {
  (globalThis as any).Deno = { env: { get: () => undefined } };
});
afterEach(() => {
  delete (globalThis as any).Deno;
  vi.unstubAllGlobals();
});

/** Chainable supabase stub resolving every query to `result`. */
function stubDb(result: { data?: any; error?: any } = { data: null }) {
  const q: any = {};
  for (const m of ['select', 'insert', 'update', 'upsert', 'eq', 'ilike', 'order', 'limit']) q[m] = vi.fn(() => q);
  q.then = (res: any, rej: any) => Promise.resolve(result).then(res, rej);
  q.single = vi.fn(() => Promise.resolve(result));
  q.maybeSingle = vi.fn(() => Promise.resolve(result));
  return { from: vi.fn(() => q), _q: q } as any;
}

describe('fetch_ecb_rates internal handler', () => {
  it('parses ECB XML with both quote styles', () => {
    const xml = `<Cube time='2026-07-17'><Cube currency='USD' rate='1.09'/><Cube currency="SEK" rate="11.2"/></Cube>`;
    const { date, rates } = parseEcbXml(xml);
    expect(date).toBe('2026-07-17');
    expect(rates).toEqual([{ currency: 'USD', rate: 1.09 }, { currency: 'SEK', rate: 11.2 }]);
  });

  it('ECB HTTP error → { success: false, error: "ECB <status>" } (edge parity)', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 503 })));
    const res = await executeFetchFxRates(stubDb());
    expect(res).toEqual({ success: false, error: 'ECB 503' });
  });

  it('happy path → upserts EUR + cross rates from SEK base, same summary shape', async () => {
    const xml = `<Cube time='2026-07-17'><Cube currency='USD' rate='1.0'/><Cube currency='SEK' rate='10.0'/></Cube>`;
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, text: async () => xml })));
    const db = stubDb({ data: [{ code: 'USD' }, { code: 'SEK' }, { code: 'EUR' }], error: null });
    // base-currency query uses maybeSingle → SEK
    db._q.maybeSingle = vi.fn(() => Promise.resolve({ data: { code: 'SEK' } }));
    const res = await executeFetchFxRates(db);
    expect(res).toMatchObject({ success: true, rate_date: '2026-07-17', base_currency: 'SEK', source: 'ecb' });
    // EUR→USD, EUR→SEK, SEK→EUR, SEK→USD
    expect(res.rows_upserted).toBe(4);
  });
});

describe('qualify_lead internal handler', () => {
  it('missing id → exact alias-documenting error', async () => {
    const res = await executeQualifyLead(stubDb(), {}, ctx);
    expect(res).toEqual({ error: 'Lead ID is required (pass leadId or lead_id)' });
  });

  it('accepts snake_case lead_id (MCP-agent alias) and reports not-found', async () => {
    const db = stubDb({ data: null, error: { message: 'nope' } });
    const res = await executeQualifyLead(db, { lead_id: 'x' }, ctx);
    expect(res).toEqual({ error: 'Lead not found' });
  });
});

describe('enrich_company internal handler', () => {
  it('no domain and no companyId → validation error', async () => {
    const res = await executeEnrichCompany(stubDb(), {}, ctx);
    expect(res).toEqual({ error: 'Domain or companyId is required' });
  });

  it('already-enriched company → skip shape unchanged', async () => {
    const db = stubDb({ data: { id: 'c1', domain: 'a.se', enriched_at: '2026-01-01' }, error: null });
    const res = await executeEnrichCompany(db, { companyId: 'c1' }, ctx);
    expect(res).toEqual({ success: true, message: 'Already enriched', skipped: true });
  });
});

describe('prospect_fit_analysis internal handler', () => {
  it('no identifier → validation error', async () => {
    const res = await executeProspectFitAnalysis(stubDb(), {});
    expect(res).toEqual({ error: 'company_id or company_name is required' });
  });

  it('unknown company → Not-found note + empty completeness (edge parity)', async () => {
    const res = await executeProspectFitAnalysis(stubDb({ data: null }), { company_name: 'Ghost AB' });
    expect(res.success).toBe(true);
    expect(res.company).toEqual({ name: 'Ghost AB', note: 'Not found in CRM' });
    expect((res.data_completeness as any).lead_count).toBe(0);
  });
});

describe('sales_profile_setup internal handler — auth semantics', () => {
  it('type user WITHOUT resolved caller → same 401-message as the edge function gave agents', async () => {
    const res = await executeSalesProfileSetup(stubDb(), { type: 'user', data: { icp: 'x' } }, { ...ctx, callerUserId: null });
    expect(res).toEqual({ error: 'Authentication required for user profile' });
  });

  it('type user WITH resolved caller → saves under that user id', async () => {
    const db = stubDb({ data: { id: 'p1' }, error: null });
    const res = await executeSalesProfileSetup(db, { type: 'user', data: { icp: 'x' } }, { ...ctx, callerUserId: 'u1' });
    expect(res).toMatchObject({ success: true, message: 'user profile saved successfully' });
    expect(db._q.upsert).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'user', user_id: 'u1' }),
      { onConflict: 'type,user_id' },
    );
  });

  it('flat payload (no data wrapper) is accepted — MCP/FlowChat tolerance kept', async () => {
    const db = stubDb({ data: { id: 'p2' }, error: null });
    const res = await executeSalesProfileSetup(db, { type: 'company', icp: 'SMBs', value_proposition: 'v' }, ctx);
    expect(res).toMatchObject({ success: true });
    expect(db._q.upsert).toHaveBeenCalledWith(
      expect.objectContaining({ data: { icp: 'SMBs', value_proposition: 'v' } }),
      expect.anything(),
    );
  });

  it('bad type → exact validation message', async () => {
    const res = await executeSalesProfileSetup(stubDb(), { type: 'x' }, ctx);
    expect(res).toEqual({ error: 'type must be "company" or "user"' });
  });
});

describe('prospect_research internal handler', () => {
  it('company_name required', async () => {
    const res = await executeProspectResearch(stubDb(), {}, ctx);
    expect(res).toEqual({ error: 'company_name is required' });
  });

  it('degrades gracefully when search/scrape fail — contact-finder is a LIBRARY call, no HTTP hop', async () => {
    // web-search + web-scrape (HTTP) fail; the handler must still persist the
    // company and return the ResearchResult shape.
    const fetchSpy = vi.fn(async () => ({ ok: false, text: async () => 'down' }));
    vi.stubGlobal('fetch', fetchSpy);
    const db = stubDb({ data: { id: 'co1' }, error: null });
    const res = await executeProspectResearch(db, { company_name: 'ACME' }, ctx);
    expect(res).toMatchObject({ success: true, company: { id: 'co1', name: 'ACME' } });
    expect((res as any).data_sources).toEqual({ search: false, scrape: false, contacts: false });
    // Only the two HTTP utility calls — proves contact-finder wasn't fetched over HTTP
    const urls = fetchSpy.mock.calls.map((c: any[]) => String(c[0]));
    expect(urls.every((u: string) => u.includes('web-search') || u.includes('web-scrape'))).toBe(true);
  });
});
