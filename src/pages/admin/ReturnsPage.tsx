import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { AdminLayout } from '@/components/admin/AdminLayout';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Button } from '@/components/ui/button';
import { Undo2, CheckCircle2, PackageCheck, RefreshCw } from 'lucide-react';
import { toast } from 'sonner';
import { formatDistanceToNow } from 'date-fns';

interface ReturnRow {
  id: string;
  rma_number: string;
  order_id: string;
  status: string;
  reason: string | null;
  refund_amount_cents: number | null;
  refund_currency: string | null;
  created_at: string;
}

const STATUS_COLORS: Record<string, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  requested: 'outline',
  approved: 'secondary',
  received: 'secondary',
  refunded: 'default',
  rejected: 'destructive',
  cancelled: 'destructive',
};

export default function ReturnsPage() {
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ['returns'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('returns' as any)
        .select('*')
        .order('created_at', { ascending: false });
      if (error) throw error;
      return (data ?? []) as unknown as ReturnRow[];
    },
  });

  const approve = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('approve_return' as any, { p_return_id: id });
      if (error) throw error;
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['returns'] }); toast.success('Return approved'); },
    onError: (e: Error) => toast.error(e.message),
  });

  const receive = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('receive_return' as any, { p_return_id: id });
      if (error) throw error;
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['returns'] }); toast.success('Return received & restocked'); },
    onError: (e: Error) => toast.error(e.message),
  });

  return (
    <AdminLayout>
      <div className="container mx-auto p-6 space-y-6">
        <div>
          <h1 className="text-3xl font-bold flex items-center gap-2">
            <Undo2 className="h-7 w-7" /> Returns / RMA
          </h1>
          <p className="text-muted-foreground mt-1">
            Process customer returns: approve, receive & restock, refund.
          </p>
        </div>

        <Card>
          <CardHeader>
            <CardTitle>All returns</CardTitle>
            <CardDescription>
              Status flow: requested → approved → received (auto-restock) → refunded
            </CardDescription>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <p className="text-muted-foreground">Loading…</p>
            ) : (data?.length ?? 0) === 0 ? (
              <div className="text-center py-12">
                <p className="text-muted-foreground">No returns yet.</p>
              </div>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>RMA #</TableHead>
                    <TableHead>Order</TableHead>
                    <TableHead>Reason</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead>Refund</TableHead>
                    <TableHead>Age</TableHead>
                    <TableHead className="text-right">Actions</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {data!.map((r) => (
                    <TableRow key={r.id}>
                      <TableCell className="font-medium">{r.rma_number}</TableCell>
                      <TableCell className="text-xs font-mono">{r.order_id.slice(0, 8)}</TableCell>
                      <TableCell className="max-w-xs truncate">{r.reason ?? '—'}</TableCell>
                      <TableCell>
                        <Badge variant={STATUS_COLORS[r.status] ?? 'outline'}>{r.status}</Badge>
                      </TableCell>
                      <TableCell>
                        {r.refund_amount_cents != null
                          ? new Intl.NumberFormat('sv-SE', { style: 'currency', currency: r.refund_currency ?? 'SEK' }).format(r.refund_amount_cents / 100)
                          : '—'}
                      </TableCell>
                      <TableCell className="text-sm text-muted-foreground">
                        {formatDistanceToNow(new Date(r.created_at), { addSuffix: true })}
                      </TableCell>
                      <TableCell className="text-right space-x-2">
                        {r.status === 'requested' && (
                          <Button size="sm" variant="outline" onClick={() => approve.mutate(r.id)}>
                            <CheckCircle2 className="h-3 w-3 mr-1" /> Approve
                          </Button>
                        )}
                        {r.status === 'approved' && (
                          <Button size="sm" variant="outline" onClick={() => receive.mutate(r.id)}>
                            <PackageCheck className="h-3 w-3 mr-1" /> Receive
                          </Button>
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>
      </div>
    </AdminLayout>
  );
}
