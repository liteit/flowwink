import { useState } from "react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";
import { Plus, ExternalLink } from "lucide-react";
import { toast } from "sonner";
import { usePagesRpcQuery, usePagesRpcMutation } from "@/hooks/usePagesRpc";

type Translation = { slug: string; locale: string; status: string; title: string };

const COMMON_LOCALES = ["en", "sv", "de", "fr", "es", "no", "da", "fi"];

export function PageTranslationsDialog({
  slug,
  open,
  onOpenChange,
}: {
  slug: string;
  open: boolean;
  onOpenChange: (v: boolean) => void;
}) {
  const listQ = usePagesRpcQuery<{ translations: Translation[] }>(
    "manage_page_translation",
    { p_action: "list", p_slug: slug },
    ["list", slug],
    open,
  );
  const invalidate = [["manage_page_translation", "list", slug]];
  const setLocaleMut = usePagesRpcMutation("manage_page_translation", invalidate);
  const createMut = usePagesRpcMutation("manage_page_translation", invalidate);

  const currentLocale = listQ.data?.translations.find((t) => t.slug === slug)?.locale ?? "en";
  const [locale, setLocale] = useState<string>("");
  const displayLocale = locale || currentLocale;

  const setPageLocale = async (l: string) => {
    setLocale(l);
    try {
      await setLocaleMut.mutateAsync({ p_action: "set_locale", p_slug: slug, p_locale: l });
      toast.success(`Locale set to ${l}`);
    } catch { /* handled */ }
  };

  const [newLocale, setNewLocale] = useState("");
  const [newTitle, setNewTitle] = useState("");
  const createTranslation = async () => {
    try {
      const res = (await createMut.mutateAsync({
        p_action: "create",
        p_slug: slug,
        p_locale: newLocale,
        p_title: newTitle || null,
      })) as { slug?: string } | null;
      const newSlug = res?.slug;
      toast.success(newSlug ? `Created — /admin/pages/${newSlug}` : "Translation created");
      setNewLocale("");
      setNewTitle("");
    } catch { /* handled */ }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Translations for /{slug}</DialogTitle>
        </DialogHeader>

        <div className="space-y-5 py-2">
          <div>
            <Label>This page's locale</Label>
            <Select value={displayLocale} onValueChange={setPageLocale}>
              <SelectTrigger className="mt-1"><SelectValue /></SelectTrigger>
              <SelectContent>
                {COMMON_LOCALES.map((l) => <SelectItem key={l} value={l}>{l}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>

          <Separator />

          <div>
            <Label className="mb-2 block">Translation group</Label>
            {listQ.isLoading ? (
              <Skeleton className="h-16 w-full" />
            ) : !listQ.data?.translations.length ? (
              <p className="text-sm text-muted-foreground">No translations linked yet.</p>
            ) : (
              <div className="space-y-2">
                {listQ.data.translations.map((t) => (
                  <div key={t.slug} className="flex items-center justify-between border border-border rounded p-2">
                    <div className="flex items-center gap-2 min-w-0">
                      <Badge variant="outline" className="uppercase">{t.locale}</Badge>
                      <span className="text-sm truncate">{t.title}</span>
                      <Badge variant="secondary" className="text-xs">{t.status}</Badge>
                    </div>
                    <Button size="sm" variant="ghost" asChild>
                      <Link to={`/admin/pages/${t.slug}`}>
                        Edit <ExternalLink className="h-3 w-3 ml-1" />
                      </Link>
                    </Button>
                  </div>
                ))}
              </div>
            )}
          </div>

          <Separator />

          <div className="space-y-2">
            <Label>Create translation</Label>
            <div className="flex gap-2">
              <Select value={newLocale} onValueChange={setNewLocale}>
                <SelectTrigger className="w-28"><SelectValue placeholder="Locale" /></SelectTrigger>
                <SelectContent>
                  {COMMON_LOCALES.filter((l) => !listQ.data?.translations.some((t) => t.locale === l)).map((l) => (
                    <SelectItem key={l} value={l}>{l}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Input placeholder="Title (optional)" value={newTitle} onChange={(e) => setNewTitle(e.target.value)} />
            </div>
          </div>
        </div>

        <DialogFooter>
          <Button onClick={createTranslation} disabled={!newLocale || createMut.isPending}>
            <Plus className="h-4 w-4 mr-2" /> Create draft
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
