import { useEffect } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { toast } from 'sonner';

export interface PickingOrder {
  id: string;
  picking_number: string;
  order_id: string | null;
  source_location_id: string | null;
  status: 'draft' | 'ready' | 'in_progress' | 'picked' | 'shipped' | 'cancelled';
  assigned_to: string | null;
  ship_to_name: string | null;
  tracking_number: string | null;
  carrier: string | null;
  allocated_at: string | null;
  picked_at: string | null;
  shipped_at: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
  created_at: string;
}

export interface PickingLine {
  id: string;
  picking_order_id: string;
  product_id: string | null;
  product_sku: string | null;
  product_name: string;
  qty_requested: number;
  qty_picked: number;
  lot_id: string | null;
  reservation_id: string | null;
  status: 'pending' | 'reserved' | 'picked' | 'short' | 'cancelled';
  picked_at: string | null;
  picked_by: string | null;
  created_at: string;
}

export function usePickingOrders(statusFilter?: string) {
  const queryClient = useQueryClient();

  const query = useQuery({
    queryKey: ['picking-orders', statusFilter ?? 'all'],
    queryFn: async () => {
      let q = supabase
        .from('picking_orders')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(50);
      if (statusFilter && statusFilter !== 'all') {
        q = q.eq('status', statusFilter);
      }
      const { data, error } = await q;
      if (error) throw error;
      return (data ?? []) as PickingOrder[];
    },
  });

  // Realtime subscription for new pick events
  useEffect(() => {
    const channel = supabase
      .channel('picking-orders-feed')
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'picking_orders' },
        (payload) => {
          queryClient.invalidateQueries({ queryKey: ['picking-orders'] });
          if (payload.eventType === 'INSERT') {
            const po = payload.new as PickingOrder;
            toast.info(`New pick: ${po.picking_number}`);
          } else if (payload.eventType === 'UPDATE') {
            const po = payload.new as PickingOrder;
            const old = payload.old as PickingOrder;
            if (po.status === 'shipped' && old.status !== 'shipped') {
              toast.success(`Shipped: ${po.picking_number}`);
            } else if (po.status === 'cancelled' && old.status !== 'cancelled') {
              toast.warning(`Cancelled: ${po.picking_number}`);
            }
          }
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [queryClient]);

  return query;
}

export function usePickingLines(pickingOrderId: string | null) {
  return useQuery({
    queryKey: ['picking-lines', pickingOrderId],
    queryFn: async () => {
      if (!pickingOrderId) return [] as PickingLine[];
      const { data, error } = await supabase
        .from('picking_lines')
        .select('*')
        .eq('picking_order_id', pickingOrderId)
        .order('created_at');
      if (error) throw error;
      return (data ?? []) as PickingLine[];
    },
    enabled: !!pickingOrderId,
  });
}

export function useAllocatePicking() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (orderId: string) => {
      const { data, error } = await supabase.rpc('allocate_picking', {
        p_order_id: orderId,
      });
      if (error) throw error;
      return data as { picking_order_id: string; lines_total: number; lines_short: number };
    },
    onSuccess: (res) => {
      queryClient.invalidateQueries({ queryKey: ['picking-orders'] });
      const shortMsg = res.lines_short > 0 ? ` (${res.lines_short} short)` : '';
      toast.success(`Allocated ${res.lines_total} lines${shortMsg}`);
    },
    onError: (err: Error) => toast.error(`Allocation failed: ${err.message}`),
  });
}

export function useConfirmPick() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (args: { lineId: string; qtyPicked: number; lotId?: string }) => {
      const { data, error } = await supabase.rpc('confirm_pick', {
        p_line_id: args.lineId,
        p_qty_picked: args.qtyPicked,
        p_lot_id: args.lotId ?? undefined,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['picking-lines'] });
      queryClient.invalidateQueries({ queryKey: ['picking-orders'] });
      toast.success('Pick confirmed');
    },
    onError: (err: Error) => toast.error(`Pick failed: ${err.message}`),
  });
}

export function useShipPicking() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (args: { pickingOrderId: string; trackingNumber?: string; carrier?: string }) => {
      const { data, error } = await supabase.rpc('ship_picking', {
        p_picking_order_id: args.pickingOrderId,
        p_tracking_number: args.trackingNumber ?? undefined,
        p_carrier: args.carrier ?? undefined,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['picking-orders'] });
      queryClient.invalidateQueries({ queryKey: ['picking-lines'] });
    },
    onError: (err: Error) => toast.error(`Ship failed: ${err.message}`),
  });
}

export function useCancelPicking() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (args: { pickingOrderId: string; reason?: string }) => {
      const { data, error } = await supabase.rpc('cancel_picking', {
        p_picking_order_id: args.pickingOrderId,
        p_reason: args.reason ?? undefined,
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['picking-orders'] });
    },
    onError: (err: Error) => toast.error(`Cancel failed: ${err.message}`),
  });
}
