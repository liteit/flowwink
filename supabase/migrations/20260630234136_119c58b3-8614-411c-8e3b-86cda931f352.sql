
CREATE TABLE IF NOT EXISTS public.flowtable_bases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT NOT NULL,
  icon TEXT DEFAULT 'Table2',
  color TEXT DEFAULT '#3b82f6',
  description TEXT,
  owner_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  workspace_shared BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(owner_id, slug)
);

CREATE TABLE IF NOT EXISTS public.flowtable_tables (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  base_id UUID NOT NULL REFERENCES public.flowtable_bases(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  slug TEXT NOT NULL,
  view_mode TEXT NOT NULL DEFAULT 'grid',
  position INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(base_id, slug)
);

CREATE TABLE IF NOT EXISTS public.flowtable_fields (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_id UUID NOT NULL REFERENCES public.flowtable_tables(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  key TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'text',
  options JSONB NOT NULL DEFAULT '{}'::jsonb,
  position INT NOT NULL DEFAULT 0,
  width INT NOT NULL DEFAULT 180,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(table_id, key)
);

CREATE TABLE IF NOT EXISTS public.flowtable_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_id UUID NOT NULL REFERENCES public.flowtable_tables(id) ON DELETE CASCADE,
  values JSONB NOT NULL DEFAULT '{}'::jsonb,
  position DOUBLE PRECISION NOT NULL DEFAULT 0,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_flowtable_tables_base ON public.flowtable_tables(base_id);
CREATE INDEX IF NOT EXISTS idx_flowtable_fields_table ON public.flowtable_fields(table_id, position);
CREATE INDEX IF NOT EXISTS idx_flowtable_records_table ON public.flowtable_records(table_id, position);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.flowtable_bases TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.flowtable_tables TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.flowtable_fields TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.flowtable_records TO authenticated;
GRANT ALL ON public.flowtable_bases TO service_role;
GRANT ALL ON public.flowtable_tables TO service_role;
GRANT ALL ON public.flowtable_fields TO service_role;
GRANT ALL ON public.flowtable_records TO service_role;

ALTER TABLE public.flowtable_bases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flowtable_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flowtable_fields ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.flowtable_records ENABLE ROW LEVEL SECURITY;

-- Helper: access predicate for a base
CREATE OR REPLACE FUNCTION public.can_access_flowtable_base(_base_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.flowtable_bases b
    WHERE b.id = _base_id
      AND (b.owner_id = auth.uid() OR b.workspace_shared = true)
  );
$$;

-- Bases policies
DROP POLICY IF EXISTS "flowtable_bases owner or shared read" ON public.flowtable_bases;
CREATE POLICY "flowtable_bases owner or shared read" ON public.flowtable_bases
  FOR SELECT TO authenticated
  USING (owner_id = auth.uid() OR workspace_shared = true);

DROP POLICY IF EXISTS "flowtable_bases owner write" ON public.flowtable_bases;
CREATE POLICY "flowtable_bases owner write" ON public.flowtable_bases
  FOR INSERT TO authenticated
  WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS "flowtable_bases owner update" ON public.flowtable_bases;
CREATE POLICY "flowtable_bases owner update" ON public.flowtable_bases
  FOR UPDATE TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS "flowtable_bases owner delete" ON public.flowtable_bases;
CREATE POLICY "flowtable_bases owner delete" ON public.flowtable_bases
  FOR DELETE TO authenticated
  USING (owner_id = auth.uid());

-- Tables policies (inherit via base)
DROP POLICY IF EXISTS "flowtable_tables access" ON public.flowtable_tables;
CREATE POLICY "flowtable_tables access" ON public.flowtable_tables
  FOR ALL TO authenticated
  USING (public.can_access_flowtable_base(base_id))
  WITH CHECK (public.can_access_flowtable_base(base_id));

-- Fields policies (inherit via table)
DROP POLICY IF EXISTS "flowtable_fields access" ON public.flowtable_fields;
CREATE POLICY "flowtable_fields access" ON public.flowtable_fields
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.flowtable_tables t
    WHERE t.id = table_id AND public.can_access_flowtable_base(t.base_id)
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.flowtable_tables t
    WHERE t.id = table_id AND public.can_access_flowtable_base(t.base_id)
  ));

-- Records policies
DROP POLICY IF EXISTS "flowtable_records access" ON public.flowtable_records;
CREATE POLICY "flowtable_records access" ON public.flowtable_records
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.flowtable_tables t
    WHERE t.id = table_id AND public.can_access_flowtable_base(t.base_id)
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.flowtable_tables t
    WHERE t.id = table_id AND public.can_access_flowtable_base(t.base_id)
  ));

-- updated_at triggers
CREATE OR REPLACE FUNCTION public.flowtable_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS flowtable_bases_touch ON public.flowtable_bases;
CREATE TRIGGER flowtable_bases_touch BEFORE UPDATE ON public.flowtable_bases
  FOR EACH ROW EXECUTE FUNCTION public.flowtable_touch_updated_at();

DROP TRIGGER IF EXISTS flowtable_tables_touch ON public.flowtable_tables;
CREATE TRIGGER flowtable_tables_touch BEFORE UPDATE ON public.flowtable_tables
  FOR EACH ROW EXECUTE FUNCTION public.flowtable_touch_updated_at();

DROP TRIGGER IF EXISTS flowtable_records_touch ON public.flowtable_records;
CREATE TRIGGER flowtable_records_touch BEFORE UPDATE ON public.flowtable_records
  FOR EACH ROW EXECUTE FUNCTION public.flowtable_touch_updated_at();
