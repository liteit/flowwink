-- Replace publish-scheduled-pages edge function with a pure SQL function
CREATE OR REPLACE FUNCTION public.publish_scheduled_pages()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now timestamptz := now();
  v_page record;
  v_published int := 0;
  v_results jsonb := '[]'::jsonb;
BEGIN
  FOR v_page IN
    SELECT id, title, slug, scheduled_at
    FROM public.pages
    WHERE status = 'reviewing'
      AND scheduled_at IS NOT NULL
      AND scheduled_at <= v_now
  LOOP
    UPDATE public.pages
       SET status = 'published',
           scheduled_at = NULL,
           updated_at = v_now
     WHERE id = v_page.id;

    INSERT INTO public.audit_logs (action, entity_type, entity_id, metadata)
    VALUES (
      'scheduled_publish',
      'page',
      v_page.id::text,
      jsonb_build_object('title', v_page.title, 'slug', v_page.slug, 'scheduled_at', v_page.scheduled_at)
    );

    INSERT INTO public.audit_logs (action, entity_type, entity_id, metadata)
    VALUES (
      'cache_invalidate',
      'cache',
      v_page.slug,
      jsonb_build_object('slug', v_page.slug, 'source', 'scheduled_publish', 'timestamp', v_now)
    );

    v_published := v_published + 1;
    v_results := v_results || jsonb_build_object('id', v_page.id, 'title', v_page.title, 'success', true);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'published', v_published, 'results', v_results);
END;
$$;

REVOKE ALL ON FUNCTION public.publish_scheduled_pages() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.publish_scheduled_pages() TO service_role;