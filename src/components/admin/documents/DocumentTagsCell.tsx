import { useState, KeyboardEvent } from "react";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { X, Plus } from "lucide-react";
import { useUpdateDocument } from "@/hooks/useDocuments";

interface Props {
  documentId: string;
  tags: string[] | null;
}

/**
 * Inline tag editor for a documents row. Renders tags as badges with an
 * inline "x" to remove and a small input (opens on +) to add new ones.
 * Persists via useUpdateDocument.
 */
export function DocumentTagsCell({ documentId, tags }: Props) {
  const current = tags ?? [];
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState("");
  const update = useUpdateDocument();

  const commit = (next: string[]) => {
    update.mutate({ id: documentId, patch: { tags: next } });
  };

  const addTag = () => {
    const t = draft.trim();
    if (!t) return;
    if (current.includes(t)) {
      setDraft("");
      setAdding(false);
      return;
    }
    commit([...current, t]);
    setDraft("");
    setAdding(false);
  };

  const removeTag = (t: string) => commit(current.filter((x) => x !== t));

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Enter") {
      e.preventDefault();
      addTag();
    } else if (e.key === "Escape") {
      setDraft("");
      setAdding(false);
    }
  };

  return (
    <div className="flex flex-wrap items-center gap-1">
      {current.map((t) => (
        <Badge key={t} variant="secondary" className="gap-1 pr-1">
          <span>{t}</span>
          <button
            type="button"
            aria-label={`Remove tag ${t}`}
            onClick={() => removeTag(t)}
            className="rounded hover:bg-muted-foreground/20 p-0.5"
          >
            <X className="h-3 w-3" />
          </button>
        </Badge>
      ))}
      {adding ? (
        <Input
          autoFocus
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={onKeyDown}
          onBlur={addTag}
          placeholder="tag"
          className="h-6 w-24 text-xs"
        />
      ) : (
        <Button
          type="button"
          size="icon"
          variant="ghost"
          className="h-6 w-6"
          onClick={() => setAdding(true)}
          aria-label="Add tag"
        >
          <Plus className="h-3 w-3" />
        </Button>
      )}
    </div>
  );
}
