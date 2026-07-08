import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';

export interface VendorScorecardRow {
  vendor_id: string;
  name: string;
  manual_rating: number | null;
  po_count: number;
  delivered_count: number;
  on_time_count: number;
  on_time_pct: number | null;
  invoice_count: number;
  variance_invoice_count: number;
  variance_pct: number | null;
  rating_notes: string | null;
  is_active: boolean;
}

export function useVendorScorecards() {
  return useQuery({
    queryKey: ['vendor-scorecards'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('v_vendor_scorecard' as any)
        .select('*')
        .order('name');
      if (error) throw error;
      return (data ?? []) as unknown as VendorScorecardRow[];
    },
  });
}

export function useUpdateVendorRating() {
  const qc = useQueryClient();
  const { toast } = useToast();
  return useMutation({
    mutationFn: async (input: { vendor_id: string; manual_rating: number | null; rating_notes?: string | null }) => {
      const { error } = await supabase
        .from('vendors')
        .update({
          manual_rating: input.manual_rating,
          rating_notes: input.rating_notes ?? null,
        } as any)
        .eq('id', input.vendor_id);
      if (error) throw error;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['vendor-scorecards'] });
      qc.invalidateQueries({ queryKey: ['vendors'] });
      toast({ title: 'Vendor rating saved' });
    },
    onError: (e: Error) => toast({ title: 'Save failed', description: e.message, variant: 'destructive' }),
  });
}
