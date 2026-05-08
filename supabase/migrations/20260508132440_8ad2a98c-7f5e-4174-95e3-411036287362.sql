-- ── tags ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text NOT NULL UNIQUE,
  color text NOT NULL DEFAULT '#64748b',
  scope text NOT NULL DEFAULT '*',
  description text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tags_scope ON public.tags(scope);

ALTER TABLE public.tags ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tags_admin_all" ON public.tags;
CREATE POLICY "tags_admin_all" ON public.tags
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "tags_authenticated_read" ON public.tags;
CREATE POLICY "tags_authenticated_read" ON public.tags
  FOR SELECT TO authenticated
  USING (true);

DROP TRIGGER IF EXISTS tags_set_updated_at ON public.tags;
CREATE TRIGGER tags_set_updated_at
  BEFORE UPDATE ON public.tags
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ── entity_tags (polymorphic) ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.entity_tags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tag_id uuid NOT NULL REFERENCES public.tags(id) ON DELETE CASCADE,
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tag_id, entity_type, entity_id)
);

CREATE INDEX IF NOT EXISTS idx_entity_tags_entity ON public.entity_tags(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_entity_tags_tag ON public.entity_tags(tag_id);

ALTER TABLE public.entity_tags ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "entity_tags_admin_all" ON public.entity_tags;
CREATE POLICY "entity_tags_admin_all" ON public.entity_tags
  FOR ALL TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

DROP POLICY IF EXISTS "entity_tags_authenticated_read" ON public.entity_tags;
CREATE POLICY "entity_tags_authenticated_read" ON public.entity_tags
  FOR SELECT TO authenticated
  USING (true);
