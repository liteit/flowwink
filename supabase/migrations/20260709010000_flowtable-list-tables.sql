-- Flowtable schema discovery (2026-07-09): the canonical skill set (query_flowtable /
-- manage_flowtable_record / list_flowtable_records) lets an agent read + filter a table
-- BY NAME, but nothing lets it discover WHICH tables live in a base + their field keys.
-- list_flowtable_tables closes that gap: given a base, return its tables with record
-- counts + field schema. Proven in the Flowtable→OpenClaw simulation (6000-row error
-- code base): base → list_flowtable_tables → query_flowtable is the full navigation loop.
CREATE OR REPLACE FUNCTION public.list_flowtable_tables(p_base_id uuid DEFAULT NULL, p_base_slug text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_base_id uuid;
BEGIN
  v_base_id := coalesce(p_base_id, (SELECT id FROM flowtable_bases WHERE slug = p_base_slug LIMIT 1));
  IF v_base_id IS NULL THEN RAISE EXCEPTION 'Provide p_base_id or a valid p_base_slug'; END IF;
  RETURN jsonb_build_object('base_id', v_base_id, 'tables', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'table_id', t.id, 'name', t.name, 'slug', t.slug,
      'record_count', (SELECT count(*) FROM flowtable_records r WHERE r.table_id = t.id),
      'fields', coalesce((SELECT jsonb_agg(jsonb_build_object('key', f.key, 'name', f.name, 'type', f.type) ORDER BY f.position)
                          FROM flowtable_fields f WHERE f.table_id = t.id), '[]'::jsonb)
    ) ORDER BY t.position)
    FROM flowtable_tables t WHERE t.base_id = v_base_id), '[]'::jsonb));
END; $$;
