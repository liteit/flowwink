/**
 * Client-side subscription provider registry.
 *
 * The frontend never talks to providers directly — it dispatches to the
 * unified `subscriptions` edge function with an `action` parameter
 * (checkout | portal | manage). This file only exports types + a small
 * helper that picks the active provider from site_settings.
 */

import { supabase } from '@/integrations/supabase/client';
import type { SubscriptionProviderId } from './types';

export * from './types';

export type SubscriptionAction = 'checkout' | 'portal' | 'manage' | 'sync';

export async function getActiveProvider(): Promise<SubscriptionProviderId> {
  const { data } = await supabase
    .from('site_settings')
    .select('value')
    .eq('key', 'subscriptions')
    .maybeSingle();
  const value = (data?.value as { provider?: SubscriptionProviderId } | null) ?? null;
  return value?.provider ?? 'stripe';
}

export async function invokeSubscriptionEdge<T = unknown>(
  action: SubscriptionAction,
  body: Record<string, unknown>,
): Promise<T> {
  const fn = action === 'sync' ? 'subscriptions-sync' : 'subscriptions';
  const payload = action === 'sync' ? body : { action, ...body };
  const { data, error } = await supabase.functions.invoke(fn, { body: payload });
  if (error) throw error;
  return data as T;
}
