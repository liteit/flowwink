import { useEffect, useState } from 'react';
import { supabase } from '@/integrations/supabase/client';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Skeleton } from '@/components/ui/skeleton';
import { ChevronRight, Network, Trash2, Bot } from 'lucide-react';
import { toast } from 'sonner';
import { logger } from '@/lib/logger';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog';

interface PeerNode {
  id: string;
  name: string;
  status: string;
  invited_by_peer_id: string | null;
  toolset_groups: string[];
  created_at: string;
  depth: number;
  children: PeerNode[];
}

interface Invitation {
  id: string;
  inviter_peer_id: string | null;
  invitee_peer_id: string;
  invitee_name: string;
  toolset_groups: string[];
  reason: string | null;
  created_at: string;
}

export function InvitationTree() {
  const [tree, setTree] = useState<PeerNode[]>([]);
  const [invitations, setInvitations] = useState<Invitation[]>([]);
  const [loading, setLoading] = useState(true);

  const load = async () => {
    setLoading(true);
    try {
      const [{ data: nodes, error: e1 }, { data: invs, error: e2 }] = await Promise.all([
        supabase.from('peer_invitation_tree' as any).select('*').order('depth').order('created_at'),
        supabase.from('peer_invitations' as any).select('*').order('created_at', { ascending: false }).limit(50),
      ]);
      if (e1) throw e1;
      if (e2) throw e2;

      const map = new Map<string, PeerNode>();
      (nodes as any[] ?? []).forEach((n) => map.set(n.id, { ...n, children: [] }));
      const roots: PeerNode[] = [];
      map.forEach((node) => {
        if (node.invited_by_peer_id && map.has(node.invited_by_peer_id)) {
          map.get(node.invited_by_peer_id)!.children.push(node);
        } else {
          roots.push(node);
        }
      });
      setTree(roots);
      setInvitations((invs as any[]) ?? []);
    } catch (err) {
      logger.error('Failed to load invitation tree', err);
      toast.error('Failed to load federation tree');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    load();
  }, []);

  const revokePeer = async (peer: PeerNode) => {
    try {
      // Orphan children: clear their invited_by_peer_id so they survive
      const { error: orphanErr } = await supabase
        .from('a2a_peers')
        .update({ invited_by_peer_id: null } as any)
        .eq('invited_by_peer_id', peer.id);
      if (orphanErr) throw orphanErr;

      const { error: revokeErr } = await supabase
        .from('a2a_peers')
        .update({ status: 'revoked' } as any)
        .eq('id', peer.id);
      if (revokeErr) throw revokeErr;

      toast.success(`Revoked ${peer.name} — sub-peers orphaned (kept active)`);
      load();
    } catch (err: any) {
      logger.error('Revoke failed', err);
      toast.error(err.message ?? 'Revoke failed');
    }
  };

  const renderNode = (node: PeerNode, level = 0) => (
    <div key={node.id} className="space-y-2">
      <div
        className="flex items-center gap-3 rounded-md border border-border bg-card/40 px-3 py-2"
        style={{ marginLeft: level * 24 }}
      >
        {level > 0 && <ChevronRight className="h-3 w-3 text-muted-foreground" />}
        <Bot className="h-4 w-4 text-primary" />
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="font-medium text-sm truncate">{node.name}</span>
            <Badge variant={node.status === 'active' ? 'default' : 'secondary'} className="text-xs">
              {node.status}
            </Badge>
            {node.invited_by_peer_id === null && level === 0 && (
              <Badge variant="outline" className="text-xs">root</Badge>
            )}
          </div>
          {node.toolset_groups?.length > 0 && (
            <div className="flex gap-1 mt-1 flex-wrap">
              {node.toolset_groups.map((g) => (
                <Badge key={g} variant="outline" className="text-[10px] px-1 py-0">
                  {g}
                </Badge>
              ))}
            </div>
          )}
        </div>
        {node.status === 'active' && (
          <AlertDialog>
            <AlertDialogTrigger asChild>
              <Button variant="ghost" size="sm">
                <Trash2 className="h-3 w-3" />
              </Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>Revoke {node.name}?</AlertDialogTitle>
                <AlertDialogDescription>
                  This peer will be marked as revoked. Any sub-peers it invited
                  ({node.children.length}) will be <strong>orphaned</strong> — they remain active
                  but lose their inviter link.
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>Cancel</AlertDialogCancel>
                <AlertDialogAction onClick={() => revokePeer(node)}>
                  Revoke (orphan children)
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        )}
      </div>
      {node.children.map((child) => renderNode(child, level + 1))}
    </div>
  );

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-base">
            <Network className="h-4 w-4" />
            Federation Tree
          </CardTitle>
        </CardHeader>
        <CardContent>
          {loading ? (
            <div className="space-y-2">
              <Skeleton className="h-12" />
              <Skeleton className="h-12 ml-6" />
            </div>
          ) : tree.length === 0 ? (
            <p className="text-sm text-muted-foreground">No peers registered yet.</p>
          ) : (
            <div className="space-y-2">{tree.map((root) => renderNode(root))}</div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Invitation Audit Log</CardTitle>
        </CardHeader>
        <CardContent>
          {invitations.length === 0 ? (
            <p className="text-sm text-muted-foreground">No invitations recorded.</p>
          ) : (
            <div className="space-y-2">
              {invitations.map((inv) => (
                <div
                  key={inv.id}
                  className="flex items-start justify-between gap-3 rounded-md border border-border px-3 py-2 text-sm"
                >
                  <div className="flex-1 min-w-0">
                    <div className="font-medium">{inv.invitee_name}</div>
                    {inv.reason && (
                      <div className="text-xs text-muted-foreground mt-0.5">{inv.reason}</div>
                    )}
                    {inv.toolset_groups?.length > 0 && (
                      <div className="flex gap-1 mt-1 flex-wrap">
                        {inv.toolset_groups.map((g) => (
                          <Badge key={g} variant="outline" className="text-[10px] px-1 py-0">
                            {g}
                          </Badge>
                        ))}
                      </div>
                    )}
                  </div>
                  <span className="text-xs text-muted-foreground whitespace-nowrap">
                    {new Date(inv.created_at).toLocaleString()}
                  </span>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
