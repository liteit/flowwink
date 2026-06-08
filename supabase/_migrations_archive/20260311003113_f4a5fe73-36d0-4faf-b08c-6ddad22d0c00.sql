UPDATE agent_skills 
SET tool_definition = jsonb_set(
  jsonb_set(
    tool_definition,
    '{function,parameters,properties,education}',
    '{"type": "array", "description": "Education entries", "items": {"type": "object", "properties": {"institution": {"type": "string"}, "degree": {"type": "string"}, "year": {"type": "string"}}}}'
  ),
  '{function,parameters,properties,experience_json}',
  '{"type": "array", "description": "Work experience entries", "items": {"type": "object", "properties": {"company": {"type": "string"}, "role": {"type": "string"}, "period": {"type": "string"}, "description": {"type": "string"}}}}'
)
WHERE name = 'manage_consultant_profile';