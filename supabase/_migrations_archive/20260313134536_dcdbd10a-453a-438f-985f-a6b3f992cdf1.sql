UPDATE public.agent_skills 
SET tool_definition = jsonb_set(
  tool_definition,
  '{function,parameters,properties,skill,description}',
  '"The skill name to call on the peer (e.g. generate_track)"'::jsonb
),
description = 'Send a request to a connected A2A peer agent. Connected to SoundSpace for music generation via generate_track skill.'
WHERE id = '18dd2c37-361d-4cee-a7bc-c01ff8743e8a';