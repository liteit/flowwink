import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { toast } from 'sonner';

export interface GiftCard {
  id: string;
  code: string;
  balance_cents: number;
  initial_amount_cents?: number;
  currency: string;
  status: 'active' | 'deactivated' | string;
  issued_at?: string;
  created_at?: string;
  deactivated_at?: string | null;
}

function extractCards(data: any): GiftCard[] {
  if (Array.isArray(data)) return data as GiftCard[];
  return (data?.gift_cards ?? data?.cards ?? []) as GiftCard[];
}

export function useGiftCards() {
  return useQuery({
    queryKey: ['gift_cards'],
    queryFn: async (): Promise<GiftCard[]> => {
      const { data, error } = await supabase.rpc('manage_gift_card' as any, {
        p_action: 'list',
      });
      if (error) throw error;
      return extractCards(data);
    },
  });
}

export function useIssueGiftCard() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: { p_code?: string | null; p_amount_cents: number }): Promise<GiftCard> => {
      const { data, error } = await supabase.rpc('manage_gift_card' as any, {
        p_action: 'issue',
        p_code: input.p_code ?? null,
        p_amount_cents: input.p_amount_cents,
      });
      if (error) throw error;
      const card = (data as any)?.gift_card ?? (data as any)?.card ?? (data as any);
      return card as GiftCard;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['gift_cards'] });
      toast.success('Gift card issued');
    },
    onError: (e: Error) => toast.error(e.message),
  });
}

export function useDeactivateGiftCard() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (code: string) => {
      const { data, error } = await supabase.rpc('manage_gift_card' as any, {
        p_action: 'deactivate',
        p_code: code,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['gift_cards'] });
      toast.success('Gift card deactivated');
    },
    onError: (e: Error) => toast.error(e.message),
  });
}

/** Imperative lookup — not cached; returns null if not found. */
export async function lookupGiftCard(code: string): Promise<GiftCard | null> {
  const { data, error } = await supabase.rpc('manage_gift_card' as any, {
    p_action: 'get',
    p_code: code,
  });
  if (error) throw error;
  const card = (data as any)?.gift_card ?? (data as any)?.card ?? (data as any);
  if (!card || !card.code) return null;
  return card as GiftCard;
}
