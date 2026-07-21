import { useMemo, useState } from "react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Route, Pencil, Loader2 } from "lucide-react";
import { useAccountRoles, useUpdateAccountRole, type AccountRole } from "@/hooks/useAccountRoles";
import { useChartOfAccounts } from "@/hooks/useAccounting";

interface Props {
  /** Active locale pack id — the roles listed and the chart searched all key off this. */
  localeId: string;
  /** Human label for the pack, shown in the explainer copy. */
  localeLabel: string;
}

/**
 * Viewer + editor for `account_roles` rows of the ACTIVE locale pack.
 *
 * Bookkeeping RPCs post to a role (e.g. `bank`, `vat_output`) — not a
 * hardcoded account code. This section shows the current role → account_code
 * mapping and lets an admin remap a role to a different account without SQL.
 * Adding/removing roles is intentionally not allowed here: the role vocabulary
 * is platform-defined; only the mapping is tenant-editable.
 */
export function AccountRolesEditor({ localeId, localeLabel }: Props) {
  const { data: roles, isLoading } = useAccountRoles(localeId);
  const { data: accounts } = useChartOfAccounts(localeId);
  const update = useUpdateAccountRole();

  const [editing, setEditing] = useState<AccountRole | null>(null);

  const accountByCode = useMemo(() => {
    const map = new Map<string, string>();
    (accounts ?? []).forEach((a) => map.set(a.account_code, a.account_name));
    return map;
  }, [accounts]);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <Route className="h-4 w-4" /> Account roles
        </CardTitle>
        <CardDescription>
          Bookkeeping functions post to <span className="font-medium">roles</span>, not
          hardcoded accounts. The active pack ({localeLabel}) maps each role to an account
          in your chart. Remap a role here if your business uses a different account — e.g.
          bank on 1931 instead of 1930.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {isLoading ? (
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" /> Loading roles…
          </div>
        ) : !roles || roles.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No roles defined for this pack yet.
          </p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Role</TableHead>
                <TableHead>Account</TableHead>
                <TableHead>Description</TableHead>
                <TableHead className="w-16" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {roles.map((r) => {
                const accountName = accountByCode.get(r.account_code);
                return (
                  <TableRow key={r.id}>
                    <TableCell className="font-mono text-xs">
                      <Badge variant="secondary" className="font-mono">
                        {r.role}
                      </Badge>
                    </TableCell>
                    <TableCell>
                      <div className="flex items-baseline gap-2">
                        <span className="font-mono text-sm">{r.account_code}</span>
                        <span className="text-xs text-muted-foreground truncate max-w-[240px]">
                          {accountName ?? (
                            <span className="text-destructive">
                              not in chart of accounts
                            </span>
                          )}
                        </span>
                      </div>
                    </TableCell>
                    <TableCell className="text-sm text-muted-foreground">
                      {r.description ?? "—"}
                    </TableCell>
                    <TableCell className="text-right">
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => setEditing(r)}
                      >
                        <Pencil className="h-3.5 w-3.5" />
                      </Button>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
      </CardContent>

      <RemapDialog
        role={editing}
        onClose={() => setEditing(null)}
        accounts={accounts ?? []}
        onSubmit={(code) => {
          if (!editing) return;
          update.mutate(
            { id: editing.id, account_code: code },
            { onSuccess: () => setEditing(null) },
          );
        }}
        isSaving={update.isPending}
      />
    </Card>
  );
}

interface RemapProps {
  role: AccountRole | null;
  accounts: Array<{ account_code: string; account_name: string; account_type?: string }>;
  onClose: () => void;
  onSubmit: (accountCode: string) => void;
  isSaving: boolean;
}

function RemapDialog({ role, accounts, onClose, onSubmit, isSaving }: RemapProps) {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<string>("");

  // Reset when opening for a different role.
  const open = role !== null;
  const currentCode = role?.account_code ?? "";
  const effectiveSelected = selected || currentCode;

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return accounts.slice(0, 200);
    return accounts
      .filter(
        (a) =>
          a.account_code.toLowerCase().includes(q) ||
          a.account_name.toLowerCase().includes(q),
      )
      .slice(0, 200);
  }, [accounts, query]);

  const chosen = accounts.find((a) => a.account_code === effectiveSelected) ?? null;
  const isValid = !!chosen && chosen.account_code !== currentCode;

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        if (!o) {
          onClose();
          setQuery("");
          setSelected("");
        }
      }}
    >
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Remap role</DialogTitle>
          <DialogDescription>
            Choose the account that role <span className="font-mono">{role?.role}</span>{" "}
            should post to. Only existing accounts in the chart are valid.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <div className="text-sm">
            <span className="text-muted-foreground">Currently: </span>
            <span className="font-mono">{currentCode}</span>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="chart-search">Search chart of accounts</Label>
            <Input
              id="chart-search"
              placeholder="Search by code or name…"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </div>

          <ScrollArea className="h-64 rounded-md border">
            <div className="divide-y">
              {filtered.length === 0 ? (
                <div className="p-4 text-sm text-muted-foreground">
                  No accounts match.
                </div>
              ) : (
                filtered.map((a) => {
                  const isSelected = a.account_code === effectiveSelected;
                  return (
                    <button
                      key={a.account_code}
                      type="button"
                      onClick={() => setSelected(a.account_code)}
                      className={`w-full text-left px-3 py-2 hover:bg-muted/60 transition-colors ${
                        isSelected ? "bg-primary/5" : ""
                      }`}
                    >
                      <div className="flex items-baseline gap-3">
                        <span className="font-mono text-sm w-16 shrink-0">
                          {a.account_code}
                        </span>
                        <span className="text-sm truncate">{a.account_name}</span>
                      </div>
                    </button>
                  );
                })
              )}
            </div>
          </ScrollArea>
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={onClose} disabled={isSaving}>
            Cancel
          </Button>
          <Button
            onClick={() => chosen && onSubmit(chosen.account_code)}
            disabled={!isValid || isSaving}
          >
            {isSaving ? (
              <>
                <Loader2 className="h-4 w-4 mr-2 animate-spin" /> Saving…
              </>
            ) : (
              "Save mapping"
            )}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
