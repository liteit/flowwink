import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Link } from 'react-router-dom';
import { ExternalLink } from 'lucide-react';
import type { WorkspaceCitation } from '@/hooks/useWorkspaceChat';

interface Props {
  citations: WorkspaceCitation[];
}

const TYPE_LABEL: Record<string, string> = {
  document: 'Document',
  contract: 'Contract',
  employment_contract: 'Employment',
  kb_article: 'KB',
  page: 'Page',
  lead: 'Lead',
  deal: 'Deal',
  employee: 'Employee',
};

export function CitationsDrawer({ citations }: Props) {
  return (
    <Card className="border-border/60 h-full flex flex-col">
      <CardHeader className="pb-3">
        <CardTitle className="text-sm font-medium">
          Sources cited{' '}
          <span className="text-xs text-muted-foreground font-normal">
            ({citations.length})
          </span>
        </CardTitle>
      </CardHeader>
      <CardContent className="flex-1 min-h-0 p-0">
        <ScrollArea className="h-full">
          <div className="px-6 pb-4 space-y-2">
            {citations.length === 0 ? (
              <p className="text-xs text-muted-foreground py-4">
                No citations yet. Ask a question — sources used in the answer
                will appear here.
              </p>
            ) : (
              citations.map((c) => (
                <div
                  key={`${c.type}-${c.id}-${c.ref}`}
                  className="rounded-md border border-border/60 bg-card/50 p-3 hover:bg-accent/50 transition-colors"
                >
                  <div className="flex items-start gap-2">
                    <span className="text-xs font-mono text-primary mt-0.5">
                      [{c.ref}]
                    </span>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-1.5 mb-1">
                        <Badge variant="secondary" className="text-[10px] py-0 px-1.5 h-4">
                          {TYPE_LABEL[c.type] || c.type}
                        </Badge>
                      </div>
                      <p className="text-sm font-medium truncate" title={c.title}>
                        {c.title}
                      </p>
                      {c.url && (
                        <Link
                          to={c.url}
                          className="text-xs text-primary hover:underline inline-flex items-center gap-1 mt-1"
                        >
                          Open <ExternalLink className="h-3 w-3" />
                        </Link>
                      )}
                    </div>
                  </div>
                </div>
              ))
            )}
          </div>
        </ScrollArea>
      </CardContent>
    </Card>
  );
}
