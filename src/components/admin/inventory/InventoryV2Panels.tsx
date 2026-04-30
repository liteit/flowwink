import { useState } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { PlayCircle, Check, X, Warehouse, AlertTriangle } from 'lucide-react';
import {
  useReorderRules,
  useProcurementSuggestions,
  useRunProcurement,
  useApproveSuggestion,
  useRejectSuggestion,
  useUpsertReorderRule,
  useStockLocations,
} from '@/hooks/useInventoryV2';
import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { formatDistanceToNow } from 'date-fns';

export function ReorderMrpPanel() {
  const { data: rules = [], isLoading: rulesLoading } = useReorderRules();
  const { data: suggestions = [], isLoading: sugLoading } = useProcurementSuggestions('pending');
  const { data: locations = [] } = useStockLocations();
  const run = useRunProcurement();
  const approve = useApproveSuggestion();
  const reject = useRejectSuggestion();
  const upsert = useUpsertReorderRule();

  const [ruleDialog, setRuleDialog] = useState(false);
  const [form, setForm] = useState({
    product_id: '',
    location_id: locations[0]?.id ?? '',
    min_qty: 5,
    max_qty: 50,
    lead_time_days: 7,
    procurement_method: 'buy' as 'buy' | 'manufacture',
    preferred_vendor_id: '',
  });

  const { data: products = [] } = useQuery({
    queryKey: ['products-for-reorder'],
    queryFn: async () => {
      const { data } = await supabase.from('products').select('id, name').order('name');
      return data ?? [];
    },
  });

  const { data: vendors = [] } = useQuery({
    queryKey: ['vendors-for-reorder'],
    queryFn: async () => {
      const { data } = await supabase.from('vendors').select('id, name').eq('is_active', true).order('name');
      return data ?? [];
    },
  });

  const submitRule = () => {
    if (!form.product_id || !form.location_id) return;
    upsert.mutate(
      {
        product_id: form.product_id,
        location_id: form.location_id,
        min_qty: Number(form.min_qty),
        max_qty: Number(form.max_qty),
        lead_time_days: Number(form.lead_time_days),
        procurement_method: form.procurement_method,
        preferred_vendor_id: form.preferred_vendor_id || null,
      },
      { onSuccess: () => setRuleDialog(false) }
    );
  };

  return (
    <div className="space-y-6">
      {/* Suggestions */}
      <Card>
        <CardContent className="p-0">
          <div className="flex items-center justify-between p-4 border-b">
            <div>
              <h3 className="font-semibold flex items-center gap-2">
                <AlertTriangle className="h-4 w-4 text-amber-500" />
                Procurement Suggestions
                <Badge variant="secondary">{suggestions.length}</Badge>
              </h3>
              <p className="text-xs text-muted-foreground mt-1">
                Pending PO/MO proposals from the MRP scheduler.
              </p>
            </div>
            <Button onClick={() => run.mutate()} disabled={run.isPending} className="gap-2" size="sm">
              <PlayCircle className="h-4 w-4" />
              {run.isPending ? 'Running...' : 'Run Procurement'}
            </Button>
          </div>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Product</TableHead>
                <TableHead>Location</TableHead>
                <TableHead className="text-right">Qty</TableHead>
                <TableHead>Method</TableHead>
                <TableHead>Vendor</TableHead>
                <TableHead>Needed by</TableHead>
                <TableHead>Reasoning</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {sugLoading ? (
                <TableRow><TableCell colSpan={8} className="text-center py-8 text-muted-foreground">Loading...</TableCell></TableRow>
              ) : suggestions.length === 0 ? (
                <TableRow><TableCell colSpan={8} className="text-center py-8 text-muted-foreground">No pending suggestions. Run procurement to scan reorder rules.</TableCell></TableRow>
              ) : suggestions.map(s => (
                <TableRow key={s.id}>
                  <TableCell className="font-medium">{s.products?.name ?? s.product_id.slice(0,8)}</TableCell>
                  <TableCell>{s.stock_locations?.code ?? '—'}</TableCell>
                  <TableCell className="text-right tabular-nums">{s.suggested_qty}</TableCell>
                  <TableCell><Badge variant="outline">{s.procurement_method}</Badge></TableCell>
                  <TableCell>{s.vendors?.name ?? '—'}</TableCell>
                  <TableCell className="text-sm text-muted-foreground">{s.needed_by ?? '—'}</TableCell>
                  <TableCell className="text-xs text-muted-foreground max-w-[200px] truncate">
                    {s.reasoning ? `on:${s.reasoning.on_hand} res:${s.reasoning.reserved} inc:${s.reasoning.incoming} virt:${s.reasoning.virtual} min:${s.reasoning.min_qty}` : '—'}
                  </TableCell>
                  <TableCell className="text-right">
                    <div className="flex justify-end gap-1">
                      <Button size="icon" variant="ghost" onClick={() => approve.mutate(s.id)} disabled={approve.isPending} title="Approve & materialize">
                        <Check className="h-4 w-4 text-emerald-600" />
                      </Button>
                      <Button size="icon" variant="ghost" onClick={() => reject.mutate({ id: s.id })} disabled={reject.isPending} title="Reject">
                        <X className="h-4 w-4 text-destructive" />
                      </Button>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      {/* Reorder Rules */}
      <Card>
        <CardContent className="p-0">
          <div className="flex items-center justify-between p-4 border-b">
            <div>
              <h3 className="font-semibold flex items-center gap-2">
                <Warehouse className="h-4 w-4" />
                Reorder Rules
                <Badge variant="secondary">{rules.length}</Badge>
              </h3>
              <p className="text-xs text-muted-foreground mt-1">
                Min/max levels per product+location that drive the procurement run.
              </p>
            </div>
            <Button size="sm" variant="outline" onClick={() => setRuleDialog(true)}>Add Rule</Button>
          </div>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Product</TableHead>
                <TableHead>Location</TableHead>
                <TableHead className="text-right">Min</TableHead>
                <TableHead className="text-right">Max</TableHead>
                <TableHead className="text-right">Lead (d)</TableHead>
                <TableHead>Method</TableHead>
                <TableHead>Vendor</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rulesLoading ? (
                <TableRow><TableCell colSpan={7} className="text-center py-8 text-muted-foreground">Loading...</TableCell></TableRow>
              ) : rules.length === 0 ? (
                <TableRow><TableCell colSpan={7} className="text-center py-8 text-muted-foreground">No reorder rules defined.</TableCell></TableRow>
              ) : rules.map(r => (
                <TableRow key={r.id}>
                  <TableCell className="font-medium">{r.products?.name ?? r.product_id.slice(0,8)}</TableCell>
                  <TableCell>{r.stock_locations?.code ?? '—'}</TableCell>
                  <TableCell className="text-right tabular-nums">{r.min_qty}</TableCell>
                  <TableCell className="text-right tabular-nums">{r.max_qty}</TableCell>
                  <TableCell className="text-right tabular-nums">{r.lead_time_days}</TableCell>
                  <TableCell><Badge variant="outline">{r.procurement_method}</Badge></TableCell>
                  <TableCell className="text-sm">{r.vendors?.name ?? '—'}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      {/* Add Rule Dialog */}
      <Dialog open={ruleDialog} onOpenChange={setRuleDialog}>
        <DialogContent>
          <DialogHeader><DialogTitle>Add Reorder Rule</DialogTitle></DialogHeader>
          <div className="space-y-3">
            <div>
              <Label>Product</Label>
              <Select value={form.product_id} onValueChange={(v) => setForm({ ...form, product_id: v })}>
                <SelectTrigger><SelectValue placeholder="Select product" /></SelectTrigger>
                <SelectContent>
                  {products.map(p => <SelectItem key={p.id} value={p.id}>{p.name}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div>
              <Label>Location</Label>
              <Select value={form.location_id} onValueChange={(v) => setForm({ ...form, location_id: v })}>
                <SelectTrigger><SelectValue placeholder="Select location" /></SelectTrigger>
                <SelectContent>
                  {locations.filter(l => l.location_type === 'internal').map(l => (
                    <SelectItem key={l.id} value={l.id}>{l.code} — {l.name}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="grid grid-cols-3 gap-2">
              <div>
                <Label>Min</Label>
                <Input type="number" value={form.min_qty} onChange={e => setForm({ ...form, min_qty: Number(e.target.value) })} />
              </div>
              <div>
                <Label>Max</Label>
                <Input type="number" value={form.max_qty} onChange={e => setForm({ ...form, max_qty: Number(e.target.value) })} />
              </div>
              <div>
                <Label>Lead (d)</Label>
                <Input type="number" value={form.lead_time_days} onChange={e => setForm({ ...form, lead_time_days: Number(e.target.value) })} />
              </div>
            </div>
            <div>
              <Label>Method</Label>
              <Select value={form.procurement_method} onValueChange={(v) => setForm({ ...form, procurement_method: v as 'buy' | 'manufacture' })}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="buy">Buy (PO)</SelectItem>
                  <SelectItem value="manufacture">Manufacture (MO)</SelectItem>
                </SelectContent>
              </Select>
            </div>
            {form.procurement_method === 'buy' && (
              <div>
                <Label>Preferred Vendor</Label>
                <Select value={form.preferred_vendor_id} onValueChange={(v) => setForm({ ...form, preferred_vendor_id: v })}>
                  <SelectTrigger><SelectValue placeholder="Select vendor" /></SelectTrigger>
                  <SelectContent>
                    {vendors.map(v => <SelectItem key={v.id} value={v.id}>{v.name}</SelectItem>)}
                  </SelectContent>
                </Select>
              </div>
            )}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setRuleDialog(false)}>Cancel</Button>
            <Button onClick={submitRule} disabled={upsert.isPending || !form.product_id || !form.location_id}>
              {upsert.isPending ? 'Saving...' : 'Save Rule'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export function LocationsPanel() {
  const { data: locations = [], isLoading } = useStockLocations();
  return (
    <Card>
      <CardContent className="p-0">
        <div className="p-4 border-b">
          <h3 className="font-semibold flex items-center gap-2">
            <Warehouse className="h-4 w-4" />
            Stock Locations
            <Badge variant="secondary">{locations.length}</Badge>
          </h3>
          <p className="text-xs text-muted-foreground mt-1">Warehouses, transit, scrap, and partner locations.</p>
        </div>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Code</TableHead>
              <TableHead>Name</TableHead>
              <TableHead>Type</TableHead>
              <TableHead>Active</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {isLoading ? (
              <TableRow><TableCell colSpan={4} className="text-center py-8 text-muted-foreground">Loading...</TableCell></TableRow>
            ) : locations.map(l => (
              <TableRow key={l.id}>
                <TableCell className="font-mono text-sm">{l.code}</TableCell>
                <TableCell>{l.name}</TableCell>
                <TableCell><Badge variant="outline">{l.location_type}</Badge></TableCell>
                <TableCell>{l.is_active ? <Badge className="bg-emerald-500/10 text-emerald-600 border-emerald-500/20">Active</Badge> : <Badge variant="secondary">Inactive</Badge>}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent>
    </Card>
  );
}
