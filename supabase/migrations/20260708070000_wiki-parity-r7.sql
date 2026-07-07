-- Wiki: parity round 7 (docs/parity/capabilities/wiki.json)
-- Adds: page hierarchy (parent_slug + tree/children RPC with cycle guard),
-- version history (wiki_page_revisions + capture trigger + list/get/restore),
-- and access permissions (visibility internal|admin, editable_by
-- authenticated|admin, enforced in RLS + manage RPC).
--
-- Idempotent DDL. Forward-dated for the Lovable-managed migrate runner
-- (backdated files are silently skipped).

-- ── 1. Schema additions ──────────────────────────────────────────────────────
ALTER TABLE public.wiki_pages ADD COLUMN IF NOT EXISTS parent_slug text;
ALTER TABLE public.wiki_pages ADD COLUMN IF NOT EXISTS visibility text NOT NULL DEFAULT 'internal';
ALTER TABLE public.wiki_pages ADD COLUMN IF NOT EXISTS editable_by text NOT NULL DEFAULT 'authenticated';

ALTER TABLE public.wiki_pages DROP CONSTRAINT IF EXISTS wiki_pages_visibility_check;
ALTER TABLE public.wiki_pages
  ADD CONSTRAINT wiki_pages_visibility_check CHECK (visibility IN ('internal','admin'));
ALTER TABLE public.wiki_pages DROP CONSTRAINT IF EXISTS wiki_pages_editable_by_check;
ALTER TABLE public.wiki_pages
  ADD CONSTRAINT wiki_pages_editable_by_check CHECK (editable_by IN ('authenticated','admin'));
ALTER TABLE public.wiki_pages DROP CONSTRAINT IF EXISTS wiki_pages_parent_fk;
ALTER TABLE public.wiki_pages
  ADD CONSTRAINT wiki_pages_parent_fk FOREIGN KEY (parent_slug)
  REFERENCES public.wiki_pages(slug) ON DELETE SET NULL ON UPDATE CASCADE;

-- ── 2. Version history ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.wiki_page_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL,
  title text NOT NULL,
  content_md text NOT NULL,
  revision_no integer NOT NULL,
  action text NOT NULL DEFAULT 'update',
  edited_by uuid,
  revised_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS wiki_page_revisions_slug_idx
  ON public.wiki_page_revisions (slug, revision_no DESC);

ALTER TABLE public.wiki_page_revisions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Wiki revisions readable" ON public.wiki_page_revisions;
CREATE POLICY "Wiki revisions readable" ON public.wiki_page_revisions FOR SELECT
  USING (
    has_role(auth.uid(), 'admin'::app_role)
    OR (auth.uid() IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.wiki_pages w
      WHERE w.slug = wiki_page_revisions.slug AND w.visibility = 'internal'))
  );

CREATE OR REPLACE FUNCTION public.log_wiki_revision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.content_md IS NOT DISTINCT FROM NEW.content_md
     AND OLD.title IS NOT DISTINCT FROM NEW.title THEN
    RETURN NEW; -- metadata-only change (parent/visibility) — no content revision
  END IF;
  INSERT INTO public.wiki_page_revisions (slug, title, content_md, revision_no, action, edited_by)
  VALUES (OLD.slug, OLD.title, OLD.content_md,
    (SELECT COALESCE(MAX(revision_no),0)+1 FROM public.wiki_page_revisions WHERE slug = OLD.slug),
    lower(TG_OP), auth.uid());
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_wiki_pages_revision ON public.wiki_pages;
CREATE TRIGGER trg_wiki_pages_revision
  BEFORE UPDATE OR DELETE ON public.wiki_pages
  FOR EACH ROW EXECUTE FUNCTION public.log_wiki_revision();

CREATE OR REPLACE FUNCTION public.wiki_page_history(
  p_action text,
  p_slug text DEFAULT NULL,
  p_revision_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_rev public.wiki_page_revisions;
  v_rows jsonb;
  v_is_writer boolean;
BEGIN
  v_is_writer := auth.role() = 'service_role' OR has_role(auth.uid(),'admin');
  IF NOT (v_is_writer OR auth.uid() IS NOT NULL) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF p_action = 'list' THEN
    IF p_slug IS NULL THEN RAISE EXCEPTION 'list requires p_slug'; END IF;
    SELECT COALESCE(jsonb_agg(r ORDER BY r.revision_no DESC), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT id, slug, title, revision_no, action, edited_by, revised_at,
             length(content_md) AS content_length
      FROM public.wiki_page_revisions WHERE slug = p_slug
      ORDER BY revision_no DESC
      LIMIT LEAST(GREATEST(COALESCE(p_limit,20),1),100)
    ) r;
    RETURN jsonb_build_object('success', true, 'slug', p_slug, 'revisions', v_rows);

  ELSIF p_action = 'get' THEN
    IF p_revision_id IS NULL THEN RAISE EXCEPTION 'get requires p_revision_id'; END IF;
    SELECT * INTO v_rev FROM public.wiki_page_revisions WHERE id = p_revision_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Revision % not found', p_revision_id; END IF;
    RETURN jsonb_build_object('success', true, 'revision', to_jsonb(v_rev));

  ELSIF p_action = 'restore' THEN
    IF NOT v_is_writer THEN
      RAISE EXCEPTION 'Only admins can restore wiki revisions';
    END IF;
    IF p_revision_id IS NULL THEN RAISE EXCEPTION 'restore requires p_revision_id'; END IF;
    SELECT * INTO v_rev FROM public.wiki_page_revisions WHERE id = p_revision_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Revision % not found', p_revision_id; END IF;
    UPDATE public.wiki_pages
    SET title = v_rev.title, content_md = v_rev.content_md, updated_at = now(), updated_by = auth.uid()
    WHERE slug = v_rev.slug;
    IF NOT FOUND THEN
      -- Page was deleted — restore recreates it.
      INSERT INTO public.wiki_pages (slug, title, content_md, created_by, updated_by)
      VALUES (v_rev.slug, v_rev.title, v_rev.content_md, auth.uid(), auth.uid());
    END IF;
    RETURN jsonb_build_object('success', true, 'slug', v_rev.slug,
      'restored_revision_no', v_rev.revision_no);

  ELSE
    RAISE EXCEPTION 'Unknown action %. Use list|get|restore', p_action;
  END IF;
END;
$$;

-- ── 3. Hierarchy ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_wiki_hierarchy(
  p_action text,
  p_slug text DEFAULT NULL,
  p_parent_slug text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_rows jsonb;
  v_cursor text;
  v_depth integer := 0;
BEGIN
  IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin') OR auth.uid() IS NOT NULL) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF p_action = 'set_parent' THEN
    IF p_slug IS NULL THEN RAISE EXCEPTION 'set_parent requires p_slug'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.wiki_pages WHERE slug = p_slug) THEN
      RAISE EXCEPTION 'Page % not found', p_slug;
    END IF;
    IF p_parent_slug IS NOT NULL THEN
      IF p_parent_slug = p_slug THEN RAISE EXCEPTION 'A page cannot be its own parent'; END IF;
      IF NOT EXISTS (SELECT 1 FROM public.wiki_pages WHERE slug = p_parent_slug) THEN
        RAISE EXCEPTION 'Parent page % not found', p_parent_slug;
      END IF;
      -- Cycle guard: walk up from the proposed parent.
      v_cursor := p_parent_slug;
      WHILE v_cursor IS NOT NULL AND v_depth < 50 LOOP
        SELECT parent_slug INTO v_cursor FROM public.wiki_pages WHERE slug = v_cursor;
        IF v_cursor = p_slug THEN
          RAISE EXCEPTION 'Cannot set parent: % is a descendant of %', p_parent_slug, p_slug;
        END IF;
        v_depth := v_depth + 1;
      END LOOP;
    END IF;
    UPDATE public.wiki_pages SET parent_slug = p_parent_slug, updated_at = now() WHERE slug = p_slug;
    RETURN jsonb_build_object('success', true, 'slug', p_slug, 'parent_slug', p_parent_slug);

  ELSIF p_action = 'tree' THEN
    WITH RECURSIVE tree AS (
      SELECT slug, title, parent_slug, visibility, 0 AS depth,
             ARRAY[slug] AS path
      FROM public.wiki_pages WHERE parent_slug IS NULL
      UNION ALL
      SELECT w.slug, w.title, w.parent_slug, w.visibility, t.depth + 1,
             t.path || w.slug
      FROM public.wiki_pages w
      JOIN tree t ON w.parent_slug = t.slug
      WHERE t.depth < 20
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'slug', slug, 'title', title, 'parent_slug', parent_slug,
      'visibility', visibility, 'depth', depth, 'path', path)
      ORDER BY path), '[]'::jsonb)
    INTO v_rows FROM tree;
    RETURN jsonb_build_object('success', true, 'tree', v_rows,
      'note', 'flat depth-first list — indent by depth to render the tree');

  ELSIF p_action = 'children' THEN
    IF p_slug IS NULL THEN RAISE EXCEPTION 'children requires p_slug'; END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('slug', slug, 'title', title) ORDER BY title), '[]'::jsonb)
    INTO v_rows FROM public.wiki_pages WHERE parent_slug = p_slug;
    RETURN jsonb_build_object('success', true, 'slug', p_slug, 'children', v_rows);

  ELSE
    RAISE EXCEPTION 'Unknown action %. Use set_parent|tree|children', p_action;
  END IF;
END;
$$;

-- ── 4. Permissions ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manage_wiki_permissions(
  p_action text,
  p_slug text DEFAULT NULL,
  p_visibility text DEFAULT NULL,
  p_editable_by text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row record;
  v_rows jsonb;
BEGIN
  IF p_action = 'get' THEN
    IF NOT (auth.role() = 'service_role' OR auth.uid() IS NOT NULL) THEN
      RAISE EXCEPTION 'Not authorized';
    END IF;
    IF p_slug IS NULL THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'slug', slug, 'title', title, 'visibility', visibility, 'editable_by', editable_by)
        ORDER BY slug), '[]'::jsonb)
      INTO v_rows FROM public.wiki_pages;
      RETURN jsonb_build_object('success', true, 'pages', v_rows);
    END IF;
    SELECT slug, title, visibility, editable_by INTO v_row FROM public.wiki_pages WHERE slug = p_slug;
    IF NOT FOUND THEN RAISE EXCEPTION 'Page % not found', p_slug; END IF;
    RETURN jsonb_build_object('success', true, 'slug', v_row.slug,
      'visibility', v_row.visibility, 'editable_by', v_row.editable_by);

  ELSIF p_action = 'set' THEN
    IF NOT (auth.role() = 'service_role' OR has_role(auth.uid(),'admin')) THEN
      RAISE EXCEPTION 'Only admins can change wiki permissions';
    END IF;
    IF p_slug IS NULL THEN RAISE EXCEPTION 'set requires p_slug'; END IF;
    IF p_visibility IS NOT NULL AND p_visibility NOT IN ('internal','admin') THEN
      RAISE EXCEPTION 'visibility must be internal or admin';
    END IF;
    IF p_editable_by IS NOT NULL AND p_editable_by NOT IN ('authenticated','admin') THEN
      RAISE EXCEPTION 'editable_by must be authenticated or admin';
    END IF;
    UPDATE public.wiki_pages SET
      visibility = COALESCE(p_visibility, visibility),
      editable_by = COALESCE(p_editable_by, editable_by),
      updated_at = now()
    WHERE slug = p_slug
    RETURNING slug, visibility, editable_by INTO v_row;
    IF NOT FOUND THEN RAISE EXCEPTION 'Page % not found', p_slug; END IF;
    RETURN jsonb_build_object('success', true, 'slug', v_row.slug,
      'visibility', v_row.visibility, 'editable_by', v_row.editable_by);

  ELSE
    RAISE EXCEPTION 'Unknown action %. Use get|set', p_action;
  END IF;
END;
$$;

-- ── 5. RLS honors per-page permissions ───────────────────────────────────────
DROP POLICY IF EXISTS "Wiki readable by authenticated" ON public.wiki_pages;
CREATE POLICY "Wiki readable by authenticated" ON public.wiki_pages FOR SELECT
  USING (
    has_role(auth.uid(), 'admin'::app_role)
    OR (auth.uid() IS NOT NULL AND visibility = 'internal')
  );

DROP POLICY IF EXISTS "Wiki update by authenticated" ON public.wiki_pages;
CREATE POLICY "Wiki update by authenticated" ON public.wiki_pages FOR UPDATE
  USING (
    has_role(auth.uid(), 'admin'::app_role)
    OR (auth.uid() IS NOT NULL AND editable_by = 'authenticated')
  )
  WITH CHECK (
    has_role(auth.uid(), 'admin'::app_role)
    OR (auth.uid() IS NOT NULL AND editable_by = 'authenticated')
  );
