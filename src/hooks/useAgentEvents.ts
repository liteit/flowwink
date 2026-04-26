import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';

export interface AgentEvent {
  id: string;
  event_name: string;
  payload: Record<string, unknown> | null;
  source: string | null;
  processed_at: string | null;
  created_at: string;
}

export function useAgentEvents(filter?: string) {
  return useQuery({
    queryKey: ['agent-events', filter ?? 'all'],
    queryFn: async () => {
      let q = supabase
        .from('agent_events')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(50);
      if (filter && filter.trim()) {
        q = q.ilike('event_name', `%${filter.trim()}%`);
      }
      const { data, error } = await q;
      if (error) throw error;
      return (data ?? []) as unknown as AgentEvent[];
    },
    refetchInterval: 15000,
  });
}
