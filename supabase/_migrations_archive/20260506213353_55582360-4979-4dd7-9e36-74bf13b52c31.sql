CREATE OR REPLACE FUNCTION public.mcp_global_search(p_search_query text, p_result_limit int DEFAULT 8)
RETURNS TABLE (entity_type text, entity_id uuid, title text, subtitle text, url text, rank real)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT * FROM public.global_search(p_search_query, p_result_limit);
$$;
GRANT EXECUTE ON FUNCTION public.mcp_global_search(text, int) TO authenticated;
COMMENT ON FUNCTION public.mcp_global_search IS 'MCP-callable wrapper around global_search() with p_-prefixed args matching agent-execute convention.';