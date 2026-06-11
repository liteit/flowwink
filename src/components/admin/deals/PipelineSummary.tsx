import { Card, CardContent } from '@/components/ui/card';
import { TrendingUp, Hash, Calculator, Calendar } from 'lucide-react';
import { formatPrice } from '@/hooks/useProducts';
import type { Deal } from '@/hooks/useDeals';
import { usePipelineStages } from '@/hooks/usePipelineStages';
import { differenceInDays, parseISO } from 'date-fns';

interface PipelineSummaryProps {
  deals: Deal[];
}

/**
 * Pipeline summary bar (Pipedrive-style).
 * Uses pipeline_stages.is_won/is_lost to decide which deals are "open" so the
 * forecast adapts to whatever pipeline an admin has configured.
 */
export function PipelineSummary({ deals }: PipelineSummaryProps) {
  const { data: stages = [] } = usePipelineStages('deal');
  const closedKeys = new Set(stages.filter(s => s.is_won || s.is_lost).map(s => s.key));

  const open = deals.filter(d => !closedKeys.has(d.stage as string));
  const totalValue = open.reduce((sum, d) => sum + (d.value_cents || 0), 0);
  const count = open.length;
  const avg = count > 0 ? Math.round(totalValue / count) : 0;

  const avgAgeDays = count > 0
    ? Math.round(
        open.reduce((sum, d) => {
          if (!d.created_at) return sum;
          return sum + differenceInDays(new Date(), parseISO(d.created_at));
        }, 0) / count
      )
    : 0;

  const items = [
    { icon: TrendingUp, label: 'Open value', value: formatPrice(totalValue) },
    { icon: Hash, label: 'Open deals', value: String(count) },
    { icon: Calculator, label: 'Avg deal', value: count > 0 ? formatPrice(avg) : '—' },
    { icon: Calendar, label: 'Avg age', value: count > 0 ? `${avgAgeDays}d` : '—' },
  ];

  return (
    <Card>
      <CardContent className="p-4">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {items.map(({ icon: Icon, label, value }) => (
            <div key={label} className="flex items-center gap-3">
              <div className="h-9 w-9 rounded-md bg-primary/10 text-primary flex items-center justify-center shrink-0">
                <Icon className="h-4 w-4" />
              </div>
              <div className="min-w-0">
                <p className="text-xs text-muted-foreground">{label}</p>
                <p className="text-base font-semibold truncate">{value}</p>
              </div>
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  );
}
