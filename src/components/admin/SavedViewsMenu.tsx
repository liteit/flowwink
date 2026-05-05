import { useState } from 'react';
import { Bookmark, BookmarkPlus, Check, Trash2, Users } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Switch } from '@/components/ui/switch';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import {
  useCreateSavedView,
  useDeleteSavedView,
  useSavedViews,
  type SavedView,
} from '@/hooks/useSavedViews';

interface Props<T extends Record<string, unknown>> {
  scope: string;
  currentConfig: T;
  onApply: (config: T) => void;
  activeViewId?: string | null;
  onActiveViewChange?: (id: string | null) => void;
}

export function SavedViewsMenu<T extends Record<string, unknown>>({
  scope,
  currentConfig,
  onApply,
  activeViewId,
  onActiveViewChange,
}: Props<T>) {
  const { data: views = [] } = useSavedViews<T>(scope);
  const create = useCreateSavedView();
  const del = useDeleteSavedView();
  const [name, setName] = useState('');
  const [shared, setShared] = useState(false);
  const [savePopOpen, setSavePopOpen] = useState(false);

  const handleSave = async () => {
    if (!name.trim()) return;
    const v = await create.mutateAsync({
      scope,
      name: name.trim(),
      config: currentConfig,
      is_shared: shared,
    });
    onActiveViewChange?.(v.id);
    setName('');
    setShared(false);
    setSavePopOpen(false);
  };

  const handleApply = (v: SavedView<T>) => {
    onApply(v.config);
    onActiveViewChange?.(v.id);
  };

  return (
    <div className="flex items-center gap-1">
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="outline" size="sm" className="gap-1.5">
            <Bookmark className="h-3.5 w-3.5" />
            {activeViewId
              ? views.find((v) => v.id === activeViewId)?.name ?? 'Views'
              : 'Views'}
            {views.length > 0 && (
              <span className="ml-1 text-xs text-muted-foreground">({views.length})</span>
            )}
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-64">
          <DropdownMenuLabel>Saved views</DropdownMenuLabel>
          {views.length === 0 && (
            <p className="px-2 py-1.5 text-xs text-muted-foreground">No saved views yet.</p>
          )}
          {views.map((v) => (
            <DropdownMenuItem
              key={v.id}
              className="flex items-center justify-between gap-2 cursor-pointer"
              onSelect={(e) => {
                e.preventDefault();
                handleApply(v);
              }}
            >
              <div className="flex items-center gap-2 flex-1 min-w-0">
                {activeViewId === v.id ? (
                  <Check className="h-3.5 w-3.5 text-primary shrink-0" />
                ) : (
                  <span className="w-3.5" />
                )}
                <span className="truncate">{v.name}</span>
                {v.is_shared && <Users className="h-3 w-3 text-muted-foreground shrink-0" />}
              </div>
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  del.mutate({ id: v.id, scope });
                  if (activeViewId === v.id) onActiveViewChange?.(null);
                }}
                className="text-muted-foreground hover:text-destructive p-0.5"
                title="Delete view"
              >
                <Trash2 className="h-3 w-3" />
              </button>
            </DropdownMenuItem>
          ))}
          {activeViewId && (
            <>
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => onActiveViewChange?.(null)}>
                Clear active view
              </DropdownMenuItem>
            </>
          )}
        </DropdownMenuContent>
      </DropdownMenu>

      <Popover open={savePopOpen} onOpenChange={setSavePopOpen}>
        <PopoverTrigger asChild>
          <Button variant="ghost" size="sm" className="gap-1" title="Save current filters as view">
            <BookmarkPlus className="h-3.5 w-3.5" />
          </Button>
        </PopoverTrigger>
        <PopoverContent align="end" className="w-64 space-y-3">
          <div className="space-y-2">
            <Label className="text-xs">Save current filters as</Label>
            <Input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="View name"
              onKeyDown={(e) => e.key === 'Enter' && handleSave()}
            />
          </div>
          <div className="flex items-center justify-between">
            <Label htmlFor="shared" className="text-xs flex items-center gap-1">
              <Users className="h-3 w-3" /> Share with team
            </Label>
            <Switch id="shared" checked={shared} onCheckedChange={setShared} />
          </div>
          <Button size="sm" className="w-full" onClick={handleSave} disabled={!name.trim()}>
            Save view
          </Button>
        </PopoverContent>
      </Popover>
    </div>
  );
}
