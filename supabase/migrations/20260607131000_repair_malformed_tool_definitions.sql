-- 11 enabled+mcp_exposed skills had a malformed tool_definition: it held the
-- bare parameters object ({ "type":"object", "properties":{...} }) instead of
-- the OpenAI function-calling envelope ({ "type":"function", "function":{ name,
-- description, parameters } }). Because mcp-server filters on
-- tool_definition.function.name and execute_skill matches on it, these skills
-- were INVISIBLE to the entire MCP surface (catalog + dispatch) and unfindable
-- by external agents — despite their handlers (rpc:*) being fully functional.
--
-- Rebuild the envelope: wrap the existing bare-params object as `parameters`,
-- and fill name (= skill name) and description (= skill.description column).
-- Idempotent: only touches rows where the inner function.name is still NULL.

UPDATE public.agent_skills
SET tool_definition = jsonb_build_object(
  'type', 'function',
  'function', jsonb_build_object(
    'name', name,
    'description', COALESCE(description, name),
    'parameters', CASE
      WHEN tool_definition ? 'properties' OR tool_definition->>'type' = 'object'
        THEN tool_definition
      ELSE COALESCE(
        tool_definition->'function'->'parameters',
        '{"type":"object","properties":{}}'::jsonb
      )
    END
  )
)
WHERE (tool_definition->'function'->>'name') IS NULL
  AND tool_definition IS NOT NULL;
