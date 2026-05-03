import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { AdminLayout } from '@/components/admin/AdminLayout';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Tag, Plus } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Link } from 'react-router-dom';

interface Pricelist {
  id: string;
  name: string;
  currency: string;
  valid_from: string | null;
  valid_until: string | null;
  is_default: boolean;
  is_active: boolean;
  priority: number;
  company_id: string | null;
  lead_id: string | null;
}

export default function PricelistsPage() {
  const { data, isLoading } = useQuery({
    queryKey: ['pricelists'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('pricelists' as any)
        .select('*')
        .order('priority', { ascending: true });
      if (error) throw error;
      return (data ?? []) as unknown as Pricelist[];
    },
  });

  return (
    <AdminLayout>
      <div className="container mx-auto p-6 space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-bold flex items-center gap-2">
              <Tag className="h-7 w-7" /> Pricelists
            </h1>
            <p className="text-muted-foreground mt-1">
              Versioned pricing per customer, company, or period.
            </p>
          </div>
          <Button disabled>
            <Plus className="h-4 w-4 mr-2" /> New pricelist
          </Button>
        </div>

        <Card>
          <CardHeader>
            <CardTitle>All pricelists</CardTitle>
            <CardDescription>
              Use FlowPilot or the MCP skill <code>manage_pricelist</code> to create and edit.
              Best price is auto-resolved per product+customer via <code>resolve_pricelist_price</code>.
            </CardDescription>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <p className="text-muted-foreground">Loading…</p>
            ) : (data?.length ?? 0) === 0 ? (
              <div className="text-center py-12">
                <p className="text-muted-foreground">No pricelists yet.</p>
                <p className="text-sm text-muted-foreground mt-2">
                  Ask FlowPilot: <em>"Create a 10% discount pricelist for Acme AB valid through Q3"</em>
                </p>
              </div>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Name</TableHead>
                    <TableHead>Currency</TableHead>
                    <TableHead>Valid</TableHead>
                    <TableHead>Scope</TableHead>
                    <TableHead>Priority</TableHead>
                    <TableHead>Status</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {data!.map((p) => (
                    <TableRow key={p.id}>
                      <TableCell className="font-medium">{p.name}</TableCell>
                      <TableCell>{p.currency}</TableCell>
                      <TableCell className="text-sm text-muted-foreground">
                        {p.valid_from ?? '—'} → {p.valid_until ?? '∞'}
                      </TableCell>
                      <TableCell>
                        {p.lead_id ? <Badge variant="outline">Lead</Badge> :
                         p.company_id ? <Badge variant="outline">Company</Badge> :
                         <Badge variant="secondary">Global</Badge>}
                      </TableCell>
                      <TableCell>{p.priority}</TableCell>
                      <TableCell>
                        {p.is_active ? <Badge>Active</Badge> : <Badge variant="outline">Inactive</Badge>}
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
