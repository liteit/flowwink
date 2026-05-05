import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Plus, Star, Trash2 } from 'lucide-react';
import { supabase } from '@/integrations/supabase/client';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Badge } from '@/components/ui/badge';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger, DialogFooter } from '@/components/ui/dialog';

export type AddressOwnerType = 'company' | 'profile' | 'vendor' | 'lead';
export type AddressType = 'billing' | 'shipping' | 'private' | 'other';

export interface Address {
  id: string;
  owner_type: AddressOwnerType;
  owner_id: string;
  address_type: AddressType;
  is_primary: boolean;
  label: string | null;
  street: string | null;
  street2: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  country: string | null;
  phone: string | null;
  notes: string | null;
}

const TYPE_VARIANTS: Record<AddressType, 'default' | 'secondary' | 'outline'> = {
  billing: 'default', shipping: 'secondary', private: 'outline', other: 'outline',
};

export function AddressList({ ownerType, ownerId }: { ownerType: AddressOwnerType; ownerId: string }) {
  const qc = useQueryClient();
  const key = ['addresses', ownerType, ownerId];
  const { data: items = [] } = useQuery({
    queryKey: key,
    queryFn: async () => {
      const { data, error } = await supabase.from('addresses').select('*')
        .eq('owner_type', ownerType).eq('owner_id', ownerId)
        .order('is_primary', { ascending: false }).order('created_at', { ascending: true });
      if (error) throw error;
      return (data ?? []) as Address[];
    },
  });

  const create = useMutation({
    mutationFn: async (input: Partial<Address>) => {
      const { error } = await supabase.from('addresses').insert({ ...input, owner_type: ownerType, owner_id: ownerId } as any);
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: key }),
  });

  const setPrimary = useMutation({
    mutationFn: async (id: string) => {
      await supabase.from('addresses').update({ is_primary: false }).eq('owner_type', ownerType).eq('owner_id', ownerId);
      const { error } = await supabase.from('addresses').update({ is_primary: true }).eq('id', id);
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: key }),
  });

  const del = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('addresses').delete().eq('id', id);
      if (error) throw error;
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: key }),
  });

  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState<Partial<Address>>({ address_type: 'shipping' });

  return (
    <Card className="p-4 space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold">Addresses</h3>
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild><Button size="sm" variant="outline"><Plus className="h-3 w-3 mr-1" />Add</Button></DialogTrigger>
          <DialogContent>
            <DialogHeader><DialogTitle>New address</DialogTitle></DialogHeader>
            <div className="grid grid-cols-2 gap-3">
              <div className="col-span-2">
                <Label>Type</Label>
                <Select value={draft.address_type ?? 'shipping'} onValueChange={(v) => setDraft({ ...draft, address_type: v as AddressType })}>
                  <SelectTrigger><SelectValue /></SelectTrigger>
                  <SelectContent>
                    <SelectItem value="billing">Billing</SelectItem>
                    <SelectItem value="shipping">Shipping</SelectItem>
                    <SelectItem value="private">Private</SelectItem>
                    <SelectItem value="other">Other</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <div className="col-span-2"><Label>Label</Label><Input value={draft.label ?? ''} onChange={(e) => setDraft({ ...draft, label: e.target.value })} placeholder="HQ, Warehouse, Home…" /></div>
              <div className="col-span-2"><Label>Street</Label><Input value={draft.street ?? ''} onChange={(e) => setDraft({ ...draft, street: e.target.value })} /></div>
              <div><Label>Postal</Label><Input value={draft.postal_code ?? ''} onChange={(e) => setDraft({ ...draft, postal_code: e.target.value })} /></div>
              <div><Label>City</Label><Input value={draft.city ?? ''} onChange={(e) => setDraft({ ...draft, city: e.target.value })} /></div>
              <div><Label>State</Label><Input value={draft.state ?? ''} onChange={(e) => setDraft({ ...draft, state: e.target.value })} /></div>
              <div><Label>Country</Label><Input value={draft.country ?? ''} onChange={(e) => setDraft({ ...draft, country: e.target.value })} /></div>
              <div className="col-span-2"><Label>Phone</Label><Input value={draft.phone ?? ''} onChange={(e) => setDraft({ ...draft, phone: e.target.value })} /></div>
            </div>
            <DialogFooter>
              <Button onClick={async () => { await create.mutateAsync(draft); setDraft({ address_type: 'shipping' }); setOpen(false); }}>Save</Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </div>

      {items.length === 0 && <p className="text-sm text-muted-foreground py-4 text-center">No addresses yet</p>}
      {items.map((a) => (
        <div key={a.id} className="flex items-start gap-3 border rounded-md p-3 group">
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 mb-1">
              <Badge variant={TYPE_VARIANTS[a.address_type]}>{a.address_type}</Badge>
              {a.is_primary && <Badge variant="outline" className="gap-1"><Star className="h-3 w-3" />Primary</Badge>}
              {a.label && <span className="text-sm font-medium">{a.label}</span>}
            </div>
            <p className="text-sm text-muted-foreground">
              {[a.street, a.street2, [a.postal_code, a.city].filter(Boolean).join(' '), a.state, a.country].filter(Boolean).join(', ') || '—'}
            </p>
            {a.phone && <p className="text-xs text-muted-foreground mt-1">{a.phone}</p>}
          </div>
          <div className="opacity-0 group-hover:opacity-100 flex gap-1">
            {!a.is_primary && (
              <Button size="sm" variant="ghost" onClick={() => setPrimary.mutate(a.id)}><Star className="h-3 w-3" /></Button>
            )}
            <Button size="sm" variant="ghost" onClick={() => del.mutate(a.id)}><Trash2 className="h-3 w-3" /></Button>
          </div>
        </div>
      ))}
    </Card>
  );
}
