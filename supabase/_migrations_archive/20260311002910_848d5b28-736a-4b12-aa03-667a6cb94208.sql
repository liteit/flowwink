UPDATE agent_skills 
SET tool_definition = jsonb_set(
  tool_definition,
  '{parameters,properties,education}',
  '{"type": "array", "description": "Education history", "items": {"type": "object", "properties": {"degree": {"type": "string"}, "school": {"type": "string"}, "year": {"type": "string"}}}}'
)
WHERE name = 'manage_consultant_profile' 
AND tool_definition->'parameters'->'properties'->'education' IS NOT NULL;