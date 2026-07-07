import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';

export interface CannedResponse {
  id: string;
  title: string;
  shortcut: string | null;
  body_md: string;
  category: string | null;
  is_active: boolean;
  usage_count: number;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}

export interface CannedResponseInput {
  title: string;
  shortcut?: string | null;
  body_md: string;
  category?: string | null;
  is_active?: boolean;
}

export function useCannedResponses(activeOnly = false) {
  return useQuery({
    queryKey: ['canned_responses', { activeOnly }],
    queryFn: async () => {
      let q = supabase.from('canned_responses').select('*').order('title');
      if (activeOnly) q = q.eq('is_active', true);
      const { data, error } = await q;
      if (error) throw error;
      return (data ?? []) as CannedResponse[];
    },
  });
}

export function useCreateCannedResponse() {
  const qc = useQueryClient();
  const { toast } = useToast();
  return useMutation({
    mutationFn: async (input: CannedResponseInput) => {
      const { data: userRes } = await supabase.auth.getUser();
      const { error } = await supabase.from('canned_responses').insert([{
        title: input.title,
        shortcut: input.shortcut || null,
        body_md: input.body_md,
        category: input.category || null,
        is_active: input.is_active ?? true,
        created_by: userRes.user?.id ?? null,
      }]);
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['canned_responses'] });
      toast({ title: 'Canned response created' });
    },
    onError: (err: Error) => toast({ title: 'Error', description: err.message, variant: 'destructive' }),
  });
}

export function useUpdateCannedResponse() {
  const qc = useQueryClient();
  const { toast } = useToast();
  return useMutation({
    mutationFn: async ({ id, ...updates }: Partial<CannedResponseInput> & { id: string }) => {
      const { error } = await supabase
        .from('canned_responses')
        .update({ ...updates, updated_at: new Date().toISOString() } as never)
        .eq('id', id);
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['canned_responses'] });
      toast({ title: 'Canned response updated' });
    },
    onError: (err: Error) => toast({ title: 'Error', description: err.message, variant: 'destructive' }),
  });
}

export function useIncrementCannedUsage() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const { data: current } = await supabase
        .from('canned_responses')
        .select('usage_count')
        .eq('id', id)
        .single();
      const next = ((current as { usage_count?: number } | null)?.usage_count ?? 0) + 1;
      await supabase
        .from('canned_responses')
        .update({ usage_count: next } as never)
        .eq('id', id);
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['canned_responses'] }),
  });
}
