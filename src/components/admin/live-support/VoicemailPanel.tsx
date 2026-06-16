import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Voicemail, Loader2, Sparkles, Play, Pause } from 'lucide-react';
import { formatDistanceToNow } from 'date-fns';
import { toast } from 'sonner';

interface VoicemailRow {
  id: string;
  from_number: string | null;
  from_name: string | null;
  duration_seconds: number | null;
  audio_url: string | null;
  transcript: string | null;
  summary: string | null;
  status: string | null;
  created_at: string;
}

export function VoicemailPanel() {
  const qc = useQueryClient();
  const [playingId, setPlayingId] = useState<string | null>(null);

  const { data, isLoading, error } = useQuery({
    queryKey: ['voicemail-messages'],
    queryFn: async () => {
      // voicemail_messages is part of the omnichannel contract owned by
      // Claude Code. Read defensively so the UI keeps rendering on instances
      // where the table hasn't been migrated yet.
      const { data, error } = await (supabase as any)
        .from('voicemail_messages')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(50);
      if (error) {
        if ((error as any).code === '42P01' || /relation .* does not exist/i.test(error.message)) {
          return null; // table not provisioned yet
        }
        throw error;
      }
      return (data ?? []) as VoicemailRow[];
    },
    retry: false,
  });

  const summarize = useMutation({
    mutationFn: async (voicemail_id: string) => {
      const { data, error } = await supabase.functions.invoke('agent-execute', {
        body: {
          skill_name: 'handle_voicemail',
          arguments: { action: 'summarize', voicemail_id },
        },
      });
      if (error) throw error;
      return data;
    },
    onSuccess: () => {
      toast.success('FlowPilot summarized the voicemail');
      qc.invalidateQueries({ queryKey: ['voicemail-messages'] });
    },
    onError: (e: any) => toast.error(e?.message ?? 'Summarization failed'),
  });

  if (isLoading) {
    return (
      <Card>
        <CardContent className="flex items-center justify-center py-12">
          <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
        </CardContent>
      </Card>
    );
  }

  if (data === null || error) {
    return (
      <Card>
        <CardHeader>
          <CardTitle className="text-base flex items-center gap-2">
            <Voicemail className="h-4 w-4 text-amber-500" />
            Voicemail
          </CardTitle>
          <CardDescription>
            Voicemail storage isn't provisioned on this instance yet. Once the
            backend lands voicemail_messages, recordings, transcripts and
            FlowPilot summaries will appear here.
          </CardDescription>
        </CardHeader>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base flex items-center gap-2">
          <Voicemail className="h-4 w-4 text-amber-500" />
          Voicemail
          <Badge variant="outline">{data.length}</Badge>
        </CardTitle>
        <CardDescription>
          Inbound voicemails with transcript and a FlowPilot summary.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {data.length === 0 ? (
          <p className="text-sm text-muted-foreground text-center py-6">
            No voicemails.
          </p>
        ) : (
          <ul className="space-y-3">
            {data.map(vm => (
              <li key={vm.id} className="rounded-lg border p-3 space-y-2">
                <div className="flex items-center justify-between gap-2">
                  <div className="min-w-0">
                    <p className="text-sm font-medium truncate">
                      {vm.from_name || vm.from_number || 'Unknown caller'}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {formatDistanceToNow(new Date(vm.created_at), { addSuffix: true })}
                      {vm.duration_seconds ? ` · ${vm.duration_seconds}s` : ''}
                    </p>
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    <Badge variant="outline">{vm.status ?? 'new'}</Badge>
                    {vm.audio_url && (
                      <Button
                        size="sm" variant="ghost"
                        onClick={() => setPlayingId(playingId === vm.id ? null : vm.id)}
                      >
                        {playingId === vm.id ? <Pause className="h-4 w-4" /> : <Play className="h-4 w-4" />}
                      </Button>
                    )}
                  </div>
                </div>

                {playingId === vm.id && vm.audio_url && (
                  <audio src={vm.audio_url} controls autoPlay className="w-full h-8" />
                )}

                {vm.summary ? (
                  <div className="rounded-md bg-primary/5 border border-primary/10 p-2 text-xs">
                    <p className="font-medium text-primary mb-1 flex items-center gap-1">
                      <Sparkles className="h-3 w-3" /> FlowPilot summary
                    </p>
                    <p>{vm.summary}</p>
                  </div>
                ) : (
                  <Button
                    size="sm" variant="outline"
                    onClick={() => summarize.mutate(vm.id)}
                    disabled={summarize.isPending}
                    className="gap-1"
                  >
                    <Sparkles className="h-3 w-3" /> Ask FlowPilot to summarize
                  </Button>
                )}

                {vm.transcript && (
                  <details className="text-xs">
                    <summary className="cursor-pointer text-muted-foreground">Transcript</summary>
                    <p className="mt-1 whitespace-pre-wrap">{vm.transcript}</p>
                  </details>
                )}
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
