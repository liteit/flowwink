import { Play } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Skeleton } from '@/components/ui/skeleton';
import {
  useMoWorkOrders,
  useGenerateMoWorkOrders,
  useWorkCenters,
} from '@/hooks/useManufacturing';
import { logger } from '@/lib/logger';

function fmtMoney(cents: number) {
  return `${(cents / 100).toFixed(2)}`;
}

export function MoWorkOrdersPanel({ moId }: { moId: string }) {
  const { data: workOrders, isLoading } = useMoWorkOrders(moId);
  const { data: workCenters } = useWorkCenters();
  const generate = useGenerateMoWorkOrders();

  const wcName = (id: string | null) =>
    id ? workCenters?.find((w) => w.id === id)?.name ?? '—' : '—';

  async function handleGenerate() {
    try {
      await generate.mutateAsync({ p_mo_id: moId });
    } catch (err) {
      logger.error('Generate work orders failed', err);
    }
  }

  const totalPlanned = (workOrders ?? []).reduce((s, w) => s + (w.planned_minutes ?? 0), 0);
  const totalLabor = (workOrders ?? []).reduce((s, w) => s + (w.planned_labor_cost_cents ?? 0), 0);

  return (
    <div className="space-y-2 rounded-md border bg-muted/20 p-3">
      <div className="flex items-center justify-between">
        <h4 className="text-sm font-semibold">Work orders</h4>
        <Button size="sm" variant="outline" onClick={handleGenerate} disabled={generate.isPending}>
          <Play className="mr-1 h-3 w-3" />
          {generate.isPending ? 'Generating…' : 'Generate work orders'}
        </Button>
      </div>

      {isLoading ? (
        <Skeleton className="h-16 w-full" />
      ) : !workOrders || workOrders.length === 0 ? (
        <p className="text-xs text-muted-foreground">
          No work orders yet. Generate them from the active BOM's routing.
        </p>
      ) : (
        <>
          <div className="overflow-hidden rounded border bg-background">
            <table className="w-full text-xs">
              <thead className="bg-muted/40 text-muted-foreground">
                <tr>
                  <th className="px-2 py-1.5 text-left font-medium w-8">#</th>
                  <th className="px-2 py-1.5 text-left font-medium">Operation</th>
                  <th className="px-2 py-1.5 text-left font-medium">Work center</th>
                  <th className="px-2 py-1.5 text-right font-medium">Planned min</th>
                  <th className="px-2 py-1.5 text-right font-medium">Planned labor</th>
                  <th className="px-2 py-1.5 text-left font-medium">Status</th>
                </tr>
              </thead>
              <tbody>
                {workOrders.map((w) => (
                  <tr key={w.id} className="border-t">
                    <td className="px-2 py-1.5 tabular-nums text-muted-foreground">{w.sequence}</td>
                    <td className="px-2 py-1.5">{w.name}</td>
                    <td className="px-2 py-1.5 text-muted-foreground">{wcName(w.work_center_id)}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">{w.planned_minutes}</td>
                    <td className="px-2 py-1.5 text-right tabular-nums">
                      {fmtMoney(w.planned_labor_cost_cents)}
                    </td>
                    <td className="px-2 py-1.5">
                      <Badge variant="outline" className="text-[10px]">{w.status}</Badge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="text-xs text-muted-foreground">
            Total: <span className="font-medium text-foreground">{totalPlanned} min</span> ·{' '}
            <span className="font-medium text-foreground">{fmtMoney(totalLabor)}</span> planned labor
          </p>
        </>
      )}
    </div>
  );
}
