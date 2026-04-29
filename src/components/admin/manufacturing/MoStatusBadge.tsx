import { Badge } from '@/components/ui/badge';
import { Circle, CheckCircle2, Play, Hammer, XCircle, Clock } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { MoStatus } from '@/hooks/useManufacturing';

const META: Record<
  MoStatus,
  { label: string; icon: typeof Circle; className: string }
> = {
  draft: {
    label: 'Draft',
    icon: Circle,
    className: 'bg-muted text-muted-foreground border-border',
  },
  planned: {
    label: 'Planned',
    icon: Clock,
    className: 'bg-muted text-muted-foreground border-border',
  },
  confirmed: {
    label: 'Confirmed',
    icon: CheckCircle2,
    className: 'bg-blue-500/10 text-blue-700 dark:text-blue-300 border-blue-500/30',
  },
  in_progress: {
    label: 'In progress',
    icon: Play,
    className:
      'bg-amber-500/10 text-amber-700 dark:text-amber-300 border-amber-500/30 animate-pulse',
  },
  done: {
    label: 'Done',
    icon: Hammer,
    className: 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-300 border-emerald-500/30',
  },
  cancelled: {
    label: 'Cancelled',
    icon: XCircle,
    className: 'bg-destructive/10 text-destructive border-destructive/30',
  },
};

export function MoStatusBadge({
  status,
  className,
}: {
  status: MoStatus;
  className?: string;
}) {
  const meta = META[status] ?? META.draft;
  const Icon = meta.icon;
  return (
    <Badge
      variant="outline"
      className={cn('gap-1 font-medium', meta.className, className)}
    >
      <Icon className="h-3 w-3" />
      {meta.label}
    </Badge>
  );
}
