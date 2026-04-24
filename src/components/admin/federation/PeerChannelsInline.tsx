import { useState } from 'react';
import { Button } from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
  DialogTrigger,
} from '@/components/ui/dialog';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { Label } from '@/components/ui/label';
import { Input } from '@/components/ui/input';
import { Plus, Trash2, Clock, KeyRound } from 'lucide-react';
import { formatDistanceToNow } from 'date-fns';
import {
  useFederationConnections,
  useDeleteFederationConnection,
  useCreateFederationConnection,
  type ConnectionDirection,
  type ConnectionTransport,
} from '@/hooks/useFederationConnections';
import { useApiKeys } from '@/hooks/useApiKeys';
import { ConnectionBadge } from './ConnectionBadges';

/** Inline list of all channels for a peer + add/remove controls. */
export function PeerChannelsInline({ peerId, peerName }: { peerId: string; peerName: string }) {
  const { data: connections } = useFederationConnections(peerId);
  const { data: apiKeys } = useApiKeys();
  const deleteConn = useDeleteFederationConnection();
  const createConn = useCreateFederationConnection();

  const [open, setOpen] = useState(false);
  const [direction, setDirection] = useState<ConnectionDirection>('inbound');
  const [transport, setTransport] = useState<ConnectionTransport>('mcp');
  const [apiKeyId, setApiKeyId] = useState('');
  const [url, setUrl] = useState('');
  const [token, setToken] = useState('');

  const reset = () => {
    setDirection('inbound');
    setTransport('mcp');
    setApiKeyId('');
    setUrl('');
    setToken('');
  };

  const handleAdd = async () => {
    await createConn.mutateAsync({
      peer_id: peerId,
      direction,
      transport,
      endpoint_url: direction !== 'inbound' ? url || null : null,
      outbound_token: direction !== 'inbound' ? token || null : null,
      api_key_id: direction === 'inbound' ? apiKeyId || null : null,
    });
    setOpen(false);
    reset();
  };

  return (
    <div className="rounded-md border border-border/50 bg-muted/20 p-2.5 space-y-1.5">
      <div className="flex items-center justify-between">
        <span className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider">
          Channels {connections?.length ? `(${connections.length})` : ''}
        </span>
        <Dialog open={open} onOpenChange={(o) => { setOpen(o); if (!o) reset(); }}>
          <DialogTrigger asChild>
            <Button variant="ghost" size="sm" className="h-6 text-[11px] gap-1">
              <Plus className="h-3 w-3" />
              Add Channel
            </Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Add channel to {peerName}</DialogTitle>
              <DialogDescription>
                Wire a directional channel. <strong>↔</strong> two-way A2A · <strong>→</strong> we call them · <strong>←</strong> they call us.
              </DialogDescription>
            </DialogHeader>
            <div className="space-y-4">
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label>Direction</Label>
                  <Select value={direction} onValueChange={(v: ConnectionDirection) => setDirection(v)}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="bidirectional">↔ Bidirectional</SelectItem>
                      <SelectItem value="outbound">→ Outbound</SelectItem>
                      <SelectItem value="inbound">← Inbound</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1.5">
                  <Label>Transport</Label>
                  <Select value={transport} onValueChange={(v: ConnectionTransport) => setTransport(v)}>
                    <SelectTrigger><SelectValue /></SelectTrigger>
                    <SelectContent>
                      <SelectItem value="a2a">A2A (JSON-RPC)</SelectItem>
                      <SelectItem value="openresponses">/v1/responses</SelectItem>
                      <SelectItem value="mcp">MCP</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              </div>

              {direction === 'inbound' ? (
                <div className="space-y-1.5">
                  <Label>API Key (theirs to call us)</Label>
                  <Select value={apiKeyId} onValueChange={setApiKeyId}>
                    <SelectTrigger><SelectValue placeholder="Select API key" /></SelectTrigger>
                    <SelectContent>
                      {apiKeys?.map(k => (
                        <SelectItem key={k.id} value={k.id}>
                          {k.name} ({k.key_prefix}…)
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              ) : (
                <>
                  <div className="space-y-1.5">
                    <Label>Endpoint URL</Label>
                    <Input value={url} onChange={e => setUrl(e.target.value)} placeholder="https://peer.example.com" />
                  </div>
                  <div className="space-y-1.5">
                    <Label>Outbound Token</Label>
                    <Input value={token} onChange={e => setToken(e.target.value)} placeholder="bearer token" type="password" />
                  </div>
                </>
              )}
            </div>
            <DialogFooter>
              <Button variant="outline" onClick={() => setOpen(false)}>Cancel</Button>
              <Button onClick={handleAdd} disabled={createConn.isPending}>
                {createConn.isPending ? 'Adding…' : 'Add Channel'}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </div>

      {!connections?.length ? (
        <p className="text-[11px] text-muted-foreground/70 italic">No channels yet</p>
      ) : (
        <div className="space-y-1">
          {connections.map(c => (
            <div key={c.id} className="flex items-center justify-between gap-2 text-xs">
              <div className="flex items-center gap-2 min-w-0 flex-1">
                <ConnectionBadge direction={c.direction} transport={c.transport} />
                <div className="flex items-center gap-2 min-w-0 text-muted-foreground">
                  {c.endpoint_url && (
                    <code className="bg-muted px-1.5 py-0.5 rounded text-[10px] truncate max-w-[260px]">
                      {c.endpoint_url}
                    </code>
                  )}
                  {c.api_key && (
                    <span className="flex items-center gap-1 text-[10px]">
                      <KeyRound className="h-2.5 w-2.5" />
                      <code className="bg-muted px-1 rounded">{c.api_key.key_prefix}…</code>
                    </span>
                  )}
                  {c.last_activity_at && (
                    <span className="flex items-center gap-1 text-[10px]">
                      <Clock className="h-2.5 w-2.5" />
                      {formatDistanceToNow(new Date(c.last_activity_at), { addSuffix: true })}
                    </span>
                  )}
                </div>
              </div>
              <Button
                variant="ghost"
                size="icon"
                className="h-6 w-6 text-destructive/60 hover:text-destructive shrink-0"
                onClick={() => deleteConn.mutate(c.id)}
                title="Remove channel"
              >
                <Trash2 className="h-3 w-3" />
              </Button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
