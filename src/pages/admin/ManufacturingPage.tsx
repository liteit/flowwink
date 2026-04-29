import { useMemo, useState } from 'react';
import { Plus, Pencil, CheckCircle2 } from 'lucide-react';
import { AdminLayout } from '@/components/admin/AdminLayout';
import { AdminPageHeader } from '@/components/admin/AdminPageHeader';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Skeleton } from '@/components/ui/skeleton';
import { BomEditorDialog } from '@/components/admin/manufacturing/BomEditorDialog';
import { useProducts } from '@/hooks/useProducts';
import {
  useManufacturingOrders,
  useBoms,
  useActivateBom,
  useConfirmMo,
  useStartMo,
  useCompleteMo,
  useCancelMo,
  useCheckAvailability,
  useTriggerProcurement,
  type MoStatus,
  type BomHeader,
} from '@/hooks/useManufacturing';

const STATUS_VARIANT: Record<MoStatus, 'secondary' | 'outline' | 'default'> = {
  draft: 'outline',
  planned: 'outline',
  confirmed: 'secondary',
  in_progress: 'default',
  done: 'secondary',
  cancelled: 'outline',
};

function MoActions({ mo }: { mo: Record<string, unknown> }) {
  const id = String(mo.id);
  const status = mo.status as MoStatus;
  const confirm = useConfirmMo();
  const start = useStartMo();
  const complete = useCompleteMo();
  const cancel = useCancelMo();
  const check = useCheckAvailability();
  const procure = useTriggerProcurement();

  return (
    <div className="flex flex-wrap gap-2">
      {status === 'draft' && (
        <Button size="sm" onClick={() => confirm.mutate({ p_mo_id: id })}>Confirm</Button>
      )}
      {status === 'confirmed' && (
        <>
          <Button size="sm" onClick={() => start.mutate({ p_mo_id: id })}>Start</Button>
          <Button size="sm" variant="outline" onClick={() => check.mutate({ p_mo_id: id })}>Re-check</Button>
          <Button size="sm" variant="outline" onClick={() => procure.mutate({ p_mo_id: id })}>Procure</Button>
        </>
      )}
      {status === 'in_progress' && (
        <Button size="sm" onClick={() => complete.mutate({ p_mo_id: id })}>Complete</Button>
      )}
      {!['done', 'cancelled'].includes(status) && (
        <Button
          size="sm"
          variant="ghost"
          onClick={() => cancel.mutate({ p_mo_id: id, p_reason: 'cancelled by user' })}
        >
          Cancel
        </Button>
      )}
    </div>
  );
}

function MoList() {
  const { data, isLoading } = useManufacturingOrders();
  if (isLoading) return <Skeleton className="h-64 w-full" />;
  if (!data || data.length === 0) {
    return (
      <Card>
        <CardContent className="py-12 text-center text-sm text-muted-foreground">
          No manufacturing orders yet. Create one via the <code>create_manufacturing_order</code> skill.
        </CardContent>
      </Card>
    );
  }
  return (
    <div className="space-y-3">
      {data.map((mo) => (
        <Card key={String(mo.id)}>
          <CardContent className="flex flex-col gap-3 py-4 md:flex-row md:items-center md:justify-between">
            <div className="space-y-1">
              <div className="flex items-center gap-2">
                <span className="font-mono text-sm font-medium">{String(mo.mo_number)}</span>
                <Badge variant={STATUS_VARIANT[mo.status as MoStatus] ?? 'outline'}>
                  {String(mo.status)}
                </Badge>
              </div>
              <div className="text-xs text-muted-foreground">
                Qty {String(mo.quantity)} · due {mo.due_date ? String(mo.due_date) : '—'} · source {String(mo.source_type)}
              </div>
            </div>
            <MoActions mo={mo} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

function BomList() {
  const { data, isLoading } = useBoms();
  const { data: products = [] } = useProducts();
  const activate = useActivateBom();

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<BomHeader | undefined>();

  const productById = useMemo(() => {
    const map = new Map<string, string>();
    for (const p of products) map.set(p.id, p.name);
    return map;
  }, [products]);

  function openCreate() {
    setEditing(undefined);
    setDialogOpen(true);
  }

  function openEdit(bom: BomHeader) {
    setEditing(bom);
    setDialogOpen(true);
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <p className="text-sm text-muted-foreground">
          Versioned recipes that drive Manufacturing Orders.
        </p>
        <Button size="sm" onClick={openCreate}>
          <Plus className="mr-1 h-4 w-4" /> New BOM
        </Button>
      </div>

      {isLoading ? (
        <Skeleton className="h-64 w-full" />
      ) : !data || data.length === 0 ? (
        <Card>
          <CardContent className="py-12 text-center text-sm text-muted-foreground">
            No Bills of Materials yet. Click <strong>New BOM</strong> to define your first recipe.
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-3 md:grid-cols-2">
          {data.map((bom) => (
            <Card key={bom.id}>
              <CardHeader className="pb-2">
                <CardTitle className="flex items-start justify-between gap-2 text-base">
                  <span className="space-x-2">
                    <span>{productById.get(bom.product_id) ?? 'Unknown product'}</span>
                    <span className="text-xs font-normal text-muted-foreground">
                      · {bom.version}
                    </span>
                  </span>
                  {bom.is_active && <Badge variant="default">active</Badge>}
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-3 text-xs text-muted-foreground">
                <div>
                  Produces <strong>{Number(bom.quantity_produced)}</strong> unit(s) per run.
                  {bom.routing_notes && <p className="mt-1 italic">{bom.routing_notes}</p>}
                </div>
                <div className="flex flex-wrap gap-2">
                  <Button size="sm" variant="outline" onClick={() => openEdit(bom)}>
                    <Pencil className="mr-1 h-3 w-3" /> Edit
                  </Button>
                  {!bom.is_active && (
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => activate.mutate({ bomId: bom.id, productId: bom.product_id })}
                      disabled={activate.isPending}
                    >
                      <CheckCircle2 className="mr-1 h-3 w-3" /> Activate
                    </Button>
                  )}
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      <BomEditorDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        bom={editing}
      />
    </div>
  );
}

export default function ManufacturingPage() {
  return (
    <AdminLayout>
      <div className="space-y-6">
        <AdminPageHeader
          title="Manufacturing"
          description="MRP-light: Bills of Materials, Manufacturing Orders, and the procurement loop."
        />
        <Tabs defaultValue="orders">
          <TabsList>
            <TabsTrigger value="orders">Manufacturing Orders</TabsTrigger>
            <TabsTrigger value="boms">Bills of Materials</TabsTrigger>
          </TabsList>
          <TabsContent value="orders" className="mt-4"><MoList /></TabsContent>
          <TabsContent value="boms" className="mt-4"><BomList /></TabsContent>
        </Tabs>
      </div>
    </AdminLayout>
  );
}
