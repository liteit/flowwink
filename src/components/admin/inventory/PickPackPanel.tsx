import { useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter, DialogDescription } from '@/components/ui/dialog';
import { Package, Truck, X, CheckCircle2, Loader2, PackageCheck } from 'lucide-react';
import { formatDistanceToNow } from 'date-fns';
import {
  usePickingOrders,
  usePickingLines,
  useConfirmPick,
  useShipPicking,
  useCancelPicking,
  useAllocatePicking,
  type PickingOrder,
} from '@/hooks/usePickPack';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';

const STATUS_VARIANT: Record<string, string> = {
  draft: 'bg-muted text-muted-foreground',
  ready: 'bg-blue-500/10 text-blue-600 border-blue-500/20',
  in_progress: 'bg-amber-500/10 text-amber-600 border-amber-500/20',
  picked: 'bg-violet-500/10 text-violet-600 border-violet-500/20',
  shipped: 'bg-emerald-500/10 text-emerald-600 border-emerald-500/20',
  cancelled: 'bg-destructive/10 text-destructive border-destructive/20',
};

export function PickPackPanel() {
  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [selectedPicking, setSelectedPicking] = useState<PickingOrder | null>(null);
  const [allocateOrderId, setAllocateOrderId] = useState('');

  const { data: pickings = [], isLoading } = usePickingOrders(statusFilter === 'all' ? undefined : statusFilter);
  const allocate = useAllocatePicking();

  // Stats
  const stats = {
    ready: pickings.filter((p) => p.status === 'ready').length,
    inProgress: pickings.filter((p) => p.status === 'in_progress').length,
    picked: pickings.filter((p) => p.status === 'picked').length,
    shipped: pickings.filter((p) => p.status === 'shipped').length,
  };

  return (
    <div className="space-y-6">
      {/* KPI Strip */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <KpiCard icon={<Package className="h-4 w-4" />} label="Ready" value={stats.ready} tone="blue" />
        <KpiCard icon={<Loader2 className="h-4 w-4" />} label="In Progress" value={stats.inProgress} tone="amber" />
        <KpiCard icon={<PackageCheck className="h-4 w-4" />} label="Picked" value={stats.picked} tone="violet" />
        <KpiCard icon={<Truck className="h-4 w-4" />} label="Shipped" value={stats.shipped} tone="emerald" />
      </div>

      <Card>
        <CardHeader className="flex flex-row items-center justify-between gap-3">
          <div>
            <CardTitle className="text-base">Pick & Pack</CardTitle>
            <p className="text-xs text-muted-foreground mt-1">
              Live order fulfillment — auto-allocates when an order is paid.
            </p>
          </div>
          <div className="flex items-center gap-2">
            <Select value={statusFilter} onValueChange={setStatusFilter}>
              <SelectTrigger className="w-[140px]">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All</SelectItem>
                <SelectItem value="ready">Ready</SelectItem>
                <SelectItem value="in_progress">In Progress</SelectItem>
                <SelectItem value="picked">Picked</SelectItem>
                <SelectItem value="shipped">Shipped</SelectItem>
                <SelectItem value="cancelled">Cancelled</SelectItem>
              </SelectContent>
            </Select>
          </div>
        </CardHeader>
        <CardContent>
          <div className="flex items-end gap-2 mb-4 p-3 rounded-md border bg-muted/30">
            <div className="flex-1">
              <Label className="text-xs">Manually allocate from order ID</Label>
              <Input
                value={allocateOrderId}
                onChange={(e) => setAllocateOrderId(e.target.value)}
                placeholder="order UUID"
                className="h-8 mt-1"
              />
            </div>
            <Button
              size="sm"
              onClick={() => allocateOrderId && allocate.mutate(allocateOrderId, {
                onSuccess: () => setAllocateOrderId(''),
              })}
              disabled={!allocateOrderId || allocate.isPending}
            >
              Allocate
            </Button>
          </div>

          {isLoading ? (
            <p className="text-sm text-muted-foreground">Loading…</p>
          ) : pickings.length === 0 ? (
            <p className="text-sm text-muted-foreground py-8 text-center">
              No picking orders yet. Mark an order as <code>paid</code> to trigger auto-allocation.
            </p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Pick #</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Ship to</TableHead>
                  <TableHead>Tracking</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {pickings.map((p) => (
                  <TableRow key={p.id}>
                    <TableCell className="font-mono text-xs">{p.picking_number}</TableCell>
                    <TableCell>
                      <Badge variant="outline" className={STATUS_VARIANT[p.status]}>
                        {p.status}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-sm">{p.ship_to_name ?? '—'}</TableCell>
                    <TableCell className="text-xs font-mono">{p.tracking_number ?? '—'}</TableCell>
                    <TableCell className="text-xs text-muted-foreground">
                      {formatDistanceToNow(new Date(p.created_at), { addSuffix: true })}
                    </TableCell>
                    <TableCell className="text-right">
                      <Button size="sm" variant="ghost" onClick={() => setSelectedPicking(p)}>
                        Open
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <PickingDetailDialog
        picking={selectedPicking}
        onClose={() => setSelectedPicking(null)}
      />
    </div>
  );
}

function KpiCard({ icon, label, value, tone }: { icon: React.ReactNode; label: string; value: number; tone: string }) {
  const tones: Record<string, string> = {
    blue: 'text-blue-600 bg-blue-500/10',
    amber: 'text-amber-600 bg-amber-500/10',
    violet: 'text-violet-600 bg-violet-500/10',
    emerald: 'text-emerald-600 bg-emerald-500/10',
  };
  return (
    <Card>
      <CardContent className="p-4 flex items-center gap-3">
        <div className={`h-9 w-9 rounded-md flex items-center justify-center ${tones[tone]}`}>{icon}</div>
        <div>
          <p className="text-xs text-muted-foreground">{label}</p>
          <p className="text-2xl font-semibold">{value}</p>
        </div>
      </CardContent>
    </Card>
  );
}

function PickingDetailDialog({ picking, onClose }: { picking: PickingOrder | null; onClose: () => void }) {
  const { data: lines = [] } = usePickingLines(picking?.id ?? null);
  const confirmPick = useConfirmPick();
  const shipPicking = useShipPicking();
  const cancelPicking = useCancelPicking();
  const [trackingNumber, setTrackingNumber] = useState('');
  const [carrier, setCarrier] = useState('');

  // Lots for the products in this picking
  const productIds = lines.map((l) => l.product_id).filter(Boolean) as string[];
  const { data: lots = [] } = useQuery({
    queryKey: ['lots-for-picking', productIds],
    queryFn: async () => {
      if (productIds.length === 0) return [];
      const { data } = await supabase
        .from('stock_lots')
        .select('id, lot_number, product_id, expiry_date')
        .in('product_id', productIds);
      return data ?? [];
    },
    enabled: productIds.length > 0,
  });

  if (!picking) return null;

  const allPicked = lines.length > 0 && lines.every((l) => l.status === 'picked' || l.status === 'short' || l.status === 'cancelled');
  const canShip = picking.status === 'picked' || (allPicked && picking.status === 'in_progress');

  return (
    <Dialog open={!!picking} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 font-mono">
            {picking.picking_number}
            <Badge variant="outline" className={STATUS_VARIANT[picking.status]}>
              {picking.status}
            </Badge>
          </DialogTitle>
          <DialogDescription>
            {picking.ship_to_name && <>Ship to: <strong>{picking.ship_to_name}</strong> · </>}
            Order: <code>{picking.order_id ?? '—'}</code>
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3 max-h-[50vh] overflow-y-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Product</TableHead>
                <TableHead>Req</TableHead>
                <TableHead>Picked</TableHead>
                <TableHead>Lot</TableHead>
                <TableHead>Status</TableHead>
                <TableHead></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {lines.map((line) => (
                <PickLineRow
                  key={line.id}
                  line={line}
                  lots={lots.filter((l) => l.product_id === line.product_id)}
                  disabled={picking.status === 'shipped' || picking.status === 'cancelled'}
                  onConfirm={(qty, lotId) => confirmPick.mutate({ lineId: line.id, qtyPicked: qty, lotId })}
                />
              ))}
            </TableBody>
          </Table>
        </div>

        {canShip && (
          <div className="grid grid-cols-2 gap-2 p-3 rounded-md border bg-muted/30">
            <div>
              <Label className="text-xs">Tracking number</Label>
              <Input value={trackingNumber} onChange={(e) => setTrackingNumber(e.target.value)} className="h-8 mt-1" />
            </div>
            <div>
              <Label className="text-xs">Carrier</Label>
              <Input value={carrier} onChange={(e) => setCarrier(e.target.value)} placeholder="DHL, PostNord…" className="h-8 mt-1" />
            </div>
          </div>
        )}

        <DialogFooter>
          {picking.status !== 'shipped' && picking.status !== 'cancelled' && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => cancelPicking.mutate({ pickingOrderId: picking.id, reason: 'Manual cancel' }, { onSuccess: onClose })}
            >
              <X className="h-4 w-4 mr-1" /> Cancel
            </Button>
          )}
          {canShip && (
            <Button
              onClick={() => shipPicking.mutate({ pickingOrderId: picking.id, trackingNumber, carrier }, { onSuccess: onClose })}
              disabled={shipPicking.isPending}
            >
              <Truck className="h-4 w-4 mr-1" /> Ship
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function PickLineRow({
  line,
  lots,
  disabled,
  onConfirm,
}: {
  line: ReturnType<typeof usePickingLines>['data'] extends (infer T)[] | undefined ? T : never;
  lots: { id: string; lot_number: string; expiry_date: string | null }[];
  disabled: boolean;
  onConfirm: (qty: number, lotId?: string) => void;
}) {
  const [qty, setQty] = useState(String(line.qty_requested));
  const [lotId, setLotId] = useState<string>(line.lot_id ?? '');

  const isDone = line.status === 'picked' || line.status === 'cancelled';

  return (
    <TableRow>
      <TableCell className="font-medium">
        {line.product_name}
        {line.product_sku && <span className="text-xs text-muted-foreground ml-2">({line.product_sku})</span>}
      </TableCell>
      <TableCell>{line.qty_requested}</TableCell>
      <TableCell>
        {isDone ? (
          <span>{line.qty_picked}</span>
        ) : (
          <Input
            type="number"
            value={qty}
            onChange={(e) => setQty(e.target.value)}
            className="h-7 w-20"
            disabled={disabled}
          />
        )}
      </TableCell>
      <TableCell>
        {isDone ? (
          <span className="text-xs font-mono text-muted-foreground">
            {lots.find((l) => l.id === line.lot_id)?.lot_number ?? '—'}
          </span>
        ) : lots.length > 0 ? (
          <Select value={lotId} onValueChange={setLotId}>
            <SelectTrigger className="h-7 w-32"><SelectValue placeholder="lot…" /></SelectTrigger>
            <SelectContent>
              {lots.map((l) => (
                <SelectItem key={l.id} value={l.id}>{l.lot_number}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        ) : (
          <span className="text-xs text-muted-foreground">—</span>
        )}
      </TableCell>
      <TableCell>
        <Badge variant="outline" className="text-xs">{line.status}</Badge>
      </TableCell>
      <TableCell className="text-right">
        {!isDone && (
          <Button
            size="sm"
            variant="ghost"
            onClick={() => onConfirm(Number(qty), lotId || undefined)}
            disabled={disabled}
          >
            <CheckCircle2 className="h-4 w-4" />
          </Button>
        )}
      </TableCell>
    </TableRow>
  );
}
