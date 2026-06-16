import { useState } from 'react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Alert, AlertDescription } from '@/components/ui/alert';
import { Send, Loader2, CheckCircle2, XCircle, ExternalLink } from 'lucide-react';
import { supabase } from '@/integrations/supabase/client';
import { toast } from 'sonner';

type TestState = 'idle' | 'running' | 'ok' | 'error';

export function TelegramIntegrationCard() {
  const [botToken, setBotToken] = useState('');
  const [webhookUrl, setWebhookUrl] = useState('');
  const [test, setTest] = useState<TestState>('idle');
  const [error, setError] = useState<string | null>(null);

  const runTest = async () => {
    setTest('running');
    setError(null);
    try {
      // Talk to the manage_channel skill — it owns provider verification.
      const { data, error: invokeErr } = await supabase.functions.invoke('agent-execute', {
        body: {
          skill_name: 'manage_channel',
          arguments: {
            action: 'test',
            channel: 'telegram',
            bot_token: botToken || undefined,
            webhook_url: webhookUrl || undefined,
          },
        },
      });
      if (invokeErr) throw invokeErr;
      const ok = (data as any)?.success !== false;
      setTest(ok ? 'ok' : 'error');
      if (!ok) setError((data as any)?.error || 'Test failed');
      else toast.success('Telegram connection verified');
    } catch (e: any) {
      setTest('error');
      setError(e?.message ?? 'Unable to reach manage_channel skill');
    }
  };

  return (
    <Card>
      <CardHeader className="flex flex-row items-start justify-between gap-2">
        <div>
          <CardTitle className="text-base flex items-center gap-2">
            <Send className="h-4 w-4 text-sky-500" />
            Telegram
          </CardTitle>
          <CardDescription>
            Inbound messages, replies and callbacks via your Telegram bot.
          </CardDescription>
        </div>
        <Badge variant="outline" className="gap-1">
          {test === 'ok' && <CheckCircle2 className="h-3 w-3 text-green-500" />}
          {test === 'error' && <XCircle className="h-3 w-3 text-red-500" />}
          {test === 'idle' && 'Not tested'}
          {test === 'running' && 'Testing…'}
          {test === 'ok' && 'Connected'}
          {test === 'error' && 'Error'}
        </Badge>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="space-y-1.5">
          <Label htmlFor="telegram-bot-token" className="text-xs">Bot token</Label>
          <Input
            id="telegram-bot-token"
            type="password"
            placeholder="123456:ABC-DEF…"
            value={botToken}
            onChange={(e) => setBotToken(e.target.value)}
            autoComplete="off"
          />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="telegram-webhook-url" className="text-xs">Webhook URL</Label>
          <Input
            id="telegram-webhook-url"
            placeholder="https://your-site/functions/v1/telegram-webhook"
            value={webhookUrl}
            onChange={(e) => setWebhookUrl(e.target.value)}
          />
          <p className="text-[11px] text-muted-foreground">
            Telegram will POST updates to this URL. Configure in BotFather as well.
          </p>
        </div>

        {error && (
          <Alert variant="destructive">
            <AlertDescription className="text-xs">{error}</AlertDescription>
          </Alert>
        )}

        <div className="flex items-center justify-between pt-1">
          <a
            href="https://core.telegram.org/bots#how-do-i-create-a-bot"
            target="_blank" rel="noreferrer"
            className="text-xs text-muted-foreground hover:text-foreground inline-flex items-center gap-1"
          >
            BotFather docs <ExternalLink className="h-3 w-3" />
          </a>
          <Button size="sm" onClick={runTest} disabled={test === 'running'}>
            {test === 'running' ? <Loader2 className="h-3 w-3 animate-spin" /> : 'Test connection'}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}

export function TwilioIntegrationPlaceholder() {
  return (
    <Card className="opacity-70">
      <CardHeader>
        <CardTitle className="text-base">Twilio (SMS / Voice)</CardTitle>
        <CardDescription>
          Coming next — once Twilio is wired the same Test pattern will land here.
        </CardDescription>
      </CardHeader>
    </Card>
  );
}
