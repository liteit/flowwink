import { Check, Circle, XCircle } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { MoStatus } from '@/hooks/useManufacturing';

interface Stage {
  key: 'draft' | 'confirmed' | 'in_progress' | 'done';
  label: string;
}

const STAGES: Stage[] = [
  { key: 'draft', label: 'Draft' },
  { key: 'confirmed', label: 'Confirmed' },
  { key: 'in_progress', label: 'In progress' },
  { key: 'done', label: 'Done' },
];

const STATUS_ORDER: Record<MoStatus, number> = {
  draft: 0,
  planned: 0,
  confirmed: 1,
  in_progress: 2,
  done: 3,
  cancelled: -1,
};

interface Props {
  status: MoStatus;
  createdAt?: string | null;
  startedAt?: string | null;
  completedAt?: string | null;
  className?: string;
}

function fmt(ts?: string | null): string {
  if (!ts) return '';
  try {
    return new Date(ts).toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return '';
  }
}

export function MoTimeline({
  status,
  createdAt,
  startedAt,
  completedAt,
  className,
}: Props) {
  const currentIdx = STATUS_ORDER[status] ?? 0;
  const cancelled = status === 'cancelled';

  // Best-effort timestamps per stage. confirmed_at not stored — fall back to created_at
  // if we've moved past draft, since confirm is the first explicit transition after draft.
  const stampForStage = (key: Stage['key']): string => {
    if (key === 'draft') return fmt(createdAt);
    if (key === 'confirmed') return currentIdx >= 1 ? fmt(createdAt) : '';
    if (key === 'in_progress') return fmt(startedAt);
    if (key === 'done') return fmt(completedAt);
    return '';
  };

  if (cancelled) {
    return (
      <div
        className={cn(
          'flex items-center gap-2 rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-xs text-destructive',
          className,
        )}
      >
        <XCircle className="h-4 w-4" />
        <span>Cancelled {completedAt ? `· ${fmt(completedAt)}` : ''}</span>
      </div>
    );
  }

  return (
    <div className={cn('flex items-center gap-1', className)}>
      {STAGES.map((stage, idx) => {
        const reached = currentIdx >= idx;
        const isCurrent = currentIdx === idx;
        const stamp = stampForStage(stage.key);

        return (
          <div key={stage.key} className="flex flex-1 items-center gap-1">
            <div className="flex flex-col items-center gap-1 min-w-0">
              <div
                className={cn(
                  'flex h-7 w-7 items-center justify-center rounded-full border-2 transition-colors',
                  reached
                    ? 'border-primary bg-primary text-primary-foreground'
                    : 'border-border bg-background text-muted-foreground',
                  isCurrent && 'ring-2 ring-primary/30 ring-offset-2 ring-offset-background',
                )}
                aria-current={isCurrent ? 'step' : undefined}
              >
                {reached ? <Check className="h-3.5 w-3.5" /> : <Circle className="h-2.5 w-2.5" />}
              </div>
              <div className="text-center">
                <div
                  className={cn(
                    'text-[11px] font-medium leading-tight',
                    reached ? 'text-foreground' : 'text-muted-foreground',
                  )}
                >
                  {stage.label}
                </div>
                {stamp && (
                  <div className="text-[10px] leading-tight text-muted-foreground">{stamp}</div>
                )}
              </div>
            </div>
            {idx < STAGES.length - 1 && (
              <div
                className={cn(
                  'h-0.5 flex-1 rounded-full transition-colors',
                  currentIdx > idx ? 'bg-primary' : 'bg-border',
                )}
              />
            )}
          </div>
        );
      })}
    </div>
  );
}
