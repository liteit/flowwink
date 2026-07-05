CREATE OR REPLACE FUNCTION public.convert_uom(p_qty numeric, p_from_uom uuid, p_to_uom uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $$
DECLARE v_from RECORD; v_to RECORD;
BEGIN
  IF p_from_uom = p_to_uom OR p_from_uom IS NULL OR p_to_uom IS NULL THEN RETURN p_qty; END IF;
  SELECT category_id, factor INTO v_from FROM uoms WHERE id = p_from_uom;
  IF NOT FOUND THEN RAISE EXCEPTION 'UoM % not found', p_from_uom; END IF;
  SELECT category_id, factor INTO v_to FROM uoms WHERE id = p_to_uom;
  IF NOT FOUND THEN RAISE EXCEPTION 'UoM % not found', p_to_uom; END IF;
  IF v_from.category_id <> v_to.category_id THEN
    RAISE EXCEPTION 'Cannot convert between UoMs in different categories';
  END IF;
  RETURN p_qty * v_from.factor / v_to.factor;
END; $$;

GRANT ALL ON FUNCTION public.convert_uom(numeric, uuid, uuid) TO anon, authenticated, service_role;

INSERT INTO public.uom_categories (id, name) VALUES
  ('11111111-1111-4111-8111-111111111111', 'Units'),
  ('33333333-3333-4333-8333-333333333333', 'Weight')
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.uoms (id, category_id, name, code, factor, is_reference) VALUES
  ('22222222-2222-4222-8222-222222222222', '11111111-1111-4111-8111-111111111111', 'Unit', 'unit', 1, true),
  ('44444444-4444-4444-8444-444444444441', '33333333-3333-4333-8333-333333333333', 'kg', 'kg', 1, true),
  ('44444444-4444-4444-8444-444444444442', '33333333-3333-4333-8333-333333333333', 'g',  'g',  0.001, false),
  ('44444444-4444-4444-8444-444444444443', '33333333-3333-4333-8333-333333333333', 't',  't',  1000, false)
ON CONFLICT (category_id, name) DO NOTHING;

INSERT INTO public.agent_skills (name, description, category, handler, scope, enabled, mcp_exposed, origin, trust_level, tool_definition, instructions)
VALUES (
  'search_kb',
  'Full-text search across KB articles. Returns matching articles ranked by relevance.',
  'search','edge:agent-execute','both', true, true, 'bundled', 'notify',
  '{"type":"function","function":{"name":"search_kb","description":"Search KB articles by keyword.","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["search"]},"query":{"type":"string"},"limit":{"type":"integer"}},"required":["action","query"]}}}'::jsonb,
  'Use action=search with a query string to find KB articles.'
)
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description, category = EXCLUDED.category, handler = EXCLUDED.handler,
  scope = EXCLUDED.scope, enabled = true, mcp_exposed = true,
  tool_definition = EXCLUDED.tool_definition, instructions = EXCLUDED.instructions;

UPDATE public.agent_skills
SET tool_definition = '{"type":"function","function":{"name":"convert_uom","description":"Convert a quantity between two Units of Measure in the same category.","parameters":{"type":"object","properties":{"p_qty":{"type":"number"},"p_from_uom":{"type":"string"},"p_to_uom":{"type":"string"}},"required":["p_qty","p_from_uom","p_to_uom"]}}}'::jsonb,
    mcp_exposed = true, enabled = true
WHERE name = 'convert_uom';