import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { format } from 'date-fns';
import {
  ShoppingBag,
  CreditCard,
  Check,
  PackageCheck,
  Truck,
  MapPin,
  Mail,
  RefreshCw,
  XCircle,
  Activity,
} from 'lucide-react';
import type { Tables } from '@/integrations/supabase/types';

type Order = Tables<'orders'>;

interface OrderEventHistoryProps {
  order: Order;
}

interface TimelineEvent {
  key: string;
  at: string;
  label: string;
  detail?: string;
  icon: React.ElementType;
  color: string;
}

const ACTION_META: Record<string, { label: string; icon: React.ElementType; color: string }> = {
  'order.created': { label: 'Order created', icon: ShoppingBag, color: 'text-muted-foreground' },
  'order.paid': { label: 'Payment received', icon: CreditCard, color: 'text-emerald-600' },
  'order.status_changed': { label: 'Status changed', icon: Activity, color: 'text-blue-600' },
  'order.fulfillment.picked': { label: 'Marked as picked', icon: Check, color: 'text-amber-600' },
  'order.fulfillment.packed': { label: 'Marked as packed', icon: PackageCheck, color: 'text-blue-600' },
  'order.fulfillment.shipped': { label: 'Marked as shipped', icon: Truck, color: 'text-indigo-600' },
  'order.fulfillment.delivered': { label: 'Marked as delivered', icon: MapPin, color: 'text-emerald-600' },
  'order.confirmation_sent': { label: 'Confirmation email sent', icon: Mail, color: 'text-muted-foreground' },
  'order.refunded': { label: 'Refunded', icon: RefreshCw, color: 'text-purple-600' },
  'order.cancelled': { label: 'Cancelled', icon: XCircle, color: 'text-destructive' },
};

export function OrderEventHistory({ order }: OrderEventHistoryProps) {
  const { data: logs = [], isLoading } = useQuery({
    queryKey: ['order-audit-logs', order.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('audit_logs')
        .select('*')
        .eq('entity_type', 'order')
        .eq('entity_id', order.id)
        .order('created_at', { ascending: true });
      if (error) throw error;
      return data ?? [];
    },
  });

  const events: TimelineEvent[] = [];

  // Always include created
  events.push({
    key: 'created',
    at: order.created_at,
    label: 'Order created',
    icon: ShoppingBag,
    color: 'text-muted-foreground',
  });

  // Intrinsic fulfillment timestamps (fallback when no audit log entry exists)
  const intrinsic: Array<[string, string | null | undefined, string, React.ElementType, string]> = [
    ['picked', (order as any).picked_at, 'Picked', Check, 'text-amber-600'],
    ['packed', (order as any).packed_at, 'Packed', PackageCheck, 'text-blue-600'],
    ['shipped', (order as any).shipped_at, 'Shipped', Truck, 'text-indigo-600'],
    ['delivered', (order as any).delivered_at, 'Delivered', MapPin, 'text-emerald-600'],
  ];
  for (const [key, at, label, icon, color] of intrinsic) {
    if (at) events.push({ key, at, label, icon, color });
  }

  // Audit log entries
  for (const log of logs) {
    const meta = ACTION_META[log.action] || {
      label: log.action,
      icon: Activity,
      color: 'text-muted-foreground',
    };
    const md = (log.metadata ?? {}) as Record<string, unknown>;
    const detailParts: string[] = [];
    if (md.from && md.to) detailParts.push(`${md.from} → ${md.to}`);
    if (md.tracking_number) detailParts.push(`#${md.tracking_number}`);
    if (md.note) detailParts.push(String(md.note));
    events.push({
      key: log.id,
      at: log.created_at,
      label: meta.label,
      detail: detailParts.join(' · ') || undefined,
      icon: meta.icon,
      color: meta.color,
    });
  }

  // Dedupe intrinsic vs audit on same key+second
  const seen = new Set<string>();
  const sorted = events
    .filter((e) => {
      const k = `${e.label}-${e.at?.slice(0, 19)}`;
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    })
    .sort((a, b) => new Date(a.at).getTime() - new Date(b.at).getTime());

  if (isLoading && events.length === 1) {
    return <p className="text-sm text-muted-foreground">Loading history...</p>;
  }

  return (
    <div className="space-y-3">
      {sorted.map((e, idx) => {
        const Icon = e.icon;
        const isLast = idx === sorted.length - 1;
        return (
          <div key={e.key} className="flex gap-3">
            <div className="flex flex-col items-center">
              <div className={`flex h-8 w-8 items-center justify-center rounded-full bg-muted ${e.color}`}>
                <Icon className="h-4 w-4" />
              </div>
              {!isLast && <div className="w-px flex-1 bg-border mt-1" />}
            </div>
            <div className="flex-1 pb-2">
              <p className="text-sm font-medium">{e.label}</p>
              {e.detail && <p className="text-xs text-muted-foreground">{e.detail}</p>}
              <p className="text-xs text-muted-foreground">
                {format(new Date(e.at), 'PPp')}
              </p>
            </div>
          </div>
        );
      })}
    </div>
  );
}
