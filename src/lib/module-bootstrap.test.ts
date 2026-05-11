import { describe, it, expect, vi, beforeEach } from 'vitest';

// Mock supabase before importing the module under test
const insertMock = vi.fn((..._args: unknown[]) => Promise.resolve({ error: null })) as ReturnType<typeof vi.fn>;
const rpcMock = vi.fn();
const updateInMock = vi.fn(() => Promise.resolve({ error: null }));
const fromMock = vi.fn((table: string) => {
  if (table === 'bootstrap_runs') {
    return { insert: insertMock };
  }
  if (table === 'agent_skills') {
    return {
      update: () => ({ in: updateInMock, eq: () => Promise.resolve({ error: null }) }),
      select: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: null }) }) }),
      insert: () => Promise.resolve({ error: null }),
    };
  }
  if (table === 'agent_automations') {
    return {
      select: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: null }) }) }),
      insert: () => Promise.resolve({ error: null }),
      update: () => ({ in: () => Promise.resolve({ error: null }) }),
    };
  }
  return {};
});

vi.mock('@/integrations/supabase/client', () => ({
  supabase: {
    from: (t: string) => fromMock(t),
    rpc: (...args: unknown[]) => rpcMock(...args),
    functions: { invoke: () => Promise.resolve({}) },
  },
}));

vi.mock('@/lib/module-bootstraps/skill-map', () => ({
  getModuleSkillNames: () => [],
}));

vi.mock('@/lib/module-def', () => ({
  getUnifiedModule: () => undefined,
  getUnifiedSkillNames: () => [],
  isUnifiedModule: () => false,
}));

import { bootstrapModule, getBootstrapHealth } from './module-bootstrap';
import type { ModulesSettings } from '@/hooks/useModules';

const fakeModules = { flowpilot: { enabled: false } } as unknown as ModulesSettings;

describe('Bootstrap circuit breaker', () => {
  beforeEach(() => {
    insertMock.mockClear();
    rpcMock.mockReset();
  });

  it('records a successful run', async () => {
    rpcMock.mockResolvedValueOnce({ data: [{ is_degraded: false, failure_streak: 0, last_status: null, last_run_at: null, last_hash: null }], error: null });
    const result = await bootstrapModule('blog' as keyof ModulesSettings, fakeModules);
    expect(result.degraded).toBe(false);
    expect(insertMock).toHaveBeenCalledTimes(1);
    const inserted = insertMock.mock.calls[0][0];
    expect(inserted.module_id).toBe('blog');
    expect(inserted.status).toBe('success');
    expect(inserted.config_hash).toBeTruthy();
  });

  it('refuses to run when degraded (3+ consecutive failures)', async () => {
    rpcMock.mockResolvedValueOnce({ data: [{ is_degraded: true, failure_streak: 4, last_status: 'failed', last_run_at: '2026-01-01', last_hash: 'abc' }], error: null });
    const result = await bootstrapModule('blog' as keyof ModulesSettings, fakeModules);
    expect(result.degraded).toBe(true);
    expect(result.errors[0]).toMatch(/degraded/i);
    expect(insertMock).not.toHaveBeenCalled();
  });

  it('runs when degraded but force=true', async () => {
    rpcMock.mockResolvedValueOnce({ data: [{ is_degraded: true, failure_streak: 4, last_status: 'failed', last_run_at: '2026-01-01', last_hash: 'abc' }], error: null });
    const result = await bootstrapModule('blog' as keyof ModulesSettings, fakeModules, { force: true });
    expect(result.degraded).toBe(false);
    expect(insertMock).toHaveBeenCalledTimes(1);
  });

  it('getBootstrapHealth returns safe defaults when no runs exist', async () => {
    rpcMock.mockResolvedValueOnce({ data: [], error: null });
    const h = await getBootstrapHealth('blog' as keyof ModulesSettings);
    expect(h.is_degraded).toBe(false);
    expect(h.failure_streak).toBe(0);
  });
});
