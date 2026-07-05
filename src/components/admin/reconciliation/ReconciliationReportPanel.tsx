import { useState } from 'react';
import { format, startOfMonth, endOfMonth } from 'date-fns';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Button } from '@/components/ui/button';
import { useReconciliationReport } from '@/hooks/useReconciliationRules';

const fmtSEK = (cents: number) =>
  new Intl.NumberFormat('sv-SE', { style: 'currency', currency: 'SEK', maximumFractionDigits: 2 })
    .format((cents ?? 0) / 100);

export function ReconciliationReportPanel() {
  const today = new Date();
  const [from, setFrom] = useState(format(startOfMonth(today), 'yyyy-MM-dd'));
  const [to, setTo] = useState(format(endOfMonth(today), 'yyyy-MM-dd'));

  const { data, isLoading, refetch, isFetching } = useReconciliationReport(from, to);

  const matchedPct =
    data && data.total_count > 0 ? Math.round((data.matched_count / data.total_count) * 100) : 0;

  return (
    <Card className="mt-4">
      <CardHeader>
        <CardTitle>Reconciliation report</CardTitle>
        <p className="text-sm text-muted-foreground">
          Bank-feed health for a period — matched vs unmatched, plus how many unmatched have a rule
          suggestion waiting.
        </p>
      </CardHeader>
      <CardContent className="space-y-6">
        <div className="flex flex-wrap items-end gap-3">
          <div className="grid gap-2">
            <Label htmlFor="rep-from">From</Label>
            <Input
              id="rep-from"
              type="date"
              value={from}
              onChange={(e) => setFrom(e.target.value)}
              className="w-44"
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="rep-to">To</Label>
            <Input
              id="rep-to"
              type="date"
              value={to}
              onChange={(e) => setTo(e.target.value)}
              className="w-44"
            />
          </div>
          <Button variant="outline" onClick={() => refetch()} disabled={isFetching}>
            {isFetching ? 'Refreshing…' : 'Refresh'}
          </Button>
        </div>

        {isLoading || !data ? (
          <div className="text-muted-foreground text-sm">Loading…</div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-sm text-muted-foreground font-medium">Total</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-semibold">{data.total_count}</div>
                <div className="text-sm text-muted-foreground mt-1">{fmtSEK(data.total_cents)}</div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-sm text-muted-foreground font-medium">Matched</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-semibold text-emerald-600">{data.matched_count}</div>
                <div className="text-sm text-muted-foreground mt-1">
                  {fmtSEK(data.matched_cents)} · {matchedPct}%
                </div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-sm text-muted-foreground font-medium">Unmatched</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-semibold text-destructive">{data.unmatched_count}</div>
                <div className="text-sm text-muted-foreground mt-1">{fmtSEK(data.unmatched_cents)}</div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader className="pb-2">
                <CardTitle className="text-sm text-muted-foreground font-medium">
                  Rule-suggested
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-2xl font-semibold">{data.rule_suggested_count}</div>
                <div className="text-sm text-muted-foreground mt-1">
                  Unmatched with a pending suggestion
                </div>
              </CardContent>
            </Card>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
