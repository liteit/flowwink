import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { toast } from 'sonner';

export type ConnectionDirection = 'outbound' | 'inbound' | 'bidirectional';
export type ConnectionTransport = 'a2a' | 'openresponses' | 'mcp';

export interface FederationConnection {
  id: string;
  peer_id: string;
  direction: ConnectionDirection;
  transport: ConnectionTransport;
  endpoint_url: string | null;
  outbound_token: string | null;
  api_key_id: string | null;
  status: string;
  last_activity_at: string | null;
  request_count: number;
  metadata: Record<string, unknown>;
  created_at: string;
  updated_at: string;
}

export interface FederationConnectionWithPeer extends FederationConnection {
  peer: {
    id: string;
    name: string;
    status: string;
  };
  api_key?: {
    id: string;
    name: string;
    key_prefix: string;
    last_used_at: string | null;
  } | null;
}

export function useFederationConnections(peerId?: string) {
  return useQuery({
    queryKey: ['federation-connections', peerId ?? 'all'],
    queryFn: async () => {
      let query = supabase
        .from('federation_connections' as any)
        .select(`
          id, peer_id, direction, transport, endpoint_url, outbound_token,
          api_key_id, status, last_activity_at, request_count, metadata,
          created_at, updated_at,
          peer:a2a_peers!peer_id(id, name, status),
          api_key:api_keys!api_key_id(id, name, key_prefix, last_used_at)
        `)
        .order('created_at', { ascending: false });

      if (peerId) query = query.eq('peer_id', peerId);

      const { data, error } = await query;
      if (error) throw error;
      return (data ?? []) as unknown as FederationConnectionWithPeer[];
    },
  });
}

export function useDeleteFederationConnection() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('federation_connections' as any)
        .delete()
        .eq('id', id);
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['federation-connections'] });
      toast.success('Connection removed');
    },
    onError: () => toast.error('Failed to remove connection'),
  });
}

export function useCreateFederationConnection() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: {
      peer_id: string;
      direction: ConnectionDirection;
      transport: ConnectionTransport;
      endpoint_url?: string | null;
      outbound_token?: string | null;
      api_key_id?: string | null;
    }) => {
      const { error } = await supabase
        .from('federation_connections' as any)
        .insert(input as any);
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['federation-connections'] });
      toast.success('Connection added');
    },
    onError: (err: any) => toast.error(err?.message || 'Failed to add connection'),
  });
}
