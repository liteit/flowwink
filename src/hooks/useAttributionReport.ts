import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';

export interface AttributionRow {
  utm_source: string;
  utm_medium: string;
  utm_campaign: string;
  visits: number;
  unique_visitors: number;
  leads: number;
  orders: number;
  revenue_cents: number;
}

export function useAttributionReport(sinceDays = 30) {
  return useQuery({
    queryKey: ['utm-attribution-report', sinceDays],
    queryFn: async () => {
      const since = new Date(Date.now() - sinceDays * 24 * 60 * 60 * 1000).toISOString();
      const { data, error } = await supabase.rpc('utm_attribution_report', { _since: since });
      if (error) throw error;
      return (data ?? []) as AttributionRow[];
    },
  });
}
