import { useState } from 'react';
import { Plus, X, Tag as TagIcon } from 'lucide-react';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover';
import {
  useAttachTag,
  useCreateTag,
  useDetachTag,
  useEntityTags,
  useTags,
} from '@/hooks/useEntityTags';

interface Props {
  entityType: string;
  entityId: string;
  scope?: string;
  compact?: boolean;
}

const COLORS = ['#64748b', '#ef4444', '#f97316', '#eab308', '#22c55e', '#06b6d4', '#3b82f6', '#a855f7', '#ec4899'];

export function EntityTags({ entityType, entityId, scope, compact }: Props) {
  const { data: attached = [] } = useEntityTags(entityType, entityId);
  const { data: allTags = [] } = useTags(scope);
  const attach = useAttachTag();
  const detach = useDetachTag();
  const create = useCreateTag();
  const [newName, setNewName] = useState('');
  const [color, setColor] = useState(COLORS[0]);
  const [open, setOpen] = useState(false);

  const attachedIds = new Set(attached.map((a) => a.tag_id));
  const available = allTags.filter((t) => !attachedIds.has(t.id));

  const handleCreate = async () => {
    if (!newName.trim()) return;
    const tag = await create.mutateAsync({ name: newName.trim(), color, scope });
    await attach.mutateAsync({ entity_type: entityType, entity_id: entityId, tag_id: tag.id });
    setNewName('');
  };

  return (
    <div className={`flex flex-wrap items-center gap-1.5 ${compact ? '' : 'py-1'}`}>
      {attached.map((row) => (
        <Badge
          key={row.id}
          variant="outline"
          className="gap-1 pl-2 pr-1 border-2"
          style={{ borderColor: row.tag?.color, color: row.tag?.color }}
        >
          {row.tag?.name}
          <button
            type="button"
            onClick={() => detach.mutate({ id: row.id, entity_type: entityType, entity_id: entityId })}
            className="hover:bg-muted rounded-sm p-0.5"
          >
            <X className="h-3 w-3" />
          </button>
        </Badge>
      ))}

      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild>
          <Button variant="ghost" size="sm" className="h-6 px-2 text-xs gap-1">
            <Plus className="h-3 w-3" /> Tag
          </Button>
        </PopoverTrigger>
        <PopoverContent className="w-64 p-3 space-y-3" align="start">
          {available.length > 0 && (
            <div className="space-y-1">
              <p className="text-xs font-medium text-muted-foreground">Available</p>
              <div className="flex flex-wrap gap-1">
                {available.map((t) => (
                  <Badge
                    key={t.id}
                    variant="outline"
                    className="cursor-pointer border-2"
                    style={{ borderColor: t.color, color: t.color }}
                    onClick={() => attach.mutate({ entity_type: entityType, entity_id: entityId, tag_id: t.id })}
                  >
                    {t.name}
                  </Badge>
                ))}
              </div>
            </div>
          )}
          <div className="space-y-2 border-t pt-2">
            <p className="text-xs font-medium text-muted-foreground flex items-center gap-1">
              <TagIcon className="h-3 w-3" /> New tag
            </p>
            <div className="flex gap-1">
              <Input
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
                placeholder="Tag name"
                className="h-8 text-sm"
                onKeyDown={(e) => e.key === 'Enter' && handleCreate()}
              />
              <Button size="sm" className="h-8" onClick={handleCreate} disabled={!newName.trim()}>
                Add
              </Button>
            </div>
            <div className="flex gap-1">
              {COLORS.map((c) => (
                <button
                  key={c}
                  type="button"
                  onClick={() => setColor(c)}
                  className={`h-5 w-5 rounded-full border-2 ${color === c ? 'border-foreground' : 'border-transparent'}`}
                  style={{ backgroundColor: c }}
                />
              ))}
            </div>
          </div>
        </PopoverContent>
      </Popover>
    </div>
  );
}
