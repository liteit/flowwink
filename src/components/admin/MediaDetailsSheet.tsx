// Detail sheet for a media asset — alt text editor, variants, where-used list.
import { useEffect, useState } from 'react';
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from '@/components/ui/sheet';
import { Button } from '@/components/ui/button';
import { Textarea } from '@/components/ui/textarea';
import { Badge } from '@/components/ui/badge';
import { Loader2, Sparkles, ExternalLink } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import {
  MediaAsset,
  useMediaUsage,
  useOptimizeMedia,
  useSetMediaAltText,
} from '@/hooks/useMediaParity';

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  storagePath: string | null;
  filename: string | null;
  publicUrl: string | null;
  asset: MediaAsset | null;
}

const SOURCE_LABEL: Record<string, string> = {
  page: 'Page',
  blog_post: 'Blog post',
  kb_article: 'KB article',
  product: 'Product',
};

export function MediaDetailsSheet({
  open,
  onOpenChange,
  storagePath,
  filename,
  publicUrl,
  asset,
}: Props) {
  const [altText, setAltText] = useState('');
  const { toast } = useToast();

  useEffect(() => {
    setAltText(asset?.alt_text ?? '');
  }, [asset?.alt_text, storagePath]);

  const usage = useMediaUsage(open && filename ? filename : null);
  const setAlt = useSetMediaAltText();
  const optimize = useOptimizeMedia();

  const handleSaveAlt = async () => {
    if (!storagePath) return;
    try {
      await setAlt.mutateAsync({ storage_path: storagePath, alt_text: altText });
      toast({ title: 'Alt text saved' });
    } catch (e) {
      toast({
        title: 'Save failed',
        description: (e as Error).message,
        variant: 'destructive',
      });
    }
  };

  const handleOptimize = async () => {
    if (!storagePath) return;
    try {
      const res = await optimize.mutateAsync({ storage_path: storagePath });
      toast({
        title: 'Variants generated',
        description: `${res.variants.length} size${res.variants.length === 1 ? '' : 's'} created`,
      });
    } catch (e) {
      toast({
        title: 'Optimization failed',
        description: (e as Error).message,
        variant: 'destructive',
      });
    }
  };

  const usageCount = usage.data?.length ?? 0;
  const variants = asset?.variants ?? [];

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-full sm:max-w-lg overflow-y-auto">
        <SheetHeader>
          <SheetTitle className="truncate">{filename ?? 'Media asset'}</SheetTitle>
          <SheetDescription className="truncate">{storagePath}</SheetDescription>
        </SheetHeader>

        {publicUrl && (
          <div className="mt-4 rounded-lg overflow-hidden border bg-muted">
            <img src={publicUrl} alt={altText || filename || ''} className="w-full object-contain max-h-64" />
          </div>
        )}

        <div className="mt-4 grid grid-cols-2 gap-3 text-sm">
          <Stat label="Dimensions" value={asset?.width && asset?.height ? `${asset.width} × ${asset.height}` : '—'} />
          <Stat label="Size" value={asset?.size_bytes ? formatBytes(asset.size_bytes) : '—'} />
          <Stat label="Type" value={asset?.mime_type ?? '—'} />
          <Stat label="Folder" value={asset?.folder ?? '—'} />
        </div>

        {/* Alt text */}
        <section className="mt-6 space-y-2">
          <label className="text-sm font-medium">Alt text</label>
          <Textarea
            value={altText}
            onChange={(e) => setAltText(e.target.value)}
            rows={3}
            placeholder="Describe the image for screen readers and SEO"
          />
          <div className="flex justify-end">
            <Button size="sm" onClick={handleSaveAlt} disabled={setAlt.isPending || !storagePath}>
              {setAlt.isPending && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
              Save alt text
            </Button>
          </div>
        </section>

        {/* Variants */}
        <section className="mt-6 space-y-2">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-medium">Optimized variants</h3>
            <Button
              size="sm"
              variant="outline"
              onClick={handleOptimize}
              disabled={optimize.isPending || !storagePath}
            >
              {optimize.isPending ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <Sparkles className="h-4 w-4 mr-2" />
              )}
              Generate
            </Button>
          </div>
          {variants.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              No variants yet. Generate thumbnail + web sizes to speed up page loads.
            </p>
          ) : (
            <ul className="space-y-2">
              {variants.map((v) => (
                <li key={v.storage_path} className="flex items-center justify-between text-sm border rounded-md p-2">
                  <div className="flex items-center gap-2">
                    <Badge variant="secondary" className="uppercase text-xs">{v.label}</Badge>
                    <span>{v.width}×{v.height}</span>
                    <span className="text-muted-foreground">· {formatBytes(v.size_bytes)}</span>
                  </div>
                  <a
                    href={v.url}
                    target="_blank"
                    rel="noreferrer"
                    className="text-primary hover:underline flex items-center gap-1"
                  >
                    Open <ExternalLink className="h-3 w-3" />
                  </a>
                </li>
              ))}
            </ul>
          )}
        </section>

        {/* Where used */}
        <section className="mt-6 space-y-2">
          <div className="flex items-center gap-2">
            <h3 className="text-sm font-medium">Used in</h3>
            <Badge variant={usageCount > 0 ? 'default' : 'outline'}>{usageCount}</Badge>
          </div>
          {usage.isLoading ? (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <Loader2 className="h-4 w-4 animate-spin" /> Scanning content…
            </div>
          ) : usageCount === 0 ? (
            <p className="text-sm text-muted-foreground">
              Not referenced by any page, blog post, KB article, or product. Safe to delete.
            </p>
          ) : (
            <ul className="space-y-1 text-sm">
              {usage.data!.map((u) => (
                <li key={`${u.source_type}-${u.source_id}`} className="flex items-center justify-between border rounded-md p-2">
                  <div className="min-w-0">
                    <Badge variant="outline" className="mr-2 text-xs">{SOURCE_LABEL[u.source_type] ?? u.source_type}</Badge>
                    <span className="truncate">{u.title ?? u.source_id}</span>
                  </div>
                  {u.slug && (
                    <span className="text-xs text-muted-foreground truncate ml-2">/{u.slug}</span>
                  )}
                </li>
              ))}
            </ul>
          )}
        </section>
      </SheetContent>
    </Sheet>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-md border p-2">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="text-sm font-medium truncate">{value}</p>
    </div>
  );
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
