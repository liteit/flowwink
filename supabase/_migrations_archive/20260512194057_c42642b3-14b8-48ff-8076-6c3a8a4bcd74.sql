UPDATE public.agent_skills
SET handler = 'rpc:publish_scheduled_pages'
WHERE name = 'publish_scheduled_content'
  AND handler = 'edge:publish-scheduled-pages';